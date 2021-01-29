//
//  cgs.h
//  pip
//
//  Created by Amit Verma on 06/04/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#ifndef cgs_h
#define cgs_h

#include <CoreGraphics/CoreGraphics.h>

#define kCPSAllWindows    0x100
#define kCPSUserGenerated 0x200
#define kCPSNoWindows     0x400

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

CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
CGError CGSGetConnectionPSN(CGSConnectionID cid, ProcessSerialNumber *psn);
CGError CGSGetWindowOwner(CGSConnectionID cid, CGWindowID wid, CGSConnectionID *ownerCid);
CGError CGSConnectionGetPID(CGSConnectionID cid, pid_t *pid, CGSConnectionID ownerCid);
CGError SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, CGWindowID wid, uint32_t mode);

OSStatus CGSGetConnectionIDForPSN(CGSConnectionID cid, ProcessSerialNumber *psn, CGSConnectionID *out);

CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, CGSSpaceMask mask, CFArrayRef windowIDs);
CFArrayRef CGSHWCaptureWindowList(CGSConnectionID, CGWindowID* windowList, int count, CGSWindowCaptureOptions);

#endif /* cgs_h */
