#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// How a touch on the picture acts on the PC
typedef enum {
    ALTouchModeTrackpad = 0,    // drag moves the pointer, tap clicks (like a laptop's touchpad)
    ALTouchModeDirect,          // the pointer jumps to the finger, tap clicks there
    ALTouchModeTouchscreen,     // real multi-touch on the PC (Sunshine/Apollo touch events)
} ALTouchMode;

// User preferences, kept in NSUserDefaults. Setters post ALSettingsDidChangeNotification.
@interface ALSettings : NSObject

+ (void)registerDefaults;
+ (void)save;

// Appearance
+ (BOOL)darkTheme;
+ (void)setDarkTheme:(BOOL)value;

// Stream
+ (NSString *)streamResolution;         // "1024x768"; "native" = the screen in pixels
+ (void)setStreamResolution:(NSString *)value;
+ (CGSize)streamSize;                   // the resolution resolved to numbers
+ (NSInteger)streamFps;                 // 30 or 60
+ (void)setStreamFps:(NSInteger)value;
+ (NSInteger)bitrateKbps;               // 1000..40000
+ (void)setBitrateKbps:(NSInteger)value;
+ (BOOL)optimizeGameSettings;           // let the host change the game's settings to the stream ("sops")
+ (void)setOptimizeGameSettings:(BOOL)value;
+ (BOOL)playAudioOnHost;
+ (void)setPlayAudioOnHost:(BOOL)value;
+ (BOOL)virtualDisplay;                 // Apollo: stream from a virtual monitor made for this device
+ (void)setVirtualDisplay:(BOOL)value;
+ (BOOL)showStats;                      // the small stream statistics overlay
+ (void)setShowStats:(BOOL)value;

// Controls
+ (BOOL)touchGamepad;                   // the on-screen gamepad
+ (void)setTouchGamepad:(BOOL)value;
+ (CGFloat)gamepadOpacity;              // 0.2..0.9
+ (void)setGamepadOpacity:(CGFloat)value;
+ (CGFloat)mouseSensitivity;            // 0.5..3
+ (void)setMouseSensitivity:(CGFloat)value;
+ (ALTouchMode)touchMode;
+ (void)setTouchMode:(ALTouchMode)value;

@end
