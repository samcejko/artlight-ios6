#import "ALStreamSession.h"
#import "ALVideoDecoder.h"
#import "ALAudioPlayer.h"
#import "ALCrypto.h"
#import "ALCommon.h"
#include "Limelight.h"
#include <arpa/inet.h>
#include <stdarg.h>

// moonlight-common-c has one connection at a time and calls plain C functions: they reach the session through this.
static ALStreamSession *gActive;
static NSLock *gLibLock;               // LiStartConnection and LiStopConnection never overlap

@interface ALStreamSession ()
@property (nonatomic, strong) ALHost *host;
@property (nonatomic, strong) ALApp *app;
@property (nonatomic, strong) ALStreamOptions *options;
@property (nonatomic, strong) ALVideoDecoder *decoder;
@property (nonatomic, strong) ALAudioPlayer *audio;
@property (atomic) BOOL isConnected;
@property (atomic) BOOL stopped;
@property (atomic) BOOL ended;
@property (nonatomic, strong) ALTask *launchTask;
- (void)finishWithMessage:(NSString *)message;
- (void)reportStatus:(NSString *)status;
@end

@implementation ALStreamSession {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    char _address[128];
    char _appVersion[48];
    char _gfeVersion[48];
    char _rtspUrl[256];
    BOOL _hasGfeVersion, _hasRtspUrl;
    // video bookkeeping (the library's decoder thread only)
    uint8_t *_frameBuffer;
    size_t _frameCapacity;
    int _lastFrameNumber;
    uint64_t _lastIdrRequestUs;
    // statistics (read on the main thread, written on the library threads: plain counters are fine)
    volatile uint64_t _framesReceived, _framesLost, _idrRequests;
    uint64_t _statsLastTime, _statsLastFrames, _statsLastDecoded;
    double _receiveFps, _decodeFps;
}

- (instancetype)initWithHost:(ALHost *)host app:(ALApp *)app options:(ALStreamOptions *)options
{
    if ((self = [super init])) {
        _host = host;
        _app = app;
        _options = options;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gLibLock = [[NSLock alloc] init]; });
    }
    return self;
}

- (void)dealloc
{
    free(_frameBuffer);
}

- (BOOL)hostSupportsTouch
{
    return self.isConnected && (LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0;
}

#pragma mark - Library callbacks

static int ALDrSetup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags)
{
    ALLog(@"Video: format 0x%x, %dx%d at %d fps", videoFormat, width, height, redrawRate);
    return (videoFormat & VIDEO_FORMAT_MASK_H264) ? 0 : -1;
}

static void ALDrStart(void) {}
static void ALDrStop(void) {}
static void ALDrCleanup(void) {}

static int ALDrSubmit(PDECODE_UNIT du)
{
    ALStreamSession *s = gActive;
    if (!s || !s->_decoder) return DR_OK;
    if (s->_lastFrameNumber && du->frameNumber > s->_lastFrameNumber + 1) s->_framesLost += (uint64_t)(du->frameNumber - s->_lastFrameNumber - 1);
    s->_lastFrameNumber = du->frameNumber;
    s->_framesReceived++;
    if ((size_t)du->fullLength > s->_frameCapacity) {
        size_t cap = (size_t)du->fullLength + 65536;
        uint8_t *nb = realloc(s->_frameBuffer, cap);
        if (!nb) return DR_NEED_IDR;
        s->_frameBuffer = nb;
        s->_frameCapacity = cap;
    }
    size_t off = 0;
    for (PLENTRY e = du->bufferList; e; e = e->next) {
        if (off + (size_t)e->length > s->_frameCapacity) break;
        memcpy(s->_frameBuffer + off, e->data, (size_t)e->length);
        off += (size_t)e->length;
    }
    BOOL keyframe = du->frameType == FRAME_TYPE_IDR;
    // the decoder lost its reference chain (a decode error or a backlog it threw away): only a keyframe helps
    if (s->_decoder.needsKeyframe && !keyframe) {
        uint64_t now = ALMonotonicMicros();
        if (now - s->_lastIdrRequestUs > 1000000) {
            s->_lastIdrRequestUs = now;
            s->_idrRequests++;
            LiRequestIdrFrame();
        }
    }
    [s->_decoder decodeAccessUnit:s->_frameBuffer length:off timestamp:du->rtpTimestamp keyframe:keyframe];
    return DR_OK;
}

static int ALArInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags)
{
    ALStreamSession *s = gActive;
    if (!s) return -1;
    return [s->_audio startWithSampleRate:opusConfig->sampleRate channels:opusConfig->channelCount streams:opusConfig->streams
                           coupledStreams:opusConfig->coupledStreams samplesPerFrame:opusConfig->samplesPerFrame mapping:opusConfig->mapping] ? 0 : -1;
}

static void ALArStart(void) {}
static void ALArStop(void) {}

static void ALArCleanup(void)
{
    ALStreamSession *s = gActive;
    if (s) [s->_audio stop];
}

static void ALArDecodeAndPlay(char *sampleData, int sampleLength)
{
    ALStreamSession *s = gActive;
    if (s) [s->_audio decodeAndPlay:(const unsigned char *)sampleData length:sampleLength];
}

static NSString *ALStageText(int stage)
{
    switch (stage) {
        case STAGE_PLATFORM_INIT: return L(@"Getting ready…");
        case STAGE_NAME_RESOLUTION: return L(@"Finding the PC…");
        case STAGE_AUDIO_STREAM_INIT: return L(@"Preparing the sound…");
        case STAGE_RTSP_HANDSHAKE: return L(@"Agreeing on the stream with the PC…");
        case STAGE_CONTROL_STREAM_INIT: return L(@"Opening the control channel…");
        case STAGE_VIDEO_STREAM_INIT: return L(@"Preparing the picture…");
        case STAGE_INPUT_STREAM_INIT: return L(@"Preparing the controls…");
        case STAGE_CONTROL_STREAM_START: return L(@"Connecting the control channel…");
        case STAGE_VIDEO_STREAM_START: return L(@"Starting the picture…");
        case STAGE_AUDIO_STREAM_START: return L(@"Starting the sound…");
        case STAGE_INPUT_STREAM_START: return L(@"Starting the controls…");
    }
    return [NSString stringWithUTF8String:LiGetStageName(stage)] ?: @"";
}

static void ALClStageStarting(int stage)
{
    ALStreamSession *s = gActive;
    [s reportStatus:ALStageText(stage)];
}

static void ALClStageComplete(int stage) {}

static void ALClStageFailed(int stage, int errorCode)
{
    ALStreamSession *s = gActive;
    char ports[128] = "";
    unsigned int flags = LiGetPortFlagsFromStage(stage);
    if (flags) LiStringifyPortFlags(flags, ", ", ports, sizeof(ports));
    NSString *message = [NSString stringWithFormat:L(@"Starting the stream failed at \"%s\" (error %d)."), LiGetStageName(stage), errorCode];
    if (ports[0]) message = [message stringByAppendingFormat:@" %@", [NSString stringWithFormat:L(@"Check that the PC's firewall lets these ports through: %s."), ports]];
    ALLog(@"Stage %d (%s) failed: %d", stage, LiGetStageName(stage), errorCode);
    [s finishWithMessage:message];
}

static void ALClConnectionStarted(void)
{
    ALStreamSession *s = gActive;
    s.isConnected = YES;
    ALLog(@"Connection started (host feature flags 0x%x)", LiGetHostFeatureFlags());
    ALMain(^{ [s.delegate streamSessionDidConnect:s]; });
}

static void ALClConnectionTerminated(int errorCode)
{
    ALStreamSession *s = gActive;
    NSString *message = nil;
    switch (errorCode) {
        case ML_ERROR_GRACEFUL_TERMINATION: message = nil; break;
        case ML_ERROR_NO_VIDEO_TRAFFIC: message = L(@"No picture arrived from the PC. Check that its firewall lets UDP ports 47998-48000 through."); break;
        case ML_ERROR_NO_VIDEO_FRAME: message = L(@"The connection is too unstable for the stream. Try a lower bitrate or move closer to the Wi-Fi router."); break;
        case ML_ERROR_UNEXPECTED_EARLY_TERMINATION: message = L(@"The PC ended the stream right after it started. Is the game or the PC's screen locked?"); break;
        case ML_ERROR_PROTECTED_CONTENT: message = L(@"The PC is showing protected content that cannot be streamed."); break;
        case ML_ERROR_FRAME_CONVERSION: message = L(@"The PC could not convert its picture for the stream (try another resolution)."); break;
        default: message = [NSString stringWithFormat:L(@"The connection to the PC was lost (error %d)."), errorCode]; break;
    }
    ALLog(@"Connection terminated: %d", errorCode);
    [s finishWithMessage:message];
}

static void ALClLogMessage(const char *format, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, format);
    vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    if (n) NSLog(@"[Artlight] mlc: %s", buf);
}

static void ALClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor) {}

static void ALClConnectionStatusUpdate(int status)
{
    ALStreamSession *s = gActive;
    ALMain(^{ [s.delegate streamSession:s connectionPoor:status == CONN_STATUS_POOR]; });
}

#pragma mark - Start / stop

- (void)reportStatus:(NSString *)status
{
    ALMain(^{ if (!self.ended) [self.delegate streamSession:self status:status]; });
}

- (void)finishWithMessage:(NSString *)message
{
    ALMain(^{
        if (self.ended) return;
        self.ended = YES;
        [self stop];
        [self.delegate streamSession:self didEnd:message];
    });
}

- (void)start
{
    ALCryptoInit();
    if (![ALVideoDecoder isAvailable]) {
        [self finishWithMessage:L(@"This device has no usable hardware video decoder (VideoToolbox).")];
        return;
    }
    if (gActive && gActive != self) [gActive stop];
    self.decoder = [[ALVideoDecoder alloc] init];
    self.audio = [[ALAudioPlayer alloc] init];
    [self reportStatus:self.host.isBusy && [self.host.currentGameId isEqualToString:self.app.appId] ? L(@"Resuming the game on the PC…") : L(@"Starting the game on the PC…")];
    __weak ALStreamSession *weakSelf = self;
    self.launchTask = [ALGameStream launchApp:self.app host:self.host options:self.options completion:^(ALLaunchResult *result, NSError *error) {
        ALStreamSession *s = weakSelf;
        if (!s || s.stopped) return;
        if (!result) {
            [s finishWithMessage:error.localizedDescription ?: L(@"The PC could not start the game.")];
            return;
        }
        [s connectWithLaunch:result];
    }];
}

- (void)connectWithLaunch:(ALLaunchResult *)launch
{
    strlcpy(_address, [launch.address UTF8String] ?: "", sizeof(_address));
    strlcpy(_appVersion, [self.host.appVersion UTF8String] ?: "7.1.431.-1", sizeof(_appVersion));
    _hasGfeVersion = self.host.gfeVersion.length > 0;
    if (_hasGfeVersion) strlcpy(_gfeVersion, [self.host.gfeVersion UTF8String], sizeof(_gfeVersion));
    _hasRtspUrl = launch.rtspSessionUrl.length > 0;
    if (_hasRtspUrl) strlcpy(_rtspUrl, [launch.rtspSessionUrl UTF8String], sizeof(_rtspUrl));

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _address;
    _serverInfo.serverInfoAppVersion = _appVersion;
    _serverInfo.serverInfoGfeVersion = _hasGfeVersion ? _gfeVersion : NULL;
    _serverInfo.rtspSessionUrl = _hasRtspUrl ? _rtspUrl : NULL;
    _serverInfo.serverCodecModeSupport = self.host.codecModeSupport;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = self.options.width;
    _streamConfig.height = self.options.height;
    _streamConfig.fps = self.options.fps;
    _streamConfig.bitrate = self.options.bitrateKbps;
    _streamConfig.packetSize = 1392;
    _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    _streamConfig.supportedVideoFormats = VIDEO_FORMAT_H264;
    _streamConfig.clientRefreshRateX100 = 6000;
    _streamConfig.colorSpace = COLORSPACE_REC_601;
    _streamConfig.colorRange = COLOR_RANGE_LIMITED;
    // the hosts encrypt on the LAN only when told to; then we can decrypt everything (AES-GCM in software is cheap
    // next to the decoder at these bitrates)
    _streamConfig.encryptionFlags = ENCFLG_ALL;
    memcpy(_streamConfig.remoteInputAesKey, launch.riKey.bytes, 16);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    uint32_t keyId = htonl((uint32_t)launch.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &keyId, sizeof(keyId));

    gActive = self;
    [self reportStatus:L(@"Connecting to the stream…")];
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(libraryThread) object:nil];
    thread.name = @"artlight-connect";
    [thread start];
}

- (void)libraryThread
{
    @autoreleasepool {
        DECODER_RENDERER_CALLBACKS dr;
        LiInitializeVideoCallbacks(&dr);
        dr.setup = ALDrSetup;
        dr.start = ALDrStart;
        dr.stop = ALDrStop;
        dr.cleanup = ALDrCleanup;
        dr.submitDecodeUnit = ALDrSubmit;
        dr.capabilities = 0;

        AUDIO_RENDERER_CALLBACKS ar;
        LiInitializeAudioCallbacks(&ar);
        ar.init = ALArInit;
        ar.start = ALArStart;
        ar.stop = ALArStop;
        ar.cleanup = ALArCleanup;
        ar.decodeAndPlaySample = ALArDecodeAndPlay;
        // 10 ms audio packets (half the packet rate of 5 ms ones) suit the A5
        ar.capabilities = CAPABILITY_SLOW_OPUS_DECODER | CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

        CONNECTION_LISTENER_CALLBACKS cl;
        LiInitializeConnectionCallbacks(&cl);
        cl.stageStarting = ALClStageStarting;
        cl.stageComplete = ALClStageComplete;
        cl.stageFailed = ALClStageFailed;
        cl.connectionStarted = ALClConnectionStarted;
        cl.connectionTerminated = ALClConnectionTerminated;
        cl.logMessage = ALClLogMessage;
        cl.rumble = ALClRumble;
        cl.connectionStatusUpdate = ALClConnectionStatusUpdate;

        [gLibLock lock];
        if (!self.stopped) {
            ALLog(@"LiStartConnection to %s (app version %s, rtsp %s)", _address, _appVersion, _hasRtspUrl ? _rtspUrl : "-");
            int rc = LiStartConnection(&_serverInfo, &_streamConfig, &cl, &dr, &ar, NULL, 0, NULL, 0);
            if (rc != 0) ALLog(@"LiStartConnection failed: %d", rc);
            if (rc != 0 && !self.ended) [self finishWithMessage:[NSString stringWithFormat:L(@"The stream could not start (error %d)."), rc]];
        }
        [gLibLock unlock];
    }
}

- (void)stop
{
    if (self.stopped) return;
    self.stopped = YES;
    [self.launchTask cancel];
    LiInterruptConnection();
    ALVideoDecoder *decoder = self.decoder;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [gLibLock lock];
        if (gActive == self) {
            LiStopConnection();
            self.isConnected = NO;
        }
        [gLibLock unlock];
        [decoder invalidate];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gActive == self) gActive = nil;
        });
    });
}

#pragma mark - Input

- (void)sendGamepad:(ALGamepadState)st
{
    if (!self.isConnected) return;
    LiSendMultiControllerEvent(0, 0x1, st.buttons, st.leftTrigger, st.rightTrigger, st.leftX, st.leftY, st.rightX, st.rightY);
}

- (void)sendMouseMoveDX:(short)dx dy:(short)dy
{
    if (self.isConnected && (dx || dy)) LiSendMouseMoveEvent(dx, dy);
}

- (void)sendMousePositionX:(short)x y:(short)y referenceWidth:(short)w height:(short)h
{
    if (self.isConnected) LiSendMousePositionEvent(x, y, w, h);
}

- (void)sendMouseButton:(int)button pressed:(BOOL)pressed
{
    if (self.isConnected) LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, button);
}

- (void)sendScroll:(short)amount
{
    if (self.isConnected && amount) LiSendHighResScrollEvent(amount);
}

- (void)sendKey:(ALKeyStroke)key pressed:(BOOL)pressed
{
    if (!self.isConnected || !key.keycode) return;
    LiSendKeyboardEvent((short)(0x8000 | key.keycode), pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP, (char)key.modifiers);
}

- (void)tapKey:(ALKeyStroke)key
{
    if (!self.isConnected || !key.keycode) return;
    ALKeyStroke shift = [ALInput keyNamed:@"shift"], ctrl = [ALInput keyNamed:@"ctrl"], alt = [ALInput keyNamed:@"alt"], win = [ALInput keyNamed:@"win"];
    if (key.modifiers & ALModCtrl) [self sendKey:ctrl pressed:YES];
    if (key.modifiers & ALModAlt) [self sendKey:alt pressed:YES];
    if (key.modifiers & ALModShift) [self sendKey:shift pressed:YES];
    if (key.modifiers & ALModMeta) [self sendKey:win pressed:YES];
    [self sendKey:key pressed:YES];
    [self sendKey:key pressed:NO];
    if (key.modifiers & ALModMeta) [self sendKey:win pressed:NO];
    if (key.modifiers & ALModShift) [self sendKey:shift pressed:NO];
    if (key.modifiers & ALModAlt) [self sendKey:alt pressed:NO];
    if (key.modifiers & ALModCtrl) [self sendKey:ctrl pressed:NO];
}

- (void)sendText:(NSString *)text
{
    if (!self.isConnected || !text.length) return;
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    LiSendUtf8TextEvent(utf8.bytes, (unsigned int)utf8.length);
}

- (BOOL)sendTouch:(uint8_t)eventType pointer:(uint32_t)pointerId x:(float)x y:(float)y
{
    if (!self.isConnected) return NO;
    return LiSendTouchEvent(eventType, pointerId, x, y, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN) == 0;
}

- (void)requestKeyframe
{
    if (self.isConnected) LiRequestIdrFrame();
}

- (BOOL)runServerCommand:(NSInteger)index
{
    if (!self.isConnected || index < 0 || index > 255) return NO;
    return LiSendExecServerCmd((uint8_t)index) == 0;
}

#pragma mark - Statistics

- (NSString *)statsText
{
    uint64_t now = ALMonotonicMicros();
    uint64_t frames = _framesReceived, decoded = self.decoder.decodedFrames;
    if (_statsLastTime && now > _statsLastTime) {
        double dt = (now - _statsLastTime) / 1e6;
        if (dt >= 0.5) {
            _receiveFps = (frames - _statsLastFrames) / dt;
            _decodeFps = (decoded - _statsLastDecoded) / dt;
            _statsLastTime = now;
            _statsLastFrames = frames;
            _statsLastDecoded = decoded;
        }
    } else {
        _statsLastTime = now;
        _statsLastFrames = frames;
        _statsLastDecoded = decoded;
    }
    uint32_t rtt = 0, rttVar = 0;
    if (self.isConnected) LiGetEstimatedRttInfo(&rtt, &rttVar);
    const RTP_VIDEO_STATS *vs = self.isConnected ? LiGetRTPVideoStats() : NULL;
    return [NSString stringWithFormat:@"%dx%d  net %.0f fps  dec %.0f fps\nrtt %u ms  lost frames %llu  idr %llu\ndecode %.1f ms  err %llu  drop %llu\nfec ok %u  fail %u\naudio %ld ms  under %llu  conceal %llu",
            self.options.width, self.options.height, _receiveFps, _decodeFps,
            rtt, _framesLost, _idrRequests,
            self.decoder.averageDecodeMs, self.decoder.errors, self.decoder.droppedInputs,
            vs ? vs->packetCountFecRecovered : 0, vs ? vs->packetCountFecFailed : 0,
            (long)self.audio.bufferedMs, self.audio.underruns, self.audio.concealed];
}

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"stream %@ app %@ connected=%d frames=%llu lost=%llu decoded=%llu errors=%llu dropped=%llu decodeMs=%.1f audioDecoded=%llu concealed=%llu underruns=%llu audioDropped=%llu bufferedMs=%ld",
            self.host.name, self.app.title, self.isConnected, _framesReceived, _framesLost, self.decoder.decodedFrames, self.decoder.errors,
            self.decoder.droppedInputs, self.decoder.averageDecodeMs, self.audio.decoded, self.audio.concealed, self.audio.underruns,
            self.audio.dropped, (long)self.audio.bufferedMs];
}

@end
