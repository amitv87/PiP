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
#import "openGLView.h"
#import "selectionView.h"

@class Button;

@protocol ButtonDelegate <NSObject>
- (void) onClick:(Button*)button;
@end

@protocol RootViewDelegate <NSObject>
- (void)rightMouseDown:(NSEvent *)theEvent;
@end

@interface RootView : NSVisualEffectView
@property (nonatomic) id<RootViewDelegate> delegate;
@end

@interface Button : NSVisualEffectView
@property (nonatomic) id<ButtonDelegate> delegate;
- (id) initWithRadius:(int)radius andImage:(NSImage*) img;
- (void) setImage:(NSImage*) img;
@end

@interface Window : NSWindow<NSWindowDelegate, RootViewDelegate, GLDelegate, ButtonDelegate, PIPViewControllerDelegate>{
  NSTimer* timer;
  NSView* butCont;
  Button* popbutt;
  Button* playbutt;
  int refreshRate;
  bool shouldClose;
  bool isWinClosing;
  bool isPipCLosing;
  CGWindowID window_id;
  RootView* rootView;
  OpenGLView* glView;
  NSViewController* nvc;
  PIPViewController* pvc;
  SelectionView* selectionView;
}

- (void)togglePlayback;
- (void)toggleNativePip;
- (void)setScale:(NSInteger) scale;

@end
#endif /* Window_h */
