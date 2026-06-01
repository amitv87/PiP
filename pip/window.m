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
#import "HLSPlayer.h"
#import "stream_manager.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#ifndef NO_AIRPLAY
#import "airplaySender.h"
#include "../airplay_sender/http_client.h"
#include "../airplay_sender/sender.h"
#include "../airplay_sender/discovery.h"
#include "../airplay_sender/frame_capture.h"
#include "../airplay_sender/video_encoder.h"
#import "frame_capture.h"
#import "video_encoder.h"
#include <sys/sysctl.h>
#endif

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
INC_IMG(camera);
INC_IMG(display);
INC_IMG(windows);
INC_IMG(hls);
INC_IMG(airplay);
INC_IMG(airplay_stop);

INC_IMG(pop_no_pad);
INC_IMG(play_no_pad);
INC_IMG(pause_no_pad);

#define DEFAULT_TITLE @"(right click to begin)"
#define HLS_BUTTON_IMAGE_SIZE 20

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
@property (nonatomic) NSString* cameraId;
@end

@implementation WindowSel
+ (WindowSel*)getDefault{
  WindowSel* sel = [[WindowSel alloc] init];
  sel.owner = nil;
  sel.title = DEFAULT_TITLE;
  sel.winId = -1;
  sel.dspId = -1;
  sel.ownerPid = -1;
  sel.cameraId = nil;
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

static void bringWindowToForegroundModern(CGWindowID wid){
  // Get owning PID from window info
  pid_t ownerPid = -1;
  CFArrayRef infoArr = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
  if(infoArr && CFArrayGetCount(infoArr) > 0) {
    CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(infoArr, 0);
    CFNumberRef pidNum = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowOwnerPID);
    if(pidNum) {
      int pidInt = -1;
      if(CFNumberGetValue(pidNum, kCFNumberIntType, &pidInt)) ownerPid = (pid_t)pidInt;
    }
  }
  if(infoArr) CFRelease(infoArr);

  if(ownerPid <= 0) {
    NSLog(@"bringWindowToForegroundModern: Could not get owner PID for window %d (is Screen Recording permission granted?)", wid);
    return;
  }

  // Get the app's AX element first
  AXUIElementRef appRef = AXUIElementCreateApplication(ownerPid);
  if(!appRef) {
    NSLog(@"bringWindowToForegroundModern: Could not create AX element for PID %d", ownerPid);
    return;
  }

  // Find the window from the app's window list
  AXUIElementRef window_ref = NULL;
  CFArrayRef windows = NULL;
  AXError err = AXUIElementCopyAttributeValues(appRef, kAXWindowsAttribute, 0, 1024, &windows);

  if(err == kAXErrorSuccess && windows) {
    CFIndex count = CFArrayGetCount(windows);
    for(CFIndex i = 0; i < count; i++) {
      AXUIElementRef winElement = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
      CGWindowID tempWid = 0;
      if(_AXUIElementGetWindow(winElement, &tempWid) == kAXErrorSuccess && tempWid == wid) {
        window_ref = winElement;
        CFRetain(window_ref);
        break;
      }
    }
    if(windows) CFRelease(windows);
  }

  // Fallback to GetUIElement if we didn't find it in the window list
  if(!window_ref) {
    window_ref = GetUIElement(wid);
  }

  if(!window_ref) {
    NSLog(@"bringWindowToForegroundModern: Could not find AX element for window %d", wid);
    CFRelease(appRef);
    return;
  }

  // Activate the app - do this AFTER finding the window
  NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPid];
  if(app) {
    [app activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
  }

  // Check if window is minimized and un-minimize it first
  CFTypeRef minimized = NULL;
  if(AXUIElementCopyAttributeValue(window_ref, kAXMinimizedAttribute, &minimized) == kAXErrorSuccess) {
    if(minimized && CFBooleanGetValue((CFBooleanRef)minimized)) {
      AXUIElementSetAttributeValue(window_ref, kAXMinimizedAttribute, kCFBooleanFalse);
    }
    if(minimized) CFRelease(minimized);
  }

  // Set app as frontmost
  AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);

  // Raise the window - this is the key action
  AXError raiseErr = AXUIElementPerformAction(window_ref, kAXRaiseAction);
  if(raiseErr != kAXErrorSuccess) {
    NSLog(@"bringWindowToForegroundModern: AXRaiseAction failed with error %d", raiseErr);
  }

  // Set it as main window
  AXUIElementSetAttributeValue(window_ref, kAXMainAttribute, kCFBooleanTrue);

  // Try to focus it
  AXUIElementSetAttributeValue(window_ref, kAXFocusedAttribute, kCFBooleanTrue);

  CFRelease(window_ref);
  CFRelease(appRef);
}

static CGImageRef CaptureWindow(CGWindowID wid, bool hidpi){
  CGImageRef window_image = NULL;
  CFArrayRef window_image_arr = NULL;
  window_image_arr = CGSHWCaptureWindowList(CGSMainConnectionID(), &wid, 1, 0
    | kCGSCaptureIgnoreGlobalClipShape
    | (hidpi ? 0 : kCGSWindowCaptureNominalResolution)
  );
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

static NSImage* hls_button_image(NSImage* img){
  // Convert to white and resize to HLS button size, preserving aspect ratio
  NSImage *whiteImg = invert_image(img);
  NSSize originalSize = [whiteImg size];
  NSSize targetSize = NSMakeSize(HLS_BUTTON_IMAGE_SIZE, HLS_BUTTON_IMAGE_SIZE);

  // Calculate aspect ratio preserving size
  CGFloat aspectRatio = originalSize.width / originalSize.height;
  NSSize scaledSize;
  if (aspectRatio > 1.0) scaledSize = NSMakeSize(targetSize.width, targetSize.width / aspectRatio);
  else scaledSize = NSMakeSize(targetSize.height * aspectRatio, targetSize.height);

  // Center the image in the target size
  NSRect drawRect = NSMakeRect(
    (targetSize.width - scaledSize.width) / 2.0,
    (targetSize.height - scaledSize.height) / 2.0,
    scaledSize.width,
    scaledSize.height
  );

  NSImage *resizedImage = [[NSImage alloc] initWithSize:targetSize];
  [resizedImage lockFocus];
  [[NSColor clearColor] set];
  NSRectFill(NSMakeRect(0, 0, targetSize.width, targetSize.height));
  [whiteImg drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
  [resizedImage unlockFocus];
  return resizedImage;
}

@interface HLSImageButton : NSButton
@end

@implementation HLSImageButton

#if 0
- (void)drawRect:(NSRect)dirtyRect
{
  self.layer.borderColor = [NSColor whiteColor].CGColor;
  self.layer.borderWidth = 2.0;
  [super drawRect:dirtyRect];
}
#endif

- (void)setImage:(NSImage *)image {
  [super setImage:image];
  // Automatically create highlighted (smaller) version and set as alternate image
  if (image) {
    NSSize originalSize = [image size];
    NSSize smallerSize = NSMakeSize(originalSize.width * 0.7, originalSize.height * 0.7);
    NSImage *smallerImage = [[NSImage alloc] initWithSize:smallerSize];
    [smallerImage lockFocus];
    NSRect drawRect = NSMakeRect(0, 0, smallerSize.width, smallerSize.height);
    [image drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [smallerImage unlockFocus];
    [self setAlternateImage:smallerImage];
  }
}
@end

/**
 * A view that passes through all mouse events to views behind it.
 * Used for the source hint overlay so right-click menus still work.
 */
@interface PassthroughView : NSView
@end

@implementation PassthroughView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

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

@interface SeekSlider : NSSlider
@property (nonatomic, weak) id seekTarget;
@property (nonatomic) SEL seekAction;
@end

@implementation SeekSlider {
  BOOL isTracking;
}

- (NSRect)trackRectForBounds:(NSRect)bounds {
  // Return the actual track rect that matches what we draw in drawRect
  // This ensures NSSlider's internal value calculations match our visual representation
  CGFloat trackPadding = 2.0;
  CGFloat trackHeight = 4.0;
  CGFloat trackY = (bounds.size.height - trackHeight) / 2.0;
  return NSMakeRect(trackPadding, trackY, bounds.size.width - (trackPadding * 2), trackHeight);
}

- (double)valueForMouseLocation:(NSPoint)locationInView {
  NSRect bounds = [self bounds];
  NSRect trackRect = [self trackRectForBounds:bounds];
  double minVal = [self minValue];
  double maxVal = [self maxValue];

  // Calculate value based on mouse X position within the track area
  double value = minVal;
  if (trackRect.size.width > 0) {
    // Convert mouse X to position relative to track start
    double relativeX = locationInView.x - trackRect.origin.x;
    // Clamp to track bounds
    relativeX = fmax(0.0, fmin(trackRect.size.width, relativeX));
    // Calculate percentage within track
    double percentage = relativeX / trackRect.size.width;
    percentage = fmax(0.0, fmin(1.0, percentage)); // Ensure 0-1 range
    value = minVal + (maxVal - minVal) * percentage;
  }

  return value;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  isTracking = YES;

  // Call the target's action to handle pause/state
  if (self.seekTarget && self.seekAction) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.seekTarget performSelector:self.seekAction withObject:self];
    #pragma clang diagnostic pop
  }

  // Calculate and set value immediately on mouse down
  NSPoint locationInView = [self convertPoint:[event locationInWindow] fromView:nil];
  double value = [self valueForMouseLocation:locationInView];
  [self setDoubleValue:value];

  // Call action for immediate feedback
  if (self.seekTarget && self.seekAction) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.seekTarget performSelector:self.seekAction withObject:self];
    #pragma clang diagnostic pop
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (!isTracking) return;

  NSPoint locationInView = [self convertPoint:[event locationInWindow] fromView:nil];
  double value = [self valueForMouseLocation:locationInView];

  // Update the slider value to match mouse position
  [self setDoubleValue:value];

  // Call the action continuously during drag
  if (self.seekTarget && self.seekAction) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.seekTarget performSelector:self.seekAction withObject:self];
    #pragma clang diagnostic pop
  }
}

- (void)mouseUp:(NSEvent *)event {
  if (!isTracking) return;
  isTracking = NO;

  // Calculate value from mouse position
  NSPoint locationInView = [self convertPoint:[event locationInWindow] fromView:nil];
  double value = [self valueForMouseLocation:locationInView];

  // Update slider value to match calculated position
  [self setDoubleValue:value];

  // Perform seek immediately on mouse up with calculated value (for single tap)
  if (self.seekTarget) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.seekTarget performSelector:@selector(seekSliderMouseUp:withValue:) withObject:self withObject:@(value)];
    #pragma clang diagnostic pop
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect bounds = [self bounds];

  // Draw the track manually (a simple rounded rectangle)
  CGFloat trackHeight = 4.0;
  CGFloat trackY = (bounds.size.height - trackHeight) / 2.0;
  CGFloat trackPadding = 2.0;
  NSRect trackRect = NSMakeRect(trackPadding, trackY, bounds.size.width - (trackPadding * 2), trackHeight);

  // Draw track background
  NSColor *trackColor = [NSColor colorWithWhite:0.3 alpha:0.5];
  [trackColor set];
  NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:trackRect xRadius:1.0 yRadius:1.0];
  [trackPath fill];

  // Draw filled portion of track (before knob position)
  double minVal = [self minValue];
  double maxVal = [self maxValue];
  double currentVal = [self doubleValue];
  double percentage = 0.0;
  if (maxVal > minVal) {
    percentage = (currentVal - minVal) / (maxVal - minVal);
    percentage = fmax(0.0, fmin(1.0, percentage)); // Clamp to 0-1
  }

  CGFloat filledWidth = trackRect.size.width * percentage;
  if (filledWidth > 0) {
    NSRect filledRect = NSMakeRect(trackRect.origin.x, trackRect.origin.y, filledWidth, trackRect.size.height);
    NSColor *filledColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    // if (@available(macOS 10.14, *)) {
    //   filledColor = [NSColor controlAccentColor];
    // }
    [filledColor set];
    NSBezierPath *filledPath = [NSBezierPath bezierPathWithRoundedRect:filledRect xRadius:1.0 yRadius:1.0];
    [filledPath fill];
  }

  // Calculate knob position
  CGFloat knobX = trackRect.origin.x + (trackRect.size.width * percentage);

  // Draw a thick vertical line at the knob position
  CGFloat lineWidth = 3.0; // Thickness of the line
  CGFloat lineHeight = 15.0; // Height of the line
  CGFloat lineY = (bounds.size.height - lineHeight) / 2.0; // Center align vertically

  // Set the color for the line
  NSColor *lineColor = [NSColor whiteColor];
  // if (@available(macOS 10.14, *)) {
  //   lineColor = [NSColor controlAccentColor];
  // }
  [lineColor set];

  // Draw the thick vertical line
  NSBezierPath *line = [NSBezierPath bezierPath];
  [line setLineWidth:lineWidth];
  [line moveToPoint:NSMakePoint(knobX, lineY)];
  [line lineToPoint:NSMakePoint(knobX, lineY + lineHeight)];
  [line stroke];
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

// Forward declaration for methods called from C callbacks
@interface Window (DisconnectHandling)
- (void)handleDisplayDisconnected:(CGDirectDisplayID)displayId;
@end

/**
 * C callback for display reconfiguration events.
 * Called when a display is added, removed, or reconfigured.
 * The userInfo parameter is a pointer to the Window instance.
 * @param display The display that was reconfigured
 * @param flags The type of reconfiguration
 * @param userInfo Pointer to the Window instance
 */
static void displayReconfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void* userInfo){
  if(flags & kCGDisplayRemoveFlag){
    Window* window = (__bridge Window*)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
      [window handleDisplayDisconnected:display];
    });
  }
} // End of displayReconfigurationCallback()

@implementation Window{
  NSTimer* timer;
  NSView* butCont;
  NSVisualEffectView* hlsButCont;
  VButton* pinbutt;
  VButton* popbutt;
  VButton* playbutt;
  float contentAR;
  int refreshRate;
  bool is_hidpi;
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
  HLSPlayer* hlsPlayer;

  NSView* hlsInputView;
  NSTextField* hlsInputField;
  NSButton* hlsLoadButton;
  NSButton* hlsCancelButton;
  NSString* lastSuccessfulHLSURL;

  NSSlider* hlsSeekSlider;
  NSSlider* hlsVolumeSlider;
  NSTextField* hlsElapsedTimeLabel;
  NSTextField* hlsTotalTimeLabel;
  NSTextField* hlsLiveIndicator;
  NSButton* hlsPlayButton;
  NSButton* hlsPopButton;
  bool isSeeking;
  NSTimer* seekDebounceTimer;
  float pendingSeekValue;
  BOOL wasPlayingBeforeSeek;
  int bufferingCheckCount;
  BOOL isLiveStream;

  NSTimer* mouse_timer;
  bool mouse_timer_rerun;

  NSView* sourceHintOverlay;
  NSTextField* hintLabel;

  NSString* airplay_title;
  bool was_floating;
  bool is_playing;
  bool is_airplay_session;
  bool is_hls_session;
  bool shouldEnableFullScreen;

  int owner_pid;
  int display_id;
  CGDisplayStreamRef display_stream;
  AVCaptureSession* camera_session;
  AVCaptureDeviceInput* camera_input;
  AVCaptureVideoDataOutput* camera_output;
  AVCaptureAudioDataOutput* camera_audio_output;
  NSString* camera_id;
  AVCaptureDeviceFormat* camera_format;
  AVCaptureDevicePosition camera_position;
  uint64_t camera_audio_sample_count;

  // Camera audio capture and playback using AVCaptureAudioPreviewOutput
  AVCaptureAudioPreviewOutput* camera_audio_preview;
  bool camera_audio_enabled;
  bool camera_audio_monitoring;  // Local audio monitoring (does not affect HLS streaming)
  bool camera_has_microphone;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  SCStream *window_stream API_AVAILABLE(macos(12.3));
  SCStreamConfiguration *window_stream_config API_AVAILABLE(macos(12.3));
  bool is_window_stream_updating API_AVAILABLE(macos(12.3));
#endif
#ifndef NO_AIRPLAY
  AirPlayDiscovery* airplayDiscovery;
  void* httpClient;  // http_client_t*
  AirPlayReceiver* connectedReceiver;
  void* airplaySender;  // sender_t*
  AirPlayReceiver* connectedSenderReceiver;
  bool is_airplay_sending;
  dispatch_queue_t senderQueue;  // Serial queue for sender operations
#endif
  StreamManager* streamManager;
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
  camera_session = nil;
  camera_input = nil;
  camera_output = nil;
  camera_audio_output = nil;
  camera_id = nil;
  camera_format = nil;
  camera_audio_sample_count = 0;

  // Initialize camera audio variables
  camera_audio_preview = nil;
  camera_audio_enabled = true;  // Enabled by default
  camera_audio_monitoring = true;  // Local monitoring enabled by default
  camera_has_microphone = false;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    window_stream = nil;
    window_stream_config = nil;
    is_window_stream_updating = false;
  }
#endif

  shouldEnableFullScreen = is_playing = is_airplay_session = enable;
  is_hls_session = false;
  is_hidpi = [(NSNumber*)getPref(@"hidpi") intValue] > 0 && !is_airplay_session;
#ifndef NO_AIRPLAY
  airplayDiscovery = [AirPlayDiscovery sharedDiscovery];
  airplayDiscovery.delegate = self;
  // Discovery is started at app launch, just set delegate
  airplaySender = NULL;
  connectedSenderReceiver = nil;
  is_airplay_sending = false;
#endif

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
  self.hidesOnDeactivate = NO;
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

  NSRect hlsButContRect = NSMakeRect(0, 12, 160, 55);
  hlsButCont = [[NSVisualEffectView alloc] initWithFrame:hlsButContRect];
  if (@available(macOS 10.14, *)) {
    // hlsButCont.material = NSVisualEffectMaterialLight;
    hlsButCont.material = NSVisualEffectMaterialHUDWindow;
  } else {
    hlsButCont.material = NSVisualEffectMaterialAppearanceBased;
  }
  hlsButCont.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  hlsButCont.state = NSVisualEffectStateActive;
  hlsButCont.translatesAutoresizingMaskIntoConstraints = false;
  hlsButCont.wantsLayer = YES;
  hlsButCont.layer.cornerRadius = 15;
  hlsButCont.layer.masksToBounds = YES;

  popbutt = [[VButton alloc] initWithRadius:buttonRadius andImage:GET_IMG(pop) andImageScale:butScale];
  [popbutt setDelegate:self];
  [popbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([popbutt frame])) / 2) - (buttonRadius + 7.5), 0)];
  [butCont addSubview:popbutt];

  playbutt = [[VButton alloc] initWithRadius:buttonRadius andImage:GET_IMG(play) andImageScale:butScale];
  [playbutt setDelegate:self];
  [playbutt setFrameOrigin:NSMakePoint(round((NSWidth([butCont bounds]) - NSWidth([playbutt frame])) / 2) + (buttonRadius + 7.5), 0)];
  [butCont addSubview:playbutt];

  hlsSeekSlider = [[SeekSlider alloc] initWithFrame:NSMakeRect(45, 5, 70, 20)];
  [hlsSeekSlider setMinValue:0.0];
  [hlsSeekSlider setMaxValue:1.0];
  [hlsSeekSlider setDoubleValue:0.0];
  [hlsSeekSlider setTarget:self];
  [hlsSeekSlider setAction:@selector(seekSliderChanged:)];
  [hlsSeekSlider setContinuous:YES]; // Allow continuous updates for UI
  [hlsSeekSlider setControlSize:NSControlSizeSmall];
  [hlsSeekSlider setTranslatesAutoresizingMaskIntoConstraints:NO];
  ((SeekSlider *)hlsSeekSlider).seekTarget = self;
  ((SeekSlider *)hlsSeekSlider).seekAction = @selector(seekSliderChanged:);
  [hlsButCont addSubview:hlsSeekSlider];

  // Create elapsed time label (left of seekbar)
  hlsElapsedTimeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(5, 8, 30, 20)];
  [hlsElapsedTimeLabel setStringValue:@"00:00"];
  [hlsElapsedTimeLabel setBezeled:NO];
  [hlsElapsedTimeLabel setDrawsBackground:NO];
  [hlsElapsedTimeLabel setEditable:NO];
  [hlsElapsedTimeLabel setSelectable:NO];
  [hlsElapsedTimeLabel setTextColor:[NSColor whiteColor]];
  [hlsElapsedTimeLabel setFont:[NSFont systemFontOfSize:11]];
  [hlsElapsedTimeLabel setAlignment:NSTextAlignmentRight];
  [hlsElapsedTimeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsButCont addSubview:hlsElapsedTimeLabel];

  // Create total time label (right of seekbar)
  hlsTotalTimeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(120, 8, 30, 20)];
  [hlsTotalTimeLabel setStringValue:@"00:00"];
  [hlsTotalTimeLabel setBezeled:NO];
  [hlsTotalTimeLabel setDrawsBackground:NO];
  [hlsTotalTimeLabel setEditable:NO];
  [hlsTotalTimeLabel setSelectable:NO];
  [hlsTotalTimeLabel setTextColor:[NSColor whiteColor]];
  [hlsTotalTimeLabel setFont:[NSFont systemFontOfSize:11]];
  [hlsTotalTimeLabel setAlignment:NSTextAlignmentLeft];
  [hlsTotalTimeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsButCont addSubview:hlsTotalTimeLabel];

  // Create horizontal volume slider
  hlsVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(5, 27, 50, 20)];
  [hlsVolumeSlider setMinValue:0.0];
  [hlsVolumeSlider setMaxValue:1.0];
  [hlsVolumeSlider setDoubleValue:1.0]; // Default to full volume
  [hlsVolumeSlider setTarget:self];
  [hlsVolumeSlider setAction:@selector(volumeSliderChanged:)];
  [hlsVolumeSlider setControlSize:NSControlSizeSmall];
  [hlsVolumeSlider setVertical:NO]; // Horizontal slider
  [hlsVolumeSlider setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsButCont addSubview:hlsVolumeSlider];

  // Create play/pause button for HLS
  hlsPlayButton = [[HLSImageButton alloc] initWithFrame:NSMakeRect(70, 27, HLS_BUTTON_IMAGE_SIZE, HLS_BUTTON_IMAGE_SIZE)];
  [hlsPlayButton setButtonType:NSButtonTypeMomentaryChange];
  [hlsPlayButton setBordered:NO];
  [hlsPlayButton setImage:hls_button_image(GET_IMG(play_no_pad))];
  [hlsPlayButton setImagePosition:NSImageOnly];
  [hlsPlayButton setTarget:self];
  [hlsPlayButton setAction:@selector(togglePlayback)];
  [hlsPlayButton setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsButCont addSubview:hlsPlayButton];

  // Create live indicator label
  hlsLiveIndicator = [[NSTextField alloc] initWithFrame:NSMakeRect(100, 31, 13, 20)];
  [hlsLiveIndicator setStringValue:@"⬤"];
  [hlsLiveIndicator setBezeled:NO];
  [hlsLiveIndicator setDrawsBackground:NO];
  [hlsLiveIndicator setEditable:NO];
  [hlsLiveIndicator setSelectable:NO];
  [hlsLiveIndicator setTextColor:[NSColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0]]; // Red color for live indicator
  [hlsLiveIndicator setFont:[NSFont boldSystemFontOfSize:10]];
  [hlsLiveIndicator setAlignment:NSTextAlignmentLeft];
  [hlsLiveIndicator setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsLiveIndicator setHidden:YES]; // Hidden by default, shown when stream is live
  [hlsButCont addSubview:hlsLiveIndicator];

  // Create pop out button for HLS
  hlsPopButton = [[HLSImageButton alloc] initWithFrame:NSMakeRect(130, 27, HLS_BUTTON_IMAGE_SIZE, HLS_BUTTON_IMAGE_SIZE)];
  [hlsPopButton setButtonType:NSButtonTypeMomentaryChange];
  [hlsPopButton setBordered:NO];
  [hlsPopButton setImage:hls_button_image(GET_IMG(pop_no_pad))];
  [hlsPopButton setImagePosition:NSImageOnly];
  [hlsPopButton setTarget:self];
  [hlsPopButton setAction:@selector(toggleNativePip)];
  [hlsPopButton setTranslatesAutoresizingMaskIntoConstraints:NO];
  [hlsButCont addSubview:hlsPopButton];

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
  imageView.renderer = [(NSNumber*)getPref(@"renderer") intValue] == DisplayRendererTypeOpenGL ? [[OpenGLRenderer alloc] init:is_hidpi] : [[MetalRenderer alloc] init:is_hidpi];
  imageView.renderer.delegate = self;
  imageView.hidden = !is_airplay_session;

  [rootView addSubview:imageView];
  [rootView addSubview:pinbutt];

  // Add butCont last with highest z-index to ensure it's always on top
  [rootView addSubview:butCont positioned:NSWindowAbove relativeTo:nil];
  [rootView addSubview:hlsButCont positioned:NSWindowAbove relativeTo:nil];

  NSRect pinbutRect = pinbutt.frame;
  [[pinbutt.widthAnchor constraintEqualToConstant:pinbutRect.size.width] setActive:true];
  [[pinbutt.heightAnchor constraintEqualToConstant:pinbutRect.size.height] setActive:true];
  [[pinbutt.topAnchor constraintEqualToAnchor:rootView.topAnchor constant:pinbutRect.origin.x] setActive:true];
  [[pinbutt.rightAnchor constraintEqualToAnchor:rootView.rightAnchor constant:-pinbutRect.origin.y] setActive:true];

  [[butCont.widthAnchor constraintEqualToConstant:butContRect.size.width] setActive:true];
  [[butCont.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor constant:-butContRect.origin.x] setActive:true];

  [[hlsButCont.widthAnchor constraintEqualToConstant:hlsButContRect.size.width] setActive:true];
  [[hlsButCont.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor constant:-hlsButContRect.origin.x] setActive:true];

  // Create source hint overlay for blank windows
  if(!is_airplay_session){
    sourceHintOverlay = [[PassthroughView alloc] initWithFrame:kStartRect];
    sourceHintOverlay.wantsLayer = YES;
    sourceHintOverlay.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.6] CGColor];
    sourceHintOverlay.layer.cornerRadius = 10;
    sourceHintOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    hintLabel = [[NSTextField alloc] init];
    hintLabel.stringValue = @"Right-click to select source";
    hintLabel.editable = NO;
    hintLabel.selectable = NO;
    hintLabel.bezeled = NO;
    hintLabel.drawsBackground = NO;
    hintLabel.textColor = [NSColor whiteColor];
    hintLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    hintLabel.alignment = NSTextAlignmentCenter;
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [sourceHintOverlay addSubview:hintLabel];
    [sourceHintOverlay addConstraint:[NSLayoutConstraint constraintWithItem:hintLabel attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:sourceHintOverlay attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]];
    [sourceHintOverlay addConstraint:[NSLayoutConstraint constraintWithItem:hintLabel attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:sourceHintOverlay attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];

    [rootView addSubview:sourceHintOverlay positioned:NSWindowAbove relativeTo:nil];
  } // End of source hint overlay setup

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

  [self setupNonHLSControls];

  if(!is_airplay_session){
    NSDictionary* defaultSource = getDefaultSourcePreference();
    NSString* sourceType = defaultSource[@"type"];
    if([sourceType isEqualToString:@"display"]){
      int defaultDisplayId = [defaultSource[@"id"] intValue];
      if(defaultDisplayId > 0){
        BOOL hasDisplay = NO;
        NSArray* displays = getDisplayList();
        for(NSDictionary* display in displays){
          if([display[@"id"] intValue] == defaultDisplayId){
            hasDisplay = YES;
            break;
          }
        } // End of loop through displays
        if(hasDisplay){
          WindowSel* sel = [WindowSel getDefault];
          sel.title = getDisplayNameForId(defaultDisplayId);
          sel.dspId = defaultDisplayId;
          NSMenuItem* item = [[NSMenuItem alloc] init];
          [item setRepresentedObject:sel];
          [self changeWindow:item];
        }
      }
    } else if([sourceType isEqualToString:@"camera"]){
      NSString* defaultCameraId = defaultSource[@"id"];
      if(defaultCameraId && defaultCameraId.length > 0 && [AVCaptureDevice deviceWithUniqueID:defaultCameraId]){
        WindowSel* sel = [WindowSel getDefault];
        sel.title = getCameraNameForId(defaultCameraId);
        sel.cameraId = defaultCameraId;
        NSMenuItem* item = [[NSMenuItem alloc] init];
        [item setRepresentedObject:sel];
        [self changeWindow:item];
      }
    }
  } // End of if not airplay session

  // Register for display reconfiguration events (display disconnect)
  CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, (__bridge void*)self);

  return self;
}

- (void) loadHLSURL:(NSURL*)url {
  [self loadHLSURL:url withHeaders:nil];
}

- (void) loadHLSURL:(NSURL*)url withHeaders:(NSDictionary<NSString *, NSString *> *)headers {
  NSMenuItem* item = [[NSMenuItem alloc] init];
  [item setTarget:self];
  [item setRepresentedObject:[WindowSel getDefault]];
  [self changeWindow:item];

  is_hls_session = true;
  is_playing = true;
  is_hidpi = false; // HLS streams typically have fixed resolution

  hlsPlayer = [[HLSPlayer alloc] initWithURL:url headers:headers];
  hlsPlayer.delegate = self;

  imageView.hidden = NO;
  [self resetPlaybackSate];
  [self setOwner:@"HLS" withTitle:[url absoluteString]];
  isLiveStream = NO; // Will be updated when duration is known
  [self setupHLSControls];
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
  if(!mouse_timer){
    bool alphaVal = [self ignoresMouseEvents] ? 0 : 1;
    [[butCont animator] setAlphaValue:alphaVal];
    [[hlsButCont animator] setAlphaValue:alphaVal];
  }
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
    else{
      NSEvent *currentEvent = [self currentEvent];
      if(0
        || currentEvent.type == NSEventTypeLeftMouseDown
        || currentEvent.type == NSEventTypeLeftMouseDragged
      ) return;
      [[self->butCont animator] setAlphaValue:0];
      [[self->hlsButCont animator] setAlphaValue:0];
    }
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
  [[hlsButCont animator] setAlphaValue:alphaVal];
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
  if(is_airplay_session || display_id >= 0 || is_hls_session || window_stream || camera_id){
    is_playing = !is_playing;
    if(is_hls_session) {
      if(is_playing) [hlsPlayer play];
      else [hlsPlayer pause];
    }
    [self resetPlaybackSate];
  }
  else{
    if(timer) [self stopTimer];
    else [self startTimer:1.0/refreshRate];
  }
}

- (void)keyDown:(NSEvent *)event {
  if ([event keyCode] == 49) [self togglePlayback]; // Space bar key code
  else [super keyDown:event];
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
  if(timer || is_playing) {
    [playbutt setImage:GET_IMG(pause)];
    if(hlsPlayButton) {
      [hlsPlayButton setImage:hls_button_image(GET_IMG(pause_no_pad))];
    }
  } else {
    [playbutt setImage:GET_IMG(play)];
    if(hlsPlayButton) {
      [hlsPlayButton setImage:hls_button_image(GET_IMG(play_no_pad))];
    }
  }
  [self mouseMoved:[self currentEvent]];
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
  if(shouldClose || CGSizeEqualToSize(CGSizeZero, rect.size)) return;
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
  // NSLog(@"onResize: %@ %@", NSStringFromSize(size), NSStringFromSize(ar));
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
  if(hlsPlayer) {
    [hlsPlayer setVolume:volume];
    // Update volume slider if it exists
    if (hlsVolumeSlider) {
      [hlsVolumeSlider setDoubleValue:volume];
    }
  }
}

- (void)hlsPlayerDidUpdateFrame:(CIImage *)image {
  if(!is_playing || isWinClosing) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->imageView setImage:image];
  });
}

- (void)hlsPlayerDidChangeStatus:(AVPlayerItemStatus)status {
  if(status == AVPlayerItemStatusReadyToPlay) {
    [hlsPlayer play];
    CMTime duration = hlsPlayer.duration;
    if(CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
      NSSize videoSize = NSMakeSize(1920, 1080); // Default, will be updated from frame
      [self onResize:videoSize andAspectRatio:videoSize];
    }
    // Initialize volume slider with current player volume
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->hlsVolumeSlider) {
        [self->hlsVolumeSlider setDoubleValue:self->hlsPlayer.player.volume];
      }
    });
  } else if(status == AVPlayerItemStatusFailed) {
    NSLog(@"HLS player failed to load");
  }
}

- (void)hlsPlayerDidChangeTime:(CMTime)time {
  if (isSeeking) return; // Don't update slider while user is seeking

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->hlsSeekSlider && CMTIME_IS_VALID(time)) {
      if (self->isLiveStream) {
        // For live streams, use seekable time ranges (buffered window)
        AVPlayerItem *item = self->hlsPlayer.player.currentItem;
        if (item && item.seekableTimeRanges.count > 0) {
          CMTimeRange seekableRange = [[item.seekableTimeRanges lastObject] CMTimeRangeValue];
          CMTime seekableStart = seekableRange.start;
          CMTime seekableDuration = seekableRange.duration;

          if (CMTIME_IS_VALID(seekableStart) && CMTIME_IS_VALID(seekableDuration)) {
            double currentSeconds = CMTimeGetSeconds(time);
            double seekableStartSeconds = CMTimeGetSeconds(seekableStart);
            double seekableDurationSeconds = CMTimeGetSeconds(seekableDuration);

            // Calculate position within seekable range (0.0 = start of buffer, 1.0 = live edge)
            if (seekableDurationSeconds > 0) {
              double relativePosition = (currentSeconds - seekableStartSeconds) / seekableDurationSeconds;
              relativePosition = fmax(0.0, fmin(1.0, relativePosition)); // Clamp to [0, 1]
              [self->hlsSeekSlider setDoubleValue:relativePosition];

              // Update time label showing position in buffer
              double bufferPosition = currentSeconds - seekableStartSeconds;
              [self updateHLSLiveTimeLabel:bufferPosition bufferDuration:seekableDurationSeconds];
            }
          }
        }
      } else {
        // For non-live streams, use duration
        CMTime duration = self->hlsPlayer.duration;
        if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
          double currentSeconds = CMTimeGetSeconds(time);
          double durationSeconds = CMTimeGetSeconds(duration);
          if (durationSeconds > 0) {
            [self->hlsSeekSlider setDoubleValue:currentSeconds / durationSeconds];
            [self updateHLSTimeLabel:currentSeconds duration:durationSeconds];
          }
        }
      }
    }
  });
}

- (void)hlsPlayerDidEncounterError:(NSError *)error {
  NSLog(@"HLS player error: %@", error);
  // Show error to user
  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert *errorAlert = [[NSAlert alloc] init];
    [errorAlert setMessageText:@"HLS Stream Error"];
    NSString *errorDescription = error.localizedDescription ?: @"Unknown error occurred";
    [errorAlert setInformativeText:[NSString stringWithFormat:@"Failed to load HLS stream:\n\n%@", errorDescription]];
    [errorAlert addButtonWithTitle:@"OK"];
    [errorAlert setAlertStyle:NSAlertStyleWarning];
    [errorAlert runModal];
  });
}

- (void)hlsPlayerDidChangeLoadingStatus:(BOOL)isLoading {
  if (isLoading) {
    NSLog(@"HLS player is buffering/loading");
    // Could show a loading indicator here if needed
  } else {
    // NSLog(@"HLS player finished loading");
    // Could hide loading indicator here if needed
  }
}

- (void)hlsPlayerDidChangePlaybackRate:(float)rate {
  NSLog(@"HLS player playback rate changed: %.2f", rate);
  // Could update UI to show playback speed if needed
}

- (void)hlsPlayerDidChangeSeekableRanges:(NSArray<NSValue *> *)seekableTimeRanges {
  // Update live stream time labels when seekable range changes
  if (isLiveStream && hlsPlayer && seekableTimeRanges.count > 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      CMTimeRange seekableRange = [[seekableTimeRanges lastObject] CMTimeRangeValue];
      CMTime seekableDuration = seekableRange.duration;
      if (CMTIME_IS_VALID(seekableDuration)) {
        double bufferDurationSeconds = CMTimeGetSeconds(seekableDuration);
        CMTime currentTime = [self->hlsPlayer.player currentTime];
        if (CMTIME_IS_VALID(currentTime)) {
          CMTime seekableStart = seekableRange.start;
          if (CMTIME_IS_VALID(seekableStart)) {
            double currentSeconds = CMTimeGetSeconds(currentTime);
            double seekableStartSeconds = CMTimeGetSeconds(seekableStart);
            double bufferPosition = currentSeconds - seekableStartSeconds;
            [self updateHLSLiveTimeLabel:bufferPosition bufferDuration:bufferDurationSeconds];

            // Update slider position (1.0 = live edge)
            if (self->hlsSeekSlider && bufferDurationSeconds > 0) {
              double relativePosition = bufferPosition / bufferDurationSeconds;
              relativePosition = fmax(0.0, fmin(1.0, relativePosition));
              if (!self->isSeeking) {
                [self->hlsSeekSlider setDoubleValue:relativePosition];
              }
            }
          }
        }
      }
    });
  }
}

- (void)hlsPlayerDidChangeDuration:(CMTime)duration {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Check if this is a live stream (indefinite duration)
    if (CMTIME_IS_INDEFINITE(duration)) {
      self->isLiveStream = YES;
      NSLog(@"HLS player: Live stream detected (indefinite duration)");

      // Show live indicator
      if (self->hlsLiveIndicator) {
        [self->hlsLiveIndicator setHidden:NO];
      }

      // Enable seek slider for live streams (allows seeking within buffer window)
      if (self->hlsSeekSlider) {
        [self->hlsSeekSlider setEnabled:YES];
        [self->hlsSeekSlider setAlphaValue:1.0]; // Full opacity
        // Set slider to end (live edge) initially
        [self->hlsSeekSlider setDoubleValue:1.0];
      }

      // Update time labels for live stream (will be updated as buffer changes)
      if (self->hlsElapsedTimeLabel) {
        [self->hlsElapsedTimeLabel setTextColor:[NSColor whiteColor]];
      }
      if (self->hlsTotalTimeLabel) {
        [self->hlsTotalTimeLabel setTextColor:[NSColor whiteColor]];
      }

      // Update time labels based on current seekable range
      AVPlayerItem *item = self->hlsPlayer.player.currentItem;
      if (item && item.seekableTimeRanges.count > 0) {
        CMTimeRange seekableRange = [[item.seekableTimeRanges lastObject] CMTimeRangeValue];
        CMTime seekableDuration = seekableRange.duration;
        if (CMTIME_IS_VALID(seekableDuration)) {
          double bufferDurationSeconds = CMTimeGetSeconds(seekableDuration);
          CMTime currentTime = [self->hlsPlayer.player currentTime];
          if (CMTIME_IS_VALID(currentTime)) {
            CMTime seekableStart = seekableRange.start;
            if (CMTIME_IS_VALID(seekableStart)) {
              double currentSeconds = CMTimeGetSeconds(currentTime);
              double seekableStartSeconds = CMTimeGetSeconds(seekableStart);
              double bufferPosition = currentSeconds - seekableStartSeconds;
              [self updateHLSLiveTimeLabel:bufferPosition bufferDuration:bufferDurationSeconds];
            }
          }
        }
      }
    } else if (CMTIME_IS_VALID(duration)) {
      self->isLiveStream = NO;
      double durationSeconds = CMTimeGetSeconds(duration);
      NSLog(@"HLS player duration: %.2f seconds", durationSeconds);

      // Hide live indicator
      if (self->hlsLiveIndicator) {
        [self->hlsLiveIndicator setHidden:YES];
      }

      // Enable seek slider for non-live streams
      if (self->hlsSeekSlider) {
        [self->hlsSeekSlider setEnabled:YES];
        [self->hlsSeekSlider setAlphaValue:1.0]; // Full opacity
      }

      // Update time labels with normal time display
      if (self->hlsElapsedTimeLabel) {
        [self->hlsElapsedTimeLabel setTextColor:[NSColor whiteColor]];
      }
      if (self->hlsTotalTimeLabel) {
        [self->hlsTotalTimeLabel setTextColor:[NSColor whiteColor]];
      }

      if (self->hlsSeekSlider) {
        // Keep maxValue at 1.0 for normalized 0-1 range
        CMTime currentTime = [self->hlsPlayer.player currentTime];
        if (CMTIME_IS_VALID(currentTime)) {
          double currentSeconds = CMTimeGetSeconds(currentTime);
          // Update slider position based on normalized value
          if (durationSeconds > 0) {
            double normalizedValue = currentSeconds / durationSeconds;
            if (normalizedValue >= 0.0 && normalizedValue <= 1.0) {
              [self->hlsSeekSlider setDoubleValue:normalizedValue];
            }
          }
          [self updateHLSTimeLabel:currentSeconds duration:durationSeconds];
        }
      }
    }
  });
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
  // Skip capture if using ScreenCaptureKit stream (it handles frames directly)
  // If window_stream is active, the timer shouldn't be running, but check defensively
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    if (window_stream) {
      return; // ScreenCaptureKit stream handles frames via callback
    }
  }
#endif

  // Use legacy methods for older macOS or when ScreenCaptureKit is unavailable
  CGImageRef window_image = window_id >= 0 ? CaptureWindow(window_id, is_hidpi) : (display_id >= 0 ? CGDisplayCreateImage(display_id) : NULL);
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

  if(@available(macOS 11.0, *)){
    if(!AXIsProcessTrusted()) return request_permission("Accessibility");
  }

  if(@available(macOS 14.0, *)) bringWindowToForegroundModern(window_id);
  else bringWindoToForeground(window_id);
}

- (bool)is_capturing{
  return display_id >= 0 || window_id >= 0 || is_hls_session || camera_id != nil;
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
  NSMenu* camera_menu = [[NSMenu alloc] init];
  NSArray<AVCaptureDevice *> *cameras;

  #ifndef NO_AIRPLAY
  // Only show AirPlay sender options if sender is enabled
  bool airplay_sender_enabled = [(NSNumber*)getPref(@"airplay_sender") intValue] > 0;
  [airplayDiscovery updateReceivers];
  NSArray<AirPlayReceiver *> *receivers = [airplayDiscovery receivers];
  #endif

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

    NSString* windowTitle = getDisplayNameForId(did);

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
      CGImageRef window_image = CaptureWindow(windowId, false);
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
    ADD_MENU_ITEM(theMenu, @"Display", nil, GET_REL_IMG(display), {
      [item setSubmenu:display_menu];
    })
  }

  if(window_menu.numberOfItems > 0){
    ADD_MENU_ITEM(theMenu, @"Window", nil, GET_REL_IMG(windows), {
      [item setSubmenu:window_menu];
    })
  }

  // Add camera menu
  cameras = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for(AVCaptureDevice *camera in cameras){
    NSString* cameraName = getCameraNameForId([camera uniqueID]);
    WindowSel* sel = [WindowSel getDefault];
    sel.title = cameraName;
    sel.cameraId = [camera uniqueID];
    ADD_MENU_ITEM(camera_menu, cameraName, @selector(changeWindow:), NULL, {
      [item setRepresentedObject:sel];
    })
  }
  if(camera_menu.numberOfItems > 0){
    ADD_MENU_ITEM(theMenu, @"Camera", nil, GET_REL_IMG(camera), {
      [item setSubmenu:camera_menu];
    })
  }

  ADD_MENU_ITEM(theMenu, @"Open Stream URL…", @selector(loadHLSStream:), GET_REL_IMG(hls))
#ifndef NO_AIRPLAY
  if (airplay_sender_enabled && [self is_capturing]) {
    // Show start/stop options based on senderQueue state
    if (!senderQueue) {
      // Not mirroring - show "AirPlay Mirror to..." menu
      // AirPlay Sender menu (for mirroring/sending content)
      NSMenu *airplaySendMenu = [[NSMenu alloc] init];
      for (AirPlayReceiver *receiver in receivers) {
        if (!receiver.supportsScreenMirroring) {
          continue;  // Skip receivers that don't support mirroring
        }
        NSString *title = receiver.name;
        if (receiver.requiresPassword) {
          title = [title stringByAppendingString:@" 🔒"];
        }
        // Add connection status indicator
        if (connectedSenderReceiver && [connectedSenderReceiver.deviceId isEqualToString:receiver.deviceId]) {
          title = [title stringByAppendingString:@" ✓"];
        }
        ADD_MENU_ITEM(airplaySendMenu, title, @selector(connectToAirPlaySender:), NULL, {
          [item setRepresentedObject:receiver];
          // Set checkmark state for connected sender receiver
          if (connectedSenderReceiver && [connectedSenderReceiver.deviceId isEqualToString:receiver.deviceId]) {
            [item setState:NSControlStateValueOn];
          }
        })
      }
      if (airplaySendMenu.numberOfItems > 0) {
        ADD_MENU_ITEM(theMenu, @"AirPlay Mirror to...", nil, GET_REL_IMG(airplay), {
          [item setSubmenu:airplaySendMenu];
        })
      }
    } else {
      NSString *mirroringTitle = [NSString stringWithFormat:@"Stop Mirroring to %@", connectedSenderReceiver.name];
      ADD_MENU_ITEM(theMenu, mirroringTitle, @selector(stopAirPlayMirroring:), GET_REL_IMG(airplay_stop))
    }
  }
#endif

  // Streaming submenu
  if ([self is_capturing] || is_hls_session || camera_id) {
    NSMenu *streamMenu = [[NSMenu alloc] init];

    if (streamManager && [streamManager isStreaming]) {
      ADD_MENU_ITEM(streamMenu, @"Stop Broadcasting", @selector(stopStreamAction:), NULL)
      [streamMenu addItem:[NSMenuItem separatorItem]];
      ADD_MENU_ITEM(streamMenu, @"Copy URL", @selector(copyStreamURL:), NULL)
      ADD_MENU_ITEM(streamMenu, @"Open in Browser", @selector(openStreamInBrowser:), NULL)
    } else {
      ADD_MENU_ITEM(streamMenu, @"Broadcast This Window", @selector(startStreamAction:), NULL)
    }

    [streamMenu addItem:[NSMenuItem separatorItem]];

    // Quality submenu
    NSMenu *qualitySubmenu = [[NSMenu alloc] init];
    StreamQuality currentQ = streamManager ? [streamManager currentQuality] : StreamQualityMedium;

    NSArray *qualityNames = @[@"Low (720p)", @"Medium (1080p)", @"High (native)"];
    NSArray *qualityValues = @[@(StreamQualityLow), @(StreamQualityMedium), @(StreamQualityHigh)];

    for (int i = 0; i < 3; i++) {
      NSMenuItem *qItem = [qualitySubmenu addItemWithTitle:qualityNames[i] action:@selector(setStreamQuality:) keyEquivalent:@""];
      [qItem setTarget:self];
      [qItem setTag:[qualityValues[i] intValue]];
      if ([qualityValues[i] intValue] == (int)currentQ) {
        [qItem setState:NSControlStateValueOn];
      }
    } // End of loop through quality options

    ADD_MENU_ITEM(streamMenu, @"Quality", nil, NULL, {
      [item setSubmenu:qualitySubmenu];
    })

    // Show URL as info if streaming
    if (streamManager && [streamManager isStreaming]) {
      [streamMenu addItem:[NSMenuItem separatorItem]];
      NSString *url = [streamManager streamURL];
      if (url) {
        NSMenuItem *urlItem = [streamMenu addItemWithTitle:url action:nil keyEquivalent:@""];
        [urlItem setEnabled:NO];
      }
    }

    ADD_MENU_ITEM(theMenu, @"Broadcast", nil, NULL, {
      [item setSubmenu:streamMenu];
    })
  }

end:
  if(is_hls_session && !pvc){
    // Add quality/resolution selection menu for HLS
    if (hlsPlayer) {
      NSMenu *qualityMenu = [[NSMenu alloc] init];
      NSArray<NSDictionary *> *qualities = [hlsPlayer getAvailableQualities];
      NSDictionary *currentQuality = [hlsPlayer getCurrentQuality];

      for (NSDictionary *quality in qualities) {
        NSString *qualityName = quality[@"name"];
        NSMenuItem *qualityItem = [qualityMenu addItemWithTitle:qualityName action:@selector(selectHLSQuality:) keyEquivalent:@""];
        [qualityItem setTarget:self];
        [qualityItem setRepresentedObject:quality];

        // Mark current quality with checkmark
        if ([qualityName isEqualToString:currentQuality[@"name"]]) {
          [qualityItem setState:NSControlStateValueOn];
        }
      }

      ADD_MENU_ITEM(theMenu, @"Video Quality", nil, NULL, {
        [item setSubmenu:qualityMenu];
      })
    }
  }

  if(camera_id && !pvc){
    // Add resolution selection menu for camera
    NSMenu *resolutionMenu = [[NSMenu alloc] init];
    NSArray<NSDictionary *> *resolutions = [self getAvailableCameraResolutions:camera_id];
    NSDictionary *currentResolution = [self getCurrentCameraResolution];

    // Get the actual active format from device for accurate comparison
    AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:camera_id];
    AVCaptureDeviceFormat *activeFormat = device ? device.activeFormat : nil;

    for (NSDictionary *resolution in resolutions) {
      NSString *resolutionName = resolution[@"name"];
      NSMenuItem *resolutionItem = [resolutionMenu addItemWithTitle:resolutionName action:@selector(selectCameraResolution:) keyEquivalent:@""];
      [resolutionItem setTarget:self];
      [resolutionItem setRepresentedObject:resolution];

      // Mark current resolution with checkmark - compare both name and format for accuracy
      AVCaptureDeviceFormat *resolutionFormat = resolution[@"format"];
      BOOL isCurrent = NO;
      if (currentResolution && activeFormat) {
        // Compare by format object first (most accurate), then fall back to name
        if (resolutionFormat == activeFormat || [resolutionFormat isEqual:activeFormat]) {
          isCurrent = YES;
        } else if ([resolutionName isEqualToString:currentResolution[@"name"]]) {
          isCurrent = YES;
        }
      }

      if (isCurrent) {
        [resolutionItem setState:NSControlStateValueOn];
      }
    }

    if (resolutionMenu.numberOfItems > 0) {
      ADD_MENU_ITEM(theMenu, @"Camera Resolution", nil, NULL, {
        [item setSubmenu:resolutionMenu];
      })
    }

    // Local audio monitoring toggle (does not affect HLS streaming)
    if(camera_has_microphone) {
      ADD_MENU_ITEM(theMenu, @"Local Audio Monitoring", @selector(toggleCameraAudio:), NULL, {
        if(camera_audio_monitoring) {
          [item setState:NSControlStateValueOn];
        }
      })
    }
  }

  if(!pvc && ([self is_capturing] || is_airplay_session || is_hls_session)){
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
  if(is_hls_session || camera_output) [imageView.renderer setScale:[sender tag] * self.backingScaleFactor];
  else if([self is_capturing] || is_airplay_session) [imageView.renderer setScale:[sender tag]];
}

- (void)adjustOpacity:(id)sender{
  NSSlider* slider = (NSSlider*)sender;
  [self setAlphaValue:slider.doubleValue];
}

#pragma mark - Streaming Methods

/**
 * Start streaming the current window content.
 * Creates a StreamManager if needed, reads port/quality from preferences,
 * and copies the stream URL to the clipboard on success.
 */
- (void)startStreamAction:(id)sender {
  if (!imageView) return;

  if (!streamManager) {
    streamManager = [[StreamManager alloc] initWithImageView:imageView];
  }

  // stream_port is stored as NSString by TextInput preferences
  NSObject *portPref = getPref(@"stream_port");
  int port = 8080;
  if ([portPref isKindOfClass:[NSString class]]) {
    port = [(NSString*)portPref intValue];
  } else if ([portPref isKindOfClass:[NSNumber class]]) {
    port = [(NSNumber*)portPref intValue];
  }
  if (port <= 0 || port > 65535) port = 8080;

  StreamQuality quality = (StreamQuality)[(NSNumber*)getPref(@"stream_quality") intValue];

  BOOL success = [streamManager startStreamingOnPort:port withQuality:quality];
  if (success) {
    NSString *url = [streamManager streamURL];
    NSLog(@"Streaming started at %@", url);
    // Copy direct stream URL to clipboard automatically
    NSString *directURL = [url stringByAppendingString:@"/stream.m3u8"];
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:directURL forType:NSPasteboardTypeString];
  }
} // End of startStreamAction:

/**
 * Stop the current streaming session.
 */
- (void)stopStreamAction:(id)sender {
  if (streamManager) {
    [streamManager stopStreaming];
  }
} // End of stopStreamAction:

/**
 * Copy the stream URL to the system clipboard.
 */
- (void)copyStreamURL:(id)sender {
  if (streamManager && [streamManager isStreaming]) {
    NSString *url = [streamManager streamURL];
    if (url) {
      NSString *directURL = [url stringByAppendingString:@"/stream.m3u8"];
      [[NSPasteboard generalPasteboard] clearContents];
      [[NSPasteboard generalPasteboard] setString:directURL forType:NSPasteboardTypeString];
    }
  }
} // End of copyStreamURL:

/**
 * Open the stream URL in the default web browser.
 */
- (void)openStreamInBrowser:(id)sender {
  if (streamManager && [streamManager isStreaming]) {
    NSString *url = [streamManager streamURL];
    if (url) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
    }
  }
} // End of openStreamInBrowser:

/**
 * Set the streaming quality from a menu item tag.
 * Saves the preference and updates the active stream if running.
 */
- (void)setStreamQuality:(id)sender {
  NSMenuItem *menuItem = (NSMenuItem *)sender;
  StreamQuality quality = (StreamQuality)[menuItem tag];
  setPref(@"stream_quality", [NSNumber numberWithInt:(int)quality]);
  if (streamManager) {
    [streamManager setQuality:quality];
  }
} // End of setStreamQuality:

-(void)stopDisplayStream{
  if(!display_stream) return;
  CGDisplayStreamStop(display_stream);
  CFRelease(display_stream);
  display_stream = NULL;
}

-(void)stopWindowStream{
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    if(!window_stream) return;
    [window_stream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
      // Stream stopped
    }];
    window_stream = nil;
    window_stream_config = nil;
    is_window_stream_updating = false;
  }
#endif
}

#pragma mark - Camera Audio Methods

/**
 * Stops camera capture and cleans up resources.
 */
-(void)stopCameraCapture{
  if(!camera_session) return;

  // Remove notification observers before stopping
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:camera_session];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:camera_session];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceWasDisconnectedNotification object:nil];

  [camera_session stopRunning];

  // Clean up audio preview
  camera_audio_preview = nil;
  camera_has_microphone = false;

  camera_session = nil;
  camera_input = nil;
  camera_output = nil;
  camera_audio_output = nil;
  camera_id = nil;
  camera_format = nil;
  camera_position = AVCaptureDevicePositionUnspecified;
  camera_audio_sample_count = 0;
} // End of stopCameraCapture

-(NSArray<NSDictionary *> *)getAvailableCameraResolutions:(NSString*)deviceId {
  NSMutableArray *resolutions = [[NSMutableArray alloc] init];

  AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceId];
  if(!device) {
    return resolutions;
  }

  NSArray<AVCaptureDeviceFormat *> *formats = device.formats;
  NSMutableSet *seenResolutions = [[NSMutableSet alloc] init];

  for(AVCaptureDeviceFormat *format in formats) {
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    if(dimensions.width > 0 && dimensions.height > 0) {
      NSString *resolutionKey = [NSString stringWithFormat:@"%dx%d", dimensions.width, dimensions.height];
      if(![seenResolutions containsObject:resolutionKey]) {
        [seenResolutions addObject:resolutionKey];
        [resolutions addObject:@{
          @"name": resolutionKey,
          @"width": @(dimensions.width),
          @"height": @(dimensions.height),
          @"format": format
        }];
      }
    }
  }

  // Sort by resolution (width * height) descending
  [resolutions sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
    int area1 = [obj1[@"width"] intValue] * [obj1[@"height"] intValue];
    int area2 = [obj2[@"width"] intValue] * [obj2[@"height"] intValue];
    if(area1 > area2) return NSOrderedAscending;
    if(area1 < area2) return NSOrderedDescending;
    return NSOrderedSame;
  }];

  return resolutions;
}

-(NSDictionary *)getCurrentCameraResolution {
  if(!camera_id) {
    return nil;
  }

  // Get the actual active format from the device to ensure accuracy
  AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:camera_id];
  if(!device) {
    return nil;
  }

  AVCaptureDeviceFormat *activeFormat = device.activeFormat;
  if(!activeFormat) {
    return nil;
  }

  CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription);
  NSString *resolutionKey = [NSString stringWithFormat:@"%dx%d", dimensions.width, dimensions.height];

  // Update stored format to match actual active format
  camera_format = activeFormat;

  return @{
    @"name": resolutionKey,
    @"width": @(dimensions.width),
    @"height": @(dimensions.height),
    @"format": activeFormat
  };
}

-(void)startCameraCapture:(NSString*)deviceId{
  [self stopCameraCapture];

  AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceId];
  if(!device) {
    NSLog(@"Camera device not found: %@", deviceId);
    return;
  }

  // Ensure camera permission is granted or request it if needed
  AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if(authStatus == AVAuthorizationStatusDenied || authStatus == AVAuthorizationStatusRestricted) {
    request_permission("Camera");
    return;
  }
  if(authStatus == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if(granted) {
          [self startCameraCapture:deviceId];
        } else {
          request_permission("Camera");
        }
      });
    }];
    return;
  }

  NSError *error = nil;
  AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
  if(error || !input) {
    NSLog(@"Failed to create camera input: %@", error);
    // If creation failed due to missing authorization, prompt user
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if(status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
      request_permission("Camera");
    }
    return;
  }

  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  session.sessionPreset = AVCaptureSessionPresetHigh;

  if(![session canAddInput:input]) {
    NSLog(@"Cannot add camera input to session");
    return;
  }
  [session addInput:input];

  // Store camera position to determine if we need to un-mirror
  AVCaptureDevicePosition cameraPosition = device.position;

  // Set the active format if one was previously selected
  if(camera_format && [device.formats containsObject:camera_format]) {
    if([device lockForConfiguration:&error]) {
      device.activeFormat = camera_format;
      [device unlockForConfiguration];
    } else {
      NSLog(@"Failed to lock device for configuration: %@", error);
    }
  } else if(!camera_format) {
    // Use the highest resolution format by default
    NSArray<NSDictionary *> *resolutions = [self getAvailableCameraResolutions:deviceId];
    if(resolutions.count > 0) {
      NSDictionary *highestRes = resolutions[0];
      AVCaptureDeviceFormat *format = highestRes[@"format"];
      if([device lockForConfiguration:&error]) {
        device.activeFormat = format;
        camera_format = format;
        [device unlockForConfiguration];
      }
    }
  }

  AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
  output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};

  dispatch_queue_t queue = dispatch_queue_create("com.pip.camera", DISPATCH_QUEUE_SERIAL);
  [output setSampleBufferDelegate:self queue:queue];

  if(![session canAddOutput:output]) {
    NSLog(@"Cannot add camera output to session");
    return;
  }
  [session addOutput:output];

  // Get the connection and explicitly disable mirroring
  AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
  if(connection && connection.isVideoMirroringSupported) {
    // Try to disable automatic mirroring
    if([connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
      connection.automaticallyAdjustsVideoMirroring = NO;
    }
    // Note: videoMirrored is read-only, so we can't set it directly
    // We'll handle un-mirroring in the capture output delegate if needed
  }

  // Set up audio preview if enabled - uses AVCaptureAudioPreviewOutput for automatic format handling
  camera_has_microphone = false;
  camera_audio_preview = nil;
  camera_audio_output = nil;
  camera_audio_sample_count = 0;

  if(camera_audio_enabled) {
    // Check microphone permission
    AVAuthorizationStatus audioAuthStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    
    __block BOOL micPermissionGranted = (audioAuthStatus == AVAuthorizationStatusAuthorized);
    
    if(audioAuthStatus == AVAuthorizationStatusNotDetermined) {
      // Request permission synchronously using a semaphore
      dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        micPermissionGranted = granted;
        dispatch_semaphore_signal(semaphore);
      }];
      dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }

    if(micPermissionGranted) {
      // Try to find an audio device associated with this camera
      AVCaptureDevice *audioDevice = nil;
      NSArray<AVCaptureDevice *> *audioDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
      
      for(AVCaptureDevice *audioD in audioDevices) {
        if([audioD.localizedName containsString:device.localizedName] ||
           [audioD.manufacturer isEqualToString:device.manufacturer]) {
          audioDevice = audioD;
          NSLog(@"Found matching audio device: %@ for camera: %@", audioD.localizedName, device.localizedName);
          break;
        }
      }

      // If no matching audio device found, use the default microphone
      if(!audioDevice && audioDevices.count > 0) {
        audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        NSLog(@"Using default audio device: %@", audioDevice.localizedName);
      }

      if(audioDevice) {
        NSError *audioError = nil;
        AVCaptureDeviceInput *audioInput = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:&audioError];
        
        if(audioError || !audioInput) {
          NSLog(@"Failed to create audio input: %@", audioError);
        } else if(![session canAddInput:audioInput]) {
          NSLog(@"Cannot add audio input to camera session");
        } else {
          [session addInput:audioInput];

          AVCaptureAudioDataOutput *audioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
          dispatch_queue_t audioQueue = dispatch_queue_create("com.pip.camera.audio", DISPATCH_QUEUE_SERIAL);
          [audioDataOutput setSampleBufferDelegate:self queue:audioQueue];
          if([session canAddOutput:audioDataOutput]) {
            [session addOutput:audioDataOutput];
            camera_audio_output = audioDataOutput;
            camera_has_microphone = true;
            NSLog(@"Camera audio stream output configured for outgoing HLS audio");
          } else {
            NSLog(@"Cannot add audio data output to camera session");
          }

          // Use AVCaptureAudioPreviewOutput for automatic audio playback
          // This handles all format conversion automatically
          AVCaptureAudioPreviewOutput *audioPreview = [[AVCaptureAudioPreviewOutput alloc] init];
          audioPreview.volume = camera_audio_monitoring ? 1.0 : 0.0;
          audioPreview.outputDeviceUniqueID = nil;  // Use default output device

          if(![session canAddOutput:audioPreview]) {
            NSLog(@"Cannot add audio preview output to camera session");
          } else {
            [session addOutput:audioPreview];
            camera_audio_preview = audioPreview;
            camera_has_microphone = true;
            NSLog(@"Camera audio preview configured for device: %@", audioDevice.localizedName);
          }
        }
      }
    } else {
      NSLog(@"Microphone permission not granted, camera audio disabled");
    }
  } // End of audio configuration

  camera_session = session;
  camera_input = input;
  camera_output = output;
  camera_id = deviceId;
  camera_position = cameraPosition;

  // Store the current active format
  if(!camera_format) {
    camera_format = device.activeFormat;
  }

  // Register for camera disconnect/error notifications
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cameraSessionError:) name:AVCaptureSessionRuntimeErrorNotification object:session];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cameraSessionError:) name:AVCaptureSessionDidStopRunningNotification object:session];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cameraSessionError:) name:AVCaptureDeviceWasDisconnectedNotification object:device];

  // Start session after all inputs/outputs are configured
  [session startRunning];

  is_playing = true;
  [self resetPlaybackSate];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  if(!is_playing || isWinClosing || !camera_session) return;

  if([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
    camera_audio_sample_count++;
    if(camera_audio_sample_count == 1 || (camera_audio_sample_count % 500 == 0)) {
      NSLog(@"Camera audio callback samples=%llu", (unsigned long long)camera_audio_sample_count);
    }
    if(streamManager && [streamManager isStreaming]) {
      [streamManager pushAudioSampleBuffer:sampleBuffer];
    }
    return;
  }

  if(![output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
    return;
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if(!imageBuffer) return;

  CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];

  if(ciImage) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if(self->is_playing && !self->isWinClosing) {
        [self->imageView setImage:ciImage];
      }
    });
  }
} // End of captureOutput:didOutputSampleBuffer:fromConnection:

- (void)changeWindow:(id)sender{
  WindowSel* sel = [sender representedObject];
  BOOL cameraMatch = (sel.cameraId == nil && camera_id == nil) || [camera_id isEqualToString:sel.cameraId];
  if(window_id == sel.winId && display_id == sel.dspId && cameraMatch && !is_hls_session) return;

  [self stopTimer];
  [self stopDisplayStream];
  [self stopWindowStream];
  [self stopCameraCapture];
  #ifndef NO_AIRPLAY
  [self stopAirPlayMirroring:sender];
  #endif

  if(hlsPlayer) {
    [hlsPlayer stop];
    hlsPlayer = nil;
    is_hls_session = false;
  }

  is_playing = false;
  [self resetPlaybackSate];

  CIImage* img = [self->imageView.renderer currentImage];
  if(img){
    CIImage *transparentImage = [CIImage imageWithColor:[CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0]];
    CIImage *finalImage = [transparentImage imageByCroppingToRect:img.extent];
    NSLog(@"finalImage: %@", finalImage);
    [self->imageView setImage:finalImage];
  }

  // Restore non-HLS controls when HLS session ends
  [self setupNonHLSControls];

  window_id = sel.winId;
  display_id = sel.dspId;
  owner_pid = sel.ownerPid;

  if(sel.cameraId){
    [self startCameraCapture:sel.cameraId];
  }
  else if(display_id >= 0){
    size_t width = CGDisplayPixelsWide(display_id);
    size_t height = CGDisplayPixelsHigh(display_id);
    if(is_hidpi) width *= self.backingScaleFactor, height *= self.backingScaleFactor;

    NSDictionary* opts = @{
      (__bridge NSString *)kCGDisplayStreamMinimumFrameTime : @(1.0f / refreshRate),
      (__bridge NSString *)kCGDisplayStreamShowCursor : [(NSNumber*)getPref(@"mouse_capture") intValue] > 0 ? @YES : @NO,
    };

    display_stream = CGDisplayStreamCreateWithDispatchQueue(display_id, width, height, kCVPixelFormatType_32BGRA,  (__bridge CFDictionaryRef)opts, dispatch_get_main_queue(), ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
      if(status == kCGDisplayStreamFrameStatusStopped){
        if(!self->isWinClosing) [self showDisconnectOverlay:@"Display disconnected"];
        return;
      }
      if(status != kCGDisplayStreamFrameStatusFrameComplete || !self->is_playing || self->isWinClosing) return;
      [self->imageView setImage:[CIImage imageWithIOSurface:frameSurface]];
    });
    CGDisplayStreamStart(display_stream);

    is_playing = true;
    [self resetPlaybackSate];
  }
  else if(window_id >= 0){
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
    // Check if ScreenCaptureKit is enabled in preferences and available
    bool use_screencapturekit = false;
    if (@available(macOS 12.3, *)) {
      use_screencapturekit = [(NSNumber*)getPref(@"use_screencapturekit") intValue] > 0;
    }
    if (use_screencapturekit) {
      [self startWindowStream];
    } else {
      // ScreenCaptureKit disabled in preferences or unavailable, use timer-based capture
      [self startTimer:1.0/refreshRate];
    }
#else
    // ScreenCaptureKit not available, use timer-based capture
    [self startTimer:1.0/refreshRate];
#endif
  }

  [self setMovable:YES];
  [selectionView removeFromSuperview];
  dispatch_async(dispatch_get_main_queue(), ^{[[NSCursor arrowCursor] set];});
//  [imageView setImage:nil];
  [imageView setHidden:![self is_capturing]];
  [self setOwner:sel.owner withTitle:sel.title];

  // Hide or show source hint overlay based on capture state
  if(sourceHintOverlay){
    [sourceHintOverlay setHidden:[self is_capturing]];
  }
}

/**
 * Shows the disconnect overlay with a message explaining why the source was lost.
 * Stops all capture, resets source state, and displays the overlay with the given message
 * plus a hint to right-click for a new source.
 * Must be called on the main thread.
 * @param message The disconnect reason to display (e.g. "Display disconnected")
 */
- (void)showDisconnectOverlay:(NSString*)message{
  if(isWinClosing) return;

  [self stopTimer];
  [self stopDisplayStream];
  [self stopWindowStream];
  [self stopCameraCapture];

  window_id = -1;
  display_id = -1;
  is_playing = false;
  [self resetPlaybackSate];

  [imageView setHidden:YES];

  if(sourceHintOverlay && hintLabel){
    hintLabel.stringValue = [NSString stringWithFormat:@"%@\nRight-click to select source", message];
    [sourceHintOverlay setHidden:NO];
  }

  [self setOwner:nil withTitle:message];
} // End of showDisconnectOverlay:

/**
 * Called when a display is physically disconnected.
 * If this window was capturing that display, shows a disconnect overlay.
 * @param displayId The ID of the disconnected display
 */
- (void)handleDisplayDisconnected:(CGDirectDisplayID)displayId{
  if(display_id >= 0 && (CGDirectDisplayID)display_id == displayId){
    [self showDisconnectOverlay:@"Display disconnected"];
  }
} // End of handleDisplayDisconnected:

/**
 * Called when the camera capture session encounters an error or the device is disconnected.
 * Shows a disconnect overlay with the appropriate message.
 * @param notification The notification containing error information
 */
- (void)cameraSessionError:(NSNotification*)notification{
  if(!camera_session) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if(self->isWinClosing) return;
    [self showDisconnectOverlay:@"Camera unavailable"];
  });
} // End of cameraSessionError:

/**
 * Clones the current source selection to another window.
 * Creates a WindowSel from the current state and triggers changeWindow on the target.
 * Camera sources are skipped since AVCaptureDevice is exclusive to one session.
 * @param target The window to clone the source to
 * @return YES if cloning succeeded, NO if source can't be cloned (camera or no source)
 */
- (BOOL) cloneSourceToWindow:(Window*)target{
  if(![self is_capturing] && !is_hls_session) return NO;

  // Camera can't be shared between sessions
  if(camera_id != nil){
    NSLog(@"Cannot clone camera source — AVCaptureDevice is exclusive to one session");
    return NO;
  }

  WindowSel* sel = [WindowSel getDefault];
  sel.winId = window_id;
  sel.dspId = display_id;
  sel.ownerPid = owner_pid;
  sel.cameraId = nil;
  sel.owner = nil;
  sel.title = self.title;

  NSMenuItem* item = [[NSMenuItem alloc] init];
  [item setRepresentedObject:sel];
  [target changeWindow:item];
  return YES;
} // End of cloneSourceToWindow:

/**
 * Returns a string describing the type of source this window is capturing.
 * @return Source type string (e.g. "Display", "Window", "Camera", "HLS", "AirPlay")
 */
- (NSString*) sourceType{
  if(is_airplay_session) return @"AirPlay";
  if(is_hls_session) return @"HLS";
  if(camera_id != nil) return @"Camera";
  if(display_id >= 0) return @"Display";
  if(window_id >= 0) return @"Window";
  return @"None";
} // End of sourceType

/**
 * Returns a string describing the current status of this window's capture.
 * @return Status string (e.g. "Active", "Paused", "No source")
 */
- (NSString*) sourceStatus{
  if(![self is_capturing] && !is_hls_session && !is_airplay_session) return @"No source";
  if(is_playing) return @"Active";
  return @"Paused";
} // End of sourceStatus


#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)

// SCStreamDelegate method - called when stream stops
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  NSLog(@"ScreenCaptureKit stream stopped%@", error ? [NSString stringWithFormat:@" with error: %@", error] : @"");
  dispatch_async(dispatch_get_main_queue(), ^{
    if(self->isWinClosing) return;
    [self showDisconnectOverlay:@"Window closed"];
  });
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)){
  if(!is_playing || isWinClosing) return;

  if (@available(macOS 13.0, *)) {
    if (type == SCStreamOutputTypeAudio) {
      if (streamManager && [streamManager isStreaming]) {
        [streamManager pushAudioSampleBuffer:sampleBuffer];
      }
      return;
    }
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!imageBuffer) {
    return;
  }

  // Extract window size from CMSampleBuffer metadata (no system call needed!)
  // ScreenCaptureKit provides contentRect and contentScale in the sample attachments or format description
  CGRect contentRect = CGRectZero;
  CGFloat contentScale = 1.0;
  CGFloat scaleFactor = 1.0;

  CFDictionaryRef infoDict = NULL;

  // Try sample attachments first (this is where ScreenCaptureKit typically puts frame info)
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
  if (attachments && CFArrayGetCount(attachments) > 0) infoDict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);

  // If not found in attachments, try format description extensions
  if(!infoDict){
    const CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if(formatDescription) infoDict = CMFormatDescriptionGetExtensions(formatDescription);
  }

  if(infoDict){
    if(is_hidpi){
      CFNumberRef scaleFactorRef = (CFNumberRef)CFDictionaryGetValue(infoDict, SCStreamFrameInfoScaleFactor);
      if(scaleFactorRef) CFNumberGetValue(scaleFactorRef, kCFNumberCGFloatType, &scaleFactor);
    }

    CFNumberRef contecntScaleFactorRef = (CFNumberRef)CFDictionaryGetValue(infoDict, SCStreamFrameInfoContentScale);
    if(contecntScaleFactorRef) CFNumberGetValue(contecntScaleFactorRef, kCFNumberCGFloatType, &contentScale);

    CFDictionaryRef contentRectDict = (CFDictionaryRef)CFDictionaryGetValue(infoDict, SCStreamFrameInfoContentRect);
    if(contentRectDict) CGRectMakeWithDictionaryRepresentation(contentRectDict, &contentRect);
  }

  // Get buffer size for comparison
  size_t bufferWidth = CVPixelBufferGetWidth(imageBuffer);
  size_t bufferHeight = CVPixelBufferGetHeight(imageBuffer);

  if (bufferWidth / contentRect.size.width != bufferHeight / contentRect.size.height) {
    self->window_stream_config.width = (NSUInteger)(contentRect.size.width * scaleFactor / contentScale);
    self->window_stream_config.height = (NSUInteger)(contentRect.size.height * scaleFactor / contentScale);

    NSLog(@"forceUpdateStream begin");
    is_window_stream_updating = true;

    dispatch_async(dispatch_get_main_queue(), ^{
      [self->window_stream updateConfiguration:self->window_stream_config completionHandler:^(NSError * _Nullable updateError) {
        is_window_stream_updating = false;
        if (updateError) {
          NSLog(@"forceUpdateStream: FAILED to update stream configuration: %@, recreating stream", updateError);
        } else {
          NSLog(@"forceUpdateStream: SUCCESSFULLY updated stream configuration to %zux%zu", bufferWidth, bufferHeight);
        }
      }];
    });

    return;
  }

  CIImage *ciImage = [CIImage imageWithCVImageBuffer:imageBuffer];

  if(!ciImage) return;

  dispatch_async(dispatch_get_main_queue(), ^{
    [self->imageView setImage:ciImage];
  });
}

- (void)startWindowStream {
  if (@available(macOS 12.3, *)) {
    // Use ScreenCaptureKit for continuous streaming
    // Get shareable content asynchronously
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
        if (error || !shareableContent) {
          NSLog(@"Failed to get shareable content: %@", error);
          // Fall back to timer-based capture
          dispatch_async(dispatch_get_main_queue(), ^{
            [self startTimer:1.0/refreshRate];
          });
          return;
        }

        // Find the window by CGWindowID
        SCWindow *targetWindow = nil;
        for (SCWindow *window in shareableContent.windows) {
          if (window.windowID == window_id) {
            targetWindow = window;
            break;
          }
        }

        if (!targetWindow) {
          NSLog(@"Window %d not found in shareable content", window_id);
          // Fall back to timer-based capture
          dispatch_async(dispatch_get_main_queue(), ^{
            [self startTimer:1.0/refreshRate];
          });
          return;
        }

        // Create content filter for the window
        SCContentFilter *contentFilter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];

        // Create stream configuration
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        CGRect windowFrame = targetWindow.frame;
        // Use exact window dimensions - we'll recreate the stream if size changes significantly
        NSUInteger configWidth, configHeight;
        configWidth = windowFrame.size.width;
        configHeight = windowFrame.size.height;
        if(is_hidpi) configWidth *= self.backingScaleFactor, configHeight *= self.backingScaleFactor;

        streamConfig.width = configWidth;
        streamConfig.height = configHeight;
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.showsCursor = [(NSNumber*)getPref(@"mouse_capture") intValue] > 0 ? YES : NO;
        streamConfig.minimumFrameInterval = CMTimeMake(1, refreshRate);
        streamConfig.scalesToFit = NO;
        streamConfig.queueDepth = 2;
        streamConfig.capturesAudio = YES;
        streamConfig.sampleRate = 48000;
        streamConfig.channelCount = 2;

        NSLog(@"startWindowStream: window_id=%d, windowFrame={%.1f,%.1f,%.1f,%.1f}, is_hidpi=%d, config=%lux%lu",
              window_id, windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height,
              is_hidpi, (unsigned long)configWidth, (unsigned long)configHeight);

        // Store configuration and dimensions for later updates
        self->window_stream_config = streamConfig;

        // Create stream with delegate to receive content change notifications
        self->window_stream = [[SCStream alloc] initWithFilter:contentFilter configuration:streamConfig delegate:self];

        NSError *addError = nil;
        BOOL success = [self->window_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) error:&addError];

        if (!success || addError) {
          NSLog(@"Failed to add stream output: %@", addError);
          // Fall back to timer-based capture
          dispatch_async(dispatch_get_main_queue(), ^{
            [self stopWindowStream];
            [self startTimer:1.0/refreshRate];
          });
          return;
        }

        if (@available(macOS 13.0, *)) {
          NSError *audioOutputError = nil;
          BOOL audioOutputAdded = [self->window_stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) error:&audioOutputError];
          if (!audioOutputAdded || audioOutputError) {
            NSLog(@"ScreenCaptureKit audio output unavailable: %@", audioOutputError);
          }
        }

        // Start stream
        [self->window_stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
          if (startError) {
            NSLog(@"Failed to start ScreenCaptureKit stream: %@", startError);
            // Fall back to timer-based capture
            dispatch_async(dispatch_get_main_queue(), ^{
              [self stopWindowStream];
              [self startTimer:1.0/refreshRate];
            });
          } else {
            NSLog(@"startWindowStream: ScreenCaptureKit stream started successfully with config %lux%lu",
                  (unsigned long)configWidth, (unsigned long)configHeight);
            dispatch_async(dispatch_get_main_queue(), ^{
              self->is_playing = true;
              // Ensure imageView is visible when capturing starts
              if (self->imageView) {
                self->imageView.hidden = NO;
                NSLog(@"startWindowStream: made imageView visible, hidden=%d", self->imageView.hidden);
              }
              [self resetPlaybackSate];
            });
          }
        }];
      }];
    }
  }
#endif

- (void)selectRegion:(id)sender{
  [self setMovable:NO];
  [selectionView setFrameSize:NSMakeSize(imageView.bounds.size.width, imageView.bounds.size.height)];
  [imageView addSubview:selectionView];
  dispatch_async(dispatch_get_main_queue(), ^{[[NSCursor crosshairCursor] set];});
}

- (void)clearSelection:(id)sender{
  [self onSelcetion:CGRectZero];
}

- (void)setupNonHLSControls {
  butCont.hidden = false;
  hlsButCont.hidden = true;
}

- (void)setupHLSControls {
  isSeeking = false;
  hlsButCont.hidden = false;
  butCont.hidden = true;
}

- (void)updateHLSTimeLabel:(double)currentSeconds duration:(double)durationSeconds {
  // Update elapsed time label
  if (hlsElapsedTimeLabel) {
    int currentMin = (int)(currentSeconds / 60);
    int currentSec = (int)(currentSeconds) % 60;
    NSString *elapsedString = [NSString stringWithFormat:@"%02d:%02d", currentMin, currentSec];
    [hlsElapsedTimeLabel setStringValue:elapsedString];
  }

  // Update total time label
  if (hlsTotalTimeLabel) {
    int durationMin = (int)(durationSeconds / 60);
    int durationSec = (int)(durationSeconds) % 60;
    NSString *totalString = [NSString stringWithFormat:@"%02d:%02d", durationMin, durationSec];
    [hlsTotalTimeLabel setStringValue:totalString];
  }
}

- (void)updateHLSLiveTimeLabel:(double)bufferPosition bufferDuration:(double)bufferDurationSeconds {
  // Update elapsed time label showing position in buffer
  if (hlsElapsedTimeLabel) {
    int bufferMin = (int)(bufferPosition / 60);
    int bufferSec = (int)(bufferPosition) % 60;
    NSString *elapsedString = [NSString stringWithFormat:@"-%02d:%02d", bufferMin, bufferSec];
    [hlsElapsedTimeLabel setStringValue:elapsedString];
  }

  // Update total time label showing buffer duration
  if (hlsTotalTimeLabel) {
    int durationMin = (int)(bufferDurationSeconds / 60);
    int durationSec = (int)(bufferDurationSeconds) % 60;
    NSString *totalString = [NSString stringWithFormat:@"%02d:%02d", durationMin, durationSec];
    [hlsTotalTimeLabel setStringValue:totalString];
  }
}

- (void)seekSliderChanged:(id)sender {
  if (!hlsPlayer || !hlsSeekSlider) return;

  NSSlider *slider = (NSSlider *)sender;
  double value = [slider doubleValue];

  if (isLiveStream) {
    // For live streams, update time label based on seekable range
    AVPlayerItem *item = hlsPlayer.player.currentItem;
    if (item && item.seekableTimeRanges.count > 0) {
      CMTimeRange seekableRange = [[item.seekableTimeRanges lastObject] CMTimeRangeValue];
      CMTime seekableStart = seekableRange.start;
      CMTime seekableDuration = seekableRange.duration;

      if (CMTIME_IS_VALID(seekableStart) && CMTIME_IS_VALID(seekableDuration)) {
        double seekableStartSeconds = CMTimeGetSeconds(seekableStart);
        double seekableDurationSeconds = CMTimeGetSeconds(seekableDuration);
        double bufferPosition = value * seekableDurationSeconds;
        [self updateHLSLiveTimeLabel:bufferPosition bufferDuration:seekableDurationSeconds];
      }
    }

    // Store pending seek value and cancel any pending seek
    pendingSeekValue = value;

    // If this is the first interaction during this drag, pause playback and remember state
    if (!isSeeking && !seekDebounceTimer) {
      AVPlayer *player = hlsPlayer.player;
      wasPlayingBeforeSeek = player.rate > 0.0;

      // Pause playback immediately when user starts seeking
      if (wasPlayingBeforeSeek) {
        NSLog(@"HLS seek (live): Pausing playback for seek");
        [hlsPlayer pause];
        is_playing = NO;
        [self resetPlaybackSate];
      }
    }

    // Cancel any existing debounce timer
    if (seekDebounceTimer) {
      [seekDebounceTimer invalidate];
      seekDebounceTimer = nil;
    }

    // Debounce: wait for user to stop dragging before seeking
    seekDebounceTimer = [NSTimer timerWithTimeInterval:0.15 repeats:NO block:^(NSTimer * _Nonnull timer) {
      if (!self->isSeeking && self->pendingSeekValue >= 0.0 && self->pendingSeekValue <= 1.0) {
        [self performSeekToValue:self->pendingSeekValue];
      }
      self->seekDebounceTimer = nil;
    }];
    [[NSRunLoop mainRunLoop] addTimer:seekDebounceTimer forMode:NSRunLoopCommonModes];
    return;
  }

  // Non-live stream handling continues below...

  // Update time label immediately for responsive UI
  CMTime duration = hlsPlayer.duration;
  if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
    double durationSeconds = CMTimeGetSeconds(duration);
    double currentSeconds = value * durationSeconds;
    [self updateHLSTimeLabel:currentSeconds duration:durationSeconds];
  }

  // Store pending seek value and cancel any pending seek
  pendingSeekValue = value;

  // If this is the first interaction during this drag, pause playback and remember state
  if (!isSeeking && !seekDebounceTimer) {
    AVPlayer *player = hlsPlayer.player;
    wasPlayingBeforeSeek = player.rate > 0.0;

    // Pause playback immediately when user starts seeking
    if (wasPlayingBeforeSeek) {
      NSLog(@"HLS seek: Pausing playback for seek");
      [hlsPlayer pause];
      is_playing = NO;
      [self resetPlaybackSate];
    }
  }

  // Cancel any existing debounce timer
  if (seekDebounceTimer) {
    [seekDebounceTimer invalidate];
    seekDebounceTimer = nil;
  }

  // Debounce: wait for user to stop dragging before seeking
  // This prevents multiple rapid seeks while dragging
  // Use a shorter interval (0.15s) for more responsive seeking
  seekDebounceTimer = [NSTimer timerWithTimeInterval:0.15 repeats:NO block:^(NSTimer * _Nonnull timer) {
    // Only perform seek if not already seeking and value is valid
    if (!self->isSeeking && self->pendingSeekValue >= 0.0 && self->pendingSeekValue <= 1.0) {
      [self performSeekToValue:self->pendingSeekValue];
    } else {
      NSLog(@"HLS seek: Skipping debounced seek - isSeeking=%d, value=%.4f", self->isSeeking, self->pendingSeekValue);
    }
    self->seekDebounceTimer = nil;
  }];
  [[NSRunLoop mainRunLoop] addTimer:seekDebounceTimer forMode:NSRunLoopCommonModes];
}

- (void)seekSliderMouseUp:(id)sender withValue:(NSNumber *)valueNumber {
  // Called when mouse is released on slider - perform seek immediately for single tap
  if (!hlsPlayer || !hlsSeekSlider || isSeeking) return;

  double value = [valueNumber doubleValue];

  if (isLiveStream) {
    // For live streams, perform seek within seekable range
    pendingSeekValue = value;
    [self performSeekToValue:value];
    return;
  }

  // Non-live stream handling continues below...

  // Clamp and validate
  if (value < 0.0) value = 0.0;
  if (value > 1.0) value = 1.0;

  // Check if this is actually a different position
  CMTime duration = hlsPlayer.duration;
  if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
    double durationSeconds = CMTimeGetSeconds(duration);
    double targetSeconds = value * durationSeconds;
    CMTime currentTime = [hlsPlayer.player currentTime];
    double currentSeconds = CMTIME_IS_VALID(currentTime) ? CMTimeGetSeconds(currentTime) : 0.0;

    // Only seek if the target is significantly different (more than 0.5 seconds)
    if (fabs(targetSeconds - currentSeconds) < 0.5) {
      NSLog(@"HLS seek: Skipping seek - target (%.2f) too close to current (%.2f)", targetSeconds, currentSeconds);
      return;
    }
  }

  // Cancel any pending debounce timer since we're seeking now
  if (seekDebounceTimer) {
    [seekDebounceTimer invalidate];
    seekDebounceTimer = nil;
  }

  // Perform seek immediately
  pendingSeekValue = value;
  [self performSeekToValue:value];
}

- (void)performSeekToValue:(double)value {
  if (!hlsPlayer || isSeeking) {
    NSLog(@"HLS seek: Skipping seek - player=%p, isSeeking=%d", hlsPlayer, isSeeking);
    return;
  }

  // Clamp value to valid range [0.0, 1.0]
  if (value < 0.0) value = 0.0;
  if (value > 1.0) value = 1.0;

  CMTime seekTime;

  if (isLiveStream) {
    // For live streams, seek within the seekable time range (buffer window)
    AVPlayerItem *item = hlsPlayer.player.currentItem;
    if (!item || item.seekableTimeRanges.count == 0) {
      NSLog(@"HLS seek (live): No seekable time ranges available");
      return;
    }

    CMTimeRange seekableRange = [[item.seekableTimeRanges lastObject] CMTimeRangeValue];
    CMTime seekableStart = seekableRange.start;
    CMTime seekableDuration = seekableRange.duration;

    if (!CMTIME_IS_VALID(seekableStart) || !CMTIME_IS_VALID(seekableDuration)) {
      NSLog(@"HLS seek (live): Invalid seekable time range");
      return;
    }

    double seekableStartSeconds = CMTimeGetSeconds(seekableStart);
    double seekableDurationSeconds = CMTimeGetSeconds(seekableDuration);

    // Calculate seek time within the buffer window
    // value 0.0 = start of buffer, value 1.0 = live edge (end of buffer)
    double seekSeconds = seekableStartSeconds + (value * seekableDurationSeconds);
    seekTime = CMTimeMakeWithSeconds(seekSeconds, NSEC_PER_SEC);

    NSLog(@"HLS seek (live): Seeking to %.2f seconds (buffer: %.2f - %.2f, value=%.4f)",
          seekSeconds, seekableStartSeconds, seekableStartSeconds + seekableDurationSeconds, value);
  } else {
    // For non-live streams, use duration
    CMTime duration = hlsPlayer.duration;
    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration)) {
      NSLog(@"HLS seek: Invalid duration");
      return;
    }

    double durationSeconds = CMTimeGetSeconds(duration);
    double seekSeconds = value * durationSeconds;

    // Clamp seek time to valid range
    if (seekSeconds < 0.0) seekSeconds = 0.0;
    if (seekSeconds > durationSeconds) seekSeconds = durationSeconds;

    seekTime = CMTimeMakeWithSeconds(seekSeconds, NSEC_PER_SEC);

    NSLog(@"HLS seek: Seeking to %.2f seconds (value=%.4f, duration=%.2f)", seekSeconds, value, durationSeconds);
  }

  AVPlayer *player = hlsPlayer.player;

  // Get current time for comparison
  CMTime currentTime = [player currentTime];
  double currentSeconds = CMTIME_IS_VALID(currentTime) ? CMTimeGetSeconds(currentTime) : 0.0;
  double seekSeconds = CMTimeGetSeconds(seekTime);

  if (!isLiveStream) {
    CMTime duration = hlsPlayer.duration;
    double durationSeconds = CMTIME_IS_VALID(duration) ? CMTimeGetSeconds(duration) : 0.0;
    NSLog(@"HLS seek: Performing seek from %.2f to %.2f seconds (value=%.4f, duration=%.2f), wasPlaying=%d",
          currentSeconds, seekSeconds, value, durationSeconds, wasPlayingBeforeSeek);
  } else {
    NSLog(@"HLS seek (live): Performing seek from %.2f to %.2f seconds (value=%.4f), wasPlaying=%d",
          currentSeconds, seekSeconds, value, wasPlayingBeforeSeek);
  }

  isSeeking = true;
  bufferingCheckCount = 0; // Reset buffering check counter

  // Use AVPlayer's completion handler version to resume playback if needed
  [player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
    NSLog(@"HLS seek: Seek completed, finished=%d, wasPlaying=%d", finished, self->wasPlayingBeforeSeek);
    if (finished) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self->isSeeking = false;

        // Resume playback if it was playing before the seek
        if (self->wasPlayingBeforeSeek) {
          // Ensure is_playing flag is set
          self->is_playing = YES;

          NSLog(@"HLS seek: Resuming playback after seek");

          // Wait a brief moment for buffering, then resume
          // The player will continue buffering during playback if needed
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self resumePlaybackAfterSeek];
          });
        }
      });
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        self->isSeeking = false;
      });
    }
  }];
}

- (void)resumePlaybackAfterSeek {
  NSLog(@"HLS seek: resumePlaybackAfterSeek called, wasPlayingBeforeSeek=%d", wasPlayingBeforeSeek);

  // Only resume if playback was active before seeking
  if (!wasPlayingBeforeSeek) {
    NSLog(@"HLS seek: Was not playing before seek, not resuming");
    [self resetPlaybackSate];
    return;
  }

  // Ensure is_playing flag is set
  is_playing = YES;

  // Ensure player rate is set first, then call play
  AVPlayer *player = hlsPlayer.player;
  player.rate = 1.0;

  // Call play() which will ensure frame timer is running
  [hlsPlayer play];

  // Double-check everything after a brief delay
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    AVPlayer *player = self->hlsPlayer.player;
    if (player.rate == 0.0) {
      NSLog(@"HLS seek: Player rate is 0 after play(), forcing to 1.0 again");
      player.rate = 1.0;
      // Try play() again
      [self->hlsPlayer play];
    } else {
      NSLog(@"HLS seek: Player rate is %.2f, should be playing", player.rate);
    }

    // Verify player item is ready
    AVPlayerItem *item = player.currentItem;
    if (item) {
      NSLog(@"HLS seek: Player item status=%ld, playbackLikelyToKeepUp=%d, playbackBufferEmpty=%d, currentTime=%.2f",
            (long)item.status, item.playbackLikelyToKeepUp, item.playbackBufferEmpty,
            CMTimeGetSeconds([player currentTime]));
    }

    [self resetPlaybackSate];
  });
}

- (void)waitForBufferingAndResume {
  bufferingCheckCount++;

  // Timeout after 5 seconds (50 checks * 0.1s) to prevent infinite loop
  if (bufferingCheckCount > 50) {
    NSLog(@"HLS seek: Buffering timeout, resuming anyway");
    [self resumePlaybackAfterSeek];
    return;
  }

  AVPlayerItem *item = hlsPlayer.player.currentItem;
  if (!item) {
    NSLog(@"HLS seek: No player item, resuming");
    [self resumePlaybackAfterSeek];
    return;
  }

  if (item.playbackLikelyToKeepUp && !item.playbackBufferEmpty) {
    NSLog(@"HLS seek: Buffering complete after %d checks, resuming", bufferingCheckCount);
    [self resumePlaybackAfterSeek];
  } else {
    // Check again in 0.1 seconds
    if (bufferingCheckCount % 10 == 0) { // Log every 10 checks to reduce spam
      NSLog(@"HLS seek: Still buffering (check %d), playbackLikelyToKeepUp=%d, playbackBufferEmpty=%d",
            bufferingCheckCount, item.playbackLikelyToKeepUp, item.playbackBufferEmpty);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      // Only continue if we're still seeking (another seek might have started)
      if (self->isSeeking) {
        [self waitForBufferingAndResume];
      }
    });
  }
}

- (void)volumeSliderChanged:(id)sender {
  if (!hlsPlayer) return;

  NSSlider *slider = (NSSlider *)sender;
  float volume = (float)[slider doubleValue];
  [hlsPlayer setVolume:volume];

  // Sync the other volume slider if it exists
  if (hlsVolumeSlider && slider != hlsVolumeSlider) {
    [hlsVolumeSlider setDoubleValue:volume];
  }
}

- (void)selectHLSQuality:(id)sender {
  if (!hlsPlayer) return;

  NSMenuItem *item = (NSMenuItem *)sender;
  NSDictionary *quality = [item representedObject];

  if (quality) {
    [hlsPlayer setQuality:quality];
    NSLog(@"HLS quality changed to: %@", quality[@"name"]);
  }
}

- (void)selectCameraResolution:(id)sender {
  if (!camera_id || !camera_session) return;

  NSMenuItem *item = (NSMenuItem *)sender;
  NSDictionary *resolution = [item representedObject];

  if (resolution && resolution[@"format"]) {
    AVCaptureDeviceFormat *format = resolution[@"format"];
    AVCaptureDevice *device = camera_input.device;

    if (!device) {
      NSLog(@"Camera device not available");
      return;
    }

    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
      // Check if the format is still available
      if ([device.formats containsObject:format]) {
        device.activeFormat = format;
        camera_format = format;
        NSLog(@"Camera resolution changed to: %@", resolution[@"name"]);
      } else {
        NSLog(@"Camera format no longer available: %@", resolution[@"name"]);
      }
      [device unlockForConfiguration];
    } else {
      NSLog(@"Failed to lock device for configuration: %@", error);
    }
  }
} // End of selectCameraResolution:

/**
 * Toggles local camera audio monitoring on/off.
 * Only affects the local audio preview volume; audio capture and HLS streaming are not affected.
 * @param sender The menu item that triggered this action
 */
-(void)toggleCameraAudio:(id)sender {
  camera_audio_monitoring = !camera_audio_monitoring;

  if(camera_audio_preview) {
    camera_audio_preview.volume = camera_audio_monitoring ? 1.0 : 0.0;
  }

  NSLog(@"Local camera audio monitoring %@", camera_audio_monitoring ? @"enabled" : @"disabled");
} // End of toggleCameraAudio:

- (void)updateHLSInputViewLayout {
  if (!hlsInputView) return;

  NSRect windowBounds = [rootView bounds];
  CGFloat minWidth = 400;
  CGFloat preferredWidth = 500;
  CGFloat viewHeight = 120;
  CGFloat padding = 20;

  // Calculate width that fits in window with padding
  CGFloat maxWidth = windowBounds.size.width - (padding * 2);
  CGFloat viewWidth = fmin(fmax(minWidth, preferredWidth), maxWidth);

  // Calculate position to center, but ensure it stays within bounds
  CGFloat xPos = (windowBounds.size.width - viewWidth) / 2;
  CGFloat yPos = (windowBounds.size.height - viewHeight) / 2;

  // Ensure view stays within bounds
  if (xPos < padding) xPos = padding;
  if (yPos < padding) yPos = padding;
  if (xPos + viewWidth > windowBounds.size.width - padding) {
    xPos = windowBounds.size.width - viewWidth - padding;
  }
  if (yPos + viewHeight > windowBounds.size.height - padding) {
    yPos = windowBounds.size.height - viewHeight - padding;
  }

  NSRect viewRect = NSMakeRect(xPos, yPos, viewWidth, viewHeight);
  [hlsInputView setFrame:viewRect];

  // Update subviews to fit new width
  CGFloat contentWidth = viewWidth - 40; // 20px padding on each side
  if (hlsInputField) {
    NSRect fieldFrame = [hlsInputField frame];
    fieldFrame.size.width = contentWidth;
    [hlsInputField setFrame:fieldFrame];
  }

  // Update label width
  NSView *label = [[hlsInputView subviews] firstObject];
  if (label && [label isKindOfClass:[NSTextField class]]) {
    NSRect labelFrame = [label frame];
    labelFrame.size.width = contentWidth;
    [label setFrame:labelFrame];
  }

  // Update button positions - position from right edge
  if (hlsCancelButton) {
    NSRect cancelFrame = [hlsCancelButton frame];
    cancelFrame.origin.x = contentWidth - 75 + 20; // Right edge minus button width plus padding
    [hlsCancelButton setFrame:cancelFrame];
  }

  if (hlsLoadButton) {
    NSRect loadFrame = [hlsLoadButton frame];
    loadFrame.origin.x = contentWidth - 160 + 20; // Right edge minus both buttons width plus padding
    [hlsLoadButton setFrame:loadFrame];
  }
}

- (void)loadHLSStream:(id)sender {
  // Remove existing input view if present
  [self dismissHLSInputView];

  if(is_airplay_session) return;

  NSRect windowBounds = [rootView bounds];
  CGFloat minWidth = 400;
  CGFloat preferredWidth = 500;
  CGFloat viewHeight = 120;
  CGFloat padding = 20;

  // Calculate width that fits in window with padding
  CGFloat maxWidth = windowBounds.size.width - (padding * 2);
  CGFloat viewWidth = fmin(fmax(minWidth, preferredWidth), maxWidth);

  // Calculate position to center, but ensure it stays within bounds
  CGFloat xPos = (windowBounds.size.width - viewWidth) / 2;
  CGFloat yPos = (windowBounds.size.height - viewHeight) / 2;

  // Ensure view stays within bounds
  if (xPos < padding) xPos = padding;
  if (yPos < padding) yPos = padding;
  if (xPos + viewWidth > windowBounds.size.width - padding) {
    xPos = windowBounds.size.width - viewWidth - padding;
  }
  if (yPos + viewHeight > windowBounds.size.height - padding) {
    yPos = windowBounds.size.height - viewHeight - padding;
  }

  NSRect viewRect = NSMakeRect(xPos, yPos, viewWidth, viewHeight);

  // Create container view with semi-transparent background
  hlsInputView = [[NSView alloc] initWithFrame:viewRect];
  hlsInputView.wantsLayer = YES;
  hlsInputView.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.85] CGColor];
  hlsInputView.layer.cornerRadius = 10;
  hlsInputView.layer.borderWidth = 1;
  hlsInputView.layer.borderColor = [[NSColor colorWithWhite:0.5 alpha:0.5] CGColor];
  hlsInputView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

  CGFloat contentWidth = viewWidth - 40; // 20px padding on each side

  // Create label
  NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 85, contentWidth, 17)];
  [label setStringValue:@"Enter HLS Stream URL/cURL (m3u8):"];
  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setTextColor:[NSColor whiteColor]];
  [label setFont:[NSFont systemFontOfSize:13]];
  [hlsInputView addSubview:label];

  // Create text field
  hlsInputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, contentWidth, 22)];
  [hlsInputField setStringValue:lastSuccessfulHLSURL ?: @""];
  [hlsInputField setEditable:YES];
  [hlsInputField setSelectable:YES];
  [hlsInputField setBezeled:YES];
  [hlsInputField setBordered:YES];
  [hlsInputField setRefusesFirstResponder:NO];
  [hlsInputField setTarget:self];
  [hlsInputField setAction:@selector(loadHLSURLFromInput:)];
  [hlsInputField setUsesSingleLineMode:YES];
  [hlsInputField setMaximumNumberOfLines:1];
  [hlsInputField setAutoresizingMask:NSViewWidthSizable];

  NSTextFieldCell *cell = [hlsInputField cell];
  [cell setEditable:YES];
  [cell setSelectable:YES];
  [cell setWraps:NO];
  [cell setScrollable:YES];

  [hlsInputView addSubview:hlsInputField];

  // Create buttons - position from right edge
  hlsCancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentWidth - 75 + 20, 12, 75, 28)];
  [hlsCancelButton setTitle:@"Cancel"];
  [hlsCancelButton setButtonType:NSButtonTypeMomentaryPushIn];
  [hlsCancelButton setBezelStyle:NSBezelStyleRounded];
  [hlsCancelButton setKeyEquivalent:@"\e"];
  [hlsCancelButton setTarget:self];
  [hlsCancelButton setAction:@selector(dismissHLSInputView:)];
  [hlsCancelButton setAutoresizingMask:NSViewMinXMargin];
  [hlsInputView addSubview:hlsCancelButton];

  hlsLoadButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentWidth - 160 + 20, 12, 75, 28)];
  [hlsLoadButton setTitle:@"Load"];
  [hlsLoadButton setButtonType:NSButtonTypeMomentaryPushIn];
  [hlsLoadButton setBezelStyle:NSBezelStyleRounded];
  [hlsLoadButton setKeyEquivalent:@"\r"];
  [hlsLoadButton setTarget:self];
  [hlsLoadButton setAction:@selector(loadHLSURLFromInput:)];
  [hlsLoadButton setAutoresizingMask:NSViewMinXMargin];
  [hlsInputView addSubview:hlsLoadButton];

  // Add to root view
  [rootView addSubview:hlsInputView positioned:NSWindowAbove relativeTo:nil];

  // Observe window resize to update layout
  [[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(windowDidResize:)
                                        name:NSWindowDidResizeNotification
                                        object:self];

  // Make text field first responder
  dispatch_async(dispatch_get_main_queue(), ^{
    [self makeFirstResponder:hlsInputField];
    [hlsInputField selectText:nil];
  });
}

- (void)windowDidResize:(NSNotification *)notification {
  [self updateHLSInputViewLayout];
  if (is_hls_session && hlsPlayer && !isWinClosing) [hlsPlayer setViewportSize:[self contentRectForFrameRect:self.frame].size];
}

- (void)loadHLSURLFromInput:(id)sender {
  if (!hlsInputField) return;

  NSString *inputString = [[hlsInputField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if(inputString.length == 0) return;

  NSURL *url = nil;
  NSMutableDictionary<NSString *, NSString *> *headers = nil;

  // Check if input looks like a curl command
  if ([inputString hasPrefix:@"curl "] || [inputString containsString:@" -H '"]) {
    // Parse curl command
    NSError *error = nil;
    // Match quoted strings that look like URLs (http:// or https://) anywhere in the command
    NSRegularExpression *urlRegex = [NSRegularExpression regularExpressionWithPattern:@"['\"](https?://[^'\"]+)['\"]" options:0 error:&error];
    NSRegularExpression *headerRegex = [NSRegularExpression regularExpressionWithPattern:@"-H\\s+['\"]([^:]+):\\s*([^'\"]+)['\"]" options:0 error:&error];

    // Extract URL - find first quoted string that looks like a URL
    NSTextCheckingResult *urlMatch = [urlRegex firstMatchInString:inputString options:0 range:NSMakeRange(0, inputString.length)];
    if (urlMatch && urlMatch.numberOfRanges > 1) {
      NSString *urlString = [inputString substringWithRange:[urlMatch rangeAtIndex:1]];
      url = [NSURL URLWithString:urlString];
    }

    // Extract headers
    NSArray<NSTextCheckingResult *> *headerMatches = [headerRegex matchesInString:inputString options:0 range:NSMakeRange(0, inputString.length)];
    if (headerMatches.count > 0) {
      headers = [NSMutableDictionary dictionary];
      for (NSTextCheckingResult *match in headerMatches) {
        if (match.numberOfRanges >= 3) {
          NSString *headerName = [inputString substringWithRange:[match rangeAtIndex:1]];
          NSString *headerValue = [inputString substringWithRange:[match rangeAtIndex:2]];
          // Trim whitespace
          headerName = [headerName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
          headerValue = [headerValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
          if (headerName.length > 0 && headerValue.length > 0) {
            [headers setObject:headerValue forKey:headerName];
          }
        }
      }
    }
  } else {
    // Try as plain URL
    url = [NSURL URLWithString:inputString];
  }

  if(url) {
    // Retain the successfully parsed input string
    lastSuccessfulHLSURL = inputString;
    [self dismissHLSInputView];
    [self loadHLSURL:url withHeaders:headers];
  } else {
    // Show error briefly
    NSBeep();
    [hlsInputField setStringValue:@""];
    [hlsInputField setPlaceholderString:@"Invalid URL or curl command - please try again"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (hlsInputField) {
        [hlsInputField setPlaceholderString:@""];
      }
    });
  }
}

- (void)dismissHLSInputView:(id)sender {
  [self dismissHLSInputView];
}

- (void)dismissHLSInputView {
  if(!hlsInputView) return;
  [hlsInputView removeFromSuperview];
  hlsInputView = nil;
  hlsInputField = nil;
  hlsLoadButton = nil;
  hlsCancelButton = nil;
}

- (void)windowWillClose:(NSNotification *)notification{
  isWinClosing = true;
  [self stopTimer];
  [self stopDisplayStream];
  [self stopWindowStream];
  [self stopCameraCapture];

  // Stop streaming if active
  if (streamManager) {
    [streamManager stopStreaming];
    streamManager = nil;
  }
  CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, (__bridge void*)self);

  // If this is the last PiP window, terminate the app
  NSInteger remainingPipWindows = 0;
  for(NSWindow* w in [[NSApplication sharedApplication] windows]){
    if([w isKindOfClass:[Window class]] && w != self) remainingPipWindows++;
  }
  if(remainingPipWindows == 0){
    [[NSApplication sharedApplication] terminate:nil];
  }
}

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

//- (void)dealloc{
//  NSLog(@"dealloc called");
//}

- (void)close{
  [self dismissHLSInputView];
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

  // Unregister display reconfiguration callback
  CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, (__bridge void*)self);

  // Remove camera disconnect notification observers
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceWasDisconnectedNotification object:nil];

  #ifndef NO_AIRPLAY
  if(is_airplay_session) airplay_receiver_session_stop(self.conn);
  if (airplaySender) {
    sender_stop((sender_t *)airplaySender);
    sender_destroy((sender_t *)airplaySender);
    airplaySender = NULL;
  }
  connectedSenderReceiver = nil;
  is_airplay_sending = false;
  #endif

  [self stopTimer];
  [self stopDisplayStream];
  [self stopWindowStream];
  [self stopCameraCapture];

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
  if(sourceHintOverlay){
    [sourceHintOverlay removeFromSuperview];
    sourceHintOverlay = nil;
  }
  [rootView removeFromSuperview];

  nvc = NULL;
  timer = NULL;
  rootView = NULL;
#ifndef NO_AIRPLAY
  if (airplayDiscovery) {
    airplayDiscovery.delegate = nil;
  }
#endif
  butCont = NULL;
  pinbutt = NULL;
  popbutt = NULL;
  playbutt = NULL;
  selectionView = NULL;

  [self setContentViewController:nil];

  if(audPlayer) [audPlayer destroy]; audPlayer = nil;
  if(h264decoder) [h264decoder destroy]; h264decoder = nil;
  if(hlsPlayer) {
    [hlsPlayer stop];
    hlsPlayer = nil;
  }

  // Clean up HLS controls
  if (hlsSeekSlider) {
    [hlsSeekSlider removeFromSuperview];
    hlsSeekSlider = nil;
  }
  if (hlsVolumeSlider) {
    [hlsVolumeSlider removeFromSuperview];
    hlsVolumeSlider = nil;
  }
  if (hlsElapsedTimeLabel) {
    [hlsElapsedTimeLabel removeFromSuperview];
    hlsElapsedTimeLabel = nil;
  }
  if (hlsTotalTimeLabel) {
    [hlsTotalTimeLabel removeFromSuperview];
    hlsTotalTimeLabel = nil;
  }
  if (hlsLiveIndicator) {
    [hlsLiveIndicator removeFromSuperview];
    hlsLiveIndicator = nil;
  }
  if (hlsPlayButton) {
    [hlsPlayButton removeFromSuperview];
    hlsPlayButton = nil;
  }
  if (hlsPopButton) {
    [hlsPopButton removeFromSuperview];
    hlsPopButton = nil;
  }

  [super close];
}

#ifndef NO_AIRPLAY
- (void)receiverAdded:(AirPlayReceiver *)receiver {
  NSLog(@"AirPlay receiver discovered: %@ (%@)", receiver.name, receiver.model);
  // Receivers list will be updated when menu is shown next time
  // If we're not connected and this is the first receiver, could show a notification
}

- (void)receiverRemoved:(AirPlayReceiver *)receiver {
  return;
  NSLog(@"AirPlay receiver removed: %@", receiver.name);

  // If the removed receiver is the one we're connected to, disconnect
  if (connectedReceiver && [connectedReceiver.deviceId isEqualToString:receiver.deviceId]) {
    if (httpClient) {
      http_client_disconnect((http_client_t *)httpClient);
      http_client_destroy((http_client_t *)httpClient);
      httpClient = NULL;
    }
    connectedReceiver = nil;
    [self setOwner:nil withTitle:DEFAULT_TITLE];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"AirPlay Disconnected"];
    [alert setInformativeText:[NSString stringWithFormat:@"Connection to %@ was lost.", receiver.name]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleInformational];
    [alert runModal];
  }

  // Receivers list will be updated when menu is shown next time
}

- (void)connectToAirPlayReceiver:(id)sender {
  NSMenuItem *item = (NSMenuItem *)sender;
  AirPlayReceiver *receiver = [item representedObject];
  if (!receiver) {
    return;
  }

  // Disconnect from previous receiver if any
  if (httpClient) {
    http_client_disconnect((http_client_t *)httpClient);
    http_client_destroy((http_client_t *)httpClient);
    httpClient = NULL;
  }

  // Create HTTP client
  const char *host = [receiver.host UTF8String];

  // Try connecting to the advertised port first (some receivers listen on the advertised port)
  // If that fails, try port-1 (for PiP receiver and similar implementations)
  uint16_t ports_to_try[] = {receiver.port, receiver.port > 0 ? receiver.port - 1 : receiver.port};
  http_client_t *client = NULL;
  uint16_t connect_port = 0;
  int connect_result = -1;

  for (int i = 0; i < 2; i++) {
    connect_port = ports_to_try[i];
    NSLog(@"Attempting to connect to %@ at %s:%u (attempt %d/2)", receiver.name, host, connect_port, i + 1);

    client = http_client_init(host, connect_port);
    if (!client) {
      NSLog(@"Failed to initialize HTTP client for %@ on port %u", receiver.name, connect_port);
      continue;
    }

    connect_result = http_client_connect(client);
    if (connect_result == 0) {
      NSLog(@"Successfully connected to %@ at %s:%u", receiver.name, host, connect_port);
      break;
    } else {
      NSLog(@"Connection failed to %@ on port %u: %d", receiver.name, connect_port, connect_result);
      http_client_destroy(client);
      client = NULL;
    }
  }

  if (!client || connect_result != 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Connection Error"];
    [alert setInformativeText:[NSString stringWithFormat:@"Failed to connect to %@\n\nPlease check that the receiver is on the same network.", receiver.name]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    return;
  }

  // Get server info to verify connection
  server_info_t *info = http_client_get_info(client);
  if (!info) {
    http_client_disconnect(client);
    http_client_destroy(client);
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Connection Error"];
    [alert setInformativeText:[NSString stringWithFormat:@"Failed to get information from %@", receiver.name]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    return;
  }

  // Store connection
  httpClient = client;
  connectedReceiver = receiver;

  // Extract info before cleanup
  uint64_t features = info->features;
  NSString *version = nil;
  if (info->sourceVersion) {
    version = [NSString stringWithUTF8String:info->sourceVersion];
  }

  // Update window title
  NSString *title = [NSString stringWithFormat:@"AirPlay: %@", receiver.name];
  if (version) {
    title = [title stringByAppendingFormat:@" (v%@)", version];
  }
  [self setOwner:@"AirPlay" withTitle:title];

  // Clean up info
  server_info_destroy(info);

  NSLog(@"Connected to AirPlay receiver: %@ at %@:%u (via RAOP port)", receiver.name, receiver.host, connect_port);
  NSLog(@"Features: 0x%llx", (unsigned long long)features);

  // TODO: Phase 3 - Start pairing/authentication
  // TODO: Phase 4 - Set up streaming
}

// Sender state callback
static void sender_state_callback(sender_state_t state, const char *error, void *ctx) {
  Window *window = (__bridge Window *)ctx;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!window) {
      return;
    }

    switch (state) {
      case SENDER_STATE_IDLE:
        NSLog(@"AirPlay sender: Idle");
        break;
      case SENDER_STATE_CONNECTING:
        NSLog(@"AirPlay sender: Connecting...");
        break;
      case SENDER_STATE_PAIRING:
        NSLog(@"AirPlay sender: Pairing...");
        break;
      case SENDER_STATE_STREAMING:
        NSLog(@"AirPlay sender: Streaming");
        break;
      case SENDER_STATE_ERROR:
        NSLog(@"AirPlay sender: Error - %s", error ? error : "Unknown error");
        if (error) {
          NSAlert *alert = [[NSAlert alloc] init];
          [alert setMessageText:@"AirPlay Mirroring Error"];
          [alert setInformativeText:[NSString stringWithUTF8String:error]];
          [alert addButtonWithTitle:@"OK"];
          [alert setAlertStyle:NSAlertStyleWarning];
          [alert runModal];
        }
        // Clean up on error
        if (window->airplaySender) {
          sender_destroy((sender_t *)window->airplaySender);
          window->airplaySender = NULL;
        }
        window->connectedSenderReceiver = nil;
        window->is_airplay_sending = false;
        break;
    }
  });
}

- (void)connectToAirPlaySender:(id)sender {
  NSMenuItem *item = (NSMenuItem *)sender;
  AirPlayReceiver *receiver = [item representedObject];
  if (!receiver) {
    return;
  }

  // Stop existing sender if any
  if (airplaySender) {
    sender_stop((sender_t *)airplaySender);
    sender_destroy((sender_t *)airplaySender);
    airplaySender = NULL;
  }

  // Get receiver info from discovery
  int count = 0;
  airplay_receiver_t *receivers = airplay_discovery_get_receivers(&count);
  airplay_receiver_t *c_receiver = NULL;

  for (int i = 0; i < count; i++) {
    if (strcmp(receivers[i].deviceId, [receiver.deviceId UTF8String]) == 0) {
      c_receiver = &receivers[i];
      break;
    }
  }

  if (!c_receiver) {
    if (receivers) {
      free(receivers);
    }
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Connection Error"];
    [alert setInformativeText:[NSString stringWithFormat:@"Receiver %@ not found", receiver.name]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    return;
  }

  // Initialize sender
  sender_t *sender_obj = sender_init();
  if (!sender_obj) {
    if (receivers) {
      free(receivers);
    }
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Initialization Error"];
    [alert setInformativeText:@"Failed to initialize AirPlay sender"];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    return;
  }

  // Set state callback
  sender_set_state_callback(sender_obj, sender_state_callback, (__bridge void *)self);

  // Get device info
  NSString *deviceId = [[[NSHost currentHost] address] stringByReplacingOccurrencesOfString:@"." withString:@":"];
  if (!deviceId || deviceId.length == 0) {
    deviceId = @"00:00:00:00:00:00";  // Fallback
  }

  NSProcessInfo *processInfo = [NSProcessInfo processInfo];
  NSString *osName = @"Mac OS X";
  NSString *osVersion = [processInfo operatingSystemVersionString];
  NSString *model = @"Mac";

  // Try to get actual model
  size_t size = 0;
  sysctlbyname("hw.model", NULL, &size, NULL, 0);
  if (size > 0) {
    char *modelBuf = malloc(size);
    if (modelBuf && sysctlbyname("hw.model", modelBuf, &size, NULL, 0) == 0) {
      model = [NSString stringWithUTF8String:modelBuf];
    }
    if (modelBuf) {
      free(modelBuf);
    }
  }

  // Store receiver info before dispatching to background thread
  AirPlayReceiver *receiverToConnect = receiver;

  // Run sender connection on background thread to avoid blocking main UI thread
  // This prevents deadlock when receiver's conn_init tries to use main queue
  // Create or reuse the sender queue
  senderQueue = dispatch_queue_create("com.pip.airplay.sender", DISPATCH_QUEUE_SERIAL);

  dispatch_async(senderQueue, ^{
    // Get hostname for device name
    NSString *deviceName = [[NSHost currentHost] name];
    if (!deviceName) {
      deviceName = @"Mac";
    }

    // Connect to receiver (this blocks waiting for HTTP responses)
    int result = sender_connect(sender_obj, c_receiver,
                                [deviceId UTF8String],
                                [osName UTF8String],
                                [osVersion UTF8String],
                                [model UTF8String],
                                [deviceName UTF8String]);

    if (receivers) {
      free(receivers);
    }

    if (result != 0) {
      sender_destroy(sender_obj);
      dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Connection Error"];
        [alert setInformativeText:[NSString stringWithFormat:@"Failed to connect to %@\n\nPlease check that the receiver is on the same network.", receiverToConnect.name]];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert runModal];
      });
      return;
    }

    // Start mirroring (will need to set up video/audio capture separately)
    // For now, pass NULL as source_id - platform code will set up capture
    result = sender_start_mirroring(sender_obj, NULL);

    if (result != 0) {
      sender_stop(sender_obj);
      sender_destroy(sender_obj);
      dispatch_async(dispatch_get_main_queue(), ^{
        airplaySender = NULL;
        connectedSenderReceiver = nil;
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Mirroring Error"];
        [alert setInformativeText:[NSString stringWithFormat:@"Failed to start mirroring to %@", receiverToConnect.name]];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert runModal];
      });
      return;
    }

    // Update UI on main thread and set up frame capture
    dispatch_async(dispatch_get_main_queue(), ^{
      // Store sender and receiver
      airplaySender = sender_obj;
      connectedSenderReceiver = receiverToConnect;
      is_airplay_sending = true;

      // Update window title
      [self setOwner:@"AirPlay Mirror" withTitle:[NSString stringWithFormat:@"Mirroring to %@", receiverToConnect.name]];

      // Initialize frame capture and video encoder from ImageView
      if (self->imageView && self->imageView.renderer) {
        // Get image dimensions from current image or use default
        CIImage *currentImage = [self->imageView.renderer currentImage];
        int width = 1920;  // Default width
        int height = 1080; // Default height
        int fps = 30;  // Reduced from 30 to 5 to test buffer lifetime issue

        if (currentImage) {
          CGRect extent = [currentImage extent];
          width = (int)extent.size.width;
          height = (int)extent.size.height;
        } else {
          // Use window/view size as fallback
          NSSize viewSize = self->imageView.bounds.size;
          if (viewSize.width > 0 && viewSize.height > 0) {
            width = (int)viewSize.width;
            height = (int)viewSize.height;
          }
        }

        // Get quality preference for bitrate
        int quality = [(NSNumber*)getPref(@"airplay_sender_quality") intValue];
        int bitrate = quality == 0 ? 2000000 : (quality == 1 ? 5000000 : 10000000); // Low/Medium/High

        NSLog(@"AirPlay: Setting up video pipeline - width=%d, height=%d, fps=%d, bitrate=%d", width, height, fps, bitrate);

        // Initialize video encoder
        video_encoder_t *encoder = video_encoder_init(width, height, fps, bitrate);
        if (encoder) {
          NSLog(@"AirPlay: Video encoder created, setting on sender");
          sender_set_video_encoder(sender_obj, encoder);

          // Initialize frame capture
          frame_capture_t *frame_cap = frame_capture_init((__bridge void *)self->imageView);
          if (frame_cap) {
            NSLog(@"AirPlay: Frame capture created, setting on sender");
            sender_set_frame_capture(sender_obj, frame_cap);
            // Start frame capture at target fps
            int start_result = frame_capture_start(frame_cap, fps);
            if (start_result == 0) {
              NSLog(@"AirPlay: Frame capture started successfully");
            } else {
              NSLog(@"AirPlay: Failed to start frame capture: %d", start_result);
            }
          } else {
            NSLog(@"AirPlay: Failed to create frame capture, cleaning up encoder");
            // If frame capture fails, clean up encoder
            video_encoder_destroy(encoder);
          }
        } else {
          NSLog(@"AirPlay: Failed to create video encoder");
        }
      }
    });
  });

  // TODO: When platform code creates audio encoder/capture, check audio preference:
  // bool audio_enabled = [(NSNumber*)getPref(@"airplay_sender_audio") intValue] > 0;
  // if (audio_enabled) {
  //   audio_encoder_t *audio_enc = audio_encoder_init(44100, 2, 128000);
  //   sender_set_audio_encoder(sender_obj, audio_enc);
  //   // ... set up audio capture
  // }

  NSLog(@"Started AirPlay mirroring to: %@", receiver.name);
}

- (void)stopAirPlayMirroring:(id)sender {
  if (!senderQueue || !airplaySender) {
    return;
  }

  dispatch_sync(senderQueue, ^{
    sender_stop(airplaySender);
    sender_destroy(airplaySender);
  });

  airplaySender = NULL;
  connectedSenderReceiver = nil;
  is_airplay_sending = false;
  senderQueue = NULL;  // Clear queue so menu shows start option
  [self setOwner:nil withTitle:DEFAULT_TITLE];
  NSLog(@"Stopped AirPlay mirroring");
}
#endif

@end

/*
https://www.cbsnews.com/live/#x
https://hlsjs.video-dev.org/demo/
https://ottverse.com/free-hls-m3u8-test-urls/
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8
*/
