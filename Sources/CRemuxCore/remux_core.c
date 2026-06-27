/*
 * remux_core.c — Plozz local-remux C core implementation.
 *
 * See remux_core.h for the public contract. This file is the only place the
 * FFmpeg framework headers are included, so the importing Swift module never
 * needs them on its own include path.
 */
#include "remux_core.h"

#include <Libavformat/avformat.h>
#include <Libavformat/avio.h>
#include <Libavcodec/avcodec.h>
#include <Libavutil/avutil.h>
#include <Libavutil/dict.h>
#include <Libavutil/error.h>
#include <Libavutil/mathematics.h>
#include <Libavutil/mem.h>
#include <Libavutil/dovi_meta.h>

#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>

/* ----- logging ----------------------------------------------------------- */

static plozz_remux_log_cb g_log_cb = NULL;
static void *g_log_opaque = NULL;

void plozz_remux_set_log(plozz_remux_log_cb cb, void *opaque) {
    g_log_cb = cb;
    g_log_opaque = opaque;
}

static void remux_log(int level, const char *fmt, ...) {
    if (!g_log_cb) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    g_log_cb(g_log_opaque, level, buf);
}

/* ----- session ----------------------------------------------------------- */

#define PLOZZ_AVIO_BUFFER_SIZE (1 << 20)  /* 1 MiB read buffer */
#define PLOZZ_MAX_SEGMENTS 100000

struct plozz_remux_session {
    void *opaque;
    plozz_remux_read_cb read_cb;
    plozz_remux_seek_cb seek_cb;

    AVFormatContext *ic;     /* input (Matroska) demuxer */
    AVIOContext *avio;       /* custom AVIO over the callbacks */
    unsigned char *avio_buf; /* buffer owned by avio (freed via avio_context_free) */

    int video_index;         /* source video stream index */
    int audio_index;         /* source audio stream index (-1 if none) */

    plozz_remux_segment *segments;
    int segment_count;

    double duration_seconds;
};

/* ----- AVIO callback adapters ------------------------------------------- */

static int avio_read_adapter(void *opaque, uint8_t *buf, int buf_size) {
    plozz_remux_session *s = (plozz_remux_session *)opaque;
    int n = s->read_cb(s->opaque, buf, buf_size);
    if (n == 0) return AVERROR_EOF;
    if (n < 0) return AVERROR(EIO);
    return n;
}

static int64_t avio_seek_adapter(void *opaque, int64_t offset, int whence) {
    plozz_remux_session *s = (plozz_remux_session *)opaque;
    if (whence & AVSEEK_SIZE) {
        return s->seek_cb(s->opaque, 0, PLOZZ_REMUX_SEEK_SIZE);
    }
    /* Strip the AVSEEK_FORCE bit; pass the bare whence (SEEK_SET/CUR/END). */
    int base = whence & ~AVSEEK_FORCE;
    return s->seek_cb(s->opaque, offset, base);
}

/* ----- segment table ----------------------------------------------------- */

/*
 * Build the keyframe-aligned segment table from the video stream's libavformat
 * index. For Matroska this index is populated from the Cues at open time, so the
 * boundaries are the file's real IDR keyframes. Falls back to a fixed cadence
 * (relying on a BACKWARD seek to snap to a keyframe) when no index is available.
 */
static void build_segment_table(plozz_remux_session *s, double target_seconds) {
    AVStream *vst = s->ic->streams[s->video_index];
    double start_time = (s->ic->start_time != AV_NOPTS_VALUE)
        ? (double)s->ic->start_time / AV_TIME_BASE : 0.0;
    double duration = s->duration_seconds;
    if (target_seconds < 1.0) target_seconds = 6.0;

    int entries = avformat_index_get_entries_count(vst);
    remux_log(0, "remux: index has %d keyframe entries, duration=%.2fs", entries, duration);

    /* Collect keyframe times (seconds, 0-based) from the index. */
    double *kf = NULL;
    int kf_count = 0;
    if (entries > 0) {
        kf = (double *)malloc(sizeof(double) * (size_t)entries);
        if (kf) {
            for (int i = 0; i < entries; i++) {
                const AVIndexEntry *e = avformat_index_get_entry(vst, i);
                if (!e || !(e->flags & AVINDEX_KEYFRAME)) continue;
                if (e->timestamp == AV_NOPTS_VALUE) continue;
                double t = e->timestamp * av_q2d(vst->time_base) - start_time;
                if (t < 0) t = 0;
                kf[kf_count++] = t;
            }
        }
    }

    plozz_remux_segment *segs = NULL;
    int count = 0;

    if (kf_count > 1) {
        segs = (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)kf_count);
        double seg_start = kf[0] > 0.001 ? 0.0 : kf[0];
        for (int i = 1; i < kf_count && count < PLOZZ_MAX_SEGMENTS; i++) {
            if (kf[i] - seg_start >= target_seconds - 0.001) {
                segs[count].start_seconds = seg_start;
                segs[count].duration_seconds = kf[i] - seg_start;
                count++;
                seg_start = kf[i];
            }
        }
        /* Final tail segment up to the end of the file. */
        double tail_end = (duration > seg_start) ? duration : (kf[kf_count - 1]);
        if (tail_end > seg_start + 0.001 && count < PLOZZ_MAX_SEGMENTS) {
            segs[count].start_seconds = seg_start;
            segs[count].duration_seconds = tail_end - seg_start;
            count++;
        }
    }

    free(kf);

    /* Fallback: fixed cadence (BACKWARD seek snaps each to a real keyframe). */
    if (count == 0 && duration > 0) {
        int n = (int)(duration / target_seconds) + 1;
        if (n > PLOZZ_MAX_SEGMENTS) n = PLOZZ_MAX_SEGMENTS;
        segs = (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)n);
        double t = 0;
        while (t < duration - 0.001 && count < n) {
            double dur = target_seconds;
            if (t + dur > duration) dur = duration - t;
            segs[count].start_seconds = t;
            segs[count].duration_seconds = dur;
            count++;
            t += target_seconds;
        }
        remux_log(1, "remux: no usable index; using %d fixed-cadence segments", count);
    }

    s->segments = segs;
    s->segment_count = count;
}

/* ----- open -------------------------------------------------------------- */

/* Record a precise failure (stage + AVERROR) into the caller's result so an
 * opaque "demux failed" becomes an actionable reason on a cold device play. */
static void set_open_error(plozz_remux_open_result *r, int stage, int code) {
    if (!r) return;
    r->ok = 0;
    r->error_stage = stage;
    r->error_code = code;
}

/* Decode an AVERROR to text for the log sink (best-effort). */
static void log_averror(const char *what, int rc) {
    char errbuf[160];
    if (av_strerror(rc, errbuf, sizeof(errbuf)) < 0) {
        snprintf(errbuf, sizeof(errbuf), "unknown");
    }
    remux_log(2, "remux: %s failed (%d: %s)", what, rc, errbuf);
}

plozz_remux_session *plozz_remux_open(void *opaque,
                                      plozz_remux_read_cb read_cb,
                                      plozz_remux_seek_cb seek_cb,
                                      double target_segment_seconds,
                                      plozz_remux_open_result *out_result) {
    if (out_result) memset(out_result, 0, sizeof(*out_result));

    plozz_remux_session *s = (plozz_remux_session *)calloc(1, sizeof(*s));
    if (!s) { set_open_error(out_result, PLOZZ_REMUX_STAGE_ALLOC, 0); return NULL; }
    s->opaque = opaque;
    s->read_cb = read_cb;
    s->seek_cb = seek_cb;
    s->video_index = -1;
    s->audio_index = -1;

    s->avio_buf = (unsigned char *)av_malloc(PLOZZ_AVIO_BUFFER_SIZE);
    if (!s->avio_buf) {
        set_open_error(out_result, PLOZZ_REMUX_STAGE_ALLOC, 0);
        plozz_remux_close(s);
        return NULL;
    }

    s->avio = avio_alloc_context(s->avio_buf, PLOZZ_AVIO_BUFFER_SIZE, 0,
                                 s, avio_read_adapter, NULL, avio_seek_adapter);
    if (!s->avio) {
        set_open_error(out_result, PLOZZ_REMUX_STAGE_ALLOC, 0);
        plozz_remux_close(s);
        return NULL;
    }
    s->avio->seekable = AVIO_SEEKABLE_NORMAL;

    s->ic = avformat_alloc_context();
    if (!s->ic) {
        set_open_error(out_result, PLOZZ_REMUX_STAGE_ALLOC, 0);
        plozz_remux_close(s);
        return NULL;
    }
    s->ic->pb = s->avio;
    /* GENPTS: the Matroska demuxer stores only one timecode per block and leaves
     * DTS unset for reordered (B-frame) HEVC. movenc then warns "Timestamps are
     * unset in a packet for stream 0" and writes broken decode times, so AVPlayer
     * stalls at the first segment boundary. GENPTS makes libavformat reconstruct
     * the missing PTS/DTS during av_read_frame so every copied packet carries a
     * valid, monotonic DTS. */
    s->ic->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_GENPTS;

    int rc = avformat_open_input(&s->ic, NULL, NULL, NULL);
    if (rc < 0) {
        log_averror("avformat_open_input", rc);
        set_open_error(out_result, PLOZZ_REMUX_STAGE_OPEN_INPUT, rc);
        plozz_remux_close(s);
        return NULL;
    }

    rc = avformat_find_stream_info(s->ic, NULL);
    if (rc < 0) {
        log_averror("avformat_find_stream_info", rc);
        set_open_error(out_result, PLOZZ_REMUX_STAGE_FIND_STREAM_INFO, rc);
        plozz_remux_close(s);
        return NULL;
    }

    s->video_index = av_find_best_stream(s->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    s->audio_index = av_find_best_stream(s->ic, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (s->video_index < 0) {
        remux_log(2, "remux: no video stream");
        set_open_error(out_result, PLOZZ_REMUX_STAGE_NO_VIDEO, 0);
        plozz_remux_close(s);
        return NULL;
    }

    s->duration_seconds = (s->ic->duration != AV_NOPTS_VALUE)
        ? (double)s->ic->duration / AV_TIME_BASE : 0.0;

    build_segment_table(s, target_segment_seconds);
    if (s->segment_count <= 0) {
        remux_log(2, "remux: empty segment table");
        set_open_error(out_result, PLOZZ_REMUX_STAGE_EMPTY_SEGMENTS, 0);
        plozz_remux_close(s);
        return NULL;
    }

    if (out_result) {
        AVStream *vst = s->ic->streams[s->video_index];
        AVCodecParameters *vp = vst->codecpar;
        out_result->ok = 1;
        out_result->video_stream_index = s->video_index;
        out_result->audio_stream_index = s->audio_index;
        out_result->duration_seconds = s->duration_seconds;
        out_result->segment_count = s->segment_count;
        out_result->width = vp->width;
        out_result->height = vp->height;
        double fr = av_q2d(vst->avg_frame_rate);
        if (!(fr > 0.0)) { fr = av_q2d(vst->r_frame_rate); }
        if (!(fr > 0.0)) { fr = 0.0; }
        out_result->frame_rate = fr;

        const char *vname = avcodec_get_name(vp->codec_id);
        if (vname) { strncpy(out_result->video_codec, vname, sizeof(out_result->video_codec) - 1); }

        if (vp->codec_tag) {
            uint32_t t = vp->codec_tag;
            out_result->video_tag[0] = (char)(t & 0xff);
            out_result->video_tag[1] = (char)((t >> 8) & 0xff);
            out_result->video_tag[2] = (char)((t >> 16) & 0xff);
            out_result->video_tag[3] = (char)((t >> 24) & 0xff);
        }

        for (int i = 0; i < vp->nb_coded_side_data; i++) {
            if (vp->coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF) {
                out_result->has_dovi_config = 1;
                if (vp->coded_side_data[i].size >= (int)sizeof(AVDOVIDecoderConfigurationRecord)) {
                    const AVDOVIDecoderConfigurationRecord *dovi =
                        (const AVDOVIDecoderConfigurationRecord *)vp->coded_side_data[i].data;
                    out_result->dovi_profile = dovi->dv_profile;
                    out_result->dovi_level = dovi->dv_level;
                    out_result->dovi_el_present = dovi->el_present_flag;
                }
                break;
            }
        }

        if (s->audio_index >= 0) {
            AVCodecParameters *ap = s->ic->streams[s->audio_index]->codecpar;
            out_result->audio_channels = ap->ch_layout.nb_channels;
            const char *aname = avcodec_get_name(ap->codec_id);
            if (aname) { strncpy(out_result->audio_codec, aname, sizeof(out_result->audio_codec) - 1); }
        }
    }

    remux_log(0, "remux: opened, %d segments, %dx%d",
              s->segment_count,
              s->ic->streams[s->video_index]->codecpar->width,
              s->ic->streams[s->video_index]->codecpar->height);
    return s;
}

int plozz_remux_segment_count(plozz_remux_session *s) {
    return s ? s->segment_count : 0;
}

int plozz_remux_segment_at(plozz_remux_session *s, int index, plozz_remux_segment *out) {
    if (!s || !out || index < 0 || index >= s->segment_count) return 0;
    *out = s->segments[index];
    return 1;
}

/* ----- muxer helpers ----------------------------------------------------- */

/* DVH1 fourcc for the Dolby-Vision-tagged HEVC sample entry. */
#define PLOZZ_TAG_DVH1 MKTAG('d', 'v', 'h', '1')

/*
 * Build the output fMP4 context with a video (+ optional audio) stream copied
 * `-c copy` from the source. The video sample entry is tagged `dvh1` so AVPlayer
 * recognises the Dolby Vision track; movenc emits the dvcC/dvvC + dec3 boxes from
 * the copied codecpar side data. Output streams map: 0 = video, 1 = audio.
 */
static AVFormatContext *make_output(plozz_remux_session *s, int *out_audio_index) {
    AVFormatContext *oc = NULL;
    if (avformat_alloc_output_context2(&oc, NULL, "mp4", NULL) < 0 || !oc) return NULL;

    /* Permit movenc to emit the Dolby Vision dvcC/dvvC configuration box. movenc
     * gates these "unofficial" boxes behind strict_std_compliance; at the default
     * (NORMAL) it silently drops them and the stream loses its DoVi signal. */
    oc->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;

    AVStream *src_v = s->ic->streams[s->video_index];
    AVStream *dst_v = avformat_new_stream(oc, NULL);
    if (!dst_v) { avformat_free_context(oc); return NULL; }
    if (avcodec_parameters_copy(dst_v->codecpar, src_v->codecpar) < 0) {
        avformat_free_context(oc); return NULL;
    }
    dst_v->codecpar->codec_tag = PLOZZ_TAG_DVH1;
    dst_v->time_base = src_v->time_base;
    dst_v->avg_frame_rate = src_v->avg_frame_rate;
    dst_v->r_frame_rate = src_v->r_frame_rate;

    *out_audio_index = -1;
    if (s->audio_index >= 0) {
        AVStream *src_a = s->ic->streams[s->audio_index];
        AVStream *dst_a = avformat_new_stream(oc, NULL);
        if (dst_a && avcodec_parameters_copy(dst_a->codecpar, src_a->codecpar) >= 0) {
            dst_a->codecpar->codec_tag = 0; /* let movenc pick eac3 -> dec3 */
            dst_a->time_base = src_a->time_base;
            /* movenc needs the audio frame size to compute per-sample durations;
             * the Matroska demuxer often leaves it 0 for (E-)AC-3 ("track 1: codec
             * frame size is not set"), which makes the audio track's sample timing
             * wrong and stalls A/V. AC-3 and E-AC-3 are both 1536 samples/frame. */
            if ((dst_a->codecpar->codec_id == AV_CODEC_ID_AC3 ||
                 dst_a->codecpar->codec_id == AV_CODEC_ID_EAC3) &&
                dst_a->codecpar->frame_size <= 0) {
                dst_a->codecpar->frame_size = 1536;
            }
            *out_audio_index = dst_a->index;
        }
    }
    return oc;
}

static AVDictionary *fmp4_options(void) {
    AVDictionary *opts = NULL;
    /* empty_moov + default_base_moof + frag_keyframe = CMAF-style fMP4 with a
     * standalone moov init and one moof+mdat fragment per keyframe.
     *
     * delay_moov defers writing the moov until the first packet is muxed, so codec
     * parameters that are only known from the bitstream — notably E-AC-3's dec3
     * (Atmos/JOC) box — are populated before the moov is emitted. Without it,
     * write_header fails with "Cannot write moov atom before EAC3 packets parsed"
     * and every init/segment mux returns empty (→ 404 for AVPlayer). */
    /* frag_discont: each segment is muxed by an INDEPENDENT output context, so by
     * default movenc writes every fragment's tfdt baseMediaDecodeTime starting at
     * 0. With a shared EXT-X-MAP init that makes every segment claim to begin at
     * t=0; AVPlayer plays the first segment then sees the next one's decode time
     * jump backward and freezes (buffer full but stuck). frag_discont tells movenc
     * to seed the fragment start from the first packet's real DTS, so each segment
     * carries its true absolute position on the timeline. */
    av_dict_set(&opts, "movflags",
                "frag_keyframe+empty_moov+delay_moov+default_base_moof+frag_discont+write_colr", 0);
    return opts;
}

/* Forward declarations: the init/segment writers below share one full-fragment
 * muxer and the box scanner that splits its output into init (ftyp+moov) and
 * media (moof+mdat). */
static int media_offset_after_init(const uint8_t *buf, int len);
static int mux_segment_full(plozz_remux_session *s, int index,
                            uint8_t **out_buf, int *out_len);

/* ----- init segment ------------------------------------------------------ */

int plozz_remux_init_segment(plozz_remux_session *s, uint8_t **out_data, int *out_len) {
    if (!s || !out_data || !out_len) return 0;
    *out_data = NULL;
    *out_len = 0;
    if (s->segment_count <= 0) return 0;

    /* Derive the shared CMAF init (ftyp + moov) from a real fragment of the first
     * segment. With delay_moov the moov is only complete — EAC3 dec3 box, DoVi
     * dvcC/dvvC — after packets are muxed, so a packet-less write_header can't
     * produce a usable init. The empty_moov moov describes the tracks only (no
     * samples), so it is identical for every segment and valid as the EXT-X-MAP. */
    uint8_t *full = NULL;
    int full_len = 0;
    if (!mux_segment_full(s, 0, &full, &full_len)) return 0;

    int media_off = media_offset_after_init(full, full_len);
    if (media_off <= 0) { free(full); return 0; } /* no ftyp+moov prefix → fail */

    uint8_t *copy = (uint8_t *)malloc((size_t)media_off);
    if (!copy) { free(full); return 0; }
    memcpy(copy, full, (size_t)media_off);
    free(full);

    *out_data = copy;
    *out_len = media_off;
    remux_log(0, "remux: init segment %d bytes", media_off);
    return 1;
}

/* ----- media segment ----------------------------------------------------- */

/*
 * Scan top-level ISO-BMFF boxes and return the offset of the first `moof` (or
 * `styp`) box — i.e. the start of the media data, past any leading ftyp + moov.
 * Returns the input length if no such box is found (degrade to whole buffer).
 */
static int media_offset_after_init(const uint8_t *buf, int len) {
    int off = 0;
    while (off + 8 <= len) {
        uint32_t size = ((uint32_t)buf[off] << 24) | ((uint32_t)buf[off + 1] << 16)
                      | ((uint32_t)buf[off + 2] << 8) | (uint32_t)buf[off + 3];
        const uint8_t *type = &buf[off + 4];
        if (!memcmp(type, "styp", 4) || !memcmp(type, "moof", 4)) {
            return off;
        }
        if (size < 8) break;             /* malformed / 64-bit size; bail */
        if (off + (int)size > len) break;
        off += (int)size;
    }
    return 0; /* no init prefix found: emit the whole buffer */
}

static int mux_segment_full(plozz_remux_session *s, int index, uint8_t **out_data, int *out_len) {
    if (!s || !out_data || !out_len || index < 0 || index >= s->segment_count) return 0;
    *out_data = NULL;
    *out_len = 0;

    double start_s = s->segments[index].start_seconds;
    double end_s = start_s + s->segments[index].duration_seconds;

    AVStream *vst = s->ic->streams[s->video_index];
    double file_start = (s->ic->start_time != AV_NOPTS_VALUE)
        ? (double)s->ic->start_time / AV_TIME_BASE : 0.0;

    /* CARDINAL SEEK RULE: seek BACKWARD to the source keyframe at/just before the
     * segment start so a `-c copy` segment always begins on an IDR. */
    int64_t seek_ts = (int64_t)((start_s + file_start) / av_q2d(vst->time_base));
    int rc = avformat_seek_file(s->ic, s->video_index, INT64_MIN, seek_ts, seek_ts,
                                AVSEEK_FLAG_BACKWARD);
    if (rc < 0) {
        remux_log(2, "remux: seek failed for segment %d (%d)", index, rc);
        return 0;
    }

    int out_audio_index = -1;
    AVFormatContext *oc = make_output(s, &out_audio_index);
    if (!oc) return 0;
    if (avio_open_dyn_buf(&oc->pb) < 0) { avformat_free_context(oc); return 0; }

    AVDictionary *opts = fmp4_options();
    rc = avformat_write_header(oc, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); av_free(tmp);
        oc->pb = NULL; avformat_free_context(oc);
        return 0;
    }

    AVStream *ast = (s->audio_index >= 0) ? s->ic->streams[s->audio_index] : NULL;
    AVStream *out_v = oc->streams[0];
    AVStream *out_a = (out_audio_index >= 0) ? oc->streams[out_audio_index] : NULL;

    /* Shift output timestamps so the timeline is 0-based (matches the playlist). */
    int64_t v_shift = av_rescale_q((int64_t)(file_start / av_q2d(vst->time_base)),
                                   vst->time_base, vst->time_base);

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        uint8_t *tmp = NULL; avio_close_dyn_buf(oc->pb, &tmp); av_free(tmp);
        oc->pb = NULL; avformat_free_context(oc);
        return 0;
    }

    int wrote_any = 0;
    double end_limit = end_s + file_start;
    /* Defensive monotonic-DTS belt: av_read_frame returns packets in decode order,
     * so DTS must be strictly increasing and PTS >= DTS. GENPTS fixes the common
     * case, but guard here so movenc never receives an unset/backward DTS (which
     * would corrupt the fragment's decode timeline and the frag_discont start). */
    int64_t last_v_dts = AV_NOPTS_VALUE;
    int64_t last_a_dts = AV_NOPTS_VALUE;
    while (av_read_frame(s->ic, pkt) >= 0) {
        int is_video = (pkt->stream_index == s->video_index);
        int is_audio = (ast && pkt->stream_index == s->audio_index);

        if (is_video) {
            double pts_s = (pkt->pts != AV_NOPTS_VALUE)
                ? pkt->pts * av_q2d(vst->time_base) : -1.0;
            /* Stop at the next segment boundary (a keyframe at/after end). */
            if (pts_s >= 0 && pts_s >= end_limit && (pkt->flags & AV_PKT_FLAG_KEY)) {
                av_packet_unref(pkt);
                break;
            }
            av_packet_rescale_ts(pkt, vst->time_base, out_v->time_base);
            if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= v_shift;
            if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= v_shift;
            if (pkt->dts == AV_NOPTS_VALUE) {
                pkt->dts = (last_v_dts == AV_NOPTS_VALUE)
                    ? (pkt->pts != AV_NOPTS_VALUE ? pkt->pts : 0) : last_v_dts + 1;
            }
            if (last_v_dts != AV_NOPTS_VALUE && pkt->dts <= last_v_dts) {
                pkt->dts = last_v_dts + 1;
            }
            last_v_dts = pkt->dts;
            if (pkt->pts == AV_NOPTS_VALUE || pkt->pts < pkt->dts) {
                pkt->pts = pkt->dts;
            }
            pkt->stream_index = out_v->index;
            pkt->pos = -1;
            if (av_interleaved_write_frame(oc, pkt) >= 0) wrote_any = 1;
            av_packet_unref(pkt);
        } else if (is_audio && out_a) {
            double a_pts_s = (pkt->pts != AV_NOPTS_VALUE)
                ? pkt->pts * av_q2d(ast->time_base) : -1.0;
            /* Keep audio within the segment window (allow a little lead-in). */
            if (a_pts_s >= 0 && a_pts_s >= end_limit) {
                av_packet_unref(pkt);
                continue;
            }
            int64_t a_shift = (int64_t)(file_start / av_q2d(ast->time_base));
            av_packet_rescale_ts(pkt, ast->time_base, out_a->time_base);
            if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= av_rescale_q(a_shift, ast->time_base, out_a->time_base);
            if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= av_rescale_q(a_shift, ast->time_base, out_a->time_base);
            if (pkt->dts == AV_NOPTS_VALUE) {
                pkt->dts = (last_a_dts == AV_NOPTS_VALUE)
                    ? (pkt->pts != AV_NOPTS_VALUE ? pkt->pts : 0) : last_a_dts + 1;
            }
            if (last_a_dts != AV_NOPTS_VALUE && pkt->dts <= last_a_dts) {
                pkt->dts = last_a_dts + 1;
            }
            last_a_dts = pkt->dts;
            if (pkt->pts == AV_NOPTS_VALUE || pkt->pts < pkt->dts) {
                pkt->pts = pkt->dts;
            }
            pkt->stream_index = out_a->index;
            pkt->pos = -1;
            av_interleaved_write_frame(oc, pkt);
            av_packet_unref(pkt);
        } else {
            av_packet_unref(pkt);
        }
    }
    av_packet_free(&pkt);

    av_write_trailer(oc);
    avio_flush(oc->pb);

    uint8_t *buf = NULL;
    int len = avio_close_dyn_buf(oc->pb, &buf);
    oc->pb = NULL;
    avformat_free_context(oc);

    if (!wrote_any || len <= 0 || !buf) { av_free(buf); return 0; }

    /* Hand back the FULL ftyp+moov+moof+mdat fragment; callers slice it into the
     * init prefix (ftyp+moov) or media suffix (moof+mdat). Copy out of the av_*
     * allocation so plozz_remux_free_buffer (plain free) releases it uniformly. */
    uint8_t *copy = (uint8_t *)malloc((size_t)len);
    if (!copy) { av_free(buf); return 0; }
    memcpy(copy, buf, (size_t)len);
    av_free(buf);

    *out_data = copy;
    *out_len = len;
    (void)start_s;
    return 1;
}

int plozz_remux_media_segment(plozz_remux_session *s, int index, uint8_t **out_data, int *out_len) {
    if (!s || !out_data || !out_len || index < 0 || index >= s->segment_count) return 0;
    *out_data = NULL;
    *out_len = 0;

    uint8_t *full = NULL;
    int full_len = 0;
    if (!mux_segment_full(s, index, &full, &full_len)) return 0;

    /* Strip the leading ftyp + moov so the media segment is moof+mdat referencing
     * the shared EXT-X-MAP init. */
    int media_off = media_offset_after_init(full, full_len);
    int media_len = full_len - media_off;
    if (media_len <= 0) { free(full); return 0; }

    uint8_t *copy = (uint8_t *)malloc((size_t)media_len);
    if (!copy) { free(full); return 0; }
    memcpy(copy, full + media_off, (size_t)media_len);
    free(full);

    *out_data = copy;
    *out_len = media_len;
    remux_log(0, "remux: segment %d -> %d bytes", index, media_len);
    return 1;
}

/* ----- teardown ---------------------------------------------------------- */

void plozz_remux_free_buffer(uint8_t *data) {
    free(data);
}

void plozz_remux_close(plozz_remux_session *s) {
    if (!s) return;
    free(s->segments);
    if (s->ic) {
        /* avformat_close_input frees ic; our custom pb is freed separately. */
        avformat_close_input(&s->ic);
    }
    if (s->avio) {
        /* avio_context_free frees the AVIOContext but not its buffer if we still
         * own it; the buffer pointer may have been reallocated by avio, so free
         * the *current* one. */
        av_freep(&s->avio->buffer);
        avio_context_free(&s->avio);
    } else {
        av_free(s->avio_buf);
    }
    free(s);
}
