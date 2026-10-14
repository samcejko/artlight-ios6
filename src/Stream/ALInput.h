#import <Foundation/Foundation.h>

// XInput button bits (the same values moonlight-common-c's LiSendMultiControllerEvent takes)
enum {
    ALPadDpadUp = 0x0001, ALPadDpadDown = 0x0002, ALPadDpadLeft = 0x0004, ALPadDpadRight = 0x0008,
    ALPadStart = 0x0010, ALPadBack = 0x0020, ALPadLeftThumb = 0x0040, ALPadRightThumb = 0x0080,
    ALPadLeftShoulder = 0x0100, ALPadRightShoulder = 0x0200, ALPadGuide = 0x0400,
    ALPadA = 0x1000, ALPadB = 0x2000, ALPadX = 0x4000, ALPadY = 0x8000,
};

typedef struct {
    uint16_t buttons;
    uint8_t leftTrigger, rightTrigger;      // 0..255
    int16_t leftX, leftY, rightX, rightY;   // -32768..32767, +Y up
} ALGamepadState;

// A key on the PC: a Windows virtual key code and the modifiers to hold (moonlight-common-c's MODIFIER_* bits)
typedef struct {
    uint16_t keycode;
    uint8_t modifiers;      // 0x01 shift, 0x02 ctrl, 0x04 alt, 0x08 meta (Windows key)
} ALKeyStroke;

enum { ALModShift = 0x01, ALModCtrl = 0x02, ALModAlt = 0x04, ALModMeta = 0x08 };

@interface ALInput : NSObject
// The key press that types one character on a US layout host (NO when there is no single key for it: such
// characters go to the PC as UTF-8 text instead)
+ (BOOL)keyStroke:(ALKeyStroke *)out forCharacter:(unichar)character;
// "escape", "enter", "tab", "backspace", "space", "shift", "ctrl", "alt", "win", "f1".."f12", "up", "down",
// "left", "right", "home", "end", "pageup", "pagedown", "delete", "insert", "capslock", "menu", "printscreen"
+ (ALKeyStroke)keyNamed:(NSString *)name;
@end
