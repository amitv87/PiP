//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "cgs.h"
#import "common.h"
#import "window.h"
#import "audioPlayer.h"
#import "H264Decoder.h"

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin.h"
#define INC_IMG(x) INCBIN(img_##x##_, "img/" #x ".png")
#define GET_IMG(x) [[NSImage alloc] initWithData:[NSData dataWithBytes:gimg_##x##_Data length:gimg_##x##_Size]]
#define GET_REL_IMG(x) get_rel_image(GET_IMG(x))

INC_IMG(pin);
INC_IMG(pop);
INC_IMG(play);
INC_IMG(pause);
INC_IMG(pinned);
INC_IMG(opacity);

INC_IMG(stop);
INC_IMG(crop);
INC_IMG(uncrop);
INC_IMG(pop_in);
INC_IMG(pop_out);
INC_IMG(display);
INC_IMG(windows);

#define DEFAULT_TITLE @"(right click to begin)"

static CGRect kStartRect = {
  .origin = {.x = 0, .y = 0,},
  .size = {.width = kStartSize, .height = kStartSize,},
};

static NSWindowStyleMask kWindowMask = NSWindowStyleMaskBorderless
  | NSWindowStyleMaskTitled
  | NSWindowStyleMaskClosable
  | NSWindowStyleMaskResizable
  | NSWindowStyleMaskMiniaturizable
  | NSWindowStyleMaskFullSizeContentView
  | NSWindowStyleMaskNonactivatingPanel
;

static bool isInside(int rad, CGPoint cirlce, CGPoint point){
  if ((point.x - cirlce.x) * (point.x - cirlce.x) + (point.y - cirlce.y) * (point.y - cirlce.y) <= rad * rad) return true;
  else return false;
}

static void setWindowSize(NSWindow* window, NSRect windowRect, NSRect screenRect, NSSize size, bool animate){
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
@property (nonatomic) int winId;
@property (nonatomic) int dspId;
@property (nonatomic) int ownerPid;
@end

@implementation WindowSel
+ (WindowSel*)getDefault{
  WindowSel* sel = [[WindowSel alloc] init];
  sel.owner = nil;
  sel.title = DEFAULT_TITLE;
  sel.winId = -1;
  sel.dspId = -1;
  sel.ownerPid = -1;
  return sel;
}
@end

AXError _AXUIElementGetWindow(AXUIElementRef window, CGWindowID *windowID);

static AXUIElementRef GetUIElement(CGWindowID win) {
  // Window PID
  pid_t pid = 0;

  // Create array storing window
  CFArrayRef wlist = CFArrayCreate(NULL, (const void ** ) &win, 1, NULL);

  // Get window info
  CFArrayRef info = CGWindowListCreateDescriptionFromArray(wlist);
  CFRelease(wlist);

  // Check whether the resulting array is populated
  if (info != NULL && CFArrayGetCount(info) > 0) {
    // Retrieve description from info array
    CFDictionaryRef desc = (CFDictionaryRef)
    CFArrayGetValueAtIndex(info, 0);

    // Get window PID
    CFNumberRef data = (CFNumberRef)
    CFDictionaryGetValue(desc, kCGWindowOwnerPID);

    if (data != NULL) CFNumberGetValue(data, kCFNumberIntType, & pid);

    // Return result
    CFRelease(info);
  }

  // Check if PID was retrieved
  if (pid <= 0) return NULL;

  // Create an accessibility object using retrieved PID
  AXUIElementRef application = AXUIElementCreateApplication(pid);
  if (application == NULL) return NULL;

  CFArrayRef windows = NULL;
  // Get all windows associated with the app
  AXUIElementCopyAttributeValues(application, kAXWindowsAttribute, 0, 1024, & windows);

  // Reference to resulting value
  AXUIElementRef result = NULL;

  if (windows != NULL) {
    CFIndex count = CFArrayGetCount(windows);
    // Loop all windows in the process
    for (CFIndex i = 0; i < count; ++i) {
      // Get the element at the index
      AXUIElementRef element = (AXUIElementRef)
      CFArrayGetValueAtIndex(windows, i);

      CGWindowID temp = 0;
      // Use undocumented API to get WindowID
      _AXUIElementGetWindow(element, & temp);

      // Check results
      if (temp == win) {
        // Retain element
        CFRetain(element);
        result = element;
        break;
      }
    }

    CFRelease(windows);
  }

  CFRelease(application);
  return result;
}

static void bringWindoToForeground(CGWindowID wid){
  AXUIElementRef window_ref = GetUIElement(wid);
  if(!window_ref) return;
  ProcessSerialNumber psn;
  CGSConnectionID cid = CGSMainConnectionID(), ownerCid;
  CGSGetWindowOwner(cid, wid, &ownerCid);
  CGSGetConnectionPSN(ownerCid, &psn);
  SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated);

  uint8_t bytes1[0xf8] = {
      [0x04] = 0xF8,
      [0x08] = 0x01,
      [0x3a] = 0x10
  };

  uint8_t bytes2[0xf8] = {
      [0x04] = 0xF8,
      [0x08] = 0x02,
      [0x3a] = 0x10
  };

  memcpy(bytes1 + 0x3c, &wid, sizeof(uint32_t));
  memset(bytes1 + 0x20, 0xFF, 0x10);
  memcpy(bytes2 + 0x3c, &wid, sizeof(uint32_t));
  memset(bytes2 + 0x20, 0xFF, 0x10);
  SLPSPostEventRecordTo(&psn, bytes1);
  SLPSPostEventRecordTo(&psn, bytes2);

  AXUIElementPerformAction(window_ref, kAXRaiseAction);
  CFRelease(window_ref);
}

static void request_permission(const char* perm_string){
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:@"Missing %s permission. Please do the needful!", perm_string]];
  [alert addButtonWithTitle:@"Ok"];
  [alert runModal];
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"x-apple.systempreferences:com.apple.preference.security?Privacy_%s", perm_string]]];
}

static CGImageRef CaptureWindow(CGWindowID wid){
  CGImageRef window_image = NULL;
  CFArrayRef window_image_arr = NULL;
  window_image_arr = CGSHWCaptureWindowList(CGSMainConnectionID(), &wid, 1, kCGSCaptureIgnoreGlobalClipShape | kCGSWindowCaptureNominalResolution);
  if(window_image_arr) window_image = (CGImageRef)CFArrayGetValueAtIndex(window_image_arr, 0);
  if(!window_image) window_image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, wid, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming);
  return window_image;
}

static NSImage* invert_image(NSImage* img){
  CIImage* ciImage = [[CIImage alloc] initWithData:[img TIFFRepresentation]];
  CIFilter* filter = [CIFilter filterWithName:@"CIColorInvert"];
  [filter setDefaults];
  [filter setValue:ciImage forKey:@"inputImage"];
  CIImage* output = [filter valueForKey:@"outputImage"];
  [output drawAtPoint:NSZeroPoint fromRect:NSRectFromCGRect([output extent]) operation:NSCompositingOperationSourceOver fraction:1.0];

  NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:output];
  NSImage *nsImage = [[NSImage alloc] initWithSize:rep.size];
  [nsImage addRepresentation:rep];
  return  nsImage;
}

static bool is_dark_mode(){
  return [[[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"]  isEqual: @"Dark"];
}

static NSImage* get_rel_image(NSImage* img){
  if(is_dark_mode()) return invert_image(img);
  return img;
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

@implementation VButton{
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
  [button setButtonType:NSButtonTypeMomentaryChange];
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

- (void)mouseUp:(NSEvent *)theEvent{
  if([theEvent clickCount] == 2) if(self.delegate)[self.delegate onDoubleClick:theEvent];
//  NSLog(@"click count %ld", (long)[theEvent clickCount]);
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
  VButton* pinbutt;
  VButton* popbutt;
  VButton* playbutt;
  float contentAR;
  int refreshRate;
  bool shouldClose;
  bool isWinClosing;
  bool isPipCLosing;
  int window_id;
  RootView* rootView;
  NSViewController* nvc;
  PIPViewController* pvc;
  SelectionView* selectionView;

  ImageView* imageView;

  AudioPlayer* audPlayer;
  H264Decoder* h264decoder;

  NSTimer* mouse_timer;
  bool mouse_timer_rerun;

  NSString* airplay_title;
  bool was_floating;
  bool is_playing;
  bool is_airplay_session;
  bool shouldEnableFullScreen;

  int owner_pid;
  int display_id;
  CGDisplayStreamRef display_stream;
}

- (id) initWithAirplay:(bool)enable andTitle:(NSString*)title{
  pvc = nil;
  timer = NULL;
  window_id = -1;
  display_id = -1;
  refreshRate = 30;
  shouldClose = false;
  isWinClosing = false;
  isPipCLosing = false;
  was_floating = false;
  
  airplay_title = title;
  display_stream = NULL;

  shouldEnableFullScreen = is_playing = is_airplay_session = enable;

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
//  self.backgroundColor = NSColor.clearColor;
  self.aspectRatio = kStartRect.size;
  self.minSize = NSMakeSize(kMinSize, kMinSize);
  self.maxSize = [[self screen] visibleFrame].size;
  self.preservesContentDuringLiveResize = false;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle |
  (shouldEnableFullScreen ? NSWindowCollectionBehaviorFullScreenPrimary : NSWindowCollectionBehaviorFullScreenAuxiliary);

  selectionView = [[SelectionView alloc] init];
  selectionView.delegate = self;
  selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  float butScale = 2;
  int buttonRadius = 20;
  NSRect butContRect = NSMakeRect(0, 12, (buttonRadius * 4) + 20, buttonRadius * 2);
  butCont = [[NSView alloc] initWithFrame:butContRect];
  butCont.translatesAutoresizingMaskIntoConstraints = false;

  popbutt = [[VButton alloc] initWithRadius:buttonRadius andImage:GET_IMG(pop) andImageScale:butScale];
  [popbutt setDelegate:self];
  [popbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([popbutt frame])) / 2) - (buttonRadius + 7.5), 0)];
  [butCont addSubview:popbutt];

  playbutt = [[VButton alloc] initWithRadius:buttonRadius andImage:GET_IMG(play) andImageScale:butScale];
  [playbutt setDelegate:self];
  [playbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([playbutt frame])) / 2) + (buttonRadius + 7.5), 0)];
  [butCont addSubview:playbutt];

  int ppbutradius = 10;
  pinbutt = [[VButton alloc] initWithRadius:ppbutradius andImage:nil andImageScale:1.8];
  pinbutt.delegate = self;
  pinbutt.translatesAutoresizingMaskIntoConstraints = false;
  pinbutt.frameOrigin = NSMakePoint(ppbutradius, ppbutradius);
  [self setupPushPin:false];

  rootView = [[RootView alloc] initWithFrame:kStartRect];
  rootView.delegate = self;
  [rootView setMaterial:NSVisualEffectMaterialAppearanceBased];
  [rootView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
  [rootView setState:NSVisualEffectStateActive];
  rootView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

  imageView = [[ImageView alloc] initWithFrame:kStartRect];
  imageView.renderer = [(NSNumber*)getPref(@"renderer") intValue] == DisplayRendererTypeOpenGL ? [[OpenGLRenderer alloc] init] : [[MetalRenderer alloc] init];
  imageView.renderer.delegate = self;
  imageView.hidden = !is_airplay_session;

  [rootView addSubview:imageView];
  [rootView addSubview:butCont];
  [rootView addSubview:pinbutt];

  NSRect pinbutRect = pinbutt.frame;
  [[pinbutt.widthAnchor constraintEqualToConstant:pinbutRect.size.width] setActive:true];
  [[pinbutt.heightAnchor constraintEqualToConstant:pinbutRect.size.height] setActive:true];
  [[pinbutt.topAnchor constraintEqualToAnchor:rootView.topAnchor constant:pinbutRect.origin.x] setActive:true];
  [[pinbutt.rightAnchor constraintEqualToAnchor:rootView.rightAnchor constant:-pinbutRect.origin.y] setActive:true];

  [[butCont.widthAnchor constraintEqualToConstant:butContRect.size.width] setActive:true];
  [[butCont.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor constant:-butContRect.origin.x] setActive:true];

  NSTrackingAreaOptions nstopts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside;
  nstopts |= NSTrackingMouseMoved;
  NSTrackingArea *nstArea = [[NSTrackingArea alloc] initWithRect:[[self contentView] frame] options:nstopts owner:self userInfo:nil];

  [rootView addTrackingArea:nstArea];

  nvc = [[NSViewController alloc] init];
  [nvc setView:rootView];
  [self setContentViewController:nvc];

  if(is_airplay_session){
    audPlayer = [[AudioPlayer alloc] init];
    h264decoder = [[H264Decoder alloc] init];
  }

//  [self onMouseEnter:false];
  [self setOwner:nil withTitle:is_airplay_session ? airplay_title : DEFAULT_TITLE];

  [self resetPlaybackSate];

  return self;
}

- (BOOL) canBecomeKeyWindow{
  return YES;
}

- (void)setOwner:(NSString*)owner withTitle:(NSString*) title{
  if(!owner) owner = @"PiP";
  [self setTitle:[NSString localizedStringWithFormat:@"%@ - %@", owner, title]];
}

- (void) onClick:(VButton*)button{
  if(button == playbutt) [self togglePlayback];
  else if(button == popbutt) [self toggleNativePip];
  else if(button == pinbutt) [self togglePin];
}

- (void)stopMouseTimer{
  if(!mouse_timer) return;
  [mouse_timer invalidate];
  mouse_timer = nil;
}

- (void)mouseMoved:(NSEvent *)event{
  if(pvc) return;
  if(!mouse_timer)[[butCont animator] setAlphaValue:1];
  else{
    mouse_timer_rerun = true;
    return;
  }

  mouse_timer = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer * _Nonnull timer){
    [self stopMouseTimer];
    if(self->mouse_timer_rerun){
      self->mouse_timer_rerun = false;
      [self mouseMoved:event];
    }
    else [[self->butCont animator] setAlphaValue:0];
  }];
  [[NSRunLoop mainRunLoop] addTimer:mouse_timer forMode:NSRunLoopCommonModes];
}

- (void)mouseEntered:(NSEvent *)event{
  [self onMouseEnter:true];
}

- (void)mouseExited:(NSEvent *)event{
  [self stopMouseTimer];
  [self onMouseEnter:false];
}

- (void)onMouseEnter:(BOOL)entered{
  bool alphaVal = entered ? 1 : 0;
  if(pvc || self.ignoresMouseEvents) alphaVal = 0;
  if(![self isFullScreen]) [[pinbutt animator] setAlphaValue:alphaVal];
  [[butCont animator] setAlphaValue:alphaVal];
  [[[[self standardWindowButton:NSWindowCloseButton] superview] animator] setAlphaValue:[self isFullScreen] ? 1 : alphaVal];
}

- (void)setupPushPin:(bool)active{
  [pinbutt setImage:active ? GET_IMG(pinned) : GET_IMG(pin)];
}

- (void)toggleFloat{
  if([self isFullScreen]) return;
  if(self.level == NSFloatingWindowLevel) self.level = NSNormalWindowLevel;
  else self.level = NSFloatingWindowLevel;
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

- (void)windowDidEnterFullScreen:(NSNotification *)notification{
  pinbutt.hidden = true;
  was_floating = self.level == NSFloatingWindowLevel;
  self.level = NSNormalWindowLevel;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification{
  pinbutt.hidden = false;
  if(was_floating) self.level = NSFloatingWindowLevel;
}

- (void)togglePlayback{
  if(isWinClosing) return;
  if(is_airplay_session || display_id >= 0){
    is_playing = !is_playing;
    [self resetPlaybackSate];
  }
  else{
    if(timer) [self stopTimer];
    else [self startTimer:1.0/refreshRate];
  }
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
  if(pvc) pvc.playing = timer || is_playing;
  if(timer || is_playing) [playbutt setImage:GET_IMG(pause)];
  else [playbutt setImage:GET_IMG(play)];
}

- (void) startPiP{
//  NSLog(@"startPiP");
  [self stopMouseTimer];
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
  [self togglePlayback];
}

- (void)pipActionPlay:(PIPViewController *)pip{
//  NSLog(@"pipActionPlay");
  [self togglePlayback];
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
  if(isPipCLosing) return;
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
  if(window_id < 0) return;
  timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(capture) userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  [self resetPlaybackSate];
}

- (void)onResize:(CGSize)size andAspectRatio:(CGSize) ar{
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

- (void) setAudioInputFormat:(UInt32)format withsampleRate:(UInt32)sampleRate andChannels:(UInt32)channelCount andSPF:(UInt32)spf{
  [audPlayer setInputFormat:format withSampleRate:sampleRate andChannels:channelCount andSPF:spf];
}

- (void) setVolume:(float)volume{
  [audPlayer setVolume:volume];
}

- (void) renderAudio:(uint8_t*) data withLength:(size_t) length{
  if(!is_playing || isWinClosing) return;
  [audPlayer decode:data andLength:length];
}

- (void) renderH264:(uint8_t*) data withLength:(size_t) length{
  if(!is_playing || isWinClosing) return;
  [h264decoder decode:data withLength:length andReturnDecodedData:^(CVPixelBufferRef pixelBuffer){
    if(!self->is_playing || self->isWinClosing) return;
    CIImage* image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    dispatch_async(dispatch_get_main_queue(), ^{[self->imageView setImage:image];});
  }];
}

- (void)capture{
  CGImageRef window_image = window_id >= 0 ? CaptureWindow(window_id) : (display_id >= 0 ? CGDisplayCreateImage(display_id) : NULL);
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
  [item setRepresentedObject:[WindowSel getDefault]];
  [self changeWindow:item];
}

- (void)onDoubleClick:(NSEvent *)theEvent{
  if(window_id < 0) return;
  bringWindoToForeground(window_id);
  if(@available(macOS 11.0, *)){
    if(!AXIsProcessTrusted()) request_permission("Accessibility");
  }
}

- (bool)is_capturing{
  return display_id >= 0 || window_id >= 0;
}

#define ADD_MENU_ITEM(dest, title, actn, img, ...) {\
  NSMenuItem* item = [dest addItemWithTitle:title action:actn keyEquivalent:@""]; \
  item.image = img; \
  if(item.image) [item.image setSize:NSMakeSize(16, 16)]; \
  [item setTarget:self]; \
  __VA_ARGS__ \
}

- (void)rightMouseDown:(NSEvent *)theEvent {
  NSMenu *theMenu = [[NSMenu alloc] init];
  [theMenu setMinimumWidth:100];

  NSMutableDictionary* window_dict = [[NSMutableDictionary alloc] init];
  NSArray* screens = [NSScreen screens];
  NSMenu* display_menu = [[NSMenu alloc] init];
  NSMenu* window_menu = [[NSMenu alloc] init];

  if(is_airplay_session) goto end;

  if(@available(macOS 11.0, *)){
    if(!CGPreflightScreenCaptureAccess()){
      CGRequestScreenCaptureAccess();
      request_permission("ScreenCapture");
      return;
    }
  }

//  [theMenu addItem:[NSMenuItem separatorItem]];

  bool should_exclude_desktop_elements = [(NSNumber*)getPref(@"wfilter_desktop_elemnts") intValue] > 0;
  bool should_exclude_windows_with_null_title = [(NSNumber*)getPref(@"wfilter_null_title") intValue] > 0;
  bool should_exclude_windows_with_empty_title = [(NSNumber*)getPref(@"wfilter_epmty_title") intValue] > 0;
  bool should_exclude_floating_windows = [(NSNumber*)getPref(@"wfilter_floating") intValue] > 0;

  for(NSScreen* screen in screens){
    NSDictionary* dict = [screen deviceDescription];
//    NSLog(@"%@", dict);
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] intValue];

    NSString* windowTitle = [NSString stringWithFormat:@"Display %u", did];
    if (@available(macOS 10.15, *)) windowTitle = [NSString stringWithFormat:@"%@", [screen localizedName]];

    WindowSel* sel = [WindowSel getDefault];
    sel.title = windowTitle;
    sel.dspId = did;

    NSMenu* dest_menu = display_menu;
//    if(screens.count == 1) dest_menu = theMenu;
    ADD_MENU_ITEM(dest_menu, windowTitle, @selector(changeWindow:), NULL, {
      [item setRepresentedObject:sel];
    })
  }

//  [theMenu addItem:[NSMenuItem separatorItem]];

  uint32_t windowId = 0, ownerPid = 0;
  CGWindowListOption win_option = kCGWindowListOptionAll;
  if(should_exclude_desktop_elements) win_option |= kCGWindowListExcludeDesktopElements;
  CFArrayRef all_windows = CGWindowListCopyWindowInfo(win_option, kCGNullWindowID);

  int self_pid = [[NSProcessInfo processInfo] processIdentifier];

  for (CFIndex i = 0; i < CFArrayGetCount(all_windows); ++i) {
    CFDictionaryRef window_ref = (CFDictionaryRef)CFArrayGetValueAtIndex(all_windows, i);

    int layer = -1;
    CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowLayer), kCFNumberIntType, &layer);
    if(layer != 0 && should_exclude_floating_windows) continue;

    NSString* owner = (__bridge NSString*)CFDictionaryGetValue(window_ref, kCGWindowOwnerName);
    NSString* name = (__bridge NSString*)CFDictionaryGetValue(window_ref, kCGWindowName);
//    NSLog(@"owner: %@, name: %@", owner, name);
    if(!owner) continue;
    if(!name && should_exclude_windows_with_null_title) continue;
    if([name length] <= 0 && should_exclude_windows_with_empty_title) continue;

    CFNumberRef id_ref = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowNumber);
    CFNumberGetValue(id_ref, kCFNumberIntType, &windowId);

    id_ref = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowOwnerPID);
    CFNumberGetValue(id_ref, kCFNumberIntType, &ownerPid);
    if(ownerPid == self_pid) continue;

    bool isFaulty = true;
    CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue (window_ref, kCGWindowBounds);
    if(bounds){
      NSRect rect = NSZeroRect;
      CGRectMakeWithDictionaryRepresentation(bounds, &rect);
      isFaulty = rect.size.width * rect.size.height <= 1;
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
      isFaulty = CGImageGetHeight(window_image) * CGImageGetWidth(window_image) <= 1;
      CGImageRelease(window_image);
    }

    if(isFaulty) continue;

//    NSLog(@"%@", (__bridge NSDictionary*)window_ref);

    NSString* key = [NSString stringWithFormat:@"%@_%u", owner, ownerPid];
    NSMutableArray* window_arr = window_dict[key];
    if(!window_arr) window_dict[key] = window_arr = [[NSMutableArray alloc] init];

    if(!name || name.length == 0) name = [NSString stringWithFormat:@"win_%u", windowId];

    WindowSel* sel = [WindowSel getDefault];
    sel.owner = owner;
    sel.title = name;
    sel.winId = windowId;
    sel.ownerPid = ownerPid;
    [window_arr addObject:sel];
  }

  CFRelease(all_windows);

  for(NSString* key in [window_dict.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]){
    NSArray* window_arr = [window_dict[key] sortedArrayUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"title" ascending:YES]]];
    NSMenu *dest_menu = window_menu;
//    if(window_dict.allKeys.count == 1) dest_menu = theMenu;
    WindowSel* proc_sel = window_arr[0];
    NSImage *icon = [[NSRunningApplication runningApplicationWithProcessIdentifier: proc_sel.ownerPid] icon];
    if(!icon) icon = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];

    if(window_arr.count > 1){
      ADD_MENU_ITEM(dest_menu, ([NSString stringWithFormat:@"%@", proc_sel.owner]), nil, icon, {
        [item setSubmenu:dest_menu = [[NSMenu alloc] init]];
      })
    }
    for(WindowSel* sel in window_arr){
      NSString* windowTitle = window_arr.count > 1 ? [NSString stringWithFormat:@"%@", sel.title] : [NSString stringWithFormat:@"%@ - %@", sel.owner, sel.title];
      ADD_MENU_ITEM(dest_menu, windowTitle, @selector(changeWindow:), (dest_menu == window_menu ? icon : NULL), {
        [item setRepresentedObject:sel];
      })
    }
  }

  if(display_menu.numberOfItems > 0){
    ADD_MENU_ITEM(theMenu, @"Select Display", nil, GET_REL_IMG(display), {
      [item setSubmenu:display_menu];
    })
  }

  if(window_menu.numberOfItems > 0){
    ADD_MENU_ITEM(theMenu, @"Select Window", nil, GET_REL_IMG(windows), {
      [item setSubmenu:window_menu];
    })
  }

end:
  if(!pvc && ([self is_capturing] || is_airplay_session)){
    NSSize cropSize = [imageView.renderer cropRect].size;
    bool can_crop = cropSize.width * cropSize.height == 0;
    ADD_MENU_ITEM(theMenu, (can_crop ? @"Select region" : @"Deselect region"), can_crop ? @selector(selectRegion:) : @selector(clearSelection:), (can_crop ? GET_REL_IMG(crop) : GET_REL_IMG(uncrop)))
  }

  if([self is_capturing]){
    ADD_MENU_ITEM(theMenu, @"Stop Preview", @selector(changeWindow:), GET_REL_IMG(stop), {
      [item setRepresentedObject:[WindowSel getDefault]];
    })
  }

  if(!pvc){
    NSSlider* slider = [[NSSlider alloc] init];

    [slider setTarget:self];
    [slider setMinValue:0.1];
    [slider setMaxValue:1.0];
    [slider setControlSize:NSControlSizeSmall];
    [slider setDoubleValue:[[nvc view] window].alphaValue];
    [slider setFrame:NSMakeRect(36, 6 , 50, 18)];
    [slider setAction:@selector(adjustOpacity:)];
    [slider setAutoresizingMask:NSViewWidthSizable];

    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
    view.autoresizingMask = NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin;

    NSImageView* iv = [[NSImageView alloc] init];
    [iv setImage:GET_REL_IMG(opacity)];
    [iv setFrame:NSMakeRect(14, 8, 16, 16)];
    [view addSubview: iv];
    [view addSubview:slider];

    NSMenuItem* itemSlider = [[NSMenuItem alloc] init];
    [itemSlider setEnabled:YES];
    [itemSlider setView:view];
    [theMenu addItem:itemSlider];
  }

  ADD_MENU_ITEM(theMenu, ([NSString stringWithFormat:@"%s native pip", (pvc ? "Exit" : "Enter")]), @selector(toggleNativePip), (pvc ? GET_REL_IMG(pop_in) : GET_REL_IMG(pop_out)))

  [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:rootView];
}

- (void)setScale:(id)sender{
  if([self is_capturing] || is_airplay_session) [imageView.renderer setScale:[sender tag]];
}

- (void)adjustOpacity:(id)sender{
  NSSlider* slider = (NSSlider*)sender;
  [self setAlphaValue:slider.doubleValue];
}

-(void)stopDisplayStream{
  if(!display_stream) return;
  CGDisplayStreamStop(display_stream);
  CFRelease(display_stream);
  display_stream = NULL;
}

- (void)changeWindow:(id)sender{
  WindowSel* sel = [sender representedObject];
  if(window_id == sel.winId && display_id == sel.dspId) return;

  [self stopTimer];
  [self stopDisplayStream];

  window_id = sel.winId;
  display_id = sel.dspId;
  owner_pid = sel.ownerPid;

  if(![self is_capturing]){
    NSSize size = [self frame].size;
    size.height = size.width;
    [self onResize:size andAspectRatio:kStartRect.size];
  }
  else if(display_id >= 0){
    size_t width = CGDisplayPixelsWide(display_id);
    size_t height = CGDisplayPixelsHigh(display_id);

    NSDictionary* opts = @{
      (__bridge NSString *)kCGDisplayStreamMinimumFrameTime : @(1.0f / refreshRate),
      (__bridge NSString *)kCGDisplayStreamShowCursor : [(NSNumber*)getPref(@"mouse_capture") intValue] > 0 ? @YES : @NO,
    };

    display_stream = CGDisplayStreamCreateWithDispatchQueue(display_id, width, height, kCVPixelFormatType_32BGRA,  (__bridge CFDictionaryRef)opts, dispatch_get_main_queue(), ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
      if(status != kCGDisplayStreamFrameStatusFrameComplete || !self->is_playing || self->isWinClosing) return;
      [self->imageView setImage:[CIImage imageWithIOSurface:frameSurface]];
    });
    CGDisplayStreamStart(display_stream);

    is_playing = true;
    [self resetPlaybackSate];
  }
  else if(window_id >= 0){
    [self startTimer:1.0/refreshRate];
  }

  [self setMovable:YES];
  [selectionView removeFromSuperview];
  dispatch_async(dispatch_get_main_queue(), ^{[[NSCursor arrowCursor] set];});

  [imageView setImage:nil];
  [imageView setHidden:![self is_capturing]];
  [self setOwner:sel.owner withTitle:sel.title];
}

- (void)selectRegion:(id)sender{
  [self setMovable:NO];
  [selectionView setFrameSize:NSMakeSize(imageView.bounds.size.width, imageView.bounds.size.height)];
  [imageView addSubview:selectionView];
  dispatch_async(dispatch_get_main_queue(), ^{[[NSCursor crosshairCursor] set];});
}

- (void)clearSelection:(id)sender{
  [self onSelcetion:CGRectZero];
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

  [self stopMouseTimer];

  if(isWinClosing) return;
  isWinClosing = true;

  #ifndef NO_AIRPLAY
  if(is_airplay_session) airplay_receiver_session_stop(self.conn);
  #endif

  [self stopTimer];
  [self stopDisplayStream];

  window_id = -1;
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

  nvc = NULL;
  timer = NULL;
  rootView = NULL;
  butCont = NULL;
  pinbutt = NULL;
  popbutt = NULL;
  playbutt = NULL;
  selectionView = NULL;

  [self setContentViewController:nil];

  if(audPlayer) [audPlayer destroy]; audPlayer = nil;
  if(h264decoder) [h264decoder destroy]; h264decoder = nil;

  [super close];
}

@end
