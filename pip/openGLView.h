#ifndef OpenGLView_h
#define OpenGLView_h

#import <Cocoa/Cocoa.h>

void initGL(void);

@protocol RightCLickDelegate <NSObject>
- (void)rightMouseDown:(NSEvent *)theEvent;
@end

@interface OpenGLView : NSOpenGLView{
    GLuint FBOid;
    CGRect imageRect;
    NSInteger scale;
    BOOL setScaleOnce;
    BOOL alreadyCropped;
    GLuint FBOTextureId;
    GLfloat imageAspectRatio;
    id<RightCLickDelegate> rightCLickDelegate;
}
- (id)initWithFrame:(NSRect)frameRect rightCLickDelegate:(id<RightCLickDelegate>) delegate;
- (void) setScale:(NSInteger) scale;
- (void) drawRect: (NSRect) bounds;
- (void) drawImage: (CGImageRef) cgimage withRect:(CGRect) rect;
@end
#endif
