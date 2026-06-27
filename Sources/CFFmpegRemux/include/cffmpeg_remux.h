/*
 * cffmpeg_remux — a deliberately thin libavformat shim for Plozz's cue-driven
 * local remux. It demuxes an MKV that is read on the fly through Swift-supplied
 * range callbacks (no temp files) and re-muxes selected GOPs to fragmented MP4
 * (CMAF) with `-c copy` only — NO transcode — preserving single-layer Dolby
 * Vision (dvcC/dvvC via the copied DOVI configuration record, sample entry
 * tagged dvh1) and E-AC-3 / AC-3 (dec3 box, Atmos JOC bitstream untouched).
 *
 * The Swift layer owns cue parsing, segment-boundary math, the HLS playlist and
 * the localhost server; this shim only turns "give me bytes for [start,end)" and
 * "give me the init segment" into valid CMAF, which is the one job that genuinely
 * needs FFmpeg. Keeping it C-side means FFmpeg's macros (AVERROR, MKTAG, …) work
 * natively and the Swift surface stays a handful of POD calls.
 *
 * All returned buffers are malloc'd by FFmpeg/av_malloc and MUST be released with
 * plozz_free(). The handle is single-threaded: serialise calls per remuxer.
 */
#ifndef CFFMPEG_REMUX_H
#define CFFMPEG_REMUX_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlozzRemuxer PlozzRemuxer;

/* Custom IO callbacks, matching libavformat's avio_alloc_context contract.
 * read: fill buf (<= buf_size), return bytes read, 0/AVERROR_EOF at end, <0 on error.
 * seek: whence is SEEK_SET/CUR/END or AVSEEK_SIZE (0x10000) to query total size. */
typedef int     (*PlozzReadCallback)(void *opaque, uint8_t *buf, int buf_size);
typedef int64_t (*PlozzSeekCallback)(void *opaque, int64_t offset, int whence);

#define PLOZZ_REMUX_OK 0

/* Allocate an empty handle. Never returns NULL unless out of memory. */
PlozzRemuxer *plozz_remuxer_create(void);

/* Open the MKV through the supplied callbacks and probe its streams.
 * `file_size` (>0) lets the demuxer answer AVSEEK_SIZE cheaply; pass <=0 if
 * unknown. Returns PLOZZ_REMUX_OK or a negative AVERROR. */
int plozz_remuxer_open(PlozzRemuxer *r,
                       PlozzReadCallback read_cb,
                       PlozzSeekCallback seek_cb,
                       void *opaque,
                       int64_t file_size);

/* Container duration in seconds (0 if unknown). */
double plozz_remuxer_duration_seconds(const PlozzRemuxer *r);

/* Selected input stream indices, or -1 if none was mapped. */
int plozz_remuxer_video_stream_index(const PlozzRemuxer *r);
int plozz_remuxer_audio_stream_index(const PlozzRemuxer *r);

/* Produce the CMAF init segment (ftyp + empty moov, with dvh1 + dec3 sample
 * entries). Deterministic, so it matches the prefix of every media segment and
 * can back a single EXT-X-MAP. On success out_buf / out_len are set; free with
 * plozz_free(*out_buf). Returns PLOZZ_REMUX_OK or a negative AVERROR. */
int plozz_remuxer_init_segment(PlozzRemuxer *r, uint8_t **out_buf, int *out_len);

/* Produce one CMAF media segment (styp + moof + mdat …) covering the keyframe
 * range [start_seconds, end_seconds). `sequence` is the 0-based segment index
 * used as the fragment sequence number. The moof's baseMediaDecodeTime is the
 * absolute timeline position, so AVPlayer can request segments in any order
 * (far seeks resolve locally). free with plozz_free(*out_buf). */
int plozz_remuxer_make_segment(PlozzRemuxer *r,
                               int sequence,
                               double start_seconds,
                               double end_seconds,
                               uint8_t **out_buf,
                               int *out_len);

/* Tear down the handle and all FFmpeg state. Safe on NULL. */
void plozz_remuxer_destroy(PlozzRemuxer *r);

/* Free a buffer returned by the *_segment functions. Safe on NULL. */
void plozz_free(void *ptr);

/* Human-readable description of the last failure on this handle (never NULL). */
const char *plozz_remuxer_last_error(const PlozzRemuxer *r);

#ifdef __cplusplus
}
#endif

#endif /* CFFMPEG_REMUX_H */
