//
//  openGLRenderer.m
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#import "imageRenderer.h"
#import <OpenGL/gl.h>
#import <CoreImage/CoreImage.h>

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
@property (nonatomic,strong) CIImage *image;
@property (nonatomic,strong) NSOpenGLView *view;
@end

static CIContext* ciContext = nil;
static NSOpenGLContext* openGLContext = nil;

static NSOpenGLContext* getGLContext(){
  if(!openGLContext) openGLContext = [[NSOpenGLContext alloc] initWithFormat:[NSOpenGLView defaultPixelFormat] shareContext:nil];
  return openGLContext;
}

static CIContext* getCIContext(){
  if(!ciContext) ciContext = [CIContext contextWithCGLContext:openGLContext.CGLContextObj pixelFormat:nil colorSpace:nil options:nil];
  return ciContext;
}

@implementation OpenGLRenderer{
  NSRect cropRect;
  float imageScale;
}

@synthesize context;
@synthesize delegate;

- (instancetype)init{
  self = [super init];
  cropRect = CGRectZero;
  GLView *openGLView = [[GLView alloc] initWithFrame:CGRectZero pixelFormat:[NSOpenGLView defaultPixelFormat]];
  openGLView.renderDelegate = self;
  self.view = openGLView;
  self.view.openGLContext = getGLContext();
  self.view.wantsBestResolutionOpenGLSurface = NO;
  self.context = getCIContext();
  return self;
}

- (void)setCropRect:(NSRect) rect{
  if(!self.image) return;
  NSSize frameSize = self.view.frame.size;
  NSSize imageSize = self.image.extent.size;
  float scale = frameSize.width / imageSize.width;
  rect = NSMakeRect(rect.origin.x / scale, rect.origin.y / scale, rect.size.width / scale, rect.size.height / scale);
  cropRect = rect;
}

- (void)openGLView:(GLView *)view drawRect:(CGRect)rect {
  if(!self.image) return;

  NSSize frameSize = self.view.frame.size;
  NSSize targetSize = frameSize;
  NSSize imageSize = cropRect.size.width * cropRect.size.height == 0 ? self.image.extent.size : cropRect.size;

  NSSize availSize = self.view.window.screen.visibleFrame.size;
  float frameAspectRatio = frameSize.width / frameSize.height;
  float imageAspectRatio = imageSize.width / imageSize.height;
  float arr = imageAspectRatio / frameAspectRatio;

  if(imageScale){
    targetSize.width = imageScale * imageSize.width;
    targetSize.height = imageScale * imageSize.height;
    imageScale = 0;
    arr = 2;
  }
  else targetSize.height = targetSize.width / imageAspectRatio;

  if(targetSize.width > availSize.width || targetSize.height > availSize.height){
    arr = 2;
    NSSize size;
    size.width = fmin(availSize.height * imageAspectRatio, availSize.width);
    size.height = fmin(availSize.width / imageAspectRatio, availSize.height);
    targetSize = size;
  }

  if(arr < 0.99 || arr > 1.01) [self.delegate onResize:targetSize andAspectRatio:targetSize];

  NSRect fromRect = cropRect.size.width * cropRect.size.height == 0 ? self.image.extent : cropRect;

  NSRect inRect = CGRectZero;
  inRect.size = targetSize;

  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();

  glViewport(0, 0, targetSize.width, targetSize.height);
  glOrtho(0, targetSize.width, 0, targetSize.height, -1, 1);

  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  [self.context drawImage:self.image inRect:inRect fromRect:fromRect];
  glFlush();
}

- (void)renderImage:(CIImage *)image {
  self.image = image;
  if(self.image) self.view.needsDisplay = YES;
  else{
    imageScale = 0;
    cropRect = CGRectZero;
  }
}

- (void)setScale:(float)scale {
  if(!self.image) return;
  imageScale = scale / 100;
  self.view.needsDisplay = YES;
}

- (NSRect)cropRect{
  return self->cropRect;
}

@end
