//
//  metalRenderer.m
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#import "common.h"
#import "imageRenderer.h"

#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

@interface MetalRenderer () <MTKViewDelegate>
@property (nonatomic,strong) MTKView *view;
@property (nonatomic,strong) CIImage *image;
@property (nonatomic,strong) id<MTLDevice> device;
@property (nonatomic,strong) id<MTLCommandQueue> commandQueue;
@end

@implementation MetalRenderer{
  NSRect cropRect;
  float imageScale;
  CGColorSpaceRef colorspace;
}

@synthesize context;
@synthesize delegate;

- (instancetype)init:(BOOL)hidpi{
  self = [super init];
  self.image = nil;
  self.device = MTLCreateSystemDefaultDevice();
  self.view = [[MTKView alloc] initWithFrame:CGRectZero device:self.device];
  self.view.clearColor = MTLClearColorMake(0, 0, 0, 0);
  self.view.delegate = self;
  self.view.framebufferOnly = NO;
  self.view.autoResizeDrawable = true;
  self.view.enableSetNeedsDisplay = YES;
  self.view.wantsBestResolutionOpenGLSurface = hidpi;
  colorspace = CGColorSpaceCreateDeviceRGB();
  self.context = [CIContext contextWithMTLDevice:self.device options:@{kCIContextWorkingColorSpace: (__bridge id)colorspace,}];
  self.commandQueue = [self.device newCommandQueue];

  imageScale = 0;
  cropRect = CGRectZero;
  return self;
}

- (void)dealloc{
  CGColorSpaceRelease(colorspace);
}

- (void)setCropRect:(NSRect) rect{
  if(!self.image) return;
  float scale = self.image.extent.size.width / self.view.frame.size.width;
  cropRect = CGRectApplyAffineTransform(rect, CGAffineTransformMakeScale(scale, scale));
}

- (void)drawInMTKView:(MTKView *)view {
  if(!self.image) return;
  id<MTLTexture> outputTexture = self.view.currentDrawable.texture;
  if (!outputTexture) return;

  CIImage* image = self.image;

  NSRect bounds = {.size = image.extent.size};
  NSSize frameSize = self.view.frame.size;
  float hidpi_scale = self.view.wantsBestResolutionOpenGLSurface ? self.view.window.backingScaleFactor : 1;

  if(cropRect.size.width * cropRect.size.height != 0) bounds = cropRect;
  bounds = CGRectApplyAffineTransform(bounds, CGAffineTransformMakeScale(1.0/hidpi_scale, 1.0/hidpi_scale));

  NSSize imageSize = bounds.size;

  NSSize availSize = self.view.window.screen.visibleFrame.size;
  float frameAspectRatio = frameSize.width / frameSize.height;
  float imageAspectRatio = imageSize.width / imageSize.height;
  float arr = imageAspectRatio / frameAspectRatio;

  NSSize targetSize = frameSize;
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

  float scale = targetSize.width / (imageSize.width / hidpi_scale);

  self.view.drawableSize = CGSizeApplyAffineTransform(bounds.size, CGAffineTransformMakeScale(hidpi_scale, hidpi_scale));
  bounds = CGRectApplyAffineTransform(bounds, CGAffineTransformMakeScale(scale, scale));

  // if(targetSize.width < imageSize.width){
    scale /= hidpi_scale;
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    self.view.drawableSize = bounds.size;
  // }

  id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
  [self.context render:image toMTLTexture:outputTexture commandBuffer:commandBuffer bounds:bounds colorSpace:colorspace];
  [commandBuffer presentDrawable:self.view.currentDrawable];
  [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

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
