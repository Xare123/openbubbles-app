#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSDictionary * _Nullable (^OBRelayPushNativeOperation)(NSDictionary *request);
typedef void (^OBRelayPushReply)(NSString *text);

@interface OBRelayPushService : NSObject
@property(nonatomic) double generationSeconds; // Default7, clamp to (0,7]. Tests only shorten it.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults operation:(OBRelayPushNativeOperation)operation;
- (void)invalidatePendingRequest;
- (void)handleCommand:(NSString *)command code:(NSString *)code requestID:(id)requestID reply:(OBRelayPushReply)reply;
@end
NS_ASSUME_NONNULL_END
