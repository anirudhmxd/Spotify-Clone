#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "RhythmDSP.h"

@interface RhythmEqualizer : NSObject {
@public RhythmControl control;
}
- (void)setGains:(NSArray<NSNumber *> *)gains enabled:(BOOL)enabled;
- (void)attachToItem:(AVPlayerItem *)item;
- (NSDictionary *)waveformEnabled:(BOOL)enabled;
@end
