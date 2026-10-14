#import "ALHost.h"
#import "ALCrypto.h"
#import "ALUtils.h"
#import "ALCommon.h"

static NSString *ALStr(id v) { return [v isKindOfClass:[NSString class]] ? v : ([v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil); }

@implementation ALApp

+ (instancetype)appWithDictionary:(NSDictionary *)d
{
    ALApp *a = [[ALApp alloc] init];
    a.appId = ALStr(d[@"ID"]) ?: @"0";
    a.title = ALStr(d[@"AppTitle"]) ?: @"";
    a.uuid = ALStr(d[@"UUID"]);
    a.hdrSupported = [ALStr(d[@"IsHdrSupported"]) integerValue] == 1;
    return a;
}

- (NSDictionary *)dictionary
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{ @"ID": self.appId ?: @"0", @"AppTitle": self.title ?: @"",
                                                                              @"IsHdrSupported": self.hdrSupported ? @"1" : @"0" }];
    if (self.uuid.length) d[@"UUID"] = self.uuid;
    return d;
}

@end

@implementation ALHost {
    NSData *_derCache;
    NSData *_derSource;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _httpPort = 47989;
        _httpsPort = 47984;
        _permission = -1;
        _currentGameId = @"0";
        _serverCommands = @[];
        _apps = @[];
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)d
{
    if ((self = [self init])) {
        _uuid = ALStr(d[@"uuid"]);
        _name = ALStr(d[@"name"]);
        _manualAddress = ALStr(d[@"manualAddress"]);
        _localAddress = ALStr(d[@"localAddress"]);
        _mdnsAddress = ALStr(d[@"mdnsAddress"]);
        _activeAddress = ALStr(d[@"activeAddress"]);
        if ([d[@"httpPort"] intValue] > 0) _httpPort = [d[@"httpPort"] intValue];
        if ([d[@"httpsPort"] intValue] > 0) _httpsPort = [d[@"httpsPort"] intValue];
        _mac = ALStr(d[@"mac"]);
        _serverCertificate = [d[@"serverCertificate"] isKindOfClass:[NSData class]] ? d[@"serverCertificate"] : nil;
        _paired = [d[@"paired"] boolValue] && _serverCertificate != nil;
        _appVersion = ALStr(d[@"appVersion"]);
        _gfeVersion = ALStr(d[@"gfeVersion"]);
        _codecModeSupport = [d[@"codecModeSupport"] intValue];
        _permission = d[@"permission"] ? [d[@"permission"] longLongValue] : -1;
        _serverCommands = [d[@"serverCommands"] isKindOfClass:[NSArray class]] ? d[@"serverCommands"] : @[];
        _virtualDisplayCapable = [d[@"virtualDisplayCapable"] boolValue];
        _virtualDisplayReady = [d[@"virtualDisplayReady"] boolValue];
        NSMutableArray *apps = [NSMutableArray array];
        for (NSDictionary *a in ([d[@"apps"] isKindOfClass:[NSArray class]] ? d[@"apps"] : @[])) {
            if ([a isKindOfClass:[NSDictionary class]]) [apps addObject:[ALApp appWithDictionary:a]];
        }
        _apps = apps;
        _lastSeen = [d[@"lastSeen"] isKindOfClass:[NSDate class]] ? d[@"lastSeen"] : nil;
    }
    return self;
}

- (NSDictionary *)dictionary
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.uuid) d[@"uuid"] = self.uuid;
    if (self.name) d[@"name"] = self.name;
    if (self.manualAddress) d[@"manualAddress"] = self.manualAddress;
    if (self.localAddress) d[@"localAddress"] = self.localAddress;
    if (self.mdnsAddress) d[@"mdnsAddress"] = self.mdnsAddress;
    if (self.activeAddress) d[@"activeAddress"] = self.activeAddress;
    d[@"httpPort"] = @(self.httpPort);
    d[@"httpsPort"] = @(self.httpsPort);
    if (self.mac) d[@"mac"] = self.mac;
    if (self.serverCertificate) d[@"serverCertificate"] = self.serverCertificate;
    d[@"paired"] = @(self.paired);
    if (self.appVersion) d[@"appVersion"] = self.appVersion;
    if (self.gfeVersion) d[@"gfeVersion"] = self.gfeVersion;
    d[@"codecModeSupport"] = @(self.codecModeSupport);
    d[@"permission"] = @(self.permission);
    d[@"serverCommands"] = self.serverCommands ?: @[];
    d[@"virtualDisplayCapable"] = @(self.virtualDisplayCapable);
    d[@"virtualDisplayReady"] = @(self.virtualDisplayReady);
    NSMutableArray *apps = [NSMutableArray array];
    for (ALApp *a in self.apps) [apps addObject:[a dictionary]];
    d[@"apps"] = apps;
    if (self.lastSeen) d[@"lastSeen"] = self.lastSeen;
    return d;
}

- (NSArray *)versionParts
{
    return [self.appVersion componentsSeparatedByString:@"."];
}

- (BOOL)isSunshine
{
    NSArray *p = [self versionParts];
    return p.count >= 4 && [p[3] integerValue] < 0;
}

- (BOOL)isApollo
{
    return self.isSunshine && (self.permission >= 0 || self.virtualDisplayCapable || self.serverCommands.count);
}

- (int)serverMajorVersion
{
    return [[[self versionParts] firstObject] intValue];
}

- (BOOL)isBusy
{
    return self.currentGameId.length && ![self.currentGameId isEqualToString:@"0"];
}

- (NSData *)serverCertificateDER
{
    if (!self.serverCertificate) return nil;
    if (_derSource != self.serverCertificate) {
        _derSource = self.serverCertificate;
        _derCache = [ALCertificate certificateWithData:self.serverCertificate].der;
    }
    return _derCache;
}

- (BOOL)hasPermission:(long long)bit
{
    if (self.permission < 0) return YES;
    return (self.permission & bit) != 0;
}

- (NSArray *)candidateAddresses
{
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *a in @[ self.activeAddress ?: @"", self.manualAddress ?: @"", self.mdnsAddress ?: @"", self.localAddress ?: @"" ]) {
        if (a.length && ![a isEqualToString:@"127.0.0.1"] && ![list containsObject:a]) [list addObject:a];
    }
    return list;
}

- (NSString *)displayAddress
{
    return self.activeAddress ?: self.manualAddress ?: self.mdnsAddress ?: self.localAddress ?: @"";
}

- (ALApp *)appWithId:(NSString *)appId
{
    for (ALApp *a in self.apps) if ([a.appId isEqualToString:appId]) return a;
    return nil;
}

@end

@implementation ALHostStore {
    NSMutableArray *_hosts;
}

+ (instancetype)shared
{
    static ALHostStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ALHostStore alloc] init]; });
    return s;
}

+ (NSString *)path
{
    return [[ALUtils appDataPath] stringByAppendingPathComponent:@"hosts.plist"];
}

- (instancetype)init
{
    if ((self = [super init])) {
        _hosts = [NSMutableArray array];
        NSArray *saved = [NSArray arrayWithContentsOfFile:[ALHostStore path]];
        for (NSDictionary *d in saved) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            ALHost *h = [[ALHost alloc] initWithDictionary:d];
            if (h.uuid.length || h.manualAddress.length) [_hosts addObject:h];
        }
    }
    return self;
}

- (NSArray *)hosts { return [_hosts copy]; }

- (ALHost *)hostWithUUID:(NSString *)uuid
{
    if (!uuid.length) return nil;
    for (ALHost *h in _hosts) if ([h.uuid isEqualToString:uuid]) return h;
    return nil;
}

- (ALHost *)hostWithAddress:(NSString *)address
{
    if (!address.length) return nil;
    for (ALHost *h in _hosts) if ([[h candidateAddresses] containsObject:address]) return h;
    return nil;
}

- (void)addHost:(ALHost *)host
{
    if (!host || [_hosts containsObject:host]) return;
    [_hosts addObject:host];
    [self hostChanged:host];
}

- (void)removeHost:(ALHost *)host
{
    if (!host) return;
    [_hosts removeObject:host];
    [self save];
    [[NSNotificationCenter defaultCenter] postNotificationName:ALHostsDidChangeNotification object:nil];
}

- (void)hostChanged:(ALHost *)host
{
    [self save];
    [[NSNotificationCenter defaultCenter] postNotificationName:ALHostsDidChangeNotification object:host];
}

- (void)save
{
    NSMutableArray *list = [NSMutableArray array];
    for (ALHost *h in _hosts) [list addObject:[h dictionary]];
    if (![list writeToFile:[ALHostStore path] atomically:YES]) ALLog(@"Hosts: saving failed");
}

@end
