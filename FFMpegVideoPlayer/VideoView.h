//
//  VideoView.h
//  FFMpegVideoPlayer
//
//  Created by 默羊 on 2021/7/30.
//

#import <Cocoa/Cocoa.h>
#import "VideoPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface VideoView : NSView

- (void)frameDecode:(VideoPlayer *)player data:(uint8_t *)data width:(int)width height:(int)height linesize:(int)linesize;

@end

NS_ASSUME_NONNULL_END
