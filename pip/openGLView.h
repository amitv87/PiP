#ifndef OpenGLView_h
#define OpenGLView_h

#import <Cocoa/Cocoa.h>

void initGL(void);

@protocol GLDelegate <NSObject>
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
}
@property (nonatomic) id<GLDelegate> delegate;
- (id)initWithFrame:(NSRect)frameRect;
- (void) setScale:(NSInteger) scale;
- (void) drawRect: (NSRect) bounds;
- (bool) drawImage: (CGImageRef) cgimage withRect:(CGRect) rect;
@end
#endif
