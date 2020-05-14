//
//  cgs.h
//  pip
//
//  Created by Amit Verma on 06/04/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#ifndef cgs_h
#define cgs_h

#include <CoreGraphics/CGWindow.h>

typedef int CGSConnectionID;

typedef enum {
  kCGSWindowCaptureNominalResolution = (1 << 9),
  kCGSCaptureIgnoreGlobalClipShape   = (1 << 11),
} CGSWindowCaptureOptions;

typedef enum {
  CGSSpaceIncludesCurrent  = 1 << 0,
  CGSSpaceIncludesOthers   = 1 << 1,
  CGSSpaceIncludesUser     = 1 << 2,
  CGSSpaceVisible          = 1 << 16,
  kCGSCurrentSpaceMask     = CGSSpaceIncludesUser | CGSSpaceIncludesCurrent,
  kCGSOtherSpacesMask      = CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent,
  kCGSAllSpacesMask        = CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent,
  KCGSAllVisibleSpacesMask = CGSSpaceVisible | kCGSAllSpacesMask,
} CGSSpaceMask;

CGSConnectionID CGSMainConnectionID(void);
CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, CGSSpaceMask mask, CFArrayRef windowIDs);
CFArrayRef CGSHWCaptureWindowList(CGSConnectionID, CGWindowID* windowList, int count, CGSWindowCaptureOptions);

#endif /* cgs_h */
