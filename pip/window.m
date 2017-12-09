//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "common.h"
#import "window.h"

extern Window* currentWindow;

@implementation Window

- (id) init{
    timer = NULL;
    window_id = 0;
    NSRect rect = NSMakeRect(0, 0, kStartSize, kStartSize);
    self = [super initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    [self setAspectRatio:rect.size];

    [self center];
    [self setMovable:YES];
    [self setShowsResizeIndicator:NO];
    [self setLevel: NSFloatingWindowLevel];
    [self setMinSize:NSMakeSize(kMinSize, kMinSize)];
    [self setMaxSize:[[self screen] visibleFrame].size];

    glView = [[OpenGLView alloc] initWithFrame:rect rightCLickDelegate:self];
    [glView setWantsLayer: YES];
    [glView.layer setCornerRadius: 5];
    [glView.layer setMasksToBounds:YES];
    [self setContentView:glView];

    [self setDelegate:self];
    [self setRestorable:NO];
    [self setWindowController:NULL];
    [self setReleasedWhenClosed:NO];
    [self makeKeyAndOrderFront:self];
    [self setMovableByWindowBackground:YES];

    selectionView = [[SelectionView alloc] init];
    selectionView.selection = CGRectZero;
    selectionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    dummyView = [[NSView alloc] initWithFrame:rect];
    dummyView.wantsLayer = YES;
    dummyView.layer.backgroundColor = [NSColor blackColor].CGColor;
    dummyView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSString* text = @"Right click anywhere on the window";
    NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 250, 0)];

    [textView setFrameOrigin:NSMakePoint((NSWidth([dummyView bounds]) - NSWidth([textView frame])) / 2, (NSHeight([dummyView bounds]) - NSHeight([textView frame])) / 2)];

    [textView setString:text];
    [textView setEditable:NO];
    [textView setSelectable:NO];
    [textView setTextColor:[NSColor whiteColor]];
    [textView setAlignment:NSTextAlignmentCenter];
    [textView setBackgroundColor:[NSColor blackColor]];
    [textView setAutoresizingMask: NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin];
    [dummyView addSubview: textView];

    [self.contentView setSubviews:@[dummyView]];
    return self;
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
    CFArrayRef all_windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);

    NSSlider* slider = [[NSSlider alloc] init];

    [slider setMinValue:0.1];
    [slider setMaxValue:1.0];
    [slider setDoubleValue:self.alphaValue];
    [slider setFrame:NSMakeRect(0, 0, 200, 30)];
    slider.autoresizingMask = NSViewWidthSizable;
    [slider setTarget:self];
    [slider setAction:@selector(adjustOpacity:)];
    
    if(selectionView.selection.size.width == 0 && window_id != 0){
        NSMenuItem* item = [theMenu addItemWithTitle:@"selct region" action:@selector(selectRegion:) keyEquivalent:@""];
        [item setTarget:self];
    }

    if(window_id != 0){
        NSMenuItem* item = [theMenu addItemWithTitle:@"clear window" action:@selector(changeWindow:) keyEquivalent:@""];
        [item setTag:0];
        [item setTarget:self];
    }

    NSMenuItem* itemSlider = [[NSMenuItem alloc] init];
    [itemSlider setEnabled:YES];
    [itemSlider setView:slider];
    [theMenu addItem:itemSlider];
    [theMenu addItem:[NSMenuItem separatorItem]];

    for (CFIndex i = 0; i < CFArrayGetCount(all_windows); ++i) {
        CFDictionaryRef window_ref = (CFDictionaryRef)CFArrayGetValueAtIndex(all_windows, i);
        CFNumberRef id_ref = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowNumber);
        CFStringRef name_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowName);
        CFStringRef owner_ref = (CFStringRef)CFDictionaryGetValue(window_ref, kCGWindowOwnerName);
        CFNumberRef window_layer = (CFNumberRef)CFDictionaryGetValue(window_ref, kCGWindowLayer);
        CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue (window_ref, kCGWindowBounds);

        if(bounds){
            CGRect rect;
            CGRectMakeWithDictionaryRepresentation(bounds, &rect);
            if(rect.size.width < 100 || rect.size.height < 100) continue;
        }
        else
            continue;
        
        CFNumberGetValue(id_ref, kCFNumberIntType, &windowId);
        CFNumberGetValue(window_layer, kCFNumberIntType, &layer);
        
        if(layer != 0) continue;
        
        CFStringRef name = NULL;
        if(name_ref == NULL){
            name = CFStringCreateWithCString (NULL, "", kCFStringEncodingUTF8);;
        }
        
//        NSLog(@"%@", window_ref);
//        NSLog(@"id: %d, layer: %d, window: %@ %@", windowId, layer, owner_ref, name_ref);

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

- (void)windowDidBecomeKey:(NSNotification *)notification{
    currentWindow = self;
}

- (void)close{
    window_id = 0;
    if(timer) [timer invalidate];
    glView = NULL;
    selectionView = NULL;
    [self setContentView:NULL];
    [super close];
}

@end
