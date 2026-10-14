#import "ALAppDelegate.h"
#import "ALRootViewController.h"
#import "ALHostsViewController.h"
#import "ALAppsViewController.h"
#import "ALStreamViewController.h"
#import "ALGameStream.h"
#import "ALDiscovery.h"
#import "ALCrypto.h"
#import "ALSettings.h"
#import "ALTheme.h"
#import "ALUtils.h"
#import "ALModern.h"
#import "ALCommon.h"
#import "ALVideoDecoder.h"
#include "al_h264.h"
#include <dlfcn.h>
#include <signal.h>
#include <mach/mach.h>

// A button "named" text: by its title or by its accessibility label (icon buttons have no title), case does not matter
static BOOL ALButtonMatches(UIButton *button, NSString *text)
{
    for (NSString *name in @[ button.currentTitle ?: @"", button.accessibilityLabel ?: @"" ]) {
        if (name.length && [name rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// Is the text in a label of this view? (Controls' own labels excepted: a segment title is not its table row's text.)
static BOOL ALViewContainsText(UIView *view, NSString *text)
{
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *s = ((UILabel *)view).text;
        return s.length && [s rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) continue;
        if (ALViewContainsText(sub, text)) return YES;
    }
    return NO;
}

// Acts on a view "named" text the way a finger would: a button is pressed, a segment selected, the switch of a table
// row flipped, a table or grid row selected. YES when this view was the one.
static BOOL ALPressView(UIView *v, NSString *text)
{
    if ([v isKindOfClass:[UIButton class]]) {
        if (!ALButtonMatches((UIButton *)v, text)) return NO;
        [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    if ([v isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segments = (UISegmentedControl *)v;
        for (NSUInteger i = 0; i < segments.numberOfSegments; i++) {
            NSString *title = [segments titleForSegmentAtIndex:i];
            if (title.length && [title rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                segments.selectedSegmentIndex = (NSInteger)i;
                [segments sendActionsForControlEvents:UIControlEventValueChanged];
                return YES;
            }
        }
        return NO;
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)v;
        if (!ALViewContainsText(cell, text)) return NO;
        if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            [sw setOn:!sw.on animated:NO];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];
            return YES;
        }
        UIView *table = cell.superview;
        while (table && ![table isKindOfClass:[UITableView class]]) table = table.superview;
        NSIndexPath *ip = [(UITableView *)table indexPathForCell:cell];
        id<UITableViewDelegate> delegate = [(UITableView *)table delegate];
        if (!ip || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [delegate tableView:(UITableView *)table didSelectRowAtIndexPath:ip];
        return YES;
    }
    if ([v isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)v;
        if (!ALViewContainsText(cell, text)) return NO;
        UIView *grid = cell.superview;
        while (grid && ![grid isKindOfClass:[UICollectionView class]]) grid = grid.superview;
        NSIndexPath *ip = [(UICollectionView *)grid indexPathForCell:cell];
        id<UICollectionViewDelegate> delegate = [(UICollectionView *)grid delegate];
        if (!ip || ![delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) return NO;
        [delegate collectionView:(UICollectionView *)grid didSelectItemAtIndexPath:ip];
        return YES;
    }
    return NO;
}

static UIViewController *ALTopController(UIViewController *root)
{
    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UITabBarController class]]) top = [(UITabBarController *)top selectedViewController];
    if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
    return top;
}

@implementation ALAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // (a peer that went away must not kill the process while a socket is written to)
    signal(SIGPIPE, SIG_IGN);
    [ALSettings registerDefaults];
    ALLog(@"Artlight %@ starting on %@ (iOS %@)", [ALUtils appVersion], [ALUtils deviceModel], [UIDevice currentDevice].systemVersion);
    // iOS 7 and newer (the arm64 build): the iOS 6 look of the bars, full-screen modals; nothing on iOS 6
    ALModernSetUp([[ALTheme shared] barStyle]);
    ALCryptoInit();
    [[ALIdentity shared] prepareWithCompletion:nil];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.rootViewController = [[ALRootViewController alloc] init];
    self.window.rootViewController = self.rootViewController;
    self.window.backgroundColor = [[ALTheme shared] backgroundColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:[[ALTheme shared] statusBarStyle] animated:NO];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [ALSettings save];
    [[ALDiscovery shared] stop];
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    UIViewController *top = ALTopController(self.rootViewController);
    if (![top isKindOfClass:[ALStreamViewController class]]) [[ALDiscovery shared] start];
}

- (void)selfTest
{
    ALLog(@"Self test: crypto %@", ALCryptoSelfTest());
    // an x264 High-profile SPS of a 1280x720 stream (with an emulation prevention byte inside) - picture size parsing
    static const uint8_t sps[] = { 0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60 };
    int w = 0, h = 0;
    int ok = al_h264_sps_dimensions(sps, sizeof(sps), &w, &h) && w == 1280 && h == 720;
    ALLog(@"Self test: SPS parse %@ (%dx%d, expected 1280x720)", ok ? @"OK" : @"FAILED", w, h);
    ALLog(@"Self test: VideoToolbox %@", [ALVideoDecoder isAvailable] ? @"available" : @"MISSING");
    ALLog(@"Self test: identity %@", [ALIdentity shared].isReady ? @"ready" : @"not ready");
}

- (ALHost *)hostForParam:(NSString *)value
{
    NSArray *hosts = [ALHostStore shared].hosts;
    if (!value.length) return hosts.firstObject;
    for (ALHost *h in hosts) {
        if ([h.name caseInsensitiveCompare:value] == NSOrderedSame || [[h candidateAddresses] containsObject:value] || [h.uuid isEqualToString:value]) return h;
    }
    return nil;
}

// Over SSH (uiopen) a few commands help checking the app; they need a file named "debug" in the app's Documents:
//   artlight:stats                       memory, hosts, the stream state
//   artlight:selftest                    crypto, SPS parser, VideoToolbox, identity
//   artlight:snapshot | screen           tmp/screen.png (the app's windows | the real screen with the video)
//   artlight:press?title=X | press?n=1   a button, segment, switch row or list row with that text | an alert's button
//   artlight:tab?n=1, scroll?y=400, back
//   artlight:addhost?ip=192.168.1.10     add a PC by address
//   artlight:pair?host=NAME&pin=1234[&pass=PASSPHRASE]   pair with a PIN (typed on the PC) or Apollo's one-time PIN
//   artlight:open?host=NAME              the PC's app list
//   artlight:launch?host=NAME&app=Desktop   start (or resume) an app by title or id
//   artlight:quit?host=NAME              quit the running app on the PC
//   artlight:stream?cmd=key&name=escape | cmd=type&text= | cmd=pad&buttons=0x1000 | cmd=mouse&dx=&dy=&click=1 | cmd=disconnect
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    if (![[s lowercaseString] hasPrefix:@"artlight:"]) return NO;
    NSString *target = [s substringFromIndex:@"artlight:".length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        query = [target substringFromIndex:q.location + 1];
        target = [target substringToIndex:q.location];
    }
    NSDictionary *params = query.length ? [ALUtils parseQuery:query] : @{};
    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[ALUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;
    UIViewController *top = ALTopController(self.rootViewController);
    if ([target isEqualToString:@"stats"]) {
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
            ALLog(@"Memory: %.1f MB resident, %.1f MB virtual", info.resident_size / 1048576.0, info.virtual_size / 1048576.0);
        }
        ALLog(@"Top controller: %@, dark theme %d, identity %d", NSStringFromClass([top class]), [ALTheme shared].isDark, [ALIdentity shared].isReady);
        for (ALHost *h in [ALHostStore shared].hosts) {
            ALLog(@"Host %@ [%@] state %d paired %d busy %@ addr %@ version %@ perm %lld cmds %@ apps %lu", h.name, h.uuid, (int)h.state, h.paired,
                  h.currentGameId, [[h candidateAddresses] componentsJoinedByString:@","], h.appVersion, h.permission,
                  [h.serverCommands componentsJoinedByString:@"|"], (unsigned long)h.apps.count);
        }
        if ([top isKindOfClass:[ALStreamViewController class]]) ALLog(@"Stream: %@", [(ALStreamViewController *)top debugDescription]);
        return YES;
    }
    if ([target isEqualToString:@"selftest"]) {
        [self selfTest];
        return YES;
    }
    if ([target isEqualToString:@"addhost"] && [params[@"ip"] length]) {
        [self.rootViewController selectTab:0];
        [self.rootViewController.hostsController addHostWithAddress:params[@"ip"]];
        return YES;
    }
    if ([target isEqualToString:@"pair"]) {
        ALHost *host = [self hostForParam:params[@"host"]];
        if (!host || ![params[@"pin"] length]) { ALLog(@"Pair: no such host or no pin"); return YES; }
        [self.rootViewController selectTab:0];
        [self.rootViewController.hostsController pairHost:host pin:params[@"pin"] otpPassphrase:params[@"pass"]];
        return YES;
    }
    if ([target isEqualToString:@"open"]) {
        ALHost *host = [self hostForParam:params[@"host"]];
        if (!host) { ALLog(@"Open: no such host"); return YES; }
        [self.rootViewController selectTab:0];
        [self.rootViewController.hostsController openHost:host];
        return YES;
    }
    if ([target isEqualToString:@"launch"] || [target isEqualToString:@"quit"]) {
        ALHost *host = [self hostForParam:params[@"host"]];
        if (!host) { ALLog(@"Launch: no such host"); return YES; }
        UINavigationController *nav = (UINavigationController *)self.rootViewController.viewControllers.firstObject;
        ALAppsViewController *apps = [nav.topViewController isKindOfClass:[ALAppsViewController class]] ? (ALAppsViewController *)nav.topViewController : nil;
        if (!apps || apps.host != host) {
            [self.rootViewController selectTab:0];
            [self.rootViewController.hostsController openHost:host];
            apps = [nav.topViewController isKindOfClass:[ALAppsViewController class]] ? (ALAppsViewController *)nav.topViewController : nil;
        }
        if ([target isEqualToString:@"quit"]) { [apps quitRunningApp]; return YES; }
        NSString *want = params[@"app"] ?: @"Desktop";
        ALApp *app = nil;
        for (ALApp *a in host.apps) if ([a.title caseInsensitiveCompare:want] == NSOrderedSame || [a.appId isEqualToString:want]) app = a;
        if (!app) { ALLog(@"Launch: no app %@ (known: %lu)", want, (unsigned long)host.apps.count); return YES; }
        [apps launchApp:app];
        return YES;
    }
    if ([target isEqualToString:@"stream"]) {
        if ([top isKindOfClass:[ALStreamViewController class]]) [(ALStreamViewController *)top debugCommand:params[@"cmd"] ?: @"" params:params];
        else ALLog(@"Stream command: no stream open");
        return YES;
    }
    if ([target isEqualToString:@"snapshot"]) {
        // every visible window drawn into one picture (alerts and sheets have windows of their own)
        CGSize size = [UIScreen mainScreen].bounds.size;
        UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha <= 0) continue;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, w.frame.origin.x, w.frame.origin.y);
            [w.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
        ALLog(@"Snapshot %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"screen"]) {
        // what the screen really shows, video included (the system's own screen grab, resolved at run time)
        CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        CGImageRef shot = grab ? grab() : NULL;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if (shot) {
            ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES];
            CGImageRelease(shot);
        }
        ALLog(@"Screen grab %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        NSString *byTitle = params[@"title"];
        NSInteger n = [params[@"n"] integerValue];
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle.length && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle.length && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle.length && !v.hidden && ALPressView(v, byTitle)) {
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        ALLog(@"Press %@: %@", query ?: @"", pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"tab"]) {
        [self.rootViewController selectTab:[params[@"n"] integerValue]];
        return YES;
    }
    if ([target isEqualToString:@"scroll"]) {
        // scroll?y=400 (or y=end) moves the largest scroll view on screen, so that rows further down can be pressed
        UIScrollView *largest = nil;
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.hidden) [views addObject:w];
        for (NSUInteger i = 0; i < views.count; i++) {
            UIView *v = views[i];
            if ([v isKindOfClass:[UIScrollView class]] && !v.hidden && v.window) {
                CGFloat area = v.bounds.size.width * v.bounds.size.height;
                if (!largest || area > largest.bounds.size.width * largest.bounds.size.height) largest = (UIScrollView *)v;
            }
            [views addObjectsFromArray:v.subviews];
        }
        if (largest) {
            CGFloat maxY = MAX(0, largest.contentSize.height + largest.contentInset.bottom - largest.bounds.size.height);
            CGFloat y = [params[@"y"] isEqualToString:@"end"] ? maxY : MIN(maxY, MAX(-largest.contentInset.top, [params[@"y"] doubleValue]));
            [largest setContentOffset:CGPointMake(largest.contentOffset.x, y) animated:NO];
        }
        ALLog(@"Scroll: %@", largest ? NSStringFromClass([largest class]) : @"no scroll view");
        return YES;
    }
    if ([target isEqualToString:@"back"]) {
        UIViewController *presented = self.rootViewController;
        while (presented.presentedViewController) presented = presented.presentedViewController;
        if (presented != self.rootViewController && ![presented isKindOfClass:[ALStreamViewController class]]) {
            [presented.presentingViewController dismissViewControllerAnimated:YES completion:nil];
            ALLog(@"Back: dismissed %@", NSStringFromClass([presented class]));
            return YES;
        }
        UINavigationController *nav = [top isKindOfClass:[UINavigationController class]] ? (UINavigationController *)top : top.navigationController;
        ALLog(@"Back: %@", [nav popViewControllerAnimated:YES] ? @"popped" : @"nothing to pop");
        return YES;
    }
    return YES;
}

@end
