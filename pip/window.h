//
//  Window.h
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#ifndef Window_h
#define Window_h

#import "openGLView.h"
#import "selectionView.h"

@interface Window : NSWindow<NSWindowDelegate, RightCLickDelegate>{
    NSTimer* timer;
    CGWindowID window_id;
    NSView* dummyView;
    OpenGLView* glView;
    SelectionView* selectionView;
}

- (void) start;
- (void) setScale:(NSInteger) scale;
- (void) rightMouseDown:(NSEvent *) theEvent;

@end
#endif /* Window_h */
