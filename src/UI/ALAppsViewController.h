#import <UIKit/UIKit.h>
#import "ALHost.h"

// The apps of one paired PC as a grid of box art; tapping one starts (or resumes) the stream
@interface ALAppsViewController : UIViewController
- (instancetype)initWithHost:(ALHost *)host;
@property (nonatomic, readonly) ALHost *host;
- (void)launchApp:(ALApp *)app;          // also the debug command artlight:launch?app=
- (void)quitRunningApp;
@end
