//
//  main.m
//  pip
//
//  Created by Amit Verma on 02/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"

Window* currentWindow = NULL;

@interface MyApplicationDelegate : NSObject <NSApplicationDelegate> {
    NSApplication* app;
    NSMenuItem* windowMenuItem;
    boolean_t clickThroughState;
}
@end

@implementation MyApplicationDelegate
-(id)initWithApp:(NSApplication*) application{
    self = [super init];
    app = application;
    clickThroughState = false;

    NSString* appName = [[NSProcessInfo processInfo] processName];

    NSMenu* menubar = [[NSMenu alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:appName];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newWindow) keyEquivalent:@"n"]];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Click Through" action:@selector(clickThrough:) keyEquivalent:@"c"]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(terminate:) keyEquivalent:@"q"]];

    [self addScaleMenuItemWithTitle:@"Scale 1x" keyEquivalent:@"1" mask:NO andScale:100 toMenu:windowMenu];
    [self addScaleMenuItemWithTitle:@"Scale 2x" keyEquivalent:@"2" mask:NO andScale:200 toMenu:windowMenu];
    [self addScaleMenuItemWithTitle:@"Scale 3x" keyEquivalent:@"3" mask:NO andScale:300 toMenu:windowMenu];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [self addScaleMenuItemWithTitle:@"Scale 1/2x" keyEquivalent:@"2" mask:YES andScale:100/2 toMenu:windowMenu];
    [self addScaleMenuItemWithTitle:@"Scale 1/3x" keyEquivalent:@"3" mask:YES andScale:100/3 toMenu:windowMenu];
    [self addScaleMenuItemWithTitle:@"Scale 1/4x" keyEquivalent:@"4" mask:YES andScale:100/4 toMenu:windowMenu];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Close Current" action:@selector(closeWindow) keyEquivalent:@"w"]];

    windowMenuItem = [[NSMenuItem alloc] init];
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];

    [appMenuItem setSubmenu:appMenu];
    [windowMenuItem setSubmenu:windowMenu];

    [menubar addItem:appMenuItem];
    [menubar addItem:windowMenuItem];

    [app setMainMenu:menubar];

    [app setDelegate:self];
    return self;
}

-(void) addScaleMenuItemWithTitle:(NSString*) title keyEquivalent:(NSString*) key mask:(BOOL) flag andScale:(NSInteger) scale toMenu:(NSMenu*) windowMenu{
    NSMenuItem* scaleItem = [windowMenu addItemWithTitle:title action:@selector(setScale:) keyEquivalent:key];
    [scaleItem setTag:scale];
    [scaleItem setTarget:self];
    if(flag) [scaleItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
}

- (void) run{
    [app run];
}

- (void) closeWindow{
    if([[app windows] count] == 1) [windowMenuItem setEnabled:NO];
    if(currentWindow){
        Window* cWindow = currentWindow;
        currentWindow = NULL;
        [cWindow close];
    }
}

- (void) newWindow{
    Window* window = [[Window alloc] init];
    [window start];
    [window setIgnoresMouseEvents:clickThroughState];
    [windowMenuItem setEnabled:YES];
}

- (void) setScale:(id)sender{
    if(currentWindow) [currentWindow setScale:[sender tag]];
}

-(void) clickThrough:(id)sender{
    NSMenuItem* item = (NSMenuItem*)sender;
    clickThroughState = !item.state;
    [item setState:clickThroughState];
    for(NSWindow* window in [app windows]){
        [window setIgnoresMouseEvents:clickThroughState];
    }
}

-(void)applicationDidFinishLaunching:(NSNotification *)notification{
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app activateIgnoringOtherApps:YES];
    [self newWindow];
}

@end

int main(int argc, const char * argv[]) {
    [[[MyApplicationDelegate alloc] initWithApp:[NSApplication sharedApplication]] run];
    return 0;
}
