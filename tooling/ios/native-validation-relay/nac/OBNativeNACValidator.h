#import "OBNACValidator.h"

NS_ASSUME_NONNULL_BEGIN

// Device/IDS NAC only. This is not the AAAbsintheSigner account qualifier.
@interface OBNativeNACValidator : NSObject <OBNACValidating>
@property(atomic, copy, readonly) NSString *lastFailureCode;
@end

NS_ASSUME_NONNULL_END
