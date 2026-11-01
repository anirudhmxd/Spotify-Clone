#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "../../third_party/just_audio/darwin/just_audio/Sources/just_audio/RhythmEqualizer.h"
#include <assert.h>

static double render(NSURL *url, BOOL cut) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    RhythmEqualizer *eq = [[RhythmEqualizer alloc] init];
    [eq setGains:(cut ? @[@0,@0,@-12,@0,@0] : @[@0,@0,@0,@0,@0]) enabled:YES];
    [eq waveformEnabled:YES];
    [eq attachToItem:item];
    assert(item.audioMix != nil);
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    assert(reader != nil);
    AVAssetReaderAudioMixOutput *output = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:[asset tracksWithMediaType:AVMediaTypeAudio] audioSettings:@{
        AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMIsFloatKey:@YES,
        AVLinearPCMBitDepthKey:@32, AVLinearPCMIsNonInterleaved:@NO,
        AVSampleRateKey:@48000, AVNumberOfChannelsKey:@1
    }];
    output.audioMix = item.audioMix;
    [reader addOutput:output];
    if (![reader startReading]) { NSLog(@"Start failed: %@",reader.error); return NAN; }
    double sum=0; unsigned long frames=0, count=0;
    CMSampleBufferRef buffer;
    while ((buffer=[output copyNextSampleBuffer])) {
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(buffer);
        size_t length=0; char *bytes=NULL;
        OSStatus status=CMBlockBufferGetDataPointer(block,0,NULL,&length,&bytes);
        assert(status==noErr);
        float *samples=(float *)bytes;
        for (unsigned i=0;i<length/sizeof(float);i++,frames++) {
            assert(isfinite(samples[i]));
            if (frames>48000) { sum+=samples[i]*samples[i]; count++; }
        }
        CFRelease(buffer);
    }
    if(reader.status!=AVAssetReaderStatusCompleted) NSLog(@"Reader error %@",reader.error);
    assert(reader.status==AVAssetReaderStatusCompleted);
    assert(atomic_load(&eq->control.supported));
    double peak=0;
    for(NSNumber *value in [eq waveformEnabled:NO][@"samples"]) peak+=fabs(value.doubleValue);
    assert(peak>0);
    return sqrt(sum/count);
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    double flat=render(url,NO),cut=render(url,YES),db=20*log10(cut/flat);
    printf("Apple audio-mix tap: measured %.2f dB at 910 Hz; waveform captured from rendered PCM.\n",db);
    assert(fabs(db+12)<.2);
} }
