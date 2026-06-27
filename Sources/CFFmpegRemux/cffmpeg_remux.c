#include "cffmpeg_remux.h"

#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/dict.h"
#include "libavutil/mathematics.h"

#include <string.h>
#include <stdlib.h>

/* The intermediate buffer libavformat uses to pull bytes through our read
 * callback. 256 KiB keeps range reads chunky without holding much memory. */
#define PLOZZ_IO_BUFFER_SIZE (256 * 1024)

struct PlozzRemuxer {
    AVFormatContext   *input;
    AVIOContext       *input_avio;
    PlozzReadCallback  read_cb;
    PlozzSeekCallback  seek_cb;
    void              *opaque;
    int64_t            file_size;

    int                video_index;   /* input stream index, or -1 */
    int                audio_index;    /* input stream index, or -1 */

    char               error[256];
};

static void plozz_set_error(PlozzRemuxer *r, const char *prefix, int averr) {
    if (!r) return;
    char buf[160];
    if (av_strerror(averr, buf, sizeof(buf)) < 0) {
        snprintf(buf, sizeof(buf), "averror %d", averr);
    }
    snprintf(r->error, sizeof(r->error), "%s: %s", prefix ? prefix : "error", buf);
}

static void plozz_set_message(PlozzRemuxer *r, const char *message) {
    if (!r) return;
    snprintf(r->error, sizeof(r->error), "%s", message ? message : "");
}

/* AVIO trampolines: libavformat calls these with the PlozzRemuxer as opaque, and
 * we forward to the Swift-supplied callbacks. Forwarding here lets the Swift side
 * use simple semantics (read returns 0 at EOF) while we translate 0 → AVERROR_EOF
 * the way libavformat expects. */
static int plozz_avio_read(void *opaque, uint8_t *buf, int buf_size) {
    PlozzRemuxer *r = (PlozzRemuxer *)opaque;
    int n = r->read_cb(r->opaque, buf, buf_size);
    if (n == 0) return AVERROR_EOF;
    return n;
}

static int64_t plozz_avio_seek(void *opaque, int64_t offset, int whence) {
    PlozzRemuxer *r = (PlozzRemuxer *)opaque;
    if (whence == AVSEEK_SIZE) {
        return r->file_size > 0 ? r->file_size : r->seek_cb(r->opaque, 0, AVSEEK_SIZE);
    }
    return r->seek_cb(r->opaque, offset, whence);
}

PlozzRemuxer *plozz_remuxer_create(void) {
    PlozzRemuxer *r = (PlozzRemuxer *)calloc(1, sizeof(PlozzRemuxer));
    if (r) {
        r->video_index = -1;
        r->audio_index = -1;
    }
    return r;
}

int plozz_remuxer_open(PlozzRemuxer *r,
                       PlozzReadCallback read_cb,
                       PlozzSeekCallback seek_cb,
                       void *opaque,
                       int64_t file_size) {
    if (!r || !read_cb || !seek_cb) return AVERROR(EINVAL);

    r->read_cb = read_cb;
    r->seek_cb = seek_cb;
    r->opaque = opaque;
    r->file_size = file_size;

    unsigned char *iobuf = (unsigned char *)av_malloc(PLOZZ_IO_BUFFER_SIZE);
    if (!iobuf) { plozz_set_message(r, "out of memory allocating IO buffer"); return AVERROR(ENOMEM); }

    r->input_avio = avio_alloc_context(iobuf, PLOZZ_IO_BUFFER_SIZE,
                                       0, r, plozz_avio_read, NULL, plozz_avio_seek);
    if (!r->input_avio) {
        av_free(iobuf);
        plozz_set_message(r, "avio_alloc_context failed");
        return AVERROR(ENOMEM);
    }

    r->input = avformat_alloc_context();
    if (!r->input) {
        plozz_set_message(r, "avformat_alloc_context failed");
        return AVERROR(ENOMEM);
    }
    r->input->pb = r->input_avio;
    r->input->flags |= AVFMT_FLAG_CUSTOM_IO;

    int ret = avformat_open_input(&r->input, NULL, NULL, NULL);
    if (ret < 0) { plozz_set_error(r, "avformat_open_input", ret); return ret; }

    ret = avformat_find_stream_info(r->input, NULL);
    if (ret < 0) { plozz_set_error(r, "avformat_find_stream_info", ret); return ret; }

    /* Map the first video stream and the first AC-3 / E-AC-3 audio stream. We
     * keep the footprint lean: exactly one video + one audio passthrough. */
    for (unsigned i = 0; i < r->input->nb_streams; i++) {
        AVCodecParameters *par = r->input->streams[i]->codecpar;
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && r->video_index < 0) {
            r->video_index = (int)i;
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && r->audio_index < 0) {
            if (par->codec_id == AV_CODEC_ID_EAC3 || par->codec_id == AV_CODEC_ID_AC3) {
                r->audio_index = (int)i;
            }
        }
    }
    if (r->video_index < 0) {
        plozz_set_message(r, "no video stream found");
        return AVERROR_STREAM_NOT_FOUND;
    }
    /* Audio is optional but expected; if no AC-3/E-AC-3 found, fall back to the
     * first audio stream so the segment still carries sound. */
    if (r->audio_index < 0) {
        for (unsigned i = 0; i < r->input->nb_streams; i++) {
            if (r->input->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                r->audio_index = (int)i;
                break;
            }
        }
    }
    return PLOZZ_REMUX_OK;
}

double plozz_remuxer_duration_seconds(const PlozzRemuxer *r) {
    if (!r || !r->input) return 0.0;
    if (r->input->duration == AV_NOPTS_VALUE) return 0.0;
    return (double)r->input->duration / (double)AV_TIME_BASE;
}

int plozz_remuxer_video_stream_index(const PlozzRemuxer *r) {
    return r ? r->video_index : -1;
}

int plozz_remuxer_audio_stream_index(const PlozzRemuxer *r) {
    return r ? r->audio_index : -1;
}

/* Fragmented-MP4 movflags chosen for deterministic init capture:
 *   empty_moov       — write ftyp + an empty moov at write_header time (NOT
 *                      delayed), so the header bytes ARE the EXT-X-MAP init
 *                      segment and the same prefix leads every media segment.
 *   default_base_moof— default-base-is-moof, making each moof self-contained so
 *                      fragments are valid served in isolation / out of order.
 *   frag_keyframe    — start a fragment at each keyframe (our segments are
 *                      keyframe-aligned, so one fragment per segment).
 * We intentionally avoid the `cmaf` shorthand because it can enable delay_moov,
 * which would defer the moov past write_header and break the init-prefix split. */
static const char *PLOZZ_MOVFLAGS =
    "empty_moov+default_base_moof+frag_keyframe";

/* Build an output mp4 context writing to a fresh dynamic buffer, mirroring the
 * selected input streams with `-c copy` and a dvh1 video sample entry. On
 * success *out_oc and the per-output stream map are filled. */
static int plozz_build_output(PlozzRemuxer *r,
                              AVFormatContext **out_oc,
                              int *out_video_oidx,
                              int *out_audio_oidx) {
    *out_oc = NULL;
    *out_video_oidx = -1;
    *out_audio_oidx = -1;

    AVFormatContext *oc = NULL;
    int ret = avformat_alloc_output_context2(&oc, NULL, "mp4", NULL);
    if (ret < 0 || !oc) { plozz_set_error(r, "alloc_output_context2", ret); return ret < 0 ? ret : AVERROR(ENOMEM); }

    ret = avio_open_dyn_buf(&oc->pb);
    if (ret < 0) { plozz_set_error(r, "avio_open_dyn_buf", ret); avformat_free_context(oc); return ret; }

    int oidx = 0;
    int input_indices[2];
    int count = 0;
    if (r->video_index >= 0) input_indices[count++] = r->video_index;
    if (r->audio_index >= 0) input_indices[count++] = r->audio_index;

    for (int k = 0; k < count; k++) {
        AVStream *in_stream = r->input->streams[input_indices[k]];
        AVStream *out_stream = avformat_new_stream(oc, NULL);
        if (!out_stream) {
            plozz_set_message(r, "avformat_new_stream failed");
            avio_close_dyn_buf(oc->pb, NULL);
            avformat_free_context(oc);
            return AVERROR(ENOMEM);
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_stream->codecpar);
        if (ret < 0) {
            plozz_set_error(r, "avcodec_parameters_copy", ret);
            uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
            avformat_free_context(oc);
            return ret;
        }
        out_stream->codecpar->codec_tag = 0;
        out_stream->time_base = in_stream->time_base;

        if (input_indices[k] == r->video_index) {
            /* Tag the HEVC video sample entry as dvh1 so AVPlayer engages the
             * Dolby Vision path. The DOVI configuration record copied above as
             * coded_side_data drives movenc to emit the dvcC/dvvC box. */
            out_stream->codecpar->codec_tag = MKTAG('d', 'v', 'h', '1');
            *out_video_oidx = oidx;
        } else {
            *out_audio_oidx = oidx;
        }
        oidx++;
    }

    *out_oc = oc;
    return PLOZZ_REMUX_OK;
}

static int plozz_write_header_with_flags(PlozzRemuxer *r, AVFormatContext *oc, int sequence) {
    (void)sequence; /* movenc auto-numbers fragment sequence from 1. */
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "movflags", PLOZZ_MOVFLAGS, 0);
    int ret = avformat_write_header(oc, &opts);
    av_dict_free(&opts);
    if (ret < 0) plozz_set_error(r, "avformat_write_header", ret);
    return ret;
}

int plozz_remuxer_init_segment(PlozzRemuxer *r, uint8_t **out_buf, int *out_len) {
    if (!r || !out_buf || !out_len) return AVERROR(EINVAL);
    if (!r->input) { plozz_set_message(r, "remuxer not opened"); return AVERROR(EINVAL); }
    *out_buf = NULL; *out_len = 0;

    AVFormatContext *oc = NULL;
    int v_oidx = -1, a_oidx = -1;
    int ret = plozz_build_output(r, &oc, &v_oidx, &a_oidx);
    if (ret < 0) return ret;

    ret = plozz_write_header_with_flags(r, oc, 0);
    if (ret < 0) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return ret;
    }

    /* With empty_moov the header IS the init segment (ftyp + moov). Flush and
     * capture exactly those bytes, then discard the context without a trailer. */
    avio_flush(oc->pb);
    uint8_t *headerbuf = NULL;
    int header_len = avio_get_dyn_buf(oc->pb, &headerbuf);
    if (header_len <= 0 || !headerbuf) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        plozz_set_message(r, "empty init segment");
        return AVERROR_UNKNOWN;
    }
    uint8_t *copy = (uint8_t *)av_malloc((size_t)header_len);
    if (!copy) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return AVERROR(ENOMEM);
    }
    memcpy(copy, headerbuf, (size_t)header_len);

    uint8_t *discard = NULL;
    avio_close_dyn_buf(oc->pb, &discard);
    if (discard) av_free(discard);
    avformat_free_context(oc);

    *out_buf = copy;
    *out_len = header_len;
    return PLOZZ_REMUX_OK;
}

int plozz_remuxer_make_segment(PlozzRemuxer *r,
                               int sequence,
                               double start_seconds,
                               double end_seconds,
                               uint8_t **out_buf,
                               int *out_len) {
    if (!r || !out_buf || !out_len) return AVERROR(EINVAL);
    if (!r->input) { plozz_set_message(r, "remuxer not opened"); return AVERROR(EINVAL); }
    if (end_seconds <= start_seconds) { plozz_set_message(r, "empty segment range"); return AVERROR(EINVAL); }
    *out_buf = NULL; *out_len = 0;

    AVStream *v_in = r->input->streams[r->video_index];

    /* Seek to the keyframe at or before the segment start on the video stream. */
    int64_t seek_ts = (int64_t)(start_seconds / av_q2d(v_in->time_base));
    int ret = av_seek_frame(r->input, r->video_index, seek_ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) { plozz_set_error(r, "av_seek_frame", ret); return ret; }

    AVFormatContext *oc = NULL;
    int v_oidx = -1, a_oidx = -1;
    ret = plozz_build_output(r, &oc, &v_oidx, &a_oidx);
    if (ret < 0) return ret;

    ret = plozz_write_header_with_flags(r, oc, sequence);
    if (ret < 0) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return ret;
    }

    /* Record the init-prefix length so we can return only the media bytes
     * (styp+moof+mdat …); the init segment is served separately via EXT-X-MAP. */
    avio_flush(oc->pb);
    uint8_t *peek = NULL;
    int prefix_len = avio_get_dyn_buf(oc->pb, &peek);
    if (prefix_len < 0) prefix_len = 0;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return AVERROR(ENOMEM);
    }

    const double kEpsilon = 1e-6;
    int wrote_any = 0;
    int write_err = 0;

    while ((ret = av_read_frame(r->input, pkt)) >= 0) {
        int in_idx = pkt->stream_index;
        int oidx = -1;
        if (in_idx == r->video_index) oidx = v_oidx;
        else if (in_idx == r->audio_index) oidx = a_oidx;

        if (oidx < 0) { av_packet_unref(pkt); continue; }

        AVStream *in_stream = r->input->streams[in_idx];
        int64_t ref_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
        double t = (ref_ts == AV_NOPTS_VALUE) ? start_seconds
                                              : ref_ts * av_q2d(in_stream->time_base);

        /* Stop at the next video keyframe that begins at/after the segment end:
         * that frame opens the following segment. */
        if (in_idx == r->video_index && (pkt->flags & AV_PKT_FLAG_KEY) &&
            t >= end_seconds - kEpsilon && wrote_any) {
            av_packet_unref(pkt);
            break;
        }
        /* Drop anything beyond the segment window so segments don't overlap. */
        if (t >= end_seconds + kEpsilon) { av_packet_unref(pkt); continue; }

        AVStream *out_stream = oc->streams[oidx];
        av_packet_rescale_ts(pkt, in_stream->time_base, out_stream->time_base);
        pkt->stream_index = oidx;
        pkt->pos = -1;

        ret = av_interleaved_write_frame(oc, pkt);
        av_packet_unref(pkt);
        if (ret < 0) { write_err = ret; plozz_set_error(r, "av_interleaved_write_frame", ret); break; }
        wrote_any = 1;
    }
    av_packet_free(&pkt);

    if (write_err < 0) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return write_err;
    }

    ret = av_write_trailer(oc);
    if (ret < 0) {
        plozz_set_error(r, "av_write_trailer", ret);
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); if (tmp) av_free(tmp);
        avformat_free_context(oc);
        return ret;
    }

    uint8_t *full = NULL;
    int full_len = avio_close_dyn_buf(oc->pb, &full);
    avformat_free_context(oc);

    if (full_len <= 0 || !full) {
        if (full) av_free(full);
        plozz_set_message(r, "empty media segment");
        return AVERROR_UNKNOWN;
    }
    if (!wrote_any) {
        av_free(full);
        plozz_set_message(r, "no packets in segment range");
        return AVERROR_UNKNOWN;
    }

    if (prefix_len > full_len) prefix_len = 0;   /* defensive */
    int media_len = full_len - prefix_len;
    uint8_t *media = (uint8_t *)av_malloc((size_t)media_len);
    if (!media) { av_free(full); return AVERROR(ENOMEM); }
    memcpy(media, full + prefix_len, (size_t)media_len);
    av_free(full);

    *out_buf = media;
    *out_len = media_len;
    return PLOZZ_REMUX_OK;
}

void plozz_remuxer_destroy(PlozzRemuxer *r) {
    if (!r) return;
    if (r->input) {
        /* avformat_close_input frees the AVIOContext it owns only when it
         * allocated it; ours was set manually, so free its buffer + context. */
        AVIOContext *avio = r->input_avio;
        avformat_close_input(&r->input);
        if (avio) {
            if (avio->buffer) av_freep(&avio->buffer);
            avio_context_free(&avio);
        }
        r->input_avio = NULL;
    } else if (r->input_avio) {
        if (r->input_avio->buffer) av_freep(&r->input_avio->buffer);
        avio_context_free(&r->input_avio);
    }
    free(r);
}

void plozz_free(void *ptr) {
    if (ptr) av_free(ptr);
}

const char *plozz_remuxer_last_error(const PlozzRemuxer *r) {
    if (!r) return "null remuxer";
    return r->error[0] ? r->error : "ok";
}
