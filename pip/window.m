//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "cgs.h"
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

static const bool shouldEnableFullScreen = false;

static NSWindowStyleMask kWindowMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
  | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
  | NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskUnifiedTitleAndToolbar | NSWindowStyleMaskFullSizeContentView
  | NSWindowStyleMaskNonactivatingPanel
;

bool isInside(int rad, CGPoint cirlce, CGPoint point){
  if ((point.x - cirlce.x) * (point.x - cirlce.x) + (point.y - cirlce.y) * (point.y - cirlce.y) <= rad * rad) return true;
  else return false;
}

void setWindowSize(NSWindow* window, NSRect windowRect, NSRect screenRect, NSSize size, bool animate){
  float screenWidth = screenRect.origin.x + screenRect.size.width;
  float screenHeight = screenRect.origin.y + screenRect.size.height;

  if(windowRect.origin.x + windowRect.size.width == screenWidth)
    windowRect.origin.x += windowRect.size.width - size.width;
  else{
    float clippingWidth = screenWidth - (windowRect.origin.x + size.width);
    if(clippingWidth < 0) windowRect.origin.x += clippingWidth;
  }

  if(windowRect.origin.y + windowRect.size.height == screenHeight)
    windowRect.origin.y += windowRect.size.height - size.height;
  else{
    float clippingHeight = screenHeight - (windowRect.origin.y + size.height);
    if(clippingHeight < 0) windowRect.origin.y += clippingHeight;
  }

  if(windowRect.origin.x < screenRect.origin.x) windowRect.origin.x = screenRect.origin.x;
  if(windowRect.origin.y < screenRect.origin.y) windowRect.origin.y = screenRect.origin.y;

  windowRect.size = size;

  [window setFrame:windowRect display:YES animate:animate];
}

@interface WindowSel : NSObject{}
@property (nonatomic) NSString* owner;
@property (nonatomic) NSString* title;
@property (nonatomic) CGWindowID winId;
@end

@implementation WindowSel
@end

static CGImageRef CaptureWindow(CGWindowID wid){
  CGImageRef window_image = NULL;
  CFArrayRef window_image_arr = NULL;
  window_image_arr = CGSHWCaptureWindowList(CGSMainConnectionID(), &wid, 1, kCGSCaptureIgnoreGlobalClipShape | kCGSWindowCaptureNominalResolution);
  if(window_image_arr) window_image = (CGImageRef)CFArrayGetValueAtIndex(window_image_arr, 0);
  if(!window_image) window_image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, wid, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming);
  return window_image;
}

@interface NSImage (ImageAdditions)
+(NSImage *)swatchWithColor:(NSColor *)color size:(NSSize)size;
@end

@implementation NSImage (ImageAdditions)
+(NSImage *)swatchWithColor:(NSColor *)color size:(NSSize)size{
  NSImage *image = [[NSImage alloc] initWithSize:size];
  [image lockFocus];
  [color set];
  NSBezierPath *rectPath = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, size.width, size.height)];
  [rectPath fill];
  [image unlockFocus];
  return image;
}
@end

@interface CircularButton : NSButton
- (instancetype)initWithRadius:(int)rad;
@end

@implementation CircularButton{
  int radius;
}
- (instancetype)initWithRadius:(int)rad{
  radius = rad;
  int sideLen = radius * 2;
  self = [super initWithFrame:NSMakeRect(0, 0, sideLen, sideLen)];
  return self;
}

- (bool)isVaid:(NSEvent *)event{
  NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
  CGPoint circle = NSMakePoint(radius, radius);
  bool isValid = isInside(radius, circle, loc);
  return isValid;
}

- (void)mouseUp:(NSEvent *)event{
  if([self isVaid:event]) [super mouseUp:event];
}

- (void)mouseDown:(NSEvent *)event{
  if([self isVaid:event]) [super mouseDown:event];
}

- (void)drawRect:(NSRect)dirtyRect{
  NSColor* target = self.isHighlighted ? [NSColor whiteColor] : [NSColor clearColor];
  self.layer.backgroundColor = target.CGColor;
  [super drawRect:dirtyRect];
}

@end

@implementation Button{
  int radius;
  NSButton* button;
}

- (id) initWithRadius:(int)rad andImage:(NSImage*) img andImageScale:(float)scale{
  radius = rad;
  int sideLen = radius * 2;
  self = [super initWithFrame:NSMakeRect(0, 0, sideLen, sideLen)];

  self.imageScale = scale;
  self.wantsLayer = true;
  self.layer.cornerRadius = radius;
  self.layer.backgroundColor = nil;

  self.state = NSVisualEffectStateActive;
  self.material = NSVisualEffectMaterialLight;
  self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  self.maskImage = [NSImage swatchWithColor:[NSColor blackColor] size:NSMakeRect(0, 0, sideLen, sideLen).size];

  button = [[CircularButton alloc] initWithRadius:radius];
  [button setButtonType:NSMomentaryChangeButton];
  [button setBordered:NO];
  [button setAction:@selector(onClick:)];
  [button setTarget:self];
  [self addSubview:button];

  if(img) [self setImage:img];

  return self;
}

- (void)setImage:(NSImage*) img{
  int iconLen = radius * self.imageScale;
  [img setSize:NSMakeSize(iconLen, iconLen)];
  [button setImage:img];
  [button setImagePosition:NSImageOnly];
}

-(void)onClick:(id)sender{
  [self.delegate onClick:self];
}

- (void) setEnable:(bool) en{
  button.enabled = en;
}

- (bool) getEnabled{
  return button.isEnabled;
}

@end

@implementation NSWindow (FullScreen)
- (BOOL)isFullScreen{
  return (([self styleMask] & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen);
}
@end

@implementation RootView

- (void)rightMouseDown:(NSEvent *)theEvent{
  if(self.delegate)[self.delegate rightMouseDown:theEvent];
}

- (void)magnifyWithEvent:(NSEvent *)event{
  if([self.window isFullScreen]) return;
  NSSize ar = self.window.aspectRatio;
  NSRect windowRect = [self.window frame];
  NSRect screenRect = [[self.window screen] visibleFrame];

  float width, height, scale = [event magnification] + 1;

  if(ar.width * ar.height == 0){
    width = windowRect.size.width * scale;
    height = windowRect.size.height * scale;
  }
  else{
    width = windowRect.size.width * scale;
    height = (width * ar.height / ar.width);
  }

  if(screenRect.size.width < width || screenRect.size.height < height || (width < kMinSize && height < kMinSize)) return;

  setWindowSize(self.window, windowRect, screenRect, NSMakeSize(width, height), false);
}

@end

@implementation Window{
  NSTimer* timer;
  NSView* butCont;
  Button* pinbutt;
  Button* popbutt;
  Button* playbutt;
  float contentAR;
  int refreshRate;
  bool shouldClose;
  bool isWinClosing;
  bool isPipCLosing;
  CGWindowID window_id;
  RootView* rootView;
  NSViewController* nvc;
  PIPViewController* pvc;
  SelectionView* selectionView;
  NSTitlebarAccessoryViewController* tbavc;

  ImageView* imageView;
}

- (id) init{
  pvc = nil;
  timer = NULL;
  window_id = 0;
  refreshRate = 30;
  shouldClose = false;
  isWinClosing = false;
  isPipCLosing = false;

  self = [super initWithContentRect:kStartRect styleMask:kWindowMask backing:NSBackingStoreBuffered defer:YES];

  NSRect screenRect = [[self screen] visibleFrame];
  NSPoint point = NSMakePoint(
    screenRect.origin.x + screenRect.size.width - kStartRect.size.width,
    screenRect.origin.y
//    + screenRect.size.height - kStartRect.size.height
  );
  [self setFrameOrigin:point];

  self.opaque = YES;
  self.movable = YES;
  self.delegate = self;
  self.releasedWhenClosed = NO;
  self.level = NSFloatingWindowLevel;
  self.movableByWindowBackground = YES;
  self.titlebarAppearsTransparent = true;
  self.aspectRatio = kStartRect.size;
  self.minSize = NSMakeSize(kMinSize, kMinSize);
  self.maxSize = [[self screen] visibleFrame].size;
  self.preservesContentDuringLiveResize = false;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle |
  (shouldEnableFullScreen ? NSWindowCollectionBehaviorFullScreenPrimary : NSWindowCollectionBehaviorFullScreenAuxiliary);

  [self makeKeyAndOrderFront:self];

  selectionView = [[SelectionView alloc] init];
  selectionView.delegate = self;
  selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  float butScale = 2;
  int buttonRadius = 20;
  NSRect butContRect = NSMakeRect(0, 12, (buttonRadius * 4) + 20, buttonRadius * 2);
  butCont = [[NSView alloc] initWithFrame:butContRect];
  butCont.translatesAutoresizingMaskIntoConstraints = false;

  #define NSColorFromRGB(rgbValue, opacity) [NSColor colorWithRed:((float)((rgbValue & 0xFF0000) >> 16))/255.0 \
    green:((float)((rgbValue & 0xFF00) >> 8))/255.0 blue:((float)(rgbValue & 0xFF))/255.0 alpha:opacity]

  popbutt = [[Button alloc] initWithRadius:buttonRadius andImage:GET_IMG(pop) andImageScale:butScale];
  [popbutt setDelegate:self];
  [popbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([popbutt frame])) / 2) - (buttonRadius + 7.5), 0)];
  [butCont addSubview:popbutt];

  playbutt = [[Button alloc] initWithRadius:buttonRadius andImage:GET_IMG(play) andImageScale:butScale];
  [playbutt setDelegate:self];
  [playbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([playbutt frame])) / 2) + (buttonRadius + 7.5), 0)];
  [butCont addSubview:playbutt];

  int ppbutradius = 6.5;
  float butspacing = ppbutradius * 3;
  pinbutt = [[Button alloc] initWithRadius:ppbutradius andImage:nil andImageScale:1.8];
  [pinbutt setFrameOrigin:NSMakePoint(0 * butspacing, 5)];
  [pinbutt setDelegate:self];
  [self setupPushPin:false];

  NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1 * butspacing, 0)];
  [view addSubview:pinbutt];

  tbavc = [[NSTitlebarAccessoryViewController alloc] init];
  tbavc.view = view;
  tbavc.layoutAttribute = NSLayoutAttributeTrailing;
  [self addTitlebarAccessoryViewController:tbavc];

  rootView = [[RootView alloc] initWithFrame:kStartRect];
  rootView.delegate = self;
  [rootView setMaterial:NSVisualEffectMaterialAppearanceBased];
  [rootView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
  [rootView setState:NSVisualEffectStateActive];
  rootView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

  imageView = [[ImageView alloc] initWithFrame:kStartRect];
  imageView.renderer = [[MetalRenderer alloc] init];
  imageView.renderer.delegate = self;
  imageView.hidden = true;
  [rootView addSubview:imageView];

  [rootView addSubview:butCont];

  NSLayoutConstraint* constCentX = [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeCenterX multiplier:1 constant:-butContRect.origin.x];
  NSLayoutConstraint* constBottom = [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeBottom multiplier:1 constant:-butContRect.origin.y];
  NSLayoutConstraint* constWindth = [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeWidth multiplier:1 constant:butContRect.size.width];
  NSLayoutConstraint* constHeight = [NSLayoutConstraint constraintWithItem:butCont attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeHeight multiplier:1 constant:butContRect.size.height];

  [rootView addConstraints:@[constCentX, constBottom, constWindth, constHeight]];

  NSTrackingAreaOptions nstopts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside;
  NSTrackingArea *nstArea = [[NSTrackingArea alloc] initWithRect:[[self contentView] frame] options:nstopts owner:self userInfo:nil];

  [rootView addTrackingArea:nstArea];

  nvc = [[NSViewController alloc] init];
  [nvc setView:rootView];
  [self setContentViewController:nvc];

//  [self onMouseEnter:false];
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
  if(button == playbutt) [self togglePlayback];
  else if(button == popbutt) [self toggleNativePip];
  else if(button == pinbutt) [self togglePin];
}

- (void)mouseEntered:(NSEvent *)event{
  [self onMouseEnter:true];
}

- (void)mouseExited:(NSEvent *)event{
  [self onMouseEnter:false];
}

- (void)onMouseEnter:(BOOL)value{
  bool alphaVal = value;
  if([self isFullScreen]) alphaVal = true;
  if(pvc) alphaVal = false;
  if(self.ignoresMouseEvents) alphaVal = false;
  [[butCont animator] setAlphaValue:alphaVal];
  [[[[self standardWindowButton:NSWindowCloseButton] superview] animator] setAlphaValue:alphaVal];
}

- (void)setupPushPin:(bool)active{
  [pinbutt setImage:active ? GET_IMG(pinned) : GET_IMG(pin)];
}

- (void)togglePin{
  if(![pinbutt getEnabled]) return;
  bool isPinned = (self.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces) == NSWindowCollectionBehaviorCanJoinAllSpaces;
  if(isPinned){
    self.collectionBehavior &= ~NSWindowCollectionBehaviorCanJoinAllSpaces;
    if(shouldEnableFullScreen){
      self.collectionBehavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
      self.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    }
  }
  else{
    if(shouldEnableFullScreen){
      self.collectionBehavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
      self.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    self.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
  }
  [self setupPushPin:!isPinned];
}

- (void)resetWindow:(bool) fromPiPEvent{
  if(!fromPiPEvent && pvc) return;
  if([self isFullScreen]){
    [pinbutt setEnable:false];
    contentAR = self.aspectRatio.width * self.aspectRatio.height != 0 ? self.aspectRatio.width / self.aspectRatio.height : 0;
    NSRect screenRect = [[self screen] frame];
    if(contentAR >= 0.1){
      NSSize size = screenRect.size;
      size = NSMakeSize(fmin(size.height * contentAR, size.width), fmin(size.width / contentAR, size.height));
      if(screenRect.size.width > size.width) screenRect.origin.x = (screenRect.size.width - size.width) / 2;
      if(screenRect.size.height > size.height) screenRect.origin.y = (screenRect.size.height - size.height) / 2;
      screenRect.size = size;
    }
    [self setMaxSize:screenRect.size];
    [self setFrame:screenRect display:YES];
  }
  else{
    [pinbutt setEnable:true];
    [self setMaxSize:[[self screen] visibleFrame].size];
  }
}

- (void)windowDidChangeScreen:(NSNotification *)notification{
  [self resetWindow:false];
}

- (void)windowDidChangeScreenProfile:(NSNotification *)notification{
  [self resetWindow:false];
}

- (void)togglePlayback{
  if(isWinClosing) return;
  if(timer) [self stopTimer];
  else [self startTimer:1.0/refreshRate];
}

- (void)toggleNativePip{
  if(isWinClosing || isPipCLosing) return;
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
  [pvc setReplacementWindow:nil];
  [pvc setReplacementRect:[self frame]];
  [pvc setAspectRatio:[self aspectRatio]];
  [pvc presentViewControllerAsPictureInPicture:nvc];
  [self resetPlaybackSate];
  [self onMouseEnter:false];
  [self setIsVisible:false];
}

- (void)stopPip:(bool) force{
  if(!pvc) return;
//  NSLog(@"stopPip %d", force);
  [pvc setDelegate:nil];
  if(force) [pvc dismissViewController:nvc];
  NSRect rect = pvc.replacementRect;
  pvc = nil;
  [self setContentViewController:nil];
  [self setContentViewController:nvc];
  [self setAspectRatio:rect.size];
  [self setFrame:rect display:YES];
  [self setIsVisible:true];
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
  [self resetWindow:true];
  NSRect rect = [self frame];
  NSSize ar = [pip aspectRatio];
  if(ar.width * ar.height != 0) rect.size.height = rect.size.width * ar.height / ar.width;
  [pip setReplacementRect:rect];
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
  if(shouldClose)[self performClose:self];
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

- (void)onResize:(CGSize)size andAspectRatio:(CGSize) ar{
  if(window_id == 0) return;
  [self setAspectRatio:ar];
  if(pvc) [pvc setAspectRatio:ar];
  else{
    [self resetWindow:false];
    if([self isFullScreen]) return;
    setWindowSize(self, self.frame, self.screen.visibleFrame, size, false);
  }
}

- (void) onSelcetion:(NSRect) rect{
  [imageView.renderer setCropRect:rect];
}

- (void)captrue{
  CGImageRef window_image = CaptureWindow(window_id);
  if(window_image != NULL){
    CIImage* ciimage = [CIImage imageWithCGImage:window_image];
    CGRect imageRect = [ciimage extent];
    bool rc = imageRect.size.height * imageRect.size.width > 1;

//    imageView.renderer.cropRect = selectionView.selection;
    if(rc) [imageView setImage:ciimage];
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
  else return;

  NSMenuItem* item = [[NSMenuItem alloc] init];
  [item setTarget:self];
  WindowSel* sel = [[WindowSel alloc] init];
  sel.owner = @"PiP";
  sel.title = @"(right click to begin)";
  sel.winId = 0;
  [item setRepresentedObject:sel];
  [self changeWindow:item];
}

- (void)rightMouseDown:(NSEvent *)theEvent {
  NSMenu *theMenu = [[NSMenu alloc] init];
  [theMenu setMinimumWidth:100];
  NSMenuItem* item = [theMenu addItemWithTitle:[NSString stringWithFormat:@"%snative pip", (pvc ? "exit " : "") ] action:@selector(toggleNativePip) keyEquivalent:@""];
  [item setTarget:self];

  if(!pvc){
    NSSize cropSize = [imageView.renderer cropRect].size;
    if(cropSize.width * cropSize.height == 0 && window_id != 0){
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

  uint32_t windowId = 0;
  CFArrayRef all_windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);

  for (CFIndex i = 0; i < CFArrayGetCount(all_windows); ++i) {
    CFDictionaryRef window_ref = (CFDictionaryRef)CFArrayGetValueAtIndex(all_windows, i);

    int layer = -1;
    CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowLayer), kCFNumberIntType, &layer);
    if(layer != 0) continue;

    CFNumberRef id_ref = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowNumber);
    CFNumberGetValue(id_ref, kCFNumberIntType, &windowId);

    bool isFaulty = true;
    CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue (window_ref, kCGWindowBounds);
    if(bounds){
      NSRect rect = NSZeroRect;
      CGRectMakeWithDictionaryRepresentation(bounds, &rect);
      isFaulty = rect.size.width <= 1 && rect.size.height <= 1;
      if(!isFaulty){
        CFArrayRef spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), kCGSAllSpacesMask, (__bridge CFArrayRef)@[[NSNumber numberWithInt:windowId]]);
        if(spaces){
          CFIndex ans = CFArrayGetCount(spaces);
          CFRelease(spaces);
          isFaulty = !ans;
        }
      }
    }
    else{
      CGImageRef window_image = CaptureWindow(windowId);
      if(window_image == NULL) continue;
      isFaulty = CGImageGetHeight(window_image) == 1 && CGImageGetWidth(window_image) == 1;
      CGImageRelease(window_image);
    }

    if(isFaulty) continue;

    CFStringRef name_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowName);

//    NSLog(@"%@", (__bridge NSDictionary*)window_ref);

    CFStringRef owner_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowOwnerName);

    NSString* windowTitle = [[(__bridge NSString*)owner_ref stringByAppendingString:@" - "] stringByAppendingString: name_ref ? (__bridge NSString*)name_ref : @""];

    NSMenuItem* item = [theMenu addItemWithTitle:windowTitle action:@selector(changeWindow:) keyEquivalent:@""];
    [item setTarget:self];

    WindowSel* sel = [[WindowSel alloc] init];
    sel.owner = (__bridge NSString*)owner_ref;
    sel.title = (__bridge NSString*)name_ref;
    sel.winId = windowId;
    [item setRepresentedObject:sel];
  }

  CFRelease(all_windows);
  [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:rootView];
}

- (void)setScale:(id)sender{
  if(window_id > 0) [imageView.renderer setScale:[sender tag]];
}

- (void)adjustOpacity:(id)sender{
  NSSlider* slider = (NSSlider*)sender;
  [self setAlphaValue:slider.doubleValue];
}

- (void)changeWindow:(id)sender{
//  NSLog(@"changeWindow");
  WindowSel* sel = [sender representedObject];

  if(!sel.winId){
    NSSize size = [self frame].size;
    size.height = size.width;
    [self onResize:size andAspectRatio:kStartRect.size];
  }

  window_id = sel.winId;
  [self startTimer:1.0/refreshRate];

  [imageView setImage:nil];
  [imageView setHidden:window_id == 0];
  [self setOnwer:sel.owner withTitle:sel.title];
}

- (void)selectRegion:(id)sender{
  [self setMovable:NO];
  [selectionView setFrameSize:NSMakeSize(imageView.bounds.size.width, imageView.bounds.size.height)];
  [imageView addSubview:selectionView];
  [[NSCursor crosshairCursor] set];
}

- (void)cancel:(id)arg1{}

- (void)windowWillClose:(NSNotification *)notification{
//  NSLog(@"windowWillClose");
}

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

//- (void)dealloc{
//  NSLog(@"dealloc called");
//}

- (void)close{
//  NSLog(@"close pvc: %d, isPipCLosing: %d, isWinClosing: %d", (int)pvc, isPipCLosing, isWinClosing);
  if(pvc){
    if(!isPipCLosing){
      NSRect rect = [[[pvc view] window] frame];
      rect.origin.x += rect.size.width / 2;
      rect.origin.y += rect.size.height / 2;
      rect.size.width = 0;
      rect.size.height = 0;

      shouldClose = true;
      isPipCLosing = true;
      [pvc setReplacementRect:rect];
      [pvc dismissViewController:nvc];
    }
    return;
  }

  if(isWinClosing) return;
  isWinClosing = true;

  [self stopTimer];

  window_id = 0;
  pinbutt.delegate = NULL;
  popbutt.delegate = NULL;
  playbutt.delegate = NULL;

  imageView.renderer.delegate = nil;
  imageView.renderer = nil;

  [imageView removeFromSuperview];
  [pinbutt removeFromSuperview];
  [butCont removeFromSuperview];
  [popbutt removeFromSuperview];
  [playbutt removeFromSuperview];
  [selectionView removeFromSuperview];
  [rootView removeFromSuperview];
  [tbavc removeFromParentViewController];

  nvc = NULL;
  tbavc = NULL;
  timer = NULL;
  rootView = NULL;
  butCont = NULL;
  pinbutt = NULL;
  popbutt = NULL;
  playbutt = NULL;
  selectionView = NULL;

  [self setContentViewController:nil];

  [super close];
}

@end
