/**
 *  stream_manager.m
 *  PiP
 *
 *  Streaming pipeline manager implementation.
 *  Wires together: frame capture -> video encoder -> TS muxer -> HLS writer -> HTTP server.
 *
 *  The pipeline is driven by C callbacks that chain each stage:
 *    1. frame_capture fires frame_capture_cb() on each captured frame
 *    2. frame_capture_cb() feeds RGBA data into the video encoder
 *    3. The encoder fires encoded_frame_cb() with H.264 NAL units
 *    4. encoded_frame_cb() pushes NALs into the TS muxer
 *    5. The muxer fires segment_cb() when a complete MPEG-TS segment is ready
 *    6. segment_cb() stores the segment in the HLS writer ring buffer
 *    7. The HTTP server serves the HLS playlist and segments on demand
 */

#import "stream_manager.h"
#import "imageView.h"
#import "frame_capture.h"
#import "video_encoder.h"
#import "ts_muxer.h"
#import "hls_writer.h"
#import "stream_server.h"

#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <pthread.h>
#include <math.h>

/* ------------------------------------------------------------------ */
/* Embedded viewer resources via incbin                                */
/* ------------------------------------------------------------------ */

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin.h"

INCBIN(viewer_html, "pip/viewer.html");
INCBIN(hls_js, "pip/hls.min.js");

/* ------------------------------------------------------------------ */
/* Pipeline constants                                                  */
/* ------------------------------------------------------------------ */

#define HLS_MAX_SEGMENTS     12  /* ring buffer size for HLS writer (keeps extra for slow clients) */
#define HLS_PLAYLIST_SIZE    4   /* shorter live window for lower end-to-end latency */
#define SEGMENT_DURATION_SEC 1   /* target MPEG-TS segment duration for ~2-3s latency */

/* ------------------------------------------------------------------ */
/* Quality preset parameters                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    int max_width;   /* maximum width (0 = native) */
    int max_height;  /* maximum height (0 = native) */
    int bitrate;     /* target bitrate in bits per second */
    int fps;         /* target frame rate */
} quality_params_t;

static const quality_params_t quality_presets[] = {
    [StreamQualityLow]    = { 1280, 720,  1500000, 24 },
    [StreamQualityMedium] = { 1920, 1080, 3000000, 30 },
    [StreamQualityHigh]   = { 0,    0,    6000000, 30 },
};

/* ------------------------------------------------------------------ */
/* Pipeline context (passed as void *ctx to C callbacks)               */
/* ------------------------------------------------------------------ */

typedef struct {
    video_encoder_t *encoder;
    ts_muxer_t      *muxer;
    hls_writer_t    *writer;
    int              sps_pps_sent;    /* whether SPS/PPS has been set on the muxer */
    int              expected_width;  /* encoder's configured frame width */
    int              expected_height; /* encoder's configured frame height */
    int              audio_sample_rate;
    int              audio_channels;
    pthread_mutex_t  muxer_lock;
} pipeline_ctx_t;

/* ------------------------------------------------------------------ */
/* Forward declarations for C callbacks                                */
/* ------------------------------------------------------------------ */

static void frame_capture_cb(uint8_t *rgba_data, int width, int height,
                              int stride, uint64_t pts, void *ctx);
static void encoded_frame_cb(uint8_t *data, int len, bool is_keyframe,
                              uint8_t *sps, int sps_len,
                              uint8_t *pps, int pps_len,
                              uint64_t pts, void *ctx);
static void encoded_audio_cb(uint8_t *data, int len, uint64_t pts, void *ctx);
static void segment_cb(void *context, uint8_t *segment_data,
                        size_t segment_size, double duration,
                        uint64_t segment_index);

/* ------------------------------------------------------------------ */
/* Private helper declarations                                         */
/* ------------------------------------------------------------------ */

static NSString *get_local_ip_address(void);
static void compute_output_resolution(StreamQuality quality,
                                       int source_width, int source_height,
                                       int *out_width, int *out_height);
static float *resample_interleaved_linear(const float *input, int input_frames, int channels,
                                          int input_rate, int output_rate, int *output_frames);
static float *expand_mono_to_stereo(const float *input, int frames);

/* ------------------------------------------------------------------ */
/* Internal AAC encoder state                                          */
/* ------------------------------------------------------------------ */

typedef struct {
    AudioConverterRef converter;
    AudioStreamBasicDescription in_asbd;
    AudioStreamBasicDescription out_asbd;
    float *pcm_buffer;
    int pcm_capacity_frames;
    int pcm_frames;
    int sample_rate;
    int channels;
    int bitrate;
    int pts_initialized;
    uint64_t next_pts_us;
} aac_encoder_t;

static aac_encoder_t *aac_encoder_create(int sample_rate, int channels, int bitrate);
static void aac_encoder_destroy(aac_encoder_t *enc);
static int aac_encoder_encode_pcm(aac_encoder_t *enc, const float *samples, int num_frames,
                                   uint64_t pts,
                                   void (*callback)(uint8_t *data, int len, uint64_t pts, void *ctx),
                                   void *callback_ctx);

/* ------------------------------------------------------------------ */
/* StreamManager class extension (private ivars)                       */
/* ------------------------------------------------------------------ */

@interface StreamManager () {
    ImageView        *_imageView;

    /* Pipeline components */
    frame_capture_t  *_capture;
    video_encoder_t  *_encoder;
    aac_encoder_t    *_audio_encoder;
    ts_muxer_t       *_muxer;
    hls_writer_t     *_writer;
    stream_server_t  *_server;

    /* Pipeline callback context (heap-allocated, shared with C callbacks) */
    pipeline_ctx_t   *_pipeline_ctx;

    /* State */
    BOOL              _streaming;
    int               _port;
    StreamQuality     _quality;
    int               _audio_sample_rate;
    int               _audio_channels;
    uint64_t          _audio_next_pts_us;
    BOOL              _audio_pts_initialized;
}
@end

/* ------------------------------------------------------------------ */
/* StreamManager implementation                                        */
/* ------------------------------------------------------------------ */

@implementation StreamManager

/**
 * Initialize the stream manager with an ImageView to capture from.
 * @param imageView The source ImageView
 * @return A new StreamManager instance
 */
- (instancetype)initWithImageView:(ImageView *)imageView
{
    self = [super init];
    if (self) {
        _imageView = imageView;
        _capture = NULL;
        _encoder = NULL;
        _audio_encoder = NULL;
        _muxer = NULL;
        _writer = NULL;
        _server = NULL;
        _pipeline_ctx = NULL;
        _streaming = NO;
        _port = 0;
        _quality = StreamQualityMedium;
        _audio_sample_rate = 0;
        _audio_channels = 0;
        _audio_next_pts_us = 0;
        _audio_pts_initialized = NO;
    }
    return self;
} // end of function initWithImageView:

/**
 * Start the full streaming pipeline on the given port with the specified quality.
 * @param port    TCP port for the HTTP server
 * @param quality Quality preset
 * @return YES on success, NO on failure
 */
- (BOOL)startStreamingOnPort:(int)port withQuality:(StreamQuality)quality
{
    if (_streaming) {
        NSLog(@"stream_manager: already streaming, stop first");
        return NO;
    }

    if (!_imageView) {
        NSLog(@"stream_manager: no ImageView configured");
        return NO;
    }

    _quality = quality;
    _port = port;

    /* Determine source dimensions, preferring the renderer's current frame size.
       View bounds can be larger than the actual rendered CIImage (HiDPI/crop cases),
       which would otherwise configure an encoder too large and drop every frame. */
    int source_width = 0;
    int source_height = 0;

    CIImage *current_image = [_imageView.renderer currentImage];
    if (current_image) {
        CGRect extent = current_image.extent;
        source_width = (int)extent.size.width;
        source_height = (int)extent.size.height;
    }

    if (source_width <= 0 || source_height <= 0) {
        NSSize view_size = _imageView.bounds.size;
        source_width = (int)view_size.width;
        source_height = (int)view_size.height;
    }

    if (source_width <= 0 || source_height <= 0) {
        NSLog(@"stream_manager: invalid source dimensions %dx%d", source_width, source_height);
        return NO;
    }

    /* Compute output resolution based on quality preset */
    int output_width = 0;
    int output_height = 0;
    compute_output_resolution(quality, source_width, source_height,
                              &output_width, &output_height);

    const quality_params_t *params = &quality_presets[quality];

    NSLog(@"stream_manager: starting pipeline %dx%d @ %d fps, %d kbps, port %d",
          output_width, output_height, params->fps, params->bitrate / 1000, port);

    /* --- 1. Create the HLS writer (ring buffer of segments) --- */
    _writer = hls_writer_create(HLS_MAX_SEGMENTS, HLS_PLAYLIST_SIZE, SEGMENT_DURATION_SEC);
    if (!_writer) {
        NSLog(@"stream_manager: failed to create HLS writer");
        [self stopStreaming];
        return NO;
    }

    /* --- 2. Create the TS muxer (feeds segments into the HLS writer) --- */
    _muxer = ts_muxer_create(SEGMENT_DURATION_SEC, segment_cb, _writer);
    if (!_muxer) {
        NSLog(@"stream_manager: failed to create TS muxer");
        [self stopStreaming];
        return NO;
    }

    /* --- 3. Create the video encoder --- */
    _encoder = video_encoder_init(output_width, output_height,
                                  params->fps, params->bitrate);
    if (!_encoder) {
        NSLog(@"stream_manager: failed to create video encoder");
        [self stopStreaming];
        return NO;
    }
    /* Force 1-second GOP for low-latency HLS segmentation. */
    video_encoder_set_keyframe_interval(_encoder, params->fps);

    /* --- 4. Allocate and populate the pipeline context --- */
    _pipeline_ctx = calloc(1, sizeof(pipeline_ctx_t));
    if (!_pipeline_ctx) {
        NSLog(@"stream_manager: failed to allocate pipeline context");
        [self stopStreaming];
        return NO;
    }
    _pipeline_ctx->encoder = _encoder;
    _pipeline_ctx->muxer = _muxer;
    _pipeline_ctx->writer = _writer;
    _pipeline_ctx->sps_pps_sent = 0;
    _pipeline_ctx->expected_width = output_width;
    _pipeline_ctx->expected_height = output_height;
    _pipeline_ctx->audio_sample_rate = 48000;
    _pipeline_ctx->audio_channels = 2;
    pthread_mutex_init(&_pipeline_ctx->muxer_lock, NULL);

    /* Wire the encoder callback -> TS muxer */
    video_encoder_set_callback(_encoder, encoded_frame_cb, _pipeline_ctx);

    /* --- 5. Create the frame capture (source is the ImageView) --- */
    _capture = frame_capture_init((__bridge void *)_imageView);
    if (!_capture) {
        NSLog(@"stream_manager: failed to create frame capture");
        [self stopStreaming];
        return NO;
    }

    /* Wire the capture callback -> encoder */
    frame_capture_set_callback(_capture, frame_capture_cb, _pipeline_ctx);

    /* --- 6. Create and configure the HTTP server --- */
    _server = stream_server_create(port);
    if (!_server) {
        NSLog(@"stream_manager: failed to create stream server");
        [self stopStreaming];
        return NO;
    }

    stream_server_set_hls_writer(_server, _writer);
    stream_server_set_viewer_data(_server, gviewer_htmlData, gviewer_htmlSize);
    stream_server_set_hlsjs_data(_server, ghls_jsData, ghls_jsSize);

    if (stream_server_start(_server) != 0) {
        NSLog(@"stream_manager: failed to start stream server on port %d", port);
        [self stopStreaming];
        return NO;
    }

    /* --- 7. Start capturing frames (this kicks off the whole pipeline) --- */
    if (frame_capture_start(_capture, params->fps) != 0) {
        NSLog(@"stream_manager: failed to start frame capture");
        [self stopStreaming];
        return NO;
    }

    _streaming = YES;
    _audio_sample_rate = 0;
    _audio_channels = 0;
    _audio_next_pts_us = 0;
    _audio_pts_initialized = NO;

    NSString *url = [self streamURL];
    NSLog(@"stream_manager: pipeline started, stream available at %@", url ?: @"(unknown)");

    return YES;
} // end of function startStreamingOnPort:withQuality:

/**
 * Stop the streaming pipeline and destroy all components in reverse order.
 */
- (void)stopStreaming
{
    @synchronized (self) {
        if (!_streaming && !_capture && !_encoder && !_muxer && !_writer && !_server) {
            return;
        }

        NSLog(@"stream_manager: stopping pipeline");
        _streaming = NO;

        /* Stop in reverse order: capture -> encoder -> muxer -> writer -> server */

    /* 1. Stop and destroy frame capture (stops producing frames) */
        if (_capture) {
            frame_capture_stop(_capture);
            frame_capture_destroy(_capture);
            _capture = NULL;
        }

    /* 2. Destroy the video encoder (no more encoded frames after this) */
        if (_encoder) {
            video_encoder_destroy(_encoder);
            _encoder = NULL;
        }

    /* 3. Destroy the audio encoder */
        if (_audio_encoder) {
            aac_encoder_destroy(_audio_encoder);
            _audio_encoder = NULL;
        }

    /* 4. Flush and destroy the TS muxer (emit any partial segment) */
        if (_muxer) {
            ts_muxer_flush(_muxer);
            ts_muxer_destroy(_muxer);
            _muxer = NULL;
        }

    /* 5. Stop and destroy the HTTP server */
        if (_server) {
            stream_server_stop(_server);
            stream_server_destroy(_server);
            _server = NULL;
        }

    /* 6. Destroy the HLS writer (frees segment ring buffer) */
        if (_writer) {
            hls_writer_destroy(_writer);
            _writer = NULL;
        }

    /* 7. Free the pipeline context */
        if (_pipeline_ctx) {
            pthread_mutex_destroy(&_pipeline_ctx->muxer_lock);
            free(_pipeline_ctx);
            _pipeline_ctx = NULL;
        }
        _audio_sample_rate = 0;
        _audio_channels = 0;
        _audio_next_pts_us = 0;
        _audio_pts_initialized = NO;

        NSLog(@"stream_manager: pipeline stopped");
    }
} // end of function stopStreaming

/**
 * Check whether the pipeline is currently active.
 * @return YES if streaming
 */
- (BOOL)isStreaming
{
    return _streaming;
} // end of function isStreaming

/**
 * Get the port the HTTP server is listening on.
 * @return Port number, or 0 if not streaming
 */
- (int)port
{
    if (_server) {
        return stream_server_get_port(_server);
    }
    return 0;
} // end of function port

/**
 * Get the number of currently connected viewers.
 * @return Active connection count
 */
- (int)viewerCount
{
    if (_server) {
        return stream_server_get_connection_count(_server);
    }
    return 0;
} // end of function viewerCount

/**
 * Get the full stream URL including the local IP address and port.
 * @return URL string, or nil if not streaming
 */
- (NSString *)streamURL
{
    if (!_streaming || !_server) {
        return nil;
    }

    NSString *ip = get_local_ip_address();
    if (!ip) {
        ip = @"127.0.0.1";
    }

    int active_port = stream_server_get_port(_server);
    return [NSString stringWithFormat:@"http://%@:%d", ip, active_port];
} // end of function streamURL

/**
 * Change the streaming quality. Restarts the pipeline if currently streaming.
 * @param quality The new quality preset
 */
- (void)setQuality:(StreamQuality)quality
{
    if (_quality == quality) {
        return;
    }

    _quality = quality;

    /* If currently streaming, restart with the new quality */
    if (_streaming) {
        int current_port = _port;
        [self stopStreaming];
        [self startStreamingOnPort:current_port withQuality:quality];
    }
} // end of function setQuality:

/**
 * Get the current quality preset.
 * @return The active StreamQuality value
 */
- (StreamQuality)currentQuality
{
    return _quality;
} // end of function currentQuality

/**
 * Generate a QR code NSImage from a string.
 * Uses CIQRCodeGenerator filter from CoreImage.
 * @param string The string to encode as a QR code
 * @param size   The desired image size in points
 * @return An NSImage of the QR code, or nil on failure
 */
static NSImage *generateQRCode(NSString *string, CGFloat size)
{
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[string dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];

    CIImage *ciImage = filter.outputImage;
    if (!ciImage) return nil;

    /* Scale up from the tiny QR to the desired size */
    CGFloat scale = size / ciImage.extent.size.width;
    CIImage *scaled = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];
    return image;
} // end of function generateQRCode()

/**
 * Show a floating window with the QR code for the stream URL.
 * The window contains the QR code image and the URL text below it.
 * Does nothing if the pipeline is not streaming.
 */
- (void)showQRCode
{
    if (!_streaming) return;

    NSString *url = [self streamURL];
    if (!url) return;

    NSImage *qrImage = generateQRCode(url, 200);
    if (!qrImage) return;

    /* Create a floating panel */
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 250, 280)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:YES];
    [panel setTitle:@"Código QR"];
    [panel setLevel:NSFloatingWindowLevel];
    [panel center];

    NSView *contentView = panel.contentView;

    /* QR code image view */
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(25, 50, 200, 200)];
    [imageView setImage:qrImage];
    [imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [contentView addSubview:imageView];

    /* URL label */
    NSTextField *label = [NSTextField wrappingLabelWithString:url];
    [label setFrame:NSMakeRect(10, 10, 230, 30)];
    [label setAlignment:NSTextAlignmentCenter];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setSelectable:YES];
    [contentView addSubview:label];

    [panel makeKeyAndOrderFront:nil];
} // end of function showQRCode

/**
 * Get all local non-loopback IPv4 addresses from active network interfaces.
 * @return Array of IP address strings
 */
- (NSArray<NSString *> *)localIPAddresses
{
    NSMutableArray *addresses = [[NSMutableArray alloc] init];
    struct ifaddrs *interfaces = NULL;

    if (getifaddrs(&interfaces) != 0) {
        return addresses;
    }

    struct ifaddrs *cursor = interfaces;
    while (cursor != NULL) {
        if (cursor->ifa_addr->sa_family == AF_INET) {
            unsigned int flags = cursor->ifa_flags;
            if ((flags & IFF_UP) && !(flags & IFF_LOOPBACK)) {
                struct sockaddr_in *addr = (struct sockaddr_in *)cursor->ifa_addr;
                char addr_buf[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &addr->sin_addr, addr_buf, sizeof(addr_buf));
                [addresses addObject:[NSString stringWithUTF8String:addr_buf]];
            }
        } // end of block handling AF_INET addresses
        cursor = cursor->ifa_next;
    } // end of loop iterating over network interfaces

    freeifaddrs(interfaces);
    return addresses;
} // end of function localIPAddresses

static float *
resample_interleaved_linear(const float *input, int input_frames, int channels,
                            int input_rate, int output_rate, int *output_frames)
{
    if (!input || input_frames <= 0 || channels <= 0 || input_rate <= 0 || output_rate <= 0 || !output_frames) {
        return NULL;
    }

    if (input_rate == output_rate) {
        size_t sample_count = (size_t)input_frames * (size_t)channels;
        float *copy = malloc(sample_count * sizeof(float));
        if (!copy) {
            return NULL;
        }
        memcpy(copy, input, sample_count * sizeof(float));
        *output_frames = input_frames;
        return copy;
    }

    double ratio = (double)output_rate / (double)input_rate;
    int out_frames = (int)floor((double)input_frames * ratio);
    if (out_frames <= 0) {
        return NULL;
    }

    float *out = calloc((size_t)out_frames * (size_t)channels, sizeof(float));
    if (!out) {
        return NULL;
    }

    double step = (double)input_rate / (double)output_rate;
    for (int i = 0; i < out_frames; i++) {
        double src_pos = (double)i * step;
        int idx0 = (int)src_pos;
        if (idx0 < 0) {
            idx0 = 0;
        }
        if (idx0 >= input_frames) {
            idx0 = input_frames - 1;
        }
        int idx1 = idx0 < (input_frames - 1) ? idx0 + 1 : idx0;
        float frac = (float)(src_pos - (double)idx0);
        for (int ch = 0; ch < channels; ch++) {
            float a = input[(size_t)idx0 * (size_t)channels + (size_t)ch];
            float b = input[(size_t)idx1 * (size_t)channels + (size_t)ch];
            out[(size_t)i * (size_t)channels + (size_t)ch] = a + (b - a) * frac;
        }
    }

    *output_frames = out_frames;
    return out;
}

static float *
expand_mono_to_stereo(const float *input, int frames)
{
    if (!input || frames <= 0) {
        return NULL;
    }

    float *out = calloc((size_t)frames * 2, sizeof(float));
    if (!out) {
        return NULL;
    }

    for (int i = 0; i < frames; i++) {
        float v = input[i];
        out[(size_t)i * 2] = v;
        out[(size_t)i * 2 + 1] = v;
    }
    return out;
}

- (void)pushAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    @synchronized (self) {
        if (!sampleBuffer || !_streaming || !_pipeline_ctx || !_pipeline_ctx->muxer) {
            return;
        }

    CMAudioFormatDescriptionRef format_desc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format_desc) {
        return;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format_desc);
    if (!asbd) {
        return;
    }

    int channels = (int)asbd->mChannelsPerFrame;
    int sample_rate = (int)llround(asbd->mSampleRate);
    int num_frames = (int)CMSampleBufferGetNumSamples(sampleBuffer);
    if (channels <= 0 || sample_rate <= 0 || num_frames <= 0) {
        return;
    }

    size_t abl_size = sizeof(AudioBufferList) + (size_t)(channels > 1 ? (channels - 1) : 0) * sizeof(AudioBuffer);
    AudioBufferList *audio_list = calloc(1, abl_size);
    if (!audio_list) {
        return;
    }
    CMBlockBufferRef block_buffer = NULL;
    OSStatus list_status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        audio_list,
        abl_size,
        NULL,
        NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &block_buffer
    );
    if (list_status != noErr || audio_list->mNumberBuffers == 0) {
        free(audio_list);
        if (block_buffer) {
            CFRelease(block_buffer);
        }
        return;
    }

    size_t sample_count = (size_t)num_frames * (size_t)channels;
    float *working = calloc(sample_count, sizeof(float));
    if (!working) {
        free(audio_list);
        if (block_buffer) {
            CFRelease(block_buffer);
        }
        return;
    }

    int non_interleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : 0;
    int is_float = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) ? 1 : 0;
    int is_signed_int = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) ? 1 : 0;
    int bits_per_channel = (int)asbd->mBitsPerChannel;

    if (non_interleaved) {
        for (int ch = 0; ch < channels; ch++) {
            uint32_t buf_index = (uint32_t)((ch < (int)audio_list->mNumberBuffers) ? ch : 0);
            AudioBuffer ab = audio_list->mBuffers[buf_index];
            if (!ab.mData) {
                continue;
            }

            if (is_float && bits_per_channel == 32) {
                const float *src = (const float *)ab.mData;
                for (int i = 0; i < num_frames; i++) {
                    working[i * channels + ch] = src[i];
                }
            } else if (is_signed_int && bits_per_channel == 16) {
                const int16_t *src = (const int16_t *)ab.mData;
                for (int i = 0; i < num_frames; i++) {
                    working[i * channels + ch] = (float)src[i] / 32768.0f;
                }
            }
        }
    } else {
        AudioBuffer ab = audio_list->mBuffers[0];
        if (ab.mData) {
            if (is_float && bits_per_channel == 32) {
                size_t copy_count = sample_count;
                size_t available = ab.mDataByteSize / sizeof(float);
                if (available < copy_count) {
                    copy_count = available;
                }
                memcpy(working, ab.mData, copy_count * sizeof(float));
            } else if (is_signed_int && bits_per_channel == 16) {
                const int16_t *src = (const int16_t *)ab.mData;
                size_t available = ab.mDataByteSize / sizeof(int16_t);
                size_t count = sample_count < available ? sample_count : available;
                for (size_t i = 0; i < count; i++) {
                    working[i] = (float)src[i] / 32768.0f;
                }
            }
        }
    }

    int encode_sample_rate = sample_rate;
    int encode_channels = channels;
    int encode_frames = num_frames;

    if (encode_sample_rate > 48000) {
        int resampled_frames = 0;
        float *resampled = resample_interleaved_linear(working, encode_frames, encode_channels,
                                                       encode_sample_rate, 48000, &resampled_frames);
        if (resampled && resampled_frames > 0) {
            free(working);
            working = resampled;
            encode_frames = resampled_frames;
            encode_sample_rate = 48000;
        }
    }

    if (encode_channels == 1) {
        float *stereo = expand_mono_to_stereo(working, encode_frames);
        if (stereo) {
            free(working);
            working = stereo;
            encode_channels = 2;
        }
    }

    if (encode_frames <= 0) {
        free(working);
        free(audio_list);
        if (block_buffer) {
            CFRelease(block_buffer);
        }
        return;
    }

    if (!_audio_encoder || _audio_sample_rate != encode_sample_rate || _audio_channels != encode_channels) {
        if (_audio_encoder) {
            aac_encoder_destroy(_audio_encoder);
            _audio_encoder = NULL;
        }

        _audio_encoder = aac_encoder_create(encode_sample_rate, encode_channels, 128000);
        if (!_audio_encoder) {
            free(working);
            free(audio_list);
            if (block_buffer) {
                CFRelease(block_buffer);
            }
            return;
        }

        _audio_sample_rate = _audio_encoder->sample_rate;
        _audio_channels = _audio_encoder->channels;
        _pipeline_ctx->audio_sample_rate = _audio_encoder->sample_rate;
        _pipeline_ctx->audio_channels = _audio_encoder->channels;
        _audio_next_pts_us = 0;
        _audio_pts_initialized = NO;
        NSLog(@"stream_manager: audio encoder configured %d Hz, %d ch (input %d Hz, %d ch)",
              _audio_encoder->sample_rate, _audio_encoder->channels, sample_rate, channels);
    }

    uint64_t pts_us = 0;
    if (!_audio_pts_initialized) {
        _audio_next_pts_us = 0;
        _audio_pts_initialized = YES;
    }
    pts_us = _audio_next_pts_us;
    _audio_next_pts_us += (uint64_t)((double)encode_frames * 1000000.0 / (double)_audio_sample_rate);

        aac_encoder_encode_pcm(_audio_encoder, working, encode_frames, pts_us, encoded_audio_cb, _pipeline_ctx);

        free(working);
        free(audio_list);
        if (block_buffer) {
            CFRelease(block_buffer);
        }
    }
}

/**
 * Clean up all resources when the manager is deallocated.
 */
- (void)dealloc
{
    [self stopStreaming];
} // end of function dealloc

@end

/* ================================================================== */
/* Internal AAC encoder (PCM float -> AAC LC raw frames)               */
/* ================================================================== */

typedef struct {
    const float *pcm;
    UInt32 frames;
    UInt32 channels;
} aac_input_ctx_t;

static OSStatus
aac_input_data_proc(AudioConverterRef inAudioConverter,
                    UInt32 *ioNumberDataPackets,
                    AudioBufferList *ioData,
                    AudioStreamPacketDescription **outDataPacketDescription,
                    void *inUserData)
{
    (void)inAudioConverter;
    (void)outDataPacketDescription;

    aac_input_ctx_t *ctx = (aac_input_ctx_t *)inUserData;
    if (!ctx || !ctx->pcm || !ioNumberDataPackets || *ioNumberDataPackets == 0 || ctx->frames == 0) {
        *ioNumberDataPackets = 0;
        return -1;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = ctx->channels;
    ioData->mBuffers[0].mData = (void *)ctx->pcm;
    ioData->mBuffers[0].mDataByteSize = ctx->frames * ctx->channels * sizeof(float);
    *ioNumberDataPackets = ctx->frames;
    return noErr;
}

static aac_encoder_t *
aac_encoder_create(int sample_rate, int channels, int bitrate)
{
    if (sample_rate <= 0 || channels <= 0) {
        return NULL;
    }

    aac_encoder_t *enc = calloc(1, sizeof(aac_encoder_t));
    if (!enc) {
        return NULL;
    }

    enc->sample_rate = sample_rate;
    enc->channels = channels;
    enc->bitrate = bitrate > 0 ? bitrate : 128000;
    enc->pcm_capacity_frames = 8192;
    enc->pcm_frames = 0;
    enc->pts_initialized = 0;
    enc->next_pts_us = 0;
    enc->pcm_buffer = calloc((size_t)enc->pcm_capacity_frames * (size_t)channels, sizeof(float));
    if (!enc->pcm_buffer) {
        free(enc);
        return NULL;
    }

    memset(&enc->in_asbd, 0, sizeof(enc->in_asbd));
    enc->in_asbd.mSampleRate = (Float64)sample_rate;
    enc->in_asbd.mFormatID = kAudioFormatLinearPCM;
    enc->in_asbd.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    enc->in_asbd.mBitsPerChannel = 32;
    enc->in_asbd.mChannelsPerFrame = (UInt32)channels;
    enc->in_asbd.mFramesPerPacket = 1;
    enc->in_asbd.mBytesPerFrame = (UInt32)(channels * (int)sizeof(float));
    enc->in_asbd.mBytesPerPacket = enc->in_asbd.mBytesPerFrame;

    memset(&enc->out_asbd, 0, sizeof(enc->out_asbd));
    enc->out_asbd.mSampleRate = (Float64)sample_rate;
    enc->out_asbd.mFormatID = kAudioFormatMPEG4AAC;
    enc->out_asbd.mFormatFlags = kMPEG4Object_AAC_LC;
    enc->out_asbd.mChannelsPerFrame = (UInt32)channels;

    UInt32 out_asbd_size = sizeof(enc->out_asbd);
    OSStatus format_status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                                    0, NULL,
                                                    &out_asbd_size, &enc->out_asbd);
    if (format_status != noErr) {
        free(enc->pcm_buffer);
        free(enc);
        return NULL;
    }

    OSStatus create_status = AudioConverterNew(&enc->in_asbd, &enc->out_asbd, &enc->converter);
    if (create_status != noErr || !enc->converter) {
        free(enc->pcm_buffer);
        free(enc);
        return NULL;
    }

    UInt32 br = (UInt32)enc->bitrate;
    AudioConverterSetProperty(enc->converter, kAudioConverterEncodeBitRate, sizeof(br), &br);

    return enc;
}

static void
aac_encoder_destroy(aac_encoder_t *enc)
{
    if (!enc) {
        return;
    }

    if (enc->converter) {
        AudioConverterDispose(enc->converter);
        enc->converter = NULL;
    }
    if (enc->pcm_buffer) {
        free(enc->pcm_buffer);
        enc->pcm_buffer = NULL;
    }
    free(enc);
}

static int
aac_encoder_ensure_pcm_capacity(aac_encoder_t *enc, int needed_frames)
{
    if (!enc) {
        return -1;
    }
    if (needed_frames <= enc->pcm_capacity_frames) {
        return 0;
    }

    int new_capacity = enc->pcm_capacity_frames;
    while (new_capacity < needed_frames) {
        new_capacity *= 2;
    }

    size_t sample_count = (size_t)new_capacity * (size_t)enc->channels;
    float *new_buf = realloc(enc->pcm_buffer, sample_count * sizeof(float));
    if (!new_buf) {
        return -1;
    }

    enc->pcm_buffer = new_buf;
    enc->pcm_capacity_frames = new_capacity;
    return 0;
}

static int
aac_encoder_encode_pcm(aac_encoder_t *enc, const float *samples, int num_frames,
                       uint64_t pts,
                       void (*callback)(uint8_t *data, int len, uint64_t pts, void *ctx),
                       void *callback_ctx)
{
    if (!enc || !samples || num_frames <= 0 || !enc->converter) {
        return -1;
    }

    if (!enc->pts_initialized) {
        enc->next_pts_us = pts;
        enc->pts_initialized = 1;
    } else {
        /* Re-anchor if external clock drifts significantly. */
        uint64_t delta = enc->next_pts_us > pts ? enc->next_pts_us - pts : pts - enc->next_pts_us;
        if (delta > 2000000ULL) {
            enc->next_pts_us = pts;
        }
    }

    int needed_frames = enc->pcm_frames + num_frames;
    if (aac_encoder_ensure_pcm_capacity(enc, needed_frames) != 0) {
        return -1;
    }

    size_t dst_offset = (size_t)enc->pcm_frames * (size_t)enc->channels;
    size_t copy_samples = (size_t)num_frames * (size_t)enc->channels;
    memcpy(enc->pcm_buffer + dst_offset, samples, copy_samples * sizeof(float));
    enc->pcm_frames += num_frames;

    const int aac_frame_samples = 1024;

    while (enc->pcm_frames >= aac_frame_samples) {
        aac_input_ctx_t input_ctx;
        input_ctx.pcm = enc->pcm_buffer;
        input_ctx.frames = (UInt32)aac_frame_samples;
        input_ctx.channels = (UInt32)enc->channels;

        uint8_t out_buf[8192];
        AudioBufferList out_list;
        out_list.mNumberBuffers = 1;
        out_list.mBuffers[0].mNumberChannels = (UInt32)enc->channels;
        out_list.mBuffers[0].mData = out_buf;
        out_list.mBuffers[0].mDataByteSize = sizeof(out_buf);

        UInt32 out_packets = 1;
        AudioStreamPacketDescription out_desc = {0};
        OSStatus enc_status = AudioConverterFillComplexBuffer(
            enc->converter,
            aac_input_data_proc,
            &input_ctx,
            &out_packets,
            &out_list,
            &out_desc
        );

        if (enc_status == noErr && out_packets > 0 && out_list.mBuffers[0].mDataByteSize > 0 && callback) {
            uint8_t *copy = malloc(out_list.mBuffers[0].mDataByteSize);
            if (copy) {
                memcpy(copy, out_list.mBuffers[0].mData, out_list.mBuffers[0].mDataByteSize);
                callback(copy, (int)out_list.mBuffers[0].mDataByteSize, enc->next_pts_us, callback_ctx);
                free(copy);
            }
        }

        enc->next_pts_us += (uint64_t)((double)aac_frame_samples * 1000000.0 / (double)enc->sample_rate);

        int remaining_frames = enc->pcm_frames - aac_frame_samples;
        if (remaining_frames > 0) {
            size_t remaining_samples = (size_t)remaining_frames * (size_t)enc->channels;
            memmove(enc->pcm_buffer,
                    enc->pcm_buffer + ((size_t)aac_frame_samples * (size_t)enc->channels),
                    remaining_samples * sizeof(float));
        }
        enc->pcm_frames = remaining_frames;
    }

    return 0;
}

/* ================================================================== */
/* C callback functions (static, pipeline glue)                        */
/* ================================================================== */

/**
 * Frame capture callback. Called for each captured RGBA frame.
 * Feeds the frame data into the video encoder.
 * @param rgba_data Raw RGBA32 pixel data (freed after callback returns)
 * @param width     Frame width in pixels
 * @param height    Frame height in pixels
 * @param stride    Bytes per row
 * @param pts       Presentation timestamp in microseconds
 * @param ctx       Pipeline context (pipeline_ctx_t *)
 */
static void
frame_capture_cb(uint8_t *rgba_data, int width, int height,
                 int stride, uint64_t pts, void *ctx)
{
    pipeline_ctx_t *pipeline = (pipeline_ctx_t *)ctx;
    if (!pipeline || !pipeline->encoder) {
        return;
    }

    /* Skip frames that are smaller than the encoder expects.
       The encoder reads enc->width * enc->height pixels from the buffer,
       so a smaller source would cause out-of-bounds reads. Larger sources
       are safe (the encoder simply crops to its configured dimensions). */
    if (width < pipeline->expected_width || height < pipeline->expected_height) {
        return;
    }

    video_encoder_encode_frame(pipeline->encoder, rgba_data, stride, pts);
} // end of function frame_capture_cb()

/**
 * Encoded frame callback. Called for each encoded H.264 access unit.
 * Sets SPS/PPS on the muxer when available, then pushes the NAL data.
 * @param data        Encoded H.264 data in AVCC format (freed after callback returns)
 * @param len         Length of encoded data in bytes
 * @param is_keyframe True if this is a keyframe (IDR)
 * @param sps         SPS NAL unit data (may be NULL)
 * @param sps_len     Length of SPS data
 * @param pps         PPS NAL unit data (may be NULL)
 * @param pps_len     Length of PPS data
 * @param pts         Presentation timestamp in microseconds
 * @param ctx         Pipeline context (pipeline_ctx_t *)
 */
static void
encoded_frame_cb(uint8_t *data, int len, bool is_keyframe,
                 uint8_t *sps, int sps_len,
                 uint8_t *pps, int pps_len,
                 uint64_t pts, void *ctx)
{
    pipeline_ctx_t *pipeline = (pipeline_ctx_t *)ctx;
    if (!pipeline || !pipeline->muxer) {
        return;
    }

    pthread_mutex_lock(&pipeline->muxer_lock);

    /* Update SPS/PPS on the muxer whenever new parameter sets arrive */
    if (sps && sps_len > 0 && pps && pps_len > 0) {
        ts_muxer_set_sps_pps(pipeline->muxer,
                              sps, (size_t)sps_len,
                              pps, (size_t)pps_len);
        pipeline->sps_pps_sent = 1;
    }

    /* Only push data if we have SPS/PPS configured */
    if (!pipeline->sps_pps_sent) {
        pthread_mutex_unlock(&pipeline->muxer_lock);
        return;
    }

    ts_muxer_push_h264(pipeline->muxer,
                        data, (size_t)len,
                        pts, is_keyframe ? 1 : 0);

    pthread_mutex_unlock(&pipeline->muxer_lock);
} // end of function encoded_frame_cb()

static void
encoded_audio_cb(uint8_t *data, int len, uint64_t pts, void *ctx)
{
    pipeline_ctx_t *pipeline = (pipeline_ctx_t *)ctx;
    if (!pipeline || !pipeline->muxer || !data || len <= 0) {
        return;
    }

    pthread_mutex_lock(&pipeline->muxer_lock);
    ts_muxer_push_aac(pipeline->muxer, data, (size_t)len, pts,
                      pipeline->audio_sample_rate, pipeline->audio_channels);
    pthread_mutex_unlock(&pipeline->muxer_lock);
}

/**
 * TS segment callback. Called when a complete MPEG-TS segment is ready.
 * Stores the segment in the HLS writer ring buffer.
 * @param context       HLS writer instance (hls_writer_t *)
 * @param segment_data  Segment data (copied by hls_writer_add_segment)
 * @param segment_size  Size of segment data in bytes
 * @param duration      Segment duration in seconds
 * @param segment_index Zero-based segment index
 */
static void
segment_cb(void *context, uint8_t *segment_data,
           size_t segment_size, double duration,
           uint64_t segment_index)
{
    hls_writer_t *writer = (hls_writer_t *)context;
    if (!writer) {
        return;
    }

    hls_writer_add_segment(writer, segment_data, segment_size,
                           duration, segment_index);
} // end of function segment_cb()

/* ================================================================== */
/* Private helper functions                                            */
/* ================================================================== */

/**
 * Get the local IP address of the first active non-loopback IPv4 interface.
 * Prefers en0/en1 (Wi-Fi/Ethernet) interfaces.
 * @return IP address string, or nil if no suitable interface is found
 */
static NSString *
get_local_ip_address(void)
{
    NSString *result = nil;
    struct ifaddrs *interfaces = NULL;

    if (getifaddrs(&interfaces) != 0) {
        NSLog(@"stream_manager: getifaddrs() failed");
        return nil;
    }

    struct ifaddrs *cursor = interfaces;
    while (cursor != NULL) {
        /* Only consider IPv4 addresses */
        if (cursor->ifa_addr->sa_family != AF_INET) {
            cursor = cursor->ifa_next;
            continue;
        }

        /* Skip interfaces that are not up or are loopback */
        unsigned int flags = cursor->ifa_flags;
        if (!(flags & IFF_UP) || (flags & IFF_LOOPBACK)) {
            cursor = cursor->ifa_next;
            continue;
        }

        /* Prefer en0, en1, etc. (Wi-Fi and Ethernet) */
        NSString *if_name = [NSString stringWithUTF8String:cursor->ifa_name];
        if ([if_name hasPrefix:@"en"]) {
            struct sockaddr_in *addr = (struct sockaddr_in *)cursor->ifa_addr;
            char addr_buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &addr->sin_addr, addr_buf, sizeof(addr_buf));
            result = [NSString stringWithUTF8String:addr_buf];
            break;
        }

        cursor = cursor->ifa_next;
    } // end of loop iterating over network interfaces

    freeifaddrs(interfaces);
    return result;
} // end of function get_local_ip_address()

/**
 * Compute the output resolution based on the quality preset and source dimensions.
 * Clamps to the preset maximum while maintaining the source aspect ratio.
 * For StreamQualityHigh, uses the native source resolution.
 * @param quality       Quality preset
 * @param source_width  Source width in pixels
 * @param source_height Source height in pixels
 * @param out_width     Output: computed width (always even for encoder compatibility)
 * @param out_height    Output: computed height (always even for encoder compatibility)
 */
static void
compute_output_resolution(StreamQuality quality,
                          int source_width, int source_height,
                          int *out_width, int *out_height)
{
    const quality_params_t *params = &quality_presets[quality];

    int w = source_width;
    int h = source_height;

    /* If the preset has a maximum, clamp to it while maintaining aspect ratio */
    if (params->max_width > 0 && params->max_height > 0) {
        if (w > params->max_width || h > params->max_height) {
            double scale_w = (double)params->max_width / (double)w;
            double scale_h = (double)params->max_height / (double)h;
            double scale = (scale_w < scale_h) ? scale_w : scale_h;
            w = (int)(w * scale);
            h = (int)(h * scale);
        }
    } // end of block clamping to preset maximum

    /* Ensure dimensions are even (required by most video encoders) */
    w = (w + 1) & ~1;
    h = (h + 1) & ~1;

    /* Ensure minimum dimensions */
    if (w < 2) w = 2;
    if (h < 2) h = 2;

    *out_width = w;
    *out_height = h;
} // end of function compute_output_resolution()
