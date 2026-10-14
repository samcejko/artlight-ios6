#import "ALDiscovery.h"
#import "ALGameStream.h"
#import "ALHost.h"
#import "ALCommon.h"
#include <arpa/inet.h>
#include <netinet/in.h>

@interface ALDiscovery () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic) BOOL isRunning;
@end

@implementation ALDiscovery {
    NSNetServiceBrowser *_browser;
    NSMutableArray *_services;            // being resolved (NSNetService keeps no reference to itself)
    NSMutableDictionary *_lastProbe;      // address -> NSDate
    NSMutableSet *_refreshing;            // host uuids with a /serverinfo call out
    NSTimer *_timer;
}

+ (instancetype)shared
{
    static ALDiscovery *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ALDiscovery alloc] init]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _services = [NSMutableArray array];
        _lastProbe = [NSMutableDictionary dictionary];
        _refreshing = [NSMutableSet set];
    }
    return self;
}

- (void)start
{
    if (self.isRunning) return;
    self.isRunning = YES;
    _browser = [[NSNetServiceBrowser alloc] init];
    _browser.delegate = self;
    [_browser searchForServicesOfType:@"_nvstream._tcp." inDomain:@"local."];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self refreshNow];
}

- (void)stop
{
    if (!self.isRunning) return;
    self.isRunning = NO;
    [_browser stop];
    _browser.delegate = nil;
    _browser = nil;
    for (NSNetService *s in _services) { [s stop]; s.delegate = nil; }
    [_services removeAllObjects];
    [_timer invalidate];
    _timer = nil;
}

- (void)tick
{
    [self refreshNow];
}

- (void)refreshNow
{
    for (ALHost *host in [ALHostStore shared].hosts) {
        NSString *key = host.uuid ?: host.manualAddress ?: @"";
        if (!key.length || [_refreshing containsObject:key]) continue;
        [_refreshing addObject:key];
        [ALGameStream refreshHost:host completion:^(NSError *error) {
            [self->_refreshing removeObject:key];
        }];
    }
}

#pragma mark - mDNS

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing
{
    ALLog(@"mDNS: found %@", service.name);
    [_services addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing
{
    ALLog(@"mDNS: %@ went away", service.name);
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict
{
    ALLog(@"mDNS: search failed %@", errorDict);
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    NSString *v4 = nil, *v6 = nil;
    for (NSData *data in service.addresses) {
        const struct sockaddr *sa = data.bytes;
        char buf[INET6_ADDRSTRLEN];
        if (sa->sa_family == AF_INET && data.length >= sizeof(struct sockaddr_in)) {
            if (inet_ntop(AF_INET, &((const struct sockaddr_in *)sa)->sin_addr, buf, sizeof(buf))) v4 = [NSString stringWithUTF8String:buf];
        } else if (sa->sa_family == AF_INET6 && data.length >= sizeof(struct sockaddr_in6)) {
            const struct sockaddr_in6 *s6 = (const struct sockaddr_in6 *)sa;
            if (!IN6_IS_ADDR_LINKLOCAL(&s6->sin6_addr) && inet_ntop(AF_INET6, &s6->sin6_addr, buf, sizeof(buf))) v6 = [NSString stringWithUTF8String:buf];
        }
    }
    [service stop];
    service.delegate = nil;
    [_services removeObject:service];
    NSString *address = v4 ?: v6;
    if (!address) return;
    NSDate *last = _lastProbe[address];
    if (last && -[last timeIntervalSinceNow] < 10) return;
    _lastProbe[address] = [NSDate date];
    NSInteger port = service.port > 0 ? service.port : 47989;
    ALLog(@"mDNS: %@ is at %@ port %ld", service.name, address, (long)port);
    NSString *target = v4 ? [NSString stringWithFormat:@"%@:%ld", address, (long)port] : [NSString stringWithFormat:@"[%@]:%ld", address, (long)port];
    [ALGameStream probeAddress:target manual:NO completion:nil];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict
{
    [service stop];
    service.delegate = nil;
    [_services removeObject:service];
}

@end
