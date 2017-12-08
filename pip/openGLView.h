#ifndef OpenGLView_h
#define OpenGLView_h

#import <Cocoa/Cocoa.h>

@protocol RightCLickDelegate <NSObject>
- (void)rightMouseDown:(NSEvent *)theEvent;
@end

@interface OpenGLView : NSOpenGLView{
    GLuint FBOid;
    CGRect imageRect;
    BOOL set1x;
    BOOL alreadyCropped;
    GLuint FBOTextureId;
    CIContext *myCIcontext;
    GLfloat imageAspectRatio;
    NSOpenGLPixelFormat *pixelFormat;
    id<RightCLickDelegate> rightCLickDelegate;
}
- (id)initWithFrame:(NSRect)frameRect rightCLickDelegate:(id<RightCLickDelegate>) delegate;
- (void) resizeTo1x;
- (void) drawRect: (NSRect) bounds;
- (void) drawImage: (CGImageRef) cgimage withRect:(CGRect) rect;
@end
#endif
