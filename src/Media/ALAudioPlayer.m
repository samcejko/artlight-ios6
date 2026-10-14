#import "ALAudioPlayer.h"
#import "ALCommon.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <opus_multistream.h>

#define OUT_CHANNELS 2
#define RING_SECONDS_DIV 3                      // 333 ms of PCM
#define MAX_BUFFER_MS 120                       // above this the newest audio is dropped to catch up
#define MAX_FRAME_SAMPLES 5760                  // 120 ms at 48 kHz, Opus' largest frame

@interface ALAudioPlayer ()
@property (nonatomic) uint64_t decoded;
@property (nonatomic) uint64_t concealed;
@property (nonatomic) uint64_t underruns;
@property (nonatomic) uint64_t dropped;
@end

@implementation ALAudioPlayer {
    AudioComponentInstance _unit;
    OpusMSDecoder *_decoder;
    int _sampleRate, _channels, _samplesPerFrame;
    int16_t *_pcm;                              // decode buffer (channels interleaved)
    int16_t *_ring;                             // stereo interleaved
    uint32_t _ringFrames;
    volatile uint32_t _ringWrite, _ringRead;    // in frames, modulo _ringFrames
    BOOL _running;
    volatile BOOL _primed;
    uint32_t _fadeFrames;
}

- (void)dealloc
{
    [self stop];
}

- (NSInteger)bufferedMs
{
    if (!_ringFrames || !_sampleRate) return 0;
    uint32_t w = _ringWrite, r = _ringRead;
    return ((w + _ringFrames - r) % _ringFrames) * 1000 / (uint32_t)_sampleRate;
}

static OSStatus ALAudioRender(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    ALAudioPlayer *self = (__bridge ALAudioPlayer *)inRefCon;
    int16_t *out = ioData->mBuffers[0].mData;
    uint32_t size = self->_ringFrames;
    uint32_t w = self->_ringWrite, r = self->_ringRead;
    __sync_synchronize();   // (the samples written before the index became visible: arm64 reorders otherwise)
    uint32_t available = (w + size - r) % size;
    // after a start or an underrun, wait for a small cushion (40 ms) so Wi-Fi jitter does not crackle
    if (!self->_primed) {
        if (available < (uint32_t)(self->_sampleRate / 25)) {
            memset(out, 0, inNumberFrames * OUT_CHANNELS * sizeof(int16_t));
            return noErr;
        }
        self->_primed = YES;
    }
    uint32_t n = inNumberFrames < available ? inNumberFrames : available;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (r + i) % size;
        out[2 * i] = self->_ring[2 * idx];
        out[2 * i + 1] = self->_ring[2 * idx + 1];
    }
    if (n < inNumberFrames) {
        memset(out + 2 * n, 0, (inNumberFrames - n) * OUT_CHANNELS * sizeof(int16_t));
        if (available == 0) { self->_underruns++; self->_primed = NO; }
    }
    __sync_synchronize();
    self->_ringRead = (r + n) % size;
    return noErr;
}

- (BOOL)startWithSampleRate:(int)sampleRate channels:(int)channels streams:(int)streams coupledStreams:(int)coupled
            samplesPerFrame:(int)samplesPerFrame mapping:(const unsigned char *)mapping
{
    [self stop];
    if (channels < 1 || channels > 8 || sampleRate <= 0) return NO;
    int err = 0;
    _decoder = opus_multistream_decoder_create(sampleRate, channels, streams, coupled, mapping, &err);
    if (err != OPUS_OK || !_decoder) { ALLog(@"Audio: opus decoder failed (%d)", err); _decoder = NULL; return NO; }
    _sampleRate = sampleRate;
    _channels = channels;
    _samplesPerFrame = samplesPerFrame > 0 ? samplesPerFrame : 240;
    _pcm = calloc((size_t)MAX_FRAME_SAMPLES * (size_t)channels, sizeof(int16_t));
    _ringFrames = (uint32_t)(sampleRate / RING_SECONDS_DIV);
    _ring = calloc(_ringFrames * OUT_CHANNELS, sizeof(int16_t));
    _ringWrite = _ringRead = 0;
    _fadeFrames = 0;
    _primed = NO;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [session setPreferredSampleRate:sampleRate error:nil];
    [session setPreferredIOBufferDuration:0.01 error:nil];
    [session setActive:YES error:&error];
    if (error) ALLog(@"Audio: session error %@", error.localizedDescription);

    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &_unit) != noErr) { ALLog(@"Audio: no RemoteIO"); _unit = NULL; return NO; }
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = OUT_CHANNELS;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = OUT_CHANNELS * 2;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = OUT_CHANNELS * 2;
    OSStatus st = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (st != noErr) ALLog(@"Audio: stream format failed (%d)", (int)st);
    AURenderCallbackStruct cb = { ALAudioRender, (__bridge void *)self };
    AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (AudioUnitInitialize(_unit) != noErr || AudioOutputUnitStart(_unit) != noErr) {
        ALLog(@"Audio: unit start failed");
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
        return NO;
    }
    _running = YES;
    ALLog(@"Audio: %d Hz, %d channels (%d streams, %d coupled), %d samples per packet, RemoteIO at %.0f Hz",
          sampleRate, channels, streams, coupled, _samplesPerFrame, session.sampleRate);
    return YES;
}

- (void)stop
{
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
    }
    _running = NO;
    if (_decoder) { opus_multistream_decoder_destroy(_decoder); _decoder = NULL; }
    free(_pcm); _pcm = NULL;
    free(_ring); _ring = NULL;
    _ringFrames = 0;
}

- (void)decodeAndPlay:(const unsigned char *)data length:(int)length
{
    if (!_running || !_decoder) return;
    int frames;
    if (data && length > 0) {
        frames = opus_multistream_decode(_decoder, data, length, _pcm, MAX_FRAME_SAMPLES, 0);
        if (frames > 0) self.decoded++;
    } else {
        frames = opus_multistream_decode(_decoder, NULL, 0, _pcm, _samplesPerFrame, 0);
        self.concealed++;
    }
    if (frames <= 0) return;
    uint32_t size = _ringFrames;
    uint32_t w = _ringWrite, r = _ringRead;
    __sync_synchronize();
    uint32_t buffered = (w + size - r) % size;
    if (buffered > (uint32_t)(_sampleRate * MAX_BUFFER_MS / 1000) || buffered + (uint32_t)frames >= size - 1) {
        self.dropped++;   // running long (a burst after a stall): skip this packet to get the latency back
        return;
    }
    for (int i = 0; i < frames; i++) {
        int16_t left, right;
        if (_channels == 1) { left = right = _pcm[i]; }
        else { left = _pcm[i * _channels]; right = _pcm[i * _channels + 1]; }
        if (_fadeFrames < 4800) {   // a 100 ms fade-in: no click at the start
            float g = (float)_fadeFrames / 4800.0f;
            left = (int16_t)(left * g);
            right = (int16_t)(right * g);
            _fadeFrames++;
        }
        uint32_t idx = (w + (uint32_t)i) % size;
        _ring[2 * idx] = left;
        _ring[2 * idx + 1] = right;
    }
    __sync_synchronize();   // (the samples before the index: the render callback on the other core reads them in that order)
    _ringWrite = (w + (uint32_t)frames) % size;
}

@end
