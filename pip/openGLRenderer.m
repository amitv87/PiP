//
//  openGLRenderer.m
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#import "imageRenderer.h"

@class GLView;

@protocol OpenGLRenderDelegate <NSObject>
- (void)openGLView:(GLView *)view drawRect:(CGRect)rect;
@end

@interface GLView : NSOpenGLView
@property (nonatomic,weak) id<OpenGLRenderDelegate> renderDelegate;
@end

@implementation GLView
- (void)drawRect:(NSRect)rect {
  [self.renderDelegate openGLView:self drawRect:rect];
}
@end

@interface OpenGLRenderer () <OpenGLRenderDelegate>
@property (nonatomic,strong) NSOpenGLView *view;
@property (nonatomic,strong) CIImage *image;
@end

@implementation OpenGLRenderer

@synthesize context;
@synthesize delegate;

- (instancetype)init{
  self = [super init];
  NSOpenGLContext* openGLContext = [[NSOpenGLContext alloc] initWithFormat:[NSOpenGLView defaultPixelFormat] shareContext:nil];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  self.context = [CIContext contextWithCGLContext:openGLContext.CGLContextObj
                                      pixelFormat:nil
                                       colorSpace:colorSpace
                                          options:@{kCIContextWorkingColorSpace: (__bridge id)colorSpace}];
  CGColorSpaceRelease(colorSpace);
  GLView *openGLView = [[GLView alloc] initWithFrame:CGRectZero pixelFormat:[NSOpenGLView defaultPixelFormat]];
  openGLView.renderDelegate = self;
  self.view = openGLView;
  self.view.openGLContext = openGLContext;
  return self;
}

- (void)openGLView:(GLView *)view drawRect:(CGRect)rect {
  glClearColor(0, 0, 0, 0);
  glClear(GL_COLOR_BUFFER_BIT);
  glViewport(0, 0, view.bounds.size.width, view.bounds.size.height);
  [self.context drawImage:self.image inRect:CGRectMake(-1, -1, 2, 2) fromRect:self.image.extent];
  glFlush();
}

- (void)renderImage:(CIImage *)image {
  self.image = image;
  [self.view setNeedsDisplay:YES];
}

- (void)setScale:(float)scale {

}

- (void)setCropRect:(NSRect)rect {

}

- (NSRect)cropRect {
  return CGRectZero;
}

@end

