//
//  VideoPlayer.m
//  FFMpegVideoPlayer
//
//  Created by 默羊 on 2021/7/30.
//

#import "VideoPlayer.h"
#include <stdio.h>
#include <list>
extern"C" {
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avutil.h"
#include "SDL.h"
#include "libswresample/swresample.h"
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
}

typedef void(^VoidBlock)(void *, Uint8 *, int);

typedef struct {
    const char *filename;
    int sampleRate;
    AVSampleFormat sampleFmt;
    int64_t chLayout;
    int chs;
    int bytesPerSampleFrame;
} AudioEncodeSpec;

typedef struct {
    int width;
    int height;
    AVPixelFormat pixFmt;
    int size;
} VideoSwsSpec;

#define AUDIO_MAX_PKT_SIZE 1000
#define VIDEO_MAX_PKT_SIZE 500

#define ERROR_BUF \
    char errbuf[1024]; \
    av_strerror(ret, errbuf, sizeof (errbuf));

#define END(func) \
    if (ret < 0) { \
        ERROR_BUF; \
        NSLog(@"%@ error %s", func, errbuf); \
        [self fataError]; \
        return; \
    }

#define RET(func) \
    if (ret < 0) { \
        ERROR_BUF; \
        NSLog(@"%@ error %s", func, errbuf); \
        return ret; \
    }

@interface VideoPlayer () {
    /** 解封装上下文 */
    AVFormatContext *_fmtCtx;
    BOOL _fCanFree;
    int _seekTime;

    /** 音频相关 */
    AVCodecContext *_aDecodeCtx;
    AVStream *_aStream;
    std::list<AVPacket> _aPktList;
    SwrContext *_aSwrCtx;
    AudioEncodeSpec _aSwrInSpec, _aSwrOutSpec;
    AVFrame *_aSwrInFrame;
    AVFrame *_aSwrOutFrame;
    int _aSwrOutIdx;
    /// 重采样之后输出的pcm的大小
    int _aSwrOutSize;
    int _volumn;
    /// 音频时钟
    double _aTime;
    BOOL _aCanFree;
    BOOL _hasAudio;
    int _aSeekTime;

    /** 视频相关 */
    AVCodecContext *_vDecodeCtx;
    AVStream *_vStream;
    AVFrame *_vSwsInFrame;
    AVFrame *_vSwsOutFrame;
    SwsContext *_vSwsCtx;
    std::list<AVPacket> _vPktList;
    VideoSwsSpec _vSwsOutSpec;
    double _vTime;
    int _vSeekTime;
    BOOL _vCanFree;
    BOOL _hasVideo;
}

@property (nonatomic, strong) NSCondition *audioCondition;
@property (nonatomic, strong) NSCondition *videoCondition;
@property (nonatomic, assign, readwrite) State state;

@end

@implementation VideoPlayer

- (instancetype)init {
    self = [super init];
    if (self) {
        if (SDL_Init(SDL_INIT_AUDIO)) {
            NSLog(@"SDK_Init error:%s", SDL_GetError());
            if ([self.delegate respondsToSelector:@selector(playFailed:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate playFailed:self];
                });
            }
        }
        self.audioCondition = [[NSCondition alloc] init];
        self.videoCondition = [[NSCondition alloc] init];
        _seekTime = -1;
        _aSeekTime = -1;
        _vSeekTime = -1;
    }
    return self;
}

#pragma mark -- 公共函数

- (void)play {
    if (_state == Playing) return;
    NSLog(@"%@", [NSThread currentThread]);
    if (self.state == Stopped) {
        __weak typeof(self) wSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [wSelf readFile];
        });
    } else {
        self.state = Playing;
    }
}

- (void)stop {
    if (_state == Stopped) return;
    self.state = Stopped;

    [self free];

    if ([self.delegate respondsToSelector:@selector(frameDecode:data:width:height:linesize:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate frameDecode:self data:NULL width:0 height:0 linesize:0];
        });
    }
}

- (void)pause {
    self.state = Paused;
}

- (BOOL)isPlaying {
    return _state == Playing;
}


- (void)setState:(State)state {
    if (state == _state) return;
    if (state == Stopped) {
        
    }
    _state = state;
    if ([self.delegate respondsToSelector:@selector(stateChange:player:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate stateChange:self->_state player:self];
        });
    }
}

- (int)getDuration {

    return _fmtCtx ? (int)(round((long long)_fmtCtx->duration * av_q2d(AV_TIME_BASE_Q))) : 0;
}

- (int)getCurrentTime {
    return round(_aTime);
}

- (void)setTime:(int)seekTime {
    _seekTime = seekTime;
}

#pragma mark -- 解封装

- (void)readFile {

    // 返回结果
    int ret = 0;

    // 创建解封装上下文、打开文件
    ret = avformat_open_input(&_fmtCtx, [self.filename UTF8String], nullptr, nullptr);
    END(@"avformat_open_input");

    // 检索流信息
    ret = avformat_find_stream_info(_fmtCtx, nullptr);
    END(@"avformat_find_stream_info");

    // 打印流信息到控制台
    av_dump_format(_fmtCtx, 0, [self.filename UTF8String], 0);
    fflush(stderr);

    // 初始化音频信息
    _hasAudio = ![self initAudioInfo];
    // 初始化视频信息
    _hasVideo = ![self initVideoInfo];

    if (!_hasAudio && !_hasVideo) {
        [self fataError];
        return;
    }

    // 初始化完毕
    if ([self.delegate respondsToSelector:@selector(initFinished:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate initFinished:self];
        });
    }

    self.state = Playing;

    // 开始播放
    SDL_PauseAudio(0);

    // 开始解码视频数据
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self decodeVideo];
    });

    // 从输入文件中读取数据
    while (_state != Stopped) {
        AVPacket pkt;
//        处理seek操作
        if (_seekTime >= 0) {
            int streamIdx;
            if (_hasAudio) {
                streamIdx = _aStream->index;
            } else {
                streamIdx = _vStream->index;
            }

            ret = av_seek_frame(_fmtCtx, streamIdx, _seekTime / av_q2d(_fmtCtx->streams[streamIdx]->time_base), AVSEEK_FLAG_BACKWARD);
            if (ret < 0) {
//                seek失败
                NSLog(@"seek失败");
                _seekTime = -1;
            } else {
                NSLog(@"seek成功 %d", _seekTime);
                [self clearAudioPktList];
                [self clearVideoPktList];
                _vSeekTime = _seekTime;
                _seekTime = -1;
                _aTime = _seekTime;
                _vTime = _seekTime;
            }
        }

        if (_vPktList.size() >= VIDEO_MAX_PKT_SIZE ||
            _aPktList.size() >= AUDIO_MAX_PKT_SIZE) {
            continue;
        }
        ret = av_read_frame(_fmtCtx, &pkt);
        if (ret == 0) {
            if (pkt.stream_index == _aStream->index) { // 读取到的是音频数据
                [self addAudioPkt:pkt];
            } else if (pkt.stream_index == _vStream->index) { // 读取到的是视频数据
                [self addVideoPkt:pkt];
            } else {
                av_packet_unref(&pkt);
            }
        } else if (ret == AVERROR_EOF) {
            if (_vPktList.size() == 0 && _aPktList.size() == 0) {
                NSLog(@"播放完");
                _fCanFree = YES;
                break;
            }
            continue;
        } else {
            ERROR_BUF;
            continue;
        }
    }

    if (_fCanFree) {
        NSLog(@"播放完 stop");
        [self stop];
    } else {
        _fCanFree = YES;
    }
}

- (void)addAudioPkt:(AVPacket &)pkt {
    [self.audioCondition lock];
    _aPktList.push_back(pkt);
    [self.audioCondition signal];
    [self.audioCondition unlock];
}

- (void)addVideoPkt:(AVPacket &)pkt {
    [self.videoCondition lock];
    _vPktList.push_back(pkt);
    [self.videoCondition signal];
    [self.videoCondition unlock];
}

- (void)clearAudioPktList {
    [self.audioCondition lock];
    for (AVPacket &pkt : _aPktList) {
        av_packet_unref(&pkt);
    }
    _aPktList.clear();
    [self.audioCondition unlock];
}

- (void)clearVideoPktList {
    [self.videoCondition lock];
    for (AVPacket &pkt : _vPktList) {
        av_packet_unref(&pkt);
    }
    _vPktList.clear();
    [self.videoCondition unlock];
}

#pragma mark -- 视频信息
- (int)initVideoInfo {
    // 初始化解码器
    int ret = [self initDecoder:&_vDecodeCtx stream:&_vStream type:AVMEDIA_TYPE_VIDEO];
    RET(@"initDecoder");

    // 初始化sws
    ret = [self initSws];
    RET(@"initSws");

    return 0;
}

- (int)initSws {
    int inW = _vDecodeCtx->width;
    int inH = _vDecodeCtx->height;

    _vSwsOutSpec.width = inW >> 4 << 4;
    _vSwsOutSpec.height = inH >> 4 << 4;
    _vSwsOutSpec.pixFmt = AV_PIX_FMT_RGB24;

    _vSwsOutSpec.size = av_image_get_buffer_size(_vSwsOutSpec.pixFmt, _vSwsOutSpec.width, _vSwsOutSpec.height, 1);


    // 初始化像素格式转换上下文
    _vSwsCtx = sws_getContext(inW,
                              inH,
                              _vDecodeCtx->pix_fmt,
                              _vSwsOutSpec.width,
                              _vSwsOutSpec.height,
                              _vSwsOutSpec.pixFmt,
                              SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!_vSwsCtx) {
        return -1;
    }


    // 初始化in frame
    _vSwsInFrame = av_frame_alloc();
    if (!_vSwsInFrame) {
        return -1;
    }

    _vSwsOutFrame = av_frame_alloc();
    if (!_vSwsOutFrame) {
        return -1;
    }

    // 初始化_vSwsOutFrame->data[0]
    int ret = av_image_alloc(_vSwsOutFrame->data,
                             _vSwsOutFrame->linesize,
                             _vSwsOutSpec.width,
                             _vSwsOutSpec.height,
                             _vSwsOutSpec.pixFmt,
                             1);

    RET(@"av_image_alloc");

    return 0;
}

- (void)decodeVideo {
    while (YES) {
        if (_state == Paused && _vSeekTime == -1) {
            continue;
        }

        if (_state == Stopped) {
            _vCanFree = YES;
            break;
        }
        [self.videoCondition lock];
        if (_vPktList.empty()) {
            [self.videoCondition unlock];
            continue;
        }
        AVPacket pkt = _vPktList.front();
        _vPktList.pop_front();
        [self.videoCondition unlock];

        //解码
        int ret = avcodec_send_packet(_vDecodeCtx, &pkt);
        //视频时钟
        if (pkt.pts != AV_NOPTS_VALUE) {
            _vTime = av_q2d(_vStream->time_base) * pkt.pts;
        }
        av_packet_unref(&pkt);

        if (ret < 0) continue;

        while (_state != Stopped) {
            ret = avcodec_receive_frame(_vDecodeCtx, _vSwsInFrame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            } else if (ret < 0) {
                ERROR_BUF;
                NSLog(@"%@ error %s", @"avcodec_receive_frame", errbuf);
                break;
            }

            // 发现视频的时间是早与seek的，直接丢弃
            if (_vSeekTime >= 0) {
                if (_vTime < _vSeekTime) {
                    continue;
                } else {
                    _vSeekTime = -1;
                }
            }

            sws_scale(_vSwsCtx, _vSwsInFrame->data, _vSwsInFrame->linesize, 0, _vSwsInFrame->height, _vSwsOutFrame->data, _vSwsOutFrame->linesize);

            // 音视频同步
            if (_hasAudio) {
                while (_vTime > _aTime+0.1 && _state == Playing) {
                    NSLog(@"_vTime %f, _aTime %f", _vTime, _aTime);
                };
            } else {

            }

            uint8_t *data = new uint8_t[_vSwsOutSpec.size];
            memcpy(data, _vSwsOutFrame->data[0], _vSwsOutSpec.size);
            if ([self.delegate respondsToSelector:@selector(frameDecode:data:width:height:linesize:)]) {
                if (_state != Stopped) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate frameDecode:self data:data width:self->_vSwsOutSpec.width height:self->_vSwsOutSpec.height linesize:self->_vSwsOutFrame->linesize[0]];
                    });
                }
            }
        }
    }
}

- (void)freeVideo {
    _vSeekTime = -1;
    _vTime = 0;
    _vStream = NULL;
    avcodec_free_context(&_vDecodeCtx);
    av_frame_free(&_vSwsInFrame);
    if (_vSwsOutFrame) {

    }
    av_frame_free(&_vSwsOutFrame);
    sws_freeContext(_vSwsCtx);
    _vSwsCtx = NULL;
    [self clearVideoPktList];
}


#pragma mark -- 音频信息

- (void)setVolumn:(int)volumn {
    _volumn = volumn;
}

- (int)initAudioInfo {
    // 初始化解码器
    int ret = [self initDecoder:&_aDecodeCtx stream:&_aStream type:AVMEDIA_TYPE_AUDIO];

    RET(@"initDecoder");
    [self initSwr];
    [self initSDL];
    return 0;
}

- (int)initSDL {
    SDL_AudioSpec spec;
    spec.freq = 44100;
    spec.format = AUDIO_S16LSB;
    spec.channels = 2;
    spec.samples = 512;
    spec.callback = sdlAudioCallback;
    spec.userdata = (__bridge void *)self;
    if (SDL_OpenAudio(&spec, NULL)) {
        return -1;
    }

    return 1;
}

- (int)initSwr {
    // 初始化变量
        // 创建重采样上下文
        // 输出参数
    _aSwrInSpec.sampleFmt = _aDecodeCtx->sample_fmt;
    _aSwrInSpec.sampleRate = _aDecodeCtx->sample_rate;
    _aSwrInSpec.chLayout = _aDecodeCtx->channel_layout;
    _aSwrInSpec.chs = _aDecodeCtx->channels;

    _aSwrOutSpec.sampleFmt = AV_SAMPLE_FMT_S16;
    _aSwrOutSpec.sampleRate = 44100;
    _aSwrOutSpec.chLayout = AV_CH_LAYOUT_STEREO;
    _aSwrOutSpec.chs = av_get_channel_layout_nb_channels(_aSwrOutSpec.chLayout);
    _aSwrOutSpec.bytesPerSampleFrame = _aSwrOutSpec.chs * av_get_bytes_per_sample(_aSwrOutSpec.sampleFmt);

    _aSwrInFrame = av_frame_alloc();
    if (!_aSwrInFrame) {
        return -1;
    }

    _aSwrOutFrame = av_frame_alloc();
    if (!_aSwrOutFrame) {
        return -1;
    }

    int ret = av_samples_alloc(_aSwrOutFrame->data, _aSwrOutFrame->linesize, _aSwrOutSpec.chs, 4096, _aSwrOutSpec.sampleFmt, 1);

    RET(@"av_samples_alloc");

    // 重采样上下文
    _aSwrCtx = swr_alloc_set_opts(nullptr,
                                  _aSwrOutSpec.chLayout,
                                  _aSwrOutSpec.sampleFmt,
                                  _aSwrOutSpec.sampleRate,
                                  _aSwrInSpec.chLayout,
                                  _aSwrInSpec.sampleFmt,
                                  _aSwrInSpec.sampleRate,
                                  0, nullptr);


    // 初始化重采样上下文
    ret = swr_init(_aSwrCtx);
    if (!ret) {
        return -1;
    }
    RET(@"swr_init");

    return 0;
}

static void sdlAudioCallback(void *userdata, Uint8 *stream, int len) {
    VideoPlayer *player = (__bridge VideoPlayer *)userdata;
    [player sdlAudioCallback:stream len:len];
}

- (void)sdlAudioCallback:(Uint8 *)stream len:(int)len {
    SDL_memset(stream, 0, len);
    // len:SDL音频缓冲区的大小
    while (len > 0) {
        if (_state == Paused) {
            break;
        }
        if (_state == Stopped) {
            _aCanFree = true;
            break;
        }
        if (_aSwrOutIdx >= _aSwrOutSize) {
            _aSwrOutSize = [self decodeAudio];
            if (_aSwrOutSize <= 0) {
                memset(_aSwrOutFrame->data[0], 0, _aSwrOutSize = 1024);
            } else {

            }
            _aSwrOutIdx = 0;
        }

        int fillLen = _aSwrOutSize - _aSwrOutIdx;
        fillLen = MIN(len, fillLen);

        SDL_MixAudio(stream,
                     _aSwrOutFrame->data[0] + _aSwrOutIdx,
                     fillLen,
                     _volumn);
        // 移动偏移量
        len -= fillLen;
        stream += fillLen;
        _aSwrOutIdx += fillLen;
    }
}

- (int)decodeAudio {
    [self.audioCondition lock];

//    while (_aPktList.empty()) {
//        [self.audioCondition wait];
//    }
    if (_aPktList.empty() || _state == Stopped) {
        [self.audioCondition unlock];
        return 0;
    }

    // 取出头部数据包
    AVPacket pkt = _aPktList.front();
    // 从头部删除
    _aPktList.pop_front();
    [self.audioCondition unlock];

    // 音频时钟
    if (pkt.pts != AV_NOPTS_VALUE) {
        _aTime = av_q2d(_aStream->time_base) * pkt.pts;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate timeDidChange:self];
        });
    }

    if (_aSeekTime >= 0) {
        if (_aTime < _aSeekTime) {
            av_packet_unref(&pkt);
            return 0;
        } else {
            _aSeekTime = -1;
        }
    }

    //解码
    int ret = avcodec_send_packet(_aDecodeCtx, &pkt);
    av_packet_unref(&pkt);
    RET(@"avcodec_send_packet");

    ret = avcodec_receive_frame(_aDecodeCtx, _aSwrInFrame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    } else RET(@"avcodec_receive_frame");

    // 重采样输出样本数
    int64_t outSamples = av_rescale_rnd(_aSwrOutSpec.sampleRate,
                                    _aSwrInFrame->nb_samples,
                                    _aSwrInSpec.sampleRate,
                                    AV_ROUND_UP);

    //音频重采样
    ret = swr_convert(_aSwrCtx,
                      _aSwrOutFrame->data,
                      (int)outSamples,
                      (const UInt8 **)_aSwrInFrame->data,
                      _aSwrInFrame->nb_samples);

    RET(@"swr_convert");

    // 音频
//    NSLog(@"%d %d %s ", _aSwrOutFrame->sample_rate, _aSwrOutFrame->channels, av_get_sample_fmt_name((AVSampleFormat)_aSwrOutFrame->format));

    return ret * _aSwrOutSpec.bytesPerSampleFrame;
}

- (void)freeAudio {
    _aSeekTime = -1;
    _aTime = 0;
    _aSwrOutIdx = 0;
    _aSwrOutSize = 0;
    _aStream = NULL;
    avcodec_free_context(&_aDecodeCtx);
    swr_free(&_aSwrCtx);
    [self clearAudioPktList];
    av_frame_free(&_aSwrInFrame);
    if (_aSwrOutFrame) {
        if (_aSwrOutFrame->data[0]) {
            av_freep(&_aSwrOutFrame->data[0]);
        }
    }
    av_frame_free(&_aSwrOutFrame);
    SDL_PauseAudio(1);
    SDL_CloseAudio();
}

#pragma mark -- 解码相关

- (int)initDecoder:(AVCodecContext **)decodeCtx stream:(AVStream **)stream type:(AVMediaType)type {

    // 检验流
    int ret = 0;
    int streamIdx = 0;

    ret = av_find_best_stream(_fmtCtx, type, -1, -1, NULL, 0);
    RET(@"av_find_best_stream");

    streamIdx = ret;
    *stream = _fmtCtx->streams[streamIdx];
    if (!*stream) {
        return -1;
    }

    // 为当前流找到合适的解码器
    AVCodec *decoder = avcodec_find_decoder((*stream)->codecpar->codec_id);
    if (!decoder) {
        NSLog(@"decoder not found %d", (*stream)->codecpar->codec_id);
        return -1;
    }

    // 初始化解码上下文
    *decodeCtx = avcodec_alloc_context3(decoder);
    if (!decodeCtx) {
        NSLog(@"avcodec_alloc_context3 error");
        return -1;
    }

    // 从流中拷贝参数到解码上下文中
    ret = avcodec_parameters_to_context(*decodeCtx, (*stream)->codecpar);
    RET(@"avcodec_parameters_to_context");

    // 打开解码器
    ret = avcodec_open2(*decodeCtx, decoder, nullptr);
    RET(@"avcodec_open2");

    return 0;
}

- (int)decode:(AVCodecContext *)decodeCtx avpacket:(AVPacket *)pkt {

    return 0;
}

#pragma mark -- 释放内存

- (void)free {
    while (!_fCanFree);
    while (!_vCanFree && _hasVideo);
    while (!_aCanFree && _hasAudio);
    avformat_close_input(&_fmtCtx);
    [self freeAudio];
    [self freeVideo];
    _fCanFree = NO;
    _vCanFree = NO;
    _aCanFree = NO;
    _seekTime = -1;
}

- (void)dealloc {
    [self stop];
    SDL_Quit();
}


- (void)fataError {
    self.state = Stopped;
    if ([self.delegate respondsToSelector:@selector(playFailed:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate playFailed:self];
        });
    }
    [self free];
}

@end
