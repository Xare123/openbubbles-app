// Registration code/secret persistence. App-private NSUserDefaults only;
// the header/qualifier proofs and account material never pass through here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OBRelayRegistrationStore : NSObject
@property(nonatomic, copy, readonly) NSString *code;
@property(nonatomic, copy, readonly) NSString *secret;
// Saved trio is valid only for the exact relay URL it was issued against.
- (instancetype)initWithRelayURL:(NSURL *)relayURL;
// Testable storage boundary. Production uses the app's private standard defaults.
- (instancetype)initWithRelayURL:(NSURL *)relayURL defaults:(NSUserDefaults *)defaults;
- (BOOL)hasSavedRegistration;
// Registration request payload: empty for a first registration, otherwise
// code, secret and only the safe hardware model under versions.
- (NSDictionary *)registerDataWithHardwareModel:(nullable NSString *)hardwareModel;
// Accepts a server data object only when code and secret are non-empty
// strings; saves the trio together and returns the code for display.
- (nullable NSString *)acceptRegistrationData:(id)data;
@end

NS_ASSUME_NONNULL_END
