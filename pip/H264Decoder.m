//
//  H264Decoder.m
//  PiP
//
//  Created by Amit Verma on 25/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import "H264Decoder.h"

@interface H264Decoder(){
  uint8_t *mSPS, *mPPS;
  long mSPSSize, mPPSSize;
  VTDecompressionSessionRef   mDecodeSession;
  CMFormatDescriptionRef      mFormatDescription;
  bool should_reset;
}
@end

@implementation H264Decoder
- (instancetype)init {
  self = [super init];
  should_reset = false;
  return self;
}

void didDecompress(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration){
  if(status != noErr) NSLog(@"didDecompress failed with code: %d", status);
  CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
  *outputPixelBuffer = CVPixelBufferRetain(pixelBuffer);
}

-(void)decode:(uint8_t*)data withLength:(size_t)length andReturnDecodedData:(ReturnDecodedVideoDataBlock)block{
  self.returnDataBlock = block;
  uint32_t nalSize = (uint32_t)(length - 4);
  uint32_t *pNalSize = (uint32_t *)data;
  *pNalSize = CFSwapInt32HostToBig(nalSize);

  CVPixelBufferRef pixelBuffer = NULL;
  int nalType = data[4] & 0x1F;
  switch (nalType){
    case 0x07:
      should_reset = true;
      if(mSPS) free(mSPS);
      mSPSSize = length - 4;
      mSPS = malloc(mSPSSize);
      memcpy(mSPS, data + 4, mSPSSize);
      break;
    case 0x08:
      if(mPPS) free(mPPS);
      mPPSSize = length - 4;
      mPPS = malloc(mPPSSize);
      memcpy(mPPS, data + 4, mPPSSize);
      break;
    case 0x05:
      if(should_reset && mDecodeSession){
        VTDecompressionSessionInvalidate(mDecodeSession);
        CFRelease(mDecodeSession);
        mDecodeSession = NULL;
      }
      should_reset = false;
      [self initVideoToolBox];
    default:{
      CMBlockBufferRef blockBuffer = NULL;
      OSStatus status  = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, data, length, kCFAllocatorNull, NULL, 0, length, 0, &blockBuffer);
      if(status == kCMBlockBufferNoErr) {
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = {length};
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, mFormatDescription, 1, 0, NULL, 1, sampleSizeArray, &sampleBuffer);
        if(status == kCMBlockBufferNoErr && sampleBuffer) {
          OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(mDecodeSession, sampleBuffer, 0, &pixelBuffer, NULL);
          if(decodeStatus != noErr) NSLog(@"decode failed status=%d", decodeStatus);
          CFRelease(sampleBuffer);
        }
        CFRelease(blockBuffer);
      }
      break;
    }
  }
  if(!pixelBuffer) return;
  self.returnDataBlock(pixelBuffer);
  CVPixelBufferRelease(pixelBuffer);
}

-(void)initVideoToolBox{
  if(mDecodeSession) return;
  const uint8_t* parameterSetPointers[2] = {mSPS, mPPS};
  const size_t parameterSetSizes[2] = {mSPSSize, mPPSSize};
  OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &mFormatDescription);
  if(status != noErr){
    NSLog(@"CMVideoFormatDescriptionCreateFromH264ParameterSets failed with code: %d", status);
    return;
  }
  VTDecompressionOutputCallbackRecord callBackRecord;
  callBackRecord.decompressionOutputCallback = didDecompress;
  callBackRecord.decompressionOutputRefCon = NULL;

  status = VTDecompressionSessionCreate(kCFAllocatorDefault, mFormatDescription, NULL, NULL, &callBackRecord, &mDecodeSession);
  if(status != noErr){//kVTVideoDecoderBadDataErr
    NSLog(@"VTDecompressionSessionCreate failed with code: %d", status);
  }
}

-(void)destroy{
  if(mDecodeSession) {
    VTDecompressionSessionInvalidate(mDecodeSession);
    CFRelease(mDecodeSession);
    mDecodeSession = NULL;
  }

  if(mFormatDescription) {
    CFRelease(mFormatDescription);
    mFormatDescription = NULL;
  }

  if(mSPS) free(mSPS);
  if(mPPS) free(mPPS);
  mSPS = mPPS = NULL;
  mSPSSize = mPPSSize = 0;
}

@end


