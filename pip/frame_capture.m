//
//  frame_capture.m
//  PiP
//
//  Platform-specific frame capture implementation for macOS
//  Captures frames from ImageView's renderer and converts to RGBA32
//

#import "frame_capture.h"
#import "imageView.h"
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

struct frame_capture_s {
  frame_capture_callback_t callback;
  void *callback_ctx;
  void *source_id;  // ImageView* cast to void*
  int started;
  int fps;
  dispatch_source_t capture_timer;
  dispatch_queue_t capture_queue;
  uint64_t frame_count;
  uint64_t start_time;
};

static uint64_t get_timestamp_us(void) {
  return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000.0);
}

static void convert_ciimage_to_rgba32(CIImage *image, uint8_t **out_data, int *out_width, int *out_height, int *out_stride) {
  if (!image) {
    *out_data = NULL;
    return;
  }

  CGRect extent = [image extent];
  int width = (int)extent.size.width;
  int height = (int)extent.size.height;

  if (width <= 0 || height <= 0) {
    *out_data = NULL;
    return;
  }

  // Calculate stride (bytes per row, aligned to 16 bytes for efficiency)
  int stride = ((width * 4) + 15) & ~15;
  size_t data_size = stride * height;

  uint8_t *rgba_data = (uint8_t *)calloc(1, data_size);
  if (!rgba_data) {
    *out_data = NULL;
    return;
  }

  // Create a CIContext for rendering
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)colorSpace}];
  if (!context) {
    CGColorSpaceRelease(colorSpace);
    free(rgba_data);
    *out_data = NULL;
    return;
  }

  // Use CIContext's render method directly to bitmap (RGBA8 format)
  [context render:image
        toBitmap:rgba_data
        rowBytes:stride
        bounds:extent
        format:kCIFormatRGBA8
        colorSpace:colorSpace];

  CGColorSpaceRelease(colorSpace);

  *out_data = rgba_data;
  *out_width = width;
  *out_height = height;
  *out_stride = stride;
}

static void capture_frame(frame_capture_t *cap) {
  if (!cap || !cap->started || !cap->callback) {
    if (!cap) NSLog(@"frame_capture: cap is NULL");
    else if (!cap->started) NSLog(@"frame_capture: not started");
    else if (!cap->callback) NSLog(@"frame_capture: no callback set");
    return;
  }

  ImageView *imageView = (__bridge ImageView *)cap->source_id;
  if (!imageView || !imageView.renderer) {
    if (!imageView) NSLog(@"frame_capture: imageView is NULL");
    else if (!imageView.renderer) NSLog(@"frame_capture: renderer is NULL");
    return;
  }

  // Get the current image from the renderer on main thread.
  // Use a bounded wait when called from the capture queue to avoid deadlock
  // during shutdown (main thread stopping capture while capture queue requests main).
  __block CIImage *currentImage = nil;
  if ([NSThread isMainThread]) {
    currentImage = [imageView.renderer currentImage];
  } else {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      currentImage = [imageView.renderer currentImage];
      dispatch_semaphore_signal(sem);
    });
    long wait_result = dispatch_semaphore_wait(
      sem,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC))
    );
    if (wait_result != 0) {
      if (cap->frame_count == 0 || cap->frame_count % 30 == 0) {
        NSLog(@"frame_capture: timed out waiting for main-thread image (frame_count: %llu)", cap->frame_count);
      }
      return;
    }
  }

  if (!currentImage) {
    if (cap->frame_count == 0 || cap->frame_count % 30 == 0) {
      NSLog(@"frame_capture: no current image available (frame_count: %llu)", cap->frame_count);
    }
    return;
  }

  // Convert CIImage to RGBA32
  uint8_t *rgba_data = NULL;
  int width = 0;
  int height = 0;
  int stride = 0;

  convert_ciimage_to_rgba32(currentImage, &rgba_data, &width, &height, &stride);

  if (rgba_data) {
    // Calculate presentation timestamp
    uint64_t pts;
    if (cap->frame_count == 0) {
      cap->start_time = get_timestamp_us();
      pts = 0;
      NSLog(@"frame_capture: captured first frame %dx%d, stride=%d", width, height, stride);
    } else {
      pts = get_timestamp_us() - cap->start_time;
    }

    // Call the callback
    cap->callback(rgba_data, width, height, stride, pts, cap->callback_ctx);

    // Free the allocated data (callback should have copied it if needed)
    free(rgba_data);
    cap->frame_count++;

    if (cap->frame_count % 30 == 0) {
      NSLog(@"frame_capture: captured %llu frames", cap->frame_count);
    }
  } else {
    if (cap->frame_count == 0 || cap->frame_count % 30 == 0) {
      NSLog(@"frame_capture: failed to convert image to RGBA32 (frame_count: %llu)", cap->frame_count);
    }
  }
}

frame_capture_t *
frame_capture_init(void *source_id)
{
  NSLog(@"frame_capture_init: initializing");
  frame_capture_t *cap = calloc(1, sizeof(frame_capture_t));
  if (!cap) {
    NSLog(@"frame_capture_init: failed to allocate memory");
    return NULL;
  }

  cap->source_id = source_id;
  cap->callback = NULL;
  cap->callback_ctx = NULL;
  cap->started = 0;
  cap->fps = 30;
  cap->capture_timer = NULL;
  cap->capture_queue = dispatch_queue_create("com.pip.frame_capture", DISPATCH_QUEUE_SERIAL);
  cap->frame_count = 0;
  cap->start_time = 0;

  NSLog(@"frame_capture_init: initialized successfully");
  return cap;
}

void
frame_capture_set_callback(frame_capture_t *cap, frame_capture_callback_t cb, void *ctx)
{
  if (cap) {
    cap->callback = cb;
    cap->callback_ctx = ctx;
  }
}

int
frame_capture_start(frame_capture_t *cap, int fps)
{
  if (!cap) {
    NSLog(@"frame_capture_start: cap is NULL");
    return -1;
  }

  if (cap->started) {
    NSLog(@"frame_capture_start: already started, stopping first");
    frame_capture_stop(cap);
  }

  ImageView *imageView = (__bridge ImageView *)cap->source_id;
  if (!imageView) {
    NSLog(@"frame_capture_start: imageView is NULL");
    return -1;
  }

  cap->fps = fps > 0 ? fps : 30;
  cap->frame_count = 0;
  cap->start_time = 0;

  NSLog(@"frame_capture_start: starting capture at %d fps", cap->fps);

  // Use dispatch source timer for reliable timing
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cap->capture_queue);
  if (!timer) {
    return -1;
  }

  uint64_t interval_ns = (uint64_t)((1.0 / cap->fps) * NSEC_PER_SEC);
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, interval_ns), interval_ns, 0);

  // Store cap pointer - caller is responsible for keeping it alive while capture is active
  dispatch_source_set_event_handler(timer, ^{
    capture_frame(cap);
  });

  cap->capture_timer = timer;
  dispatch_resume(timer);

  cap->started = 1;
  return 0;
}

void
frame_capture_stop(frame_capture_t *cap)
{
  if (cap && cap->started) {
    // Set started = 0 first so any in-flight capture_frame() will exit early
    cap->started = 0;
    if (cap->capture_timer) {
      NSLog(@"frame_capture_stop: timer: %p", cap->capture_timer);
      dispatch_source_cancel(cap->capture_timer);
      dispatch_sync(cap->capture_queue, ^{});
      cap->capture_timer = NULL;
      NSLog(@"frame_capture_stop: timer released");
    }
  }
}

void
frame_capture_destroy(frame_capture_t *cap)
{
  if (cap) {
    frame_capture_stop(cap);
    // ARC automatically manages dispatch_queue_t, no need to release
    free(cap);
  }
}
