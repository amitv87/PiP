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

@class PIPViewController;

@protocol PIPViewControllerDelegate <NSObject>

@optional
- (void)pipActionStop:(PIPViewController *)pip;
- (void)pipActionPause:(PIPViewController *)pip;
- (void)pipActionPlay:(PIPViewController *)pip;
- (void)pipActionReturn:(PIPViewController *)pip;
- (void)pipDidClose:(PIPViewController *)pip;
- (void)pipWillClose:(PIPViewController *)pip;
@end

@interface PIPViewController : NSViewController

@property (nonatomic, weak) id <PIPViewControllerDelegate> delegate;
@property (nonatomic, assign) NSRect replacementRect;
@property (nonatomic, weak) NSWindow *replacementWindow;
@property (nonatomic, weak) NSView *replacementView;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSSize aspectRatio;

- (void)presentViewControllerAsPictureInPicture:(__kindof NSViewController *)controller;
- (void)performWindowDragWithEvent:(id)arg1;
- (void)setPlaying:(BOOL)playing;
- (BOOL)playing;

- (instancetype)init;

@end

#endif /* pip_h */
