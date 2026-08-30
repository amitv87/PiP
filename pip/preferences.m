//
//  preferences.m
//  PiP
//
//  Created by Amit Verma on 28/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import "preferences.h"
#import <QuartzCore/QuartzCore.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

Preferences* global_pref = nil;
static NSPanel* displayNamesPanel = nil;

/**
 * Gets the custom display name for a given display ID.
 * @param displayId The CGDirectDisplayID of the display
 * @return The custom name if set, otherwise nil
 */
NSString* getCustomDisplayNameForId(CGDirectDisplayID displayId){
  NSDictionary* customNames = (NSDictionary*)getPref(@"display_custom_names");
  if(!customNames) return nil;
  NSString* key = [NSString stringWithFormat:@"%u", displayId];
  return customNames[key];
} // End of getCustomDisplayNameForId()

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
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] intValue];
    if(did == displayId){
      if (@available(macOS 10.15, *)) return [screen localizedName];
      return [NSString stringWithFormat:@"Display %u", displayId];
    }
  } // End of loop through screens
  return [NSString stringWithFormat:@"Display %u", displayId];
} // End of getDisplayNameForId()

/**
 * Sets a custom display name for a given display ID.
 * @param displayId The CGDirectDisplayID of the display
 * @param name The custom name to set (empty string to clear)
 */
void setCustomDisplayName(CGDirectDisplayID displayId, NSString* name){
  NSDictionary* existingNames = (NSDictionary*)[[NSUserDefaults standardUserDefaults] objectForKey:@"display_custom_names"];
  NSMutableDictionary* customNames = existingNames ? [existingNames mutableCopy] : [[NSMutableDictionary alloc] init];
  NSString* key = [NSString stringWithFormat:@"%u", displayId];

  if(name && name.length > 0){
    customNames[key] = name;
  } else {
    [customNames removeObjectForKey:key];
  }

  [[NSUserDefaults standardUserDefaults] setObject:customNames forKey:@"display_custom_names"];
} // End of setCustomDisplayName()

/**
 * Gets the list of available displays with their names (using custom names if set).
 * @return An array of dictionaries with "name" and "id" keys
 */
NSArray* getDisplayList(void){
  NSMutableArray* displays = [[NSMutableArray alloc] init];
  [displays addObject:@{@"name": @"Ninguno", @"id": @-1}];
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] intValue];
    NSString* name = getDisplayNameForId(did);
    [displays addObject:@{@"name": name, @"id": [NSNumber numberWithUnsignedInt:did]}];
  } // End of loop through screens
  return displays;
} // End of getDisplayList()

typedef enum{
  OptionTypeNumber,
  OptionTypeSelect,
  OptionTypeCheckBox,
  OptionTypeTextInput,
  OptionTypeDisplaySelect,
  OptionTypeButton,
} OptionType;

#define OPTION(name, text, type, options, value, desc) \
  @{@"name": @#name, @"text": @text, @"type": [NSNumber numberWithInt:OptionType##type], @"options": options, @"value": value, @"desc": desc}

static NSArray* getPrefsArray(void){
  NSMutableArray* prefs = [NSMutableArray arrayWithArray:@[
    OPTION(hidpi, "Use HiDPI mode", CheckBox, [NSNull null], @1, @"on supported displays"),
    OPTION(renderer, "Display Renderer", Select, (@[@"Metal", @"Opengl"]), [NSNumber numberWithInt:DisplayRendererTypeOpenGL], [NSNull null]),
    OPTION(default_display, "Default Display", DisplaySelect, [NSNull null], @-1, [NSNull null]),
    OPTION(display_names, "Display Names", Button, [NSNull null], [NSNull null], @"Configure..."),
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
          initWithContentRect:NSMakeRect(0, 0, 450, 230)
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

- (void)onDisplaySelect:(NSMenuItem*)sender{
  NSNumber* displayId = [sender representedObject];
//  NSLog(@"onDisplaySelect: %@ -> %@", sender.identifier, displayId);
  setPref(sender.identifier, displayId);
}

- (void)onButtonClick:(NSButton*)sender{
  if([sender.identifier isEqual:@"display_names"]){
    showDisplayNamesPanel();
  }
} // End of onButtonClick()

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
      case OptionTypeTextInput:
        break;
      case OptionTypeDisplaySelect:{
        NSPopUpButton* button = [[NSPopUpButton alloc] init];
        button.translatesAutoresizingMaskIntoConstraints = false;
        button.menu = [[NSMenu alloc] init];

        NSArray* displays = getDisplayList();
        int savedDisplayId = [(NSNumber*)value intValue];
        int selectedIndex = 0;
        for(int i = 0; i < displays.count; i++){
          NSDictionary* display = displays[i];
          NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:display[@"name"] action:@selector(onDisplaySelect:) keyEquivalent:@""];
          item.target = self;
          item.identifier = key;
          item.representedObject = display[@"id"];
          [button.menu addItem:item];
          if([display[@"id"] intValue] == savedDisplayId) selectedIndex = i;
        } // End of loop through displays
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
  // Add 12pt padding below Display Renderer, Default Display, and Display Names rows
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
}

@end

#pragma mark - Display Names Panel

@interface DisplayNamesPanel : NSPanel<NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate>
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSMutableArray* displayData;
@property (nonatomic, strong) NSMutableArray* textFields;
@property (nonatomic, strong) NSButton* okButton;
- (void)refreshPreferencesWindow;
- (void)completeTabOrder;
@end

@implementation DisplayNamesPanel

/**
 * Initializes the display names panel.
 * @return The initialized panel
 */
-(id)init{
  self = [super
          initWithContentRect:NSMakeRect(0, 0, 450, 200)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
          backing:NSBackingStoreBuffered defer:YES
  ];
  self.delegate = self;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
  self.becomesKeyOnlyIfNeeded = NO;
  [self setTitle:@"Display Names"];

  [self loadDisplayData];
  _textFields = [[NSMutableArray alloc] init];

  NSView* rootView = [[NSView alloc] init];
  rootView.translatesAutoresizingMaskIntoConstraints = false;

  // Create scroll view for table
  NSScrollView* scrollView = [[NSScrollView alloc] init];
  scrollView.hasHorizontalScroller = false;
  scrollView.hasVerticalScroller = true;
  scrollView.translatesAutoresizingMaskIntoConstraints = false;
  [rootView addSubview:scrollView];

  // Create OK button
  _okButton = [NSButton buttonWithTitle:@"OK" target:self action:@selector(onOKClick:)];
  _okButton.translatesAutoresizingMaskIntoConstraints = false;
  _okButton.bezelStyle = NSBezelStyleRounded;
  _okButton.keyEquivalent = @"\r"; // Enter key
  [rootView addSubview:_okButton];

  // Layout constraints
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
  systemNameCol.title = @"System Name";
  systemNameCol.width = 150;
  [_tableView addTableColumn:systemNameCol];

  NSTableColumn* customNameCol = [[NSTableColumn alloc] initWithIdentifier:@"customName"];
  customNameCol.title = @"Custom Name";
  customNameCol.width = 250;
  [_tableView addTableColumn:customNameCol];

  scrollView.documentView = _tableView;
  [self setContentView:rootView];

  NSSize windowSize = [self frame].size;
  NSSize screenSize = [[self screen] visibleFrame].size;
  NSPoint point = NSMakePoint(screenSize.width/2 - windowSize.width/2, screenSize.height/2 - windowSize.height/2);
  [self setFrameOrigin:point];

  // Complete tab order after table is set up
  [_tableView reloadData];
  [self completeTabOrder];

  return self;
} // End of init()

/**
 * Called when OK button is clicked. Commits pending edits and closes the panel.
 * @param sender The button that was clicked
 */
- (void)onOKClick:(NSButton*)sender{
  // Commit any pending text field edits by resigning first responder
  [self makeFirstResponder:nil];

  // Update preferences window immediately
  [self refreshPreferencesWindow];

  [self close];
} // End of onOKClick()

/**
 * Refreshes the preferences window to show updated display names.
 */
- (void)refreshPreferencesWindow{
  if(global_pref){
    // Find the table view in the preferences window and reload it
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
 * Loads display data from connected screens.
 */
- (void)loadDisplayData{
  _displayData = [[NSMutableArray alloc] init];
  for(NSScreen* screen in [NSScreen screens]){
    NSDictionary* dict = [screen deviceDescription];
    CGDirectDisplayID did = [dict[@"NSScreenNumber"] intValue];
    NSString* systemName = @"Display";
    if (@available(macOS 10.15, *)) systemName = [screen localizedName];
    NSString* customName = getCustomDisplayNameForId(did);
    if(!customName) customName = @"";

    [_displayData addObject:[@{
      @"id": [NSNumber numberWithUnsignedInt:did],
      @"systemName": systemName,
      @"customName": customName
    } mutableCopy]];
  } // End of loop through screens
} // End of loadDisplayData()

/**
 * Completes the circular tab order for keyboard navigation.
 * Chain: first text field -> ... -> last text field -> OK button -> first text field
 */
- (void)completeTabOrder{
  if(_textFields.count == 0) return;

  // Find first and last valid text fields
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
  return _displayData.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row{
  NSTableCellView* cell = [[NSTableCellView alloc] init];
  NSMutableDictionary* display = _displayData[row];

  if([tableColumn.identifier isEqual:@"systemName"]){
    NSTextField* text = [[NSTextField alloc] init];
    NSString* systemName = display[@"systemName"];
    if(systemName && systemName.length > 0){
      text.stringValue = systemName;
      text.textColor = [NSColor secondaryLabelColor];
    } else {
      text.stringValue = @"(Unknown display)";
      // Use italic font for placeholder
      NSFont* currentFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];
      NSFontDescriptor* italicDescriptor = [currentFont.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
      if(italicDescriptor){
        text.font = [NSFont fontWithDescriptor:italicDescriptor size:currentFont.pointSize];
      }
      text.textColor = [NSColor tertiaryLabelColor]; // More muted than secondaryLabelColor
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
    textField.stringValue = display[@"customName"];
    NSString* systemName = display[@"systemName"];
    textField.placeholderString = (systemName && systemName.length > 0) ? systemName : @"Enter display name";
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

    // Add to text fields array for tab navigation
    while(_textFields.count <= (NSUInteger)row){
      [_textFields addObject:[NSNull null]];
    }
    _textFields[row] = textField;

    // Set up tab order
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
  if(row >= 0 && row < (NSInteger)_displayData.count){
    NSMutableDictionary* display = _displayData[row];
    NSString* newName = textField.stringValue;
    display[@"customName"] = newName;
    CGDirectDisplayID displayId = [display[@"id"] unsignedIntValue];
    setCustomDisplayName(displayId, newName);
  }
} // End of controlTextDidEndEditing()

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
  displayNamesPanel = nil;
}

@end

/**
 * Shows the display names configuration panel.
 */
void showDisplayNamesPanel(void){
  if(!displayNamesPanel){
    displayNamesPanel = [[DisplayNamesPanel alloc] init];
  }
  [displayNamesPanel makeKeyAndOrderFront:nil];
} // End of showDisplayNamesPanel()
