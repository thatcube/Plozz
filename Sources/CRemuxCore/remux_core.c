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
#include <Libavutil/time.h>
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

    /* Set when build_segment_table fell back to fixed cadence because the
     * container index was missing/degenerate (e.g. a single Cue entry). Those
     * 6 s boundaries do NOT line up with real keyframes, so every segment snaps
     * (via the muxer's BACKWARD seek) to the GOP keyframe at/before its start
     * and runs to the next keyframe — long-GOP streams then emit overlapping
     * ~2x-target segments whose true duration ≠ the declared EXTINF, which
     * desyncs AVPlayer. plozz_remux_rescan_keyframe_segments rebuilds the table
     * on real keyframes (found by a one-time scan) only when this is set. */
    int used_fixed_cadence;

    double duration_seconds;

    /* B3: when set, raise a too-low/missing dvcC dv_level to the resolution
     * floor before muxing (gated by the com.plozz.playback.remuxHev1Mp4 flag). */
    int normalize_dovi_level;

    /* Real (E-)AC-3 samples-per-frame parsed from the first audio packet's
     * bitstream at open (0 = couldn't parse). `derive_eac3_frame_dur` (set from
     * the com.plozz.playback.remuxEac3FrameDur flag) selects whether make_output
     * stamps this true value instead of the historical fixed 1536 fallback. */
    int eac3_frame_samples;
    int derive_eac3_frame_dur;
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

/* ----- (E-)AC-3 frame-duration probe ------------------------------------- */

/* Minimal MSB-first bit reader over a byte buffer (reads past the end as 0). */
typedef struct { const uint8_t *p; int size; int bitpos; } eac3_bits;

static unsigned eac3_read_bits(eac3_bits *b, int n) {
    unsigned v = 0;
    for (int i = 0; i < n; i++) {
        int byte = b->bitpos >> 3;
        int bit = 7 - (b->bitpos & 7);
        unsigned one = (byte < b->size) ? ((b->p[byte] >> bit) & 1u) : 0u;
        v = (v << 1) | one;
        b->bitpos++;
    }
    return v;
}

/*
 * Parse the first (E-)AC-3 syncframe in a stream-copied audio packet and return
 * the number of PCM samples it represents, or 0 if it can't be parsed.
 *
 * E-AC-3 carries the block count in the BSI right after the syncword:
 *   syncword(16)=0x0B77, strmtyp(2), substreamid(3), frmsiz(11), fscod(2),
 *   then numblkscod(2) — unless fscod==3 (half sample-rate) which spends 2 bits
 *   on fscod2 and implies 6 blocks. numblkscod 0..3 → {1,2,3,6} blocks × 256
 *   samples. Only the INDEPENDENT substream (strmtyp 0/2) defines the frame's
 *   sample count; a JOC Atmos packet's trailing dependent substreams (strmtyp 1)
 *   overlay the same period and add no samples, so the first syncframe is the
 *   one to read. Plain AC-3 is always 6 blocks (1536 samples).
 */
static int eac3_samples_from_packet(const uint8_t *data, int size, enum AVCodecID id) {
    if (!data || size < 6) return 0;
    int off = -1;
    for (int i = 0; i + 1 < size; i++) {
        if (data[i] == 0x0B && data[i + 1] == 0x77) { off = i; break; }
    }
    if (off < 0) return 0;
    if (id == AV_CODEC_ID_AC3) return 1536; /* AC-3: always 6 blocks */

    eac3_bits b = { data + off + 2, size - off - 2, 0 };
    unsigned strmtyp = eac3_read_bits(&b, 2);
    (void)eac3_read_bits(&b, 3);   /* substreamid */
    (void)eac3_read_bits(&b, 11);  /* frmsiz */
    unsigned fscod = eac3_read_bits(&b, 2);
    unsigned numblkscod;
    if (fscod == 3) { (void)eac3_read_bits(&b, 2); numblkscod = 3; } /* fscod2; half-rate */
    else { numblkscod = eac3_read_bits(&b, 2); }

    if (strmtyp == 1) return 0; /* leading frame is dependent — unexpected, bail */
    static const int blocks[4] = { 1, 2, 3, 6 };
    return blocks[numblkscod & 3] * 256;
}

/* Public pure wrapper (see remux_core.h) so the parser is unit-testable without a
 * live session / network source. */
int plozz_remux_eac3_frame_samples(const uint8_t *data, int size, int is_eac3) {
    return eac3_samples_from_packet(data, size,
                                    is_eac3 ? AV_CODEC_ID_EAC3 : AV_CODEC_ID_AC3);
}

/*
 * One-time probe at open: read forward to the first audio packet and decode its
 * real (E-)AC-3 frame sample count into s->eac3_frame_samples, then rewind so
 * segment muxing starts clean (every segment seeks explicitly anyway). Always
 * logs the derived value vs the 1536 default so the difference is visible even
 * when the use-it flag is OFF.
 */
static void probe_eac3_frame_samples(plozz_remux_session *s) {
    if (!s || s->audio_index < 0) return;
    enum AVCodecID aid = s->ic->streams[s->audio_index]->codecpar->codec_id;
    if (aid != AV_CODEC_ID_EAC3 && aid != AV_CODEC_ID_AC3) return;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    int tries = 0;
    while (tries < 256 && av_read_frame(s->ic, pkt) >= 0) {
        tries++;
        if (pkt->stream_index == s->audio_index && pkt->size > 0) {
            int n = eac3_samples_from_packet(pkt->data, pkt->size, aid);
            if (n > 0) {
                s->eac3_frame_samples = n;
                remux_log(0, "remux: eac3 frame_samples probe=%d (default=1536)%s",
                          n, n != 1536 ? " <-- DIFFERS from 1536" : "");
            } else {
                remux_log(1, "remux: eac3 frame_samples probe failed to parse — using 1536");
            }
            av_packet_unref(pkt);
            break;
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    /* Rewind to the start so the first segment's BACKWARD seek begins from t=0. */
    avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);
}

/* ----- segment table ----------------------------------------------------- */

/*
 * Pure segment planner: given a sorted list of keyframe times (seconds, 0-based)
 * group them into segments whose boundaries are REAL keyframes spaced at least
 * `target_seconds` apart, and whose declared duration is the true keyframe-to-
 * keyframe delta (so playlist EXTINF == muxed content, no overlap). The final
 * tail runs to `duration` (or the last keyframe if duration is unknown). Writes
 * up to `max_out` segments and returns the count. Exposed (see remux_core.h) so
 * the grouping math is unit-testable without a live demux.
 */
int plozz_remux_plan_segments_from_keyframes(const double *kf, int kf_count,
                                             double target_seconds, double duration,
                                             plozz_remux_segment *out, int max_out) {
    if (!kf || kf_count < 2 || !out || max_out <= 0) return 0;
    if (target_seconds < 1.0) target_seconds = 6.0;

    int count = 0;
    double seg_start = kf[0] > 0.001 ? 0.0 : kf[0];
    for (int i = 1; i < kf_count && count < max_out; i++) {
        if (kf[i] - seg_start >= target_seconds - 0.001) {
            out[count].start_seconds = seg_start;
            out[count].duration_seconds = kf[i] - seg_start;
            count++;
            seg_start = kf[i];
        }
    }
    /* Final tail segment up to the end of the file. */
    double tail_end = (duration > seg_start) ? duration : kf[kf_count - 1];
    if (tail_end > seg_start + 0.001 && count < max_out) {
        out[count].start_seconds = seg_start;
        out[count].duration_seconds = tail_end - seg_start;
        count++;
    }
    return count;
}

/*
 * Build the keyframe-aligned segment table from the video stream's libavformat
 * index. For Matroska this index is populated from the Cues at open time, so the
 * boundaries are the file's real IDR keyframes. Falls back to a fixed cadence
 * (relying on a BACKWARD seek to snap to a keyframe) when no index is available;
 * that fallback is flagged so plozz_remux_rescan_keyframe_segments can replace it
 * with a real keyframe scan when the caller opts in.
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
        segs = (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)(kf_count + 1));
        if (segs) {
            int cap = kf_count + 1;
            if (cap > PLOZZ_MAX_SEGMENTS) cap = PLOZZ_MAX_SEGMENTS;
            count = plozz_remux_plan_segments_from_keyframes(kf, kf_count, target_seconds,
                                                             duration, segs, cap);
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
        s->used_fixed_cadence = 1;
        remux_log(1, "remux: no usable index; using %d fixed-cadence segments "
                     "(call rescan to keyframe-align)", count);
    }

    s->segments = segs;
    s->segment_count = count;
}

/*
 * Scan the whole stream once, recording every video keyframe's presentation time
 * (seconds, 0-based). Only packet flags + timestamps are inspected; payloads are
 * unref'd immediately. Rewinds to the start when done. Returns 0 and fills
 * *out_kf / *out_count (caller frees *out_kf) on success, -1 on allocation
 * failure. This is the cost paid (a one-time sequential read) when the container
 * has no usable keyframe index.
 */
static int scan_keyframes(plozz_remux_session *s, double **out_kf, int *out_count) {
    *out_kf = NULL;
    *out_count = 0;
    AVStream *vst = s->ic->streams[s->video_index];
    double start_time = (s->ic->start_time != AV_NOPTS_VALUE)
        ? (double)s->ic->start_time / AV_TIME_BASE : 0.0;

    /* Start from the beginning. */
    avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);

    int cap = 4096, n = 0;
    double *kf = (double *)malloc(sizeof(double) * (size_t)cap);
    if (!kf) return -1;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) { free(kf); return -1; }

    while (av_read_frame(s->ic, pkt) >= 0) {
        if (pkt->stream_index == s->video_index && (pkt->flags & AV_PKT_FLAG_KEY)) {
            int64_t ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
            if (ts != AV_NOPTS_VALUE) {
                double t = ts * av_q2d(vst->time_base) - start_time;
                if (t < 0) t = 0;
                /* Keep the keyframe list strictly increasing: av_read_frame yields
                 * decode order and GENPTS-reconstructed timestamps, so guard
                 * against a duplicate/backward PTS that would make the planner emit
                 * a zero/negative-duration segment or the muxer mis-seek. */
                if (n > 0 && t <= kf[n - 1] + 1e-6) { av_packet_unref(pkt); continue; }
                if (n >= cap) {
                    int ncap = cap * 2;
                    double *nk = (double *)realloc(kf, sizeof(double) * (size_t)ncap);
                    if (!nk) break;  /* keep what we have */
                    kf = nk;
                    cap = ncap;
                }
                if (n < cap) kf[n++] = t;
            }
        }
        av_packet_unref(pkt);
        if (n >= PLOZZ_MAX_SEGMENTS) break;
    }
    av_packet_free(&pkt);

    /* Rewind so the first segment's BACKWARD seek begins from t=0. */
    avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);

    *out_kf = kf;
    *out_count = n;
    return 0;
}

/*
 * Find segment boundaries by SPARSE SEEKING instead of reading the whole file:
 * walk boundary→boundary, each step forward-seeking to (prev + target) and
 * recording the landed video keyframe's PTS. Cost is O(segment_count) sparse
 * seeks (libavformat's generic search jumps by byte position on these no-Cues
 * Matroska files — the same fast path the per-segment muxer seek already uses),
 * not O(filesize), so a 4K title's table builds in seconds instead of after a
 * full multi-GB transfer. Boundaries are exact keyframe PTSs, identical in kind
 * to scan_keyframes, so correctness is unchanged.
 *
 * Hard-bounded so it can never hang or over-read no matter how large the source
 * (must scale to 30–40 GB remux files): a single step's forward read is capped
 * (MAX_FWD_PKTS) and the WHOLE pass is capped by a wall-clock budget
 * (MAX_WALL_SECONDS). If a forward seek degenerates into per-GOP reads on a
 * particular container, the wall-clock cap trips and we return failure rather
 * than quietly transferring the entire file — the caller then keeps the
 * fixed-cadence table (so playback still STARTS) instead of doing an unbounded
 * scan. *out_pkts gets the total packets demuxed (telemetry: proves sparseness).
 *
 * Returns 0 with an increasing list in *out_kf / *out_count (caller frees) when
 * it covered the stream; returns -1 when it couldn't (seek won't advance, or the
 * budget tripped). Rewinds to the start when done.
 */
static int sample_keyframes_by_seek(plozz_remux_session *s, double target_seconds,
                                    double **out_kf, int *out_count, long *out_pkts) {
    *out_kf = NULL;
    *out_count = 0;
    if (out_pkts) *out_pkts = 0;
    if (target_seconds < 1.0) target_seconds = 6.0;
    AVStream *vst = s->ic->streams[s->video_index];
    double file_start = (s->ic->start_time != AV_NOPTS_VALUE)
        ? (double)s->ic->start_time / AV_TIME_BASE : 0.0;
    double duration = s->duration_seconds;

    int cap = 1024, n = 0;
    double *kf = (double *)malloc(sizeof(double) * (size_t)cap);
    if (!kf) return -1;
    kf[n++] = 0.0;  /* the timeline always starts at 0 (muxer seeks back to the first IDR) */

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) { free(kf); return -1; }

    int failed = 0;
    double prev = 0.0;
    long total_pkts = 0;
    int64_t wall_start = av_gettime();
    /* Bound on how many packets a single step may read forward (when a seek
     * undershoots) before we declare the sparse path unreliable — covers one
     * generous GOP, not a runaway read. */
    const int MAX_FWD_PKTS = 1200;
    /* Whole-pass wall-clock ceiling. If sparse seeking can't build the table
     * within this, it isn't actually sparse on this container — bail so a huge
     * file can never block open() or get the app watchdog-killed. */
    const double MAX_WALL_SECONDS = 8.0;

    while (n < PLOZZ_MAX_SEGMENTS) {
        if ((double)(av_gettime() - wall_start) / 1e6 > MAX_WALL_SECONDS) {
            failed = 1;  /* over budget: not sparse on this source */
            break;
        }
        double tgt = prev + target_seconds;
        if (duration > 0 && tgt >= duration - 0.001) break;  /* tail handled by the planner */

        int64_t seek_ts = (int64_t)((tgt + file_start) / av_q2d(vst->time_base));
        /* Forward seek: keyframe with ts in [seek_ts, +inf) — i.e. the first IDR
         * at/after the target. min_ts == ts forces the forward direction. */
        int rc = avformat_seek_file(s->ic, s->video_index, seek_ts, seek_ts, INT64_MAX, 0);

        double k = -1.0;
        int tries = 0;
        while (tries < MAX_FWD_PKTS && av_read_frame(s->ic, pkt) >= 0) {
            tries++;
            total_pkts++;
            if (pkt->stream_index == s->video_index && (pkt->flags & AV_PKT_FLAG_KEY)) {
                int64_t ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
                if (ts != AV_NOPTS_VALUE) {
                    double t = ts * av_q2d(vst->time_base) - file_start;
                    if (t > prev + 0.001) { k = t; av_packet_unref(pkt); break; }
                    /* Landed at/before prev (seek undershot): keep reading forward
                     * to the next keyframe past prev, within the cap. */
                }
            }
            av_packet_unref(pkt);
        }
        if (rc < 0 && k < 0) { failed = 1; break; }
        if (k < 0) {
            /* No keyframe found past prev within the cap. If we're near the end
             * that's just the tail; otherwise the sparse path is unreliable. */
            if (duration > 0 && prev >= duration * 0.95) break;
            failed = 1;
            break;
        }
        if (n >= cap) {
            int ncap = cap * 2;
            double *nk = (double *)realloc(kf, sizeof(double) * (size_t)ncap);
            if (!nk) break;
            kf = nk; cap = ncap;
        }
        kf[n++] = k;
        prev = k;
    }

    av_packet_free(&pkt);
    if (out_pkts) *out_pkts = total_pkts;
    /* Rewind so the first muxed segment's BACKWARD seek begins from t=0. */
    avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);

    /* Reject a run that bailed early (covered far less than the file) so the
     * caller can fall back rather than shipping a short table. */
    if (failed || n < 2 ||
        (duration > 0 && kf[n - 1] < duration * 0.5)) {
        free(kf);
        return -1;
    }

    *out_kf = kf;
    *out_count = n;
    return 0;
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

    /* Decode the true (E-)AC-3 frame sample count now (uses the index-built table
     * above; it reads a few packets then rewinds). Always logged for diagnostics;
     * only consumed by make_output when the derive flag is set. */
    probe_eac3_frame_samples(s);

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
                    out_result->dovi_bl_compat = dovi->dv_bl_signal_compatibility_id;
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

void plozz_remux_set_normalize_dovi_level(plozz_remux_session *s, int enabled) {
    if (!s) return;
    s->normalize_dovi_level = enabled ? 1 : 0;
}

void plozz_remux_set_derive_eac3_frame_dur(plozz_remux_session *s, int enabled) {
    if (!s) return;
    s->derive_eac3_frame_dur = enabled ? 1 : 0;
}

int plozz_remux_rescan_keyframe_segments(plozz_remux_session *s, double target_seconds,
                                         int force_full_scan) {
    if (!s) return 0;
    /* No-op when the container index was usable: those boundaries are already the
     * real keyframes, so a rescan would just be wasted I/O. */
    if (!s->used_fixed_cadence) {
        remux_log(0, "remux: keyframe-scan skipped — index already keyframe-aligned "
                     "(%d segments)", s->segment_count);
        return s->segment_count;
    }
    if (target_seconds < 1.0) target_seconds = 6.0;

    int64_t t0 = av_gettime();
    double *kf = NULL;
    int kf_count = 0;
    long pkts = 0;
    const char *method = "seek-sample";

    /* The exhaustive O(filesize) scan reads the source to EOF. That's fine for a
     * short episode but it MUST NOT run on a large file — at multi-GB it never
     * finishes at open and can get the app watchdog-killed. So only permit the
     * full scan (as a fallback or when forced) for short-duration sources; for
     * anything large, sparse seek-sampling is the only path and if it can't cover
     * the stream we keep the fixed-cadence table (playback still starts) rather
     * than block. ~30 min ≈ a TV episode like Family Guy (works today). */
    const double FULL_SCAN_MAX_DURATION = 1800.0;
    int full_scan_ok = force_full_scan ||
                       (s->duration_seconds > 0 && s->duration_seconds <= FULL_SCAN_MAX_DURATION);

    /* Fast path: sparse seek-sampling builds the boundary table without reading
     * the whole file (O(segment_count) seeks, hard wall-clock bounded). */
    int sampled = 0;
    if (!force_full_scan) {
        sampled = (sample_keyframes_by_seek(s, target_seconds, &kf, &kf_count, &pkts) == 0);
    }

    if (!sampled) {
        free(kf); kf = NULL; kf_count = 0;
        if (!full_scan_ok) {
            /* Large file + sparse path didn't cover it: don't risk an unbounded
             * read. Keep the (imperfect) fixed-cadence table so the title still
             * opens; the log tells us seek-sampling needs work for this source. */
            double el = (double)(av_gettime() - t0) / 1e6;
            remux_log(1, "remux: seek-sample didn't cover %.0fs source in %.2fs "
                         "(%ld pkts); full scan skipped (too large) — keeping %d "
                         "fixed-cadence segments",
                      s->duration_seconds, el, pkts, s->segment_count);
            return s->segment_count;
        }
        method = force_full_scan ? "full-scan(forced)" : "full-scan(fallback)";
        if (scan_keyframes(s, &kf, &kf_count) < 0 || kf_count < 2) {
            free(kf);
            remux_log(1, "remux: keyframe rebuild found %d keyframes; keeping %d "
                         "fixed-cadence segments", kf_count, s->segment_count);
            return s->segment_count;
        }
    }

    int cap = kf_count + 1;
    if (cap > PLOZZ_MAX_SEGMENTS) cap = PLOZZ_MAX_SEGMENTS;
    plozz_remux_segment *segs =
        (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)cap);
    if (!segs) { free(kf); return s->segment_count; }

    int count = plozz_remux_plan_segments_from_keyframes(kf, kf_count, target_seconds,
                                                         s->duration_seconds, segs, cap);
    free(kf);
    if (count <= 0) { free(segs); return s->segment_count; }

    int old = s->segment_count;
    free(s->segments);
    s->segments = segs;
    s->segment_count = count;
    s->used_fixed_cadence = 0;

    double elapsed = (double)(av_gettime() - t0) / 1e6;
    remux_log(0, "remux: keyframe-scan rebuilt %d->%d segments from %d boundaries "
                 "in %.2fs via %s (%ld pkts read; declared durations now match real GOPs)",
              old, count, kf_count, elapsed, method, pkts);
    return count;
}

int plozz_remux_used_fixed_cadence(plozz_remux_session *s) {
    return s ? s->used_fixed_cadence : 0;
}

int plozz_remux_apply_keyframe_boundaries(plozz_remux_session *s, const double *kf,
                                          int kf_count, double target_seconds) {
    if (!s) return 0;
    if (!kf || kf_count < 2) return s->segment_count;
    if (target_seconds < 1.0) target_seconds = 6.0;

    int cap = kf_count + 1;
    if (cap > PLOZZ_MAX_SEGMENTS) cap = PLOZZ_MAX_SEGMENTS;
    plozz_remux_segment *segs =
        (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)cap);
    if (!segs) return s->segment_count;

    int count = plozz_remux_plan_segments_from_keyframes(kf, kf_count, target_seconds,
                                                         s->duration_seconds, segs, cap);
    if (count <= 0) { free(segs); return s->segment_count; }

    int old = s->segment_count;
    free(s->segments);
    s->segments = segs;
    s->segment_count = count;
    s->used_fixed_cadence = 0;

    remux_log(0, "remux: keyframe-index cache applied %d->%d segments from %d cached "
                 "boundaries (no scan — instant exact table)",
              old, count, kf_count);
    return count;
}

int plozz_remux_segment_at(plozz_remux_session *s, int index, plozz_remux_segment *out) {
    if (!s || !out || index < 0 || index >= s->segment_count) return 0;
    *out = s->segments[index];
    return 1;
}

/* ----- muxer helpers ----------------------------------------------------- */

/* HEVC sample-entry fourccs. `dvh1` carries the Dolby Vision signalling; `hvc1`
 * is the plain HEVC entry. Both use out-of-band parameter sets (vs `hev1`/`dvhe`,
 * which carry in-band parameter sets and which AVPlayer/VideoToolbox refuse). */
#define PLOZZ_TAG_DVH1 MKTAG('d', 'v', 'h', '1')
#define PLOZZ_TAG_HVC1 MKTAG('h', 'v', 'c', '1')

/* Locate the Dolby Vision configuration record on a codecpar's coded side data
 * (mutable so callers may normalize it before the moov is written). Returns NULL
 * when the stream carries no DoVi configuration. */
static AVDOVIDecoderConfigurationRecord *find_dovi_conf(AVCodecParameters *par) {
    if (!par) return NULL;
    for (int i = 0; i < par->nb_coded_side_data; i++) {
        if (par->coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF &&
            par->coded_side_data[i].size >= (int)sizeof(AVDOVIDecoderConfigurationRecord)) {
            return (AVDOVIDecoderConfigurationRecord *)par->coded_side_data[i].data;
        }
    }
    return NULL;
}

/* Minimum Dolby Vision level implied by the coded luma sample rate (W x H x fps),
 * using the canonical Dolby tier ladder. Mirrors the Swift fallback estimator so
 * the manifest and the dvcC can never disagree. Returns 0 when inputs are unknown
 * (caller then leaves the source level untouched). */
static int dovi_level_floor(int width, int height, double fps) {
    if (width <= 0 || height <= 0) return 0;
    if (!(fps > 0.0) || !(fps == fps) /* NaN */) {
        return ((long)width * height >= 3840L * 2160) ? 6 : 4;
    }
    double rate = (double)width * (double)height * fps;
    /* (max luma sample rate, level) ascending; 1% tolerance for NTSC rates. */
    static const struct { double ceiling; int level; } ladder[] = {
        { 1280.0 * 720 * 24, 1 },  { 1280.0 * 720 * 30, 2 },
        { 1920.0 * 1080 * 24, 3 }, { 1920.0 * 1080 * 30, 4 },
        { 1920.0 * 1080 * 60, 5 }, { 3840.0 * 2160 * 24, 6 },
        { 3840.0 * 2160 * 30, 7 }, { 3840.0 * 2160 * 48, 8 },
        { 3840.0 * 2160 * 60, 9 }, { 3840.0 * 2160 * 120, 10 },
    };
    for (size_t i = 0; i < sizeof(ladder) / sizeof(ladder[0]); i++) {
        if (rate <= ladder[i].ceiling * 1.01) return ladder[i].level;
    }
    return ladder[sizeof(ladder) / sizeof(ladder[0]) - 1].level;
}

/*
 * Build the output fMP4 context with a video (+ optional audio) stream copied
 * `-c copy` from the source. The video sample entry is tagged `dvh1` when the
 * source carries a Dolby Vision configuration record, otherwise `hvc1` — never
 * the AVPlayer-incompatible `hev1`, so an `hev1`-tagged MP4/MKV HEVC source is
 * retagged to a sample entry VideoToolbox accepts. movenc emits the dvcC/dvvC +
 * dec3 boxes from the copied codecpar side data. Output streams: 0=video, 1=audio.
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
    /* Choose the sample-entry tag from the actual DoVi signalling, and ALWAYS
     * override the source tag (which may be `hev1`/`dvhe`, both rejected by
     * VideoToolbox). DoVi present -> `dvh1`; plain HEVC -> `hvc1`. */
    AVDOVIDecoderConfigurationRecord *dovi = find_dovi_conf(dst_v->codecpar);
    dst_v->codecpar->codec_tag = dovi ? PLOZZ_TAG_DVH1 : PLOZZ_TAG_HVC1;

    /* B3 (flag-gated): raise a missing/too-low dvcC dv_level to the floor the
     * coded resolution requires, so the emitted DoVi configuration record agrees
     * with the picture. Targets the DoVi P5 @ 2160 AVPlayer `-4` rejection while
     * leaving an already-correct level (e.g. the working 3840x1600 case) intact. */
    if (dovi && s->normalize_dovi_level) {
        double fps = av_q2d(src_v->avg_frame_rate);
        if (!(fps > 0.0)) fps = av_q2d(src_v->r_frame_rate);
        int floor = dovi_level_floor(src_v->codecpar->width, src_v->codecpar->height, fps);
        if (floor > 0 && dovi->dv_level < floor) {
            remux_log(1, "remux: DoVi level %d below %dx%d floor %d — clamping",
                      dovi->dv_level, src_v->codecpar->width, src_v->codecpar->height, floor);
            dovi->dv_level = floor;
        }
    }

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
             * for constant-frame (E-)AC-3 it stamps a UNIFORM sample duration =
             * frame_size, so a wrong value drifts the whole audio track. The
             * Matroska demuxer often leaves frame_size 0 ("codec frame size is not
             * set") and historically we filled 1536. AC-3 is always 1536 (6 blocks
             * × 256); E-AC-3 is numblkscod-dependent (256/512/768/1536) and DD+/JOC
             * Atmos frequently uses <6 blocks. When the derive flag is on and the
             * open-time probe parsed the real count, stamp THAT — overriding even a
             * value the demuxer supplied, since that may itself be a wrong 1536 (so
             * the A/B can't silently no-op). Flag off keeps the historical 1536
             * fallback, applied only when the demuxer left it unset. */
            if (dst_a->codecpar->codec_id == AV_CODEC_ID_AC3 ||
                dst_a->codecpar->codec_id == AV_CODEC_ID_EAC3) {
                if (s->derive_eac3_frame_dur && s->eac3_frame_samples > 0) {
                    dst_a->codecpar->frame_size = s->eac3_frame_samples;
                } else if (dst_a->codecpar->frame_size <= 0) {
                    dst_a->codecpar->frame_size = 1536;
                }
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

    /* A/V drift telemetry (always-on, one line per segment). We record the FINAL
     * output timestamps (post rescale + 0-based shift, in out_v/out_a time_base)
     * handed to movenc, so the coordinator's --console capture can tell a
     * TIMELINE-DRIFT bug (A/V start skew drifts segment-to-segment, or the muxed
     * video span disagrees with the declared EXTINF) apart from a THROUGHPUT
     * starvation bug. Captured in raw stream-tick units; converted to seconds
     * after the loop with the (post-header) output time_base. */
    int64_t tel_first_v_pts = AV_NOPTS_VALUE, tel_first_v_dts = AV_NOPTS_VALUE;
    int64_t tel_last_v_pts = AV_NOPTS_VALUE, tel_last_v_dts = AV_NOPTS_VALUE;
    int64_t tel_first_a_pts = AV_NOPTS_VALUE, tel_last_a_pts = AV_NOPTS_VALUE;
    int tel_v_count = 0, tel_a_count = 0;
    /* Sum of the SOURCE audio packet durations (in source audio ticks) so the
     * telemetry can report the demuxer's real per-frame duration — the metric
     * that exposes the (E-)AC-3 CBR-sample-duration bug, which the PTS-based
     * spans above cannot see (PTS comes from the container and is correct even
     * when movenc stamps a wrong uniform frame_size duration). */
    int64_t tel_a_dur_sum = 0;
    int tel_a_dur_n = 0;
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
            if (tel_first_v_pts == AV_NOPTS_VALUE) {
                tel_first_v_pts = pkt->pts;
                tel_first_v_dts = pkt->dts;
            }
            tel_last_v_pts = pkt->pts;
            tel_last_v_dts = pkt->dts;
            tel_v_count++;
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
            /* Capture the demuxer-provided duration BEFORE rescale clobbers it. */
            if (pkt->duration > 0) { tel_a_dur_sum += pkt->duration; tel_a_dur_n++; }
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
            if (tel_first_a_pts == AV_NOPTS_VALUE) tel_first_a_pts = pkt->pts;
            tel_last_a_pts = pkt->pts;
            tel_a_count++;
            av_interleaved_write_frame(oc, pkt);
            av_packet_unref(pkt);
        } else {
            av_packet_unref(pkt);
        }
    }
    av_packet_free(&pkt);

    /* Emit the per-segment A/V drift telemetry before the trailer is written.
     * out_v/out_a time_base were set by movenc in avformat_write_header, so the
     * recorded raw ticks convert cleanly to seconds on the 0-based output
     * timeline AVPlayer sees. `skew` = audio_start − video_start: ideally ~0 and
     * STABLE across segments; a value that grows segment-to-segment is the
     * accumulating audio desync. `vspan` vs `decl` (the declared EXTINF) reveals
     * a video-timeline cut that disagrees with the playlist. */
    {
        double vtb = av_q2d(out_v->time_base);
        double v0 = (tel_first_v_pts != AV_NOPTS_VALUE) ? tel_first_v_pts * vtb : -1.0;
        double v1 = (tel_last_v_pts != AV_NOPTS_VALUE) ? tel_last_v_pts * vtb : -1.0;
        double vdts0 = (tel_first_v_dts != AV_NOPTS_VALUE) ? tel_first_v_dts * vtb : -1.0;
        double vspan = (tel_first_v_pts != AV_NOPTS_VALUE && tel_last_v_pts != AV_NOPTS_VALUE)
            ? (tel_last_v_pts - tel_first_v_pts) * vtb : -1.0;
        double decl = s->segments[index].duration_seconds;
        if (out_a && tel_a_count > 0) {
            double atb = av_q2d(out_a->time_base);
            double a0 = (tel_first_a_pts != AV_NOPTS_VALUE) ? tel_first_a_pts * atb : -1.0;
            double a1 = (tel_last_a_pts != AV_NOPTS_VALUE) ? tel_last_a_pts * atb : -1.0;
            double aspan = (tel_first_a_pts != AV_NOPTS_VALUE && tel_last_a_pts != AV_NOPTS_VALUE)
                ? (tel_last_a_pts - tel_first_a_pts) * atb : -1.0;
            double skew = (a0 >= 0 && v0 >= 0) ? (a0 - v0) : 0.0;
            /* CBR-audio duration check: movenc stamps a UNIFORM sample duration =
             * frame_size for constant-frame (E-)AC-3, so the audio track's real
             * playout length is acov = n * frame_size / sample_rate REGARDLESS of
             * the (correct) PTS span. If frame_size is wrong (1536 stamped for a
             * <6-block E-AC-3 frame) acov diverges from aspan and audio drifts:
             *   acov ~= aspan (+1 frame)  → frame_size correct, no drift
             *   acov ~= k*aspan           → frame_size is k× too big → progressive
             *                               "more-and-more-behind" desync.
             * srcdur = the demuxer's real mean samples/frame (ground truth); fs =
             * what we stamped. srcdur != fs with the flag OFF is the bug fingerprint;
             * with the flag ON they should match. */
            int afs = out_a->codecpar->frame_size;
            int asr = out_a->codecpar->sample_rate;
            double acov = (asr > 0) ? ((double)tel_a_count * (double)afs / (double)asr) : -1.0;
            /* tel_a_dur_sum is in SOURCE audio ticks (captured pre-rescale), so it
             * converts with the source stream's time_base, not the output's. */
            double astb = av_q2d(ast->time_base);
            double srcdur = (tel_a_dur_n > 0 && asr > 0)
                ? ((double)tel_a_dur_sum / (double)tel_a_dur_n) * astb * (double)asr : -1.0;
            remux_log(1,
                "remux-av: seg=%d decl=%.3f v[n=%d 0=%.3f 1=%.3f span=%.3f dts0=%.3f] "
                "a[n=%d 0=%.3f 1=%.3f span=%.3f] skew=%+.3f acov=%.3f fs=%d sr=%d srcdur=%.0f",
                index, decl, tel_v_count, v0, v1, vspan, vdts0,
                tel_a_count, a0, a1, aspan, skew, acov, afs, asr, srcdur);
        } else {
            remux_log(1,
                "remux-av: seg=%d decl=%.3f v[n=%d 0=%.3f 1=%.3f span=%.3f dts0=%.3f] a[none]",
                index, decl, tel_v_count, v0, v1, vspan, vdts0);
        }
    }

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
