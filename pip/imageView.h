//
//  ImageView.h
//  PiP
//
//  Created by Amit Verma on 5/14/20.
//  Copyright © 2020 boggyb. All rights reserved.
//

#ifndef imageView_h
#define imageView_h

#import "imageRenderer.h"

@interface ImageView : NSView
@property (nonatomic,strong) id<ImageRenderer> renderer;
- (void)setImage:(CIImage *)image;
@end

#endif
