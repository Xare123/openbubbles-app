// Generator seams for the relay. Implementations never log, persist or
// return values outside their single completion call.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol OBRelayHeaderGenerating <NSObject>
// Completion receives the bounded canonical header dictionary, or nil on any
// failure. It is called exactly once, on the generator's own serial queue.
- (void)fetchHeadersWithDeadline:(double)deadline
                       completion:(void (^)(NSDictionary * _Nullable headers))completion;
@end

@protocol OBRelayEmptyQualifierGenerating <NSObject>
// Completion receives ownership of a mutable empty-data proof, or nil. The
// caller must wipe it with OBRelayWipe after encoding. Exactly one call.
- (void)generateEmptyQualifierWithDeadline:(double)deadline
                                completion:(void (^)(NSMutableData * _Nullable proof))completion;
@end

static inline void OBRelayWipe(NSMutableData * _Nullable data) {
    if (data.length) {
        [data resetBytesInRange:NSMakeRange(0, data.length)];
        [data setLength:0];
    }
}

@interface OBRelayHeaderGenerator : NSObject <OBRelayHeaderGenerating>
@end

@interface OBRelayEmptyQualifierGenerator : NSObject <OBRelayEmptyQualifierGenerating>
@end

NS_ASSUME_NONNULL_END
