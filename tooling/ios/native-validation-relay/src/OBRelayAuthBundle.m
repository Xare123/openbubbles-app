#import "OBRelayAuthBundle.h"

NSString *const OBRelayAuthBundleField = @"ob_auth_bundle_v1";

// This list must stay set-equal to OBNativeHeaderNames in
// OBRelayHeaderGenerator.m; the synthetic stage tests assert that.
static NSArray<NSString *> *OBRelayCanonicalHeaderNames(void) {
    return @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-LU", @"X-Apple-I-MD-RINFO",
        @"X-Mme-Device-Id", @"X-Mme-Client-Info", @"X-Apple-I-Client-Time",
        @"X-Apple-I-TimeZone", @"X-Apple-Locale", @"X-Apple-I-SRL-NO", @"User-Agent"];
}

static NSArray<NSString *> *OBRelayRequiredHeaderNames(void) {
    return @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-RINFO",
        @"X-Mme-Device-Id", @"X-Mme-Client-Info", @"X-Apple-I-Client-Time",
        @"X-Apple-I-SRL-NO", @"User-Agent"];
}

static BOOL OBRelayBundleASCII(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 4096) return NO;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return YES;
}

@implementation OBRelayAuthBundle
+ (NSString *)bundleStringWithHeaders:(NSDictionary *)headers
                            qualifier:(NSData *)qualifier
                  elapsedMilliseconds:(long long)elapsedMilliseconds {
    if (![headers isKindOfClass:NSDictionary.class] || ![qualifier isKindOfClass:NSData.class]
        || qualifier.length == 0 || qualifier.length > 2048
        || elapsedMilliseconds < 0 || elapsedMilliseconds > 45000) return nil;
    NSSet<NSString *> *allowed = [NSSet setWithArray:OBRelayCanonicalHeaderNames()];
    if (headers.count > allowed.count) return nil;
    NSMutableDictionary *canonical = [NSMutableDictionary new];
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]
            || !OBRelayBundleASCII(headers[key])) return nil;
        canonical[key] = headers[key];
    }
    for (NSString *required in OBRelayRequiredHeaderNames())
        if (!canonical[required]) return nil;
    NSDictionary *bundle = @{
        @"schema": @1,
        @"headers": [canonical copy],
        @"native_empty_qualifier": [qualifier base64EncodedStringWithOptions:0],
        @"elapsed_ms": @(elapsedMilliseconds),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:bundle
        options:NSJSONWritingSortedKeys error:NULL];
    if (!json.length || json.length > 16384) return nil;
    return [json base64EncodedStringWithOptions:0];
}
@end
