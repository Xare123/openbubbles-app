#import "OBNACValidator.h"

@implementation OBUnavailableNACValidator
- (void)generateValidationDataWithDeadline:(double)deadline
                                completion:(void (^)(NSData * _Nullable))completion {
    (void)deadline;
    completion(nil);
}
@end
