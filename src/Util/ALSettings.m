#import "ALSettings.h"
#import "ALCommon.h"

#define DEF [NSUserDefaults standardUserDefaults]

@implementation ALSettings

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"darkTheme": @NO,
        @"streamResolution": @"1024x768",
        @"streamFps": @30,          // the iPad 2 (A5) decoder holds 30 fps comfortably; 60 fps overruns it and stutters
        @"bitrateKbps": @5000,
        @"optimizeGameSettings": @YES,
        @"playAudioOnHost": @NO,
        @"virtualDisplay": @NO,
        @"showStats": @NO,
        @"touchGamepad": @YES,
        @"gamepadOpacity": @0.45,
        @"mouseSensitivity": @1.5,
        @"touchMode": @(ALTouchModeTrackpad),
    }];
}

+ (void)save
{
    [DEF synchronize];
}

+ (void)notify
{
    ALMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ALSettingsDidChangeNotification object:nil];
    });
}

#pragma mark - Appearance

+ (BOOL)darkTheme { return [DEF boolForKey:@"darkTheme"]; }
+ (void)setDarkTheme:(BOOL)value { [DEF setBool:value forKey:@"darkTheme"]; }

#pragma mark - Stream

+ (NSString *)streamResolution { return [DEF stringForKey:@"streamResolution"] ?: @"1024x768"; }
+ (void)setStreamResolution:(NSString *)value { [DEF setObject:value ?: @"1024x768" forKey:@"streamResolution"]; [self notify]; }

+ (CGSize)nativeSize
{
    // the screen in landscape pixels, both sides even (H.264 wants it)
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat w = MAX(b.size.width, b.size.height) * scale;
    CGFloat h = MIN(b.size.width, b.size.height) * scale;
    // retina screens: 2048x1536 is far beyond a 2012 decoder, stream at the point size instead
    if (w > 1920) { w /= scale; h /= scale; }
    return CGSizeMake(floor(w / 2) * 2, floor(h / 2) * 2);
}

+ (CGSize)streamSize
{
    NSString *r = [self streamResolution];
    if (![r isEqualToString:@"native"]) {
        NSArray *parts = [r componentsSeparatedByString:@"x"];
        if (parts.count == 2) {
            CGSize s = CGSizeMake([parts[0] integerValue], [parts[1] integerValue]);
            if (s.width >= 320 && s.height >= 240) return s;
        }
    }
    return [self nativeSize];
}

+ (NSInteger)streamFps { NSInteger v = [DEF integerForKey:@"streamFps"]; return v == 60 ? 60 : 30; }
+ (void)setStreamFps:(NSInteger)value { [DEF setInteger:value forKey:@"streamFps"]; [self notify]; }

+ (NSInteger)bitrateKbps { NSInteger v = [DEF integerForKey:@"bitrateKbps"]; return MIN(40000, MAX(1000, v ?: 5000)); }
+ (void)setBitrateKbps:(NSInteger)value { [DEF setInteger:value forKey:@"bitrateKbps"]; [self notify]; }

+ (BOOL)optimizeGameSettings { return [DEF boolForKey:@"optimizeGameSettings"]; }
+ (void)setOptimizeGameSettings:(BOOL)value { [DEF setBool:value forKey:@"optimizeGameSettings"]; [self notify]; }

+ (BOOL)playAudioOnHost { return [DEF boolForKey:@"playAudioOnHost"]; }
+ (void)setPlayAudioOnHost:(BOOL)value { [DEF setBool:value forKey:@"playAudioOnHost"]; [self notify]; }

+ (BOOL)virtualDisplay { return [DEF boolForKey:@"virtualDisplay"]; }
+ (void)setVirtualDisplay:(BOOL)value { [DEF setBool:value forKey:@"virtualDisplay"]; [self notify]; }

+ (BOOL)showStats { return [DEF boolForKey:@"showStats"]; }
+ (void)setShowStats:(BOOL)value { [DEF setBool:value forKey:@"showStats"]; [self notify]; }

#pragma mark - Controls

+ (BOOL)touchGamepad { return [DEF boolForKey:@"touchGamepad"]; }
+ (void)setTouchGamepad:(BOOL)value { [DEF setBool:value forKey:@"touchGamepad"]; [self notify]; }

+ (CGFloat)gamepadOpacity { double v = [DEF doubleForKey:@"gamepadOpacity"]; return (CGFloat)MIN(0.9, MAX(0.2, v ?: 0.45)); }
+ (void)setGamepadOpacity:(CGFloat)value { [DEF setDouble:value forKey:@"gamepadOpacity"]; [self notify]; }

+ (CGFloat)mouseSensitivity { double v = [DEF doubleForKey:@"mouseSensitivity"]; return (CGFloat)MIN(3.0, MAX(0.5, v ?: 1.5)); }
+ (void)setMouseSensitivity:(CGFloat)value { [DEF setDouble:value forKey:@"mouseSensitivity"]; [self notify]; }

+ (ALTouchMode)touchMode { NSInteger v = [DEF integerForKey:@"touchMode"]; return (v >= 0 && v <= ALTouchModeTouchscreen) ? (ALTouchMode)v : ALTouchModeTrackpad; }
+ (void)setTouchMode:(ALTouchMode)value { [DEF setInteger:value forKey:@"touchMode"]; [self notify]; }

@end
