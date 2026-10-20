// Device identity strings for the legacy versions response. Values are read
// fresh on the device; nothing is logged or persisted by this helper.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OBRelayIdentifiers : NSObject
// The six legacy string fields. A field is present only when its system
// source returned a non-empty string; callers treat a short map as
// capability-absent for the auth bundle.
+ (NSDictionary<NSString *, NSString *> *)versionIdentifiers;
// utsname machine only, the single value sent at registration time.
+ (nullable NSString *)hardwareModel;
@end

NS_ASSUME_NONNULL_END
