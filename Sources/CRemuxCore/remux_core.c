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
#include <Libavutil/time.h>

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
/*
 * Hard ceiling on seek-probes performed during keyframe-scan discovery. The probe
 * count is the open-latency footprint, and it scales with duration/GOP, so a
 * multi-hour title could otherwise cost a thousand-plus probes. We instead scale
 * the *effective* segment target up on long sources (eff = max(target, dur/CAP))
 * so discovery stays a few-hundred small ranged reads regardless of file length.
 * Boundaries remain real keyframes (correctness intact: EXTINF==span, no overlap);
 * the only effect is coarser — but still byte-bounded — segments on very long files.
 * This is what lets a 30-40 GB remux start fast without reading O(filesize).
 */
#define PLOZZ_MAX_SCAN_SEGMENTS 512
/*
 * Wall-clock budget for the whole keyframe-scan discovery, in microseconds. The
 * probe loop is synchronous (off the MainActor — see FullTimelineVODStreamer's
 * Task.detached open), so on a 30-40 GB title over a slow/stalled network even a
 * bounded probe count could exceed the tvOS open/playback-start watchdog. If the
 * budget is blown, discovery aborts and the caller falls back to the original
 * fixed-cadence table: degraded (the old EXTINF mismatch) but never a hang/crash.
 */
#define PLOZZ_KEYFRAME_SCAN_BUDGET_US (8 * 1000000LL)
/*
 * HARD byte budget for the whole keyframe-scan discovery. A feature-length no-Cues
 * title (e.g. 2.5h 4K → ~1500 fixed-cadence segments) discovered upfront with the
 * av_read_frame probe transfers one keyframe IDR (~1+ MiB) per probe — hundreds of
 * MB before playback, enough to stall/OOM-kill the app during open. Independent of
 * the wall-clock budget (a single slow read can't be caught by a between-probe time
 * check), this caps total discovery transfer: once exceeded, discovery aborts to the
 * fixed-cadence table (playable, possibly desynced) rather than ever crashing. The
 * cheap header-parse path (remuxKeyframeIndex) reads only a few KB/probe, so it stays
 * far under this ceiling; the budget is the safety net for the expensive fallback.
 */
#define PLOZZ_KEYFRAME_SCAN_BYTE_BUDGET (96LL * 1024 * 1024)
/*
 * Keyframe-index (header-parse) mode constants. When enabled (flag
 * com.plozz.playback.remuxKeyframeIndex) discovery reads each boundary keyframe's
 * PTS from the Matroska cluster/Block HEADER instead of av_read_frame'ing the whole
 * keyframe packet — cutting per-probe bytes from ~one 4K IDR (~1.4MB) to a few KB.
 * PLOZZ_KF_HEADER_WINDOW is the small range read at each post-seek position;
 * PLOZZ_KF_CALIB_PROBES is how many boundaries cross-check the header parse against
 * av_read_frame (which also empirically derives the TimestampScale factor) before
 * the cheap path is trusted for the remainder. Any mismatch falls back to the
 * proven av_read_frame path, so correctness can never regress.
 */
#define PLOZZ_KF_HEADER_WINDOW 16384
#define PLOZZ_KF_CALIB_PROBES 4

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

    /* B3: when set, raise a too-low/missing dvcC dv_level to the resolution
     * floor before muxing (gated by the com.plozz.playback.remuxHev1Mp4 flag). */
    int normalize_dovi_level;

    /* Real (E-)AC-3 samples-per-frame parsed from the first audio packet's
     * bitstream at open (0 = couldn't parse). `derive_eac3_frame_dur` (set from
     * the com.plozz.playback.remuxEac3FrameDur flag) selects whether make_output
     * stamps this true value instead of the historical fixed 1536 fallback. */
    int eac3_frame_samples;
    int derive_eac3_frame_dur;

    /* Effective per-segment target (seconds) used to build the table at open,
     * stored so the post-open keyframe-scan rebuild (set_keyframe_scan, gated by
     * com.plozz.playback.remuxKeyframeScan) groups to the same cadence. */
    double target_segment_seconds;

    /* 1 when build_segment_table fell back to fixed cadence (no usable index),
     * so the keyframe-scan rebuild knows it should engage; 0 when the table was
     * built from a real keyframe index (already keyframe-aligned, never rebuilt). */
    int used_fixed_cadence;

    /* 1 when the post-open keyframe-scan should read each boundary keyframe's PTS
     * from the Matroska cluster/Block HEADER (a few KB) instead of av_read_frame'ing
     * the whole keyframe packet (~one IDR). Gated by com.plozz.playback.remuxKeyframeIndex.
     * Self-calibrating + self-validating: falls back to av_read_frame on any mismatch. */
    int keyframe_index_mode;

    /* Monotonic count of payload bytes pulled through the read callbacks (avio +
     * direct header reads). Discovery delta-measures this to enforce a HARD byte
     * budget so a feature-length no-Cues title can never read enough to OOM/stall
     * the open thread — it aborts to the fixed-cadence table (playable) instead. */
    int64_t bytes_read;
};

/* ----- AVIO callback adapters ------------------------------------------- */

static int avio_read_adapter(void *opaque, uint8_t *buf, int buf_size) {
    plozz_remux_session *s = (plozz_remux_session *)opaque;
    int n = s->read_cb(s->opaque, buf, buf_size);
    if (n > 0) s->bytes_read += n;
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
 * Group a sorted list of real keyframe times (seconds, 0-based) into
 * non-overlapping segments of at least `target_seconds` each. Every boundary is
 * one of the supplied keyframe times and each segment's duration is the true
 * keyframe-to-keyframe span, so the declared EXTINF equals what a `-c copy` mux
 * actually produces. The final tail runs to `duration` (or the last keyframe when
 * duration is unknown / <= the last keyframe). Allocates `*out_segs` (caller frees)
 * and returns the segment count, or 0 (with *out_segs left NULL) when fewer than
 * two keyframes are supplied or allocation fails.
 *
 * This is the single grouping implementation shared by the keyframe-INDEX path
 * and the keyframe-SCAN rebuild, and is mirrored exactly by the pure, testable
 * plozz_remux_plan_segments().
 */
static int build_segments_from_keyframes(const double *kf, int kf_count,
                                         double duration, double target_seconds,
                                         plozz_remux_segment **out_segs) {
    if (out_segs) *out_segs = NULL;
    if (!kf || kf_count <= 1 || !out_segs) return 0;
    if (target_seconds < 1.0) target_seconds = 6.0;

    plozz_remux_segment *segs =
        (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)kf_count);
    if (!segs) return 0;

    int count = 0;
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

    if (count <= 0) { free(segs); return 0; }
    *out_segs = segs;
    return count;
}

/*
 * Build a HYBRID segment table for a PARTIAL keyframe discovery (budget hit before
 * the whole timeline was scanned): real-keyframe boundaries for the discovered
 * PREFIX [0 .. last discovered keyframe] so the START of the title — where playback
 * begins — has correct EXTINF==span and is in sync, then fixed-cadence segments for
 * the undiscovered TAIL (last_kf .. duration]. The tail keeps the old EXTINF-vs-span
 * mismatch (possible desync) but it is pushed far past the playhead. This is what
 * lets a feature-length / multi-GB title start FAST (budget-bounded) AND in sync,
 * instead of discarding the discovered prefix and reverting wholesale to fixed
 * cadence. Returns prefix+tail segment count, or 0 on failure (caller then keeps the
 * existing fixed-cadence table).
 */
static int build_hybrid_table(const double *kf, int kf_count, double duration,
                              double target_seconds, plozz_remux_segment **out_segs) {
    if (out_segs) *out_segs = NULL;
    if (!kf || kf_count <= 1 || !out_segs) return 0;
    if (target_seconds < 1.0) target_seconds = 6.0;
    double last_kf = kf[kf_count - 1];
    if (last_kf <= 0.001) return 0;

    /* Prefix: group the discovered keyframes, tail-bounded at last_kf (NOT the file
     * end) so the final prefix segment ends exactly on the last real keyframe. */
    plozz_remux_segment *prefix = NULL;
    int prefix_count = build_segments_from_keyframes(kf, kf_count, last_kf,
                                                     target_seconds, &prefix);
    if (prefix_count <= 0) { free(prefix); return 0; }

    int max_tail = 0;
    if (duration > last_kf + 0.001) {
        max_tail = (int)((duration - last_kf) / target_seconds) + 2;
    }
    long long cap = (long long)prefix_count + (long long)max_tail;
    if (cap > PLOZZ_MAX_SEGMENTS) cap = PLOZZ_MAX_SEGMENTS;
    plozz_remux_segment *segs =
        (plozz_remux_segment *)malloc(sizeof(plozz_remux_segment) * (size_t)cap);
    if (!segs) { free(prefix); return 0; }

    int count = 0;
    for (int i = 0; i < prefix_count && count < cap; i++) segs[count++] = prefix[i];
    free(prefix);

    /* Tail: fixed cadence from the last real keyframe to the file end (each boundary
     * still snaps to a real keyframe at mux time via the BACKWARD seek). */
    double t = last_kf;
    while (t < duration - 0.001 && count < cap) {
        double dur = target_seconds;
        if (t + dur > duration) dur = duration - t;
        segs[count].start_seconds = t;
        segs[count].duration_seconds = dur;
        count++;
        t += target_seconds;
    }

    if (count <= 0) { free(segs); return 0; }
    *out_segs = segs;
    return count;
}

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
        count = build_segments_from_keyframes(kf, kf_count, duration, target_seconds, &segs);
    }

    free(kf);

    /* Fallback: fixed cadence (BACKWARD seek snaps each to a real keyframe). NB:
     * the declared per-segment duration here is the *target*, which does NOT match
     * what `-c copy` muxes when keyframes are sparser/denser than the cadence — the
     * source of the progressive A/V desync on no-index titles. The post-open
     * keyframe-scan rebuild (set_keyframe_scan) replaces this with real boundaries. */
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
        remux_log(1, "remux: no usable index; using %d fixed-cadence segments", count);
    } else {
        s->used_fixed_cadence = 0;
    }

    s->segments = segs;
    s->segment_count = count;
}

/* ===== Matroska/EBML cluster-header keyframe parse (keyframe-index mode) =====
 *
 * These helpers read a keyframe's presentation timestamp out of the Matroska
 * Cluster + (Simple)Block HEADER (Timestamp element + the block's relative ts and
 * keyframe flag) — a few bytes — instead of demuxing the whole keyframe packet.
 * They are pure functions over an in-memory buffer (no I/O), so the parser is
 * unit-tested directly via the plozz_remux_test_parse_cluster_keyframe shim.
 */

/* Length (1..8) of an EBML variable-length integer from its first byte; 0 if invalid. */
static int ebml_vint_length(uint8_t first) {
    for (int i = 0; i < 8; i++) {
        if (first & (0x80 >> i)) return i + 1;
    }
    return 0;
}

/* Read an EBML element ID (marker bits KEPT) from p[0..avail). Returns bytes
 * consumed (1..4) and writes the ID to *out_id, or 0 on insufficient/invalid. */
static int ebml_read_id(const uint8_t *p, int avail, uint32_t *out_id) {
    if (avail < 1) return 0;
    int len = ebml_vint_length(p[0]);
    if (len < 1 || len > 4 || len > avail) return 0;
    uint32_t id = 0;
    for (int i = 0; i < len; i++) id = (id << 8) | p[i];
    *out_id = id;
    return len;
}

/* Read an EBML size/value vint (marker bit STRIPPED) from p[0..avail). Returns
 * bytes consumed (1..8) and writes the value to *out_val, or 0 on
 * insufficient/invalid. *out_unknown (optional) is set when every value bit is 1
 * (the "unknown size" sentinel). */
static int ebml_read_size(const uint8_t *p, int avail, uint64_t *out_val, int *out_unknown) {
    if (avail < 1) return 0;
    int len = ebml_vint_length(p[0]);
    if (len < 1 || len > 8 || len > avail) return 0;
    uint8_t firstmask = (uint8_t)(0xFF >> len);
    uint64_t v = (uint64_t)(p[0] & firstmask);
    int all_ones = (v == (uint64_t)firstmask);
    for (int i = 1; i < len; i++) {
        v = (v << 8) | p[i];
        if (p[i] != 0xFF) all_ones = 0;
    }
    if (out_unknown) *out_unknown = all_ones;
    *out_val = v;
    return len;
}

static uint64_t ebml_read_be_uint(const uint8_t *p, int len) {
    uint64_t v = 0;
    for (int i = 0; i < len; i++) v = (v << 8) | p[i];
    return v;
}

#define MKV_ID_CLUSTER     0x1F43B675u
#define MKV_ID_TIMESTAMP   0xE7u
#define MKV_ID_SIMPLEBLOCK 0xA3u
#define MKV_ID_BLOCKGROUP  0xA0u
#define MKV_ID_BLOCK       0xA1u
#define MKV_ID_REFBLOCK    0xFBu

/* Parse a (Simple)Block header: track-number vint, 2-byte big-endian signed
 * relative timestamp, 1 flags byte. Returns 1 with *trk/*rel/*keyframe set, else 0.
 * The keyframe flag (0x80) is only meaningful for SimpleBlock; for a plain Block the
 * caller infers keyframe-ness from the absence of a ReferenceBlock sibling. */
static int mkv_block_header(const uint8_t *p, int avail, int64_t *trk, int64_t *rel, int *keyframe) {
    uint64_t t = 0;
    int tc = ebml_read_size(p, avail, &t, NULL); /* track number is an EBML vint */
    if (tc == 0 || tc + 3 > avail) return 0;
    int16_t r = (int16_t)(((uint16_t)p[tc] << 8) | (uint16_t)p[tc + 1]);
    uint8_t flags = p[tc + 2];
    if (trk) *trk = (int64_t)t;
    if (rel) *rel = (int64_t)r;
    if (keyframe) *keyframe = (flags & 0x80) ? 1 : 0;
    return 1;
}

/* A BlockGroup is a keyframe iff it carries a Block with no ReferenceBlock. */
static int mkv_blockgroup_keyframe(const uint8_t *p, int avail, int64_t video_track,
                                   int64_t cluster_ts, int64_t *out_raw) {
    int pos = 0, have_block = 0, has_ref = 0;
    int64_t trk = -1, rel = 0;
    while (pos < avail) {
        uint32_t id = 0;
        int cl = ebml_read_id(p + pos, avail - pos, &id);
        if (cl == 0) break;
        pos += cl;
        uint64_t sz = 0;
        int el = ebml_read_size(p + pos, avail - pos, &sz, NULL);
        if (el == 0) break;
        pos += el;
        int body_avail = avail - pos;
        if (body_avail < 0) break;
        if (id == MKV_ID_BLOCK) {
            int n = (sz <= (uint64_t)body_avail) ? (int)sz : body_avail;
            mkv_block_header(p + pos, n, &trk, &rel, NULL);
            have_block = 1;
        } else if (id == MKV_ID_REFBLOCK) {
            has_ref = 1;
        }
        if (sz > (uint64_t)body_avail) break;
        pos += (int)sz;
    }
    if (have_block && !has_ref && trk == video_track) {
        if (out_raw) *out_raw = cluster_ts + rel;
        return 1;
    }
    return 0;
}

/*
 * Parse a Matroska Cluster at buf[0..len) and return, via *out_raw, the raw
 * (TimestampScale-unit) timestamp of the first KEYFRAME block of `video_track`
 * (clusterTimestamp + block relative ts). Returns 1 on success; 0 when buf does not
 * begin with a Cluster or no qualifying keyframe block is found within the window.
 * Reads only element headers — never frame payloads.
 */
static int mkv_parse_cluster_keyframe(const uint8_t *buf, int len, int64_t video_track,
                                      int64_t *out_raw) {
    if (!buf || len < 2) return 0;
    int pos = 0;
    uint32_t id = 0;
    int c = ebml_read_id(buf + pos, len - pos, &id);
    if (c == 0 || id != MKV_ID_CLUSTER) return 0;
    pos += c;
    uint64_t csize = 0;
    int unknown = 0;
    int sc = ebml_read_size(buf + pos, len - pos, &csize, &unknown);
    if (sc == 0) return 0;
    pos += sc;
    int cluster_end = len;
    if (!unknown && csize <= (uint64_t)(len - pos)) cluster_end = pos + (int)csize;

    int have_ts = 0;
    int64_t cluster_ts = 0;
    while (pos < cluster_end) {
        uint32_t cid = 0;
        int cl = ebml_read_id(buf + pos, cluster_end - pos, &cid);
        if (cl == 0) break;
        pos += cl;
        uint64_t esize = 0;
        int el = ebml_read_size(buf + pos, cluster_end - pos, &esize, NULL);
        if (el == 0) break;
        pos += el;
        int body_avail = cluster_end - pos;
        if (body_avail < 0) break;
        const uint8_t *body = buf + pos;
        if (cid == MKV_ID_TIMESTAMP) {
            if (esize <= 8 && (int)esize <= body_avail) {
                cluster_ts = (int64_t)ebml_read_be_uint(body, (int)esize);
                have_ts = 1;
            }
        } else if (cid == MKV_ID_SIMPLEBLOCK && have_ts) {
            int n = (esize <= (uint64_t)body_avail) ? (int)esize : body_avail;
            int64_t trk = -1, rel = 0, kf = 0;
            if (mkv_block_header(body, n, &trk, &rel, (int *)&kf) && trk == video_track && kf) {
                if (out_raw) *out_raw = cluster_ts + rel;
                return 1;
            }
        } else if (cid == MKV_ID_BLOCKGROUP && have_ts) {
            int n = (esize <= (uint64_t)body_avail) ? (int)esize : body_avail;
            int64_t raw = 0;
            if (mkv_blockgroup_keyframe(body, n, video_track, cluster_ts, &raw)) {
                if (out_raw) *out_raw = raw;
                return 1;
            }
        }
        if (esize > (uint64_t)body_avail) break; /* element body truncated by window */
        pos += (int)esize;
    }
    return 0;
}

/* Test shim: exposes the pure cluster parser for unit tests (see header). */
int plozz_remux_test_parse_cluster_keyframe(const uint8_t *buf, int len,
                                            int64_t video_track, int64_t *out_raw) {
    return mkv_parse_cluster_keyframe(buf, len, video_track, out_raw);
}

/*
 * Read up to `want` bytes at byte `offset` directly via the session callbacks,
 * bypassing the avio buffer so the range reader's small discovery read-ahead
 * applies (a header parse needs only a few KB, not a 1 MiB avio refill). Returns
 * bytes read (>=0). Disturbs the underlying reader position; callers re-sync via
 * the next avformat_seek_file (or an explicit avio_seek before any av_read_frame).
 */
static int read_raw_at(plozz_remux_session *s, int64_t offset, uint8_t *buf, int want) {
    if (!s || !s->seek_cb || !s->read_cb) return 0;
    if (s->seek_cb(s->opaque, offset, SEEK_SET) < 0) return 0;
    int got = 0;
    while (got < want) {
        int n = s->read_cb(s->opaque, buf + got, want - got);
        if (n <= 0) break;
        got += n;
    }
    s->bytes_read += got;
    return got;
}

/*
 * Read forward from the current demux position (just after a BACKWARD seek) and
 * return the 0-based seconds timestamp of the first VIDEO keyframe encountered,
 * or -1.0 if none is found within a bounded number of packets. A BACKWARD seek
 * lands the video stream on a keyframe, so the first video packet is normally that
 * keyframe; we still prefer an explicit AV_PKT_FLAG_KEY packet and fall back to
 * the first video packet's timestamp. Cheap: reads only a handful of packets, not
 * the whole file.
 */
static double read_seek_keyframe_pts(plozz_remux_session *s, AVPacket *pkt, double file_start) {
    AVStream *vst = s->ic->streams[s->video_index];
    int tries = 0;
    double first_v = -1.0;
    while (tries < 512 && av_read_frame(s->ic, pkt) >= 0) {
        tries++;
        if (pkt->stream_index == s->video_index) {
            int64_t ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
            double t = (ts != AV_NOPTS_VALUE) ? ts * av_q2d(vst->time_base) - file_start : -1.0;
            if (t < 0 && t > -0.001) t = 0.0;
            int is_key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
            av_packet_unref(pkt);
            if (is_key) return (t < 0) ? 0.0 : t;
            if (first_v < 0 && t >= 0) first_v = t;
            continue;
        }
        av_packet_unref(pkt);
    }
    return first_v;
}

/*
 * Self-calibrating keyframe-PTS probe used by discovery when keyframe-index mode is
 * on. State carried across boundaries within one discovery pass.
 */
typedef struct {
    int enabled;        /* header-parse requested (flag on) */
    int calibrated;     /* scale validated across CALIB probes — cheap path trusted */
    int failed;         /* calibration failed — use av_read_frame for the rest */
    double scale;       /* seconds per raw cluster-ts unit (derived empirically) */
    int64_t video_track;/* Matroska track number of the video stream */
    int calib_samples;  /* cross-checks accumulated so far */
    int header_reads;   /* telemetry: boundaries served purely by header-parse */
} kf_index_ctx;

/*
 * Return the 0-based seconds PTS of the keyframe the demuxer just BACKWARD-seeked
 * onto. In keyframe-index mode this parses the cluster header (a few KB) once the
 * empirical raw->seconds `scale` has been validated against av_read_frame on the
 * first PLOZZ_KF_CALIB_PROBES boundaries. Until then — and on any per-boundary
 * uncertainty (unparsable window, non-monotonic/out-of-range value) — it returns the
 * authoritative av_read_frame timestamp, so a wrong header read can never corrupt a
 * boundary. `last` is the previous accepted boundary (monotonic guard).
 */
static double probe_keyframe_pts(plozz_remux_session *s, AVPacket *pkt, double file_start,
                                 double last, kf_index_ctx *ix) {
    if (!ix || !ix->enabled || ix->failed) {
        return read_seek_keyframe_pts(s, pkt, file_start);
    }
    int64_t pos = avio_tell(s->ic->pb);
    int64_t raw = 0;
    int parsed = 0;
    if (pos >= 0) {
        uint8_t hbuf[PLOZZ_KF_HEADER_WINDOW];
        int got = read_raw_at(s, pos, hbuf, PLOZZ_KF_HEADER_WINDOW);
        if (got > 16 && mkv_parse_cluster_keyframe(hbuf, got, ix->video_track, &raw)) parsed = 1;
    }

    if (ix->calibrated) {
        if (parsed) {
            double t = raw * ix->scale - file_start;
            if (t < 0 && t > -0.05) t = 0.0;
            /* Monotonic + sane upper bound guards a stray mis-parse; otherwise the
             * next avformat_seek_file re-syncs the reader (no restore needed). */
            if (t > last + 0.001 && t < last + 600.0) {
                ix->header_reads++;
                return t;
            }
        }
        /* Uncertain: restore reader/avio to `pos` and use av_read_frame this once. */
        if (pos >= 0) {
            s->seek_cb(s->opaque, pos, SEEK_SET);
            avio_seek(s->ic->pb, pos, SEEK_SET);
        }
        return read_seek_keyframe_pts(s, pkt, file_start);
    }

    /* Calibration phase: read_raw_at moved the reader; restore before av_read_frame. */
    if (pos >= 0) {
        s->seek_cb(s->opaque, pos, SEEK_SET);
        avio_seek(s->ic->pb, pos, SEEK_SET);
    }
    double pts_av = read_seek_keyframe_pts(s, pkt, file_start);
    if (parsed && pts_av > 0.05 && raw > 0) {
        double scale = (pts_av + file_start) / (double)raw;
        if (ix->calib_samples == 0) ix->scale = scale;
        double rel = (ix->scale != 0.0) ? (scale - ix->scale) / ix->scale : 1.0;
        if (rel < 0) rel = -rel;
        if (rel < 0.01) {
            ix->calib_samples++;
            if (ix->calib_samples >= PLOZZ_KF_CALIB_PROBES) {
                ix->calibrated = 1;
                remux_log(1, "remux: keyframe-index calibrated scale=%.9g after %d probes "
                          "— header-parse engaged", ix->scale, ix->calib_samples);
            }
        } else {
            ix->failed = 1;
            remux_log(1, "remux: keyframe-index calibration mismatch (%.6g vs %.6g) "
                      "— falling back to av_read_frame", scale, ix->scale);
        }
    } else if (ix->calib_samples == 0) {
        ix->failed = 1;
        remux_log(1, "remux: keyframe-index header parse unavailable — using av_read_frame");
    }
    return pts_av;
}

/*
 * Discover the source's real keyframe times (seconds, 0-based) by seek-probing,
 * for files whose container exposes no usable keyframe index. Starting from t=0,
 * each step BACKWARD-seeks ahead by an ADAPTIVE window and reads the keyframe it
 * lands on; the window tracks the observed keyframe cadence so a regular GOP costs
 * ~1 seek per boundary (vs ceil(gap/target) for a fixed step), and widens on demand
 * when keyframes are sparser than expected. Uses only the cheap byte-addressable
 * BACKWARD seek the muxer already relies on — it reads O(segments) small ranges,
 * NEVER the whole file (the open-latency win over a full av_read_frame-to-EOF scan,
 * which transfers every byte and stalls on multi-GB 4K titles). Allocates `*out_kf`
 * (caller frees) and returns the count (>=1 includes the synthetic t=0 start), or 0
 * on failure. `*out_probes` (optional) receives the number of seek-probes performed.
 */
static int discover_keyframes_by_seek(plozz_remux_session *s, double target_seconds,
                                      double **out_kf, int *out_probes, int *out_timed_out,
                                      int index_mode, int *out_header_reads) {
    if (out_kf) *out_kf = NULL;
    if (out_probes) *out_probes = 0;
    if (out_timed_out) *out_timed_out = 0;
    if (out_header_reads) *out_header_reads = 0;
    if (!s || !out_kf || s->video_index < 0) return 0;
    double duration = s->duration_seconds;
    if (duration <= 0) return 0;
    if (target_seconds < 1.0) target_seconds = 6.0;

    AVStream *vst = s->ic->streams[s->video_index];
    double file_start = (s->ic->start_time != AV_NOPTS_VALUE)
        ? (double)s->ic->start_time / AV_TIME_BASE : 0.0;

    /* Keyframe-index (header-parse) context. video_track is the Matroska track
     * number, which ffmpeg stores in AVStream.id; self-validation catches any
     * mismatch and falls back, so an unexpected id never corrupts boundaries. */
    kf_index_ctx ix;
    memset(&ix, 0, sizeof(ix));
    ix.enabled = index_mode ? 1 : 0;
    ix.video_track = (int64_t)vst->id;
    if (ix.enabled && ix.video_track <= 0) {
        ix.enabled = 0; /* no usable track number; stay on the proven path */
    }

    double *kf = (double *)malloc(sizeof(double) * (size_t)PLOZZ_MAX_SEGMENTS);
    if (!kf) return 0;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) { free(kf); return 0; }

    int n = 0;
    kf[n++] = 0.0;            /* first segment always starts at the timeline origin */
    double last = 0.0;
    /* Adaptive probe window: start at the target cadence, then follow the real
     * keyframe gap so regular GOP structures cost ~1 seek per boundary. Never
     * shrinks below `target` (we want >= target-sized segments; grouping merges
     * any that still come out short). */
    double step = target_seconds;
    int probes = 0;
    int timed_out = 0;
    int64_t deadline = av_gettime_relative() + PLOZZ_KEYFRAME_SCAN_BUDGET_US;
    int64_t bytes_start = s->bytes_read;
    /* Either guard tripping aborts the whole scan to the fixed-cadence fallback. */
    #define KF_BUDGET_BLOWN() \
        (av_gettime_relative() >= deadline || \
         (s->bytes_read - bytes_start) > PLOZZ_KEYFRAME_SCAN_BYTE_BUDGET)

    while (last < duration - 0.001 && n < PLOZZ_MAX_SEGMENTS) {
        /* Wall-clock + byte guard: bound BOTH open latency and total transfer so a
         * feature-length no-Cues title can never block/OOM the open thread. */
        if (KF_BUDGET_BLOWN()) { timed_out = 1; break; }
        double found = -1.0;
        double window = step;
        for (int attempt = 0; attempt < 4096; attempt++) {
            /* Re-check inside the widening loop: a sparse-keyframe boundary can do
             * many seeks+reads, and a single slow network read between outer-loop
             * checks must not let transfer run away past the budget. */
            if (KF_BUDGET_BLOWN()) { timed_out = 1; break; }
            double tgt = last + window;
            int at_end = 0;
            if (tgt >= duration) { tgt = duration - 0.05; at_end = 1; }
            if (tgt <= last + 0.001) break;
            int64_t seek_ts = (int64_t)((tgt + file_start) / av_q2d(vst->time_base));
            probes++;
            if (avformat_seek_file(s->ic, s->video_index, INT64_MIN, seek_ts, seek_ts,
                                   AVSEEK_FLAG_BACKWARD) < 0) {
                break;
            }
            double kpts = probe_keyframe_pts(s, pkt, file_start, last, &ix);
            if (kpts > last + 0.05) { found = kpts; break; }
            if (at_end) break;          /* probed the tail, no further keyframe */
            /* Landed on/<= the previous boundary: keyframes are sparser than the
             * current window, so widen and retry. */
            window += (step > target_seconds) ? step : target_seconds;
        }
        if (timed_out) break;
        if (found < 0.0) break;         /* no more keyframes; grouping tail covers rest */
        double gap = found - last;
        step = (gap > target_seconds) ? gap : target_seconds;
        kf[n++] = found;
        last = found;
    }
    #undef KF_BUDGET_BLOWN

    av_packet_free(&pkt);
    if (out_probes) *out_probes = probes;
    if (out_timed_out) *out_timed_out = timed_out;
    if (out_header_reads) *out_header_reads = ix.header_reads;
    *out_kf = kf;
    return n;
}

/*
 * Replace the segment table with one built on the source's real keyframe boundaries
 * (discovered by seek-probe), so EXTINF matches the muxed span and segments do not
 * overlap. Returns the new segment count, or 0 (table left unchanged) when the scan
 * could not improve on the existing table.
 */
static int build_segment_table_keyframe_scan(plozz_remux_session *s) {
    if (!s) return 0;
    double target = (s->target_segment_seconds < 1.0) ? 6.0 : s->target_segment_seconds;

    /*
     * Bound the probe budget: on a long source, hold #segments (== #probes) to
     * PLOZZ_MAX_SCAN_SEGMENTS by widening the effective target. Discovery then
     * costs a few-hundred small ranged reads even for a 40 GB multi-hour title,
     * instead of one probe per ~target second of runtime. Boundaries are still
     * real keyframes, so EXTINF==span and segments never overlap.
     */
    double eff_target = target;
    if (s->duration_seconds > 0.0) {
        double cap_target = s->duration_seconds / (double)PLOZZ_MAX_SCAN_SEGMENTS;
        if (cap_target > eff_target) eff_target = cap_target;
    }

    double *kf = NULL;
    int probes = 0;
    int timed_out = 0;
    int header_reads = 0;
    int64_t bytes_before = s->bytes_read;
    int kf_count = discover_keyframes_by_seek(s, eff_target, &kf, &probes, &timed_out,
                                              s->keyframe_index_mode, &header_reads);
    int64_t scan_bytes = s->bytes_read - bytes_before;
    if (timed_out) {
        /* Budget hit (slow network, or a feature-length title whose full upfront scan
         * would transfer too much / take too long). DON'T discard what we found:
         * PREFIX-APPLY the real keyframes discovered so far (they cover the START of
         * the title, where playback begins) and fixed-cadence only the undiscovered
         * TAIL. The start plays in sync; residual desync is pushed far past the
         * playhead. The open thread is never blocked/OOM-killed — fast AND in-sync at
         * the start. Falls back to keeping the fixed-cadence table only if even the
         * hybrid build fails (e.g. nothing real discovered). */
        avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);
        plozz_remux_segment *hsegs = NULL;
        int hcount = (kf_count > 1)
            ? build_hybrid_table(kf, kf_count, s->duration_seconds, eff_target, &hsegs)
            : 0;
        if (hcount > 0) {
            double covered = kf[kf_count - 1];
            int old = s->segment_count;
            free(kf);
            free(s->segments);
            s->segments = hsegs;
            s->segment_count = hcount;
            s->used_fixed_cadence = 0;
            remux_log(1, "remux: keyframe-scan budget hit after %d seek-probes, %lld bytes "
                      "(limits %llds / %lldMB) — PREFIX-APPLIED %d real-keyframe segments "
                      "covering %.1fs of %.1fs, fixed-cadence tail (was %d; start in-sync, "
                      "tail may desync)",
                      probes, (long long)scan_bytes,
                      (long long)(PLOZZ_KEYFRAME_SCAN_BUDGET_US / 1000000LL),
                      (long long)(PLOZZ_KEYFRAME_SCAN_BYTE_BUDGET / (1024 * 1024)),
                      hcount, covered, s->duration_seconds, old);
            return hcount;
        }
        free(hsegs);
        free(kf);
        remux_log(1, "remux: keyframe-scan aborted after %d seek-probes "
                  "(%lld bytes read; limits %llds / %lldMB) — keeping fixed-cadence "
                  "table (playable, possibly desynced)",
                  probes, (long long)scan_bytes,
                  (long long)(PLOZZ_KEYFRAME_SCAN_BUDGET_US / 1000000LL),
                  (long long)(PLOZZ_KEYFRAME_SCAN_BYTE_BUDGET / (1024 * 1024)));
        return 0;
    }
    if (kf_count <= 1) { free(kf); return 0; }

    plozz_remux_segment *segs = NULL;
    int count = build_segments_from_keyframes(kf, kf_count, s->duration_seconds, eff_target, &segs);
    free(kf);
    if (count <= 0) { free(segs); return 0; }

    int old = s->segment_count;
    free(s->segments);
    s->segments = segs;
    s->segment_count = count;
    s->used_fixed_cadence = 0;

    /* Rewind so the first segment's mux begins from a clean t=0 BACKWARD seek. */
    avformat_seek_file(s->ic, s->video_index, INT64_MIN, 0, 0, AVSEEK_FLAG_BACKWARD);

    /* Telemetry: seek-probe count + bytes read are the open-latency footprint —
     * O(segments), not O(filesize), capped via eff_target/byte-budget. The
     * coordinator's A/B reads this against the sibling's full-file scan to confirm
     * the startup-speed win on multi-GB 4K titles. header-parsed/probes near 1.0
     * means the cheap cluster-header path served almost every boundary. */
    remux_log(1, "remux: keyframe-scan rebuilt %d segments (was %d fixed-cadence) "
              "from %d keyframes via %d seek-probes, %lld bytes "
              "(target=%.2fs eff=%.2fs) [index-mode=%s header-parsed=%d/%d]",
              count, old, kf_count, probes, (long long)scan_bytes, target, eff_target,
              s->keyframe_index_mode ? "on" : "off", header_reads, probes);
    return count;
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

    s->target_segment_seconds = target_segment_seconds;
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

void plozz_remux_set_keyframe_scan(plozz_remux_session *s, int enabled) {
    if (!s || !enabled) return;
    /* Only engage when the open-time table was the fixed-cadence fallback; a real
     * keyframe-index table is already aligned and must not be disturbed. */
    if (!s->used_fixed_cadence) {
        remux_log(0, "remux: keyframe-scan flag ON but table is index-built; no rebuild");
        return;
    }
    build_segment_table_keyframe_scan(s);
}

void plozz_remux_set_keyframe_index_mode(plozz_remux_session *s, int enabled) {
    if (!s) return;
    /* Pure latency optimization of the keyframe-scan: when on, discovery reads each
     * boundary keyframe's PTS from the cluster header (a few KB) instead of the whole
     * keyframe packet. Set BEFORE plozz_remux_set_keyframe_scan; self-validates and
     * falls back to av_read_frame on any mismatch, so default output is unchanged. */
    s->keyframe_index_mode = enabled ? 1 : 0;
}

int plozz_remux_plan_segments(const double *keyframe_times, int count,
                              double duration, double target_seconds,
                              double *out_starts, double *out_durations,
                              int max_out) {
    if (!keyframe_times || count <= 1 || max_out <= 0) return 0;
    plozz_remux_segment *segs = NULL;
    int n = build_segments_from_keyframes(keyframe_times, count, duration,
                                          target_seconds, &segs);
    if (n <= 0) { free(segs); return 0; }
    if (n > max_out) n = max_out;
    for (int i = 0; i < n; i++) {
        if (out_starts) out_starts[i] = segs[i].start_seconds;
        if (out_durations) out_durations[i] = segs[i].duration_seconds;
    }
    free(segs);
    return n;
}

int plozz_remux_test_hybrid_segments(const double *keyframe_times, int count,
                                     double duration, double target_seconds,
                                     double *out_starts, double *out_durations,
                                     int max_out) {
    if (!keyframe_times || count <= 1 || max_out <= 0) return 0;
    plozz_remux_segment *segs = NULL;
    int n = build_hybrid_table(keyframe_times, count, duration, target_seconds, &segs);
    if (n <= 0) { free(segs); return 0; }
    if (n > max_out) n = max_out;
    for (int i = 0; i < n; i++) {
        if (out_starts) out_starts[i] = segs[i].start_seconds;
        if (out_durations) out_durations[i] = segs[i].duration_seconds;
    }
    free(segs);
    return n;
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
