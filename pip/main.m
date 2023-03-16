//
//  main.m
//  pip
//
//  Created by Amit Verma on 02/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"
#import "preferences.h"
#import <AVFoundation/AVFoundation.h>

extern int windowCount;

#define ADD_SEP() [menu addItem:[NSMenuItem separatorItem]]
#define INIT_MENU(title) {menu = [[NSMenu alloc] initWithTitle:title]; NSMenuItem* item = [[NSMenuItem alloc] init];[item setSubmenu:menu];[menubar addItem:item];}
#define ADD_ITEM(title, sel, key) [menu addItem:[[NSMenuItem alloc] initWithTitle:title action:@selector(sel) keyEquivalent:key]]

#define ADD_ITEM_MASK(title, sel, key, mask){ \
NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(sel) keyEquivalent:key]; \
item.keyEquivalentModifierMask = mask; \
[menu addItem:item]; \
}

#define XSTRINGIFY(s) #s
#define STRINGIFY(s) XSTRINGIFY(s)

#define ADD_SCALE_ITEM(scale) [self addScaleMenuItemWithTitle:@"Scale " STRINGIFY(scale) keyEquivalent:@ STRINGIFY(scale) mask:NO andScale:100 * scale toMenu:menu];
#define ADD_SCALE_ITEM_INVERSE(scale) [self addScaleMenuItemWithTitle:@"Scale 1/" STRINGIFY(scale) keyEquivalent:@ STRINGIFY(scale) mask:YES andScale:100 / scale toMenu:menu];

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

  NSMenu* menu;
  NSMenu* menubar = [[NSMenu alloc] init];
  NSString* appName = [[NSProcessInfo processInfo] processName];

  INIT_MENU(appName);
  ADD_ITEM([@"About " stringByAppendingString:appName], orderFrontStandardAboutPanel:, @"");
  ADD_SEP();
  ADD_ITEM(@"Preferences", showPreferencePanel:, @",");
  ADD_SEP();
  ADD_ITEM([@"Hide " stringByAppendingString:appName], hideAll, @"h");
  ADD_ITEM([@"Quit " stringByAppendingString:appName], terminate:, @"q");

  INIT_MENU(@"File");
  ADD_ITEM(@"New", newWindow, @"n");
  ADD_ITEM(@"Click Through", clickThrough:, @"c");
  ADD_ITEM(@"Close", performClose:, @"w");

  INIT_MENU(@"Window");
  ADD_SCALE_ITEM(1);
  ADD_SCALE_ITEM(2);
  ADD_SCALE_ITEM(3);
  ADD_SEP();
  ADD_SCALE_ITEM_INVERSE(2);
  ADD_SCALE_ITEM_INVERSE(3);
  ADD_SCALE_ITEM_INVERSE(4);
  ADD_SEP();
  ADD_ITEM_MASK(@"Zoom", performZoom:, @"z", NSEventModifierFlagCommand | NSEventModifierFlagOption);
  ADD_ITEM(@"Fullscreen", toggleFullScreen:, @"f");
  ADD_ITEM(@"Minimize", performMiniaturize:, @"m");
  ADD_ITEM(@"Always on top", toggleFloat, @"a");
  ADD_ITEM(@"Join all spaces", togglePin, @"j");
  ADD_ITEM(@"Bring All to Front", arrangeInFront:, @"");
  ADD_ITEM(@"Toggle Native PiP", toggleNativePip, @"p");

  [app setMainMenu:menubar];

  [app setDelegate:self];
  return self;
}

-(void) addScaleMenuItemWithTitle:(NSString*) title keyEquivalent:(NSString*) key mask:(BOOL) flag andScale:(NSInteger) scale toMenu:(NSMenu*) windowMenu{
  NSMenuItem* scaleItem = [windowMenu addItemWithTitle:title action:@selector(setScale:) keyEquivalent:key];
  [scaleItem setTag:scale];
  if(flag) [scaleItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
}

- (void) run{
  [app run];
}

- (void) getActiveWindow: (void (^)(Window* window))cb{
  NSWindow* currentWindow = (NSWindow*)[app keyWindow];
  if(!currentWindow || ![currentWindow isKindOfClass:[Window class]]){
    currentWindow = NULL;
    for(NSWindow* window in [app windows]){
      if([window isKindOfClass:[Window class]]){
        currentWindow = (Window*)window;
        break;
      }
    }
  }
  if(currentWindow) cb((Window*)currentWindow);
}

- (NSWindow*) newWindow{
  NSWindow* window = [[Window alloc] initWithAirplay: false andTitle:nil];
  [window makeKeyAndOrderFront:self];
  [window setIgnoresMouseEvents:clickThroughState];
  return window;
}

- (void) hideAll{
  [app hide:self];
}

-(void) clickThrough:(id)sender{
  NSMenuItem* item = (NSMenuItem*)sender;
  clickThroughState = !item.state;
  [item setState:clickThroughState];
  for(NSWindow* window in [app windows]){
    if([window isKindOfClass:[Window class]]) [window setIgnoresMouseEvents:clickThroughState];
  }
}

-(void)applicationDidFinishLaunching:(NSNotification *)notification{
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];
  [app activateIgnoringOtherApps:YES];
  [self newWindow];
//  [self showPreferencePanel:self];
  #ifndef NO_AIRPLAY
  if([(NSNumber*)getPref(@"airplay") intValue] > 0) airplay_receiver_start();
  #endif
}

- (void)applicationWillTerminate:(NSNotification *)notification{
  NSLog(@"applicationWillTerminate");
  #ifndef NO_AIRPLAY
  airplay_receiver_stop();
  #endif
}

- (void)showPreferencePanel:(id)sender{
  if(global_pref) return;
  global_pref = [[Preferences alloc] init];
  [global_pref makeKeyAndOrderFront:self];
}

-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{
  return false;
}

@end

int main(int argc, const char * argv[]) {
  [[[MyApplicationDelegate alloc] initWithApp:[NSApplication sharedApplication]] run];
  return 0;
}
