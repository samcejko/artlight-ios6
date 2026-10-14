#import <Foundation/Foundation.h>
#import "ALHost.h"
#import "ALGameStream.h"
#import "ALInput.h"

@class ALStreamSession, ALVideoDecoder, ALAudioPlayer;

// Everything is called on the main thread
@protocol ALStreamSessionDelegate <NSObject>
- (void)streamSession:(ALStreamSession *)session status:(NSString *)status;      // progress while connecting
- (void)streamSessionDidConnect:(ALStreamSession *)session;
- (void)streamSession:(ALStreamSession *)session didEnd:(NSString *)message;     // failed to start or ended; nil = ended normally
- (void)streamSession:(ALStreamSession *)session connectionPoor:(BOOL)poor;
@end

// One stream: /launch (or /resume) over HTTPS, then moonlight-common-c (RTSP, ENet control, RTP video/audio,
// input) with our hardware decoder and audio player behind its callbacks. Only one can run at a time (the library
// keeps global state).
@interface ALStreamSession : NSObject

- (instancetype)initWithHost:(ALHost *)host app:(ALApp *)app options:(ALStreamOptions *)options;
@property (nonatomic, weak) id<ALStreamSessionDelegate> delegate;
@property (nonatomic, readonly) ALHost *host;
@property (nonatomic, readonly) ALApp *app;
@property (nonatomic, readonly) ALStreamOptions *options;
@property (nonatomic, readonly) ALVideoDecoder *decoder;
@property (nonatomic, readonly) ALAudioPlayer *audio;
@property (atomic, readonly) BOOL isConnected;

- (void)start;
// Ends the connection; the game keeps running on the PC (resume it later). Safe to call more than once.
- (void)stop;

// Input (ignored until connected; any thread)
- (void)sendGamepad:(ALGamepadState)state;
- (void)sendMouseMoveDX:(short)dx dy:(short)dy;
- (void)sendMousePositionX:(short)x y:(short)y referenceWidth:(short)w height:(short)h;
- (void)sendMouseButton:(int)button pressed:(BOOL)pressed;      // 1 left, 2 middle, 3 right
- (void)sendScroll:(short)amount;                               // 120 = one notch up
- (void)sendKey:(ALKeyStroke)key pressed:(BOOL)pressed;
- (void)tapKey:(ALKeyStroke)key;                                // press and release, with its modifiers
- (void)sendText:(NSString *)text;                              // UTF-8 text (characters with no key)
- (BOOL)sendTouch:(uint8_t)eventType pointer:(uint32_t)pointerId x:(float)x y:(float)y;   // normalized 0..1
@property (nonatomic, readonly) BOOL hostSupportsTouch;
- (void)requestKeyframe;
- (BOOL)runServerCommand:(NSInteger)index;                      // Apollo

- (NSString *)statsText;                                        // a few lines for the overlay
- (NSString *)debugDescription;

@end
