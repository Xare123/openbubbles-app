// Native AuthKit header fetch, reused from this project's tested Signing5
// diagnostic (tooling/ios/account-signing-preflight/native_headers_broker.h,
// helpers and OBFetchNativeHeaders only; socket transport excluded).
// Project-owned source; see ../README.md provenance. No account login,
// provisioning, persistence or logging of header values occurs here.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <string.h>

#import "OBRelayGenerators.h"

static double OBNativeHeadersNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL OBNativeHeaderMethod(Method method, unsigned arguments, char result) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != result) return NO;
    for (unsigned i = 2; i < arguments; ++i) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (type[0] != '@' || type[1] == '?') return NO;
    }
    return YES;
}
static BOOL OBNativeHeaderASCII(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 4096) return NO;
    for (NSUInteger i = 0; i < [value length]; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return YES;
}
static NSArray<NSString *> *OBNativeHeaderNames(void) {
    return @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-LU", @"X-Apple-I-MD-RINFO",
        @"X-Mme-Device-Id", @"X-Mme-Client-Info", @"X-Apple-I-Client-Time",
        @"X-Apple-I-TimeZone", @"X-Apple-Locale", @"X-Apple-I-SRL-NO", @"User-Agent"];
}
static BOOL OBNativeHeaderMerge(NSMutableDictionary *target, id incoming) {
    if (![incoming isKindOfClass:NSDictionary.class] || [incoming count] > 32) return NO;
    for (id key in incoming) {
        if (![key isKindOfClass:NSString.class]) return NO;
        for (NSString *canonical in OBNativeHeaderNames()) {
            if ([canonical caseInsensitiveCompare:key] != NSOrderedSame) continue;
            id value = incoming[key];
            if (target[canonical] || !OBNativeHeaderASCII(value)) return NO;
            target[canonical] = value;
            break;
        }
    }
    return YES;
}

/* Build the native dictionary from explicitly NO-provision data and native
 * category factories. No guessed client ID, Xcode identity, convenience fetch,
 * account object, URLSession, password, provisioning or erase fallback.
 */
static NSDictionary *OBFetchNativeHeaders(BOOL (^active)(void), NSString **failure) {
    @try {
        static void *framework;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            framework = dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW | RTLD_LOCAL);
        });
        if (!framework || !active()) { *failure = @"native-context-unavailable"; return nil; }
        Class controllerClass = NSClassFromString(@"AKAnisetteProvisioningController");
        SEL fetch = NSSelectorFromString(@"fetchAnisetteDataAndProvisionIfNecessary:error:");
        Method method = class_getInstanceMethod(controllerClass, fetch);
        char provisionType[16] = {0}, errorType[16] = {0}, resultType[16] = {0};
        if (method) {
            method_getArgumentType(method, 2, provisionType, sizeof(provisionType));
            method_getArgumentType(method, 3, errorType, sizeof(errorType));
            method_getReturnType(method, resultType, sizeof(resultType));
        }
        if (!method || method_getNumberOfArguments(method) != 4 || resultType[0] != '@'
            || (strcmp(provisionType, "B") != 0 && strcmp(provisionType, "c") != 0)
            || strcmp(errorType, "^@") != 0) { *failure = @"native-fetch-abi-unavailable"; return nil; }
        id controller = [controllerClass new];
        if (!controller || !active()) { *failure = @"cancelled"; return nil; }
        NSError *error = nil;
        id data = ((id (*)(id, SEL, BOOL, NSError **))objc_msgSend)(controller, fetch, NO, &error);
        if (!active() || error || !data) { *failure = @"native-data-unavailable"; return nil; }
        Class dataClass = object_getClass(data);
        SEL machine = NSSelectorFromString(@"machineID"), otp = NSSelectorFromString(@"oneTimePassword");
        SEL routing = NSSelectorFromString(@"routingInfo");
        if (!OBNativeHeaderMethod(class_getInstanceMethod(dataClass, machine), 2, '@')
            || !OBNativeHeaderMethod(class_getInstanceMethod(dataClass, otp), 2, '@')
            || !OBNativeHeaderMethod(class_getInstanceMethod(dataClass, routing), 2, 'Q')
            || !OBNativeHeaderASCII(((id (*)(id, SEL))objc_msgSend)(data, machine))
            || !OBNativeHeaderASCII(((id (*)(id, SEL))objc_msgSend)(data, otp))
            || ((unsigned long long (*)(id, SEL))objc_msgSend)(data, routing) == 0) {
            *failure = @"native-data-incomplete"; return nil;
        }
        NSMutableDictionary *headers = [NSMutableDictionary new];
        Class requestClass = NSMutableURLRequest.class;
        SEL format = NSSelectorFromString(@"ak_anisetteHeadersWithData:");
        if (!OBNativeHeaderMethod(class_getClassMethod(requestClass, format), 3, '@')) {
            *failure = @"native-header-factory-unavailable"; return nil;
        }
        if (!active()) { *failure = @"cancelled"; return nil; }
        id values = ((id (*)(id, SEL, id))objc_msgSend)(requestClass, format, data);
        if (!OBNativeHeaderMerge(headers, values)) { *failure = @"native-header-invalid"; return nil; }
        for (NSString *name in @[@"ak_clientInfoHeader", @"ak_clientTimeHeader", @"ak_deviceUDIDHeader",
                @"ak_localeHeader", @"ak_timeZoneHeader"]) {
            if (!active()) { *failure = @"cancelled"; return nil; }
            SEL selector = NSSelectorFromString(name);
            if (!OBNativeHeaderMethod(class_getClassMethod(requestClass, selector), 2, '@')) {
                *failure = @"native-header-factory-unavailable"; return nil;
            }
            values = ((id (*)(id, SEL))objc_msgSend)(requestClass, selector);
            if (!OBNativeHeaderMerge(headers, values)) { *failure = @"native-header-invalid"; return nil; }
        }
        SEL serial = NSSelectorFromString(@"ak_addDeviceSerialNumberHeader");
        if (!OBNativeHeaderMethod(class_getInstanceMethod(requestClass, serial), 2, 'v')) {
            *failure = @"native-serial-factory-unavailable"; return nil;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest new];
        ((void (*)(id, SEL))objc_msgSend)(request, serial);
        // Older native formatters need not include the local-user header.
        // Ask the same runtime factory only when absent, never invent a UUID.
        if (!headers[@"X-Apple-I-MD-LU"]) {
            SEL localUser = NSSelectorFromString(@"ak_addLocalUserUUIDHashHeader");
            Method localUserMethod = class_getInstanceMethod(requestClass, localUser);
            if (localUserMethod && !OBNativeHeaderMethod(localUserMethod, 2, 'v')) {
                *failure = @"native-local-user-factory-unavailable"; return nil;
            }
            if (localUserMethod) {
                if (!active()) { *failure = @"cancelled"; return nil; }
                ((void (*)(id, SEL))objc_msgSend)(request, localUser);
            }
        }
        if (!OBNativeHeaderMerge(headers, request.allHTTPHeaderFields)) { *failure = @"native-header-invalid"; return nil; }
        // The saved relay user-agent can belong to an older/different platform.
        // Read actual public runtime versions; never borrow a Mac/Android value.
        NSBundle *networkBundle = [NSBundle bundleWithIdentifier:@"com.apple.CFNetwork"];
        if (!networkBundle) networkBundle = [NSBundle bundleWithPath:@"/System/Library/Frameworks/CFNetwork.framework"];
        NSString *networkVersion = networkBundle.infoDictionary[@"CFBundleVersion"];
        struct utsname kernel;
        NSString *kernelVersion = uname(&kernel) == 0 ? [NSString stringWithUTF8String:kernel.release] : nil;
        NSString *versionPattern = @"\\A[0-9]{1,8}(?:\\.[0-9]{1,8}){1,5}\\z";
        if (!OBNativeHeaderASCII(networkVersion) || !OBNativeHeaderASCII(kernelVersion)
            || [networkVersion rangeOfString:versionPattern options:NSRegularExpressionSearch].location == NSNotFound
            || [kernelVersion rangeOfString:versionPattern options:NSRegularExpressionSearch].location == NSNotFound) {
            *failure = @"native-system-context-unavailable"; return nil;
        }
        headers[@"User-Agent"] = [NSString stringWithFormat:@"akd/1.0 CFNetwork/%@ Darwin/%@", networkVersion, kernelVersion];
        for (NSString *required in @[@"X-Apple-I-MD", @"X-Apple-I-MD-M",
                @"X-Apple-I-MD-RINFO", @"X-Mme-Device-Id", @"X-Mme-Client-Info", @"X-Apple-I-Client-Time",
                @"X-Apple-I-SRL-NO", @"User-Agent"]) {
            if (!headers[required]) {
                // `required` is a fixed allowlisted name, never a header value.
                *failure = [@"native-header-missing-" stringByAppendingString:required];
                return nil;
            }
        }
        if (!active()) { *failure = @"cancelled"; return nil; }
        return [headers copy];
    } @catch (NSException *exception) {
        (void)exception;
        *failure = @"native-exception";
        return nil;
    }
}

@interface OBRelayHeaderGenerator ()
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation OBRelayHeaderGenerator
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("dev.openbubbles.relay.native.headers", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)fetchHeadersWithDeadline:(double)deadline
                       completion:(void (^)(NSDictionary * _Nullable))completion {
    dispatch_async(self.queue, ^{
        NSString *failure = nil;
        NSDictionary *headers = OBNativeHeadersNow() < deadline
            ? OBFetchNativeHeaders(^BOOL{ return OBNativeHeadersNow() < deadline; }, &failure)
            : nil;
        completion(headers);
    });
}
@end
