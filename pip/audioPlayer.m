//
//  audioPlayer.m
//  PiP
//
//  Created by Amit Verma on 25/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import "audioPlayer.h"
#import <AudioToolbox/AudioToolbox.h>

typedef struct{
  UInt32 mChannels;
  UInt32 mDataSize;
  const void* mData;
  AudioStreamPacketDescription mPacket;
} UserData;

typedef struct{
  uint32_t frame_length;
  uint8_t  compatible_version;
  uint8_t  bit_depth;
  uint8_t  pb;
  uint8_t  mb;
  uint8_t  kb;
  uint8_t  num_channels;
  uint16_t max_run;
  uint32_t max_frame_bytes;
  uint32_t avg_bit_rate;
  uint32_t sample_rate;
} ATTRIBUTE_PACKED alac_specific_config_t;

typedef struct{
  uint32_t atom_size;
  union{
    uint32_t channel_layout_info_id;
    char channel_layout_info_id_str[4];
  };
  union{
    uint32_t type;
    char type_str[4];
  };
} ATTRIBUTE_PACKED format_atom_t;

typedef struct {
  uint32_t info_size;
  union{
    uint32_t id;
    char id_str[4];
  };
  uint32_t version_flag;
  alac_specific_config_t config;
} ATTRIBUTE_PACKED alac_specific_info_t;

typedef struct{
  uint32_t channel_layout_info_size;
  uint32_t channel_layout_info_id;
} ATTRIBUTE_PACKED terminator_atom_t;

typedef struct{
  format_atom_t format_atom;
  alac_specific_info_t info;
  terminator_atom_t terminator_atom;
} ATTRIBUTE_PACKED alac_magic_cookie_t;

@interface AudioPlayer(){
  UInt32 w_idx, r_idx;
  uint8_t pcm_data[128 * 1024];
  UInt32 pcm_data_len;
  AudioUnit outputUnit;
  AudioConverterRef audioConverterRef;
  AudioStreamBasicDescription inFormat, outFormat;
}
@end

#define kNoMoreDataErr -2222

@implementation AudioPlayer
-(id)init{
  self = [super init];
  audioConverterRef = nil;
  inFormat = outFormat = (AudioStreamBasicDescription){0};
  return self;
}

-(void)setInputFormat:(UInt32)format withSampleRate:(UInt32)sampleRate andChannels:(UInt32)channelCount andSPF:(UInt32)spf{
  if(audioConverterRef){
    [self destroy];
  }

  inFormat.mSampleRate        = sampleRate;
  inFormat.mFormatID          = format;
  inFormat.mFramesPerPacket   = spf;
  inFormat.mChannelsPerFrame  = channelCount;

  outFormat.mSampleRate       = inFormat.mSampleRate;
  outFormat.mFormatID         = kAudioFormatLinearPCM;
  outFormat.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  outFormat.mFramesPerPacket  = 1;
  outFormat.mChannelsPerFrame = inFormat.mChannelsPerFrame;
  outFormat.mBitsPerChannel   = 16;//8 * sizeof(AudioSampleType);
  outFormat.mBytesPerFrame    = outFormat.mChannelsPerFrame * (outFormat.mBitsPerChannel / 8);
  outFormat.mBytesPerPacket   = outFormat.mBytesPerFrame / outFormat.mFramesPerPacket;

  pcm_data_len = (sizeof(pcm_data) / (inFormat.mFramesPerPacket * outFormat.mBytesPerPacket)) * (inFormat.mFramesPerPacket * outFormat.mBytesPerPacket);

  NSLog(@"init audio decoder format: %.4s, sampleRate: %u, channels: %u, spf: %u, pcm_data_len: %u", (char*)&format, sampleRate, channelCount, spf, pcm_data_len);

  OSStatus status = AudioConverterNew(&inFormat, &outFormat, &audioConverterRef);
  if(status != noErr){
    NSLog(@"AudioConverterNew status: %d -> %.4s", status, (char*)&status);
    return;
  }

  if(format == kAudioFormatAppleLossless){
    alac_magic_cookie_t magic_cookie = {
      .format_atom = {
        .atom_size = htonl(sizeof(format_atom_t)),
        .channel_layout_info_id_str = "frma",
        .type_str = "alac",
      },
      .info = {
        .info_size = htonl(sizeof(alac_specific_info_t)),
        .id_str = "alac",
        .version_flag = 0x00,
        .config = {
          .frame_length = htonl(inFormat.mFramesPerPacket),
          .compatible_version = 0x00,
          .bit_depth = outFormat.mBitsPerChannel,
          .pb = 0x28, .mb = 0x0a, .kb = 0x0e, // currently unused tuning parameter
          .num_channels = inFormat.mChannelsPerFrame,
          .max_run = htons(0x00ff),
          .max_frame_bytes = 0x00,
          .avg_bit_rate = 0x00,
          .sample_rate = htonl(inFormat.mSampleRate),
        },
      },
      .terminator_atom = {
        .channel_layout_info_size = htonl(sizeof(terminator_atom_t)),
        .channel_layout_info_id = 0,
      },
    };

    AudioChannelLayout channelLayout = {.mChannelLayoutTag = channelCount == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono};
    status = AudioConverterSetProperty(audioConverterRef, kAudioConverterDecompressionMagicCookie, sizeof(magic_cookie), &magic_cookie);
    NSLog(@"AudioConverterSetProperty kAudioConverterDecompressionMagicCookie status: %d", status);
    status = AudioConverterSetProperty(audioConverterRef, kAudioConverterInputChannelLayout, sizeof(channelLayout), &channelLayout);
    NSLog(@"AudioConverterSetProperty kAudioConverterInputChannelLayout status: %d", status);
  }

  w_idx = r_idx = 0;

  AudioComponentDescription outputUnitDescription = {
    .componentType         = kAudioUnitType_Output,
    .componentSubType      = kAudioUnitSubType_DefaultOutput,
    .componentManufacturer = kAudioUnitManufacturer_Apple
  };

  AudioComponent outputComponent = AudioComponentFindNext(NULL, &outputUnitDescription);
  if(outputComponent){
    status = AudioComponentInstanceNew(outputComponent, &outputUnit);
    NSLog(@"AudioComponentInstanceNew: %d", status);
    status = AudioUnitInitialize(outputUnit);
    NSLog(@"AudioUnitInitialize: %d", status);
    status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, sizeof(outFormat));
    NSLog(@"AudioUnitSetProperty: %d", status);
    AURenderCallbackStruct callbackInfo = {
      .inputProc       = AudioRenderCallback,
      .inputProcRefCon = (__bridge void * _Nullable)(self),
    };
    AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callbackInfo, sizeof(callbackInfo));
    AudioOutputUnitStart(outputUnit);
  }
}

-(void)setVolume:(float)volume{
  if(!outputUnit) return;
  OSStatus status = AudioUnitSetParameter(outputUnit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0, volume, 0);
//  NSLog(@"setVolume AudioUnitSetParameter: %d", status);
}

OSStatus AudioConverterCallback(AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription **outDataPacketDescription, void* inUserData){
  UserData* userData = (UserData*)(inUserData);
  if(!userData->mDataSize){
    *ioNumberDataPackets = 0;
    return kNoMoreDataErr;
  }
//  NSLog(@"AudioConverterCallback called ioNumberDataPackets: %u, outDataPacketDescription: %p", *ioNumberDataPackets, outDataPacketDescription);
  if(outDataPacketDescription){
    userData->mPacket.mStartOffset = 0;
    userData->mPacket.mVariableFramesInPacket = 0;
    userData->mPacket.mDataByteSize = userData->mDataSize;
    *outDataPacketDescription = &userData->mPacket;
  }
  *ioNumberDataPackets = ioData->mNumberBuffers = 1;
  ioData->mBuffers[0].mNumberChannels = userData->mChannels;
  ioData->mBuffers[0].mDataByteSize = userData->mDataSize;
  ioData->mBuffers[0].mData = (void*)userData->mData;
  userData->mDataSize = 0;
  return noErr;
}

OSStatus AudioRenderCallback(void * inRefCon, AudioUnitRenderActionFlags * ioActionFlags, const AudioTimeStamp * inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList * ioData){
  AudioPlayer* player = (__bridge AudioPlayer *)(inRefCon);
  for(UInt32 i = 0; i < ioData->mNumberBuffers; ++i){
    AudioBuffer buf = ioData->mBuffers[i];
    memset(buf.mData, 0, buf.mDataByteSize);
  }
  if(player->r_idx == player->w_idx) goto end;
  UInt32 dataAvailable = player->r_idx < player->w_idx ? player->w_idx - player->r_idx : player->pcm_data_len - player->r_idx;
  UInt32 data_required = player->outFormat.mBytesPerFrame * inNumberFrames;

  if(data_required > dataAvailable) data_required = dataAvailable;

  memcpy(ioData->mBuffers[0].mData, player->pcm_data + player->r_idx, data_required);

//  NSLog(@"AudioRenderCallback inNumberFrames: %u, mNumberBuffers: %u, data_required: %u, r_idx: %u", inNumberFrames, ioData->mNumberBuffers, data_required, decoder->r_idx);
  player->r_idx += data_required;
  if(player->r_idx >= player->pcm_data_len) player->r_idx = 0;
end:
  return noErr;
};

-(void)decode:(uint8_t*)data andLength:(size_t)length{
  if(!audioConverterRef) return;
  UInt32 ioOutputDataPacketSize = (pcm_data_len - w_idx)/outFormat.mBytesPerPacket;
  UserData userData = {.mChannels = inFormat.mChannelsPerFrame, .mDataSize = (UInt32)length, .mData = data};
  AudioBufferList decBuffer = {.mNumberBuffers = 1, .mBuffers = {
    {.mNumberChannels = outFormat.mChannelsPerFrame , .mDataByteSize = ioOutputDataPacketSize * outFormat.mBytesPerPacket, .mData = pcm_data + w_idx}
  }};
  OSStatus status = AudioConverterFillComplexBuffer(audioConverterRef, AudioConverterCallback, &userData, &ioOutputDataPacketSize, &decBuffer, NULL);
  if(status == kNoMoreDataErr || status == kAudioCodecNoError){
//    NSLog(@"ioOutputDataPacketSize: %u, w_idx: %u, rem: %u", ioOutputDataPacketSize, w_idx, pcm_data_len - w_idx);
    w_idx += (ioOutputDataPacketSize * outFormat.mBytesPerPacket);
    if(w_idx >= pcm_data_len) w_idx = 0;
  }
  else NSLog(@"AudioConverterFillComplexBuffer status: %d -> %.4s, ioOutputDataPacketSize: %u", status, (char*)&status, ioOutputDataPacketSize);
}
-(void)destroy{
  if(outputUnit){
    AudioOutputUnitStop(outputUnit);
    AudioUnitUninitialize(outputUnit);
    AudioComponentInstanceDispose(outputUnit);
    outputUnit = NULL;
  }
  if(audioConverterRef){
    AudioConverterDispose(audioConverterRef);
    audioConverterRef = NULL;
  }
}
@end
