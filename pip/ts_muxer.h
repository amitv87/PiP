/**
 *  ts_muxer.h
 *  PiP
 *
 *  MPEG-TS muxer for converting H.264 NAL units into MPEG-TS segments
 *  suitable for HLS streaming. Accepts AVCC-format H.264 data and produces
 *  188-byte MPEG-TS packet streams organized into timed segments.
 *
 *  Thread safety: All calls to a single ts_muxer_t instance must be
 *  serialized (e.g. on a single dispatch queue). The segment callback
 *  must NOT re-enter the muxer.
 */

#ifndef TS_MUXER_H
#define TS_MUXER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ts_muxer_s ts_muxer_t;

/**
 * Callback invoked when a complete MPEG-TS segment is ready.
 * @param context      User-provided context pointer
 * @param segment_data Pointer to the segment data (caller must copy if needed)
 * @param segment_size Size of the segment data in bytes
 * @param duration     Duration of the segment in seconds
 * @param segment_index Zero-based index of this segment
 */
typedef void (*ts_segment_callback_t)(
    void *context,
    uint8_t *segment_data,
    size_t segment_size,
    double duration,
    uint64_t segment_index
);

/**
 * Create a new MPEG-TS muxer instance.
 * @param segment_duration_seconds Target duration for each segment in seconds
 * @param callback                 Callback to invoke when a segment is complete
 * @param context                  User context passed to the callback
 * @return New muxer instance, or NULL on allocation failure
 */
ts_muxer_t *ts_muxer_create(int segment_duration_seconds, ts_segment_callback_t callback, void *context);

/**
 * Destroy a muxer instance and free all associated resources.
 * @param muxer The muxer instance to destroy (may be NULL)
 */
void ts_muxer_destroy(ts_muxer_t *muxer);

/**
 * Push an H.264 access unit (one or more NAL units) to the muxer.
 * The data must be in AVCC format (4-byte big-endian length prefix per NAL).
 * The muxer converts to Annex B format, wraps in PES/TS packets, and
 * accumulates into the current segment.
 * @param muxer       The muxer instance
 * @param nal_data    H.264 NAL data in AVCC format
 * @param nal_size    Size of nal_data in bytes
 * @param pts         Presentation timestamp in microseconds
 * @param is_keyframe Non-zero if this is a keyframe (IDR)
 */
void ts_muxer_push_h264(ts_muxer_t *muxer, uint8_t *nal_data, size_t nal_size, uint64_t pts, int is_keyframe);

/**
 * Push one raw AAC frame (no ADTS header) to the muxer.
 * The muxer wraps it in ADTS + PES + TS packets on the audio PID.
 * @param muxer       The muxer instance
 * @param aac_data    Raw AAC frame bytes
 * @param aac_size    Size of aac_data in bytes
 * @param pts         Presentation timestamp in microseconds
 * @param sample_rate AAC sample rate in Hz
 * @param channels    AAC channel count
 */
void ts_muxer_push_aac(ts_muxer_t *muxer, uint8_t *aac_data, size_t aac_size,
                       uint64_t pts, int sample_rate, int channels);

/**
 * Set the SPS and PPS parameter sets for the H.264 stream.
 * These are stored internally and prepended to keyframes in the TS output.
 * @param muxer    The muxer instance
 * @param sps      SPS NAL unit data (without start code or length prefix)
 * @param sps_size Size of the SPS data in bytes
 * @param pps      PPS NAL unit data (without start code or length prefix)
 * @param pps_size Size of the PPS data in bytes
 */
void ts_muxer_set_sps_pps(ts_muxer_t *muxer, uint8_t *sps, size_t sps_size, uint8_t *pps, size_t pps_size);

/**
 * Flush the current segment, invoking the callback with whatever data
 * has been accumulated so far. Used when stopping the stream.
 * @param muxer The muxer instance
 */
void ts_muxer_flush(ts_muxer_t *muxer);

#ifdef __cplusplus
}
#endif

#endif /* TS_MUXER_H */
