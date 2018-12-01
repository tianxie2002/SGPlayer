//
//  SGAudioStreamPlayer.m
//  SGPlayer
//
//  Created by Single on 2018/1/16.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAudioStreamPlayer.h"
#import "SGPLFTargets.h"

static int const SGAudioStreamPlayerMaximumFramesPerSlice = 4096;
static int const SGAudioStreamPlayerMaximumChannels = 2;

@interface SGAudioStreamPlayer ()

@property (nonatomic) AUGraph graph;
@property (nonatomic) AUNode nodeForTimePitch;
@property (nonatomic) AUNode nodeForMixer;
@property (nonatomic) AUNode nodeForOutput;
@property (nonatomic) AudioUnit audioUnitForTimePitch;
@property (nonatomic) AudioUnit audioUnitForMixer;
@property (nonatomic) AudioUnit audioUnitForOutput;

@end

@implementation SGAudioStreamPlayer

+ (AudioStreamBasicDescription)defaultASBD
{
    AudioStreamBasicDescription audioStreamBasicDescription;
    UInt32 floatByteSize                          = sizeof(float);
    audioStreamBasicDescription.mBitsPerChannel   = 8 * floatByteSize;
    audioStreamBasicDescription.mBytesPerFrame    = floatByteSize;
    audioStreamBasicDescription.mChannelsPerFrame = SGAudioStreamPlayerMaximumChannels;
    audioStreamBasicDescription.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    audioStreamBasicDescription.mFormatID         = kAudioFormatLinearPCM;
    audioStreamBasicDescription.mFramesPerPacket  = 1;
    audioStreamBasicDescription.mBytesPerPacket   = audioStreamBasicDescription.mFramesPerPacket * audioStreamBasicDescription.mBytesPerFrame;
    audioStreamBasicDescription.mSampleRate       = 44100.0f;
    return audioStreamBasicDescription;
}

- (instancetype)init
{
    if (self = [super init])
    {
        [self setup];
    }
    return self;
}

- (void)dealloc
{
    [self destroy];
}

#pragma mark - Setup/Destory

- (void)setup
{
    NewAUGraph(&_graph);
    
    AudioComponentDescription descriptionForTimePitch;
    descriptionForTimePitch.componentType = kAudioUnitType_FormatConverter;
    descriptionForTimePitch.componentSubType = kAudioUnitSubType_NewTimePitch;
    descriptionForTimePitch.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponentDescription descriptionForMixer;
    descriptionForMixer.componentType = kAudioUnitType_Mixer;
#if SGPLATFORM_TARGET_OS_MAC
    descriptionForMixer.componentSubType = kAudioUnitSubType_StereoMixer;
#elif SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    descriptionForMixer.componentSubType = kAudioUnitSubType_MultiChannelMixer;
#endif
    descriptionForMixer.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponentDescription descriptionForOutput;
    descriptionForOutput.componentType = kAudioUnitType_Output;
#if SGPLATFORM_TARGET_OS_MAC
    descriptionForOutput.componentSubType = kAudioUnitSubType_DefaultOutput;
#elif SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    descriptionForOutput.componentSubType = kAudioUnitSubType_RemoteIO;
#endif
    descriptionForOutput.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AUGraphAddNode(self.graph, &descriptionForTimePitch, &_nodeForTimePitch);
    AUGraphAddNode(self.graph, &descriptionForMixer, &_nodeForMixer);
    AUGraphAddNode(self.graph, &descriptionForOutput, &_nodeForOutput);
    AUGraphOpen(self.graph);
    AUGraphConnectNodeInput(self.graph, self.nodeForTimePitch, 0, self.nodeForMixer, 0);
    AUGraphConnectNodeInput(self.graph, self.nodeForMixer, 0, self.nodeForOutput, 0);
    AUGraphNodeInfo(self.graph, self.nodeForTimePitch, &descriptionForTimePitch, &_audioUnitForTimePitch);
    AUGraphNodeInfo(self.graph, self.nodeForMixer, &descriptionForMixer, &_audioUnitForMixer);
    AUGraphNodeInfo(self.graph, self.nodeForOutput, &descriptionForOutput, &_audioUnitForOutput);
    
    AudioUnitSetProperty(self.audioUnitForTimePitch,
                         kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0,
                         &SGAudioStreamPlayerMaximumFramesPerSlice,
                         sizeof(SGAudioStreamPlayerMaximumFramesPerSlice));
    AudioUnitSetProperty(self.audioUnitForMixer,
                         kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0,
                         &SGAudioStreamPlayerMaximumFramesPerSlice,
                         sizeof(SGAudioStreamPlayerMaximumFramesPerSlice));
    AudioUnitSetProperty(self.audioUnitForOutput,
                         kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0,
                         &SGAudioStreamPlayerMaximumFramesPerSlice,
                         sizeof(SGAudioStreamPlayerMaximumFramesPerSlice));
    
    AURenderCallbackStruct inputCallbackStruct;
    inputCallbackStruct.inputProc = inputCallback;
    inputCallbackStruct.inputProcRefCon = (__bridge void *)(self);
    AUGraphSetNodeInputCallback(self.graph, self.nodeForTimePitch, 0, &inputCallbackStruct);
    AudioUnitAddRenderNotify(self.audioUnitForOutput, outputRenderCallback, (__bridge void *)(self));
    
    NSError *error;
    if (![self setAsbd:[SGAudioStreamPlayer defaultASBD] error:&error])
    {
       _error = error;
    }
    if (![self setVolume:1.0 error:&error])
    {
        _error = error;
    }
    if (![self setRate:1.0 error:&error])
    {
        _error = error;
    }
    AUGraphInitialize(self.graph);
}

- (void)destroy
{
    AUGraphStop(self.graph);
    AUGraphUninitialize(self.graph);
    AUGraphClose(self.graph);
    DisposeAUGraph(self.graph);
}

#pragma mark - Interface

- (void)play
{
    if (!self.playing)
    {
        AUGraphStart(self.graph);
    }
}

- (void)pause
{
    if (self.playing)
    {
        AUGraphStop(self.graph);
    }
}

- (void)flush
{
    if (self.audioUnitForTimePitch)
    {
        AudioUnitReset(self.audioUnitForTimePitch, kAudioUnitScope_Global, 0);
    }
    if (self.audioUnitForMixer)
    {
        AudioUnitReset(self.audioUnitForMixer, kAudioUnitScope_Global, 0);
    }
    if (self.audioUnitForOutput)
    {
        AudioUnitReset(self.audioUnitForOutput, kAudioUnitScope_Global, 0);
    }
}

#pragma mark - Setter & Getter

- (BOOL)playing
{
    if (self.graph)
    {
        Boolean running = FALSE;
        OSStatus ret = AUGraphIsRunning(self.graph, &running);
        if (ret == noErr)
        {
            return running == TRUE ? YES : NO;
        }
        return NO;
    }
    return NO;
}

- (BOOL)setVolume:(float)volume error:(NSError **)error
{
    AudioUnitParameterID param;
#if SGPLATFORM_TARGET_OS_MAC
    param = kStereoMixerParam_Volume;
#elif SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    param = kMultiChannelMixerParam_Volume;
#endif
    OSStatus status = AudioUnitSetParameter(self.audioUnitForMixer, param, kAudioUnitScope_Input, 0, volume, 0);
    if (status != noErr)
    {
        *error = [NSError errorWithDomain:@"Volume-Mixer-Global" code:status userInfo:nil];
        return NO;
    }
    _volume = volume;
    return YES;
}

- (BOOL)setRate:(float)rate error:(NSError **)error
{
    OSStatus status = AudioUnitSetParameter(self.audioUnitForTimePitch, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, rate, 0);
    if (status != noErr)
    {
        *error = [NSError errorWithDomain:@"Rate-TimePitch-Global" code:status userInfo:nil];
        return NO;
    }
    _rate = rate;
    return YES;
}

- (BOOL)setAsbd:(AudioStreamBasicDescription)asbd error:(NSError **)error
{
    OSStatus status = noErr;
    UInt32 size = sizeof(AudioStreamBasicDescription);
    status = AudioUnitSetProperty(self.audioUnitForTimePitch, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size);
    if (status != noErr)
    {
        [self asbdRollback];
        *error = [NSError errorWithDomain:@"StreamForamt-TimePitch-Input" code:status userInfo:nil];
        return NO;
    }
    status = AudioUnitSetProperty(self.audioUnitForTimePitch, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size);
    if (status != noErr)
    {
        [self asbdRollback];
        *error = [NSError errorWithDomain:@"StreamForamt-TimePitch-Output" code:status userInfo:nil];
        return NO;
    }
    status = AudioUnitSetProperty(self.audioUnitForMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size);
    if (status != noErr)
    {
        [self asbdRollback];
        *error = [NSError errorWithDomain:@"StreamForamt-Mixer-Input" code:status userInfo:nil];
        return NO;
    }
    status = AudioUnitSetProperty(self.audioUnitForMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size);
    if (status != noErr)
    {
        [self asbdRollback];
        *error = [NSError errorWithDomain:@"StreamForamt-Mixer-Output" code:status userInfo:nil];
        return NO;
    }
    status = AudioUnitSetProperty(self.audioUnitForOutput, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size);
    if (status != noErr)
    {
        [self asbdRollback];
        *error = [NSError errorWithDomain:@"StreamForamt-Ouput-Input" code:status userInfo:nil];
        return NO;
    }
    _asbd = asbd;
    return YES;
}

- (void)asbdRollback
{
    UInt32 size = sizeof(AudioStreamBasicDescription);
    AudioUnitSetProperty(self.audioUnitForTimePitch, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_asbd, size);
    AudioUnitSetProperty(self.audioUnitForTimePitch, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_asbd, size);
    AudioUnitSetProperty(self.audioUnitForMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_asbd, size);
    AudioUnitSetProperty(self.audioUnitForMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_asbd, size);
    AudioUnitSetProperty(self.audioUnitForOutput, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_asbd, size);
    AudioUnitSetProperty(self.audioUnitForOutput, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_asbd, size);
}

#pragma mark - Callback

static OSStatus inputCallback(void *inRefCon,
                       AudioUnitRenderActionFlags *ioActionFlags,
                       const AudioTimeStamp *inTimeStamp,
                       UInt32 inBusNumber,
                       UInt32 inNumberFrames,
                       AudioBufferList *ioData)
{
    @autoreleasepool {
        SGAudioStreamPlayer *obj = (__bridge SGAudioStreamPlayer *)inRefCon;
        [obj.delegate audioStreamPlayer:obj render:inTimeStamp data:ioData nb_samples:inNumberFrames];
    }
    return noErr;
}

static OSStatus outputRenderCallback(void *inRefCon,
                              AudioUnitRenderActionFlags *ioActionFlags,
                              const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames,
                              AudioBufferList *ioData)
{
    @autoreleasepool {
        SGAudioStreamPlayer *obj = (__bridge SGAudioStreamPlayer *)inRefCon;
        if ((*ioActionFlags) & kAudioUnitRenderAction_PreRender)
        {
            if ([obj.delegate respondsToSelector:@selector(audioStreamPlayer:preRender:)])
            {
                [obj.delegate audioStreamPlayer:obj preRender:inTimeStamp];
            }
        }
        else if ((*ioActionFlags) & kAudioUnitRenderAction_PostRender)
        {
            if ([obj.delegate respondsToSelector:@selector(audioStreamPlayer:postRender:)])
            {
                [obj.delegate audioStreamPlayer:obj postRender:inTimeStamp];
            }
        }
    }
    return noErr;
}

@end
