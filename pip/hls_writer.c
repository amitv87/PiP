/**
 *  hls_writer.c
 *  PiP
 *
 *  HLS playlist generator and segment manager implementation.
 *  Uses a fixed-size ring buffer to store MPEG-TS segments and generates
 *  live HLS .m3u8 playlists. All public functions are thread-safe using
 *  a pthread mutex.
 */

#include "hls_writer.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* Ring buffer segment entry                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t  *data;      /* copied segment data (malloc'd) */
    size_t    size;      /* segment size in bytes */
    double    duration;  /* segment duration in seconds */
    uint64_t  index;     /* segment index from the TS muxer */
    int       valid;     /* non-zero if this slot contains data */
} hls_segment_entry_t;

/* ------------------------------------------------------------------ */
/* Writer state structure                                              */
/* ------------------------------------------------------------------ */

struct hls_writer_s {
    /* Ring buffer of segment entries */
    hls_segment_entry_t *segments;
    int max_segments;       /* capacity of the ring buffer */
    int playlist_size;      /* max segments to list in the .m3u8 playlist */
    int write_pos;          /* next slot to write into (circular) */
    int count;              /* number of valid segments currently stored */

    /* HLS playlist parameters */
    int target_duration;    /* EXT-X-TARGETDURATION value in seconds */

    /* Thread safety */
    pthread_mutex_t lock;
};

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

/**
 * Create an HLS writer instance.
 * @param max_segments    Maximum number of segments to keep in the ring buffer
 * @param playlist_size   Maximum number of segments to list in the .m3u8 playlist (must be <= max_segments)
 * @param target_duration Target segment duration in seconds (for EXT-X-TARGETDURATION)
 * @return New writer instance, or NULL on allocation failure
 */
hls_writer_t *
hls_writer_create(int max_segments, int playlist_size, int target_duration)
{
    if (max_segments <= 0 || target_duration <= 0 || playlist_size <= 0) {
        return NULL;
    }

    if (playlist_size > max_segments) {
        playlist_size = max_segments;
    }

    hls_writer_t *writer = calloc(1, sizeof(hls_writer_t));
    if (!writer) {
        return NULL;
    }

    writer->segments = calloc((size_t)max_segments, sizeof(hls_segment_entry_t));
    if (!writer->segments) {
        free(writer);
        return NULL;
    }

    writer->max_segments = max_segments;
    writer->playlist_size = playlist_size;
    writer->write_pos = 0;
    writer->count = 0;
    writer->target_duration = target_duration;

    if (pthread_mutex_init(&writer->lock, NULL) != 0) {
        free(writer->segments);
        free(writer);
        return NULL;
    }

    return writer;
} // end of function hls_writer_create()

/**
 * Destroy a writer instance and free all resources.
 * @param writer The writer instance (may be NULL)
 */
void
hls_writer_destroy(hls_writer_t *writer)
{
    if (!writer) {
        return;
    }

    /* Free all segment data in the ring buffer */
    for (int i = 0; i < writer->max_segments; i++) {
        if (writer->segments[i].valid && writer->segments[i].data) {
            free(writer->segments[i].data);
            writer->segments[i].data = NULL;
        }
    } // end of loop freeing segment data

    free(writer->segments);
    writer->segments = NULL;

    pthread_mutex_destroy(&writer->lock);

    free(writer);
} // end of function hls_writer_destroy()

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
void
hls_writer_add_segment(hls_writer_t *writer, uint8_t *data, size_t size,
                       double duration, uint64_t index)
{
    if (!writer || !data || size == 0) {
        return;
    }

    /* Allocate a copy of the segment data before locking */
    uint8_t *data_copy = malloc(size);
    if (!data_copy) {
        return;
    }
    memcpy(data_copy, data, size);

    pthread_mutex_lock(&writer->lock);

    /* Get the current write slot */
    hls_segment_entry_t *slot = &writer->segments[writer->write_pos];

    /* If the slot is occupied, free the old segment data */
    if (slot->valid && slot->data) {
        free(slot->data);
        slot->data = NULL;
    }

    /* Store the new segment */
    slot->data = data_copy;
    slot->size = size;
    slot->duration = duration;
    slot->index = index;
    slot->valid = 1;

    /* Advance the write position circularly */
    writer->write_pos = (writer->write_pos + 1) % writer->max_segments;

    /* Track the number of valid segments */
    if (writer->count < writer->max_segments) {
        writer->count++;
    }

    pthread_mutex_unlock(&writer->lock);
} // end of function hls_writer_add_segment()

/**
 * Generate the current HLS playlist (.m3u8) as a string.
 * Thread-safe. Caller must free the returned string.
 *
 * Produces a live HLS playlist (no EXT-X-ENDLIST) with format:
 *   #EXTM3U
 *   #EXT-X-VERSION:3
 *   #EXT-X-TARGETDURATION:{target_duration}
 *   #EXT-X-MEDIA-SEQUENCE:{oldest_segment_index}
 *   #EXTINF:{duration},
 *   segment_{index}.ts
 *   ...
 *
 * @param writer The writer instance
 * @return Allocated m3u8 playlist string, or NULL on failure
 */
char *
hls_writer_get_playlist(hls_writer_t *writer)
{
    if (!writer) {
        return NULL;
    }

    pthread_mutex_lock(&writer->lock);

    if (writer->count == 0) {
        pthread_mutex_unlock(&writer->lock);
        return NULL;
    }

    /* Only list the most recent playlist_size segments (not all buffered segments).
       The ring buffer may hold more segments as a safety margin so that recently-
       removed playlist entries are still available for slow clients. */
    int list_count = writer->count;
    if (list_count > writer->playlist_size) {
        list_count = writer->playlist_size;
    }

    /* Estimate buffer size: header ~128 bytes + ~50 bytes per segment entry */
    size_t buf_size = 128 + (size_t)list_count * 50;
    char *playlist = malloc(buf_size);
    if (!playlist) {
        pthread_mutex_unlock(&writer->lock);
        return NULL;
    }

    /* Determine the read position for the OLDEST segment we want to list.
       write_pos points to the next slot to be overwritten (oldest in buffer when full).
       We want the most recent list_count segments, so we start from (write_pos - list_count). */
    int oldest_buf_pos;
    if (writer->count < writer->max_segments) {
        oldest_buf_pos = 0;
    } else {
        oldest_buf_pos = writer->write_pos;
    }
    /* Skip ahead to only list the most recent list_count segments */
    int skip = writer->count - list_count;
    int read_pos = (oldest_buf_pos + skip) % writer->max_segments;

    /* Find the media sequence number (index of the oldest listed segment) */
    uint64_t media_sequence = writer->segments[read_pos].index;

    /* Compute the actual maximum segment duration (rounded up) among listed segments.
       HLS spec requires EXT-X-TARGETDURATION >= ceil(max segment duration). */
    int actual_target = writer->target_duration;
    for (int i = 0; i < list_count; i++) {
        int slot_idx = (read_pos + i) % writer->max_segments;
        hls_segment_entry_t *entry = &writer->segments[slot_idx];
        if (entry->valid) {
            int dur_ceil = (int)(entry->duration + 0.999);
            if (dur_ceil > actual_target) {
                actual_target = dur_ceil;
            }
        }
    } // end of loop computing actual target duration

    /* Write playlist header */
    int offset = snprintf(playlist, buf_size,
                          "#EXTM3U\n"
                          "#EXT-X-VERSION:3\n"
                          "#EXT-X-TARGETDURATION:%d\n"
                          "#EXT-X-MEDIA-SEQUENCE:%llu\n",
                          actual_target,
                          (unsigned long long)media_sequence);

    /* Write segment entries in order from oldest to newest (only the listed subset) */
    for (int i = 0; i < list_count; i++) {
        int slot_idx = (read_pos + i) % writer->max_segments;
        hls_segment_entry_t *entry = &writer->segments[slot_idx];

        if (!entry->valid) {
            continue;
        }

        int remaining = (int)buf_size - offset;
        if (remaining <= 0) {
            break;
        }

        offset += snprintf(playlist + offset, (size_t)remaining,
                           "#EXTINF:%.3f,\n"
                           "segment_%llu.ts\n",
                           entry->duration,
                           (unsigned long long)entry->index);
    } // end of loop writing segment entries

    pthread_mutex_unlock(&writer->lock);

    return playlist;
} // end of function hls_writer_get_playlist()

/**
 * Retrieve a segment by its index.
 * Thread-safe. Returns a malloc'd copy of the segment data so it remains
 * valid even if the ring buffer evicts the original. Caller must free *data.
 * @param writer The writer instance
 * @param index  Segment index to retrieve
 * @param data   Output pointer to segment data copy (caller must free)
 * @param size   Output pointer to segment size
 * @return 0 on success, -1 if segment not found
 */
int
hls_writer_get_segment(hls_writer_t *writer, uint64_t index,
                       uint8_t **data, size_t *size)
{
    if (!writer || !data || !size) {
        return -1;
    }

    pthread_mutex_lock(&writer->lock);

    /* Search the ring buffer for a segment matching the requested index */
    for (int i = 0; i < writer->max_segments; i++) {
        hls_segment_entry_t *entry = &writer->segments[i];
        if (entry->valid && entry->index == index) {
            /* Copy the data while holding the lock to prevent use-after-free
               if the muxer thread evicts this segment concurrently */
            uint8_t *copy = malloc(entry->size);
            if (!copy) {
                pthread_mutex_unlock(&writer->lock);
                return -1;
            }
            memcpy(copy, entry->data, entry->size);
            *data = copy;
            *size = entry->size;
            pthread_mutex_unlock(&writer->lock);
            return 0;
        }
    } // end of loop searching for segment by index

    pthread_mutex_unlock(&writer->lock);
    return -1;
} // end of function hls_writer_get_segment()

/**
 * Get the number of currently stored segments.
 * @param writer The writer instance
 * @return Number of segments in the ring buffer
 */
int
hls_writer_segment_count(hls_writer_t *writer)
{
    if (!writer) {
        return 0;
    }

    pthread_mutex_lock(&writer->lock);
    int count = writer->count;
    pthread_mutex_unlock(&writer->lock);

    return count;
} // end of function hls_writer_segment_count()
