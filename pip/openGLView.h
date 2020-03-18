#ifndef OpenGLView_h
#define OpenGLView_h

#import <Cocoa/Cocoa.h>

void initGL(void);

@protocol WindowDelegate <NSObject>
- (void)setSize:(CGSize) size andAspectRatio:(CGSize) ar;
@end

@interface OpenGLView : NSOpenGLView{
    GLuint FBOid;
    CGRect imageRect;
    NSInteger scale;
    BOOL setScaleOnce;
    BOOL alreadyCropped;
    GLuint FBOTextureId;
    GLfloat imageAspectRatio;
    id<WindowDelegate> windowDelegate;
}
- (id)initWithFrame:(NSRect)frameRect windowDelegate:(id<WindowDelegate>) delegate;
- (void) setScale:(NSInteger) scale;
- (void) drawRect: (NSRect) bounds;
- (void) drawImage: (CGImageRef) cgimage withRect:(CGRect) rect;
@end
#endif
