#import <Foundation/Foundation.h>

// Finds Sunshine/Apollo PCs on the local network (mDNS service _nvstream._tcp) and keeps the known ones' state
// fresh (a /serverinfo call every few seconds while running). Main thread only.
@interface ALDiscovery : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (void)refreshNow;
@property (nonatomic, readonly) BOOL isRunning;
@end
