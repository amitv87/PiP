//
//  ImageView.m
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#import "imageView.h"

@implementation ImageView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  self.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
  return self;
}

- (void)setRenderer:(id<ImageRenderer>)renderer {
  if(_renderer){
    [_renderer renderImage:nil];
    [_renderer.view removeFromSuperview];
  }
  _renderer = renderer;
  if(!_renderer) return;
  [self addSubview:_renderer.view];
  _renderer.view.frame = CGRectIntegral(self.bounds);
  _renderer.view.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable | NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
}

- (void)setImage:(CIImage *)image {
  [self.renderer renderImage:image];
}

@end
