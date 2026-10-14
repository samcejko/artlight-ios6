#import <UIKit/UIKit.h>
#import "ALHost.h"

// The game on screen: the stream session (moonlight-common-c), hardware decoding into the GL view, audio, the
// on-screen gamepad, touch as mouse (trackpad, direct pointer or real touch), keyboard, and the in-stream menu
// (keyboard, gamepad, statistics, Apollo's PC commands and clipboard, disconnect, quit).
@interface ALStreamViewController : UIViewController
- (instancetype)initWithHost:(ALHost *)host app:(ALApp *)app;
@property (nonatomic, copy) void (^onFinished)(NSString *message);   // called once when the stream is over (message may be nil)
// Debug hook (artlight:stream?...): "key" with name, "type" with text, "pad" with buttons, "mouse" with dx/dy,
// "keyframe", "disconnect", "quit"
- (void)debugCommand:(NSString *)command params:(NSDictionary *)params;
- (NSString *)debugDescription;
@end
