// ALModern.m - see ALModern.h. Shared by all of samcejko's iOS 6 apps (only the prefix differs).
//
// Compiled twice: with the iOS 9.3 SDK for the armv7 build (deployment target iOS 6.0) and with the iOS 16.5 SDK
// for the arm64 build (deployment target iOS 14.0). APIs newer than a SDK are behind __IPHONE_OS_VERSION_MAX_ALLOWED,
// APIs newer than the running iOS behind version checks; so this file opts out of the availability errors of the
// app's common header (which it does not import) and of the deprecation warnings of the iOS 6 era APIs it bridges.
#import "ALModern.h"
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunknown-pragmas"

#pragma mark - Versions

static NSInteger ALMajorVersion(void)
{
    static NSInteger major = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        major = [[[[UIDevice currentDevice] systemVersion] componentsSeparatedByString:@"."][0] integerValue];
        if (major < 1) major = 6;
    });
    return major;
}

BOOL ALModernIOS(void) { return ALMajorVersion() >= 7; }
static BOOL ALAtLeast(NSInteger major) { return ALMajorVersion() >= major; }

#pragma mark - Safe areas

UIEdgeInsets ALSafeAreaInsets(UIView *view)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (view && ALAtLeast(11)) return view.safeAreaInsets;
#endif
    return UIEdgeInsetsZero;
}

UIEdgeInsets ALScreenSafeAreaInsets(void)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (ALAtLeast(11)) {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *window = app.keyWindow ?: app.windows.firstObject;
        if (window) return window.safeAreaInsets;
    }
#endif
    return UIEdgeInsetsZero;
}

UIStatusBarStyle ALModernStatusBarStyle(UIStatusBarStyle ios6Style)
{
    // 1 is UIStatusBarStyleLightContent from iOS 7 on (UIStatusBarStyleBlackTranslucent of the iOS 6 headers)
    return ALModernIOS() ? (UIStatusBarStyle)1 : ios6Style;
}

CGFloat ALModernTopInset(UIView *view, CGFloat ios6Value)
{
    if (!ALModernIOS()) return ios6Value;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (ALAtLeast(11) && view.window) return view.safeAreaInsets.top;
#endif
    if ([UIApplication sharedApplication].statusBarHidden) return 0;
    CGRect frame = [UIApplication sharedApplication].statusBarFrame;
    return MIN(frame.size.width, frame.size.height);
}

CGFloat ALModernGroupedCellMargins(CGFloat ios6Margins)
{
    if (!ALModernIOS()) return ios6Margins;
    return ALAtLeast(13) ? 40 : 0;
}

#pragma mark - The iOS 6 artwork, drawn in code

static UIColor *ALRGB(NSInteger r, NSInteger g, NSInteger b)
{
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

// The colors of one glossy surface: a gradient from c1 to c2 in the upper half, a hard edge, c3 to c4 below.
typedef struct {
    NSInteger c1, c2, c3, c4;   // 0xRRGGBB
    NSInteger line;             // the border (bars: the bottom line; buttons: the outline)
    CGFloat highlight;          // alpha of the white line along the top edge
} ALGloss;

static UIColor *ALHex(NSInteger rgb) { return ALRGB((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff); }

static void ALDrawGloss(CGContextRef ctx, CGRect rect, ALGloss g)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[4] = { 0.0, 0.5, 0.5, 1.0 };
    NSArray *colors = @[ (id)ALHex(g.c1).CGColor, (id)ALHex(g.c2).CGColor, (id)ALHex(g.c3).CGColor, (id)ALHex(g.c4).CGColor ];
    CGGradientRef gradient = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
                                CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(cs);
}

// Bars (navigation bar, toolbar, search bar background): the iOS 6 blue, or the black of UIBarStyleBlack
static ALGloss ALBarGloss(BOOL black)
{
    ALGloss blue = { 0xb0bccd, 0x889bb3, 0x8195af, 0x6d84a2, 0x2d3642, 0.35 };
    ALGloss dark = { 0x4d4d4d, 0x2e2e2e, 0x262626, 0x141414, 0x000000, 0.18 };
    return black ? dark : blue;
}

// A bar background. `above` is the height of the status bar the bar extends under on iOS 7 and newer (the iOS 6
// status bar took the tint of the bar below it, so that part is drawn as a lighter gradient of the same color).
static UIImage *ALBarImage(BOOL black, CGFloat above, CGFloat height)
{
    ALGloss g = ALBarGloss(black);
    CGSize size = CGSizeMake(2, above + height);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (above > 0) {
        ALGloss status = g;
        status.c2 = status.c1;
        status.c3 = status.c1;
        status.c4 = g.c2;
        ALDrawGloss(ctx, CGRectMake(0, 0, size.width, above), status);
    }
    ALDrawGloss(ctx, CGRectMake(0, above, size.width, height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, above, size.width, 1), kCGBlendModeNormal);
    [ALHex(g.line) setFill];
    UIRectFill(CGRectMake(0, size.height - 1, size.width, 1));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0) resizingMode:UIImageResizingModeStretch];
}

// Bordered bar buttons: normal, pressed and the blue "Done" style, on the blue or the black bar
static ALGloss ALButtonGloss(BOOL black, BOOL highlighted, BOOL done)
{
    if (done) {
        ALGloss d = { 0x6aa0e6, 0x3c7cd8, 0x3374d4, 0x2563c6, 0x1d478a, 0.4 };
        ALGloss dh = { 0x4e7fc4, 0x2a62b8, 0x235bb4, 0x184ea6, 0x15397a, 0.2 };
        return highlighted ? dh : d;
    }
    if (black) {
        ALGloss b = { 0x6e6e6e, 0x4b4b4b, 0x434343, 0x333333, 0x0b0b0b, 0.25 };
        ALGloss bh = { 0x4a4a4a, 0x303030, 0x2a2a2a, 0x1e1e1e, 0x050505, 0.1 };
        return highlighted ? bh : b;
    }
    ALGloss n = { 0x8fa4c4, 0x748cb1, 0x6d86ad, 0x5f79a3, 0x3b4b62, 0.4 };
    ALGloss nh = { 0x62789a, 0x4e6488, 0x485f84, 0x3f567c, 0x2a3648, 0.2 };
    return highlighted ? nh : n;
}

// The outline of a bar button (30 pt tall): a rounded rectangle, or the iOS 6 back button with its pointed left end
static UIBezierPath *ALButtonPath(CGRect r, BOOL back)
{
    CGFloat radius = 5.0;
    if (!back) return [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
    CGFloat tip = 12.0, midY = CGRectGetMidY(r);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + tip, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMinY(r))];
    [p addArcWithCenter:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMinY(r) + radius) radius:radius startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - radius)];
    [p addArcWithCenter:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMaxY(r) - radius) radius:radius startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r) + tip, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r) + 1.5, midY + 1.5)];
    [p addQuadCurveToPoint:CGPointMake(CGRectGetMinX(r) + 1.5, midY - 1.5) controlPoint:CGPointMake(CGRectGetMinX(r), midY)];
    [p closePath];
    return p;
}

static UIImage *ALButtonImage(BOOL black, BOOL highlighted, BOOL done, BOOL back)
{
    ALGloss g = ALButtonGloss(black, highlighted, done);
    CGSize size = CGSizeMake(back ? 28 : 14, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5);
    UIBezierPath *path = ALButtonPath(inner, back);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    ALDrawGloss(ctx, CGRectMake(0, 0, size.width, size.height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, 1, size.width, 1), kCGBlendModeNormal);
    CGContextRestoreGState(ctx);
    [ALHex(g.line) setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIEdgeInsets caps = back ? UIEdgeInsetsMake(7, 15, 7, 6) : UIEdgeInsetsMake(7, 6, 7, 6);
    return [image resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
}

// A fully transparent image (hides the iOS 7 back chevron: the pointed button background draws the arrow)
static UIImage *ALClearImage(CGSize size)
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// The white rounded text field of the iOS 6 search bar
static UIImage *ALSearchFieldImage(void)
{
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5) cornerRadius:14.5];
    [[UIColor whiteColor] setFill];
    [path fill];
    [[UIColor colorWithWhite:0.0 alpha:0.35] setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(14, 14, 14, 14) resizingMode:UIImageResizingModeStretch];
}

// The black iOS 6 tab bar, and the darker rounded area behind its selected item
static UIImage *ALTabBarImage(void)
{
    ALGloss g = { 0x484848, 0x2a2a2a, 0x202020, 0x0a0a0a, 0x000000, 0.2 };
    CGSize size = CGSizeMake(2, 49);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    ALDrawGloss(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, size.width, size.height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, 0, size.width, 1), kCGBlendModeNormal);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0) resizingMode:UIImageResizingModeStretch];
}

static UIImage *ALTabSelectionImage(void)
{
    CGSize size = CGSizeMake(64, 49);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, size.width - 4, size.height - 6) cornerRadius:5];
    [[UIColor colorWithWhite:1.0 alpha:0.14] setFill];
    [path fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(10, 10, 10, 10) resizingMode:UIImageResizingModeStretch];
}

// Segments of a plain segmented control: light gray, the selected one darker
static UIImage *ALSegmentImage(BOOL selected)
{
    ALGloss normal = { 0xfbfbfb, 0xe6e6e6, 0xdcdcdc, 0xc9c9c9, 0x8e8e8e, 0.0 };
    ALGloss sel = { 0x9c9c9c, 0x7a7a7a, 0x717171, 0x5e5e5e, 0x4a4a4a, 0.15 };
    ALGloss g = selected ? sel : normal;
    CGSize size = CGSizeMake(14, 32);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:5];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    ALDrawGloss(ctx, CGRectMake(0, 0, size.width, size.height), g);
    if (g.highlight > 0) {
        [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
        UIRectFillUsingBlendMode(CGRectMake(0, 1, size.width, 1), kCGBlendModeNormal);
    }
    CGContextRestoreGState(ctx);
    [ALHex(g.line) setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(7, 6, 7, 6) resizingMode:UIImageResizingModeStretch];
}

static UIImage *ALSegmentDividerImage(void)
{
    CGSize size = CGSizeMake(1, 32);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [ALHex(0x8e8e8e) setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Text styles

// White, bold, with the dark shadow above the glyphs that iOS 6 gave bar titles and bar buttons
static NSDictionary *ALEmbossedTextAttributes(CGFloat fontSize)
{
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    shadow.shadowOffset = CGSizeMake(0, -1);
    return @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize],
              NSForegroundColorAttributeName: [UIColor whiteColor],
              NSShadowAttributeName: shadow };
}

static NSDictionary *ALEngravedTextAttributes(CGFloat fontSize, UIColor *color)
{
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    shadow.shadowOffset = CGSizeMake(0, 1);
    return @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize],
              NSForegroundColorAttributeName: color,
              NSShadowAttributeName: shadow };
}

#pragma mark - Bars

// The height of the status bar the navigation bar reaches under in portrait (0 when it is hidden)
static CGFloat ALStatusBarHeight(void)
{
    CGRect frame = [UIApplication sharedApplication].statusBarFrame;
    CGFloat h = MIN(frame.size.width, frame.size.height);
    if (h <= 0) h = 20;
    return h;
}

static BOOL ALIsBlack(UIBarStyle style) { return style == UIBarStyleBlack; }

// Legacy customization (iOS 7-12; also what iOS 13 and newer fall back to where no appearance object is set).
// Whatever the look, the bar is dark: UIBarStyleBlack makes the status bar's text light and the title white.
static void ALApplyLegacyNavigationBar(UINavigationBar *bar, BOOL black)
{
    UIImage *tall = ALBarImage(black, ALStatusBarHeight(), 44);
    UIImage *compact = ALBarImage(black, 0, 32);
    [bar setBackgroundImage:tall forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:compact forBarMetrics:(UIBarMetrics)1];   // UIBarMetricsCompact (landscape iPhone)
    [bar setShadowImage:ALClearImage(CGSizeMake(1, 1))];
    [bar setTitleTextAttributes:ALEmbossedTextAttributes(20)];
    [bar setTintColor:[UIColor whiteColor]];
    [bar setBarStyle:UIBarStyleBlack];
    if ([bar respondsToSelector:@selector(setBackIndicatorImage:)]) {
        [bar setBackIndicatorImage:ALClearImage(CGSizeMake(1, 20))];
        [bar setBackIndicatorTransitionMaskImage:ALClearImage(CGSizeMake(1, 20))];
    }
}

static void ALApplyLegacyBarButtons(UIBarButtonItem *proxy, BOOL black)
{
    for (int metrics = 0; metrics < 2; metrics++) {
        [proxy setBackgroundImage:ALButtonImage(black, NO, NO, NO) forState:UIControlStateNormal barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:ALButtonImage(black, YES, NO, NO) forState:UIControlStateHighlighted barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:ALButtonImage(black, NO, YES, NO) forState:UIControlStateNormal style:UIBarButtonItemStyleDone barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:ALButtonImage(black, YES, YES, NO) forState:UIControlStateHighlighted style:UIBarButtonItemStyleDone barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonBackgroundImage:ALButtonImage(black, NO, NO, YES) forState:UIControlStateNormal barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonBackgroundImage:ALButtonImage(black, YES, NO, YES) forState:UIControlStateHighlighted barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonTitlePositionAdjustment:UIOffsetMake(6, 0) forBarMetrics:(UIBarMetrics)metrics];
    }
    [proxy setTitleTextAttributes:ALEmbossedTextAttributes(12) forState:UIControlStateNormal];
    [proxy setTitleTextAttributes:ALEmbossedTextAttributes(12) forState:UIControlStateHighlighted];
}

static void ALApplyLegacyToolbar(UIToolbar *bar, BOOL black)
{
    [bar setBackgroundImage:ALBarImage(black, 0, 44) forToolbarPosition:(UIBarPosition)0 barMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:ALBarImage(black, 0, 32) forToolbarPosition:(UIBarPosition)0 barMetrics:(UIBarMetrics)1];
    [bar setShadowImage:ALClearImage(CGSizeMake(1, 1)) forToolbarPosition:(UIBarPosition)0];
    [bar setTintColor:[UIColor whiteColor]];
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
// iOS 13 and newer: the appearance objects (without them iOS 15 draws the bars transparent at the scroll edge)
static UIBarButtonItemAppearance *ALButtonAppearance(BOOL black, BOOL done, BOOL back)
{
    UIBarButtonItemAppearance *a = [[UIBarButtonItemAppearance alloc] initWithStyle:done ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain];
    NSDictionary *text = ALEmbossedTextAttributes(12);
    a.normal.backgroundImage = ALButtonImage(black, NO, done, back);
    a.normal.titleTextAttributes = text;
    a.highlighted.backgroundImage = ALButtonImage(black, YES, done, back);
    a.highlighted.titleTextAttributes = text;
    a.disabled.backgroundImage = a.normal.backgroundImage;
    a.disabled.titleTextAttributes = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:12], NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.5] };
    if (back) {
        a.normal.titlePositionAdjustment = UIOffsetMake(6, 0);
        a.highlighted.titlePositionAdjustment = UIOffsetMake(6, 0);
        a.disabled.titlePositionAdjustment = UIOffsetMake(6, 0);
    }
    return a;
}

static UINavigationBarAppearance *ALNavigationBarAppearance(BOOL black, BOOL compact)
{
    UINavigationBarAppearance *a = [[UINavigationBarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = compact ? ALBarImage(black, 0, 32) : ALBarImage(black, ALStatusBarHeight(), 44);
    a.backgroundImageContentMode = UIViewContentModeScaleToFill;
    a.shadowColor = nil;
    a.shadowImage = nil;
    a.titleTextAttributes = ALEmbossedTextAttributes(compact ? 17 : 20);
    a.largeTitleTextAttributes = ALEmbossedTextAttributes(34);
    a.buttonAppearance = ALButtonAppearance(black, NO, NO);
    a.doneButtonAppearance = ALButtonAppearance(black, YES, NO);
    a.backButtonAppearance = ALButtonAppearance(black, NO, YES);
    [a setBackIndicatorImage:ALClearImage(CGSizeMake(1, 20)) transitionMaskImage:ALClearImage(CGSizeMake(1, 20))];
    return a;
}

static void ALSetNavigationBarAppearances(UINavigationBar *bar, UINavigationBarAppearance *standard, UINavigationBarAppearance *compact)
{
    [bar setStandardAppearance:standard];
    [bar setScrollEdgeAppearance:standard];
    [bar setCompactAppearance:compact];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (ALAtLeast(15)) [bar setCompactScrollEdgeAppearance:compact];
#endif
}

static void ALApplyNavigationBarAppearance(UINavigationBar *bar, BOOL black)
{
    ALSetNavigationBarAppearances(bar, ALNavigationBarAppearance(black, NO), ALNavigationBarAppearance(black, YES));
    [bar setTintColor:[UIColor whiteColor]];
    [bar setBarStyle:UIBarStyleBlack];
}

static UIToolbarAppearance *ALToolbarAppearance(BOOL black, BOOL compact)
{
    UIToolbarAppearance *a = [[UIToolbarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = ALBarImage(black, 0, compact ? 32 : 44);
    a.backgroundImageContentMode = UIViewContentModeScaleToFill;
    a.shadowColor = nil;
    a.shadowImage = nil;
    return a;
}

static void ALApplyToolbarAppearance(UIToolbar *bar, BOOL black)
{
    UIToolbarAppearance *standard = ALToolbarAppearance(black, NO);
    UIToolbarAppearance *compact = ALToolbarAppearance(black, YES);
    [bar setStandardAppearance:standard];
    [bar setCompactAppearance:compact];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (ALAtLeast(15)) {
        [bar setScrollEdgeAppearance:standard];
        [bar setCompactScrollEdgeAppearance:compact];
    }
#endif
    [bar setTintColor:[UIColor whiteColor]];
}

static void ALSetTabBarAppearance(UITabBar *bar, UITabBarAppearance *a)
{
    [bar setStandardAppearance:a];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (ALAtLeast(15)) [bar setScrollEdgeAppearance:a];
#endif
}

static void ALApplyTabBarAppearance(UITabBar *bar)
{
    UITabBarAppearance *a = [[UITabBarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = ALTabBarImage();
    a.shadowColor = nil;
    a.shadowImage = nil;
    a.selectionIndicatorImage = ALTabSelectionImage();
    UIColor *selected = ALRGB(84, 164, 255), *normal = ALRGB(146, 146, 146);
    for (UITabBarItemAppearance *item in @[ a.stackedLayoutAppearance, a.inlineLayoutAppearance, a.compactInlineLayoutAppearance ]) {
        item.selected.iconColor = selected;
        item.selected.titleTextAttributes = @{ NSForegroundColorAttributeName: selected, NSFontAttributeName: [UIFont boldSystemFontOfSize:10] };
        item.normal.iconColor = normal;
        item.normal.titleTextAttributes = @{ NSForegroundColorAttributeName: normal, NSFontAttributeName: [UIFont boldSystemFontOfSize:10] };
    }
    ALSetTabBarAppearance(bar, a);
    [bar setTintColor:selected];
}
#endif

void ALModernApplyNavigationBarBackground(UINavigationBar *bar, UIImage *image, NSDictionary *titleAttributes,
                                             UIImage *buttonImage, UIImage *buttonImageHighlighted, NSDictionary *buttonTitleAttributes)
{
    if (!bar || !image || !ALModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) {
        UINavigationBarAppearance *a = [[UINavigationBarAppearance alloc] init];
        [a configureWithOpaqueBackground];
        a.backgroundImage = image;
        a.backgroundImageContentMode = UIViewContentModeScaleToFill;
        a.shadowColor = nil;
        a.shadowImage = nil;
        if (titleAttributes) a.titleTextAttributes = titleAttributes;
        if (buttonImage || buttonTitleAttributes) {
            for (UIBarButtonItemAppearance *b in @[ a.buttonAppearance, a.doneButtonAppearance, a.backButtonAppearance ]) {
                if (buttonImage) {
                    b.normal.backgroundImage = buttonImage;
                    b.highlighted.backgroundImage = buttonImageHighlighted ?: buttonImage;
                    b.disabled.backgroundImage = buttonImage;
                }
                if (buttonTitleAttributes) {
                    b.normal.titleTextAttributes = buttonTitleAttributes;
                    b.highlighted.titleTextAttributes = buttonTitleAttributes;
                }
            }
        }
        ALSetNavigationBarAppearances(bar, a, a);
        return;
    }
#endif
    [bar setBackgroundImage:image forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:image forBarMetrics:(UIBarMetrics)1];
    [bar setShadowImage:ALClearImage(CGSizeMake(1, 1))];
    if (titleAttributes) [bar setTitleTextAttributes:titleAttributes];
    // (the legacy button images come from the app's own UIBarButtonItem appearance; nothing more to do here)
}

UITextField *ALModernSearchBarTextField(UISearchBar *bar)
{
    if (!bar) return nil;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) return bar.searchTextField;
#endif
    NSMutableArray *queue = [NSMutableArray arrayWithObject:bar];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITextField class]]) return (UITextField *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

void ALModernApplyTabBarBackground(UITabBar *bar, UIImage *image)
{
    if (!bar || !image || !ALModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) {
        UITabBarAppearance *a = [[UITabBarAppearance alloc] init];
        [a configureWithOpaqueBackground];
        a.backgroundImage = image;
        a.shadowColor = nil;
        a.shadowImage = nil;
        ALSetTabBarAppearance(bar, a);
        return;
    }
#endif
    [bar setBackgroundImage:image];
    [bar setShadowImage:ALClearImage(CGSizeMake(1, 1))];
}

void ALModernKeepScrollViewInsets(UIScrollView *scrollView)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (scrollView && ALAtLeast(11)) scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
#endif
}

void ALModernDisableSwipeBack(UINavigationController *nav)
{
    if (nav && [nav respondsToSelector:@selector(interactivePopGestureRecognizer)]) nav.interactivePopGestureRecognizer.enabled = NO;
}

void ALModernStatusBarChanged(UIViewController *vc)
{
    if (vc && [vc respondsToSelector:@selector(setNeedsStatusBarAppearanceUpdate)]) [vc setNeedsStatusBarAppearanceUpdate];
}

void ALModernStyleNavigationBar(UINavigationBar *bar)
{
    if (!bar || !ALModernIOS()) return;
    BOOL black = ALIsBlack(bar.barStyle);
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) { ALApplyNavigationBarAppearance(bar, black); return; }
#endif
    ALApplyLegacyNavigationBar(bar, black);
}

void ALModernStyleToolbar(UIToolbar *bar)
{
    if (!bar || !ALModernIOS()) return;
    BOOL black = ALIsBlack(bar.barStyle);
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) { ALApplyToolbarAppearance(bar, black); return; }
#endif
    ALApplyLegacyToolbar(bar, black);
}

void ALModernStyleSearchBar(UISearchBar *bar)
{
    if (!bar || !ALModernIOS()) return;
    BOOL black = ALIsBlack(bar.barStyle);
    bar.translucent = NO;
    [bar setBackgroundImage:ALBarImage(black, 0, 44)];
    [bar setSearchFieldBackgroundImage:ALSearchFieldImage() forState:UIControlStateNormal];
    [bar setSearchTextPositionAdjustment:UIOffsetMake(4, 0)];
    bar.tintColor = [UIColor whiteColor];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) {
        bar.searchTextField.tintColor = ALRGB(30, 90, 200);
        bar.searchTextField.textColor = [UIColor blackColor];
    }
#endif
}

void ALModernStyleTabBar(UITabBar *bar)
{
    if (!bar || !ALModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) { ALApplyTabBarAppearance(bar); return; }
#endif
    [bar setBackgroundImage:ALTabBarImage()];
    [bar setSelectionIndicatorImage:ALTabSelectionImage()];
    [bar setShadowImage:ALClearImage(CGSizeMake(1, 1))];
    [bar setTintColor:ALRGB(84, 164, 255)];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 100000
    if ([bar respondsToSelector:@selector(setUnselectedItemTintColor:)]) [bar setUnselectedItemTintColor:ALRGB(146, 146, 146)];
#endif
}

#pragma mark - The defaults for every bar (UIAppearance)

static id ALAppearanceInside(Class<UIAppearance> cls, Class container)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 90000
    if ([(id)cls respondsToSelector:@selector(appearanceWhenContainedInInstancesOfClasses:)]) {
        return [cls appearanceWhenContainedInInstancesOfClasses:@[ container ]];
    }
#endif
    return [cls appearanceWhenContainedIn:container, nil];
}

// full-width separators, as before iOS 7
static void ALInstallTableDefaults(void)
{
    [[UITableView appearance] setSeparatorInset:UIEdgeInsetsZero];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 90000
    if ([[UITableView appearance] respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)]) {
        [[UITableView appearance] setCellLayoutMarginsFollowReadableWidth:NO];
    }
#endif
}

static void ALInstallAppearance(BOOL black)
{
    // navigation bars, toolbars, tab bars, search bars (the same artwork as the per-bar functions above)
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) {
        ALApplyNavigationBarAppearance([UINavigationBar appearance], black);
        ALApplyToolbarAppearance([UIToolbar appearance], black);
        ALApplyTabBarAppearance([UITabBar appearance]);
    } else
#endif
    {
        ALApplyLegacyNavigationBar([UINavigationBar appearance], black);
        ALApplyLegacyToolbar([UIToolbar appearance], black);
        [[UITabBar appearance] setBackgroundImage:ALTabBarImage()];
        [[UITabBar appearance] setSelectionIndicatorImage:ALTabSelectionImage()];
        [[UITabBar appearance] setTintColor:ALRGB(84, 164, 255)];
    }
    [[UINavigationBar appearance] setTranslucent:NO];
    [[UIToolbar appearance] setTranslucent:NO];
    [[UITabBar appearance] setTranslucent:NO];

    // bordered bar buttons: in navigation bars (as on iOS 6, where plain items were bordered there too) and the
    // Cancel button of search bars; toolbars keep their borderless white glyphs
    ALApplyLegacyBarButtons((UIBarButtonItem *)ALAppearanceInside([UIBarButtonItem class], [UINavigationBar class]), black);
    ALApplyLegacyBarButtons((UIBarButtonItem *)ALAppearanceInside([UIBarButtonItem class], [UISearchBar class]), black);
    [[UIBarButtonItem appearance] setTitleTextAttributes:ALEmbossedTextAttributes(12) forState:UIControlStateNormal];

    [[UISearchBar appearance] setBackgroundImage:ALBarImage(black, 0, 44)];
    [[UISearchBar appearance] setSearchFieldBackgroundImage:ALSearchFieldImage() forState:UIControlStateNormal];
    [[UISearchBar appearance] setSearchTextPositionAdjustment:UIOffsetMake(4, 0)];
    [(UITextField *)ALAppearanceInside([UITextField class], [UISearchBar class]) setTintColor:ALRGB(30, 90, 200)];

    // the iOS 6 blue of switches; glossy gray segmented controls with engraved labels
    [[UISwitch appearance] setOnTintColor:ALRGB(26, 108, 213)];
    UISegmentedControl *segment = [UISegmentedControl appearance];
    [segment setBackgroundImage:ALSegmentImage(NO) forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setBackgroundImage:ALSegmentImage(YES) forState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    [segment setBackgroundImage:ALSegmentImage(YES) forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    UIImage *divider = ALSegmentDividerImage();
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateSelected rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    [segment setTitleTextAttributes:ALEngravedTextAttributes(13, ALRGB(60, 60, 60)) forState:UIControlStateNormal];
    [segment setTitleTextAttributes:ALEmbossedTextAttributes(13) forState:UIControlStateSelected];
    ALInstallTableDefaults();
}

#pragma mark - iOS 13: full-screen modals and rounded grouped tables

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
static void (*ALOriginalPresent)(id, SEL, UIViewController *, BOOL, void (^)(void));
static id (*ALOriginalTableInit)(id, SEL, CGRect, UITableViewStyle);

// The app's own view controllers (also wrapped in a navigation or tab bar controller), not UIKit's pickers and sheets
static BOOL ALIsAppController(UIViewController *vc)
{
    UIViewController *probe = vc;
    if ([vc isKindOfClass:[UINavigationController class]]) probe = ((UINavigationController *)vc).viewControllers.firstObject ?: vc;
    else if ([vc isKindOfClass:[UITabBarController class]]) probe = ((UITabBarController *)vc).viewControllers.firstObject ?: vc;
    // (the bundle of a class from the executable is the main bundle; a system picker or sheet lives under /System)
    NSBundle *bundle = [NSBundle bundleForClass:[probe class]];
    if (bundle == [NSBundle mainBundle]) return YES;
    NSString *path = bundle.bundlePath ?: @"";
    return path.length && ![path hasPrefix:@"/System/"] && ![path hasPrefix:@"/Developer/"] && ![path hasPrefix:@"/usr/"];
}

static void ALPresent(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void))
{
    // iOS 13 made the default a card that slides up and can be dragged away; iOS 6 presented full screen
    if (vc && vc.modalPresentationStyle == UIModalPresentationAutomatic && ALIsAppController(vc)) {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    ALOriginalPresent(self, _cmd, vc, animated, completion);
}

static id ALTableInit(id self, SEL _cmd, CGRect frame, UITableViewStyle style)
{
    // iOS 13 draws grouped tables as full-width flat lists; the inset style keeps the rounded groups of iOS 6
    if (style == UITableViewStyleGrouped) {
        self = ALOriginalTableInit(self, _cmd, frame, UITableViewStyleInsetGrouped);
        [self setBackgroundColor:ALRGB(197, 204, 212)];
        return self;
    }
    return ALOriginalTableInit(self, _cmd, frame, style);
}

static void ALInstallIOS13Behaviour(void)
{
    Method present = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (present && !ALOriginalPresent) {
        ALOriginalPresent = (void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))method_getImplementation(present);
        method_setImplementation(present, (IMP)ALPresent);
    }
    Method tableInit = class_getInstanceMethod([UITableView class], @selector(initWithFrame:style:));
    if (tableInit && !ALOriginalTableInit) {
        ALOriginalTableInit = (id (*)(id, SEL, CGRect, UITableViewStyle))method_getImplementation(tableInit);
        method_setImplementation(tableInit, (IMP)ALTableInit);
    }
}
#endif

#pragma mark - Tables

void ALModernSetTableViewDark(UITableView *tableView, BOOL dark)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    // (the forced light style of the app would draw dark grey section headers on a dark table)
    if (ALAtLeast(13)) tableView.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
#endif
}
#pragma mark - Set-up

static BOOL GFsetUpDone = NO;

void ALModernSetUp(UIBarStyle defaultBarStyle)
{
    if (!ALModernIOS() || GFsetUpDone) return;
    GFsetUpDone = YES;
    ALInstallAppearance(ALIsBlack(defaultBarStyle));
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) ALInstallIOS13Behaviour();
#endif
    NSLog(@"[ALModern] iOS %@: the iOS 6 look is on", [UIDevice currentDevice].systemVersion);
}

void ALModernSetUpWithoutSkin(void)
{
    if (!ALModernIOS() || GFsetUpDone) return;
    GFsetUpDone = YES;
    ALInstallTableDefaults();
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (ALAtLeast(13)) ALInstallIOS13Behaviour();
#endif
    NSLog(@"[ALModern] iOS %@: iOS 6 behaviour on (the app's own look)", [UIDevice currentDevice].systemVersion);
}

void ALModernRequestNotificationPermission(void)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    UIApplication *app = [UIApplication sharedApplication];
    if (ALAtLeast(8) && [app respondsToSelector:@selector(registerUserNotificationSettings:)]) {
        UIUserNotificationType types = UIUserNotificationTypeAlert | UIUserNotificationTypeSound | UIUserNotificationTypeBadge;
        [app registerUserNotificationSettings:[UIUserNotificationSettings settingsForTypes:types categories:nil]];
    }
#endif
}
