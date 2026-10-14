#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ALHost.h"

// What a stream asks the host for (filled from ALSettings by the caller)
@interface ALStreamOptions : NSObject
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int fps;
@property (nonatomic) int bitrateKbps;
@property (nonatomic) BOOL optimizeGameSettings;   // "sops"
@property (nonatomic) BOOL playAudioOnHost;        // localAudioPlayMode
@property (nonatomic) BOOL virtualDisplay;         // Apollo: a virtual monitor at our resolution
@property (nonatomic) int scaleFactor;             // Apollo: percent (100)
@property (nonatomic) BOOL gamepad;                // a virtual controller for the on-screen gamepad
+ (instancetype)fromSettings;
@end

// The answer of /launch or /resume: what LiStartConnection needs
@interface ALLaunchResult : NSObject
@property (nonatomic, copy) NSString *address;     // the host address that answered
@property (nonatomic, copy) NSString *rtspSessionUrl;
@property (nonatomic, strong) NSData *riKey;       // 16 bytes
@property (nonatomic) int riKeyId;
@property (nonatomic) BOOL resumed;
@end

// A request that is still running (pairing waits for the PIN on the host; launching waits for the game)
@interface ALTask : NSObject
- (void)cancel;
@property (atomic, readonly) BOOL isCancelled;
@end

// The GameStream HTTP calls. Work happens on background queues; every completion runs on the main thread, where the
// ALHost objects are updated.
@interface ALGameStream : NSObject

+ (NSString *)deviceName;                           // what the host shows for us ("iPad (Artlight)")

// /serverinfo through the host's addresses (HTTPS when paired, falling back to HTTP when the host forgot us)
+ (void)refreshHost:(ALHost *)host completion:(void (^)(NSError *error))completion;
// An address typed in or found on the network: the host it belongs to is created or updated (by its uniqueid)
+ (void)probeAddress:(NSString *)address manual:(BOOL)manual completion:(void (^)(ALHost *host, NSError *error))completion;

// Pairing. pin: 4 digits we made up and the user types on the host, or (Apollo) the one-time PIN from its web UI
// together with its passphrase. The first step waits until the PIN was entered on the host.
+ (ALTask *)pairHost:(ALHost *)host pin:(NSString *)pin otpPassphrase:(NSString *)passphrase completion:(void (^)(NSError *error))completion;
+ (NSString *)randomPin;
+ (void)unpairHost:(ALHost *)host completion:(void (^)(NSError *error))completion;

+ (void)fetchAppsForHost:(ALHost *)host completion:(void (^)(NSArray *apps, NSError *error))completion;
// Box art (PNG from the host), cached in memory and on disk; nil when the host has none
+ (UIImage *)cachedBoxArtForHost:(ALHost *)host app:(ALApp *)app;
+ (void)fetchBoxArtForHost:(ALHost *)host app:(ALApp *)app completion:(void (^)(UIImage *image))completion;

+ (ALTask *)launchApp:(ALApp *)app host:(ALHost *)host options:(ALStreamOptions *)options completion:(void (^)(ALLaunchResult *result, NSError *error))completion;
+ (void)quitAppOnHost:(ALHost *)host completion:(void (^)(NSError *error))completion;

// Apollo's clipboard (needs the clipboard permissions and a running stream)
+ (void)fetchClipboardFromHost:(ALHost *)host completion:(void (^)(NSString *text, NSError *error))completion;
+ (void)sendClipboard:(NSString *)text toHost:(ALHost *)host completion:(void (^)(NSError *error))completion;

// Wake-on-LAN magic packets (needs the MAC address, known once the host was seen while paired)
+ (BOOL)wakeHost:(ALHost *)host;

@end
