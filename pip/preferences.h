//
//  preferences.h
//  PiP
//
//  Created by Amit Verma on 28/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum{
  DisplayRendererTypeMetal,
  DisplayRendererTypeOpenGL,
} DisplayRendererType;

NSObject* getPref(NSString* key);
void setPref(NSString* key, NSObject* val);

@interface Preferences : NSPanel<NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource>

@end

extern Preferences* global_pref;

NS_ASSUME_NONNULL_END
