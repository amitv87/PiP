/**
 *  Copyright (C) 2024  PiP Project
 *
 *  Stub implementation for testing - platform-specific implementation will replace this
 */

#include "video_encoder.h"
#include <stdlib.h>
#include <string.h>

struct video_encoder_s {
  encoded_frame_callback_t callback;
  void *callback_ctx;
  int width;
  int height;
  int fps;
  int bitrate;
};

video_encoder_t *
video_encoder_init(int width, int height, int fps, int bitrate)
{
  video_encoder_t *enc = calloc(1, sizeof(video_encoder_t));
  if (!enc) {
    return NULL;
  }

  enc->width = width;
  enc->height = height;
  enc->fps = fps;
  enc->bitrate = bitrate;
  enc->callback = NULL;
  enc->callback_ctx = NULL;

  return enc;
}

void
video_encoder_set_callback(video_encoder_t *enc, encoded_frame_callback_t cb, void *ctx)
{
  if (enc) {
    enc->callback = cb;
    enc->callback_ctx = ctx;
  }
}

int
video_encoder_set_keyframe_interval(video_encoder_t *enc, int keyframe_interval_frames)
{
  (void)enc;
  (void)keyframe_interval_frames;
  return 0;
}

int
video_encoder_encode_frame(video_encoder_t *enc, uint8_t *rgba_data, int stride, uint64_t pts)
{
  // Stub - does nothing
  (void)enc;
  (void)rgba_data;
  (void)stride;
  (void)pts;
  return 0;
}

void
video_encoder_destroy(video_encoder_t *enc)
{
  if (enc) {
    free(enc);
  }
}
