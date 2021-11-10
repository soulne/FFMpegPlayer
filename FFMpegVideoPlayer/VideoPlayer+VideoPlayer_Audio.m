//
//  VideoPlayer+VideoPlayer_Audio.m
//  FFMpegVideoPlayer
//
//  Created by HFY on 2021/8/2.
//

#import "VideoPlayer.h"

@implementation VideoPlayer (VideoPlayer_Audio)

- (int)initAudioInfo {
    // 初始化解码器
    int ret = [self initDecoder:&_aDecodeCtx stream:&_aStream type:AVMEDIA_TYPE_AUDIO];
    RET(initDecoder);

    return 0;
}

@end
