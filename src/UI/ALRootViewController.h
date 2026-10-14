#import <UIKit/UIKit.h>

@class ALHostsViewController;

// The tab bar: PCs, Settings
@interface ALRootViewController : UITabBarController
@property (nonatomic, readonly) ALHostsViewController *hostsController;
- (void)selectTab:(NSInteger)index;
@end
