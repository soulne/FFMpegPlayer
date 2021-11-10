//
//  ViewController.m
//  FFMpegVideoPlayer
//
//  Created by 默羊 on 2021/7/30.
//

#import "ViewController.h"
#import "VideoView.h"
#import "VideoSlider.h"
#import "VideoPlayer.h"

@interface ViewController()<VideoPlayerProtocol>

@property (weak) IBOutlet VideoView *playView;
@property (weak) IBOutlet NSSlider *timeSlider;
@property (weak) IBOutlet NSTextField *timeLabel;
@property (weak) IBOutlet NSSlider *volumeSilder;
@property (weak) IBOutlet NSTextField *volumeLabel;
@property (weak) IBOutlet NSButton *openFileButon;
@property (weak) IBOutlet NSButton *playButton;
@property (weak) IBOutlet NSButton *stopButton;

@property (nonatomic, strong) VideoPlayer *player;

@property (nonatomic, strong) NSString *totalDuration;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.playView.wantsLayer = YES;
    self.playView.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.timeSlider.trackFillColor = [NSColor whiteColor];

    self.player = [[VideoPlayer alloc] init];
    self.player.delegate = self;

    self.playButton.enabled = NO;
    self.stopButton.enabled = NO;
    self.timeSlider.enabled = NO;

    [self volumnChange:self.volumeSilder];

    NSLog(@"%lu", sizeof(void *));

    NSLog(@"%lu", sizeof(float *));

}

- (IBAction)playVideo:(id)sender {
    if (self.player.state == Playing) {
        [self.player pause];
    } else {
        [self.player play];
    }
}

- (IBAction)stopVideo:(id)sender {
    [self.player stop];
}

- (IBAction)openFile:(id)sender {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = NO;
    openPanel.directoryURL = [NSURL fileURLWithPath:@"/Users/默羊/Desktop/pcmFile"];
//    NSArray *fileTypes = [[NSArray alloc] initWithObjects:@"mp4", @"MP4", nil];
//    [openPanel setAllowedFileTypes:fileTypes];

    BOOL okButtonPressed = ([openPanel runModal] == NSModalResponseOK);
    if (okButtonPressed) {
        NSString *path = [[openPanel URL] path];
        NSLog(@"%@", path);
        self.player.filename = path;

        [self.player play];
    }
}
- (IBAction)timeChange:(VideoSlider *)sender {
    NSEvent *event = [[NSApplication sharedApplication] currentEvent];
    BOOL endingDrag = event.type == NSEventTypeLeftMouseUp;

    if (endingDrag) {
        [self setTimeText:sender.intValue];
        [self.player setTime:sender.intValue];
    }
}


- (IBAction)volumnChange:(NSSlider *)sender {
    self.volumeLabel.stringValue = [NSString stringWithFormat:@"%d", sender.intValue];
    [self.player setVolumn:sender.intValue];
}

- (void)setTimeText:(int)second {
    int h = second / 3600;
    int m = (second / 60) % 60;
    int s = second % 60;
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%02d:%02d:%02d/%@", h, m, s, self.totalDuration];
}

#pragma mark -- VideoPlayerProtocol
- (void)stateChange:(State)state player:(VideoPlayer *)player {
    if (state == Playing) {
        NSLog(@"playing");
        [self.playButton setTitle:@"暂停"];
    } else {
        [self.playButton setTitle:@"播放"];
    }

    if (state == Stopped) {
        NSLog(@"stopped");
        self.openFileButon.hidden = NO;
        self.playButton.enabled = NO;
        self.stopButton.enabled = NO;
        self.timeSlider.enabled = NO;
        self.totalDuration = [NSString stringWithFormat:@"%02d:%02d:%02d", 0, 0, 0];
        [self.timeSlider setIntValue:0];
        [self setTimeText:0];
    } else {
        NSLog(@"state %lu", (unsigned long)state);
        self.openFileButon.hidden = YES;
        self.playButton.enabled = YES;
        self.stopButton.enabled = YES;
        self.timeSlider.enabled = YES;
    }
}

- (void)initFinished:(VideoPlayer *)player {
    int seconds = [player getDuration];

    int h = seconds / 3600;
    int m = ((seconds % 3600) / 60);
    int s = (seconds % 60);
    self.totalDuration  = [NSString stringWithFormat:@"%02d:%02d:%02d", h, m, s];

    self.timeLabel.stringValue = [NSString stringWithFormat:@"00:00:00/%@", self.totalDuration];
    self.timeSlider.maxValue = seconds;
}

- (void)playFailed:(VideoPlayer *)player {

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"确定"];
    alert.messageText = @"播放失败";

    [alert beginSheetModalForWindow:[NSApplication sharedApplication].keyWindow completionHandler:^(NSModalResponse returnCode) {
        //        NSLog(@"%d", returnCode);
        if (returnCode == NSAlertFirstButtonReturn) {
            NSLog(@"确定");
        } else {
            NSLog(@"其他按钮");
        }
    }];
}

- (void)frameDecode:(VideoPlayer *)player data:(uint8_t *)data width:(int)width height:(int)height linesize:(int)linesize {
    [self.playView frameDecode:player data:data width:width height:height linesize:linesize];
}

- (void)timeDidChange:(VideoPlayer *)player {
    NSEvent *event = [[NSApplication sharedApplication] currentEvent];
    BOOL startingDrag = event.type == NSEventTypeLeftMouseDown;
    BOOL endingDrag = event.type == NSEventTypeLeftMouseUp;
    BOOL dragging = event.type == NSEventTypeLeftMouseDragged;

    if (startingDrag || endingDrag || dragging) {
        NSLog(@"slider value started changing");
    } else {
        [self.timeSlider setIntValue:[player getCurrentTime]];
        [self setTimeText:[player getCurrentTime]];
    }
}

@end
