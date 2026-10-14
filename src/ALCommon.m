#import "ALCommon.h"

#include <mach/mach_time.h>

NSString * const ALErrorDomain                   = @"com.samcejko.artlight";
NSString * const ALThemeDidChangeNotification     = @"ALThemeDidChangeNotification";
NSString * const ALSettingsDidChangeNotification  = @"ALSettingsDidChangeNotification";
NSString * const ALHostsDidChangeNotification     = @"ALHostsDidChangeNotification";
NSString * const ALBoxArtDidLoadNotification      = @"ALBoxArtDidLoadNotification";

NSError *ALMakeError(NSInteger code, NSString *message)
{
    if (!message) message = @"Unknown error";
    return [NSError errorWithDomain:ALErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

uint64_t ALMonotonicMicros(void)
{
    static mach_timebase_info_data_t info;
    if (info.denom == 0) mach_timebase_info(&info);
    uint64_t t = mach_absolute_time();
    return (t * info.numer / info.denom) / 1000ULL;
}

NSString *ALHexString(NSData *data)
{
    static const char digits[] = "0123456789ABCDEF";
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    char *out = malloc(n * 2 + 1);
    if (!out) return @"";
    for (NSUInteger i = 0; i < n; i++) {
        out[2 * i] = digits[b[i] >> 4];
        out[2 * i + 1] = digits[b[i] & 15];
    }
    out[n * 2] = 0;
    NSString *s = [NSString stringWithUTF8String:out];
    free(out);
    return s ?: @"";
}

static int ALHexNibble(unichar c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

NSData *ALDataFromHex(NSString *hex)
{
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger n = s.length / 2;
    if (s.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *b = data.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        int hi = ALHexNibble([s characterAtIndex:2 * i]), lo = ALHexNibble([s characterAtIndex:2 * i + 1]);
        if (hi < 0 || lo < 0) return nil;
        b[i] = (uint8_t)((hi << 4) | lo);
    }
    return data;
}
