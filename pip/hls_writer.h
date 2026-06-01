/**
 *  hls_writer.h
 *  PiP
 *
 *  HLS playlist generator and segment manager. Maintains a rolling window
 *  of MPEG-TS segments in a ring buffer and generates live HLS .m3u8
 *  playlists on demand. Designed to receive segments from the TS muxer
 *  callback and serve them to the HTTP server.
 */

#ifndef HLS_WRITER_H
#define HLS_WRITER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hls_writer_s hls_writer_t;

/**
 * Create an HLS writer instance.
 * @param max_segments    Maximum number of segments to keep in the ring buffer
 * @param playlist_size   Maximum number of segments to list in the .m3u8 playlist (must be <= max_segments)
 * @param target_duration Target segment duration in seconds (for EXT-X-TARGETDURATION)
 * @return New writer instance, or NULL on allocation failure
 */
hls_writer_t *hls_writer_create(int max_segments, int playlist_size, int target_duration);

/**
 * Destroy a writer instance and free all resources.
 * @param writer The writer instance (may be NULL)
 */
void hls_writer_destroy(hls_writer_t *writer);

/**
 * Add a new segment to the ring buffer. If the buffer is full, the oldest
 * segment is evicted. This function copies the segment data.
 * Thread-safe: can be called from the muxer thread while HTTP serves.
 * @param writer   The writer instance
 * @param data     Segment data (will be copied)
 * @param size     Size of segment data in bytes
 * @param duration Duration of the segment in seconds
 * @param index    Segment index from the TS muxer
 */
void hls_writer_add_segment(hls_writer_t *writer, uint8_t *data, size_t size, double duration, uint64_t index);

/**
 * Generate the current HLS playlist (.m3u8) as a string.
 * Thread-safe. Caller must free the returned string.
 * @param writer The writer instance
 * @return Allocated m3u8 playlist string, or NULL on failure
 */
char *hls_writer_get_playlist(hls_writer_t *writer);

/**
 * Retrieve a segment by its index.
 * Thread-safe. Returns a malloc'd copy of the segment data that the caller must free.
 * @param writer The writer instance
 * @param index  Segment index to retrieve
 * @param data   Output pointer to segment data copy (caller must free)
 * @param size   Output pointer to segment size
 * @return 0 on success, -1 if segment not found
 */
int hls_writer_get_segment(hls_writer_t *writer, uint64_t index, uint8_t **data, size_t *size);

/**
 * Get the number of currently stored segments.
 * @param writer The writer instance
 * @return Number of segments in the ring buffer
 */
int hls_writer_segment_count(hls_writer_t *writer);

#ifdef __cplusplus
}
#endif

#endif /* HLS_WRITER_H */
