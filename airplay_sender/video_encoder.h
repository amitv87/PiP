/**
 *  Copyright (C) 2024  PiP Project
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 */

#ifndef VIDEO_ENCODER_H
#define VIDEO_ENCODER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct video_encoder_s video_encoder_t;

/**
 * Callback for encoded video frames
 * data: Encoded H.264 data (NAL units in AVCC format)
 * len: Length of encoded data
 * is_keyframe: True if this is a keyframe (IDR)
 * sps: SPS NAL unit (may be NULL if not available)
 * sps_len: Length of SPS
 * pps: PPS NAL unit (may be NULL if not available)
 * pps_len: Length of PPS
 * pts: Presentation timestamp in microseconds
 * ctx: User context
 */
typedef void (*encoded_frame_callback_t)(
    uint8_t *data, int len,
    bool is_keyframe,
    uint8_t *sps, int sps_len,
    uint8_t *pps, int pps_len,
    uint64_t pts,
    void *ctx
);

/**
 * Initialize video encoder
 * width: Frame width in pixels
 * height: Frame height in pixels
 * fps: Target frame rate
 * bitrate: Target bitrate in bits per second
 * Returns encoder instance or NULL on error
 */
video_encoder_t *video_encoder_init(int width, int height, int fps, int bitrate);

/**
 * Set callback for encoded frames
 */
void video_encoder_set_callback(video_encoder_t *enc, encoded_frame_callback_t cb, void *ctx);

/**
 * Set maximum keyframe interval in frames.
 * Example: at 30fps, 30 => ~1 second keyframe cadence.
 * Returns 0 on success, -1 on error.
 */
int video_encoder_set_keyframe_interval(video_encoder_t *enc, int keyframe_interval_frames);

/**
 * Encode a frame
 * rgba_data: RGBA32 format frame data (row-major)
 * stride: Bytes per row (may be larger than width * 4 for alignment)
 * pts: Presentation timestamp in microseconds
 * Returns 0 on success, -1 on error
 */
int video_encoder_encode_frame(video_encoder_t *enc, uint8_t *rgba_data, int stride, uint64_t pts);

/**
 * Clean up video encoder
 */
void video_encoder_destroy(video_encoder_t *enc);

#ifdef __cplusplus
}
#endif

#endif
