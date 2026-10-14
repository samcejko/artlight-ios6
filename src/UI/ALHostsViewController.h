#import <UIKit/UIKit.h>
#import "ALHost.h"

// The gaming PCs: found on the network or added by address; pairing, waking, opening one's app list
@interface ALHostsViewController : UITableViewController
- (void)addHostWithAddress:(NSString *)address;                 // debug command artlight:addhost?ip=
- (void)pairHost:(ALHost *)host pin:(NSString *)pin otpPassphrase:(NSString *)passphrase;
- (void)openHost:(ALHost *)host;
@end
