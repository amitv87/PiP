#import "HLSPlayer.h"

@interface HLSPlayer ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) NSTimer *frameTimer;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) CGSize viewportSize;
@property (nonatomic, assign) double lastIndicatedBitrate;
@property (nonatomic, assign) CGSize lastResolution;
@end

@implementation HLSPlayer

- (instancetype)initWithURL:(NSURL *)url {
  return [self initWithURL:url headers:nil];
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers {
  self = [super init];
  if (self) {
    NSLog(@"[HLSPlayer] url: %@, headers: %@", url, headers);
    AVURLAsset *asset;
    if (headers && headers.count > 0) {
      // Create asset with custom headers
      // AVURLAsset uses AVURLAssetHTTPHeaderFieldsKey to set custom HTTP headers
      NSDictionary *options = @{@"AVURLAssetHTTPHeaderFieldsKey": headers};
      asset = [[AVURLAsset alloc] initWithURL:url options:options];
    } else {
      asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    }

    _playerItem = [AVPlayerItem playerItemWithAsset:asset];
    _player = [AVPlayer playerWithPlayerItem:_playerItem];
    _player.automaticallyWaitsToMinimizeStalling = NO;
    _playerItem.preferredForwardBufferDuration = 1.0;

    // Setup video output for frame extraction
    NSDictionary *pixBuffAttributes = @{
      (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
    _videoOutput.suppressesPlayerRendering = YES;
    [_playerItem addOutput:_videoOutput];

    _viewportSize = CGSizeZero; // Initialize to zero (will be set when window size is known)
    _lastIndicatedBitrate = 0;
    _lastResolution = CGSizeZero;

    // Observe player status and other properties
    [_playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"error" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"seekableTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:nil];
    [_playerItem addObserver:self forKeyPath:@"duration" options:NSKeyValueObservingOptionNew context:nil];

    // Observe playback rate
    [_player addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:nil];

    // Observe time changes
    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC);
    [_player addPeriodicTimeObserverForInterval:interval queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
      [weakSelf.delegate hlsPlayerDidChangeTime:time];
    }];

    // Observe access log entries to detect resolution/bitrate changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(accessLogEntry:)
                                              name:AVPlayerItemNewAccessLogEntryNotification
                                              object:_playerItem];

    // Setup timer for frame extraction (60fps for smooth playback)
    _frameTimer = nil;

    _isPlaying = NO;
  }
  return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if ([keyPath isEqualToString:@"status"]) {
    AVPlayerItemStatus status = _playerItem.status;
    if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeStatus:)]) {
      [self.delegate hlsPlayerDidChangeStatus:status];
    }

    // Report error if status is failed
    if (status == AVPlayerItemStatusFailed && _playerItem.error) {
      if ([self.delegate respondsToSelector:@selector(hlsPlayerDidEncounterError:)]) {
        [self.delegate hlsPlayerDidEncounterError:_playerItem.error];
      }
      NSLog(@"[HLSPlayer] Status failed with error: %@", _playerItem.error);
    }
  } else if ([keyPath isEqualToString:@"error"]) {
    if (_playerItem.error) {
      if ([self.delegate respondsToSelector:@selector(hlsPlayerDidEncounterError:)]) {
        [self.delegate hlsPlayerDidEncounterError:_playerItem.error];
      }
      NSLog(@"[HLSPlayer] Error: %@", _playerItem.error);
    }
  } else if ([keyPath isEqualToString:@"loadedTimeRanges"] ||
             [keyPath isEqualToString:@"playbackBufferEmpty"] ||
             [keyPath isEqualToString:@"playbackLikelyToKeepUp"]) {
    // Report loading status
    BOOL isLoading = _playerItem.playbackBufferEmpty || !_playerItem.playbackLikelyToKeepUp;
    if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeLoadingStatus:)]) {
      [self.delegate hlsPlayerDidChangeLoadingStatus:isLoading];
    }
  } else if ([keyPath isEqualToString:@"seekableTimeRanges"]) {
    // Seekable time ranges changed (important for live streams)
    if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeSeekableRanges:)]) {
      [self.delegate hlsPlayerDidChangeSeekableRanges:_playerItem.seekableTimeRanges];
    }
  } else if ([keyPath isEqualToString:@"duration"]) {
    if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeDuration:)]) {
      [self.delegate hlsPlayerDidChangeDuration:_playerItem.duration];
    }
  } else if ([keyPath isEqualToString:@"rate"]) {
    if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangePlaybackRate:)]) {
      [self.delegate hlsPlayerDidChangePlaybackRate:_player.rate];
    }
  }
}

- (void)frameTimerCallback:(NSTimer *)timer {
  CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];

  if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
    if (pixelBuffer) {
      CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
      if ([self.delegate respondsToSelector:@selector(hlsPlayerDidUpdateFrame:)]) {
        [self.delegate hlsPlayerDidUpdateFrame:image];
      }
      CVPixelBufferRelease(pixelBuffer);
    }
  }
}

- (void)play {
  [self.player play];
  // Start frame timer at 60fps for smooth playback
  if (!self.frameTimer) {
    self.frameTimer = [NSTimer timerWithTimeInterval:1.0/60.0 target:self selector:@selector(frameTimerCallback:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.frameTimer forMode:NSRunLoopCommonModes];
  }
  self.isPlaying = YES;
}

- (void)pause {
  [self.player pause];
  if (self.frameTimer) {
    [self.frameTimer invalidate];
    self.frameTimer = nil;
  }
  self.isPlaying = NO;
}

- (void)stop {
  [self pause];
  [self.player seekToTime:kCMTimeZero];
}

- (void)seekToTime:(CMTime)time {
  [self.player seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)setVolume:(float)volume {
  self.player.volume = volume;
}

- (CMTime)duration {
  return self.playerItem.duration;
}

- (NSArray<NSDictionary *> *)getAvailableQualities {
  NSMutableArray *qualities = [[NSMutableArray alloc] init];

  // Add automatic quality option
  [qualities addObject:@{
    @"name": @"Automatic",
    @"bitrate": @0,
    @"resolution": @"Auto"
  }];

  // Try to get variants if available (macOS 12.0+)
  if (@available(macOS 12.0, *)) {
    AVURLAsset *asset = (AVURLAsset *)self.playerItem.asset;
    if ([asset isKindOfClass:[AVURLAsset class]] && [asset respondsToSelector:@selector(variants)]) {
      NSArray<AVAssetVariant *> *variants = asset.variants;
      if (variants && variants.count > 0) {
        NSMutableSet *seenQualities = [[NSMutableSet alloc] init];

        for (AVAssetVariant *variant in variants) {
          double bitrate = variant.averageBitRate;
          if (bitrate <= 0) {
            bitrate = variant.peakBitRate;
          }

          CGSize resolution = CGSizeZero;
          AVAssetVariantVideoAttributes *videoAttrs = variant.videoAttributes;
          if (videoAttrs) {
            resolution = videoAttrs.presentationSize;
          }

          if (bitrate > 0 || !CGSizeEqualToSize(resolution, CGSizeZero)) {
            NSString *name;
            NSString *qualityKey;
            NSString *codec = nil;

            // Extract codec information if available
            if (videoAttrs) {
              // Get codec types from video attributes (array of FourCharCode as NSNumber)
              if ([videoAttrs respondsToSelector:@selector(codecTypes)] && videoAttrs.codecTypes.count > 0) {
                NSNumber *codecTypeNum = videoAttrs.codecTypes.firstObject;
                FourCharCode codecType = [codecTypeNum unsignedIntValue];
                codec = [NSString stringWithFormat:@"%c%c%c%c",
                  (char)((codecType >> 24) & 0xFF),
                  (char)((codecType >> 16) & 0xFF),
                  (char)((codecType >> 8) & 0xFF),
                  (char)(codecType & 0xFF)];
                // Clean up any null bytes
                codec = [codec stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
              }
            }

            // Build quality name with resolution, bitrate, and codec
            NSMutableArray *nameParts = [[NSMutableArray alloc] init];

            if (!CGSizeEqualToSize(resolution, CGSizeZero)) {
              [nameParts addObject:[NSString stringWithFormat:@"%.0fx%.0f", resolution.width, resolution.height]];
              qualityKey = [NSString stringWithFormat:@"%.0fx%.0f", resolution.width, resolution.height];
            }

            if (bitrate > 0) {
              NSString *bitrateStr;
              if (bitrate >= 1000000) {
                bitrateStr = [NSString stringWithFormat:@"%.1f Mbps", bitrate / 1000000.0];
              } else {
                bitrateStr = [NSString stringWithFormat:@"%.0f Kbps", bitrate / 1000.0];
              }
              [nameParts addObject:bitrateStr];
              if (!qualityKey) {
                qualityKey = [NSString stringWithFormat:@"%.0f", bitrate];
              } else {
                qualityKey = [NSString stringWithFormat:@"%@_%.0f", qualityKey, bitrate];
              }
            }

            if (codec && codec.length > 0) {
              [nameParts addObject:codec];
              if (qualityKey) {
                qualityKey = [NSString stringWithFormat:@"%@_%@", qualityKey, codec];
              } else {
                qualityKey = codec;
              }
            }

            if (nameParts.count == 0) {
              continue; // Skip if no useful info
            }

            name = [nameParts componentsJoinedByString:@" • "];

            // Avoid duplicates
            if (![seenQualities containsObject:qualityKey]) {
              [seenQualities addObject:qualityKey];
              [qualities addObject:@{
                @"name": name,
                @"bitrate": @(bitrate),
                @"resolution": !CGSizeEqualToSize(resolution, CGSizeZero) ?
                  [NSString stringWithFormat:@"%.0fx%.0f", resolution.width, resolution.height] : @"Unknown",
                @"codec": codec ? codec : @"Unknown"
              }];
            }
          }
        }
      }
    }
  }

  // If no variants found, add common quality presets
  if (qualities.count == 1) {
    [qualities addObjectsFromArray:@[
      @{@"name": @"1920x1080 • 5.0 Mbps", @"bitrate": @5000000, @"resolution": @"1920x1080", @"codec": @"Unknown"},
      @{@"name": @"1280x720 • 3.0 Mbps", @"bitrate": @3000000, @"resolution": @"1280x720", @"codec": @"Unknown"},
      @{@"name": @"854x480 • 1.5 Mbps", @"bitrate": @1500000, @"resolution": @"854x480", @"codec": @"Unknown"},
      @{@"name": @"640x360 • 800.0 Kbps", @"bitrate": @800000, @"resolution": @"640x360", @"codec": @"Unknown"},
      @{@"name": @"426x240 • 400.0 Kbps", @"bitrate": @400000, @"resolution": @"426x240", @"codec": @"Unknown"}
    ]];
  }

  return qualities;
}

- (void)setViewportResolution {
  if (@available(macOS 10.13, *)) {
    CGSize maxResolution = CGSizeZero;
    if (!CGSizeEqualToSize(self.viewportSize, CGSizeZero)) {
      CGFloat viewportWidth = self.viewportSize.width;
      CGFloat viewportHeight = self.viewportSize.height;
      CGFloat viewportPixels = viewportWidth * viewportHeight;

      // Try to get available resolutions from HLS variants
      CGSize closestResolution = CGSizeZero;
      CGFloat closestDistance = CGFLOAT_MAX;

      if (@available(macOS 12.0, *)) {
        AVURLAsset *asset = (AVURLAsset *)self.playerItem.asset;
        if ([asset isKindOfClass:[AVURLAsset class]] && [asset respondsToSelector:@selector(variants)]) {
          NSArray<AVAssetVariant *> *variants = asset.variants;
          if (variants && variants.count > 0) {
            for (AVAssetVariant *variant in variants) {
              AVAssetVariantVideoAttributes *videoAttrs = variant.videoAttributes;
              if (videoAttrs) {
                CGSize variantResolution = videoAttrs.presentationSize;
                if (!CGSizeEqualToSize(variantResolution, CGSizeZero)) {
                  CGFloat variantPixels = variantResolution.width * variantResolution.height;

                  // Find the closest resolution that's >= viewport size
                  // Prefer resolutions that are slightly larger than viewport (better quality)
                  CGFloat distance = variantPixels - viewportPixels;

                  // If this variant is larger or equal to viewport, and closer than previous best
                  if (distance >= 0 && distance < closestDistance) {
                    closestResolution = variantResolution;
                    closestDistance = distance;
                  }
                  // If no variant is >= viewport, pick the largest available
                  else if (distance < 0 && closestDistance == CGFLOAT_MAX) {
                    if (variantPixels > closestResolution.width * closestResolution.height) {
                      closestResolution = variantResolution;
                    }
                  }
                }
              }
            }
          }
        }
      }

      // If we found a matching variant resolution, use it
      if (!CGSizeEqualToSize(closestResolution, CGSizeZero)) {
        maxResolution = closestResolution;
        // NSLog(@"[HLSPlayer] Automatic mode: viewport=%.0fx%.0f, found closest variant resolution=%.0fx%.0f",
        //       viewportWidth, viewportHeight, maxResolution.width, maxResolution.height);
      } else {
        // Fallback to preset tiers if variants not available
        if (viewportWidth <= 320) maxResolution = CGSizeMake(320, 240); // QVGA
        else if (viewportWidth <= 640) maxResolution = CGSizeMake(640, 480); // VGA
        else if (viewportWidth <= 854) maxResolution = CGSizeMake(854, 480); // 480p
        else if (viewportWidth <= 1280) maxResolution = CGSizeMake(1280, 720); // 720p
        else if (viewportWidth <= 1920) maxResolution = CGSizeMake(1920, 1080); // 1080p
        else maxResolution = CGSizeMake(3840, 2160); // 4K

        NSLog(@"[HLSPlayer] Automatic mode: viewport=%.0fx%.0f, using fallback preset=%.0fx%.0f",
              viewportWidth, viewportHeight, maxResolution.width, maxResolution.height);
      }
    }
    self.playerItem.preferredMaximumResolution = maxResolution;
  }
}

- (void)setQuality:(NSDictionary *)quality {
  NSNumber *bitrate = quality[@"bitrate"];
  if (bitrate) {
    // Set preferred peak bitrate (0 = automatic)
    self.playerItem.preferredPeakBitRate = [bitrate doubleValue];

    // Also set preferred maximum resolution if available
    NSString *resolutionStr = quality[@"resolution"];
    if (@available(macOS 10.13, *)) {
      if (resolutionStr && ![resolutionStr isEqualToString:@"Auto"]) {
        // Parse resolution string (format: "1920x1080")
        NSArray *components = [resolutionStr componentsSeparatedByString:@"x"];
        if (components.count == 2) {
          CGFloat width = [components[0] doubleValue];
          CGFloat height = [components[1] doubleValue];
          if (width > 0 && height > 0) {
            self.playerItem.preferredMaximumResolution = CGSizeMake(width, height);
          }
        }
      }
      else if ([bitrate doubleValue] == 0) [self setViewportResolution];
    }

    NSLog(@"[HLSPlayer] Set quality: %@, bitrate: %.0f", quality[@"name"], [bitrate doubleValue]);
  }
}

- (NSDictionary *)getCurrentQuality {
  double currentBitrate = self.playerItem.preferredPeakBitRate;
  if (currentBitrate == 0) {
    return @{@"name": @"Automatic", @"bitrate": @0, @"resolution": @"Auto"};
  }

  // Try to match current bitrate to available qualities
  NSArray *qualities = [self getAvailableQualities];
  for (NSDictionary *quality in qualities) {
    NSNumber *bitrate = quality[@"bitrate"];
    if (bitrate && [bitrate doubleValue] == currentBitrate) {
      return quality;
    }
  }

  // Return custom quality info
  NSString *name;
  if (currentBitrate >= 1000000) {
    name = [NSString stringWithFormat:@"%.1f Mbps", currentBitrate / 1000000.0];
  } else {
    name = [NSString stringWithFormat:@"%.0f Kbps", currentBitrate / 1000.0];
  }

  return @{@"name": name, @"bitrate": @(currentBitrate), @"resolution": @"Unknown"};
}

- (void)setViewportSize:(CGSize)size {
  _viewportSize = size;
  if (self.playerItem && self.playerItem.preferredPeakBitRate == 0) [self setViewportResolution];
}

- (void)accessLogEntry:(NSNotification *)notification {
  AVPlayerItem *item = notification.object;
  if (item != self.playerItem) return;

  AVPlayerItemAccessLog *accessLog = item.accessLog;
  if (!accessLog || accessLog.events.count == 0) return;

  AVPlayerItemAccessLogEvent *lastEvent = accessLog.events.lastObject;
  if (!lastEvent) return;

  double currentBitrate = lastEvent.indicatedBitrate;

  // Check if bitrate changed (indicates variant switch)
  if (currentBitrate > 0 && currentBitrate != self.lastIndicatedBitrate) {
    self.lastIndicatedBitrate = currentBitrate;

    // Try to get current resolution from video track
    CGSize currentResolution = CGSizeZero;

    // First, try to get from the actual playing tracks (item.tracks) rather than asset tracks
    NSArray<AVPlayerItemTrack *> *playerTracks = item.tracks;
    for (AVPlayerItemTrack *playerTrack in playerTracks) {
      if ([playerTrack.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) {
        NSArray *formatDescs = playerTrack.assetTrack.formatDescriptions;
        if (formatDescs.count > 0) {
          CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)formatDescs.firstObject;
          if (formatDesc) {
            currentResolution = CMVideoFormatDescriptionGetPresentationDimensions(formatDesc, true, false);
            if (!CGSizeEqualToSize(currentResolution, CGSizeZero)) {
              break; // Found resolution, exit loop
            }
          }
        }
      }
    }

    // If still not found, try matching bitrate to known variants
    if (CGSizeEqualToSize(currentResolution, CGSizeZero)) {
      if (@available(macOS 12.0, *)) {
        AVURLAsset *asset = (AVURLAsset *)item.asset;
        if ([asset isKindOfClass:[AVURLAsset class]] && [asset respondsToSelector:@selector(variants)]) {
          NSArray<AVAssetVariant *> *variants = asset.variants;
          if (variants && variants.count > 0) {
            // Find variant with matching bitrate
            for (AVAssetVariant *variant in variants) {
              double variantBitrate = variant.averageBitRate;
              if (variantBitrate <= 0) {
                variantBitrate = variant.peakBitRate;
              }

              // Match bitrate (allow small tolerance for floating point comparison)
              if (variantBitrate > 0 && fabs(variantBitrate - currentBitrate) < (variantBitrate * 0.1)) {
                AVAssetVariantVideoAttributes *videoAttrs = variant.videoAttributes;
                if (videoAttrs) {
                  currentResolution = videoAttrs.presentationSize;
                  if (!CGSizeEqualToSize(currentResolution, CGSizeZero)) {
                    break; // Found matching variant, exit loop
                  }
                }
              }
            }
          }
        }
      }
    }

    // If resolution is available and different, report the change
    if (!CGSizeEqualToSize(currentResolution, CGSizeZero)) {
      if (!CGSizeEqualToSize(currentResolution, self.lastResolution)) {
        self.lastResolution = currentResolution;

        if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeResolution:bitrate:)]) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate hlsPlayerDidChangeResolution:currentResolution bitrate:currentBitrate];
          });
        }

        NSLog(@"[HLSPlayer] Resolution changed to %.0fx%.0f, bitrate: %.0f bps",
              currentResolution.width, currentResolution.height, currentBitrate);
      }
    } else {
      // Resolution not available, but bitrate changed - still report it
      if ([self.delegate respondsToSelector:@selector(hlsPlayerDidChangeResolution:bitrate:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self.delegate hlsPlayerDidChangeResolution:CGSizeZero bitrate:currentBitrate];
        });
      }

      NSLog(@"[HLSPlayer] Bitrate changed to %.0f bps (resolution unknown)", currentBitrate);
    }
  }
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self.playerItem removeObserver:self forKeyPath:@"status"];
  [self.playerItem removeObserver:self forKeyPath:@"error"];
  [self.playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
  [self.playerItem removeObserver:self forKeyPath:@"seekableTimeRanges"];
  [self.playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
  [self.playerItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
  [self.playerItem removeObserver:self forKeyPath:@"duration"];
  [self.player removeObserver:self forKeyPath:@"rate"];
  if (self.frameTimer) {
    [self.frameTimer invalidate];
    self.frameTimer = nil;
  }
  [self.playerItem removeOutput:self.videoOutput];
}

@end
