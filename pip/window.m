//
//  Window.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"

@implementation Window

- (id) init{
    self = [super init];
    timer = NULL;
    window_id = 0;
    NSRect rect = NSMakeRect(0, 0, 640, 360);
    window = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    
    [window setMovable:YES];
    [window setShowsResizeIndicator:NO];
    [window setMinSize:NSMakeSize(100, 100)];
    [window setLevel: NSFloatingWindowLevel];
    [window setStyleMask:NSWindowStyleMaskTexturedBackground | NSWindowStyleMaskResizable];

    glView = [[OpenGLView alloc] initWithFrame:rect rightCLickDelegate:self];
    [glView setWantsLayer: YES];
    [glView.layer setCornerRadius: 5];
    [window setContentView:glView];
    
    [window setOpaque:NO];
    
    [window makeKeyAndOrderFront:self];
    [window setMovableByWindowBackground:YES];
    
    selectionView = [[SelectionView alloc] init];
    selectionView.selection = NSMakeRect(0,0,0,0);
    return self;
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
    [slider setDoubleValue:window.alphaValue];
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

    NSMenuItem* item = [theMenu addItemWithTitle:@"close" action:@selector(close:) keyEquivalent:@""];
    [item setTarget:self];
    
    CFRelease(all_windows);
    
    [NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:glView];
}

- (void)adjustOpacity:(id)sender{
    NSSlider* slider = (NSSlider*)sender;
    [window setAlphaValue:slider.doubleValue];
}

- (void)changeWindow:(id)sender{
    window_id = (CGWindowID)[(NSMenuItem*)sender tag];
    selectionView.selection = NSMakeRect(0,0,0,0);
}

- (void)selectRegion:(id)sender{
    [window setMovable:NO];
    [selectionView setFrameSize:NSMakeSize(glView.bounds.size.width, glView.bounds.size.height)];
    [window.contentView addSubview:selectionView];
    [[NSCursor crosshairCursor] set];
}

- (void)close:(id)sender{
    [timer invalidate];
    [window close];
}

@end
