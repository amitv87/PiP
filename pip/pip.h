//
//  pip.h
//  pip
//
//  Created by Amit Verma on 04/08/18.
//  Copyright © 2018 boggyb. All rights reserved.
//

#ifndef pip_h
#define pip_h

#import <Cocoa/Cocoa.h>

@class PIPViewController, CAContext, PIPPanel;

@protocol PIPViewControllerDelegate <NSObject>
@optional
- (BOOL)pipShouldClose:(PIPViewController *)pip;
- (void)pipActionStop:(PIPViewController *)pip;
- (void)pipActionPause:(PIPViewController *)pip;
- (void)pipActionPlay:(PIPViewController *)pip;
- (void)pipActionReturn:(PIPViewController *)pip;
- (void)pipDidClose:(PIPViewController *)pip;
- (void)pipWillClose:(PIPViewController *)pip;
@end

@interface PIPViewController : NSViewController
@property (nonatomic) bool playing;
@property (nonatomic) bool userCanResize;
@property (nonatomic) NSSize aspectRatio;
@property (nonatomic) _Bool useAutoLayout;
@property (nonatomic) _Bool presentOnResize;
//@property (nonatomic) struct CGRect bounds;
@property (nonatomic) NSRect replacementRect;
@property (retain, nonatomic) PIPPanel *panel;
@property (retain, nonatomic) CAContext *context;
@property (nonatomic, weak) NSWindow *replacementWindow;
@property (nonatomic, weak) id<PIPViewControllerDelegate> delegate;

- (void)presentViewControllerAsPictureInPicture:(NSViewController *)viewController;

@end

#endif /* pip_h */
