//
//  imageRenderer.h
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#ifndef imageRenderer_h
#define imageRenderer_h

#import <OpenGL/gl.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

@protocol ImageRendererDelegate <NSObject>
- (void)onResize:(CGSize)size andAspectRatio:(CGSize) ar;
@end

@protocol ImageRenderer <NSObject>
@property (nonatomic,strong) CIContext *context;
@property (nonatomic,strong) id<ImageRendererDelegate> delegate;
@property (nonatomic,strong,readonly) NSView *view;
- (instancetype)init;
- (NSRect)cropRect;
- (void)setScale:(float) scale;
- (void)setCropRect:(NSRect) rect;
- (void)renderImage:(CIImage *)image;
@end

@interface MetalRenderer : NSObject <ImageRenderer>
@property (nonatomic,strong,readonly) MTKView *view;
@end

@interface OpenGLRenderer : NSObject <ImageRenderer>
@property (nonatomic,strong,readonly) NSOpenGLView *view;
@end

#endif /* imageRenderer_h */
