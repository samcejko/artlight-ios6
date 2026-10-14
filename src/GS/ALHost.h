#import <Foundation/Foundation.h>

typedef enum {
    ALHostStateUnknown = 0,
    ALHostStateChecking,
    ALHostStateOnline,
    ALHostStateOffline,
} ALHostState;

// Apollo client permissions (the <Permission> bitmask of /serverinfo over HTTPS)
enum {
    ALPermInputController = 0x00000100,
    ALPermInputTouch      = 0x00000200,
    ALPermInputPen        = 0x00000400,
    ALPermInputMouse      = 0x00000800,
    ALPermInputKeyboard   = 0x00001000,
    ALPermClipboardSet    = 0x00010000,
    ALPermClipboardRead   = 0x00020000,
    ALPermFileUpload      = 0x00040000,
    ALPermFileDownload    = 0x00080000,
    ALPermServerCommand   = 0x00100000,
    ALPermList            = 0x01000000,
    ALPermView            = 0x02000000,
    ALPermLaunch          = 0x04000000,
};

// One app the host offers (a game, the desktop, Steam Big Picture...)
@interface ALApp : NSObject
@property (nonatomic, copy) NSString *appId;        // <ID>
@property (nonatomic, copy) NSString *title;        // <AppTitle>
@property (nonatomic, copy) NSString *uuid;         // <UUID> (Apollo)
@property (nonatomic) BOOL hdrSupported;
+ (instancetype)appWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionary;
@end

// A gaming PC (Sunshine or Apollo host). Kept by ALHostStore; changed on the main thread only.
@interface ALHost : NSObject

@property (nonatomic, copy) NSString *uuid;               // the host's <uniqueid>
@property (nonatomic, copy) NSString *name;               // <hostname>
@property (nonatomic, copy) NSString *manualAddress;      // typed in by the user
@property (nonatomic, copy) NSString *localAddress;       // <LocalIP>
@property (nonatomic, copy) NSString *mdnsAddress;        // found on the network
@property (nonatomic, copy) NSString *activeAddress;      // the one that answered last
@property (nonatomic) int httpPort;                       // 47989 unless typed as "address:port"
@property (nonatomic) int httpsPort;                      // <HttpsPort>, 47984
@property (nonatomic, copy) NSString *mac;                // for Wake-on-LAN (paired hosts only tell it)
@property (nonatomic, strong) NSData *serverCertificate;  // PEM from pairing; nil = not paired
@property (nonatomic) BOOL paired;                        // the host still accepts our certificate
@property (nonatomic, copy) NSString *appVersion;         // <appversion>, 4 numbers
@property (nonatomic, copy) NSString *gfeVersion;
@property (nonatomic) int codecModeSupport;               // <ServerCodecModeSupport>
@property (nonatomic, copy) NSString *currentGameId;      // "0" = nothing running
@property (nonatomic, copy) NSString *currentGameUUID;
@property (nonatomic) long long permission;               // Apollo; -1 = not told (Sunshine: everything allowed)
@property (nonatomic, copy) NSArray *serverCommands;      // Apollo <ServerCommand> names, in order
@property (nonatomic) BOOL virtualDisplayCapable;         // Apollo on Windows
@property (nonatomic) BOOL virtualDisplayReady;
@property (nonatomic, copy) NSArray *apps;                // ALApp, the last list we got
@property (nonatomic, strong) NSDate *lastSeen;

// Not saved
@property (nonatomic) ALHostState state;
@property (nonatomic, copy) NSString *lastError;

- (instancetype)initWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionary;

@property (nonatomic, readonly) BOOL isSunshine;          // Sunshine family (appversion's 4th number < 0)
@property (nonatomic, readonly) BOOL isApollo;            // Sunshine family that reports Apollo's extras
@property (nonatomic, readonly) int serverMajorVersion;
@property (nonatomic, readonly) BOOL isBusy;              // an app is running
@property (nonatomic, readonly) NSData *serverCertificateDER;
- (BOOL)hasPermission:(long long)bit;                     // YES when not Apollo or the bit is granted
- (NSArray *)candidateAddresses;                          // the addresses to try, the last good one first
- (NSString *)displayAddress;
- (ALApp *)appWithId:(NSString *)appId;

@end

// Every known host, saved in Library/Application Support/Artlight/hosts.plist. Main thread only.
@interface ALHostStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray *hosts;
- (ALHost *)hostWithUUID:(NSString *)uuid;
- (ALHost *)hostWithAddress:(NSString *)address;
- (void)addHost:(ALHost *)host;
- (void)removeHost:(ALHost *)host;
- (void)hostChanged:(ALHost *)host;       // saves and posts ALHostsDidChangeNotification
- (void)save;
@end
