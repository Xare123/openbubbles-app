// Canonical transient auth bundle carried as one extra STRING field inside
// the get-version-info versions map. Construction only; nothing is stored.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OBRelayAuthBundleField;

@interface OBRelayAuthBundle : NSObject
// Returns standard-base64 (no line breaks) of UTF-8 JSON with exactly the
// keys schema, headers, native_empty_qualifier and elapsed_ms, or nil when
// any input is outside the bounded canonical shape. No request body, host
// nonce or issued-at timestamp exists in this contract; client time already
// rides inside the native headers themselves.
+ (nullable NSString *)bundleStringWithHeaders:(NSDictionary *)headers
                                    qualifier:(NSData *)qualifier
                          elapsedMilliseconds:(long long)elapsedMilliseconds;
@end

NS_ASSUME_NONNULL_END
