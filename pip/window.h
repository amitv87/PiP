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

@interface WindowViewController : NSViewController
@property (nonatomic) id<WindowDelegate> windowDelgate;
@end

@interface VisualEffectView : NSVisualEffectView
@end

@interface Window : NSWindow<NSWindowDelegate, WindowDelegate, PIPViewControllerDelegate>{
  NSTimer* timer;
  int refreshRate;
  bool shouldClose;
  bool isPipCLosing;
  NSTextView* textView;
  CGWindowID window_id;
  VisualEffectView* dummyView;
  OpenGLView* glView;
  PIPViewController* pvc;
  WindowViewController* nvc;
  SelectionView* selectionView;
}

- (void)toggleNativePip;
- (void)setScale:(NSInteger) scale;

@end
#endif /* Window_h */
