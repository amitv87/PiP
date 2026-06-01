//
//  main.m
//  pip
//
//  Created by Amit Verma on 02/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "window.h"
#import "preferences.h"
#import "stream_manager.h"
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#ifndef NO_AIRPLAY
#import "airplaySender.h"
#endif

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

/**
 * Returns the shared Metal device for the application.
 * Creates it on first access using dispatch_once for thread safety.
 * All windows should use this device instead of creating their own.
 * @return The shared MTLDevice instance
 */
id<MTLDevice> getSharedMTLDevice(void){
  static id<MTLDevice> sharedMTLDevice = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedMTLDevice = MTLCreateSystemDefaultDevice();
  });
  return sharedMTLDevice;
} // End of getSharedMTLDevice()

@class MyApplicationDelegate;

@interface WindowManagerPanel : NSPanel<NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource>
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSMutableArray<Window*>* windowList;
@property (nonatomic, weak) MyApplicationDelegate* appDelegate;
@property (nonatomic, strong) NSTimer* refreshTimer;
- (id)initWithAppDelegate:(MyApplicationDelegate*)delegate;
- (void)refreshWindowList;
@end

static WindowManagerPanel* windowManagerPanel = nil;

@interface MyApplicationDelegate : NSObject <NSApplicationDelegate> {
  NSApplication* app;
  NSMenuItem* windowMenuItem;
  boolean_t clickThroughState;
  bool maxWindowsAlertShown;
  bool performanceWarningShown;
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
  ADD_ITEM_MASK(@"Clone Window", cloneCurrentWindow, @"n", NSEventModifierFlagCommand | NSEventModifierFlagShift);
  ADD_ITEM(@"Open Stream URL…", loadHLSStream:, @"l");
  ADD_ITEM_MASK(@"Broadcast This Window", startStreamCurrentWindow, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift);
  ADD_ITEM(@"Click Through", clickThrough:, @"c");
  ADD_ITEM(@"Close", performClose:, @"w");

  INIT_MENU(@"Edit");
  ADD_ITEM(@"Undo", undo, @"z");
  ADD_ITEM(@"Redo", redo, @"Z");
  ADD_SEP();
  ADD_ITEM(@"Cut", cut:, @"x");
  ADD_ITEM(@"Copy", copy:, @"c");
  ADD_ITEM(@"Paste", paste:, @"v");
  ADD_SEP();
  ADD_ITEM(@"Delete", delete:, @"");
  ADD_ITEM(@"Select All", selectAll:, @"a");

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
  ADD_SEP();
  ADD_ITEM(@"Arrange in Grid", arrangeInGrid, @"g");
  ADD_ITEM(@"Cascade", arrangeInCascade, @"");
  ADD_SEP();
  ADD_ITEM_MASK(@"Close All Windows", closeAllWindows, @"w", NSEventModifierFlagCommand | NSEventModifierFlagOption);
  ADD_SEP();
  ADD_ITEM_MASK(@"Window Manager", showWindowManager, @"m", NSEventModifierFlagCommand | NSEventModifierFlagOption);

  [app setMainMenu:menubar];
  [app setWindowsMenu:menu];

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

/**
 * Creates a new PiP window, respecting the max windows preference.
 * If "clone current" behavior is selected, copies the source from the frontmost window.
 * @return The new Window, or nil if max windows limit was reached
 */
- (NSWindow*) newWindow{
  // Check max windows limit
  // max_windows preference index: 0=2, 1=4, 2=6, 3=8, 4=10
  NSInteger maxIdx = [(NSNumber*)getPref(@"max_windows") intValue];
  NSInteger maxWindows = (maxIdx + 1) * 2;
  NSArray<Window*>* currentWindows = [self allPipWindows];
  if((NSInteger)currentWindows.count >= maxWindows){
    if(!maxWindowsAlertShown){
      maxWindowsAlertShown = true;
      NSAlert* alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Window limit reached"];
      [alert setInformativeText:[NSString stringWithFormat:@"Maximum of %ld windows reached. You can change the limit in Preferences.", (long)maxWindows]];
      [alert addButtonWithTitle:@"OK"];
      [alert addButtonWithTitle:@"Preferences..."];
      NSModalResponse response = [alert runModal];
      if(response == NSAlertSecondButtonReturn){
        [self showPreferencePanel:self];
      }
    } else {
      NSBeep();
    }
    return nil;
  }

  // Show performance warning once when opening the 6th+ window
  if(!performanceWarningShown && (NSInteger)currentWindows.count >= 5){
    performanceWarningShown = true;
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Performance warning"];
    [alert setInformativeText:@"Many windows open. Performance may be affected."];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSAlertStyleInformational];
    [alert runModal];
  }

  NSWindow* window = [[Window alloc] initWithAirplay: false andTitle:nil];
  [window makeKeyAndOrderFront:self];
  [window setIgnoresMouseEvents:clickThroughState];

  // If "clone current" behavior is selected, copy the source from the previous key window
  NSInteger newWindowBehavior = [(NSNumber*)getPref(@"new_window_behavior") intValue];
  if(newWindowBehavior == 1 && currentWindows.count > 0){
    // Find the frontmost PiP window (the one that was key before this new one)
    Window* sourceWindow = nil;
    for(Window* w in currentWindows){
      if([w isVisible]){
        sourceWindow = w;
        break;
      }
    } // End of loop to find source window for cloning
    if(sourceWindow){
      [sourceWindow cloneSourceToWindow:(Window*)window];
    }
  }

  return window;
} // End of newWindow

/**
 * Clones the frontmost PiP window's source into a new window.
 * Shows an alert if the source is a camera (can't be shared).
 */
- (void) cloneCurrentWindow{
  // Check max windows limit
  NSInteger maxIdx = [(NSNumber*)getPref(@"max_windows") intValue];
  NSInteger maxWindows = (maxIdx + 1) * 2;
  NSArray<Window*>* currentWindows = [self allPipWindows];
  if((NSInteger)currentWindows.count >= maxWindows){
    if(!maxWindowsAlertShown){
      maxWindowsAlertShown = true;
      NSAlert* alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Window limit reached"];
      [alert setInformativeText:[NSString stringWithFormat:@"Maximum of %ld windows reached. You can change the limit in Preferences.", (long)maxWindows]];
      [alert addButtonWithTitle:@"OK"];
      [alert addButtonWithTitle:@"Preferences..."];
      NSModalResponse response = [alert runModal];
      if(response == NSAlertSecondButtonReturn){
        [self showPreferencePanel:self];
      }
    } else {
      NSBeep();
    }
    return;
  }

  // Find the frontmost PiP window to clone from
  __block Window* sourceWindow = nil;
  [self getActiveWindow:^(Window* window){
    sourceWindow = window;
  }];

  if(!sourceWindow){
    [self newWindow];
    return;
  }

  // Create new window and attempt clone
  NSWindow* newWin = [[Window alloc] initWithAirplay:false andTitle:nil];
  [newWin makeKeyAndOrderFront:self];
  [newWin setIgnoresMouseEvents:clickThroughState];

  BOOL cloned = [sourceWindow cloneSourceToWindow:(Window*)newWin];
  if(!cloned){
    // If clone failed (camera or no source), show alert for camera
    if([[sourceWindow sourceType] isEqualToString:@"Camera"]){
      NSAlert* alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Cannot clone"];
      [alert setInformativeText:@"Camera sources cannot be shared between windows. Right-click to select a different source."];
      [alert addButtonWithTitle:@"OK"];
      [alert runModal];
    }
  }
} // End of cloneCurrentWindow

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

/**
 * Start streaming on the active PiP window.
 * Finds the frontmost PiP window and triggers streaming via its startStreamAction: method.
 */
- (void)startStreamCurrentWindow{
  [self getActiveWindow:^(Window *window) {
    [window startStreamAction:nil];
  }];
} // End of startStreamCurrentWindow

/**
 * Returns all PiP Window instances, including minimized/hidden ones.
 * Used for counting (max windows) and closing all.
 * @return Array of Window objects
 */
- (NSArray<Window*>*) allPipWindows{
  NSMutableArray<Window*>* windows = [[NSMutableArray alloc] init];
  for(NSWindow* window in [app windows]){
    if([window isKindOfClass:[Window class]]) [windows addObject:(Window*)window];
  }
  return windows;
} // End of allPipWindows

/**
 * Returns visible PiP Window instances only.
 * Used for layout operations (grid, cascade).
 * @return Array of visible Window objects
 */
- (NSArray<Window*>*) visiblePipWindows{
  NSMutableArray<Window*>* windows = [[NSMutableArray alloc] init];
  for(NSWindow* window in [app windows]){
    if([window isKindOfClass:[Window class]] && [window isVisible]) [windows addObject:(Window*)window];
  }
  return windows;
} // End of visiblePipWindows

/**
 * Closes all open PiP windows. The app will quit since applicationShouldTerminateAfterLastWindowClosed returns YES.
 */
- (void) closeAllWindows{
  // Close preferences panel first so it doesn't keep the app alive
  if(global_pref){
    [global_pref close];
  }
  for(Window* window in [self allPipWindows]){
    [window performClose:self];
  }
} // End of closeAllWindows

/**
 * Arranges all open PiP windows in a grid layout on the current screen.
 * Uses the screen's visible frame to avoid menu bar and dock.
 * Preserves each window's aspect ratio.
 */
- (void) arrangeInGrid{
  NSArray<Window*>* windows = [self visiblePipWindows];
  NSInteger count = windows.count;
  if(count == 0) return;

  // Get visible frame from the first PiP window's screen (not keyWindow, which might be Preferences)
  NSScreen* screen = [windows[0] screen];
  if(!screen) screen = [NSScreen mainScreen];
  NSRect visibleFrame = [screen visibleFrame];

  if(count == 1){
    // Single window: center without resizing
    Window* win = windows[0];
    NSRect winFrame = [win frame];
    NSPoint center = NSMakePoint(
      visibleFrame.origin.x + (visibleFrame.size.width - winFrame.size.width) / 2,
      visibleFrame.origin.y + (visibleFrame.size.height - winFrame.size.height) / 2
    );
    [win setFrameOrigin:center];
    return;
  }

  // Calculate grid dimensions
  NSInteger cols = (NSInteger)ceil(sqrt((double)count));
  NSInteger rows = (NSInteger)ceil((double)count / cols);

  CGFloat cellW = visibleFrame.size.width / cols;
  CGFloat cellH = visibleFrame.size.height / rows;

  for(NSInteger i = 0; i < count; i++){
    Window* win = windows[i];
    NSInteger row = i / cols;
    NSInteger col = i % cols;

    // Flip row so first window is top-left (macOS has origin at bottom-left)
    NSInteger flippedRow = rows - 1 - row;

    // Scale window to fit within cell while preserving aspect ratio
    NSSize winSize = [win frame].size;
    CGFloat aspect = winSize.width / winSize.height;
    CGFloat targetW = cellW - 4;  // 2px margin on each side
    CGFloat targetH = cellH - 4;

    if(targetW / targetH > aspect){
      targetW = targetH * aspect;
    } else {
      targetH = targetW / aspect;
    }

    // Enforce minimum size
    NSSize minSize = [win minSize];
    if(targetW < minSize.width) targetW = minSize.width;
    if(targetH < minSize.height) targetH = minSize.height;

    // Center within cell
    CGFloat x = visibleFrame.origin.x + col * cellW + (cellW - targetW) / 2;
    CGFloat y = visibleFrame.origin.y + flippedRow * cellH + (cellH - targetH) / 2;

    [win setFrame:NSMakeRect(x, y, targetW, targetH) display:YES animate:YES];
  } // End of loop through windows for grid layout
} // End of arrangeInGrid

/**
 * Arranges all open PiP windows in a cascade layout, offset diagonally.
 * Wraps back to start if cascade goes off-screen.
 */
- (void) arrangeInCascade{
  NSArray<Window*>* windows = [self visiblePipWindows];
  NSInteger count = windows.count;
  if(count == 0) return;

  // Use the first PiP window's screen (not keyWindow, which might be Preferences)
  NSScreen* screen = [windows[0] screen];
  if(!screen) screen = [NSScreen mainScreen];
  NSRect visibleFrame = [screen visibleFrame];

  CGFloat offsetX = 25;
  CGFloat offsetY = 25;
  CGFloat startX = visibleFrame.origin.x + 10;
  CGFloat startY = visibleFrame.origin.y + visibleFrame.size.height;
  CGFloat curX = startX;
  CGFloat curY = startY;

  for(NSInteger i = 0; i < count; i++){
    Window* win = windows[i];
    NSSize winSize = [win frame].size;

    // Position window (top-left corner, adjusting for macOS bottom-left origin)
    CGFloat x = curX;
    CGFloat y = curY - winSize.height;

    // Wrap if window goes off-screen
    if(x + winSize.width > visibleFrame.origin.x + visibleFrame.size.width ||
       y < visibleFrame.origin.y){
      curX = startX;
      curY = startY;
      x = curX;
      y = curY - winSize.height;
    }

    [win setFrameOrigin:NSMakePoint(x, y)];

    curX += offsetX;
    curY -= offsetY;
  } // End of loop through windows for cascade layout
} // End of arrangeInCascade

-(void)applicationDidFinishLaunching:(NSNotification *)notification{
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];
  [app activateIgnoringOtherApps:YES];
  [self newWindow];

  // Pre-warm camera device enumeration in background to avoid delay on first menu access
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  });

//  [self showPreferencePanel:self];
  #ifndef NO_AIRPLAY
  if([(NSNumber*)getPref(@"airplay") intValue] > 0){
    airplay_receiver_start();
    if([(NSNumber*)getPref(@"airplay_sender") intValue] > 0){
      [NSThread sleepForTimeInterval:1.0];
      [[AirPlayDiscovery sharedDiscovery] start];
    }
  }
  #endif
}

- (void)applicationWillTerminate:(NSNotification *)notification{
  NSLog(@"applicationWillTerminate");
  #ifndef NO_AIRPLAY
  [[AirPlayDiscovery sharedDiscovery] stop];
  airplay_receiver_stop();
  #endif
}

- (void)showPreferencePanel:(id)sender{
  if(global_pref) return;
  global_pref = [[Preferences alloc] init];
  [global_pref makeKeyAndOrderFront:self];
}

/**
 * Shows the window manager panel. Creates it if it doesn't exist.
 */
- (void)showWindowManager{
  if(!windowManagerPanel){
    windowManagerPanel = [[WindowManagerPanel alloc] initWithAppDelegate:self];
  }
  [windowManagerPanel makeKeyAndOrderFront:self];
  [windowManagerPanel refreshWindowList];
}

-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{
  // Must return NO because Window is an NSPanel subclass.
  // NSPanel windows are NOT counted by AppKit for this check,
  // so returning YES causes immediate termination at launch.
  // Termination is handled manually in Window's windowWillClose: instead.
  return NO;
}

@end

#pragma mark - Window Manager Panel

@implementation WindowManagerPanel

/**
 * Initializes the window manager panel.
 * @param delegate The app delegate for accessing PiP windows
 * @return The initialized panel
 */
- (id)initWithAppDelegate:(MyApplicationDelegate*)delegate{
  self = [super
          initWithContentRect:NSMakeRect(0, 0, 420, 250)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
          backing:NSBackingStoreBuffered defer:YES
  ];
  self.delegate = self;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
  [self setTitle:@"Window Manager"];
  self.minSize = NSMakeSize(300, 150);

  _appDelegate = delegate;
  _windowList = [[NSMutableArray alloc] init];

  NSView* rootView = [[NSView alloc] init];
  rootView.translatesAutoresizingMaskIntoConstraints = false;

  NSScrollView* scrollView = [[NSScrollView alloc] init];
  scrollView.hasHorizontalScroller = false;
  scrollView.hasVerticalScroller = true;
  scrollView.translatesAutoresizingMaskIntoConstraints = false;
  [rootView addSubview:scrollView];

  // Fill root view with scroll view
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeLeft multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeRight multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeTop multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeBottom multiplier:1 constant:0]];

  _tableView = [[NSTableView alloc] init];
  _tableView.delegate = self;
  _tableView.dataSource = self;
  _tableView.headerView = nil;
  _tableView.intercellSpacing = NSMakeSize(0, 2);
  _tableView.translatesAutoresizingMaskIntoConstraints = NO;
  _tableView.rowHeight = 28;
  _tableView.doubleAction = @selector(onDoubleClick:);
  _tableView.target = self;

  NSTableColumn* nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  nameCol.title = @"Source";
  nameCol.width = 200;
  [_tableView addTableColumn:nameCol];

  NSTableColumn* typeCol = [[NSTableColumn alloc] initWithIdentifier:@"type"];
  typeCol.title = @"Tipo";
  typeCol.width = 80;
  [_tableView addTableColumn:typeCol];

  NSTableColumn* statusCol = [[NSTableColumn alloc] initWithIdentifier:@"status"];
  statusCol.title = @"Estado";
  statusCol.width = 80;
  [_tableView addTableColumn:statusCol];

  scrollView.documentView = _tableView;
  [self setContentView:rootView];

  // Center on screen
  NSSize windowSize = [self frame].size;
  NSSize screenSize = [[self screen] visibleFrame].size;
  NSPoint origin = [[self screen] visibleFrame].origin;
  NSPoint point = NSMakePoint(origin.x + screenSize.width/2 - windowSize.width/2, origin.y + screenSize.height/2 - windowSize.height/2);
  [self setFrameOrigin:point];

  return self;
} // End of initWithAppDelegate:

/**
 * Refreshes the list of open PiP windows and reloads the table.
 */
- (void)refreshWindowList{
  [_windowList removeAllObjects];
  for(NSWindow* window in [[NSApplication sharedApplication] windows]){
    if([window isKindOfClass:[Window class]]){
      [_windowList addObject:(Window*)window];
    }
  } // End of loop through windows
  [_tableView reloadData];
} // End of refreshWindowList

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView{
  return _windowList.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row{
  if(row >= (NSInteger)_windowList.count) return nil;
  Window* win = _windowList[row];

  NSTableCellView* cell = [[NSTableCellView alloc] init];
  NSTextField* text = [[NSTextField alloc] init];
  text.editable = NO;
  text.selectable = NO;
  text.bezeled = NO;
  text.drawsBackground = NO;
  text.translatesAutoresizingMaskIntoConstraints = false;

  if([tableColumn.identifier isEqual:@"name"]){
    text.stringValue = [win title] ?: @"Untitled";
    text.lineBreakMode = NSLineBreakByTruncatingTail;
  } else if([tableColumn.identifier isEqual:@"type"]){
    text.stringValue = [win sourceType];
    text.textColor = [NSColor secondaryLabelColor];
  } else if([tableColumn.identifier isEqual:@"status"]){
    NSString* status = [win sourceStatus];
    text.stringValue = status;
    if([status isEqualToString:@"Active"]){
      text.textColor = [NSColor systemGreenColor];
    } else if([status isEqualToString:@"No source"]){
      text.textColor = [NSColor tertiaryLabelColor];
    } else {
      text.textColor = [NSColor systemOrangeColor];
    }
  }

  [cell addSubview:text];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeLeft multiplier:1 constant:8]];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeRight multiplier:1 constant:-8]];

  return cell;
}

- (nullable NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row{
  NSTableRowView* rowView = [[NSTableRowView alloc] init];
  rowView.emphasized = false;
  return rowView;
}

/**
 * Handles double-click on a row: focuses the corresponding PiP window.
 * @param sender The table view
 */
- (void)onDoubleClick:(id)sender{
  NSInteger row = [_tableView clickedRow];
  if(row < 0 || row >= (NSInteger)_windowList.count) return;
  Window* win = _windowList[row];
  [win makeKeyAndOrderFront:nil];
} // End of onDoubleClick:

- (void)tableViewSelectionDidChange:(NSNotification *)notification{
  NSInteger row = [_tableView selectedRow];
  if(row < 0 || row >= (NSInteger)_windowList.count) return;
  Window* win = _windowList[row];
  [win makeKeyAndOrderFront:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  [self refreshWindowList];

  // Start auto-refresh timer (weakSelf to avoid retain cycle with repeating timer)
  if(!_refreshTimer){
    __weak WindowManagerPanel* weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer* timer){
      WindowManagerPanel* strongSelf = weakSelf;
      if(strongSelf) [strongSelf refreshWindowList];
      else [timer invalidate];
    }];
  }
}

- (void)windowDidResignKey:(NSNotification *)notification{
  // Stop auto-refresh when panel loses focus
  if(_refreshTimer){
    [_refreshTimer invalidate];
    _refreshTimer = nil;
  }
}

- (void)windowWillClose:(NSNotification *)notification{
  if(_refreshTimer){
    [_refreshTimer invalidate];
    _refreshTimer = nil;
  }
  windowManagerPanel = nil;
} // End of windowWillClose:

@end

int main(int argc, const char * argv[]) {
  [[[MyApplicationDelegate alloc] initWithApp:[NSApplication sharedApplication]] run];
  return 0;
}
