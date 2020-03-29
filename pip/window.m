//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "img.h"
#import "common.h"
#import "window.h"

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

static NSUInteger kStyleMaskOnHoverIn = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
  | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
  | NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskUnifiedTitleAndToolbar | NSWindowStyleMaskFullSizeContentView
;

bool isInside(int rad, CGPoint cirlce, CGPoint point){
  if ((point.x - cirlce.x) * (point.x - cirlce.x) + (point.y - cirlce.y) * (point.y - cirlce.y) <= rad * rad) return true;
  else return false;
}

@interface WindowSel : NSObject{}
@property (nonatomic) NSString* owner;
@property (nonatomic) NSString* title;
@property (nonatomic) CGWindowID winId;
@end

@implementation WindowSel
@end

@interface NSImage (ImageAdditions)
+(NSImage *)swatchWithColor:(NSColor *)color size:(NSSize)size;
@end

@implementation NSImage (ImageAdditions)
+(NSImage *)swatchWithColor:(NSColor *)color size:(NSSize)size{
  NSImage *image = [[NSImage alloc] initWithSize:size];
  [image lockFocus];
  [color drawSwatchInRect:NSMakeRect(0, 0, size.width, size.height)];
  [image unlockFocus];
  return image;
}
@end

@implementation Button{
  int radius;
  bool wasMouseDown;
  NSImageView* view;
}

- (id) initWithRadius:(int)rad andImage:(NSImage*) img{
  radius = rad;
  wasMouseDown = false;
  int sideLen = radius * 2;
  self = [super initWithFrame:NSMakeRect(0, 0, sideLen, sideLen)];

  self.wantsLayer = true;
  self.layer.cornerRadius = radius;
  self.layer.backgroundColor = nil;

  self.state = NSVisualEffectStateActive;
  self.material = NSVisualEffectMaterialMenu;
  self.blendingMode = NSVisualEffectBlendingModeWithinWindow;

  self.maskImage = [NSImage swatchWithColor:[NSColor blackColor] size:NSMakeRect(0, 0, sideLen, sideLen).size];

  view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, sideLen, sideLen)];
  [self addSubview:view];
  [self setImage:img];

  return self;
}

- (void)setImage:(NSImage*) img{
  int iconLen = radius * 1.25;
  [img setSize:NSMakeSize(iconLen, iconLen)];
  [view setImage:img];
}

- (void)mouseUp:(NSEvent *)event{
  [self onMouse:false withEvent:event];
}

- (void)mouseDown:(NSEvent *)event{
  [self onMouse:true withEvent:event];
}

- (void)mouseDragged:(NSEvent *)event{
  [self onMouse:true withEvent:event];
}

- (void)onMouse:(bool)down withEvent:(NSEvent *)event{
  NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
  CGPoint circle = NSMakePoint(radius, radius);
  bool isValid = isInside(radius, circle, loc);
//  NSLog(@"onMouse %d,in: %d, cirlce: %f x %f, loc: %f x %f", down, isValid, circle.x, circle.y, loc.x, loc.y);
  
  if(isValid && down){
    wasMouseDown = true;
    self.state = NSVisualEffectStateInactive;
    self.layer.backgroundColor = [NSColor whiteColor].CGColor;
  }
  else{
    self.state = NSVisualEffectStateActive;
    self.layer.backgroundColor = nil;
    if(wasMouseDown && isValid) [self.delegate onClick:self];
    wasMouseDown = false;
  }
}

@end

@implementation RootView

- (void)rightMouseDown:(NSEvent *)theEvent{
  if(self.delegate)[self.delegate rightMouseDown:theEvent];
}

- (void)magnifyWithEvent:(NSEvent *)event{
  NSRect bounds = [self bounds];
  NSRect windowBounds = [[self.window screen] visibleFrame];

  float factor = [event magnification];
  float width = bounds.size.width + (bounds.size.width * factor);
  float height = bounds.size.height + (bounds.size.height * factor);
  if(windowBounds.size.width < width || windowBounds.size.height < height || width < kMinSize || height < kMinSize) return;

  NSRect windowRect = [[self window] frame];
  windowRect.size.width = width;
  windowRect.size.height = height;
  [self.window setFrame:windowRect display:YES];
}

@end

@implementation Window

- (id) init{
  pvc = nil;
  timer = NULL;
  window_id = 0;
  refreshRate = 30;
  shouldClose = false;
  isPipCLosing = false;

  self = [super initWithContentRect:kStartRect styleMask:kStyleMaskOnHoverIn backing:NSBackingStoreBuffered defer:YES];

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
  [self setBackgroundColor:[NSColor clearColor]];
  [self setMinSize:NSMakeSize(kMinSize, kMinSize)];
  [self setMaxSize:[[self screen] visibleFrame].size];

  [self setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];

  selectionView = [[SelectionView alloc] init];
  selectionView.selection = CGRectZero;
  selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  glView = [[OpenGLView alloc] initWithFrame:kStartRect];
  glView.delegate = self;
//  glView.wantsLayer = true;
//  glView.layer.masksToBounds = true;
//  [glView setNeedsLayout:true];
  glView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
  [glView setHidden:true];

  NSRect butContRect = NSMakeRect(0, 12, 100, 40);
  butCont = [[NSView alloc] initWithFrame:butContRect];
  butCont.translatesAutoresizingMaskIntoConstraints = false;

  popbutt = [[Button alloc] initWithRadius:20 andImage:GET_IMG(pop)];
  [popbutt setDelegate:self];
  [popbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([popbutt frame])) / 2) - 27, 0)];
  [butCont addSubview:popbutt];

  playbutt = [[Button alloc] initWithRadius:20 andImage:GET_IMG(play)];
  [playbutt setDelegate:self];
  [playbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([playbutt frame])) / 2) + 27, 0)];
  [butCont addSubview:playbutt];

  rootView = [[RootView alloc] initWithFrame:kStartRect];
  rootView.delegate = self;
  [rootView setMaterial:NSVisualEffectMaterialAppearanceBased];
  [rootView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
  [rootView setState:NSVisualEffectStateActive];
  rootView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

  [rootView addSubview:glView];
  [rootView addSubview:butCont];

  [rootView addConstraints:@[
    [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeCenterX multiplier:1 constant:-butContRect.origin.x],
    [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeBottom multiplier:1 constant:-butContRect.origin.y],
    [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeWidth multiplier:1 constant:butContRect.size.width],
    [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeHeight multiplier:1 constant:butContRect.size.height],
  ]];

  NSTrackingAreaOptions nstopts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside;
  NSTrackingArea *nstArea = [[NSTrackingArea alloc] initWithRect:[[self contentView] frame] options:nstopts owner:self userInfo:nil];

  [rootView addTrackingArea:nstArea];

  nvc = [[NSViewController alloc] init];
  [nvc setView:rootView];
  [self setContentViewController:nvc];

  [self onMouseEnter:false];
  [self setOnwer:@"PiP" withTitle:@"(right click to begin)"];

  return self;
}

- (BOOL) canBecomeKeyWindow{
  return YES;
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

- (void)togglePlayback{
  if(timer) [self stopTimer];
  else [self startTimer:1.0/refreshRate];
}

- (void)toggleNativePip{
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
  pvc = [[PIPViewController alloc] init];
  [pvc setDelegate:self];
  [pvc setUserCanResize:true];
  [pvc setReplacementRect:[self frame]];
  [pvc setAspectRatio:[self aspectRatio]];
  [pvc presentViewControllerAsPictureInPicture:nvc];

  [self resetPlaybackSate];
  [self setIsVisible:false];
  [self onMouseEnter:false];
}

- (void)onPiPResize{
  NSRect rect = [[[pvc view] window] frame];
  NSLog(@"onPiPResize %@", NSStringFromRect(rect));
}

- (void)stopPip:(bool) force{
  if(!pvc) return;
//  NSLog(@"stopPip %d", force);
  [pvc setDelegate:nil];
  [self setIsVisible:true];
  [self setContentViewController:nil];
  if(force) [pvc dismissViewController:nvc];
  NSRect rect = pvc.replacementRect;
  [[nvc view] setFrameSize:rect.size];
  [self setContentViewController:nvc];
  [self setAspectRatio:rect.size];
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
//  [pip setReplacementWindow:nil];
  [pip setReplacementRect:[self frame]];
}

- (void)pipWillClose:(PIPViewController *)pip{
//  NSLog(@"pipWillClose");
  isPipCLosing = true;
  [pvc dismissViewController:nvc];
}

- (void)pipDidClose:(PIPViewController *)pip{
//  NSLog(@"pipDidClose");
  [self stopPip:!isPipCLosing];
  isPipCLosing = false;
  if(shouldClose)[self close];
}

- (void) setSize:(CGSize)size andAspectRatio:(CGSize) ar{
  if(window_id == 0) return;
  if(pvc) [pvc setAspectRatio:ar];
  else{
    [self setAspectRatio:ar];
    [self setContentSize:size];
  }
}

- (void)stopTimer{
  if(timer) [timer invalidate];
  timer = nil;
  [self resetPlaybackSate];
}

- (void)startTimer:(double)interval{
//  NSLog(@"startTimer %f", interval);
  [self stopTimer];
  if(window_id == 0) return;
  timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(captrue) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  [self resetPlaybackSate];
}

- (void)captrue{
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
  [butCont setHidden:self.ignoresMouseEvents || pvc || !value];
  [[[[self standardWindowButton:NSWindowCloseButton] superview] animator] setAlphaValue:self.ignoresMouseEvents || !value ? 0 : value];
}

- (void)rightMouseDown:(NSEvent *)theEvent { 
  int layer = -1, index = 0;
  uint32_t windowId = 0;
  NSMenu *theMenu = [[NSMenu alloc] init];
  [theMenu setMinimumWidth:100];
  CFArrayRef all_windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);

  NSMenuItem* item = [theMenu addItemWithTitle:[NSString stringWithFormat:@"%snative pip", (pvc ? "exit " : "") ] action:@selector(toggleNativePip) keyEquivalent:@""];
  [item setTarget:self];

  if(!pvc){
    if(selectionView.selection.size.width == 0 && window_id != 0){
      NSMenuItem* item = [theMenu addItemWithTitle:@"select region" action:@selector(selectRegion:) keyEquivalent:@""];
      [item setTarget:self];
    }
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
    [slider setDoubleValue:[[nvc view] window].alphaValue];
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

//    NSLog(@"%@", (__bridge NSDictionary*)window_ref);

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

//  NSPoint loc = [rootView convertPoint:[theEvent locationInWindow] fromView:nil];
//  NSLog(@"onRightMouse loc: %f x %f", loc.x, loc.y);
  [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:rootView];
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
  [glView addSubview:selectionView];
  [[NSCursor crosshairCursor] set];
}

- (void)close{
//  NSLog(@"close window");
  if(pvc){
    NSRect rect = [[[pvc view] window] frame];
    rect.origin.x += rect.size.width / 2;
    rect.origin.y += rect.size.height / 2;
    rect.size.width = 0;
    rect.size.height = 0;
    [pvc setReplacementRect:rect];
  }
  [self stopPip:true];
  [self stopTimer];
  [self setContentViewController:nil];

  window_id = 0;
  popbutt.delegate = NULL;
  playbutt.delegate = NULL;

  [glView removeFromSuperview];
  [butCont removeFromSuperview];
  [popbutt removeFromSuperview];
  [playbutt removeFromSuperview];
  [selectionView removeFromSuperview];

  nvc = NULL;
  timer = NULL;
  rootView = NULL;
  glView = NULL;
  butCont = NULL;
  popbutt = NULL;
  playbutt = NULL;
  selectionView = NULL;

  [super close];
}

@end
