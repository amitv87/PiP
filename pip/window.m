//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"

extern NSWindow* currentWindow;

@implementation Window

- (id) init{
    timer = NULL;
    window_id = 0;
    NSRect rect = NSMakeRect(0, 0, 640, 360);
    self = [super initWithContentRect:rect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    
    [self setMovable:YES];
    [self setShowsResizeIndicator:NO];
    [self setMinSize:NSMakeSize(100, 100)];
    [self setLevel: NSFloatingWindowLevel];
    [self setStyleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskResizable];

    glView = [[OpenGLView alloc] initWithFrame:rect rightCLickDelegate:self];
    [glView setWantsLayer: YES];
    [glView.layer setCornerRadius: 5];
    [self setContentView:glView];

    [self setDelegate:self];
    [self setReleasedWhenClosed:NO];
    [self makeKeyAndOrderFront:self];
    [self setMovableByWindowBackground:YES];
    [self setRestorable:NO];
    [self setWindowController:NULL];
    
    selectionView = [[SelectionView alloc] init];
    selectionView.selection = NSMakeRect(0,0,0,0);
    return self;
}

- (BOOL) canBecomeKeyWindow{
    return YES;
}

- (void) start{
    if(timer != NULL) return;
    timer = [NSTimer scheduledTimerWithTimeInterval:0.03f target:self selector:@selector(captrue:) userInfo:nil repeats:YES];
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

    [theMenu addItem:[NSMenuItem separatorItem]];

    if(window_id != 0){
        NSMenuItem* item = [theMenu addItemWithTitle:@"pause" action:@selector(changeWindow:) keyEquivalent:@""];
        [item setTag:0];
        [item setTarget:self];
    }
    
    if(selectionView.selection.size.width == 0 && window_id != 0){
        NSMenuItem* item = [theMenu addItemWithTitle:@"selct region" action:@selector(selectRegion:) keyEquivalent:@""];
        [item setTarget:self];
    }

    NSMenuItem* item = [theMenu addItemWithTitle:@"close" action:@selector(close) keyEquivalent:@""];
    [item setTarget:self];
    
    CFRelease(all_windows);
    
    [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:glView];
}

- (void)adjustOpacity:(id)sender{
    NSSlider* slider = (NSSlider*)sender;
    [self setAlphaValue:slider.doubleValue];
}

- (void)changeWindow:(id)sender{
    window_id = (CGWindowID)[(NSMenuItem*)sender tag];
    selectionView.selection = NSMakeRect(0,0,0,0);
}

- (void)selectRegion:(id)sender{
    [self setMovable:NO];
    [selectionView setFrameSize:NSMakeSize(glView.bounds.size.width, glView.bounds.size.height)];
    [self.contentView addSubview:selectionView];
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
