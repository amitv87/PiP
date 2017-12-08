//
//  main.m
//  pip
//
//  Created by Amit Verma on 02/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"

NSWindow* currentWindow = NULL;

@interface MyApplicationDelegate : NSObject <NSApplicationDelegate> {
    NSApplication* app;
    NSMenuItem* closeItem;
}
@end

@implementation MyApplicationDelegate
-(id)initWithApp:(NSApplication*) application{
    self = [super init];
    
    app = application;
    
    id appMenu = [NSMenu new];
    id appName = [[NSProcessInfo processInfo] processName];
    
    // todo: multiple windows
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newWindow) keyEquivalent:@"n"]];
    closeItem = [[NSMenuItem alloc] initWithTitle:@"Close Current" action:@selector(closeWindow) keyEquivalent:@"w"];
    [closeItem setHidden:YES];

    [appMenu addItem:closeItem];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(terminate:) keyEquivalent:@"q"]];
    
    id appMenuItem = [NSMenuItem new];
    [appMenuItem setSubmenu:appMenu];
    
    id menubar = [NSMenu new];
    [menubar addItem:appMenuItem];
    [app setMainMenu:menubar];
    
    [app setDelegate:self];
    [app activateIgnoringOtherApps:YES];
    return self;
}

- (void) run{
    [app run];
}

- (void) closeWindow{
    if([[app windows] count] == 1) [closeItem setHidden:YES];
    if(currentWindow){
        NSWindow* cWindow = currentWindow;
        currentWindow = NULL;
        [cWindow close];
    }
}

- (void) newWindow{
    [[[Window alloc] init] start];
    [closeItem setHidden:NO];
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
