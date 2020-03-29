#import "openGLView.h"
#import <GLUT/glut.h>
#import <OpenGL/OpenGL.h>
#import <QuartzCore/QuartzCore.h>

#import "common.h"

CIContext *sharedCIcontext = nil;
NSOpenGLPixelFormat *pixelFormat = nil;
NSOpenGLContext* sharedGLContext = nil;

const NSOpenGLPixelFormatAttribute kAttribsAntialised[] = {
    NSOpenGLPFAAccelerated,
    NSOpenGLPFANoRecovery,
    NSOpenGLPFADoubleBuffer,
    NSOpenGLPFAColorSize, 24,
    NSOpenGLPFAAlphaSize, 8,
    NSOpenGLPFAMultisample,
    NSOpenGLPFASampleBuffers, 1,
    NSOpenGLPFASamples, 4,
    0,
};

const NSOpenGLPixelFormatAttribute kAttribsBasic[] = {
    NSOpenGLPFAAccelerated,
    NSOpenGLPFADoubleBuffer,
    NSOpenGLPFAColorSize, 24,
    NSOpenGLPFAAlphaSize, 8,
    0,
};

void initGL(){
    if (nil == pixelFormat) pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:kAttribsAntialised];

    if (nil == pixelFormat) {
        NSLog(@"Couldn't find an FSAA pixel format, trying something more basic");
        pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:kAttribsBasic];
    }

    if(nil == sharedGLContext) sharedGLContext = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];

    if(nil == sharedCIcontext) sharedCIcontext = [CIContext contextWithCGLContext:[sharedGLContext CGLContextObj] pixelFormat:[pixelFormat CGLPixelFormatObj] colorSpace: nil options: nil];
}

@implementation OpenGLView

- (id)initWithFrame:(NSRect)frameRect{
    self = [super initWithFrame:frameRect pixelFormat:pixelFormat];

    int VBL = 1;
    [self setOpenGLContext:sharedGLContext];
    [[self openGLContext] setValues:&VBL forParameter:NSOpenGLCPSwapInterval];
    
    alreadyCropped = false;
    imageRect = CGRectMake(0,0,200,200);
    imageAspectRatio = 0;
    return self;
}

- (void)setFBO{
    if (!FBOid){
        const GLubyte* strExt;
        GLboolean isFBO;
        strExt = glGetString(GL_EXTENSIONS);
        isFBO = gluCheckExtension((const GLubyte*)"GL_EXT_framebuffer_object", strExt);
        if (!isFBO) NSLog(@"Your system does not support framebuffer extension");
        glGenFramebuffersEXT(1, &FBOid);
        glGenTextures(1, &FBOTextureId);
    }

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, FBOid);

    GLint maxTexSize;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
    if (imageRect.size.width > maxTexSize || imageRect.size.height > maxTexSize){
        if (imageAspectRatio > 1){
            imageRect.size.width = maxTexSize;
            imageRect.size.height = maxTexSize / imageAspectRatio;
        }
        else{
            imageRect.size.width = maxTexSize * imageAspectRatio ;
            imageRect.size.height = maxTexSize;
        }
    }

    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, FBOTextureId);

    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA, imageRect.size.width, imageRect.size.height, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);

    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_ARB, FBOTextureId, 0);
 
    if (GL_FRAMEBUFFER_COMPLETE_EXT != glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT)) NSLog(@"Framebuffer Object creation or update failed!");

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
}

- (void)prepareOpenGL{
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
}

- (void) renderScene{
    if(!imageAspectRatio) return;

    NSRect bounds;

    if(setScaleOnce){
        setScaleOnce = false;
        NSRect windowBounds = [[[self window] screen] visibleFrame];
        bounds = NSMakeRect(0, 0, imageRect.size.width * scale / 100, imageRect.size.height * scale / 100);
        if(windowBounds.size.width < bounds.size.width || windowBounds.size.height < bounds.size.height || bounds.size.width < kMinSize || bounds.size.height < kMinSize) goto doNormally;
        [self.delegate setSize:bounds.size andAspectRatio:bounds.size];
    }
    else{
    doNormally:
        bounds = [self bounds];
        float screenAspectRatio = bounds.size.width / bounds.size.height;
        float arr = imageAspectRatio / screenAspectRatio;
        if( 0.99 > arr || arr > 1.01) [self.delegate setSize:NSMakeSize(bounds.size.width, bounds.size.width / imageAspectRatio) andAspectRatio:imageRect.size];
    }

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glViewport(0, 0, bounds.size.width, bounds.size.height);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();

    glMatrixMode(GL_TEXTURE);
    glLoadIdentity();

    glScalef(imageRect.size.width, imageRect.size.height, 1.0f);

    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glDisable(GL_BLEND);

    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, FBOTextureId);
    glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    glPushMatrix();

    glBegin(GL_QUADS);
    glTexCoord2f(0, 0); glVertex2f(-1.0f, -1.0f);
    glTexCoord2f(1, 0); glVertex2f(1.0f, -1.0f);
    glTexCoord2f(1, 1); glVertex2f(1.0f, 1.0f);
    glTexCoord2f(0, 1); glVertex2f(-1.0f, 1.0f);

    glEnd();
    glPopMatrix();
}

-(void) drawRect: (NSRect) bounds{
    [[self openGLContext] makeCurrentContext];
    [self renderScene];
    [[self openGLContext] flushBuffer];
}

-(BOOL) isOpaque{
    return NO;
}

- (bool) drawImage: (CGImageRef) cgimage withRect:(CGRect) rect{
    CIImage* myCIImage = [CIImage imageWithCGImage:cgimage];
    
    CGRect imgRect = [myCIImage extent];
  
    if(imgRect.size.height == 1 && imgRect.size.width == 1) return false;

    if(rect.size.width == 0){
        imageRect = imgRect;
        alreadyCropped = false;
    }
    else if(!alreadyCropped){
        alreadyCropped = true;
        CGRect bounds = [self bounds];
        float scaleImgToWindow = imgRect.size.width / bounds.size.width;
        imageRect = CGRectMake(rect.origin.x * scaleImgToWindow, rect.origin.y * scaleImgToWindow, rect.size.width * scaleImgToWindow, rect.size.height * scaleImgToWindow);
    }
    
    imageAspectRatio = imageRect.size.width / imageRect.size.height;

    [[self openGLContext] makeCurrentContext];

    [self setFBO];

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, FBOid);

    GLint width = (GLint)ceil(imageRect.size.width);
    GLint height = (GLint)ceil(imageRect.size.height);

    glViewport(0, 0, width, height);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, width, 0, height, -1, 1);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    [sharedCIcontext drawImage: myCIImage atPoint: CGPointZero  fromRect: imageRect];

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    
    [self setNeedsDisplay:YES];
  
    return true;
}

- (void) setScale:(NSInteger) _scale{
    scale = _scale;
    setScaleOnce = true;
}

@end
