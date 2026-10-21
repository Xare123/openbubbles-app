// Command dispatch for the two provider operations.
//
// Concurrency contract: at most one native operation chain is in flight. A
// busy replacement gets an immediate unavailable response without queueing.
// A timed-out native chain blocks new generation until helper restart. Each
// deadline is measured from command admission, and
// every reply goes through the caller-supplied block bound to one exact
// connection task and epoch, so a late completion can never send on a
// replacement socket. Cancellation is cooperative at stage boundaries and
// by discard; the native calls themselves are not claimed interruptible.
#import <Foundation/Foundation.h>
#import "OBNACValidator.h"
#import "OBRelayGenerators.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^OBRelayReply)(NSString *text);

@interface OBRelayDispatcher : NSObject
// Total generation budget in seconds, default 45 and clamped to (0, 45].
// Set before use; present so Darwin tests can exercise the timeout path.
@property(nonatomic) double generationSeconds;
@property(nonatomic) BOOL nativePushEnabled;
- (instancetype)initWithHeaderGenerator:(id<OBRelayHeaderGenerating>)headerGenerator
                    qualifierGenerator:(id<OBRelayEmptyQualifierGenerating>)qualifierGenerator
                               validator:(id<OBNACValidating>)validator;
// Discard the old socket's reply while retaining any physical native-call
// reservation until completion. This does not claim to interrupt private APIs.
- (void)invalidatePendingRequest;
// identifiers is the already-read legacy versions map (used by
// get-version-info only; pass an empty dictionary for other commands).
// The reply block is called at most once, through its captured task/epoch;
// busy requests get no native proof. Unknown commands are ignored.
- (void)handleCommand:(NSString *)command
            requestID:(id)requestID
          identifiers:(NSDictionary<NSString *, NSString *> *)identifiers
                reply:(OBRelayReply)reply;
@end

NS_ASSUME_NONNULL_END
