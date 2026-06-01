/**
 *  stream_manager.h
 *  PiP
 *
 *  High-level streaming pipeline manager that wires together:
 *  frame capture -> video encoder -> TS muxer -> HLS writer -> HTTP server.
 *
 *  Owns the full lifecycle of every pipeline component and exposes a simple
 *  Objective-C interface for start/stop/quality control.
 */

#ifndef stream_manager_h
#define stream_manager_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@class ImageView;

/**
 * Quality presets for the streaming pipeline.
 * Each preset determines resolution, bitrate, and frame rate.
 */
typedef enum {
    StreamQualityLow,     /**< 720p,  1.5 Mbps, 24 fps */
    StreamQualityMedium,  /**< 1080p, 3 Mbps,   30 fps */
    StreamQualityHigh,    /**< Native resolution, 6 Mbps, 30 fps */
} StreamQuality;

@interface StreamManager : NSObject

/**
 * Initialize the stream manager with an ImageView to capture from.
 * @param imageView The source ImageView whose content will be streamed
 * @return A new StreamManager instance, or nil on failure
 */
- (instancetype)initWithImageView:(ImageView *)imageView;

/**
 * Start the full streaming pipeline on the given port with the specified quality.
 * Creates and wires all pipeline components (capture, encoder, muxer, writer, server).
 * @param port    TCP port for the HTTP server (e.g. 8080)
 * @param quality Quality preset controlling resolution, bitrate, and frame rate
 * @return YES on success, NO on failure
 */
- (BOOL)startStreamingOnPort:(int)port withQuality:(StreamQuality)quality;

/**
 * Stop the streaming pipeline and destroy all components in reverse order.
 */
- (void)stopStreaming;

/**
 * Check whether the pipeline is currently active and streaming.
 * @return YES if streaming, NO otherwise
 */
- (BOOL)isStreaming;

/**
 * Get the port the HTTP server is listening on.
 * @return Port number, or 0 if not streaming
 */
- (int)port;

/**
 * Get the number of currently connected viewers.
 * @return Active viewer/connection count
 */
- (int)viewerCount;

/**
 * Get the full stream URL including the local IP address and port.
 * Uses the first non-loopback IPv4 address found on an active interface.
 * @return URL string (e.g. "http://192.168.1.42:8080"), or nil if not streaming
 */
- (NSString *)streamURL;

/**
 * Change the streaming quality. If the pipeline is running, it will be
 * restarted with the new quality settings.
 * @param quality The new quality preset to apply
 */
- (void)setQuality:(StreamQuality)quality;

/**
 * Get the current quality preset.
 * @return The active StreamQuality value
 */
- (StreamQuality)currentQuality;

/**
 * Display a QR code of the stream URL in a floating window.
 * The window contains the QR code image and the URL text below it.
 * Does nothing if the pipeline is not streaming.
 */
- (void)showQRCode;

/**
 * Get all local non-loopback IPv4 addresses from active network interfaces.
 * @return Array of IP address strings
 */
- (NSArray<NSString *> *)localIPAddresses;

/**
 * Push a captured audio CMSampleBuffer into the live stream pipeline.
 * Intended for audio buffers received from ScreenCaptureKit.
 * @param sampleBuffer Audio sample buffer
 */
- (void)pushAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

#endif /* stream_manager_h */
