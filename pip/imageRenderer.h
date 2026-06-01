//
//  imageRenderer.h
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#ifndef imageRenderer_h
#define imageRenderer_h

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

id<MTLDevice> getSharedMTLDevice(void);

@protocol ImageRendererDelegate <NSObject>
- (void)onResize:(CGSize)size andAspectRatio:(CGSize) ar;
@end

@protocol ImageRenderer <NSObject>
@property (nonatomic,strong) CIContext *context;
@property (nonatomic,strong,readonly) NSView *view;
@property (nonatomic,strong) id<ImageRendererDelegate> delegate;
- (instancetype)init:(BOOL)hidpi;
- (NSRect)cropRect;
- (void)setScale:(float) scale;
- (void)setCropRect:(NSRect) rect;
- (void)renderImage:(CIImage *)image;
- (CIImage *)currentImage;
@end

@interface MetalRenderer : NSObject <ImageRenderer>
//@property (nonatomic,strong,readonly) MTKView *view;
@end

@interface OpenGLRenderer : NSObject <ImageRenderer>
//@property (nonatomic,strong,readonly) NSOpenGLView *view;
@end

#endif /* imageRenderer_h */
