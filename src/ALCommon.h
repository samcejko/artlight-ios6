// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define ALIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define ALLog(fmt, ...) NSLog((@"[Artlight] " fmt), ##__VA_ARGS__)

// Runs a block on the main thread (immediately if already there).
static inline void ALMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

extern NSString * const ALErrorDomain;
extern NSString * const ALThemeDidChangeNotification;
extern NSString * const ALSettingsDidChangeNotification;
extern NSString * const ALHostsDidChangeNotification;      // a host was added, removed or changed (main thread; object = the host or nil)
extern NSString * const ALBoxArtDidLoadNotification;       // userInfo: @"key" = "<host uuid>/<app id>"

// NSError codes in ALErrorDomain (host errors use the host's status_code as code, e.g. 403)
enum {
    ALErrorNetwork        = -1,
    ALErrorTLS            = -2,
    ALErrorCertificate    = -3,    // the host's certificate is not the one we paired with
    ALErrorTimeout        = -4,
    ALErrorCancelled      = -5,
    ALErrorBadResponse    = -6,
    ALErrorDNS            = -7,
    ALErrorConnect        = -8,
    ALErrorNotPaired      = -9,
    ALErrorPinWrong       = -10,
    ALErrorPairingBusy    = -11,   // another device is pairing with the host
    ALErrorStream         = -12,
};

NSError *ALMakeError(NSInteger code, NSString *message);

// Monotonic microseconds since an arbitrary point (mach_absolute_time based)
uint64_t ALMonotonicMicros(void);

// Hex (upper case) and back
NSString *ALHexString(NSData *data);
NSData *ALDataFromHex(NSString *hex);
