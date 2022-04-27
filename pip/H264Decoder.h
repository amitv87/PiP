//
//  H264Decoder.h
//  PiP
//
//  Created by Amit Verma on 25/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

typedef void (^ReturnDecodedVideoDataBlock) (CVPixelBufferRef pixelBuffer);

@interface H264Decoder : NSObject

@property (nonatomic, copy) ReturnDecodedVideoDataBlock returnDataBlock;
-(void)decode:(uint8_t*)data withLength:(size_t)length andReturnDecodedData:(ReturnDecodedVideoDataBlock)block;
-(void)destroy;
@end
