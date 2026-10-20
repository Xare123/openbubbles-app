// Outbound provider websocket to the existing registration relay. System TLS
// defaults only; no challenge handling is overridden anywhere in this app.
//
// All connection state (task, epoch, registration, intent, backoff) is
// confined to one serial state queue. Replies are bound to the exact task
// and epoch that admitted their command and are dropped after replacement.
#import <Foundation/Foundation.h>
#import "OBRelayDispatcher.h"
#import "OBRelayRegistrationStore.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OBRelayDefaultURLString;

@interface OBRelayConnection : NSObject
// Fixed status vocabulary only: connecting, registered, reconnecting,
// disconnected, registration-rejected. Handlers run on the main queue;
// codes arrive through codeHandler and are never logged.
@property(nonatomic, copy, nullable) void (^statusHandler)(NSString *status);
@property(nonatomic, copy, nullable) void (^codeHandler)(NSString *code);
- (instancetype)initWithDispatcher:(OBRelayDispatcher *)dispatcher
                             store:(OBRelayRegistrationStore *)store
                               url:(NSURL *)url;
- (void)connect;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
