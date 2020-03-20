//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "common.h"
#import "window.h"

static CGRect kStartRect = {
  .origin = {
    .x = 0,
    .y = 0,
  },
  .size = {
    .width = kStartSize,
    .height = kStartSize,
  },
};

static Window* nativePip = nil;

static NSUInteger kStyleMaskOnHoverIn = NSWindowStyleMaskBorderless | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskUnifiedTitleAndToolbar;

@interface WindowSel : NSObject{}
@property (nonatomic) NSString* owner;
@property (nonatomic) NSString* title;
@property (nonatomic) CGWindowID winId;
@end

@implementation WindowSel
@end

@implementation VisualEffectView
- (void)updateLayer{
//  NSLog(@"updateLayer");
  [super updateLayer];
  
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  
  CALayer *backdropLayer = self.layer.sublayers.firstObject;
  
  if ([backdropLayer.name hasPrefix:@"kCUIVariantMac"]) {
    for (CALayer *activeLayer in backdropLayer.sublayers) {
      if ([activeLayer.name isEqualToString:@"Active"]) {
        for (CALayer *sublayer in activeLayer.sublayers) {
          if ([sublayer.name isEqualToString:@"Backdrop"]) {
            for (id filter in sublayer.filters) {
              if ([filter respondsToSelector:@selector(name)] && [[filter name] isEqualToString:@"blur"]) {
                if ([filter respondsToSelector:@selector(setValue:forKey:)]) {
                  [filter setValue:@0.0001 forKey:@"inputRadius"];
                }
              }
            }
          }
        }
      }
    }
  }
  [CATransaction commit];
}
@end

@implementation WindowViewController
- (void)rightMouseDown:(NSEvent *)theEvent{
  if(_windowDelgate)[_windowDelgate rightMouseDown:theEvent];
}
@end

@implementation Window

- (id) init{
  pvc = nil;
  timer = NULL;
  window_id = 0;
  refreshRate = 30;
  shouldClose = false;

  self = [super initWithContentRect:kStartRect styleMask:kStyleMaskOnHoverIn backing:NSBackingStoreBuffered defer:YES];

//  [self center];
  [self setOpaque:NO];
  [self setMovable:YES];
  [self setDelegate:self];
  [self setReleasedWhenClosed:NO];
  [self makeKeyAndOrderFront:self];
  [self setShowsResizeIndicator:NO];
  [self setContentSize:kStartRect.size];
  [self setAspectRatio:kStartRect.size];
  [self setLevel: NSFloatingWindowLevel];
  [self setMovableByWindowBackground:YES];
  [self setTitlebarAppearsTransparent:true];
  [self setMinSize:NSMakeSize(kMinSize, kMinSize)];
  [self setMaxSize:[[self screen] visibleFrame].size];
  [self setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];

  selectionView = [[SelectionView alloc] init];
  selectionView.selection = CGRectZero;
  selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  glView = [[OpenGLView alloc] initWithFrame:kStartRect windowDelegate:self];
  glView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
  [glView setHidden:true];

  dummyView = [[VisualEffectView alloc] initWithFrame:kStartRect];
  [dummyView setMaterial:NSVisualEffectMaterialAppearanceBased];
  [dummyView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
  [dummyView setState:NSVisualEffectStateActive];
  dummyView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
//  [dummyView setWantsLayer:YES];
//  [dummyView setNeedsLayout:YES];

  nvc = [[WindowViewController alloc] init];
  [nvc setWindowDelgate:self];
  [nvc setView:dummyView];
  [self setContentViewController:nvc];

  [[nvc view] addSubview:glView];
  
  NSTrackingAreaOptions nstopts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside;
  NSTrackingArea *nstArea = [[NSTrackingArea alloc] initWithRect:[[self contentView] frame] options:nstopts owner:self userInfo:nil];

//  [glView addTrackingArea:nstArea];
  [dummyView addTrackingArea:nstArea];

  [self setOnwer:@"PiP" withTitle:@"(right click to begin)"];

  [self onMouseEnter:false];
//  [[[[self standardWindowButton:NSWindowCloseButton] superview] layer] setBackgroundColor:[[[NSColor blackColor] colorWithAlphaComponent:0.1] CGColor]];

  return self;
}

- (void)setOnwer:(NSString*)owner withTitle:(NSString*) title{
  if(window_id) [self setTitle:@""];
  else [self setTitle:[NSString localizedStringWithFormat:@"%@ - %@", owner, title]];
}

- (void)mouseEntered:(NSEvent *)event{
  [self onMouseEnter:true];
}

- (void)mouseExited:(NSEvent *)event{
  [self onMouseEnter:false];
}

- (void) toggleNativePip{
  if(isPipCLosing) return;
  if(pvc){
    [self pipActionReturn:pvc];
    [self pipWillClose:pvc];
  }
  else [self startPiP];
}

- (void)resetPlaybackSate{
  if(pvc) pvc.playing = !!timer;
}

- (void) startPiP{
//  NSLog(@"startPiP");
  if(nativePip)[nativePip toggleNativePip];
  bool doingAgain = false;
  doAgain:
  @try{
    pvc = [[PIPViewController alloc] init];
    [pvc setDelegate:self];
    [pvc presentViewControllerAsPictureInPicture:nvc];
    [pvc setAspectRatio:[self aspectRatio]];
//    [pvc setUserCanResize:true];
//    [pvc setUseAutoLayout:true];
//    [pvc setPresentOnResize:true];
    [self resetPlaybackSate];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPiPResize) name:NSWindowDidResizeNotification object:[[pvc view] window]];
    [self setIsVisible:false];
    nativePip = self;
  }
  @catch(NSException* err){
//    NSLog(@"startPiP err %@", err);
    [self stopPip:true];
    if(!doingAgain){
      doingAgain = true;
      goto doAgain;
    }
  }
}

- (void)stopPip:(bool) force{
  if(!pvc) return;
//  NSLog(@"stopPip %d", force);
  [pvc setDelegate:nil];
  if(force) [pvc dismissViewController:nvc];
  [self setContentViewController:nil];
  [self setContentViewController:nvc];
  if(self == nativePip) nativePip = nil;
  [self setIsVisible:true];
  pvc = nil;
}

- (void)pipActionStop:(PIPViewController *)pip{
//  NSLog(@"pipActionStop");
  shouldClose = true;
}

- (void)pipActionPause:(PIPViewController *)pip{
//  NSLog(@"pipActionPause");
  [self stopTimer];
}

- (void)pipActionPlay:(PIPViewController *)pip{
//  NSLog(@"pipActionPlay");
  if(window_id) [self startTimer:1.0/refreshRate];
  else [self stopTimer];
}

- (void)pipActionReturn:(PIPViewController *)pip{
//  NSLog(@"pipActionReturn");
  shouldClose = false;
  [pip setReplacementWindow:nil];
  [pip setReplacementRect:[self frame]];
}

- (void)pipWillClose:(PIPViewController *)pip{
//  NSLog(@"pipWillClose");
  isPipCLosing = true;
  [pvc dismissViewController:nvc];
}

- (void)pipDidClose:(PIPViewController *)pip{
//  NSLog(@"pipDidClose");
  isPipCLosing = false;
  [self stopPip:false];
  if(shouldClose)[self close];
}

- (void)onPiPResize{
  NSView* view = [pvc view];
  if(pvc) [self setContentSize:[view frame].size];
}

- (void) setSize:(CGSize)size andAspectRatio:(CGSize) ar{
  if(window_id == 0) return;
  if(pvc){
    [pvc setAspectRatio:ar];
    [[pvc view] setFrameSize:size];
    [[[pvc view] window] setContentSize:size];
  }
  else{
    [self setAspectRatio:ar];
    [self setContentSize:size];
  }
//  if(pvc) [[nvc view] setFrameSize:size];
}

- (BOOL) canBecomeKeyWindow{
  return YES;
}

- (void)stopTimer{
  if(timer) [timer invalidate];
  timer = nil;
  [self resetPlaybackSate];
}

- (void)startTimer:(double)interval{
//  NSLog(@"startTimer %f", interval);
  [self stopTimer];
  timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(captrue) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  [self resetPlaybackSate];
}

- (void)captrue{
  if(window_id == 0) return;
  CGImageRef window_image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window_id, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming);
  if(window_image != NULL){
    bool rc = [glView drawImage:window_image withRect:selectionView.selection];
    CGImageRelease(window_image);
    if(rc){
      if(timer && [timer timeInterval] != 1.0/refreshRate) [self startTimer:1.0/refreshRate];
      return;
    }

    CGWindowID _windowArr[] = { window_id };
    CFArrayRef windowArr = CFArrayCreate(NULL, (const void **) _windowArr, 1, NULL);
    CFArrayRef result = CGWindowListCreateDescriptionFromArray(windowArr);
    CFRelease(windowArr);

    if (result && CFArrayGetCount(result) == sizeof(_windowArr)/sizeof(CGWindowID)){
      CFRelease(result);
      if(timer && [timer timeInterval] != 1.0) [self startTimer:1.0];
      return;
    }
    if(result) CFRelease(result);
  }

  NSMenuItem* item = [[NSMenuItem alloc] init];
  [item setTarget:self];
  WindowSel* sel = [[WindowSel alloc] init];
  sel.owner = @"PiP";
  sel.title = @"(right click to begin)";
  sel.winId = 0;
  [item setRepresentedObject:sel];
  [self changeWindow:item];
}

- (void)onMouseEnter:(BOOL)value{  
  [[[[self standardWindowButton:NSWindowCloseButton] superview] animator] setAlphaValue:value];
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
    NSMenuItem* item = [theMenu addItemWithTitle:@"exit native pip" action:@selector(toggleNativePip) keyEquivalent:@""];
    [item setTarget:self];
  }

  if(window_id != 0){
    NSMenuItem* item = [theMenu addItemWithTitle:@"clear window" action:@selector(changeWindow:) keyEquivalent:@""];
    [item setTarget:self];
    WindowSel* sel = [[WindowSel alloc] init];
    sel.owner = @"PiP";
    sel.title = @"(right click to begin)";
    sel.winId = 0;
    [item setRepresentedObject:sel];
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
    
//    NSLog(@"app:%@, window: %@, layer:%d", (__bridge NSString*)owner_ref, (__bridge NSString*)name_ref, layer);
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
    
    WindowSel* sel = [[WindowSel alloc] init];
    sel.owner = (__bridge NSString*)owner_ref;
    sel.title = (__bridge NSString*)name_ref;
    sel.winId = windowId;
    [item setRepresentedObject:sel];
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
  WindowSel* sel = [sender representedObject];

  window_id = sel.winId;
  selectionView.selection = CGRectZero;
  [glView setHidden:window_id == 0];
  [self setOnwer:sel.owner withTitle:sel.title];

  if(window_id)[self startTimer:1.0/refreshRate];
  else [self stopTimer];
}

- (void)selectRegion:(id)sender{
  [self setMovable:NO];
  [selectionView setFrameSize:NSMakeSize(glView.bounds.size.width, glView.bounds.size.height)];
  [self.contentView addSubview:selectionView];
  [[NSCursor crosshairCursor] set];
}

- (void)close{
  NSLog(@"close window");
  [self stopPip:true];

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
