#import "ALInput.h"

@implementation ALInput

+ (BOOL)keyStroke:(ALKeyStroke *)out forCharacter:(unichar)c
{
    ALKeyStroke k = { 0, 0 };
    if (c == ' ') { k.keycode = 0x20; *out = k; return YES; }
    if (c == '\n' || c == '\r') { *out = [self keyNamed:@"enter"]; return YES; }
    if (c == '\t') { *out = [self keyNamed:@"tab"]; return YES; }
    if (c >= '0' && c <= '9') { k.keycode = (uint16_t)c; *out = k; return YES; }
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
        unichar upper = (unichar)((c >= 'a' && c <= 'z') ? c - 32 : c);
        k.keycode = (uint16_t)upper;
        if (c >= 'A' && c <= 'Z') k.modifiers = ALModShift;
        *out = k;
        return YES;
    }
    static const struct { unichar shifted, base; } shifted[] = {
        {'!','1'},{'@','2'},{'#','3'},{'$','4'},{'%','5'},{'^','6'},{'&','7'},{'*','8'},{'(','9'},{')','0'},{'_','-'},{'+','='},
        {'{','['},{'}',']'},{'|','\\'},{':',';'},{'"','\''},{'<',','},{'>','.'},{'?','/'},{'~','`'} };
    for (size_t i = 0; i < sizeof(shifted) / sizeof(shifted[0]); i++) {
        if (shifted[i].shifted == c) {
            if (![self keyStroke:&k forCharacter:shifted[i].base]) return NO;
            k.modifiers |= ALModShift;
            *out = k;
            return YES;
        }
    }
    static const struct { unichar ch; uint16_t vk; } punct[] = {
        {'-',0xBD},{'=',0xBB},{'[',0xDB},{']',0xDD},{'\\',0xDC},{';',0xBA},{'\'',0xDE},{',',0xBC},{'.',0xBE},{'/',0xBF},{'`',0xC0} };
    for (size_t i = 0; i < sizeof(punct) / sizeof(punct[0]); i++) {
        if (punct[i].ch == c) { k.keycode = punct[i].vk; *out = k; return YES; }
    }
    return NO;
}

+ (ALKeyStroke)keyNamed:(NSString *)name
{
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{ @"escape": @0x1B, @"enter": @0x0D, @"tab": @0x09, @"backspace": @0x08, @"space": @0x20,
                   @"shift": @0xA0, @"ctrl": @0xA2, @"alt": @0xA4, @"win": @0x5B, @"menu": @0x5D, @"capslock": @0x14,
                   @"f1": @0x70, @"f2": @0x71, @"f3": @0x72, @"f4": @0x73, @"f5": @0x74, @"f6": @0x75,
                   @"f7": @0x76, @"f8": @0x77, @"f9": @0x78, @"f10": @0x79, @"f11": @0x7A, @"f12": @0x7B,
                   @"left": @0x25, @"up": @0x26, @"right": @0x27, @"down": @0x28,
                   @"home": @0x24, @"end": @0x23, @"pageup": @0x21, @"pagedown": @0x22, @"delete": @0x2E, @"insert": @0x2D,
                   @"printscreen": @0x2C };
    });
    ALKeyStroke k = { 0, 0 };
    NSNumber *v = table[[name lowercaseString]];
    if (v) k.keycode = [v unsignedShortValue];
    return k;
}

@end
