//
//  preferences.m
//  PiP
//
//  Created by Amit Verma on 28/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import "preferences.h"
#import <QuartzCore/QuartzCore.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <AVFoundation/AVFoundation.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

Preferences* global_pref = nil;
static NSPanel* sourceNamesPanel = nil;

static NSDictionary* sourceNone(void){
  return @{@"type": @"none"};
}

static NSDictionary* sourceFromDisplayId(NSNumber* displayId){
  return @{@"type": @"display", @"id": displayId};
}

static NSDictionary* sourceFromCameraId(NSString* cameraId){
  return @{@"type": @"camera", @"id": cameraId};
}

static NSDictionary* normalizeSourcePreference(NSObject* source){
  if([source isKindOfClass:[NSDictionary class]]){
    NSDictionary* sourceDict = (NSDictionary*)source;
    NSString* type = sourceDict[@"type"];
    NSObject* sourceId = sourceDict[@"id"];
    if([type isEqualToString:@"display"] && [sourceId isKindOfClass:[NSNumber class]] && [(NSNumber*)sourceId intValue] > 0){
      return sourceFromDisplayId((NSNumber*)sourceId);
    }
    if([type isEqualToString:@"camera"] && [sourceId isKindOfClass:[NSString class]] && ((NSString*)sourceId).length > 0){
      return sourceFromCameraId((NSString*)sourceId);
    }
    if([type isEqualToString:@"none"]){
      return sourceNone();
    }
  }
  if([source isKindOfClass:[NSNumber class]] && [(NSNumber*)source intValue] > 0){
    return sourceFromDisplayId((NSNumber*)source);
  }
  if([source isKindOfClass:[NSString class]] && ((NSString*)source).length > 0){
    return sourceFromCameraId((NSString*)source);
  }
  return sourceNone();
}

/**
 * Gets a stable identifier for a display using EDID data (vendor, model, serial).
 * This identifier remains stable across reboots unlike CGDirectDisplayID.
 * Note: We only use CoreGraphics APIs here to avoid WindowServer deadlocks
 * that can occur when calling NSScreen APIs during display reconfiguration.
 * @param displayId The CGDirectDisplayID of the display
 * @return A stable identifier string
 */
NSString* getStableDisplayIdentifier(CGDirectDisplayID displayId){
  uint32_t vendorId = CGDisplayVendorNumber(displayId);
  uint32_t modelId = CGDisplayModelNumber(displayId);
  uint32_t serialNum = CGDisplaySerialNumber(displayId);

  // Use EDID data (vendor-model-serial) as stable identifier
  // This is safe to call anytime and doesn't touch WindowServer/NSScreen
  return [NSString stringWithFormat:@"%u-%u-%u", vendorId, modelId, serialNum];
} // End of getStableDisplayIdentifier()

/**
 * Gets the custom display name for a given display ID.
 * @param displayId The CGDirectDisplayID of the display
 * @return The custom name if set, otherwise nil
 */
NSString* getCustomDisplayNameForId(CGDirectDisplayID displayId){
  NSDictionary* customNames = (NSDictionary*)getPref(@"display_custom_names");
  if(!customNames) return nil;

  // First try stable identifier
  NSString* stableKey = getStableDisplayIdentifier(displayId);
  if(stableKey){
    NSString* name = customNames[stableKey];
    if(name) return name;
  }

  // Fallback to old format for backwards compatibility
  NSString* legacyKey = [NSString stringWithFormat:@"%u", displayId];
  return customNames[legacyKey];
} // End of getCustomDisplayNameForId()

/**
 * Gets the custom camera name for a given camera unique ID.
 * @param cameraId The AVCaptureDevice unique ID
 * @return The custom name if set, otherwise nil
 */
NSString* getCustomCameraNameForId(NSString* cameraId){
  if(!cameraId || cameraId.length == 0) return nil;
  NSDictionary* customNames = (NSDictionary*)getPref(@"camera_custom_names");
  if(!customNames) return nil;
  return customNames[cameraId];
} // End of getCustomCameraNameForId()

/**
 * Gets the display name for a given display ID, using custom name if available.
 * @param displayId The CGDirectDisplayID of the display
 * @return The custom name if set, otherwise the system localized name
 */
NSString* getDisplayNameForId(CGDirectDisplayID displayId){
  NSString* customName = getCustomDisplayNameForId(displayId);
  if(customName && customName.length > 0) return customName;

  // Find the screen and return its localized name
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] unsignedIntValue];
    if(did == displayId){
      if (@available(macOS 10.15, *)) return [screen localizedName];
      return [NSString stringWithFormat:@"Display %u", displayId];
    }
  } // End of loop through screens
  return [NSString stringWithFormat:@"Display %u", displayId];
} // End of getDisplayNameForId()

/**
 * Gets the camera name for a given camera ID, using custom name if available.
 * @param cameraId The AVCaptureDevice unique ID
 * @return The custom name if set, otherwise the system camera name
 */
NSString* getCameraNameForId(NSString* cameraId){
  NSString* customName = getCustomCameraNameForId(cameraId);
  if(customName && customName.length > 0) return customName;

  AVCaptureDevice* camera = [AVCaptureDevice deviceWithUniqueID:cameraId];
  if(camera){
    NSString* localizedName = [camera localizedName];
    if(localizedName && localizedName.length > 0) return localizedName;
  }
  return cameraId && cameraId.length > 0 ? cameraId : @"Camera";
} // End of getCameraNameForId()

/**
 * Sets a custom display name for a given display ID.
 * Uses stable identifier (EDID-based) to persist names across reboots.
 * @param displayId The CGDirectDisplayID of the display
 * @param name The custom name to set (empty string to clear)
 */
void setCustomDisplayName(CGDirectDisplayID displayId, NSString* name){
  NSDictionary* existingNames = (NSDictionary*)[[NSUserDefaults standardUserDefaults] objectForKey:@"display_custom_names"];
  NSMutableDictionary* customNames = existingNames ? [existingNames mutableCopy] : [[NSMutableDictionary alloc] init];

  // Use stable identifier instead of display ID
  NSString* stableKey = getStableDisplayIdentifier(displayId);
  if(!stableKey){
    stableKey = [NSString stringWithFormat:@"%u", displayId];
  }

  // Remove any legacy entry with just the display ID
  NSString* legacyKey = [NSString stringWithFormat:@"%u", displayId];
  if(![stableKey isEqualToString:legacyKey]){
    [customNames removeObjectForKey:legacyKey];
  }

  if(name && name.length > 0){
    customNames[stableKey] = name;
  } else {
    [customNames removeObjectForKey:stableKey];
  }

  [[NSUserDefaults standardUserDefaults] setObject:customNames forKey:@"display_custom_names"];
} // End of setCustomDisplayName()

/**
 * Sets a custom camera name for a given camera unique ID.
 * @param cameraId The AVCaptureDevice unique ID
 * @param name The custom name to set (empty string to clear)
 */
void setCustomCameraName(NSString* cameraId, NSString* name){
  if(!cameraId || cameraId.length == 0) return;

  NSDictionary* existingNames = (NSDictionary*)[[NSUserDefaults standardUserDefaults] objectForKey:@"camera_custom_names"];
  NSMutableDictionary* customNames = existingNames ? [existingNames mutableCopy] : [[NSMutableDictionary alloc] init];

  if(name && name.length > 0){
    customNames[cameraId] = name;
  } else {
    [customNames removeObjectForKey:cameraId];
  }

  [[NSUserDefaults standardUserDefaults] setObject:customNames forKey:@"camera_custom_names"];
} // End of setCustomCameraName()

/**
 * Gets the list of available displays with their names (using custom names if set).
 * @return An array of dictionaries with "name" and "id" keys
 */
NSArray* getDisplayList(void){
  NSMutableArray* displays = [[NSMutableArray alloc] init];
  [displays addObject:@{@"name": @"None", @"id": @-1}];
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] unsignedIntValue];
    NSString* name = getDisplayNameForId(did);
    [displays addObject:@{@"name": name, @"id": [NSNumber numberWithUnsignedInt:did]}];
  } // End of loop through screens
  return displays;
} // End of getDisplayList()

/**
 * Returns the default source preference with migration from legacy default_display.
 * @return A dictionary in the form {type: "none|display|camera", id: ...}
 */
NSDictionary* getDefaultSourcePreference(void){
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSObject* sourcePref = [defaults objectForKey:@"default_source"];
  if(sourcePref){
    NSDictionary* normalized = normalizeSourcePreference(sourcePref);
    if(![normalized isEqual:sourcePref]){
      [defaults setObject:normalized forKey:@"default_source"];
    }
    return normalized;
  }

  NSObject* legacyDefaultDisplay = [defaults objectForKey:@"default_display"];
  NSDictionary* migrated = normalizeSourcePreference(legacyDefaultDisplay);
  [defaults setObject:migrated forKey:@"default_source"];
  return migrated;
} // End of getDefaultSourcePreference()

/**
 * Gets the list of available capture sources (displays + cameras).
 * @return An array of dictionaries with "name" and "value" keys
 */
NSArray* getSourceList(void){
  NSMutableArray* sources = [[NSMutableArray alloc] init];
  [sources addObject:@{@"name": @"None", @"value": sourceNone()}];

  NSMutableArray* displaySources = [[NSMutableArray alloc] init];
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] unsignedIntValue];
    NSString* name = [NSString stringWithFormat:@"Display - %@", getDisplayNameForId(did)];
    [displaySources addObject:@{
      @"name": name,
      @"value": sourceFromDisplayId([NSNumber numberWithUnsignedInt:did]),
    }];
  }
  [displaySources sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
  }];
  [sources addObjectsFromArray:displaySources];

  NSMutableArray* cameraSources = [[NSMutableArray alloc] init];
  NSArray<AVCaptureDevice*>* cameras = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for(AVCaptureDevice* camera in cameras){
    NSString* cameraId = [camera uniqueID];
    if(!cameraId || cameraId.length == 0) continue;
    NSString* name = [NSString stringWithFormat:@"Camera - %@", getCameraNameForId(cameraId)];
    [cameraSources addObject:@{
      @"name": name,
      @"value": sourceFromCameraId(cameraId),
    }];
  }
  [cameraSources sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
  }];
  [sources addObjectsFromArray:cameraSources];

  return sources;
} // End of getSourceList()

typedef enum{
  OptionTypeNumber,
  OptionTypeSelect,
  OptionTypeCheckBox,
  OptionTypeTextInput,
  OptionTypeSourceSelect,
  OptionTypeButton,
} OptionType;

#define OPTION(name, text, type, options, value, desc) \
  @{@"name": @#name, @"text": @text, @"type": [NSNumber numberWithInt:OptionType##type], @"options": options, @"value": value, @"desc": desc}

static NSArray* getPrefsArray(void){
  NSMutableArray* prefs = [NSMutableArray arrayWithArray:@[
    OPTION(hidpi, "Use HiDPI mode", CheckBox, [NSNull null], @1, @"on supported displays"),
    OPTION(renderer, "Display Renderer", Select, (@[@"Metal", @"Opengl"]), [NSNumber numberWithInt:DisplayRendererTypeOpenGL], [NSNull null]),
    OPTION(default_source, "Default Source", SourceSelect, [NSNull null], sourceNone(), [NSNull null]),
    OPTION(source_names, "Source Names", Button, [NSNull null], [NSNull null], @"Configure..."),
    #ifndef NO_AIRPLAY
    OPTION(airplay, "AirPlay Receiver", CheckBox, [NSNull null], @0, @"Use PiP as Airplay receiver"),
    OPTION(airplay_scale_factor, "AirPlay Scale factor", Select, (@[@"1.00", @"2.00", @"3.00", @"Default"]), @3, [NSNull null]),
    OPTION(airplay_sender, "AirPlay Sender", CheckBox, [NSNull null], @0, @"Enable AirPlay mirroring to other devices"),
    OPTION(airplay_sender_quality, "Mirroring Quality", Select, (@[@"Low", @"Medium", @"High"]), @1, @"Video quality preset for mirroring"),
    OPTION(airplay_sender_audio, "Mirror Audio", CheckBox, [NSNull null], @1, @"Include audio when mirroring"),
    #endif
    OPTION(wfilter_null_title, "Exclude windows", CheckBox, [NSNull null], @0, @"when title is null"),
    OPTION(wfilter_epmty_title, "Exclude windows", CheckBox, [NSNull null], @0, @"when title is empty"),
    OPTION(wfilter_floating, "Exclude windows", CheckBox, [NSNull null], @1, @"that are floating"),
    OPTION(wfilter_desktop_elemnts, "Exclude windows", CheckBox, [NSNull null], @1, @"that are desktop elements"),
    OPTION(mouse_capture, "Show mouse cursor", CheckBox, [NSNull null], @0, @"when pipping screen"),
    OPTION(new_window_behavior, "New Window", Select, (@[@"Blank with hint", @"Clone current window"]), @0, [NSNull null]),
    OPTION(max_windows, "Max Windows", Select, (@[@"2", @"4", @"6", @"8", @"10"]), @3, [NSNull null]),
    OPTION(stream_port, "Streaming Port", TextInput, [NSNull null], @"8080", @"HTTP server port"),
    OPTION(stream_quality, "Streaming Quality", Select, (@[@"Low (720p)", @"Medium (1080p)", @"High (native)"]), @1, [NSNull null]),
  ]];

  // Add ScreenCaptureKit option only on macOS 12.3+
  if (@available(macOS 12.3, *)) {
    #if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
    // ScreenCaptureKit headers are available, check if class is available at runtime
    NSLog(@"SCStream class: %@", [SCStream class]);
    if ([SCStream class] != nil) {
      [prefs addObject:OPTION(use_screencapturekit, "Use ScreenCaptureKit", CheckBox, [NSNull null], @1, @"for window capture (macOS 12.3+)")];
    }
    #endif
  }

  return prefs;
}

static NSDictionary* getDefaultPrefs(void){
  NSMutableDictionary* prefs = [[NSMutableDictionary alloc] init];
  for(NSDictionary* opt in getPrefsArray()) [prefs setObject:opt forKey:opt[@"name"]];
  return prefs;
}

void setPref(NSString* key, NSObject* val){
//  NSLog(@"setPref %@ -> %@", key, val);
  [[NSUserDefaults standardUserDefaults] setObject:val forKey:key];
}

NSObject* getPref(NSString* key){
  NSObject* val = [[NSUserDefaults standardUserDefaults] objectForKey:key];
  if(!val) val = getDefaultPrefs()[key][@"value"];
//  NSLog(@"getPref %@ -> %@", key, val);
  return val;
}

NSObject* getPrefOption(NSString* key){
  NSArray* options = getDefaultPrefs()[key][@"options"];
  return [options objectAtIndex:[(NSNumber*)getPref(key) intValue]];
}

@implementation Preferences{
  NSViewController* nvc;
  NSArray* opts;
}

-(id)init{
  self = [super
          initWithContentRect:NSMakeRect(0, 0, 450, 290)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskNonactivatingPanel
          backing:NSBackingStoreBuffered defer:YES
  ];
  self.delegate = self;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
  [self setTitle:@"PiP Preferences"];

  opts = getPrefsArray();

  NSScrollView* scrollView = [[NSScrollView alloc] init];
  scrollView.hasHorizontalScroller = true;
  scrollView.hasVerticalScroller = true;
  scrollView.contentInsets = NSEdgeInsetsMake(0,0,0,0);
  scrollView.automaticallyAdjustsContentInsets = false;
  scrollView.translatesAutoresizingMaskIntoConstraints = false;

  NSView* rootView = [[NSView alloc] init];
  [rootView addSubview:scrollView];

  for(NSInteger attr = NSLayoutAttributeLeft; attr <= NSLayoutAttributeBottom; attr++){
    [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:attr relatedBy:NSLayoutRelationEqual toItem:rootView attribute:attr multiplier:1 constant:0]];
  }

//  NSDictionary *viewBindings = NSDictionaryOfVariableBindings(rootView,scrollView);
//  [rootView addConstraints: [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(0)-[scrollView]-(0)-|" options:0 metrics:nil views:viewBindings]];
//  [rootView addConstraints: [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(0)-[scrollView]-(0)-|" options:0 metrics:nil views:viewBindings]];

  NSTableView* tableView = [[NSTableView alloc] init];;
  tableView.frame = rootView.bounds;
  tableView.headerView.hidden = true;
  tableView.delegate = self;
  tableView.dataSource = self;
  tableView.headerView = nil;
  tableView.intercellSpacing = NSMakeSize(0,0);
  tableView.translatesAutoresizingMaskIntoConstraints = NO;
  tableView.layer.borderWidth = 0;

//  tableView.allowsColumnResizing = true;
//  tableView.usesAutomaticRowHeights = YES;
  tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

  [tableView addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"option"]];
  [tableView addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"value"]];

  scrollView.documentView = tableView;

  rootView.translatesAutoresizingMaskIntoConstraints = false;
//  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:rootView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:450]];

  [self setContentView:rootView];

  NSSize windowSize = [self frame].size;
  NSSize screenSize = [[self screen] visibleFrame].size;
  NSPoint point = NSMakePoint(screenSize.width/2 - windowSize.width/2, screenSize.height/2 - windowSize.height/2);
  [self setFrameOrigin:point];

  return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView{
  return opts.count;
}

- (void)onCheck:(NSButton*)sender{
//  NSLog(@"onCheck: %@ -> %ld", sender.identifier, sender.state);
  setPref(sender.identifier, [NSNumber numberWithLong:sender.state]);
  #ifndef NO_AIRPLAY
  void airplay_receiver_start(void);
  void airplay_receiver_stop(void);
  if([sender.identifier isEqual:@"airplay"]){
    if(sender.state) airplay_receiver_start();
    else airplay_receiver_stop();
  }
  #endif
}

- (void)onSelect:(NSMenuItem*)sender{
  NSArray* options =  getDefaultPrefs()[sender.identifier][@"options"];
  long index = [options indexOfObject:sender.title];
//  NSLog(@"onSelect: %@ -> %@(%ld)", sender.identifier, sender.title, index);
  setPref(sender.identifier, [NSNumber numberWithLong:index]);
}

- (void)onSourceSelect:(NSMenuItem*)sender{
  NSDictionary* source = normalizeSourcePreference([sender representedObject]);
//  NSLog(@"onSourceSelect: %@ -> %@", sender.identifier, source);
  setPref(sender.identifier, source);
}

- (void)onButtonClick:(NSButton*)sender{
  if([sender.identifier isEqual:@"source_names"]){
    showSourceNamesPanel();
  }
} // End of onButtonClick()

/**
 * Handles text input end editing for TextInput preferences.
 * Saves the text field value as a string preference.
 * @param notification The notification containing the text field
 */
- (void)controlTextDidEndEditing:(NSNotification *)notification{
  NSTextField* textField = notification.object;
  if(textField.identifier){
    setPref(textField.identifier, textField.stringValue);
  }
} // End of controlTextDidEndEditing:

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row{
  NSInteger col = [[tableView tableColumns] indexOfObject:tableColumn];
//  NSLog(@"row: %ld, col: %ld", row, col);
  NSView* view;
  NSTableCellView* cell = [[NSTableCellView alloc] init];
  NSDictionary* pref = opts[row];
  if(col == 0){
    NSTextField* text = [[NSTextField alloc] init];
    text.alignment = NSTextAlignmentRight;
    text.editable = false;
    text.stringValue = pref[@"text"];
    text.drawsBackground = false;
    text.bordered = false;
    text.translatesAutoresizingMaskIntoConstraints = false;
    view = text;
  }
  else if(col == 1){
//    NSLog(@"option: %@", option);
    NSInteger type = [pref[@"type"] intValue];
    NSString* key = pref[@"name"];
    NSObject* value = getPref(key);
    if(!value) value = pref[@"value"];
    switch(type){
      case OptionTypeNumber:
        break;
      case OptionTypeSelect:{
        NSPopUpButton* button = [[NSPopUpButton alloc] init];
        button.translatesAutoresizingMaskIntoConstraints = false;
        button.menu = [[NSMenu alloc] init];

        NSArray* options = pref[@"options"];
        for(int i = 0; i < options.count; i++){
          NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:options[i] action:@selector(onSelect:) keyEquivalent:@""];
          item.target = self;
          item.identifier = key;
          [button.menu addItem:item];
        }
        [button selectItem:[button.menu itemArray][[(NSNumber*)value intValue]]];
        view = button;
        break;
      }
      case OptionTypeCheckBox:{
        NSButton* checkBox = [NSButton checkboxWithTitle:pref[@"desc"] target:self action:@selector(onCheck:)];
        checkBox.translatesAutoresizingMaskIntoConstraints = false;
        checkBox.state = [(NSNumber*)value intValue] > 0 ? NSOnState : NSOffState;
        checkBox.identifier = key;
        view = checkBox;
        break;
      }
      case OptionTypeTextInput:{
        NSTextField* textField = [[NSTextField alloc] init];
        textField.translatesAutoresizingMaskIntoConstraints = false;
        textField.editable = YES;
        textField.selectable = YES;
        textField.bezeled = YES;
        textField.bezelStyle = NSTextFieldSquareBezel;
        textField.drawsBackground = YES;
        textField.identifier = key;
        textField.delegate = self;
        if ([value isKindOfClass:[NSString class]]) {
          textField.stringValue = (NSString*)value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
          textField.stringValue = [(NSNumber*)value stringValue];
        } else {
          textField.stringValue = @"";
        }
        if (pref[@"desc"] && pref[@"desc"] != [NSNull null]) {
          textField.placeholderString = (NSString*)pref[@"desc"];
        }
        view = textField;
        break;
      }
      case OptionTypeSourceSelect:{
        NSPopUpButton* button = [[NSPopUpButton alloc] init];
        button.translatesAutoresizingMaskIntoConstraints = false;
        button.menu = [[NSMenu alloc] init];

        NSDictionary* savedSource = getDefaultSourcePreference();
        NSArray* sources = getSourceList();
        int selectedIndex = 0;
        for(int i = 0; i < sources.count; i++){
          NSDictionary* source = sources[i];
          NSDictionary* sourceValue = normalizeSourcePreference(source[@"value"]);
          NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:source[@"name"] action:@selector(onSourceSelect:) keyEquivalent:@""];
          item.target = self;
          item.identifier = key;
          item.representedObject = sourceValue;
          [button.menu addItem:item];
          if([sourceValue isEqual:savedSource]) selectedIndex = i;
        } // End of loop through sources
        [button selectItem:[button.menu itemArray][selectedIndex]];
        view = button;
        break;
      }
      case OptionTypeButton:{
        NSButton* button = [NSButton buttonWithTitle:pref[@"desc"] target:self action:@selector(onButtonClick:)];
        button.translatesAutoresizingMaskIntoConstraints = false;
        button.bezelStyle = NSBezelStyleRounded;
        button.identifier = key;
        view = button;
        break;
      }
    }
  }
  if(!view) goto end;

  [cell addSubview:view];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeLeft multiplier:1 constant:13]];
  [cell addConstraint:[NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeRight multiplier:1 constant:-13]];

  end:
  return  cell;
}

- (nullable NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row{
  NSTableRowView* rowView = [[NSTableRowView alloc] init];
  rowView.emphasized = false;
  return rowView;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex{
    return NO;
}

/**
 * Returns the height for a specific row in the preferences table.
 * Adds extra spacing after certain rows to create visual groups.
 * @param tableView The table view
 * @param row The row index
 * @return The height for the row
 */
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row{
  CGFloat baseHeight = 26;
  // Add 12pt padding below Display Renderer, Default Source, and Source Names rows
  if(row == 1 || row == 2 || row == 3){
    return baseHeight + 12;
  }
  return baseHeight;
} // End of tableView:heightOfRow:

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)notification{
  global_pref = nil;

  // If no PiP windows remain, quit the app
  BOOL hasPipWindows = NO;
  Class windowClass = NSClassFromString(@"Window");
  if(windowClass){
    for(NSWindow* window in [[NSApplication sharedApplication] windows]){
      if([window isKindOfClass:windowClass]){
        hasPipWindows = YES;
        break;
      }
    } // End of loop checking for remaining PiP windows
  }
  if(!hasPipWindows){
    // Defer to next runloop tick to avoid re-entrancy with window close
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSApplication sharedApplication] terminate:nil];
    });
  }
} // End of windowWillClose:

@end

#pragma mark - Source Names Panel

@interface SourceNamesPanel : NSPanel<NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate>
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSMutableArray* sourceData;
@property (nonatomic, strong) NSMutableArray* textFields;
@property (nonatomic, strong) NSButton* okButton;
- (void)refreshPreferencesWindow;
- (void)loadSourceData;
- (void)completeTabOrder;
@end

@implementation SourceNamesPanel

/**
 * Initializes the source names panel.
 * @return The initialized panel
 */
-(id)init{
  self = [super
          initWithContentRect:NSMakeRect(0, 0, 480, 240)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
          backing:NSBackingStoreBuffered defer:YES
  ];
  self.delegate = self;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
  self.becomesKeyOnlyIfNeeded = NO;
  [self setTitle:@"Source Names"];

  [self loadSourceData];
  _textFields = [[NSMutableArray alloc] init];

  NSView* rootView = [[NSView alloc] init];
  rootView.translatesAutoresizingMaskIntoConstraints = false;

  NSScrollView* scrollView = [[NSScrollView alloc] init];
  scrollView.hasHorizontalScroller = false;
  scrollView.hasVerticalScroller = true;
  scrollView.translatesAutoresizingMaskIntoConstraints = false;
  [rootView addSubview:scrollView];

  _okButton = [NSButton buttonWithTitle:@"OK" target:self action:@selector(onOKClick:)];
  _okButton.translatesAutoresizingMaskIntoConstraints = false;
  _okButton.bezelStyle = NSBezelStyleRounded;
  _okButton.keyEquivalent = @"\r";
  [rootView addSubview:_okButton];

  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeLeft multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeRight multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeTop multiplier:1 constant:0]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:scrollView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:_okButton attribute:NSLayoutAttributeTop multiplier:1 constant:-10]];

  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:_okButton attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeRight multiplier:1 constant:-15]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:_okButton attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:rootView attribute:NSLayoutAttributeBottom multiplier:1 constant:-10]];
  [rootView addConstraint:[NSLayoutConstraint constraintWithItem:_okButton attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:80]];

  _tableView = [[NSTableView alloc] init];
  _tableView.frame = rootView.bounds;
  _tableView.delegate = self;
  _tableView.dataSource = self;
  _tableView.headerView = nil;
  _tableView.intercellSpacing = NSMakeSize(0, 5);
  _tableView.translatesAutoresizingMaskIntoConstraints = NO;
  _tableView.rowHeight = 28;

  NSTableColumn* systemNameCol = [[NSTableColumn alloc] initWithIdentifier:@"systemName"];
  systemNameCol.title = @"Source";
  systemNameCol.width = 220;
  [_tableView addTableColumn:systemNameCol];

  NSTableColumn* customNameCol = [[NSTableColumn alloc] initWithIdentifier:@"customName"];
  customNameCol.title = @"Custom Name";
  customNameCol.width = 240;
  [_tableView addTableColumn:customNameCol];

  scrollView.documentView = _tableView;
  [self setContentView:rootView];

  NSSize windowSize = [self frame].size;
  NSSize screenSize = [[self screen] visibleFrame].size;
  NSPoint point = NSMakePoint(screenSize.width/2 - windowSize.width/2, screenSize.height/2 - windowSize.height/2);
  [self setFrameOrigin:point];

  [_tableView reloadData];
  [self completeTabOrder];

  return self;
} // End of init()

- (void)onOKClick:(NSButton*)sender{
  [self makeFirstResponder:nil];
  [self refreshPreferencesWindow];
  [self close];
} // End of onOKClick()

- (void)refreshPreferencesWindow{
  if(global_pref){
    NSView* contentView = [global_pref contentView];
    for(NSView* subview in contentView.subviews){
      if([subview isKindOfClass:[NSScrollView class]]){
        NSScrollView* scrollView = (NSScrollView*)subview;
        if([scrollView.documentView isKindOfClass:[NSTableView class]]){
          NSTableView* tableView = (NSTableView*)scrollView.documentView;
          [tableView reloadData];
          break;
        }
      }
    } // End of loop through subviews
  }
} // End of refreshPreferencesWindow()

/**
 * Loads source data from connected displays and cameras.
 */
- (void)loadSourceData{
  _sourceData = [[NSMutableArray alloc] init];

  NSMutableArray* displayData = [[NSMutableArray alloc] init];
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] unsignedIntValue];
    NSString* systemName = @"Display";
    if (@available(macOS 10.15, *)) systemName = [screen localizedName];
    NSString* customName = getCustomDisplayNameForId(did);
    if(!customName) customName = @"";

    [displayData addObject:[@{
      @"type": @"display",
      @"id": [NSNumber numberWithUnsignedInt:did],
      @"systemName": [NSString stringWithFormat:@"Display - %@", systemName],
      @"customName": customName,
    } mutableCopy]];
  } // End of loop through screens
  [displayData sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [a[@"systemName"] localizedCaseInsensitiveCompare:b[@"systemName"]];
  }];
  [_sourceData addObjectsFromArray:displayData];

  NSMutableArray* cameraData = [[NSMutableArray alloc] init];
  NSArray<AVCaptureDevice*>* cameras = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for(AVCaptureDevice* camera in cameras){
    NSString* cameraId = [camera uniqueID];
    if(!cameraId || cameraId.length == 0) continue;
    NSString* systemName = [camera localizedName];
    if(!systemName || systemName.length == 0) systemName = @"Camera";
    NSString* customName = getCustomCameraNameForId(cameraId);
    if(!customName) customName = @"";

    [cameraData addObject:[@{
      @"type": @"camera",
      @"id": cameraId,
      @"systemName": [NSString stringWithFormat:@"Camera - %@", systemName],
      @"customName": customName,
    } mutableCopy]];
  } // End of loop through cameras
  [cameraData sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [a[@"systemName"] localizedCaseInsensitiveCompare:b[@"systemName"]];
  }];
  [_sourceData addObjectsFromArray:cameraData];
} // End of loadSourceData()

- (void)completeTabOrder{
  if(_textFields.count == 0) return;

  NSTextField* firstField = nil;
  NSTextField* lastField = nil;

  for(NSUInteger i = 0; i < _textFields.count; i++){
    if(_textFields[i] != [NSNull null]){
      if(!firstField) firstField = _textFields[i];
      lastField = _textFields[i];
    }
  } // End of loop through text fields

  if(firstField && lastField && _okButton){
    [lastField setNextKeyView:_okButton];
    [_okButton setNextKeyView:firstField];
  }
} // End of completeTabOrder()

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView{
  return _sourceData.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row{
  NSTableCellView* cell = [[NSTableCellView alloc] init];
  NSMutableDictionary* source = _sourceData[row];

  if([tableColumn.identifier isEqual:@"systemName"]){
    NSTextField* text = [[NSTextField alloc] init];
    NSString* systemName = source[@"systemName"];
    if(systemName && systemName.length > 0){
      text.stringValue = systemName;
      text.textColor = [NSColor secondaryLabelColor];
    } else {
      text.stringValue = @"(Unknown source)";
      NSFont* currentFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];
      NSFontDescriptor* italicDescriptor = [currentFont.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
      if(italicDescriptor){
        text.font = [NSFont fontWithDescriptor:italicDescriptor size:currentFont.pointSize];
      }
      text.textColor = [NSColor tertiaryLabelColor];
    }
    text.editable = false;
    text.drawsBackground = false;
    text.bordered = false;
    text.translatesAutoresizingMaskIntoConstraints = false;
    [cell addSubview:text];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeLeft multiplier:1 constant:8]];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:text attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeRight multiplier:1 constant:-8]];
  } else if([tableColumn.identifier isEqual:@"customName"]){
    NSTextField* textField = [[NSTextField alloc] init];
    textField.stringValue = source[@"customName"];
    NSString* systemName = source[@"systemName"];
    textField.placeholderString = (systemName && systemName.length > 0) ? systemName : @"Enter source name";
    textField.editable = YES;
    textField.selectable = YES;
    textField.bezeled = YES;
    textField.bezelStyle = NSTextFieldSquareBezel;
    textField.drawsBackground = YES;
    textField.backgroundColor = [NSColor textBackgroundColor];
    textField.translatesAutoresizingMaskIntoConstraints = false;
    textField.delegate = self;
    textField.tag = row;
    textField.cell.scrollable = YES;

    while(_textFields.count <= (NSUInteger)row){
      [_textFields addObject:[NSNull null]];
    }
    _textFields[row] = textField;

    if(row > 0 && _textFields.count > 1 && _textFields[row-1] != [NSNull null]){
      NSTextField* prevField = _textFields[row-1];
      [prevField setNextKeyView:textField];
    }
    if(row == 0 && _textFields.count > 0){
      [self setInitialFirstResponder:textField];
    }

    [cell addSubview:textField];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:textField attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:textField attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeLeft multiplier:1 constant:8]];
    [cell addConstraint:[NSLayoutConstraint constraintWithItem:textField attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:cell attribute:NSLayoutAttributeRight multiplier:1 constant:-8]];
  }

  return cell;
} // End of tableView:viewForTableColumn:row:

- (void)controlTextDidEndEditing:(NSNotification *)notification{
  NSTextField* textField = notification.object;
  NSInteger row = textField.tag;
  if(row >= 0 && row < (NSInteger)_sourceData.count){
    NSMutableDictionary* source = _sourceData[row];
    NSString* newName = textField.stringValue;
    source[@"customName"] = newName;

    NSString* type = source[@"type"];
    if([type isEqualToString:@"display"]){
      CGDirectDisplayID displayId = [source[@"id"] unsignedIntValue];
      setCustomDisplayName(displayId, newName);
    } else if([type isEqualToString:@"camera"]){
      setCustomCameraName(source[@"id"], newName);
    }
  }
} // End of controlTextDidEndEditing()

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector{
  if(commandSelector == @selector(insertBacktab:)){
    NSTextField* currentField = (NSTextField*)control;
    NSInteger currentRow = currentField.tag;
    for(NSInteger i = currentRow - 1; i >= 0; i--){
      if(i < (NSInteger)_textFields.count && _textFields[i] != [NSNull null]){
        NSTextField* prevField = _textFields[i];
        [self makeFirstResponder:prevField];
        return YES;
      }
    } // End of loop searching for previous field
    if(_okButton){
      [self makeFirstResponder:_okButton];
      return YES;
    }
    return YES;
  }
  return NO;
} // End of control:textView:doCommandBySelector:

- (nullable NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row{
  NSTableRowView* rowView = [[NSTableRowView alloc] init];
  rowView.emphasized = false;
  return rowView;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex{
  return NO;
}

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)notification{
  [self refreshPreferencesWindow];
  sourceNamesPanel = nil;
}

@end

void showSourceNamesPanel(void){
  if(!sourceNamesPanel){
    sourceNamesPanel = [[SourceNamesPanel alloc] init];
  }
  [sourceNamesPanel makeKeyAndOrderFront:nil];
} // End of showSourceNamesPanel()

void showDisplayNamesPanel(void){
  showSourceNamesPanel();
} // End of showDisplayNamesPanel()
