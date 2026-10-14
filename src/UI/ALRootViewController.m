#import "ALRootViewController.h"
#import "ALHostsViewController.h"
#import "ALSettingsViewController.h"
#import "ALTheme.h"
#import "ALCommon.h"

@interface ALRootViewController ()
@property (nonatomic, strong) ALHostsViewController *hostsController;
@property (nonatomic, strong) ALSettingsViewController *settings;
@end

@implementation ALRootViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    ALTheme *theme = [ALTheme shared];
    self.hostsController = [[ALHostsViewController alloc] init];
    self.hostsController.title = L(@"PCs");
    self.settings = [[ALSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    self.settings.title = L(@"Settings");

    NSMutableArray *controllers = [NSMutableArray array];
    NSArray *pairs = @[ @[ self.hostsController, [theme tabIconComputers] ], @[ self.settings, [theme tabIconSettings] ] ];
    for (NSArray *pair in pairs) {
        UIViewController *vc = pair[0];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:vc.title image:pair[1] tag:(NSInteger)controllers.count];
        [controllers addObject:nav];
    }
    self.viewControllers = controllers;
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:ALThemeDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme
{
    ALTheme *theme = [ALTheme shared];
    [theme applyToTabBar:self.tabBar];
    for (UINavigationController *nav in self.viewControllers) [theme applyToNavigationBar:nav.navigationBar];
    [[UIApplication sharedApplication] setStatusBarStyle:[theme statusBarStyle] animated:YES];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)selectTab:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)self.viewControllers.count) self.selectedIndex = (NSUInteger)index;
}

@end
