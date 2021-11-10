//
//  VideoView.m
//  FFMpegVideoPlayer
//
//  Created by 默羊 on 2021/7/30.
//

#import "VideoView.h"

@interface VideoView() {
    NSRect _rect;
}

@property (nonatomic, strong) NSImage *image;

@end

@implementation VideoView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // 计算尺寸
    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat w = 0;
    CGFloat h = 0;

    CGFloat playerWidth = self.bounds.size.width;
    CGFloat playerHeight = self.bounds.size.height;

    CGFloat width = self.image.size.width;
    CGFloat height = self.image.size.height;

    if (width > height && width / height >= playerWidth / playerHeight) {
        w = playerWidth;
        float scale = playerWidth / width;
        h = height * scale;
    } else {
        h = playerHeight;
        float scale = playerHeight / height;
        w = width * scale;
    }

    x = (playerWidth - w) / 2;
    y = (playerHeight - h) / 2;

    self->_rect = NSMakeRect(x, y, w, h);

    // Drawing code here.
    [self.image drawInRect:_rect];
}

- (void)frameDecode:(VideoPlayer *)player data:(uint8_t *)data width:(int)width height:(int)height linesize:(int)linesize {
    if (data) {
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
        CFDataRef dataRef = CFDataCreate(kCFAllocatorDefault,
                                      data,
                                      linesize * height);

        CGDataProviderRef provider = CGDataProviderCreateWithCFData(dataRef);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef cgImage = CGImageCreate(width,
                                           height,
                                           8,
                                           24,
                                           linesize,
                                           colorSpace,
                                           bitmapInfo,
                                           provider,
                                           NULL,
                                           NO,
                                           kCGRenderingIntentDefault);

        NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSMakeSize(width, height)];
        CGImageRelease(cgImage);
        CGColorSpaceRelease(colorSpace);
        CGDataProviderRelease(provider);
        CFRelease(dataRef);
        free(data);
        data = NULL;
        self.image = image;
    } else {
        self.image = nil;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
}

@end
