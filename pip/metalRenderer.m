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

- (instancetype)init{
  self = [super init];
  self.image = nil;
  self.device = MTLCreateSystemDefaultDevice();
  self.view = [[MTKView alloc] initWithFrame:CGRectZero device:self.device];
  self.view.clearColor = MTLClearColorMake(0, 0, 0, 0);
  self.view.delegate = self;
  self.view.framebufferOnly = NO;
  self.view.autoResizeDrawable = YES;
  self.view.enableSetNeedsDisplay = YES;
  colorspace = CGColorSpaceCreateDeviceRGB();
  self.context = [CIContext contextWithMTLDevice:self.device options:@{kCIContextWorkingColorSpace: (__bridge id)colorspace}];
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
  NSSize frameSize = self.view.frame.size;
  NSSize imageSize = self.image.extent.size;
  float scale = frameSize.width / imageSize.width;

  if(rect.size.width * rect.size.height <= 1) return;
  rect = NSMakeRect(rect.origin.x / scale, rect.origin.y / scale, rect.size.width / scale, rect.size.height / scale);
  if(rect.size.width * rect.size.height <= 1) return;
  cropRect = rect;
}

- (void)drawInMTKView:(MTKView *)view {
  if(!self.image) return;
  id<MTLTexture> outputTexture = self.view.currentDrawable.texture;
  if (!outputTexture) return;

  CIImage* image = self.image;

  if(cropRect.size.width * cropRect.size.height != 0) image = [image imageByCroppingToRect:cropRect];

  NSSize frameSize = self.view.frame.size;
  NSSize imageSize = image.extent.size;

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

  if(arr < 0.999 || arr > 1.001) [self.delegate onResize:targetSize andAspectRatio:targetSize];

  float scale = targetSize.width / imageSize.width;
  image = (scale < 0.99 || scale > 1.01) ? [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)] : image;

  self.view.drawableSize = targetSize;
  id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
  [self.context render:image toMTLTexture:outputTexture commandBuffer:commandBuffer bounds:image.extent colorSpace:colorspace];
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
