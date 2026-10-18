// Separate, human-armed, one-exchange fixture. Proofs have no disk/log/UI path.
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#include "request_reader.h"

#if !defined(OB_SOURCE_SHA) || !defined(OB_FIXTURE_BODY_SHA256) || !defined(OB_FIXTURE_JSON_SHA256)
#error Exact source and bundled fixture hashes are required
#endif

static NSString *const OBBundle = @"dev.openbubbles.diagnostics.accountqualifier";
enum { OBPort = 49173, OBHeaderBytes = OBFixtureRequestBytes, OBMaxBody = 8192,
       OBMaxMetadata = 2048, OBMaxSignature = 2048, OBMaxReply = 16384 };
static const double OBArmSeconds = 120, OBHeaderSeconds = 10;
static const double OBSigningSeconds = 45, OBExchangeSeconds = 54, OBReplySeconds = 3;

static double OBNow(void) { return NSProcessInfo.processInfo.systemUptime; }

static void OBErase(NSMutableData *data) {
    if (data.length) {
        [data resetBytesInRange:NSMakeRange(0, data.length)];
        [data setLength:0];
    }
}

static BOOL OBKeys(id value, NSArray<NSString *> *keys) {
    return [value isKindOfClass:NSDictionary.class]
        && [[NSSet setWithArray:[value allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL OBMatches(id value, NSString *pattern) {
    return [value isKindOfClass:NSString.class]
        && [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL OBASCII(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > maximum) return NO;
    for (NSUInteger i = 0; i < [value length]; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return YES;
}

static NSString *OBSHA(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSData *OBReadBundle(NSString *name, NSString *extension, NSUInteger maximum) {
    NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:extension];
    if (!url) return nil;
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    NSMutableData *data = nil;
    struct stat before, after;
    if (fstat(fd, &before) == 0 && S_ISREG(before.st_mode)
        && before.st_size > 0 && (uint64_t)before.st_size <= maximum) {
        data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
        NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { data = nil; break; }
            offset += (NSUInteger)count;
        }
        if (fstat(fd, &after) != 0 || before.st_size != after.st_size) data = nil;
    }
    close(fd);
    return data;
}

static BOOL OBLoadFixture(NSDictionary **outInfo, NSData **outBody) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:OBBundle]
        || !OBMatches(@OB_SOURCE_SHA, @"\\A[0-9a-f]{40}\\z")) return NO;
    NSData *metadata = OBReadBundle(@"fixture", @"json", OBMaxMetadata);
    NSData *body = OBReadBundle(@"body", @"plist", OBMaxBody);
    if (!metadata || !body || ![OBSHA(metadata) isEqualToString:@OB_FIXTURE_JSON_SHA256]
        || ![OBSHA(body) isEqualToString:@OB_FIXTURE_BODY_SHA256]) return NO;
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:metadata options:0 error:NULL];
    if (!OBKeys(info, @[@"schema", @"run_id", @"client_id", @"body_sha256"])) return NO;
    id schema = info[@"schema"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID()
        || CFNumberIsFloatType((__bridge CFNumberRef)schema) || [schema integerValue] != 1
        || !OBMatches(info[@"run_id"], @"\\A[0-9a-f]{32}\\z")
        || !OBMatches(info[@"client_id"], @"\\A[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\\z")
        || ![info[@"body_sha256"] isEqualToString:@OB_FIXTURE_BODY_SHA256]) return NO;
    NSPropertyListFormat format = 0;
    NSDictionary *value = [NSPropertyListSerialization propertyListWithData:body
        options:NSPropertyListImmutable format:&format error:NULL];
    if (format != NSPropertyListXMLFormat_v1_0 || !OBKeys(value, @[@"protocolVersion", @"userInfo", @"delegates"])
        || ![value[@"protocolVersion"] isEqual:@"1.0"]) return NO;
    NSDictionary *user = value[@"userInfo"], *delegates = value[@"delegates"];
    if (!OBKeys(user, @[@"client-id", @"language", @"timezone"])
        || ![user[@"client-id"] isEqual:info[@"client_id"]]
        || !OBASCII(user[@"language"], 64) || !OBASCII(user[@"timezone"], 128)
        || !OBKeys(delegates, @[@"com.apple.private.ids", @"com.apple.mobileme"])
        || !OBKeys(delegates[@"com.apple.mobileme"], @[])
        || !OBKeys(delegates[@"com.apple.private.ids"], @[@"protocol-version"])
        || ![delegates[@"com.apple.private.ids"][@"protocol-version"] isEqual:@"4"]) return NO;
    *outInfo = info;
    *outBody = body; // Original frozen bytes, never reserialized before signing.
    return YES;
}

@interface OBRunControl : NSObject
@property(atomic) BOOL cancelled;
@property(atomic) BOOL accepted;
@property(nonatomic) double armDeadline;
@end
@implementation OBRunControl
@end

// Only the I/O worker owns descriptors. No timer or native callback closes one.
static void OBClose(int *ownedFD) {
    int fd = *ownedFD;
    *ownedFD = -1;
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
}

static BOOL OBNonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

static BOOL OBWait(int fd, short events, double deadline, OBRunControl *control) {
    while (!control.cancelled && OBNow() < deadline) {
        double remaining = deadline - OBNow();
        if (remaining <= 0) break;
        int milliseconds = (int)MIN(100.0, MAX(1.0, remaining * 1000));
        struct pollfd item = { .fd = fd, .events = events, .revents = 0 };
        int result = poll(&item, 1, milliseconds);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (item.revents & (POLLERR | POLLNVAL))) return NO;
        if (result > 0 && (item.revents & (events | POLLHUP))) return YES;
    }
    return NO;
}

static int OBListen(void) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(OBPort);
    if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1 || !OBNonblocking(fd)
        || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 1) != 0) {
        OBClose(&fd);
        return -1;
    }
    return fd;
}

static int OBRequestActive(double deadline, void *context) {
    OBRunControl *control = (__bridge OBRunControl *)context;
    return !control.cancelled && OBNow() < deadline;
}

static int OBRequestWait(int fd, double deadline, void *context) {
    return OBWait(fd, POLLIN, deadline, (__bridge OBRunControl *)context);
}

static BOOL OBReadRequest(int fd, NSString *runID, double deadline, OBRunControl *control) {
    // Shared real reader: fixed OBQUAL2 frame, no EOF or half-close requirement.
    return OBFixtureReadRequest(fd, runID.UTF8String, deadline,
        OBRequestWait, OBRequestActive, (__bridge void *)control);
}

static BOOL OBSendAll(int fd, const void *bytes, NSUInteger length, double deadline, OBRunControl *control) {
    NSUInteger sent = 0;
    while (sent < length) {
        if (!OBWait(fd, POLLOUT, deadline, control)) return NO;
        ssize_t count = send(fd, (const uint8_t *)bytes + sent, length - sent, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return NO;
        sent += (NSUInteger)count;
    }
    return YES;
}

static BOOL OBMethodHasType(Method method, unsigned arguments, char result) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char encoding[16] = {0};
    method_getReturnType(method, encoding, sizeof(encoding));
    return encoding[0] == result;
}

@interface OBSigningJob : NSObject {
    NSLock *_lock;
    dispatch_semaphore_t _ready;
    dispatch_queue_t _nativeQueue;
    NSData *_body;
    NSMutableData *_emptySignature;
    NSMutableData *_bodySignature;
    NSString *_error;
    double _deadline;
    NSUInteger _phase;
    BOOL _done, _consumed;
}
- (instancetype)initWithBody:(NSData *)body deadline:(double)deadline;
- (void)start;
- (void)fail:(NSString *)error;
- (BOOL)waitUntil:(double)deadline;
- (NSDictionary *)consumeResult;
- (void)discard;
@end

@implementation OBSigningJob
- (instancetype)initWithBody:(NSData *)body deadline:(double)deadline {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _ready = dispatch_semaphore_create(0);
        _nativeQueue = dispatch_queue_create("dev.openbubbles.diagnostics.accountqualifier.native", DISPATCH_QUEUE_SERIAL);
        _body = body;
        _deadline = deadline;
    }
    return self;
}
- (void)clearLocked {
    OBErase(_emptySignature); OBErase(_bodySignature);
    _emptySignature = nil; _bodySignature = nil;
}
- (void)fail:(NSString *)error {
    [_lock lock];
    if (!_done) {
        _done = YES; _error = error;
        [self clearLocked];
        dispatch_semaphore_signal(_ready);
    }
    [_lock unlock];
}
- (BOOL)activePhase:(NSUInteger)phase {
    [_lock lock];
    BOOL active = !_done && _phase == phase && OBNow() < _deadline;
    [_lock unlock];
    return active;
}
- (void)invokePhase:(NSUInteger)phase signer:(id)signer payload:(NSData *)payload {
    if (![self activePhase:phase]) { [self fail:@"signing-timeout"]; return; }
    SEL selector = NSSelectorFromString(@"signatureForData:completion:");
    void (^reply)(NSData *, NSError *) = ^(NSData *signature, NSError *error) {
        // Single lock rejects duplicate/late callbacks before retaining any proof.
        [self->_lock lock];
        if (self->_done || self->_phase != phase || OBNow() >= self->_deadline) {
            [self->_lock unlock];
            return;
        }
        BOOL valid = !error && [signature isKindOfClass:NSData.class]
            && signature.length > 0 && signature.length <= OBMaxSignature;
        if (!valid) {
            self->_done = YES;
            self->_error = @"native-signing-failed";
            [self clearLocked];
            dispatch_semaphore_signal(self->_ready);
            [self->_lock unlock];
            return;
        }
        if (phase == 1) self->_emptySignature = [signature mutableCopy];
        else self->_bodySignature = [signature mutableCopy];
        self->_phase = phase + 1;
        if (phase == 2) {
            self->_done = YES;
            dispatch_semaphore_signal(self->_ready);
        }
        [self->_lock unlock];
        if (phase == 1) dispatch_async(self->_nativeQueue, ^{
            [self invokePhase:2 signer:signer payload:self->_body];
        });
    };
    @try {
        // Same factory result for both calls. No account object or signing-session injection.
        if ([self activePhase:phase])
            ((void (*)(id, SEL, NSData *, void (^)(NSData *, NSError *)))objc_msgSend)(signer, selector, payload, reply);
    } @catch (NSException *exception) {
        (void)exception;
        [self fail:@"native-exception"];
    }
}
- (void)start {
    // Install the main-queue observer BEFORE native dispatch/factory/load.
    double remaining = MAX(0.0, _deadline - OBNow());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self fail:@"signing-timeout"]; });
    dispatch_async(_nativeQueue, ^{
        [self->_lock lock];
        BOOL active = !self->_done && OBNow() < self->_deadline;
        if (active) self->_phase = 1;
        [self->_lock unlock];
        if (!active) { [self fail:@"signing-timeout"]; return; }
        @try {
            static void *framework;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                framework = dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount", RTLD_NOW | RTLD_LOCAL);
            });
            if (!framework) { [self fail:@"framework-unavailable"]; return; }
            Class signerClass = NSClassFromString(@"AAAbsintheSigner");
            SEL factory = NSSelectorFromString(@"sharedSigner");
            if (!OBMethodHasType(class_getClassMethod(signerClass, factory), 2, '@')) {
                [self fail:@"factory-unavailable"]; return;
            }
            if (![self activePhase:1]) return;
            id signer = ((id (*)(id, SEL))objc_msgSend)(signerClass, factory);
            Method method = class_getInstanceMethod(object_getClass(signer), NSSelectorFromString(@"signatureForData:completion:"));
            char payloadType[8] = {0}, completionType[8] = {0};
            if (method) {
                method_getArgumentType(method, 2, payloadType, sizeof(payloadType));
                method_getArgumentType(method, 3, completionType, sizeof(completionType));
            }
            if (!signer || !OBMethodHasType(method, 4, 'v') || payloadType[0] != '@' || strcmp(completionType, "@?") != 0) {
                [self fail:@"selector-unavailable"]; return;
            }
            [self invokePhase:1 signer:signer payload:NSData.data];
        } @catch (NSException *exception) {
            (void)exception;
            [self fail:@"native-exception"];
        }
    });
}
- (BOOL)waitUntil:(double)deadline {
    double remaining = MAX(0.0, deadline - OBNow());
    return dispatch_semaphore_wait(_ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC))) == 0;
}
- (NSDictionary *)consumeResult {
    [_lock lock];
    if (OBNow() >= _deadline) { _error = @"signing-timeout"; [self clearLocked]; }
    NSDictionary *result;
    if (!_consumed && _done && !_error && _emptySignature.length && _bodySignature.length) {
        // Transfer the owned mutable buffers to the I/O worker, which wipes them.
        result = @{@"empty": _emptySignature, @"body": _bodySignature, @"error": NSNull.null};
        _emptySignature = nil; _bodySignature = nil;
    } else {
        result = @{@"error": _error ?: @"internal-failure"};
    }
    _consumed = YES;
    [self clearLocked];
    [_lock unlock];
    return result;
}
- (void)discard {
    [_lock lock];
    _done = YES; _consumed = YES;
    [self clearLocked];
    [_lock unlock];
}
@end

static NSData *OBResponse(NSDictionary *info, NSData *empty, NSData *body, NSString *error, long long elapsed) {
    NSDictionary *reply = @{
        @"schema": @1, @"source_sha": @OB_SOURCE_SHA, @"run_id": info[@"run_id"],
        @"body_sha256": info[@"body_sha256"],
        @"empty_signature_b64": error ? @"" : [empty base64EncodedStringWithOptions:0],
        @"body_signature_b64": error ? @"" : [body base64EncodedStringWithOptions:0],
        @"elapsed_ms": @(elapsed), @"error": error ?: (id)NSNull.null
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
    return json.length > 0 && json.length <= OBMaxReply ? json : nil;
}

@interface OBAccountQualifierFixture : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *armButton;
@property(nonatomic, strong) OBRunControl *control;
@end

@implementation OBAccountQualifierFixture
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [UILabel new]; self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.status.text = @"One-use account qualifier fixture\n\nSigns only bundled frozen bytes and empty data. No account login. Arm only for the paired PC's USB exchange. Keep this app foreground. Native internals may use the network and system signing caches.";
    self.armButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.armButton setTitle:@"Arm once (120 seconds)" forState:UIControlStateNormal];
    [self.armButton addTarget:self action:@selector(arm) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status, self.armButton]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-24]
    ]];
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
    self.control.cancelled = YES; // I/O owner polls cancellation; callbacks never own FDs.
}
- (void)runExchange:(OBRunControl *)control {
    @autoreleasepool {
        int listener = -1, peer = -1;
        OBSigningJob *job = nil;
        NSMutableData *empty = nil, *signedBody = nil, *json = nil;
        NSString *disposition = @"internal-failure";
        NSUInteger emptyCount = 0, bodyCount = 0;
        @try {
            NSDictionary *info = nil; NSData *frozenBody = nil;
            if (!OBLoadFixture(&info, &frozenBody)) { disposition = @"fixture-invalid"; return; }
            if (control.cancelled || OBNow() >= control.armDeadline) { disposition = @"arm-timeout"; return; }
            listener = OBListen();
            if (listener < 0) { disposition = @"listener-unavailable"; return; }
            while (peer < 0 && OBWait(listener, POLLIN, control.armDeadline, control)) {
                peer = accept(listener, NULL, NULL);
                if (peer < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) break;
            }
            OBClose(&listener); // No other connection can be accepted, even on bad header.
            if (peer < 0 || control.cancelled || OBNow() >= control.armDeadline) {
                disposition = control.cancelled ? @"cancelled" : @"arm-timeout"; return;
            }
            control.accepted = YES;
            double exchangeDeadline = OBNow() + OBExchangeSeconds;
            int noSignal = 1;
            if (!OBNonblocking(peer) || setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal)) != 0) {
                disposition = @"peer-unavailable"; return;
            }
            NSString *failure = nil;
            long long elapsed = 0;
            if (!OBReadRequest(peer, info[@"run_id"], OBNow() + OBHeaderSeconds, control)) {
                failure = control.cancelled ? @"cancelled" : @"invalid-request";
            } else {
                double started = OBNow();
                double signingDeadline = MIN(started + OBSigningSeconds, exchangeDeadline - OBReplySeconds);
                job = [[OBSigningJob alloc] initWithBody:frozenBody deadline:signingDeadline];
                [job start];
                for (;;) {
                    if (control.cancelled) { [job fail:@"cancelled"]; break; }
                    if (OBNow() >= signingDeadline) { [job fail:@"signing-timeout"]; break; }
                    if ([job waitUntil:MIN(signingDeadline, OBNow() + 0.1)]) break;
                }
                NSDictionary *result = [job consumeResult];
                elapsed = (long long)((OBNow() - started) * 1000);
                if (result[@"error"] == NSNull.null) {
                    empty = result[@"empty"]; signedBody = result[@"body"];
                    emptyCount = empty.length; bodyCount = signedBody.length;
                } else failure = result[@"error"];
            }
            if (control.cancelled) { disposition = @"cancelled"; return; }
            json = [OBResponse(info, empty, signedBody, failure, elapsed) mutableCopy];
            OBErase(empty); OBErase(signedBody);
            empty = nil; signedBody = nil;
            uint32_t count = htonl((uint32_t)json.length);
            double replyDeadline = MIN(exchangeDeadline, OBNow() + OBReplySeconds);
            BOOL delivered = json && OBSendAll(peer, &count, sizeof(count), replyDeadline, control)
                && OBSendAll(peer, json.bytes, json.length, replyDeadline, control);
            disposition = delivered ? (failure ?: @"delivered-login-unverified") : @"delivery-failed";
        } @catch (NSException *exception) {
            (void)exception;
            disposition = @"internal-failure";
        } @finally {
            [job discard];
            OBErase(empty); OBErase(signedBody); OBErase(json);
            OBClose(&peer); OBClose(&listener);
            // Capture bounded metadata only; no body/proof/error description enters UI.
            NSString *finalDisposition = disposition;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = [NSString stringWithFormat:
                    @"Finished: %@\nEmpty bytes: %lu\nBody bytes: %lu\n\nSockets closed. No login result. Native timeout does not cancel underlying framework work. Close this fixture afterward.",
                    finalDisposition, (unsigned long)emptyCount, (unsigned long)bodyCount];
            });
        }
    }
}
- (void)arm {
    if (self.control) return; // One arm and one accept per process launch.
    OBRunControl *control = [OBRunControl new];
    control.armDeadline = OBNow() + OBArmSeconds;
    self.control = control; self.armButton.enabled = NO;
    self.status.text = @"Armed for one paired USB exchange. Waiting up to 120 seconds. No proof is displayed or saved.";
    // Observer installed before any I/O/native dispatch. Never closes a descriptor.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OBArmSeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ if (!control.accepted) control.cancelled = YES; });
    dispatch_queue_t io = dispatch_queue_create("dev.openbubbles.diagnostics.accountqualifier.io", DISPATCH_QUEUE_SERIAL);
    dispatch_async(io, ^{ [self runExchange:control]; });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OBAccountQualifierFixture.class));
    }
}
