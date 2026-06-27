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
