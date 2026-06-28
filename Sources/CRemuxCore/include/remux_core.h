/*
 * remux_core.h — Plozz local-remux C core (FFmpeg-free public surface).
 *
 * This is the canonical "localhost HLS origin" remux primitive: it demuxes the
 * ORIGINAL Matroska bytes (delivered lazily over HTTP range reads via the
 * caller-supplied read/seek callbacks), reads the source's real IDR keyframe
 * boundaries (Matroska Cues / libavformat keyframe index), and produces, on
 * demand:
 *
 *   - ONE shared fMP4 init segment (ftyp + moov, empty_moov) — the EXT-X-MAP.
 *   - Each media segment (moof + mdat) by `-c copy` remuxing the source from the
 *     nearest preceding keyframe to the segment boundary. No re-encode: the
 *     Dolby Vision RPU (dvcC/dvvC) and E-AC-3 JOC Atmos (dec3) bitstreams pass
 *     through untouched, and the video sample entry is tagged `dvh1`.
 *
 * The CARDINAL SEEK RULE is enforced internally: a media segment is always
 * (re)muxed from a SOURCE keyframe via avformat_seek_file(... BACKWARD), so a
 * random-access seek by AVPlayer never lands inside a `-c copy` GOP.
 *
 * Deliberately FFmpeg-free in the public header so the Swift module that imports
 * this target never needs the FFmpeg framework headers on its own include path.
 */
#ifndef PLOZZ_REMUX_CORE_H
#define PLOZZ_REMUX_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* whence value the seek callback receives to report the total stream size,
 * instead of performing a seek. Mirrors FFmpeg's AVSEEK_SIZE. */
#define PLOZZ_REMUX_SEEK_SIZE 0x10000

/* Read up to buf_size bytes from the current position into buf.
 * Return the number of bytes read, 0 on EOF, or a negative value on error. */
typedef int (*plozz_remux_read_cb)(void *opaque, uint8_t *buf, int buf_size);

/* Seek to offset (interpreted per `whence`: SEEK_SET/SEEK_CUR/SEEK_END), or, when
 * whence == PLOZZ_REMUX_SEEK_SIZE, return the total byte size without seeking.
 * Return the resulting absolute position (or the size), negative on error. */
typedef int64_t (*plozz_remux_seek_cb)(void *opaque, int64_t offset, int whence);

/* Optional log sink so C-side diagnostics can be surfaced through Swift os_log. */
typedef void (*plozz_remux_log_cb)(void *opaque, int level, const char *message);

typedef struct plozz_remux_session plozz_remux_session;

/*
 * The step of plozz_remux_open that failed, reported in
 * plozz_remux_open_result.error_stage so the caller can surface a precise reason
 * (instead of an opaque "demux failed") when a cold device play can't prepare.
 */
typedef enum {
    PLOZZ_REMUX_STAGE_NONE = 0,             /* success */
    PLOZZ_REMUX_STAGE_ALLOC = 1,            /* avio / format context allocation */
    PLOZZ_REMUX_STAGE_OPEN_INPUT = 2,       /* avformat_open_input (first byte reads) */
    PLOZZ_REMUX_STAGE_FIND_STREAM_INFO = 3, /* avformat_find_stream_info */
    PLOZZ_REMUX_STAGE_NO_VIDEO = 4,         /* no decodable video stream */
    PLOZZ_REMUX_STAGE_EMPTY_SEGMENTS = 5    /* segment table came out empty */
} plozz_remux_stage;

/* One keyframe-aligned segment boundary, in seconds on a 0-based timeline. */
typedef struct {
    double start_seconds;
    double duration_seconds;
} plozz_remux_segment;

/* Result of opening + probing a source. Populated by plozz_remux_open. */
typedef struct {
    int ok;                  /* 1 on success, 0 on failure */
    int video_stream_index;  /* source stream index of the chosen video */
    int audio_stream_index;  /* source stream index of the chosen audio (-1 if none) */
    double duration_seconds;
    int segment_count;
    int width;
    int height;
    double frame_rate;       /* video frames/sec (avg, then r_frame_rate); 0 if unknown */
    int audio_channels;
    char video_codec[32];    /* e.g. "hevc" */
    char video_tag[8];       /* container tag, e.g. "dvh1"/"hvc1" (best-effort) */
    char audio_codec[32];    /* e.g. "eac3" */
    int has_dovi_config;     /* 1 when a Dolby Vision configuration record is present */
    int dovi_profile;        /* Dolby Vision profile (5, 8, 7, ...); 0 if unknown */
    int dovi_level;          /* Dolby Vision level from the dvcC/dvvC record; 0 if unknown */
    int dovi_el_present;     /* 1 when a dual-layer enhancement layer is present (P7) */
    int dovi_bl_compat;      /* dv_bl_signal_compatibility_id (0 = P5 no HDR10 fallback) */
    int error_stage;         /* plozz_remux_stage of the failing step (0 on success) */
    int error_code;          /* libavformat AVERROR from the failing step (0 if n/a) */
} plozz_remux_open_result;

/*
 * Open a source through the supplied callbacks and build the keyframe-aligned
 * segment table. `target_segment_seconds` is the *nominal* segment length; real
 * boundaries snap to source keyframes, so segments are >= this where possible.
 *
 * Returns an opaque session (free with plozz_remux_close) or NULL on failure;
 * `out_result` (may be NULL) receives probe facts either way (`ok` reflects it).
 */
plozz_remux_session *plozz_remux_open(void *opaque,
                                      plozz_remux_read_cb read_cb,
                                      plozz_remux_seek_cb seek_cb,
                                      double target_segment_seconds,
                                      plozz_remux_open_result *out_result);

/* Number of segments in the built table. */
int plozz_remux_segment_count(plozz_remux_session *s);

/*
 * Opt into the B3 Dolby-Vision-level consistency normalization (default OFF).
 *
 * When enabled, the muxer raises a missing/too-low dvcC `dv_level` to the floor
 * implied by the coded resolution + frame rate before each segment's moov is
 * written, so the emitted DoVi configuration record can never advertise a level
 * lower than the picture actually requires. This targets the AVPlayer
 * `CoreMediaErrorDomain -4` (invalid format description) seen on DoVi Profile 5
 * at full 3840x2160 while the same profile at 3840x1600 is accepted. Lowering a
 * level is never performed (that could only ever invalidate a valid stream), so
 * the change is a no-op for sources that already carry a correct level.
 *
 * Callers gate this on the `com.plozz.playback.remuxHev1Mp4` debug flag. Safe to
 * call before generating the init/media segments; ignored when `s` is NULL.
 */
void plozz_remux_set_normalize_dovi_level(plozz_remux_session *s, int enabled);

/*
 * Opt into deriving the real (E-)AC-3 frame sample count from the bitstream
 * (default OFF). When OFF the muxer stamps the historical fixed 1536 samples as
 * the audio frame_size whenever the demuxer leaves it unset. When ON, and the
 * open-time bitstream probe successfully decoded the independent E-AC-3
 * syncframe's `numblkscod` (→ 256/512/768/1536 samples), that true value is used
 * instead, so an Atmos/JOC DD+ stream whose syncframes are not 6 blocks gets a
 * per-frame audio duration that matches real time (eliminating the progressive
 * audio-vs-video desync that a wrong 1536 assumption would accumulate). Falls
 * back to 1536 when the probe couldn't parse a frame. The probe itself always
 * runs and logs the derived value, so the comparison is visible even with the
 * flag OFF.
 *
 * Callers gate this on the `com.plozz.playback.remuxEac3FrameDur` debug flag.
 * Safe to call before generating segments; ignored when `s` is NULL.
 */
void plozz_remux_set_derive_eac3_frame_dur(plozz_remux_session *s, int enabled);

/*
 * Opt into rebuilding the segment table from REAL keyframe boundaries discovered
 * by seek-probing the source (default OFF). When OFF the table built at open is
 * used unchanged: for sources whose container carries a keyframe index (Matroska
 * Cues) that is already keyframe-aligned, but for sources WITHOUT a usable index
 * the open-time table falls back to a FIXED 6s cadence whose declared EXTINF does
 * not match what `-c copy` actually muxes — the per-segment BACKWARD-seek snaps
 * the start to an earlier keyframe and the boundary scan overshoots to the next
 * keyframe, so the real muxed span (~12s median, observed) is ~2x the declared 6s
 * and consecutive segments OVERLAP. AVPlayer advances its clock by the declared
 * EXTINF while each segment carries roughly double that much overlapping media →
 * progressive audio desync + video stutter + cut-outs that compound over time.
 *
 * When ON (and the open-time table is the fixed-cadence fallback, i.e. no usable
 * index), this discovers the file's real keyframe times with a bounded series of
 * cheap BACKWARD seek-probes (the same seek primitive the muxer already uses, so
 * no full-file read), then rebuilds the table on those real boundaries via the
 * exact grouping the keyframe-index path uses — making each segment start AND end
 * on a real IDR with EXTINF == the true keyframe-to-keyframe span (no overlap).
 * A no-op when the table was already keyframe-index-built or the source has no
 * duration. Must be called AFTER plozz_remux_open and BEFORE reading the segment
 * count / generating segments, since it can change segment_count.
 *
 * Callers gate this on the `com.plozz.playback.remuxKeyframeScan` debug flag.
 * Ignored when `s` is NULL or `enabled` is 0.
 */
void plozz_remux_set_keyframe_scan(plozz_remux_session *s, int enabled);

/*
 * Enable keyframe-index (Matroska cluster-header parse) mode for the post-open
 * keyframe-scan. When on, discovery reads each boundary keyframe's PTS out of the
 * cluster/Block header (a few KB) instead of demuxing the whole keyframe packet
 * (~one 4K IDR), cutting open-latency byte cost ~10x on multi-GB no-Cues 4K titles.
 * It self-calibrates the raw->seconds factor against av_read_frame on the first few
 * boundaries and falls back to the proven av_read_frame path on ANY mismatch, so
 * boundaries (and default output) are never corrupted. Must be called BEFORE
 * plozz_remux_set_keyframe_scan. Callers gate this on the
 * `com.plozz.playback.remuxKeyframeIndex` debug flag. Ignored when `s` is NULL.
 */
void plozz_remux_set_keyframe_index_mode(plozz_remux_session *s, int enabled);

/* ----- standalone per-window keyframe probe (for a lazy/windowed indexer) -----
 *
 * The cheap exact keyframe-discovery primitive extracted as a self-contained,
 * stateful probe so a lazy/windowed segment indexer (e.g. an EVENT-playlist server
 * that fills its timeline window-by-window in the background) can resolve ONE real
 * keyframe boundary at a time using only a ~64KB cluster-header read — instead of
 * demuxing a whole ~MB IDR per boundary (the cost that makes background fill pull
 * hundreds of MB and starve playback). It shares the exact self-calibrating /
 * self-falling-back header-parse core used by the full-at-open scan.
 *
 * Lifecycle: create once per open session, call _next repeatedly to walk boundaries
 * forward (each call advances from the previous boundary), free at the end. The probe
 * borrows the session's demuxer + byte-range reader; do not run it concurrently with
 * the muxer on the same session (single demux cursor). Bytes read are counted into
 * the session so the caller can budget/telemeter via its own bytes accounting.
 */
typedef struct plozz_remux_kf_probe plozz_remux_kf_probe;

/*
 * Create a keyframe probe bound to an open session. `enable_header_parse` selects the
 * ~64KB cluster-header path (self-calibrates against av_read_frame on the first few
 * boundaries, then engages; falls back per-boundary on any uncertainty). When 0, every
 * boundary uses the authoritative av_read_frame path (correct but ~MB/probe). Returns
 * NULL on failure (no video stream / OOM). Free with plozz_remux_kf_probe_free.
 */
plozz_remux_kf_probe *plozz_remux_kf_probe_create(plozz_remux_session *s,
                                                  int enable_header_parse);

/*
 * Resolve the next real keyframe boundary AFTER `after_seconds` (0-based seconds).
 * Seeks BACKWARD to about `after_seconds + target_gap` and returns the keyframe the
 * demuxer lands on, widening the search forward until it finds a keyframe strictly
 * after `after_seconds` (so regular GOPs cost one seek; sparse keyframes cost a few).
 * On success returns 1 and writes the keyframe PTS (> after_seconds) to *out_pts. On
 * end-of-file / no further keyframe / seek failure returns 0. Cheap once calibrated
 * (~64KB); the caller owns any time/byte budget and cancellation around the loop.
 */
int plozz_remux_kf_probe_next(plozz_remux_kf_probe *ctx, double after_seconds,
                              double target_gap, double *out_pts);

/*
 * Discover every keyframe in the window [start_seconds, end_seconds] by driving
 * plozz_remux_kf_probe_next forward from start_seconds. Writes the strictly
 * increasing keyframe PTS into out_pts (caller-allocated, capacity max_out) and
 * returns the count written. Stops after appending the first keyframe
 * >= end_seconds (inclusive seam, so adjacent windows share a boundary the
 * caller's merge collapses), or when max_out is reached, or at EOF. Pass
 * end_seconds <= 0 to scan until EOF or the cap. The probe ctx carries the
 * self-calibrating header-parse state, so REUSING one ctx across successive
 * windows (e.g. a lazy/windowed background fill) keeps calibration warm; the
 * bounded-parallel scan uses one ctx per slice. Single shared windowed-discovery
 * entry point — both callers route through it so seam/cap semantics never diverge.
 */
int plozz_remux_kf_probe_range(plozz_remux_kf_probe *ctx, double start_seconds,
                               double end_seconds, double target_gap,
                               int max_out, double *out_pts);

/* Telemetry: number of boundaries this probe served purely from a cluster-header
 * read (vs an av_read_frame fallback). 0 when `ctx` is NULL. */
int plozz_remux_kf_probe_header_reads(const plozz_remux_kf_probe *ctx);

/* Release a keyframe probe. Safe on NULL. Does not close the session. */
void plozz_remux_kf_probe_free(plozz_remux_kf_probe *ctx);

/*
 * Install a segment table from an externally discovered + merged keyframe-time array
 * (seconds, 0-based, sorted ascending, kf[0] ~ 0). This is the apply step for the
 * bounded-PARALLEL keyframe scan (com.plozz.playback.remuxParallelScan): a driver
 * discovers disjoint time slices CONCURRENTLY on its own probe sessions/readers (each
 * using plozz_remux_kf_probe_next), merges them into one sorted list, and hands it
 * here to rebuild THIS session's table — collapsing the serialized seek-probe RTTs of
 * the in-process scan into ~N/K wall-clock while keeping the VOD+ENDLIST playlist (so
 * native full-timeline seek is preserved). Boundaries are real keyframes with EXTINF
 * stamped as the true keyframe-to-keyframe span, so the table is in sync by
 * construction even where the supplied list is sparse (sparse => coarser segments,
 * never desync). Only acts when the open-time table is the fixed-cadence fallback;
 * a real keyframe-index table is left untouched. Returns the new segment count, or 0
 * (table unchanged) when fewer than two usable keyframes are supplied or grouping fails.
 * Must be called AFTER plozz_remux_open and BEFORE reading the segment count.
 */
int plozz_remux_apply_keyframes(plozz_remux_session *s, const double *kf, int count);

/*
 * 1 when the open-time segment table is the fixed-cadence fallback (no usable keyframe
 * index) — the case the keyframe-scan / parallel-scan rebuild targets; 0 when the table
 * was built from a real keyframe index (already aligned). Lets a parallel-discovery
 * driver skip its probe-session opens on index titles so they stay byte-identical.
 */
int plozz_remux_used_fixed_cadence(plozz_remux_session *s);

/*
 * Pure test/diagnostic helper: parse a Matroska Cluster at `buf[0..len)` and return,
 * via *out_raw, the raw (TimestampScale-unit) timestamp of the first keyframe block
 * of `video_track` (clusterTimestamp + block relative ts). Returns 1 on success, 0
 * when `buf` does not begin with a Cluster or no qualifying keyframe block fits in
 * the window. Reads only element headers — never frame payloads. No session state.
 */
int plozz_remux_test_parse_cluster_keyframe(const uint8_t *buf, int len,
                                            int64_t video_track, int64_t *out_raw);

/*
 * Pure test/diagnostic helper: locate the Matroska Cluster sync (0x1F43B675) nearest
 * to `anchor` in `buf[0..len)`, preferring the latest sync at or before `anchor`, else
 * the first after it. Returns the byte offset, or -1 if no sync is in the window. This
 * is the resync the header-parse uses to tolerate a cursor that a no-Cues BACKWARD seek
 * left a few bytes past the Cluster header. No session state.
 */
int plozz_remux_test_find_cluster_sync(const uint8_t *buf, int len, int anchor);

/*
 * Pure test/diagnostic helper: group a sorted list of real keyframe times (in
 * seconds, 0-based) into non-overlapping segments of at least `target_seconds`
 * each, snapping every boundary to a real keyframe and stamping each segment's
 * duration as the true keyframe-to-keyframe span (the invariant that keeps the
 * playlist EXTINF equal to the muxed media span). The final tail segment runs to
 * `duration` (or the last keyframe when duration is unknown/<= last keyframe).
 * Writes up to `max_out` segments into `out_starts` / `out_durations` and returns
 * the number written (0 when fewer than two keyframes are supplied). No session
 * state; safe to call from tests.
 */
int plozz_remux_plan_segments(const double *keyframe_times, int count,
                              double duration, double target_seconds,
                              double *out_starts, double *out_durations,
                              int max_out);

/*
 * Pure test/diagnostic helper: build the HYBRID partial-discovery table — a real
 * keyframe-grouped prefix [0 .. last keyframe] followed by a fixed-cadence tail
 * (last keyframe .. duration]. Mirrors the prefix-apply path taken when keyframe-scan
 * discovery hits its budget mid-timeline. Writes up to `max_out` segments and returns
 * the count (0 when fewer than two keyframes are supplied). No session state.
 */
int plozz_remux_test_hybrid_segments(const double *keyframe_times, int count,
                                     double duration, double target_seconds,
                                     double *out_starts, double *out_durations,
                                     int max_out);

/*
 * Pure test/diagnostic helper: parse the first (E-)AC-3 syncframe in `data` and
 * return the PCM sample count it represents (256/512/768/1536), or 0 if no
 * syncword is found or the leading frame is a dependent substream. Pass
 * is_eac3 != 0 for E-AC-3 (reads numblkscod), 0 for AC-3 (always 1536). No
 * session state; safe to call from tests.
 */
int plozz_remux_eac3_frame_samples(const uint8_t *data, int size, int is_eac3);

/* Copy the segment table entry at `index` into `out`. Returns 1 on success. */
int plozz_remux_segment_at(plozz_remux_session *s, int index, plozz_remux_segment *out);

/*
 * Generate the shared fMP4 init segment (ftyp + moov). On success returns 1 and
 * sets *out_data / *out_len; the caller owns *out_data and must release it with
 * plozz_remux_free_buffer.
 */
int plozz_remux_init_segment(plozz_remux_session *s, uint8_t **out_data, int *out_len);

/*
 * Generate the media segment at `index` (moof + mdat), remuxed `-c copy` from the
 * nearest preceding source keyframe. Same ownership contract as the init segment.
 * Returns 1 on success, 0 on failure.
 */
int plozz_remux_media_segment(plozz_remux_session *s, int index, uint8_t **out_data, int *out_len);

/* Release a buffer returned by plozz_remux_init_segment / _media_segment. */
void plozz_remux_free_buffer(uint8_t *data);

/* Tear down a session opened with plozz_remux_open. */
void plozz_remux_close(plozz_remux_session *s);

/* Install (or clear, with cb == NULL) a process-wide log sink. */
void plozz_remux_set_log(plozz_remux_log_cb cb, void *opaque);

#ifdef __cplusplus
}
#endif

#endif /* PLOZZ_REMUX_CORE_H */
