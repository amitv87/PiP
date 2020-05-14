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
#import "selectionView.h"

@class Button;

@protocol ButtonDelegate <NSObject>
- (void) onClick:(Button*)button;
@end

@protocol RootViewDelegate <NSObject>
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

@interface Button : NSVisualEffectView
@property (nonatomic) id<ButtonDelegate> delegate;
@property (nonatomic) float imageScale;
- (id) initWithRadius:(int)radius andImage:(NSImage*) img andImageScale:(float)scale;
- (void) setImage:(NSImage*) img;
- (bool) getEnabled;
- (void) setEnable:(bool) en;
@end

@interface Window : NSPanel<NSWindowDelegate, SelectionViewDelegate, ImageRendererDelegate, WindowDelegate, RootViewDelegate, ButtonDelegate, PIPViewControllerDelegate>
@end
#endif /* Window_h */
