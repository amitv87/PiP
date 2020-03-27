//
//  SelectionView.m
//  pip
//
//  Created by Amit Verma on 05/12/17.
//  Copyright © 2017 boggyb. All rights reserved.
//

#import "selectionView.h"

@implementation SelectionView

#define NSColorFromRGB(rgbValue) [NSColor colorWithCalibratedRed:((float)((rgbValue & 0xFF000000) >> 16))/255.0 green:((float)((rgbValue & 0xFF0000) >> 8))/255.0 blue:((float)(rgbValue & 0xFF00))/255.0 alpha:((float)(rgbValue & 0xFF))/255.0]

- (void)mouseDown:(NSEvent *)theEvent{
    self.startPoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];

    self.shapeLayer = [CAShapeLayer layer];
    self.shapeLayer.lineWidth = 1.0;
    self.shapeLayer.shadowOpacity = 0.5;

    self.shapeLayer.strokeColor = [[NSColor grayColor] CGColor];
    self.shapeLayer.fillColor = [NSColorFromRGB(0x00000044) CGColor];
    self.shapeLayer.shadowColor = [[NSColor whiteColor] CGColor];
    self.shapeLayer.lineDashPattern = @[@10, @10];
    [self.layer addSublayer:self.shapeLayer];

    CABasicAnimation *dashAnimation;
    dashAnimation = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
    [dashAnimation setFromValue:@0.0f];
    [dashAnimation setToValue:@15.0f];
    [dashAnimation setDuration:0.75f];
    [dashAnimation setRepeatCount:HUGE_VALF];
    [self.shapeLayer addAnimation:dashAnimation forKey:@"linePhase"];
}

- (void)mouseDragged:(NSEvent *)theEvent{
    if(!NSPointInRect([theEvent locationInWindow], [self frame])) return;
    NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
  
    self.endPoint = point;

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, self.startPoint.x, self.startPoint.y);
    CGPathAddLineToPoint(path, NULL, self.startPoint.x, point.y);
    CGPathAddLineToPoint(path, NULL, point.x, point.y);
    CGPathAddLineToPoint(path, NULL, point.x, self.startPoint.y);
    CGPathCloseSubpath(path);

    self.shapeLayer.path = path;
    CGPathRelease(path);
}

- (void)mouseUp:(NSEvent *)theEvent{
    float x = self.startPoint.x < self.endPoint.x ? self.startPoint.x : self.endPoint.x;
    float y = self.startPoint.y < self.endPoint.y ? self.startPoint.y : self.endPoint.y;
    float width = fabs(-self.startPoint.x + self.endPoint.x);
    float height = fabs(-self.startPoint.y + self.endPoint.y);
    
    self.selection = NSMakeRect(x, y, width, height);
    [self.shapeLayer removeFromSuperlayer];
    self.shapeLayer = nil;
    [self.window setMovable:YES];
    [self removeFromSuperview];
    [[NSCursor arrowCursor] set];
}

@end
