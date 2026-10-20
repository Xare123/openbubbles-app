// Private one-exchange AuthKit header transport. No account login or persistence.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <poll.h>
#import <sys/utsname.h>
#include "native_headers_transport.h"

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
        for (NSString *required in @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-LU",
                @"X-Apple-I-MD-RINFO", @"X-Mme-Device-Id", @"X-Mme-Client-Info", @"X-Apple-I-Client-Time",
                @"X-Apple-I-SRL-NO", @"User-Agent"]) {
            if (!headers[required]) { *failure = @"native-header-incomplete"; return nil; }
        }
        if (!active()) { *failure = @"cancelled"; return nil; }
        return [headers copy];
    } @catch (NSException *exception) {
        (void)exception;
        *failure = @"native-exception";
        return nil;
    }
}

@interface OBNativeHeaderJob : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSDictionary *headers;
@property(nonatomic, strong) NSString *failure;
@property(nonatomic, strong) dispatch_semaphore_t ready;
@property(nonatomic) double deadline;
@property(nonatomic) BOOL done;
@property(nonatomic, copy) BOOL (^isCancelled)(void);
- (void)fail:(NSString *)failure;
- (void)start;
- (NSDictionary *)consume;
@end
@implementation OBNativeHeaderJob
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _ready = dispatch_semaphore_create(0); }
    return self;
}
- (BOOL)active {
    [self.lock lock];
    BOOL result = !self.done && (!self.isCancelled || !self.isCancelled())
        && OBNativeHeadersNow() < self.deadline;
    [self.lock unlock];
    return result;
}
- (void)fail:(NSString *)failure {
    [self.lock lock];
    if (!self.done) { self.done = YES; self.failure = failure; self.headers = nil; dispatch_semaphore_signal(self.ready); }
    [self.lock unlock];
}
- (void)start {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, self.deadline - OBNativeHeadersNow()) * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self fail:@"native-timeout"]; });
    dispatch_async(dispatch_queue_create("dev.openbubbles.diagnostics.accountsigning.header-native", DISPATCH_QUEUE_SERIAL), ^{
        if (![self active]) return;
        NSString *failure = nil;
        NSDictionary *headers = OBFetchNativeHeaders(^BOOL{ return [self active]; }, &failure);
        [self.lock lock];
        if (!self.done && OBNativeHeadersNow() < self.deadline) {
            self.done = YES; self.headers = headers; self.failure = failure ?: (headers ? nil : @"native-data-unavailable");
            dispatch_semaphore_signal(self.ready);
        }
        [self.lock unlock];
    });
}
- (NSDictionary *)consume {
    [self.lock lock];
    NSDictionary *result = self.done && !self.failure && self.headers && OBNativeHeadersNow() < self.deadline
        ? @{@"headers": self.headers, @"error": NSNull.null}
        : @{@"headers": @{}, @"error": self.failure ?: @"native-timeout"};
    self.headers = nil;
    [self.lock unlock];
    return result;
}
@end

@interface OBNativeHeadersBroker : NSObject
@property(atomic) BOOL cancelled;
- (void)startWithCompletion:(void (^)(NSString *, NSUInteger, long long))completion;
@end
static int OBNativeHeadersIsActive(double deadline, void *context) {
    return !((__bridge OBNativeHeadersBroker *)context).cancelled && OBNativeHeadersNow() < deadline;
}
static int OBNativeHeadersWaitEvent(int fd, short event, double deadline, void *context) {
    while (OBNativeHeadersIsActive(deadline, context)) {
        struct pollfd item = {.fd = fd, .events = event, .revents = 0};
        int result = poll(&item, 1, 100);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (item.revents & (POLLERR | POLLNVAL))) return 0;
        if (result > 0 && (item.revents & (event | POLLHUP))) return 1;
    }
    return 0;
}
static int OBNativeHeadersWaitRead(int fd, double deadline, void *context) {
    return OBNativeHeadersWaitEvent(fd, POLLIN, deadline, context);
}
static BOOL OBNativeHeadersSend(int fd, const void *bytes, size_t length, double deadline, void *context) {
    size_t offset = 0;
    while (offset < length && OBNativeHeadersWaitEvent(fd, POLLOUT, deadline, context)) {
        ssize_t count = send(fd, (const uint8_t *)bytes + offset, length - offset, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return NO;
        offset += (size_t)count;
    }
    return offset == length;
}
@implementation OBNativeHeadersBroker
- (void)startWithCompletion:(void (^)(NSString *, NSUInteger, long long))completion {
    dispatch_async(dispatch_queue_create("dev.openbubbles.diagnostics.accountsigning.header-io", DISPATCH_QUEUE_SERIAL), ^{
        @autoreleasepool {
            int listener = -1, peer = -1;
            OBNativeHeaderJob *job = nil;
            NSMutableData *wire = nil;
            NSString *disposition = @"header-transport-unavailable";
            NSUInteger count = 0;
            long long elapsed = 0;
            double totalDeadline = OBNativeHeadersNow() + 60;
            void *context = (__bridge void *)self;
            @try {
                listener = OBNativeHeadersListen();
                if (listener < 0) return;
                double acceptDeadline = MIN(totalDeadline, OBNativeHeadersNow() + 15);
                while (peer < 0 && OBNativeHeadersWaitRead(listener, acceptDeadline, context)) {
                    peer = accept(listener, NULL, NULL);
                    if (peer < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) break;
                }
                close(listener); listener = -1;
                if (peer < 0 || self.cancelled) { disposition = @"header-client-unavailable"; return; }
                int flags = fcntl(peer, F_GETFL, 0), noSignal = 1;
                if (flags < 0 || fcntl(peer, F_SETFL, flags | O_NONBLOCK) < 0
                    || fcntl(peer, F_SETFD, FD_CLOEXEC) < 0
                    || setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal)) != 0) return;
                char nonce[33];
                if (!OBNativeHeadersReadRequest(peer, nonce, MIN(totalDeadline, OBNativeHeadersNow() + 10),
                        OBNativeHeadersWaitRead, OBNativeHeadersIsActive, context)) {
                    disposition = @"header-request-invalid"; return;
                }
                double started = OBNativeHeadersNow();
                job = [OBNativeHeaderJob new];
                job.deadline = MIN(totalDeadline - 3, started + 45);
                job.isCancelled = ^BOOL{ return self.cancelled; };
                [job start];
                while (dispatch_semaphore_wait(job.ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)) != 0) {
                    if (!OBNativeHeadersIsActive(job.deadline, context)) {
                        [job fail:self.cancelled ? @"cancelled" : @"native-timeout"]; break;
                    }
                }
                NSDictionary *result = [job consume];
                if (self.cancelled) { disposition = @"cancelled"; return; }
                elapsed = (long long)((OBNativeHeadersNow() - started) * 1000);
                count = [result[@"headers"] count];
                NSDictionary *response = @{@"schema": @1, @"source_sha": @OB_SOURCE_SHA,
                    @"purpose": @"native-anisette-headers", @"nonce": [NSString stringWithUTF8String:nonce],
                    @"headers": result[@"headers"], @"elapsed_ms": @(elapsed), @"error": result[@"error"]};
                wire = [[NSJSONSerialization dataWithJSONObject:response options:0 error:NULL] mutableCopy];
                if (!wire.length || wire.length > 32768) { disposition = @"header-response-invalid"; return; }
                uint32_t size = htonl((uint32_t)wire.length);
                double deadline = MIN(totalDeadline, OBNativeHeadersNow() + 3);
                BOOL delivered = OBNativeHeadersSend(peer, &size, sizeof(size), deadline, context)
                    && OBNativeHeadersSend(peer, wire.bytes, wire.length, deadline, context);
                disposition = delivered ? (result[@"error"] == NSNull.null ? @"native-headers-delivered-login-unverified" : result[@"error"])
                    : @"header-delivery-failed";
            } @catch (NSException *exception) {
                (void)exception;
                disposition = @"header-internal-failure";
            } @finally {
                [job fail:@"cancelled"];
                if (wire.length) { [wire resetBytesInRange:NSMakeRange(0, wire.length)]; [wire setLength:0]; }
                if (peer >= 0) { shutdown(peer, SHUT_RDWR); close(peer); }
                if (listener >= 0) close(listener);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(disposition, count, elapsed); });
            }
        }
    });
}
@end
