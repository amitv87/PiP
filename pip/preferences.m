//
//  preferences.m
//  PiP
//
//  Created by Amit Verma on 28/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import "preferences.h"
#import <QuartzCore/QuartzCore.h>

Preferences* global_pref = nil;

typedef enum{
  OptionTypeNumber,
  OptionTypeSelect,
  OptionTypeCheckBox,
  OptionTypeTextInput,
} OptionType;

#define OPTION(name, text, type, options, value, desc) \
  @{@"name": @#name, @"text": @text, @"type": [NSNumber numberWithInt:OptionType##type], @"options": options, @"value": value, @"desc": desc}

static NSArray* getPrefsArray(void){
  return @[
    OPTION(renderer, "Display Renderer", Select, (@[@"Metal", @"Opengl"]), [NSNumber numberWithInt:DisplayRendererTypeOpenGL], [NSNull null]),
    #ifndef NO_AIRPLAY
    OPTION(airplay, "AirPlay Receiver", CheckBox, [NSNull null], @1, @"Use PiP as Airplay receiver"),
    #endif
    OPTION(wfilter_null_title, "Exclude windows", CheckBox, [NSNull null], @1, @"when title is null"),
    OPTION(wfilter_epmty_title, "Exclude windows", CheckBox, [NSNull null], @1, @"when title is empty"),
    OPTION(wfilter_floating, "Exclude windows", CheckBox, [NSNull null], @1, @"that are floating"),
    OPTION(wfilter_desktop_elemnts, "Exclude windows", CheckBox, [NSNull null], @1, @"that are desktop elements"),
    OPTION(mouse_capture, "Show mouse cursor", CheckBox, [NSNull null], @0, @"when pipping screen"),
  ];
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

@implementation Preferences{
  NSViewController* nvc;
  NSArray* opts;
}

-(id)init{
  self = [super
          initWithContentRect:NSMakeRect(0, 0, 450, 200)
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

- (void)windowDidBecomeKey:(NSNotification *)notification{
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)notification{
  global_pref = nil;
}

@end
