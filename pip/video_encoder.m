//
//  video_encoder.m
//  PiP
//
//  Platform-specific video encoder implementation for macOS
//  Uses VideoToolbox for H.264 encoding
//

#import "video_encoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

struct video_encoder_s {
  encoded_frame_callback_t callback;
  void *callback_ctx;
  int width;
  int height;
  int fps;
  int bitrate;
  VTCompressionSessionRef compression_session;
  CMFormatDescriptionRef format_description;
  uint8_t *sps_data;
  int sps_len;
  uint8_t *pps_data;
  int pps_len;
  int frame_count;
};

static void compression_output_callback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer) {
  video_encoder_t *enc = (video_encoder_t *)outputCallbackRefCon;

  if (status != noErr) {
    NSLog(@"video_encoder: compression callback error: %d", (int)status);
    return;
  }

  if (!enc || !enc->callback) {
    if (!enc) NSLog(@"video_encoder: encoder is NULL in callback");
    else if (!enc->callback) NSLog(@"video_encoder: no callback set");
    return;
  }

  if (!sampleBuffer) {
    NSLog(@"video_encoder: sampleBuffer is NULL");
    return;
  }

  // Check if this is a keyframe
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  bool is_keyframe = false;
  if (attachments) {
    CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    if (attachment) {
      CFBooleanRef depends_on_others = (CFBooleanRef)CFDictionaryGetValue(
          attachment, kCMSampleAttachmentKey_DependsOnOthers);
      if (depends_on_others && !CFBooleanGetValue(depends_on_others)) {
        is_keyframe = true;
      }
    }
  }

  // Get presentation timestamp
  CMTime pts_time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  uint64_t pts = (uint64_t)(CMTimeGetSeconds(pts_time) * 1000000.0);

  // Extract SPS/PPS from format description on keyframes
  uint8_t *sps = NULL;
  int sps_len = 0;
  uint8_t *pps = NULL;
  int pps_len = 0;

  if (is_keyframe) {
    // Try to get format description from sample buffer first
    CMFormatDescriptionRef format_desc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format_desc && enc->format_description) {
      format_desc = enc->format_description;
    }

    if (format_desc) {
      // Extract parameter sets from format description
      const uint8_t *parameter_set_pointers[2];
      size_t parameter_set_sizes[2];
      size_t parameter_set_count = 0;

      OSStatus param_status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format_desc, 0, &parameter_set_pointers[0], &parameter_set_sizes[0], &parameter_set_count, NULL);

      if (param_status == noErr && parameter_set_count >= 2) {
        param_status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_desc, 1, &parameter_set_pointers[1], &parameter_set_sizes[1], NULL, NULL);

        if (param_status == noErr) {
          sps_len = (int)parameter_set_sizes[0];
          sps = (uint8_t *)malloc(sps_len);
          if (sps) {
            memcpy(sps, parameter_set_pointers[0], sps_len);
          }

          pps_len = (int)parameter_set_sizes[1];
          pps = (uint8_t *)malloc(pps_len);
          if (pps) {
            memcpy(pps, parameter_set_pointers[1], pps_len);
          }

          if (enc->frame_count == 0 || enc->frame_count % 30 == 0) {
            NSLog(@"video_encoder: extracted SPS len=%d, PPS len=%d", sps_len, pps_len);
          }
        } else {
          if (enc->frame_count == 0 || enc->frame_count % 30 == 0) {
            NSLog(@"video_encoder: failed to get PPS: %d", (int)param_status);
          }
        }
      } else {
        if (enc->frame_count == 0 || enc->frame_count % 30 == 0) {
          NSLog(@"video_encoder: failed to get SPS: %d, count=%zu", (int)param_status, parameter_set_count);
        }
      }
    } else {
      if (enc->frame_count == 0 || enc->frame_count % 30 == 0) {
        NSLog(@"video_encoder: no format description available for keyframe");
      }
    }

    // Store format description for future use
    if (!enc->format_description && format_desc) {
      enc->format_description = (CMFormatDescriptionRef)CFRetain(format_desc);
    }
  }

  // Get encoded data from sample buffer
  CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (!block_buffer) {
    if (sps) free(sps);
    if (pps) free(pps);
    return;
  }

  size_t total_length = CMBlockBufferGetDataLength(block_buffer);
  if (total_length == 0) {
    if (sps) free(sps);
    if (pps) free(pps);
    return;
  }

  char *data_ptr = NULL;
  OSStatus buffer_status = CMBlockBufferGetDataPointer(block_buffer, 0, NULL, NULL, &data_ptr);
  if (buffer_status != noErr || !data_ptr) {
    if (sps) free(sps);
    if (pps) free(pps);
    return;
  }

  // Copy the encoded data
  uint8_t *encoded_data = (uint8_t *)malloc(total_length);
  if (!encoded_data) {
    if (sps) free(sps);
    if (pps) free(pps);
    return;
  }

  memcpy(encoded_data, data_ptr, total_length);

  // Call the callback
  if (enc->frame_count == 0 || (enc->frame_count % 30 == 0)) {
    NSLog(@"video_encoder: encoded frame %d, size=%zu, keyframe=%d, pts=%llu",
          enc->frame_count, total_length, is_keyframe, pts);
  }

  enc->callback(encoded_data, (int)total_length, is_keyframe,
                sps, sps_len, pps, pps_len, pts, enc->callback_ctx);

  // Free allocated data (callback should have copied if needed)
  free(encoded_data);
  if (sps) free(sps);
  if (pps) free(pps);

  enc->frame_count++;
}

int
video_encoder_set_keyframe_interval(video_encoder_t *enc, int keyframe_interval_frames)
{
  if (!enc || !enc->compression_session || keyframe_interval_frames <= 0) {
    return -1;
  }

  CFNumberRef keyframe_interval_num = CFNumberCreate(NULL, kCFNumberIntType, &keyframe_interval_frames);
  if (!keyframe_interval_num) {
    return -1;
  }

  OSStatus status = VTSessionSetProperty(enc->compression_session,
                                         kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                         keyframe_interval_num);
  CFRelease(keyframe_interval_num);
  if (status != noErr) {
    NSLog(@"video_encoder: failed to set MaxKeyFrameInterval: %d", (int)status);
    return -1;
  }

  if (enc->fps > 0) {
    double interval_seconds = (double)keyframe_interval_frames / (double)enc->fps;
    CFNumberRef keyframe_duration_num = CFNumberCreate(NULL, kCFNumberDoubleType, &interval_seconds);
    if (keyframe_duration_num) {
      VTSessionSetProperty(enc->compression_session,
                           kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                           keyframe_duration_num);
      CFRelease(keyframe_duration_num);
    }
  }

  return 0;
}

video_encoder_t *
video_encoder_init(int width, int height, int fps, int bitrate)
{
  NSLog(@"video_encoder_init: initializing %dx%d @ %d fps, bitrate=%d", width, height, fps, bitrate);
  video_encoder_t *enc = calloc(1, sizeof(video_encoder_t));
  if (!enc) {
    NSLog(@"video_encoder_init: failed to allocate memory");
    return NULL;
  }

  enc->width = width;
  enc->height = height;
  enc->fps = fps;
  enc->bitrate = bitrate;
  enc->callback = NULL;
  enc->callback_ctx = NULL;
  enc->compression_session = NULL;
  enc->format_description = NULL;
  enc->sps_data = NULL;
  enc->sps_len = 0;
  enc->pps_data = NULL;
  enc->pps_len = 0;
  enc->frame_count = 0;

  // Create compression session
  OSStatus status = VTCompressionSessionCreate(
      NULL,  // allocator
      width,
      height,
      kCMVideoCodecType_H264,
      NULL,  // encoderSpecification
      NULL,  // sourceImageBufferAttributes
      NULL,  // compressedDataAllocator
      compression_output_callback,
      enc,   // outputCallbackRefCon
      &enc->compression_session);

  if (status != noErr || !enc->compression_session) {
    NSLog(@"video_encoder_init: failed to create compression session: %d", (int)status);
    free(enc);
    return NULL;
  }

  NSLog(@"video_encoder_init: compression session created");

  // Configure for real-time encoding
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

  // Use High profile for better compression efficiency (matches iPad behavior)
  // High profile uses CABAC entropy coding, producing smaller frames
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
  // Alternative: kVTProfileLevel_H264_Baseline_AutoLevel for broader compatibility (but produces larger frames)

  // Set bitrate (average bitrate)
  CFNumberRef bitrate_num = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_AverageBitRate, bitrate_num);
  CFRelease(bitrate_num);

  // Set maximum bitrate limits (125% of average for variable bitrate encoding)
  // DataRateLimits is an array: [bytes_per_second, seconds]
  // AirPlay recommends ~25 Mbps, but we use configurable bitrate
  int max_bitrate_bytes_per_second = (int)(bitrate * 1.25 / 8);  // Convert bits to bytes
  int time_window_seconds = 1;  // 1 second window
  CFNumberRef rate_limit_values[2];
  rate_limit_values[0] = CFNumberCreate(NULL, kCFNumberIntType, &max_bitrate_bytes_per_second);
  rate_limit_values[1] = CFNumberCreate(NULL, kCFNumberIntType, &time_window_seconds);
  CFArrayRef data_rate_limits = CFArrayCreate(NULL, (const void **)rate_limit_values, 2, &kCFTypeArrayCallBacks);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_DataRateLimits, data_rate_limits);
  CFRelease(rate_limit_values[0]);
  CFRelease(rate_limit_values[1]);
  CFRelease(data_rate_limits);

  // Default keyframe interval: every ~2 seconds.
  // StreamManager may override this to 1 second for lower HLS latency.
  int keyframe_interval = fps * 2;
  if (keyframe_interval < 1) keyframe_interval = 1;
  video_encoder_set_keyframe_interval(enc, keyframe_interval);

  // Set expected frame rate
  CFNumberRef fps_num = CFNumberCreate(NULL, kCFNumberIntType, &fps);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_ExpectedFrameRate, fps_num);
  CFRelease(fps_num);

  // Control latency for real-time streaming
  // Limit frame delay to minimize latency (0 = no delay, higher = more buffering)
  int max_frame_delay = 0;  // No frame delay for minimal latency
  CFNumberRef max_frame_delay_num = CFNumberCreate(NULL, kCFNumberIntType, &max_frame_delay);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_MaxFrameDelayCount, max_frame_delay_num);
  CFRelease(max_frame_delay_num);

  // Prioritize encoding speed over quality for real-time streaming
  // This reduces encoding time, improving latency
  // VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse);

  // Set Rec. 709 color space for AirPlay standard output
  // This ensures the encoded stream has correct color space metadata
  // The pixel buffer (input) won't have color space attached, so VideoToolbox
  // will convert from sRGB (source) to Rec. 709 (output) automatically
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
  VTSessionSetProperty(enc->compression_session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  NSLog(@"video_encoder_init: encoder color space set to Rec. 709 (AirPlay standard)");

  // Prepare the session
  status = VTCompressionSessionPrepareToEncodeFrames(enc->compression_session);
  if (status != noErr) {
    NSLog(@"video_encoder_init: failed to prepare session: %d", (int)status);
    VTCompressionSessionInvalidate(enc->compression_session);
    CFRelease(enc->compression_session);
    free(enc);
    return NULL;
  }

  // Format description will be extracted from the first encoded sample buffer
  enc->format_description = NULL;

  NSLog(@"video_encoder_init: initialized successfully");
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
video_encoder_encode_frame(video_encoder_t *enc, uint8_t *rgba_data, int stride, uint64_t pts)
{
  if (!enc || !enc->compression_session || !rgba_data) {
    if (!enc) NSLog(@"video_encoder_encode_frame: encoder is NULL");
    else if (!enc->compression_session) NSLog(@"video_encoder_encode_frame: compression session is NULL");
    else if (!rgba_data) NSLog(@"video_encoder_encode_frame: rgba_data is NULL");
    return -1;
  }

  // Create a CVPixelBuffer and convert RGBA to BGRA (VideoToolbox expects BGRA)
  // Use IOSurface for hardware acceleration and better color handling
  NSDictionary *pixel_buffer_attributes = @{
    (NSString *)kCVPixelBufferWidthKey: @(enc->width),
    (NSString *)kCVPixelBufferHeightKey: @(enc->height),
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{
      (NSString *)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
    },
    (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
  };

  CVPixelBufferRef pixel_buffer = NULL;
  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                       enc->width,
                                       enc->height,
                                       kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)pixel_buffer_attributes,
                                       &pixel_buffer);

  if (status != kCVReturnSuccess || !pixel_buffer) {
    return -1;
  }

  // Don't attach color space to pixel buffer - let VideoToolbox use encoder's color space settings
  // Attaching color space can cause incorrect conversions when input/output don't match perfectly
  // VideoToolbox will treat the pixel buffer as matching the encoder's configured color space

  // Lock the pixel buffer and copy/convert RGBA to BGRA
  CVPixelBufferLockBaseAddress(pixel_buffer, 0);
  void *base_address = CVPixelBufferGetBaseAddress(pixel_buffer);
  size_t buffer_stride = CVPixelBufferGetBytesPerRow(pixel_buffer);

  if (base_address) {
    // Convert RGBA to BGRA, handling potentially different strides
    size_t row_size = enc->width * 4;  // 4 bytes per pixel (BGRA)
    for (int y = 0; y < enc->height; y++) {
      uint8_t *src_row = rgba_data + (y * stride);
      uint8_t *dst_row = (uint8_t *)base_address + (y * buffer_stride);

      // Convert RGBA to BGRA by swapping R and B channels
      for (int x = 0; x < enc->width; x++) {
        dst_row[x * 4 + 0] = src_row[x * 4 + 2];  // B <- R
        dst_row[x * 4 + 1] = src_row[x * 4 + 1];  // G <- G
        dst_row[x * 4 + 2] = src_row[x * 4 + 0];  // R <- B
        dst_row[x * 4 + 3] = src_row[x * 4 + 3];  // A <- A
      }
    }
  }

  CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

  // Create presentation timestamp
  CMTime presentation_time = CMTimeMake(pts, 1000000);  // pts is in microseconds
  CMTime duration = CMTimeMake(1, enc->fps);
  VTEncodeInfoFlags flags = 0;

  // Encode the frame
  OSStatus encode_status = VTCompressionSessionEncodeFrame(
      enc->compression_session,
      pixel_buffer,
      presentation_time,
      duration,
      NULL,  // frameProperties
      NULL,  // sourceFrameRefCon
      &flags);

  CVPixelBufferRelease(pixel_buffer);

  if (encode_status != noErr) {
    if (enc->frame_count == 0 || enc->frame_count % 30 == 0) {
      NSLog(@"video_encoder_encode_frame: encode failed: %d (frame %d)", (int)encode_status, enc->frame_count);
    }
    return -1;
  }

  if (enc->frame_count == 0) {
    NSLog(@"video_encoder_encode_frame: first frame submitted for encoding");
  }

  return 0;
}

void
video_encoder_destroy(video_encoder_t *enc)
{
  if (enc) {
    if (enc->compression_session) {
      VTCompressionSessionCompleteFrames(enc->compression_session, kCMTimeInvalid);
      VTCompressionSessionInvalidate(enc->compression_session);
      CFRelease(enc->compression_session);
      enc->compression_session = NULL;
    }

    if (enc->format_description) {
      CFRelease(enc->format_description);
      enc->format_description = NULL;
    }

    if (enc->sps_data) {
      free(enc->sps_data);
      enc->sps_data = NULL;
    }

    if (enc->pps_data) {
      free(enc->pps_data);
      enc->pps_data = NULL;
    }

    free(enc);
  }
}
