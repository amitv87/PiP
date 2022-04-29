//
//  Window.h
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#ifndef Window_h
#define Window_h

#import "pip.h"
#import "imageView.h"
#import "preferences.h"
#import "selectionView.h"

@class VButton;

@protocol ButtonDelegate <NSObject>
- (void) onClick:(VButton*)button;
@end

@protocol RootViewDelegate <NSObject>
- (void)onDoubleClick:(NSEvent *)theEvent;
- (void)rightMouseDown:(NSEvent *)theEvent;
@end

@protocol WindowDelegate <NSObject>
- (void)togglePin;
- (void)togglePlayback;
- (void)toggleNativePip;
- (void)setScale:(id)sender;
@end

@interface RootView : NSVisualEffectView
@property (nonatomic) id<RootViewDelegate> delegate;
@end

@interface VButton : NSVisualEffectView
@property (nonatomic) id<ButtonDelegate> delegate;
@property (nonatomic) float imageScale;
- (id) initWithRadius:(int)radius andImage:(NSImage*) img andImageScale:(float)scale;
- (void) setImage:(NSImage*) img;
- (bool) getEnabled;
- (void) setEnable:(bool) en;
@end

@interface Window : NSPanel<NSWindowDelegate, SelectionViewDelegate, ImageRendererDelegate, WindowDelegate, RootViewDelegate, ButtonDelegate, PIPViewControllerDelegate>
@property (nonatomic) void* conn;
- (id) initWithAirplay:(bool)enable andTitle:(NSString*)title;
- (void) renderH264:(uint8_t*) data withLength:(size_t) length;
- (void) renderAudio:(uint8_t*) data withLength:(size_t) length;
- (void) setVolume:(float)volume;
- (void) setAudioInputFormat:(UInt32)format withsampleRate:(UInt32)sampleRate andChannels:(UInt32)channelCount andSPF:(UInt32)spf;
@end
#endif /* Window_h */
