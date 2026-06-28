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
 * B7 lazy / windowed progressive index (default OFF; gated by the
 * com.plozz.playback.remuxLazyIndex debug flag). Where the keyframe-SCAN path
 * (above) discovers the WHOLE timeline synchronously at open — O(total segments)
 * up-front seek round-trips, which still stalls launch + resume on a 30–40GB title
 * — the lazy path discovers real keyframe boundaries PROGRESSIVELY so launch pays
 * only for the first window and the rest of the timeline fills in the background
 * (off the watchdog-critical path), bounded and cancellable.
 *
 * Lifecycle (only engages for a no-index, fixed-cadence source; a no-op that
 * returns 0 for an index-built table so DoVi/Cues titles keep their exact VOD form):
 *   1. plozz_remux_lazy_begin — seed the discovered-keyframe list with t=0 and
 *      switch the session into lazy mode. The segment table starts EMPTY (0 ready
 *      segments) until the first extend runs.
 *   2. plozz_remux_lazy_extend — advance the frontier by bounded backward-seek
 *      probes (up to `until_seconds` of timeline OR `max_probes` probes this call,
 *      whichever first) and rebuild the table from the real keyframes found so far.
 *      Resumable: call repeatedly (e.g. from a background thread between on-demand
 *      muxes) to fill the timeline a chunk at a time. While incomplete only the
 *      fully-bracketed (closed) segments are published, so a published EXTINF can
 *      never change (no A/V desync). When the frontier reaches EOF the final
 *      tail-to-duration segment is added and `*out_complete` is set — the table is
 *      then the complete VOD timeline.
 *
 * Must serialise with plozz_remux_media_segment (both drive the single-threaded
 * demuxer): the caller holds one lock across either call.
 */
int plozz_remux_lazy_begin(plozz_remux_session *s);
int plozz_remux_lazy_extend(plozz_remux_session *s, double until_seconds,
                            int max_probes, int *out_ready_segments,
                            int *out_complete, int *out_probes);

/*
 * Enable the cheap Matroska cluster-header keyframe probe for progressive discovery
 * (ported from B6, gated by the caller on com.plozz.playback.remuxLazyIndex). When
 * on, each boundary keyframe's PTS is read from the cluster header (~16KB) instead
 * of av_read_frame'ing the whole keyframe packet (~1.4MB) — ~20-40x fewer bytes per
 * probe, which is the dominant open-latency/scrub cost. Must be called BEFORE
 * plozz_remux_lazy_begin (which snapshots it into the per-session probe context).
 * Self-calibrates against av_read_frame on the first few boundaries and falls back
 * on any mismatch, so output is byte-identical to the proven path.
 */
void plozz_remux_set_keyframe_index_mode(plozz_remux_session *s, int enabled);

/*
 * Pure test shim for the cluster-header parser (no session/I/O): parse buf[0..len)
 * as a Matroska Cluster and write the raw (TimestampScale-unit) timestamp of the
 * first keyframe block of `video_track` to *out_raw. Returns 1 on success, 0 if buf
 * isn't a Cluster or has no qualifying keyframe block in the window. For unit tests.
 */
int plozz_remux_test_parse_cluster_keyframe(const uint8_t *buf, int len,
                                            int64_t video_track, int64_t *out_raw);

/*
 * Telemetry: number of discovery boundaries resolved purely by the cheap cluster-
 * header parse (vs the av_read_frame fallback) so far this session. 0 when keyframe-
 * index mode is off or calibration hasn't engaged. Lets the Swift layer report how
 * much of discovery was served by the cheap path.
 */
int plozz_remux_lazy_header_reads(plozz_remux_session *s);

/*
 * 1 when the open-time segment table is the fixed-cadence fallback (the source has
 * no usable keyframe index) — the only case the keyframe-SCAN and lazy/windowed
 * paths engage. 0 for an index-built (Matroska Cues) table, which is already
 * keyframe-aligned. Lets the Swift layer decide whether to drive lazy discovery.
 */
int plozz_remux_uses_fixed_cadence(plozz_remux_session *s);

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
 * Pure test/diagnostic helper for the B7 PROGRESSIVE planner. Groups the keyframes
 * discovered SO FAR exactly as the lazy rebuild does: when `complete` == 0 only the
 * fully-closed segments are emitted (the still-growing trailing group is withheld so
 * a published EXTINF never changes as more keyframes arrive); when `complete` != 0
 * the final tail to `duration` (or the last keyframe) is included. Same boundary
 * invariants as plozz_remux_plan_segments (every boundary a real keyframe, each
 * duration the true keyframe-to-keyframe span). Returns the number of segments
 * written into out_starts/out_durations (capped at max_out). No session state.
 */
int plozz_remux_plan_segments_progressive(const double *keyframe_times, int count,
                                          double duration, double target_seconds,
                                          int complete, double *out_starts,
                                          double *out_durations, int max_out);

/*
 * CUE FAST-PATH (Track A producer -> B7 consume). Supply the exact keyframe times
 * parsed directly from the container Cues when libav left the title without a usable
 * index. Call BEFORE plozz_remux_set_full_vod_mode: the full-vod engage then builds the
 * segment table from these real boundaries (exact EXTINF, real-keyframe STARTS, every
 * forward-snap resolve pre-seeded to a no-op) instead of the fixed-cadence fallback.
 *  - times:        sorted, ~0-based keyframe times in seconds (count >= 2 to take effect)
 *  - duration:     declared timeline duration (<= 0 -> the session's probed duration)
 *  - byte_offsets: OPTIONAL parallel cluster byte offsets (NULL -> mux backward-seeks by
 *                  time; reserved for a future direct byte-seek optimization)
 * Stores a private copy; pass count < 2 or times == NULL to clear. No-op on NULL session.
 */
void plozz_remux_set_cue_table(plozz_remux_session *s, double duration,
                               const double *times, int count,
                               const int64_t *byte_offsets);

/* 1 if a usable cue table is currently set on the session, else 0. */
int plozz_remux_has_cue_table(plozz_remux_session *s);

/*
 * Enable the B7 FULL-VOD provisional-timeline mode. The playlist publishes the full
 * 0->duration fixed-cadence table (so the entire scrub bar is seekable at open —
 * instant launch + full-timeline seek), but every segment is muxed with FORWARD-
 * snapped contiguous boundaries: segment k starts at the first real keyframe >= k*T
 * (cached from the previous segment's stop keyframe, or resolved with one bounded
 * GOP read on a random-access seek) and ends at the first keyframe >= (k+1)*T. This
 * keeps adjacent segments contiguous and non-overlapping (the anti-desync invariant)
 * while the declared EXTINF stays the provisional cadence. Engages ONLY when the
 * table fell back to fixed cadence (no usable keyframe index); for Cues/DoVi sources
 * it is a no-op and output is byte-identical. Must be called BEFORE the Swift layer
 * reads segment durations. Returns 1 if engaged, 0 if it no-op'd.
 */
int plozz_remux_set_full_vod_mode(plozz_remux_session *s, int enabled);

/*
 * Telemetry: number of segment-start boundaries resolved on-demand (random-access
 * seeks that paid a bounded one-GOP read) so far this session. Sequential playback
 * caches boundaries for free from each mux's stop keyframe, so this counts only the
 * extra reads scrubbing/resume incurred. 0 when full-VOD mode is off.
 */
int plozz_remux_full_vod_resolves(plozz_remux_session *s);

/*
 * Pure test/diagnostic helper for the B7 FULL-VOD forward-snap rule. Given the
 * source's real keyframe times (seconds, 0-based, sorted), lay out the
 * N = ceil(duration/target) provisional fixed-cadence windows the playlist publishes
 * and snap each window's [start,end) to real keyframes: segment k =
 * [first_kf>=k*T, first_kf>=(k+1)*T). Proven CONTIGUOUS (seg k end == seg k+1 start)
 * and NON-OVERLAPPING for any keyframe layout, with a degenerate-window (GOP>T) guard
 * that never emits a zero-length segment. Writes up to max_out starts/durations and
 * returns the count. No session state; safe to call from tests.
 */
int plozz_remux_plan_forward_snap(const double *keyframe_times, int count,
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
