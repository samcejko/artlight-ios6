#import "ALGameStream.h"
#import "ALNvHTTP.h"
#import "ALCrypto.h"
#import "ALSettings.h"
#import "ALUtils.h"
#import "ALCommon.h"
#include "Limelight.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Moonlight clients all send this fixed id: Sunshine and Apollo tell clients apart by their certificates
static NSString * const kUniqueId = @"0123456789ABCDEF";

#pragma mark - Small types

@implementation ALStreamOptions

+ (instancetype)fromSettings
{
    ALStreamOptions *o = [[ALStreamOptions alloc] init];
    CGSize size = [ALSettings streamSize];
    o.width = (int)size.width;
    o.height = (int)size.height;
    o.fps = (int)[ALSettings streamFps];
    o.bitrateKbps = (int)[ALSettings bitrateKbps];
    o.optimizeGameSettings = [ALSettings optimizeGameSettings];
    o.playAudioOnHost = [ALSettings playAudioOnHost];
    o.virtualDisplay = [ALSettings virtualDisplay];
    o.scaleFactor = 100;
    o.gamepad = YES;
    return o;
}

@end

@implementation ALLaunchResult
@end

@interface ALTask ()
@property (atomic) BOOL isCancelled;
@property (atomic, strong) ALNvRequest *current;
@end

@implementation ALTask
- (void)cancel
{
    self.isCancelled = YES;
    [self.current cancel];
}
@end

#pragma mark - Helpers

static dispatch_queue_t ALWorkQueue(void)
{
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
}

static NSString *ALQuery(NSString *extra)
{
    CFUUIDRef u = CFUUIDCreate(NULL);
    NSString *uuid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, u);
    CFRelease(u);
    NSString *base = [NSString stringWithFormat:@"uniqueid=%@&uuid=%@", kUniqueId, uuid];
    return extra.length ? [base stringByAppendingFormat:@"&%@", extra] : base;
}

// One request, blocking. Returns the body; status receives the HTTP status.
static NSData *ALRun(NSString *address, int port, BOOL tls, NSData *pinned, NSString *path, NSTimeInterval readTimeout,
                     ALTask *task, NSInteger *status, NSError **error)
{
    if (task.isCancelled) { if (error) *error = ALMakeError(ALErrorCancelled, L(@"Cancelled.")); return nil; }
    ALNvRequest *r = [[ALNvRequest alloc] initWithAddress:address port:port tls:tls pathAndQuery:path];
    r.pinnedCertificate = pinned;
    r.readTimeout = readTimeout;
    r.connectTimeout = 4;
    task.current = r;
    if (task.isCancelled) [r cancel];
    NSData *body = [r runWithStatus:status error:error];
    task.current = nil;
    return body;
}

// An XML answer with status 200, else nil + error
static ALNvXML *ALRunXML(NSString *address, int port, BOOL tls, NSData *pinned, NSString *path, NSTimeInterval readTimeout,
                         ALTask *task, NSError **error)
{
    NSInteger status = 0;
    NSData *body = ALRun(address, port, tls, pinned, path, readTimeout, task, &status, error);
    if (!body) return nil;
    ALNvXML *x = [ALNvXML parse:body];
    if (!x) {
        if (error) *error = ALMakeError(status >= 400 ? status : ALErrorBadResponse,
                                        status >= 400 ? [NSString stringWithFormat:L(@"The host answered with error %ld."), (long)status] : L(@"The host sent an answer Artlight does not understand."));
        return nil;
    }
    NSError *e = [x statusError];
    if (e) { if (error) *error = e; return nil; }
    return x;
}

static BOOL ALIsNetworkError(NSError *e)
{
    return e.code == ALErrorConnect || e.code == ALErrorTimeout || e.code == ALErrorDNS || e.code == ALErrorNetwork;
}

// "1.2.3.4", "1.2.3.4:47989", "pc.local:47989", "[fe80::1]:47989" -> address + port
static void ALSplitAddress(NSString *text, NSString **address, int *port)
{
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    *port = 47989;
    if ([s hasPrefix:@"["]) {
        NSRange close = [s rangeOfString:@"]"];
        if (close.location != NSNotFound) {
            *address = [s substringWithRange:NSMakeRange(1, close.location - 1)];
            NSString *rest = [s substringFromIndex:close.location + 1];
            if ([rest hasPrefix:@":"] && [[rest substringFromIndex:1] intValue] > 0) *port = [[rest substringFromIndex:1] intValue];
            return;
        }
    }
    NSArray *parts = [s componentsSeparatedByString:@":"];
    if (parts.count == 2 && [parts[1] intValue] > 0) {
        *address = parts[0];
        *port = [parts[1] intValue];
        return;
    }
    *address = s;
}

// What /serverinfo said, applied on the main thread
static void ALApplyServerInfo(ALHost *host, ALNvXML *x, NSString *address, BOOL viaHTTPS)
{
    NSString *v;
    if ((v = [x string:@"uniqueid"]).length && !host.uuid.length) host.uuid = v;
    if ((v = [x string:@"hostname"]).length) host.name = v;
    if ((v = [x string:@"appversion"]).length) host.appVersion = v;
    host.gfeVersion = [x string:@"GfeVersion"];
    if ([[x string:@"HttpsPort"] intValue] > 0) host.httpsPort = [[x string:@"HttpsPort"] intValue];
    v = [x string:@"mac"];
    if (v.length && ![v isEqualToString:@"00:00:00:00:00:00"]) host.mac = v;
    v = [x string:@"LocalIP"];
    if (v.length && ![v isEqualToString:@"127.0.0.1"]) host.localAddress = v;
    host.codecModeSupport = [[x string:@"ServerCodecModeSupport"] intValue];
    NSString *state = [x string:@"state"] ?: @"";
    host.currentGameId = [state hasSuffix:@"_SERVER_BUSY"] ? ([x string:@"currentgame"] ?: @"0") : @"0";
    host.currentGameUUID = [x string:@"currentgameuuid"];
    if (viaHTTPS) {
        host.paired = YES;
        NSString *perm = [x string:@"Permission"];
        host.permission = perm.length ? [perm longLongValue] : -1;
        host.serverCommands = [x strings:@"ServerCommand"];
        host.virtualDisplayCapable = [[x string:@"VirtualDisplayCapable"] isEqualToString:@"true"];
        host.virtualDisplayReady = [[x string:@"VirtualDisplayDriverReady"] isEqualToString:@"true"];
    } else if (!host.serverCertificate) {
        host.paired = NO;
    }
    host.activeAddress = address;
    host.state = ALHostStateOnline;
    host.lastError = nil;
    host.lastSeen = [NSDate date];
}

@implementation ALGameStream

+ (NSString *)deviceName
{
    return [NSString stringWithFormat:@"%@ (Artlight)", [UIDevice currentDevice].model ?: @"iOS"];
}

#pragma mark - Server info

+ (void)refreshHost:(ALHost *)host completion:(void (^)(NSError *error))completion
{
    NSArray *addresses = [host candidateAddresses];
    int httpPort = host.httpPort, httpsPort = host.httpsPort;
    NSData *pinned = host.paired || host.serverCertificate ? host.serverCertificateDER : nil;
    NSString *uuid = host.uuid;
    if (host.state != ALHostStateOnline) host.state = ALHostStateChecking;
    dispatch_async(ALWorkQueue(), ^{
        ALNvXML *result = nil;
        NSString *good = nil;
        BOOL viaHTTPS = NO, forgotten = NO;
        NSError *lastError = nil;
        for (NSString *address in addresses) {
            NSError *e = nil;
            ALNvXML *x = nil;
            if (pinned) {
                x = ALRunXML(address, httpsPort, YES, pinned, [@"/serverinfo?" stringByAppendingString:ALQuery(nil)], 6, nil, &e);
                if (x) viaHTTPS = YES;
                else if (e.code == ALErrorCertificate || e.code == 401 || e.code == ALErrorTLS) {
                    // the host does not know our certificate any more (or is another machine): ask over HTTP
                    forgotten = e.code != ALErrorTLS;
                    e = nil;
                    x = ALRunXML(address, httpPort, NO, nil, [@"/serverinfo?" stringByAppendingString:ALQuery(nil)], 6, nil, &e);
                }
            } else {
                x = ALRunXML(address, httpPort, NO, nil, [@"/serverinfo?" stringByAppendingString:ALQuery(nil)], 6, nil, &e);
            }
            if (x) {
                NSString *theirs = [x string:@"uniqueid"];
                if (uuid.length && theirs.length && ![theirs isEqualToString:uuid]) {
                    lastError = ALMakeError(ALErrorConnect, [NSString stringWithFormat:L(@"Another PC answers at %@."), address]);
                    continue;
                }
                result = x;
                good = address;
                break;
            }
            lastError = e;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) {
                if (forgotten && !viaHTTPS) { host.paired = NO; host.serverCertificate = nil; }
                ALApplyServerInfo(host, result, good, viaHTTPS);
                [[ALHostStore shared] hostChanged:host];
                if (completion) completion(nil);
            } else {
                host.state = ALHostStateOffline;
                host.lastError = lastError.localizedDescription;
                host.currentGameId = @"0";
                [[NSNotificationCenter defaultCenter] postNotificationName:ALHostsDidChangeNotification object:host];
                if (completion) completion(lastError ?: ALMakeError(ALErrorConnect, L(@"The PC has no address yet.")));
            }
        });
    });
}

+ (void)probeAddress:(NSString *)text manual:(BOOL)manual completion:(void (^)(ALHost *host, NSError *error))completion
{
    NSString *address = nil;
    int port = 47989;
    ALSplitAddress(text, &address, &port);
    if (!address.length) { if (completion) completion(nil, ALMakeError(ALErrorDNS, L(@"Type the PC's address."))); return; }
    dispatch_async(ALWorkQueue(), ^{
        NSError *e = nil;
        ALNvXML *x = ALRunXML(address, port, NO, nil, [@"/serverinfo?" stringByAppendingString:ALQuery(nil)], 6, nil, &e);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!x) { if (completion) completion(nil, e); return; }
            NSString *uuid = [x string:@"uniqueid"];
            if (!uuid.length) { if (completion) completion(nil, ALMakeError(ALErrorBadResponse, L(@"This does not look like a Sunshine or Apollo PC."))); return; }
            ALHostStore *store = [ALHostStore shared];
            ALHost *host = [store hostWithUUID:uuid];
            BOOL isNew = host == nil;
            if (isNew) { host = [[ALHost alloc] init]; host.uuid = uuid; }
            if (manual) host.manualAddress = address;
            else host.mdnsAddress = address;
            host.httpPort = port;
            ALApplyServerInfo(host, x, address, NO);
            if (isNew) [store addHost:host];
            else [store hostChanged:host];
            // a paired host also tells its permissions, commands and running game over HTTPS
            if (host.serverCertificate) [self refreshHost:host completion:nil];
            if (completion) completion(host, nil);
        });
    });
}

#pragma mark - Pairing

+ (NSString *)randomPin
{
    NSData *r = ALRandomBytes(4);
    const uint8_t *b = r.bytes;
    return [NSString stringWithFormat:@"%d%d%d%d", b[0] % 10, b[1] % 10, b[2] % 10, b[3] % 10];
}

+ (ALTask *)pairHost:(ALHost *)host pin:(NSString *)pin otpPassphrase:(NSString *)passphrase completion:(void (^)(NSError *error))completion
{
    ALTask *task = [[ALTask alloc] init];
    NSString *address = host.activeAddress ?: [[host candidateAddresses] firstObject];
    int httpPort = host.httpPort, httpsPort = host.httpsPort;
    BOOL sha256 = host.serverMajorVersion >= 7 || host.serverMajorVersion == 0;
    NSString *device = [ALUtils urlEncode:[self deviceName]];
    ALIdentity *identity = [ALIdentity shared];
    dispatch_async(ALWorkQueue(), ^{
        NSError *error = nil;
        NSData *serverPEM = nil;
        NSData *(^hash)(NSData *) = ^NSData *(NSData *d) { return sha256 ? ALSHA256(d) : ALSHA1(d); };
        NSUInteger hashLen = sha256 ? 32 : 20;
        NSString *pairBase = [@"/pair?" stringByAppendingString:ALQuery([NSString stringWithFormat:@"devicename=%@&updateState=1", device])];
        BOOL started = NO;
        do {
            if (!address.length) { error = ALMakeError(ALErrorConnect, L(@"The PC has no address yet.")); break; }
            if (!identity.isReady) { error = ALMakeError(ALErrorTLS, L(@"The client certificate is not ready yet.")); break; }
            // 1. our certificate and the salt; the host answers once the PIN was typed there (or at once with an OTP)
            NSData *salt = ALRandomBytes(16);
            NSString *saltHex = ALHexString(salt);
            NSMutableData *saltedPin = [salt mutableCopy];
            [saltedPin appendData:[pin dataUsingEncoding:NSUTF8StringEncoding]];
            NSData *aesKey = [hash(saltedPin) subdataWithRange:NSMakeRange(0, 16)];
            NSMutableString *args = [NSMutableString stringWithFormat:@"&phrase=getservercert&salt=%@&clientcert=%@", saltHex, ALHexString(identity.certificatePEM)];
            if (passphrase.length) {
                NSString *otp = [NSString stringWithFormat:@"%@%@%@", pin, saltHex, passphrase];
                [args appendFormat:@"&otpauth=%@", ALHexString(ALSHA256([otp dataUsingEncoding:NSUTF8StringEncoding]))];
            }
            started = YES;
            ALNvXML *x = ALRunXML(address, httpPort, NO, nil, [pairBase stringByAppendingString:args], 0, task, &error);
            if (!x) break;
            if (![[x string:@"paired"] isEqualToString:@"1"]) { error = ALMakeError(ALErrorBadResponse, L(@"The PC refused to pair.")); break; }
            NSString *plain = [x string:@"plaincert"];
            if (!plain.length) { error = ALMakeError(ALErrorPairingBusy, L(@"Another device is pairing with this PC right now. Try again in a moment.")); break; }
            serverPEM = ALDataFromHex(plain);
            ALCertificate *serverCert = [ALCertificate certificateWithData:serverPEM];
            if (!serverCert) { error = ALMakeError(ALErrorBadResponse, L(@"The PC sent a certificate Artlight cannot read.")); break; }

            // 2. our challenge
            NSData *challenge = ALRandomBytes(16);
            x = ALRunXML(address, httpPort, NO, nil, [pairBase stringByAppendingFormat:@"&clientchallenge=%@", ALHexString(ALAESECB(challenge, aesKey, YES))], 15, task, &error);
            if (!x) break;
            if (![[x string:@"paired"] isEqualToString:@"1"]) { error = ALMakeError(ALErrorBadResponse, L(@"The PC refused to pair.")); break; }
            NSData *response = ALAESECB(ALDataFromHex([x string:@"challengeresponse"] ?: @""), aesKey, NO);
            if (response.length < hashLen + 16) { error = ALMakeError(ALErrorBadResponse, L(@"The PC sent a broken pairing answer.")); break; }
            NSData *serverResponse = [response subdataWithRange:NSMakeRange(0, hashLen)];
            NSData *serverChallenge = [response subdataWithRange:NSMakeRange(hashLen, 16)];

            // 3. our answer to the host's challenge
            NSData *clientSecret = ALRandomBytes(16);
            NSMutableData *toHash = [serverChallenge mutableCopy];
            [toHash appendData:identity.certificateSignature];
            [toHash appendData:clientSecret];
            x = ALRunXML(address, httpPort, NO, nil, [pairBase stringByAppendingFormat:@"&serverchallengeresp=%@", ALHexString(ALAESECB(hash(toHash), aesKey, YES))], 15, task, &error);
            if (!x) break;
            if (![[x string:@"paired"] isEqualToString:@"1"]) { error = ALMakeError(ALErrorBadResponse, L(@"The PC refused to pair.")); break; }
            NSData *pairingSecret = ALDataFromHex([x string:@"pairingsecret"] ?: @"");
            if (pairingSecret.length <= 16) { error = ALMakeError(ALErrorBadResponse, L(@"The PC sent a broken pairing answer.")); break; }
            NSData *serverSecret = [pairingSecret subdataWithRange:NSMakeRange(0, 16)];
            NSData *serverSignature = [pairingSecret subdataWithRange:NSMakeRange(16, pairingSecret.length - 16)];
            if (![serverCert verifySHA256Signature:serverSignature ofData:serverSecret]) {
                error = ALMakeError(ALErrorCertificate, L(@"The PC's pairing answer is not signed by its certificate."));
                break;
            }
            NSMutableData *expected = [challenge mutableCopy];
            [expected appendData:serverCert.signature];
            [expected appendData:serverSecret];
            if (![hash(expected) isEqualToData:serverResponse]) {
                error = ALMakeError(ALErrorPinWrong, passphrase.length ? L(@"The one-time PIN or the passphrase is wrong (or expired).") : L(@"The PIN typed on the PC was wrong."));
                break;
            }

            // 4. our signed secret
            NSData *signature = [identity signSHA256:clientSecret];
            if (!signature) { error = ALMakeError(ALErrorTLS, L(@"Signing failed.")); break; }
            NSMutableData *clientPairingSecret = [clientSecret mutableCopy];
            [clientPairingSecret appendData:signature];
            x = ALRunXML(address, httpPort, NO, nil, [pairBase stringByAppendingFormat:@"&clientpairingsecret=%@", ALHexString(clientPairingSecret)], 15, task, &error);
            if (!x) break;
            if (![[x string:@"paired"] isEqualToString:@"1"]) { error = ALMakeError(ALErrorBadResponse, L(@"The PC refused to pair.")); break; }

            // 5. the first call over HTTPS with our certificate
            x = ALRunXML(address, httpsPort, YES, serverCert.der, [pairBase stringByAppendingString:@"&phrase=pairchallenge"], 15, task, &error);
            if (!x) break;
            if (![[x string:@"paired"] isEqualToString:@"1"]) { error = ALMakeError(ALErrorBadResponse, L(@"The PC refused to pair.")); break; }
        } while (0);

        if (error && started && error.code != ALErrorConnect && error.code != ALErrorTimeout) {
            NSError *ignored = nil;
            ALRun(address, httpPort, NO, nil, [@"/unpair?" stringByAppendingString:ALQuery(nil)], 5, nil, NULL, &ignored);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                host.serverCertificate = serverPEM;
                host.paired = YES;
                [[ALHostStore shared] hostChanged:host];
                ALLog(@"Paired with %@", host.name);
                [self refreshHost:host completion:^(NSError *e) { if (completion) completion(nil); }];
            } else {
                ALLog(@"Pairing with %@ failed: %@", host.name, error.localizedDescription);
                if (completion) completion(task.isCancelled ? ALMakeError(ALErrorCancelled, L(@"Cancelled.")) : error);
            }
        });
    });
    return task;
}

+ (void)unpairHost:(ALHost *)host completion:(void (^)(NSError *error))completion
{
    NSString *address = host.activeAddress ?: [[host candidateAddresses] firstObject];
    int port = host.httpPort;
    dispatch_async(ALWorkQueue(), ^{
        NSError *e = nil;
        if (address.length) ALRun(address, port, NO, nil, [@"/unpair?" stringByAppendingString:ALQuery(nil)], 5, nil, NULL, &e);
        dispatch_async(dispatch_get_main_queue(), ^{
            host.paired = NO;
            host.serverCertificate = nil;
            host.permission = -1;
            host.serverCommands = @[];
            [[ALHostStore shared] hostChanged:host];
            if (completion) completion(nil);
        });
    });
}

#pragma mark - Apps

+ (BOOL)checkPaired:(ALHost *)host completion:(void (^)(NSError *))fail
{
    if (host.serverCertificateDER && host.activeAddress.length) return YES;
    fail(ALMakeError(ALErrorNotPaired, host.serverCertificate ? L(@"The PC is not reachable.") : L(@"Pair with the PC first.")));
    return NO;
}

+ (void)fetchAppsForHost:(ALHost *)host completion:(void (^)(NSArray *apps, NSError *error))completion
{
    if (![self checkPaired:host completion:^(NSError *e) { if (completion) completion(nil, e); }]) return;
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    dispatch_async(ALWorkQueue(), ^{
        NSError *e = nil;
        ALNvXML *x = ALRunXML(address, port, YES, pinned, [@"/applist?" stringByAppendingString:ALQuery(nil)], 15, nil, &e);
        NSMutableArray *apps = nil;
        if (x) {
            apps = [NSMutableArray array];
            for (NSDictionary *d in x.apps) {
                ALApp *a = [ALApp appWithDictionary:d];
                if (a.title.length && a.appId.length) [apps addObject:a];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (apps) {
                host.apps = apps;
                [[ALHostStore shared] hostChanged:host];
            } else if (e.code == ALErrorCertificate || e.code == 401) {
                host.paired = NO;
                [[ALHostStore shared] hostChanged:host];
            }
            if (completion) completion(apps, apps ? nil : e);
        });
    });
}

#pragma mark - Box art

+ (NSCache *)artCache
{
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 80; });
    return cache;
}

+ (NSString *)artKeyForHost:(ALHost *)host app:(ALApp *)app
{
    return [NSString stringWithFormat:@"%@/%@", host.uuid ?: @"-", app.appId ?: @"0"];
}

+ (NSString *)artPathForKey:(NSString *)key
{
    NSString *dir = [[ALUtils cachesPath] stringByAppendingPathComponent:@"boxart"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *name = [[key stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingString:@".png"];
    return [dir stringByAppendingPathComponent:name];
}

+ (UIImage *)cachedBoxArtForHost:(ALHost *)host app:(ALApp *)app
{
    return [[self artCache] objectForKey:[self artKeyForHost:host app:app]];
}

// Decoded off the main thread at a size fit for the grid
static UIImage *ALDecodeArt(NSData *data)
{
    UIImage *raw = [UIImage imageWithData:data];
    if (!raw) return nil;
    CGSize s = raw.size;
    CGFloat maxSide = 400;
    CGFloat scale = MIN(1.0, maxSide / MAX(s.width, s.height));
    CGSize target = CGSizeMake(floor(s.width * scale), floor(s.height * scale));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    [raw drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: raw;
}

+ (void)fetchBoxArtForHost:(ALHost *)host app:(ALApp *)app completion:(void (^)(UIImage *image))completion
{
    NSString *key = [self artKeyForHost:host app:app];
    UIImage *cached = [[self artCache] objectForKey:key];
    if (cached) { if (completion) completion(cached); return; }
    NSString *path = [self artPathForKey:key];
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    NSString *appId = app.appId;
    // one at a time: every download is a TLS handshake, heavy on an A5
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.samcejko.artlight.boxart", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        UIImage *image = nil;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length) image = ALDecodeArt(data);
        if (!image && address.length && pinned) {
            NSInteger status = 0;
            NSError *e = nil;
            data = ALRun(address, port, YES, pinned, [@"/appasset?" stringByAppendingString:ALQuery([NSString stringWithFormat:@"appid=%@&AssetType=2&AssetIdx=0", appId])], 15, nil, &status, &e);
            if (status == 200 && data.length > 8) {
                image = ALDecodeArt(data);
                if (image) [data writeToFile:path atomically:YES];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                [[self artCache] setObject:image forKey:key];
                [[NSNotificationCenter defaultCenter] postNotificationName:ALBoxArtDidLoadNotification object:nil userInfo:@{ @"key": key }];
            }
            if (completion) completion(image);
        });
    });
}

#pragma mark - Launch / quit

+ (ALTask *)launchApp:(ALApp *)app host:(ALHost *)host options:(ALStreamOptions *)o completion:(void (^)(ALLaunchResult *result, NSError *error))completion
{
    ALTask *task = [[ALTask alloc] init];
    if (![self checkPaired:host completion:^(NSError *e) { if (completion) completion(nil, e); }]) return task;
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    BOOL resume = host.isBusy && [host.currentGameId isEqualToString:app.appId];
    BOOL apollo = host.isApollo;
    BOOL virtualDisplay = o.virtualDisplay && host.virtualDisplayCapable;
    NSString *appId = app.appId, *appUUID = app.uuid;
    dispatch_async(ALWorkQueue(), ^{
        NSData *riKey = ALRandomBytes(16);
        int riKeyId = 0;
        [ALRandomBytes(4) getBytes:&riKeyId length:4];
        riKeyId &= 0x7fffffff;
        int surround = SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(AUDIO_CONFIGURATION_STEREO);
        NSMutableString *q = [NSMutableString stringWithFormat:@"appid=%@&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%@&rikeyid=%d&localAudioPlayMode=%d&surroundAudioInfo=%d&remoteControllersBitmap=%d&gcmap=%d&gcpersist=0",
                              appId, o.width, o.height, o.fps, o.optimizeGameSettings ? 1 : 0, ALHexString(riKey), riKeyId, o.playAudioOnHost ? 1 : 0, surround,
                              o.gamepad ? 1 : 0, o.gamepad ? 1 : 0];
        if (apollo) {
            if (appUUID.length) [q appendFormat:@"&appuuid=%@", appUUID];
            [q appendFormat:@"&virtualDisplay=%d&scaleFactor=%d", virtualDisplay ? 1 : 0, o.scaleFactor > 0 ? o.scaleFactor : 100];
        }
        const char *extra = LiGetLaunchUrlQueryParameters();
        if (extra && extra[0]) [q appendString:[NSString stringWithUTF8String:extra]];
        NSString *verb = resume ? @"resume" : @"launch";
        NSError *e = nil;
        ALLog(@"%@ app %@ at %dx%d %d fps %d kbps%@", verb, appId, o.width, o.height, o.fps, o.bitrateKbps, virtualDisplay ? @" (virtual display)" : @"");
        ALNvXML *x = ALRunXML(address, port, YES, pinned, [NSString stringWithFormat:@"/%@?%@", verb, ALQuery(q)], 0, task, &e);
        ALLaunchResult *result = nil;
        if (x) {
            NSString *ok = [x string:resume ? @"resume" : @"gamesession"];
            if (ok.length && ![ok isEqualToString:@"0"]) {
                result = [[ALLaunchResult alloc] init];
                result.address = address;
                result.rtspSessionUrl = [x string:@"sessionUrl0"];
                result.riKey = riKey;
                result.riKeyId = riKeyId;
                result.resumed = resume;
            } else {
                e = ALMakeError(ALErrorStream, resume ? L(@"The PC could not resume the game.") : L(@"The PC could not start the game."));
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) { host.currentGameId = appId; host.currentGameUUID = appUUID; }
            if (completion) completion(result, result ? nil : e);
        });
    });
    return task;
}

+ (void)quitAppOnHost:(ALHost *)host completion:(void (^)(NSError *error))completion
{
    if (![self checkPaired:host completion:^(NSError *e) { if (completion) completion(e); }]) return;
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    dispatch_async(ALWorkQueue(), ^{
        NSError *e = nil;
        ALNvXML *x = ALRunXML(address, port, YES, pinned, [@"/cancel?" stringByAppendingString:ALQuery(nil)], 30, nil, &e);
        if (x && [[x string:@"cancel"] isEqualToString:@"0"]) e = ALMakeError(ALErrorStream, L(@"The PC did not quit the game."));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e) { if (completion) completion(e); return; }
            [self refreshHost:host completion:^(NSError *refreshError) {
                if (!refreshError && host.isBusy) {
                    if (completion) completion(ALMakeError(599, L(@"The game was started by another device; quit it there.")));
                    return;
                }
                if (completion) completion(nil);
            }];
        });
    });
}

#pragma mark - Clipboard (Apollo)

+ (void)fetchClipboardFromHost:(ALHost *)host completion:(void (^)(NSString *text, NSError *error))completion
{
    if (![self checkPaired:host completion:^(NSError *e) { if (completion) completion(nil, e); }]) return;
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    dispatch_async(ALWorkQueue(), ^{
        NSError *e = nil;
        NSInteger status = 0;
        NSData *body = ALRun(address, port, YES, pinned, [@"/actions/clipboard?" stringByAppendingString:ALQuery(@"type=text")], 10, nil, &status, &e);
        NSString *text = nil;
        if (body && status == 200) text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
        else if (body) e = ALMakeError(status, status == 401 ? L(@"The PC does not allow this device to read its clipboard (Apollo: Clients page).") :
                                         [NSString stringWithFormat:L(@"The host answered with error %ld."), (long)status]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(text, text ? nil : e); });
    });
}

+ (void)sendClipboard:(NSString *)text toHost:(ALHost *)host completion:(void (^)(NSError *error))completion
{
    if (![self checkPaired:host completion:^(NSError *e) { if (completion) completion(e); }]) return;
    NSString *address = host.activeAddress;
    int port = host.httpsPort;
    NSData *pinned = host.serverCertificateDER;
    dispatch_async(ALWorkQueue(), ^{
        ALNvRequest *r = [[ALNvRequest alloc] initWithAddress:address port:port tls:YES pathAndQuery:[@"/actions/clipboard?" stringByAppendingString:ALQuery(@"type=text")]];
        r.method = @"POST";
        r.body = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        r.contentType = @"text/plain; charset=utf-8";
        r.pinnedCertificate = pinned;
        NSInteger status = 0;
        NSError *e = nil;
        NSData *body = [r runWithStatus:&status error:&e];
        if (body && status != 200) e = ALMakeError(status, status == 401 ? L(@"The PC does not allow this device to set its clipboard (Apollo: Clients page).") :
                                                    [NSString stringWithFormat:L(@"The host answered with error %ld."), (long)status]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(body && status == 200 ? nil : e); });
    });
}

#pragma mark - Wake-on-LAN

+ (BOOL)wakeHost:(ALHost *)host
{
    NSArray *parts = [host.mac componentsSeparatedByString:@":"];
    if (parts.count != 6) return NO;
    uint8_t packet[102];
    memset(packet, 0xFF, 6);
    uint8_t mac[6];
    for (int i = 0; i < 6; i++) mac[i] = (uint8_t)strtoul([parts[(NSUInteger)i] UTF8String], NULL, 16);
    for (int i = 0; i < 16; i++) memcpy(packet + 6 + i * 6, mac, 6);
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return NO;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    NSMutableArray *targets = [NSMutableArray arrayWithObject:@"255.255.255.255"];
    for (NSString *a in [host candidateAddresses]) {
        NSArray *octets = [a componentsSeparatedByString:@"."];
        if (octets.count == 4) {
            [targets addObject:a];
            [targets addObject:[NSString stringWithFormat:@"%@.%@.%@.255", octets[0], octets[1], octets[2]]];
        }
    }
    int ports[] = { 9, 7, 47998, 47999, 48000, 48002, 48010 };
    for (NSString *t in targets) {
        for (size_t i = 0; i < sizeof(ports) / sizeof(ports[0]); i++) {
            struct sockaddr_in sin;
            memset(&sin, 0, sizeof(sin));
            sin.sin_len = sizeof(sin);
            sin.sin_family = AF_INET;
            sin.sin_port = htons((uint16_t)ports[i]);
            if (inet_pton(AF_INET, [t UTF8String], &sin.sin_addr) != 1) continue;
            sendto(s, packet, sizeof(packet), 0, (struct sockaddr *)&sin, sizeof(sin));
        }
    }
    close(s);
    ALLog(@"Wake-on-LAN sent to %@", host.mac);
    return YES;
}

@end
