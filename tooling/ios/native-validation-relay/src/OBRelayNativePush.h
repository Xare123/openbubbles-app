#import <Foundation/Foundation.h>

// Input is an authenticated, bounded OBRelayPushProtocol request. Only public
// certificate and an operation-bound signature can leave this function.
NSDictionary * _Nullable OBRelayNativePushResult(NSDictionary *request);
