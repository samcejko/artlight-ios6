#import <Foundation/Foundation.h>

// The stream's sound: Opus (multistream, as GameStream sends it) decoded with libopus (fixed point) into a PCM
// ring that a RemoteIO unit plays. moonlight-common-c has already put the packets in order (and recovered lost
// ones with FEC when it could); a NULL packet means one was lost for good and Opus conceals it.
@interface ALAudioPlayer : NSObject

// channelMapping: channelCount bytes. Returns NO when Opus or the audio unit cannot be set up.
- (BOOL)startWithSampleRate:(int)sampleRate channels:(int)channels streams:(int)streams coupledStreams:(int)coupled
            samplesPerFrame:(int)samplesPerFrame mapping:(const unsigned char *)mapping;
- (void)decodeAndPlay:(const unsigned char *)data length:(int)length;   // any thread (the library's audio thread)
- (void)stop;

@property (nonatomic, readonly) NSInteger bufferedMs;
@property (nonatomic, readonly) uint64_t decoded;
@property (nonatomic, readonly) uint64_t concealed;
@property (nonatomic, readonly) uint64_t underruns;
@property (nonatomic, readonly) uint64_t dropped;        // frames thrown away because the ring ran long

@end
