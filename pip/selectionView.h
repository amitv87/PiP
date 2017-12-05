//
//  SelectionView.h
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#ifndef SelectionView_h
#define SelectionView_h

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface SelectionView : NSView{}
@property (nonatomic) CGRect selection;
@property (nonatomic) NSPoint endPoint;
@property (nonatomic) NSPoint startPoint;
@property (nonatomic, strong) CAShapeLayer *shapeLayer;
@end

#endif /* SelectionView_h */
