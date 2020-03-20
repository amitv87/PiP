//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "common.h"
#import "window.h"
#import "img.h"

#define pop_icon @"/Volumes/awsm/PiP/pop.png"
#define play_icon @"/Volumes/awsm/PiP/play.png"
#define pause_icon @"/Volumes/awsm/PiP/pause.png"

#define GET_IMG(x) [[NSImage alloc] initWithData:[NSData dataWithBytes:img_##x##_png length:img_##x##_png_len]]

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

bool isInside(int rad, CGPoint cirlce, CGPoint point){
  if ((point.x - cirlce.x) * (point.x - cirlce.x) + (point.y - cirlce.y) * (point.y - cirlce.y) <= rad * rad) return true;
  else return false;
}

@implementation Button{
  int radius;
  bool wasMouseDown;
  NSImageView* view;
}
- (id) initWithRadius:(int)rad andImage:(NSImage*) img{
  wasMouseDown = false;
  radius = rad;
  self = [super initWithFrame:NSMakeRect(0, 0, radius * 2, radius * 2)];
  self.wantsLayer = true;
  self.layer.masksToBounds = true;
  self.layer.cornerRadius = radius;
  view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, radius * 2, radius * 2)];
  [self setImage:img];
  [self addSubview:view];
  self.state = NSVisualEffectStateActive;
  self.material = NSVisualEffectMaterialTitlebar;
  self.blendingMode = NSVisualEffectBlendingModeWithinWindow ;
  return self;
}

- (void) setImage:(NSImage*) img{
  [img setSize:NSMakeSize(radius * 1.25, radius * 1.25)];
  [view setImage:img];
}

- (void)mouseDown:(NSEvent *)event{
  [self onMouse:true withEvent:event];
}

- (void)mouseUp:(NSEvent *)event{
  [self onMouse:false withEvent:event];
}

- (void)onMouse:(bool)down withEvent:(NSEvent *)event{
  NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
  CGFloat radius = self.layer.cornerRadius;
  CGPoint circle = NSMakePoint(radius, radius);
  bool isValid = isInside(radius, circle, loc);
//  NSLog(@"onMouse %d,in: %d, cirlce: %f x %f, loc: %f x %f", down, isValid, circle.x, circle.y, loc.x, loc.y);
//  self.material = down && isValid ? NSVisualEffectMaterialLight : NSVisualEffectMaterialTitlebar;
  
  if(isValid && down){
    wasMouseDown = true;
    self.material = NSVisualEffectMaterialLight;
  }
  else{
    self.material = NSVisualEffectMaterialTitlebar;
    if(wasMouseDown && isValid) [self.delegate onClick:self];
    wasMouseDown = false;
  }
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

  dummyView = [[NSVisualEffectView alloc] initWithFrame:kStartRect];
  [dummyView setMaterial:NSVisualEffectMaterialAppearanceBased];
  [dummyView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
  [dummyView setState:NSVisualEffectStateActive];
  dummyView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

  butCont = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 150, 40)];
  [butCont setFrameOrigin:NSMakePoint(round((NSWidth([glView bounds]) - NSWidth([butCont frame])) / 2) , 12)];
  [butCont setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];

  popbutt = [[Button alloc] initWithRadius:20 andImage:GET_IMG(pop)];
  [popbutt setDelegate:self];
  [popbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([popbutt frame])) / 2) - 27, 0)];
  [butCont addSubview:popbutt];

  playbutt = [[Button alloc] initWithRadius:20 andImage:GET_IMG(play)];
  [playbutt setDelegate:self];
  [playbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([playbutt frame])) / 2) + 27, 0)];

  [butCont addSubview:playbutt];
  [butCont setHidden:true];
  [glView addSubview:butCont];

  nvc = [[WindowViewController alloc] init];
  [nvc setWindowDelgate:self];
  [nvc setView:dummyView];
  [self setContentViewController:nvc];

  [[nvc view] addSubview:glView];
  
  NSTrackingAreaOptions nstopts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside;
  NSTrackingArea *nstArea = [[NSTrackingArea alloc] initWithRect:[[self contentView] frame] options:nstopts owner:self userInfo:nil];

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

- (void) onClick:(Button*)button{
  if(button == playbutt){
    if(timer) [self stopTimer];
    else [self startTimer:1.0/refreshRate];
  }
  else if(button == popbutt) [self toggleNativePip];
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
  if(pvc) pvc.playing = timer;
  if(timer) [playbutt setImage:GET_IMG(pause)];
  else [playbutt setImage:GET_IMG(play)];
}

- (void) startPiP{
//  NSLog(@"startPiP");
  if(nativePip)[nativePip toggleNativePip];
  bool doingAgain = false;
  doAgain:
  @try{
    pvc = [[PIPViewController alloc] init];
    [pvc setDelegate:self];
    [pvc setUserCanResize:true];
    [pvc setAspectRatio:[self aspectRatio]];
    [pvc presentViewControllerAsPictureInPicture:nvc];
    nativePip = self;
    [self resetPlaybackSate];
    [self setIsVisible:false];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPiPResize) name:NSWindowDidResizeNotification object:[[pvc view] window]];
  }
  @catch(NSException* err){
    NSLog(@"startPiP err %@", err);
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
  [self setIsVisible:true];
  pvc = nil;
  if(self == nativePip) nativePip = nil;
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
  [butCont setHidden:pvc || !value];
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
//  NSLog(@"setScale %ld", (long)scale);
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
//  NSLog(@"close window");
  [self stopPip:true];
  [self stopTimer];
  [self setContentViewController:nil];

  window_id = 0;
  popbutt.delegate = NULL;
  playbutt.delegate = NULL;

  [butCont removeFromSuperview];
  [popbutt removeFromSuperview];
  [playbutt removeFromSuperview];
  [selectionView removeFromSuperview];

  nvc = NULL;
  timer = NULL;
  glView = NULL;
  butCont = NULL;
  popbutt = NULL;
  playbutt = NULL;
  dummyView = NULL;
  selectionView = NULL;
  
  [super close];
}

@end
