#import "OBRelayRegistrationStore.h"

static NSString *const OBRelaySavedCodeKey = @"dev.openbubbles.relay.savedCode";
static NSString *const OBRelaySavedSecretKey = @"dev.openbubbles.relay.savedSecret";
static NSString *const OBRelaySavedURLKey = @"dev.openbubbles.relay.savedURL";
static NSString *const OBRelayRegistrationKey = @"dev.openbubbles.relay.registration-v1";

static BOOL OBRelayValidPair(id code, id secret) {
    if (![code isKindOfClass:NSString.class] || ![secret isKindOfClass:NSString.class]
        || [code length] != 19 || [secret length] == 0 || [secret length] > 64) return NO;
    NSString *pattern = @"\\A[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}\\z";
    if ([code rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    for (NSUInteger i = 0; i < [secret length]; ++i) {
        unichar c = [secret characterAtIndex:i];
        if (c < 0x21 || c > 0x7e) return NO;
    }
    return YES;
}

@interface OBRelayRegistrationStore ()
@property(nonatomic, copy) NSURL *relayURL;
@property(nonatomic, copy, readwrite) NSString *code;
@property(nonatomic, copy, readwrite) NSString *secret;
@property(nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation OBRelayRegistrationStore
- (instancetype)initWithRelayURL:(NSURL *)relayURL {
    return [self initWithRelayURL:relayURL defaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithRelayURL:(NSURL *)relayURL defaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _relayURL = [relayURL copy];
        _defaults = defaults;
        id record = [defaults objectForKey:OBRelayRegistrationKey];
        id code = nil, secret = nil, url = nil;
        if ([record isKindOfClass:NSDictionary.class]) {
            code = record[@"code"]; secret = record[@"secret"]; url = record[@"url"];
        } else {
            // Read old tuples without deleting or rewriting their recovery data.
            code = [defaults objectForKey:OBRelaySavedCodeKey];
            secret = [defaults objectForKey:OBRelaySavedSecretKey];
            url = [defaults objectForKey:OBRelaySavedURLKey];
        }
        if (OBRelayValidPair(code, secret) && [url isKindOfClass:NSString.class]
            && [url isEqualToString:relayURL.absoluteString]) {
            _code = [code copy];
            _secret = [secret copy];
        }
    }
    return self;
}

- (BOOL)hasSavedRegistration {
    return self.code.length > 0 && self.secret.length > 0;
}

- (NSDictionary *)registerDataWithHardwareModel:(NSString *)hardwareModel {
    NSMutableDictionary *data = [NSMutableDictionary new];
    if (self.hasSavedRegistration) {
        data[@"code"] = self.code;
        data[@"secret"] = self.secret;
    }
    if (hardwareModel.length) data[@"versions"] = @{@"hardware_version": hardwareModel};
    return [data copy];
}

- (NSString *)acceptRegistrationData:(id)data {
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    id code = data[@"code"], secret = data[@"secret"];
    if (!OBRelayValidPair(code, secret)) return nil;
    self.code = code;
    self.secret = secret;
    // One dictionary assignment keeps the issued tuple consistent across restart.
    // Explicitly select fields; never persist arbitrary server response data.
    [self.defaults setObject:@{@"code":code, @"secret":secret,
        @"url":self.relayURL.absoluteString} forKey:OBRelayRegistrationKey];
    return code;
}
@end
