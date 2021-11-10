//
//  VideoPlayer+VideoPlayer_Video.m
//  FFMpegVideoPlayer
//
//  Created by HFY on 2021/8/2.
//

#import "VideoPlayer.h"

@implementation VideoPlayer (VideoPlayer_Video)

- (int)initVideoInfo {
    // 初始化解码器
    int ret = [self initDecoder:&_vDecodeCtx stream:&_vStream type:AVMEDIA_TYPE_VIDEO];
    RET(initDecoder);

    return 0;
}


@end
