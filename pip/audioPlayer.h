//
//  audioPlayer.h
//  PiP
//
//  Created by Amit Verma on 25/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer : NSObject
-(void)setInputFormat:(UInt32)format withSampleRate:(UInt32)sampleRate andChannels:(UInt32)channelCount andSPF:(UInt32)spf;
-(void)setVolume:(float)volume;
-(void)decode:(uint8_t*)data andLength:(size_t)length;
-(void)destroy;
@end

NS_ASSUME_NONNULL_END
