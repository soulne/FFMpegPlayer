//
//  VideoPlayer.h
//  FFMpegVideoPlayer
//
//  Created by 默羊 on 2021/7/30.
//

#import <Foundation/Foundation.h>

typedef enum : NSUInteger {
    Stopped = 0,
    Playing,
    Paused
} State;

@class VideoPlayer;

NS_ASSUME_NONNULL_BEGIN

@protocol VideoPlayerProtocol <NSObject>

- (void)stateChange:(State)state player:(VideoPlayer *)player;
- (void)initFinished:(VideoPlayer *)player;

- (void)playFailed:(VideoPlayer *)player;
- (void)frameDecode:(VideoPlayer *)player data:(uint8_t * __nullable)data width:(int)width height:(int)height linesize:(int)linesize;

- (void)timeDidChange:(VideoPlayer *)player;

@end

@interface VideoPlayer : NSObject

@property (nonatomic, weak) id delegate;

- (void)play;
- (void)pause;
- (void)stop;
- (BOOL)isPlaying;
- (void)setVolumn:(int)volumn;

/// 单位微秒 1s=1000ms=1000000μs
- (int)getDuration;

- (int)getCurrentTime;

- (void)setTime:(int)seekTime;

@property (nonatomic, strong) NSString *filename;
@property (nonatomic, assign, readonly) State state;


@end

NS_ASSUME_NONNULL_END
