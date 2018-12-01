//
//  SGAudioRenderer.m
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAudioRenderer.h"
#import "SGRenderer+Internal.h"
#import "SGAudioStreamPlayer.h"
#import "SGAudioFrame.h"
#import "SGFFmpeg.h"
#import "SGLock.h"

@interface SGAudioRenderer () <SGAudioStreamPlayerDelegate>

{
    NSLock *_lock;
    SGClock *_clock;
    SGAudioStreamPlayer *_player;
    SGAudioDescription *_audioDescription;
    
    CMTime _rate;
    double _volume;
    SGCapacity *_capacity;
    SGRenderableState _state;
    
    CMTime _renderTime;
    CMTime _renderDuration;
    int _frameCopiedSamples;
    int _renderCopiedSamples;
    SGAudioFrame *_currentFrame;
}

@end

@implementation SGAudioRenderer

@synthesize delegate = _delegate;

- (instancetype)init
{
    NSAssert(NO, @"Invalid Function.");
    return nil;
}

- (instancetype)initWithClock:(SGClock *)clock
{
    if (self = [super init]) {
        self->_clock = clock;
        self->_volume = 1.0f;
        self->_rate = CMTimeMake(1, 1);
        self->_lock = [[NSLock alloc] init];
        self->_audioDescription = [[SGAudioDescription alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

#pragma mark - Setter & Getter

- (SGBlock)setState:(SGRenderableState)state
{
    if (self->_state == state) {
        return ^{};
    }
    self->_state = state;
    return ^{
        [self.delegate renderable:self didChangeState:state];
    };
}

- (SGRenderableState)state
{
    __block SGRenderableState ret = SGRenderableStateNone;
    SGLockEXE00(self->_lock, ^{
        ret = self->_state;
    });
    return ret;
}

- (SGCapacity *)capacity
{
    __block SGCapacity *ret = nil;
    SGLockEXE00(self->_lock, ^{
        ret = [self->_capacity copy];
    });
    return ret ? ret : [[SGCapacity alloc] init];
}

- (void)setRate:(CMTime)rate
{
    SGLockCondEXE11(self->_lock, ^BOOL {
        return CMTimeCompare(self->_rate, rate) != 0;
    }, ^SGBlock {
        self->_rate = rate;
        return nil;
    }, ^BOOL(SGBlock block) {
        [self->_player setRate:CMTimeGetSeconds(rate) error:nil];
        return YES;
    });
}

- (CMTime)rate
{
    __block CMTime ret = CMTimeMake(1, 1);
    SGLockEXE00(self->_lock, ^{
        ret = self->_rate;
    });
    return ret;
}

- (void)setVolume:(double)volume
{
    SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_volume != volume;
    }, ^SGBlock {
        self->_volume = volume;
        return nil;
    }, ^BOOL(SGBlock block) {
        [self->_player setVolume:volume error:nil];
        return YES;
    });
}

- (double)volume
{
    __block double ret = 1.0f;
    SGLockEXE00(self->_lock, ^{
        ret = self->_volume;
    });
    return ret;
}

- (SGAudioDescription *)audioDescription
{
    __block SGAudioDescription *ret = nil;
    SGLockEXE00(self->_lock, ^{
        ret = self->_audioDescription;
    });
    return ret;
}

#pragma mark - Interface

- (BOOL)open
{
    __block float volume = 1.0f;
    __block CMTime rate = CMTimeMake(1, 1);
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_state == SGRenderableStateNone;
    }, ^SGBlock {
        volume = self->_volume;
        rate = self->_rate;
        return [self setState:SGRenderableStatePaused];
    }, ^BOOL(SGBlock block) {
        block();
        self->_player = [[SGAudioStreamPlayer alloc] init];
        self->_player.delegate = self;
        [self->_player setVolume:volume error:nil];
        [self->_player setRate:CMTimeGetSeconds(rate) error:nil];
        return YES;
    });
}

- (BOOL)close
{
    return SGLockEXE11(self->_lock, ^SGBlock {
        self->_frameCopiedSamples = 0;
        self->_renderCopiedSamples = 0;
        self->_renderTime = kCMTimeZero;
        self->_renderDuration = kCMTimeZero;
        self->_capacity = nil;
        [self->_currentFrame unlock];
        self->_currentFrame = nil;
        return [self setState:SGRenderableStateNone];
    }, ^BOOL(SGBlock block) {
        [self->_player pause];
        self->_player = nil;
        block();
        return YES;
    });
}

- (BOOL)pause
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_state == SGRenderableStateRendering || self->_state == SGRenderableStateFinished;
    }, ^SGBlock {
        return [self setState:SGRenderableStatePaused];
    }, ^BOOL(SGBlock block) {
        [self->_player pause];
        block();
        return YES;
    });
}

- (BOOL)resume
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_state == SGRenderableStatePaused || self->_state == SGRenderableStateFinished;
    }, ^SGBlock {
        return [self setState:SGRenderableStateRendering];
    }, ^BOOL(SGBlock block) {
        [self->_player play];
        block();
        return YES;
    });
}

- (BOOL)flush
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_state == SGRenderableStatePaused || self->_state == SGRenderableStateRendering || self->_state == SGRenderableStateFinished;
    }, ^SGBlock {
        [self->_currentFrame unlock];
        self->_currentFrame = nil;
        self->_frameCopiedSamples = 0;
        self->_renderCopiedSamples = 0;
        self->_renderTime = kCMTimeZero;
        self->_renderDuration = kCMTimeZero;
        return ^{};
    }, ^BOOL(SGBlock block) {
        [self->_player flush];
        block();
        return YES;
    });
}

- (BOOL)finish
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_state == SGRenderableStateRendering || self->_state == SGRenderableStatePaused;
    }, ^SGBlock {
        return [self setState:SGRenderableStateFinished];
    }, ^BOOL(SGBlock block) {
        [self->_player pause];
        block();
        return YES;
    });
}


#pragma mark - SGAudioStreamPlayerDelegate

- (void)audioStreamPlayer:(SGAudioStreamPlayer *)player render:(const AudioTimeStamp *)timeStamp data:(AudioBufferList *)data nb_samples:(UInt32)nb_samples
{
    [self->_lock lock];
    self->_renderCopiedSamples = 0;
    self->_renderTime = kCMTimeZero;
    self->_renderDuration = kCMTimeZero;
    if (self->_state != SGRenderableStateRendering) {
        [self->_lock unlock];
        return;
    }
    UInt32 nb_samples_left = nb_samples;
    while (YES) {
        if (nb_samples_left <= 0) {
            [self->_lock unlock];
            break;
        }
        if (!self->_currentFrame) {
            [self->_lock unlock];
            SGAudioFrame *frame = [self.delegate renderable:self fetchFrame:nil];
            if (!frame) {
                break;
            }
            [self->_lock lock];
            self->_currentFrame = frame;
        }
        NSAssert(self->_currentFrame.format == AV_SAMPLE_FMT_FLTP, @"Invaild audio frame format.");
        UInt32 frame_nb_samples_left = self->_currentFrame.numberOfSamples - self->_frameCopiedSamples;
        UInt32 nb_samples_to_copy = MIN(nb_samples_left, frame_nb_samples_left);
        for (int i = 0; i < data->mNumberBuffers && i < self->_currentFrame.numberOfChannels; i++) {
            UInt32 data_offset = self->_renderCopiedSamples * (UInt32)sizeof(float);
            UInt32 frame_offset = self->_frameCopiedSamples * (UInt32)sizeof(float);
            UInt32 size_to_copy = nb_samples_to_copy * (UInt32)sizeof(float);
            memcpy(data->mBuffers[i].mData + data_offset, self->_currentFrame.data[i] + frame_offset, size_to_copy);
        }
        if (self->_renderCopiedSamples == 0) {
            CMTime duration = CMTimeMultiplyByRatio(self->_currentFrame.duration, self->_frameCopiedSamples, self->_currentFrame.numberOfSamples);
            self->_renderTime = CMTimeAdd(self->_currentFrame.timeStamp, duration);
        }
        CMTime duration = CMTimeMultiplyByRatio(self->_currentFrame.duration, nb_samples_to_copy, self->_currentFrame.numberOfSamples);
        self->_renderDuration = CMTimeAdd(self->_renderDuration, duration);
        self->_renderCopiedSamples += nb_samples_to_copy;
        self->_frameCopiedSamples += nb_samples_to_copy;
        if (self->_currentFrame.numberOfSamples <= self->_frameCopiedSamples) {
            [self->_currentFrame unlock];
            self->_currentFrame = nil;
            self->_frameCopiedSamples = 0;
        }
        nb_samples_left -= nb_samples_to_copy;
    }
    UInt32 nb_samples_copied = nb_samples - nb_samples_left;
    for (int i = 0; i < data->mNumberBuffers; i++) {
        UInt32 size_copied = nb_samples_copied * (UInt32)sizeof(float);
        UInt32 size_left = data->mBuffers[i].mDataByteSize - size_copied;
        if (size_left > 0) {
            memset(data->mBuffers[i].mData + size_copied, 0, size_left);
        }
    }
}

- (void)audioStreamPlayer:(SGAudioStreamPlayer *)player postRender:(const AudioTimeStamp *)timestamp
{
    [self->_lock lock];
    CMTime renderTime = self->_renderTime;
    CMTime renderDuration = SGCMTimeMultiply(self->_renderDuration, self->_rate);
    CMTime frameDuration = !self->_currentFrame ? kCMTimeZero : CMTimeMultiplyByRatio(self->_currentFrame.duration, self->_currentFrame.numberOfSamples - self->_frameCopiedSamples, self->_currentFrame.numberOfSamples);
    SGBlock clockBlock = ^{};
    if (self->_state == SGRenderableStateRendering) {
        if (self->_renderCopiedSamples) {
            clockBlock = ^{
                [self->_clock setAudioCurrentTime:renderTime];
            };
        } else {
            clockBlock = ^{
                [self->_clock markAsAudioStalled];
            };
        }
    }
    SGCapacity *capacity = [[SGCapacity alloc] init];
    capacity.duration = CMTimeAdd(renderDuration, frameDuration);
    SGBlock capacityBlock = ^{};
    if (![capacity isEqualToCapacity:self->_capacity]) {
        self->_capacity = capacity;
        capacityBlock = ^{
            [self.delegate renderable:self didChangeCapacity:[capacity copy]];
        };
    }
    [self->_lock unlock];
    clockBlock();
    capacityBlock();
}

@end
