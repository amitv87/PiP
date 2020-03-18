//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "common.h"
#import "window.h"

static Window* nativePiP = nil;

@implementation Window

- (id) init{
  pvc = nil;
  timer = NULL;
  window_id = 0;
  NSRect rect = NSMakeRect(0, 0, kStartSize, kStartSize);
//  NSUInteger mask = NSWindowStyleMaskTitled|NSWindowStyleMaskClosable;
  NSUInteger mask = NSWindowStyleMaskBorderless | NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskResizable;
  self = [super initWithContentRect:rect styleMask:mask backing:NSBackingStoreBuffered defer:YES];
  [self setAspectRatio:rect.size];
  [self setReleasedWhenClosed:NO];

  [self center];
  [self setMovable:YES];
  [self setShowsResizeIndicator:NO];
  [self setLevel: NSFloatingWindowLevel];
  [self setMinSize:NSMakeSize(kMinSize, kMinSize)];
  [self setMaxSize:[[self screen] visibleFrame].size];

  [self setDelegate:self];
  [self setRestorable:NO];
  [self setWindowController:NULL];
  [self makeKeyAndOrderFront:self];
  [self setMovableByWindowBackground:YES];

  nvc = [[NSViewController alloc] init];
  
  dummyView = [[NSView alloc] initWithFrame:rect];
  dummyView.wantsLayer = YES;
  dummyView.layer.backgroundColor = [NSColor blackColor].CGColor;
  dummyView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 250, 0)];
  [textView setFrameOrigin:NSMakePoint((NSWidth([dummyView bounds]) - NSWidth([textView frame])) / 2, (NSHeight([dummyView bounds]) - NSHeight([textView frame])) / 2)];
  [textView setString:@"Right click anywhere on the window"];
  [textView setEditable:NO];
  [textView setSelectable:NO];
  [textView setTextColor:[NSColor whiteColor]];
  [textView setAlignment:NSTextAlignmentCenter];
  [textView setBackgroundColor:[NSColor blackColor]];
  [textView setAutoresizingMask: NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin];

  [dummyView addSubview: textView];

  selectionView = [[SelectionView alloc] init];
  selectionView.selection = CGRectZero;
  selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  glView = [[OpenGLView alloc] initWithFrame:rect windowDelegate:self];
  [glView setWantsLayer: YES];
  [glView.layer setCornerRadius: 5];
  [glView.layer setMasksToBounds:YES];
  [glView setSubviews:@[dummyView]];
  [nvc setView:glView];

  [self setContentViewController:nvc];

  return self;
}

- (void) startPiP{
  if(nativePiP) [nativePiP stopPip];
  pvc = [[PIPViewController alloc] init];
  [pvc setDelegate:self];
  [pvc presentViewControllerAsPictureInPicture:nvc];
  [pvc setAspectRatio:[self aspectRatio]];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPiPResize) name:NSWindowDidResizeNotification object:[[pvc view] window]];
  [self setIsVisible:false];
  nativePiP = self;
}

- (void)stopPip{
  [pvc dismissViewController:nvc];
  [self pipDidClose:pvc];
}

- (void)pipDidClose:(PIPViewController *)pip{
  if(!pvc) return;
  [pvc setDelegate:nil];
  pvc = nil;
  [self setIsVisible:true];
  [self setContentViewController:nil];
  [self setContentViewController:nvc];
  if(nativePiP == self) nativePiP = nil;
}

- (void)onPiPResize{
  if(pvc) [self setContentSize:[[[pvc view] window] frame].size];
}

- (void) setSize:(CGSize)size andAspectRatio:(CGSize) ar{
  [self setAspectRatio:ar];
  [self setContentSize:size];
  if(pvc) [pvc setAspectRatio:ar];
}

- (BOOL) canBecomeKeyWindow{
  return YES;
}

- (void) start{
  if(timer != NULL) return;
  timer = [NSTimer timerWithTimeInterval:0.03f target:self selector:@selector(captrue:) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)captrue:(NSTimer *)timer{
  if(window_id == 0) return;
  CGImageRef window_image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window_id, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming);
  if(window_image != NULL){
    [glView drawImage:window_image withRect:selectionView.selection];
    CGImageRelease(window_image);
  }
  else
    window_id = 0;
}

- (void)rightMouseDown:(NSEvent *)theEvent { 
  int layer = -1, index = 0;
  uint32_t windowId = 0;
  NSMenu *theMenu = [[NSMenu alloc] init];
  [theMenu setMinimumWidth:100];
  CFArrayRef all_windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);

  if(!pvc){
    NSMenuItem* item = [theMenu addItemWithTitle:@"native pip" action:@selector(startPiP) keyEquivalent:@""];
    [item setTarget:self];

    if(selectionView.selection.size.width == 0 && window_id != 0){
      NSMenuItem* item = [theMenu addItemWithTitle:@"select region" action:@selector(selectRegion:) keyEquivalent:@""];
      [item setTarget:self];
    }
  }
  else{
    NSMenuItem* item = [theMenu addItemWithTitle:@"exit native pip" action:@selector(stopPip) keyEquivalent:@""];
    [item setTarget:self];
  }

  if(window_id != 0){
    NSMenuItem* item = [theMenu addItemWithTitle:@"clear window" action:@selector(changeWindow:) keyEquivalent:@""];
    [item setTag:0];
    [item setTarget:self];
  }

  if(!pvc){
    NSSlider* slider = [[NSSlider alloc] init];

    [slider setTarget:self];
    [slider setMinValue:0.1];
    [slider setMaxValue:1.0];
    [slider setDoubleValue:self.alphaValue];
    [slider setFrame:NSMakeRect(0, 0, 200, 30)];
    [slider setAction:@selector(adjustOpacity:)];
    [slider setAutoresizingMask:NSViewWidthSizable];

    NSMenuItem* itemSlider = [[NSMenuItem alloc] init];
    [itemSlider setEnabled:YES];
    [itemSlider setView:slider];
    [theMenu addItem:itemSlider];
  }

  [theMenu addItem:[NSMenuItem separatorItem]];

  for (CFIndex i = 0; i < CFArrayGetCount(all_windows); ++i) {
    CFDictionaryRef window_ref = (CFDictionaryRef)CFArrayGetValueAtIndex(all_windows, i);
    CFNumberRef id_ref = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowNumber);
    CFStringRef name_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowName);
    CFStringRef owner_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowOwnerName);
    CFNumberRef window_layer = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowLayer);

    CFNumberGetValue(id_ref, kCFNumberIntType, &windowId);
    CFNumberGetValue(window_layer, kCFNumberIntType, &layer);

    if(layer != 0) continue;

    CGImageRef window_image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, windowId, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming);
    if(window_image == NULL) continue;

    bool isFaulty = CGImageGetHeight(window_image) == 1 && CGImageGetWidth(window_image) == 1;
    CGImageRelease(window_image);
    if(isFaulty) continue;

    CFStringRef name = NULL;
    if(name_ref == NULL){
      name = CFStringCreateWithCString (NULL, "", kCFStringEncodingUTF8);;
    }

    NSString* windowTitle = [[(__bridge NSString*)owner_ref stringByAppendingString:@" - "] stringByAppendingString: (__bridge NSString*)(name_ref ? name_ref : name)];

    if(name) CFRelease(name);

    NSMenuItem* item = [theMenu addItemWithTitle:windowTitle action:@selector(changeWindow:) keyEquivalent:@""];
    [item setTarget:self];
    [item setTag:windowId];
    index += 1;
  }

  CFRelease(all_windows);

  [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:glView];
}

- (void) setScale:(NSInteger) scale{
  if(window_id > 0) [glView setScale:scale];
}

- (void)adjustOpacity:(id)sender{
  NSSlider* slider = (NSSlider*)sender;
  [self setAlphaValue:slider.doubleValue];
}

- (void)changeWindow:(id)sender{
  window_id = (CGWindowID)[sender tag];
  selectionView.selection = CGRectZero;
  if(window_id == 0){
    [dummyView setFrame:[glView bounds]];
    [self.contentView setSubviews:@[dummyView]];
  }
  else
    [dummyView removeFromSuperview];
}

- (void)selectRegion:(id)sender{
  [self setMovable:NO];
  [selectionView setFrameSize:NSMakeSize(glView.bounds.size.width, glView.bounds.size.height)];
  [self.contentView setSubviews:@[selectionView]];
  [[NSCursor crosshairCursor] set];
}

- (void)close{
  if(nativePiP == self){
    [nativePiP stopPip];
    return;
  }

  if(timer) [timer invalidate];

  nvc = NULL;
  timer = NULL;
  glView = NULL;
  window_id = 0;
  dummyView = NULL;
  selectionView = NULL;
  [self setContentViewController:nil];
  
  [super close];
}

@end
