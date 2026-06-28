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
 * Pure test/diagnostic helper: parse the first (E-)AC-3 syncframe in `data` and
 * return the PCM sample count it represents (256/512/768/1536), or 0 if no
 * syncword is found or the leading frame is a dependent substream. Pass
 * is_eac3 != 0 for E-AC-3 (reads numblkscod), 0 for AC-3 (always 1536). No
 * session state; safe to call from tests.
 */
int plozz_remux_eac3_frame_samples(const uint8_t *data, int size, int is_eac3);

/*
 * Re-segment on REAL keyframes when the container had no usable index (default
 * OFF; callers gate on `com.plozz.playback.remuxKeyframeSegments`). At open,
 * a missing/degenerate Cues index forces a fixed-cadence fallback whose 6 s
 * boundaries do not land on keyframes: the muxer's BACKWARD seek then snaps each
 * segment to the GOP keyframe at/before its start and runs to the next keyframe,
 * so long-GOP streams emit overlapping ~2x-target segments whose true duration
 * differs from the declared EXTINF — desyncing AVPlayer. This call does a
 * one-time keyframe scan (sequential read of the source) and rebuilds the table
 * so each segment is bounded by real keyframes with its declared duration equal
 * to the true keyframe-to-keyframe delta. It is a no-op (returns the current
 * count) when the index was already usable or `s` is NULL, so it is safe and
 * cheap to call unconditionally once the flag is on. Must be called after open
 * and before reading the segment table. By default it uses sparse seek-sampling
 * (O(segment_count) seeks, fast on large files) and only falls back to an
 * exhaustive O(filesize) scan if seek-sampling can't cover the stream; pass
 * force_full_scan != 0 to skip seek-sampling and always do the exhaustive scan
 * (a safety override). Returns the (possibly new) segment count.
 */
int plozz_remux_rescan_keyframe_segments(plozz_remux_session *s, double target_seconds,
                                         int force_full_scan);

/*
 * Pure test/diagnostic helper: group a sorted list of keyframe times (seconds,
 * 0-based) into segments at least `target_seconds` apart, each carrying its true
 * keyframe-to-keyframe duration; the tail runs to `duration` (or the last
 * keyframe if duration <= 0). Writes up to `max_out` segments to `out` and
 * returns the count. No session state; safe to call from tests.
 */
int plozz_remux_plan_segments_from_keyframes(const double *kf, int kf_count,
                                             double target_seconds, double duration,
                                             plozz_remux_segment *out, int max_out);

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
