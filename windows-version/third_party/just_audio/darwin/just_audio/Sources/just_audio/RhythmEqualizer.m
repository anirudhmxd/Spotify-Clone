#import "RhythmEqualizer.h"
#import <MediaToolbox/MediaToolbox.h>

typedef struct {
    void *owner;
    RhythmDSP dsp;
    AudioStreamBasicDescription format;
    bool supported;
} RhythmTap;

static void RhythmInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
    RhythmTap *context = calloc(1, sizeof(RhythmTap));
    context->owner = (void *)CFRetain(info);
    *storage = context;
}
static void RhythmFinalize(MTAudioProcessingTapRef tap) {
    RhythmTap *context = MTAudioProcessingTapGetStorage(tap);
    CFRelease(context->owner);
    free(context);
}
static void RhythmPrepare(MTAudioProcessingTapRef tap, CMItemCount maximum, const AudioStreamBasicDescription *format) {
    RhythmTap *context = MTAudioProcessingTapGetStorage(tap);
    context->format = *format;
    context->supported = format->mFormatID == kAudioFormatLinearPCM &&
        format->mSampleRate > 0 && format->mChannelsPerFrame <= RH_CHANNELS &&
        ((format->mFormatFlags & kAudioFormatFlagIsFloat && (format->mBitsPerChannel == 32 || format->mBitsPerChannel == 64)) ||
         (format->mFormatFlags & kAudioFormatFlagIsSignedInteger && (format->mBitsPerChannel == 16 || format->mBitsPerChannel == 32)));
    rh_reset(&context->dsp, format->mSampleRate);
    RhythmEqualizer *owner = (__bridge RhythmEqualizer *)context->owner;
    atomic_store(&owner->control.supported, context->supported);
}
static void RhythmUnprepare(MTAudioProcessingTapRef tap) {}
static void RhythmProcess(MTAudioProcessingTapRef tap, CMItemCount requested, MTAudioProcessingTapFlags flags,
                          AudioBufferList *buffers, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flagsOut, NULL, framesOut);
    if (status != noErr) { *framesOut = 0; return; }
    RhythmTap *context = MTAudioProcessingTapGetStorage(tap);
    if (!context->supported) return;
    RhythmEqualizer *owner = (__bridge RhythmEqualizer *)context->owner;
    RhythmControl *control = &owner->control;
    RhythmDSP *dsp = &context->dsp;
    if (flags & kMTAudioProcessingTapFlag_StartOfStream) rh_reset(dsp, context->format.mSampleRate);
    rh_begin(dsp, control, (unsigned)*framesOut);
    bool floating = (context->format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    unsigned bits = context->format.mBitsPerChannel;
    unsigned channelBase = 0;
    for (unsigned b=0; b<buffers->mNumberBuffers; b++) {
        AudioBuffer buffer = buffers->mBuffers[b];
        unsigned channels = buffer.mNumberChannels;
        unsigned samples = (unsigned)fmin(*framesOut * channels, buffer.mDataByteSize / (bits/8));
        for (unsigned i=0; i<samples; i++) {
            unsigned channel = channelBase + (i % channels);
            if (channel >= RH_CHANNELS || !buffer.mData) continue;
            float x = floating ? (bits == 32 ? ((float *)buffer.mData)[i] : (float)((double *)buffer.mData)[i])
                : (bits == 16 ? ((int16_t *)buffer.mData)[i]/32768.0f : ((int32_t *)buffer.mData)[i]/2147483648.0f);
            float y = rh_sample(dsp, x, channel);
            if (floating) {
                if (bits == 32) ((float *)buffer.mData)[i] = y;
                else ((double *)buffer.mData)[i] = y;
            } else {
                if (bits == 16) ((int16_t *)buffer.mData)[i] = (int16_t)lrintf(fmaxf(-32768, fminf(32767, y*32768)));
                else ((int32_t *)buffer.mData)[i] = (int32_t)llrint(fmax(-2147483648.0, fmin(2147483647.0, y*2147483648.0)));
            }
            if (channel == 0) rh_capture(dsp, control, y);
        }
        channelBase += channels;
    }
}

@implementation RhythmEqualizer {
    NSHashTable<AVPlayerItem *> *_attached;
}
- (instancetype)init {
    self = [super init];
    if (self) { rh_control_init(&control); _attached = [NSHashTable weakObjectsHashTable]; }
    return self;
}
- (void)setGains:(NSArray<NSNumber *> *)gains enabled:(BOOL)enabled {
    for (unsigned i=0; i<RH_BANDS; i++) {
        double gain = i < gains.count ? gains[i].doubleValue : 0;
        atomic_store(&control.gains[i], isfinite(gain) ? (int)(fmax(-12, fmin(12, gain))*100) : 0);
    }
    atomic_store(&control.enabled, enabled);
}
- (void)attachToItem:(AVPlayerItem *)item {
    if ([_attached containsObject:item]) return;
    NSArray<AVAssetTrack *> *tracks = [item.asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count) return;
    NSMutableArray *parameters = [NSMutableArray array];
    for (AVAssetTrack *track in tracks) {
        MTAudioProcessingTapCallbacks callbacks = {kMTAudioProcessingTapCallbacksVersion_0,
            (__bridge void *)self, RhythmInit, RhythmFinalize, RhythmPrepare, RhythmUnprepare, RhythmProcess};
        MTAudioProcessingTapRef tap = NULL;
        OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
        if (status != noErr) continue;
        AVMutableAudioMixInputParameters *input = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        input.audioTapProcessor = tap;
        CFRelease(tap);
        [parameters addObject:input];
    }
    if (parameters.count) {
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = parameters;
        item.audioMix = mix;
        [_attached addObject:item];
    }
}
- (NSDictionary *)waveformEnabled:(BOOL)enabled {
    atomic_store(&control.visualizing, enabled);
    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:RH_WAVE];
    for (unsigned i=0; i<RH_WAVE; i++) [samples addObject:@(atomic_load(&control.wave[i])/32767.0)];
    return @{ @"samples": samples, @"supported": @(atomic_load(&control.supported)) };
}
@end
