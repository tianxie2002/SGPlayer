//
//  SGFFSession.m
//  SGPlayer
//
//  Created by Single on 2018/1/16.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGFFSession.h"
#import "SGFFFormatContext.h"
#import "SGFFStreamManager.h"
#import "SGFFCodecManager.h"
#import "SGFFOutputManager.h"
#import "SGFFAudioOutput.h"
#import "SGFFVideoOutput.h"
#import "SGFFOutputSync.h"
#import "SGPlayerMacro.h"
#import "SGFFLog.h"

@interface SGFFSession () <SGFFSourceDelegate, SGFFStreamManagerDelegate, SGFFCodecCapacityDelegate, SGFFCodecProcessingDelegate, SGFFVideoOutputDelegate>

@property (nonatomic, copy) NSURL * contentURL;
@property (nonatomic, weak) id <SGFFSessionDelegate> delegate;

@property (nonatomic, strong) id <SGFFSource> source;
@property (nonatomic, strong) SGFFStreamManager * streamManager;
@property (nonatomic, strong) SGFFCodecManager * codecManager;
@property (nonatomic, strong) SGFFOutputManager * outputManager;
@property (nonatomic, strong) SGFFOutputSync * outputSync;


@end

@implementation SGFFSession

- (instancetype)initWithContentURL:(NSURL *)contentURL delegate:(id <SGFFSessionDelegate>)delegate
{
    if (self = [super init])
    {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            av_log_set_callback(SGFFLogCallback);
            av_register_all();
            avformat_network_init();
        });
        
        self.contentURL = contentURL;
        self.delegate = delegate;
    }
    return self;
}

- (void)open
{
    self.source = [[SGFFFormatContext alloc] initWithContentURL:self.contentURL delegate:self];
    [self.source open];
}

- (void)close
{
    [self.source close];
    [self.streamManager close];
}

- (void)seekToTime:(NSTimeInterval)timestamp
{
    [self.source seekToTime:timestamp];
}


#pragma mark - Callback

- (void)callbackForError
{
    if ([self.delegate respondsToSelector:@selector(session:didFailed:)]) {
        [self.delegate session:self didFailed:self.error];
    }
}


#pragma mark - SGFFSourceDelegate

- (void)sourceDidOpened:(id <SGFFSource>)source
{
    self.streamManager = [[SGFFStreamManager alloc] initWithStreams:self.source.streams delegate:self];
    [self.streamManager open];
}

- (void)sourceDidFailed:(id <SGFFSource>)source
{
    self.error = source.error;
    [self callbackForError];
}

- (void)sourceDidFinishedSeeking:(id <SGFFSource>)source
{
    [self.streamManager flush];
}

- (void)source:(id <SGFFSource>)source didOutputPacket:(SGFFPacket *)packet
{
    [self.streamManager putPacket:packet];
}


#pragma mark - SGFFStreamManagerDelegate

- (void)streamManagerDidOpened:(SGFFStreamManager *)streamManager
{
    self.outputSync = [[SGFFOutputSync alloc] init];
    self.outputManager = [[SGFFOutputManager alloc] init];
    self.outputManager.audioOutput = [[SGFFAudioOutput alloc] init];
    self.outputManager.audioOutput.renderSource = self.streamManager.currentAudioStream.codec;
    self.outputSync.audioOutput = self.outputManager.audioOutput;
    SGFFVideoOutput * videoOutput = [[SGFFVideoOutput alloc] init];
    videoOutput.sync = self.outputSync;
    videoOutput.delegate = self;
    videoOutput.renderSource = self.streamManager.currentVideoStream.codec;
    self.outputManager.videoOutput = videoOutput;
    [self.source read];
    [self.outputManager.audioOutput play];
}

- (void)streamManagerDidFailed:(SGFFStreamManager *)streamManager
{
    self.error = streamManager.error;
    [self callbackForError];
}

- (id <SGFFCodec>)streamManager:(SGFFStreamManager *)streamManager codecForStream:(SGFFStream *)stream
{
    if (!self.codecManager)
    {
        self.codecManager = [[SGFFCodecManager alloc] init];
    }
    id <SGFFCodec> codec = [self.codecManager codecForStream:stream.stream];
    codec.capacityDelegate = self;
    codec.processingDelegate = self;
    return codec;
}


#pragma marl - SGFFCodecCapacityDelegate

- (void)codecDidChangeCapacity:(id <SGFFCodec>)codec
{
    BOOL shouldPaused = NO;
    if (self.streamManager.size > 15 * 1024 * 1024)
    {
        shouldPaused = YES;
    }
    else if (codec == self.streamManager.currentAudioStream.codec)
    {
        if (SGFFTimestampConvertToSeconds(codec.duration, codec.timebase) > 10)
        {
            shouldPaused = YES;
        }
    }
    if (shouldPaused) {
        [self.source pause];
    } else {
        [self.source resume];
    }
}


#pragma mark - SGFFCodecProcessingDelegate

- (id <SGFFFrame>)codec:(id <SGFFCodec>)codec processingFrame:(id <SGFFFrame>)frame
{
    return frame;
}

- (id <SGFFOutputRender>)codec:(id <SGFFCodec>)codec processingOutputRender:(id <SGFFFrame>)frame
{
    return [self.outputManager renderWithFrame:frame];
}


#pragma mark - SGFFVideoOutputDelegate

- (void)videoOutputDidChangeDisplayView:(SGFFVideoOutput *)output
{
    output.displayView.frame = self.view.bounds;
    [self.view addSubview:output.displayView];
}


@end
