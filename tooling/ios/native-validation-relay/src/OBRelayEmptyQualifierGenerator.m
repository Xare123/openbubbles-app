// Native-empty ACAccountStore proof, adapted from this project's tested
// Qualifier2 signing job (tooling/ios/account-qualifier-fixture/main.m,
// OBSigningJob) reduced to its empty-data phase only. Project-owned source;
// see ../README.md provenance. This signs empty data only. It is not NAC
// validation data and must never be returned for get-validation-data.
#import "OBRelayGenerators.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

enum { OBRelayQualifierMaxSignature = 2048 };

static double OBRelayQualifierNow(void) { return NSProcessInfo.processInfo.systemUptime; }

static BOOL OBRelayQualifierMethodHasType(Method method, unsigned arguments, char result) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char encoding[16] = {0};
    method_getReturnType(method, encoding, sizeof(encoding));
    return encoding[0] == result;
}

@interface OBRelayEmptySigningJob : NSObject {
    NSLock *_lock;
    dispatch_semaphore_t _ready;
    dispatch_queue_t _nativeQueue;
    NSMutableData *_emptySignature;
    NSString *_error;
    double _deadline;
    BOOL _done, _consumed;
}
- (instancetype)initWithDeadline:(double)deadline;
- (void)start;
- (void)fail:(NSString *)error;
- (BOOL)waitUntil:(double)deadline;
- (NSMutableData *)consume;
@end

@implementation OBRelayEmptySigningJob
- (instancetype)initWithDeadline:(double)deadline {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _ready = dispatch_semaphore_create(0);
        _nativeQueue = dispatch_queue_create("dev.openbubbles.relay.native.qualifier", DISPATCH_QUEUE_SERIAL);
        _deadline = deadline;
    }
    return self;
}
- (void)clearLocked {
    OBRelayWipe(_emptySignature);
    _emptySignature = nil;
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
- (BOOL)activeLocked {
    return !_done && OBRelayQualifierNow() < _deadline;
}
- (void)invokeWithSigner:(id)signer {
    SEL selector = NSSelectorFromString(@"signatureForData:completion:");
    void (^reply)(NSData *, NSError *) = ^(NSData *signature, NSError *error) {
        // Single lock rejects duplicate or late callbacks before retaining
        // any proof, exactly as in the tested fixture job.
        [self->_lock lock];
        if (![self activeLocked]) { [self->_lock unlock]; return; }
        BOOL valid = !error && [signature isKindOfClass:NSData.class]
            && signature.length > 0 && signature.length <= OBRelayQualifierMaxSignature;
        self->_done = YES;
        if (valid) self->_emptySignature = [signature mutableCopy];
        else { self->_error = @"native-signing-failed"; [self clearLocked]; }
        dispatch_semaphore_signal(self->_ready);
        [self->_lock unlock];
    };
    @try {
        [_lock lock];
        BOOL active = [self activeLocked];
        [_lock unlock];
        if (active)
            ((void (*)(id, SEL, NSData *, void (^)(NSData *, NSError *)))objc_msgSend)(signer, selector, NSData.data, reply);
        else
            [self fail:@"signing-timeout"];
    } @catch (NSException *exception) {
        (void)exception;
        [self fail:@"native-exception"];
    }
}
- (void)start {
    // Install the main-queue observer BEFORE native dispatch/factory/load.
    double remaining = MAX(0.0, _deadline - OBRelayQualifierNow());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self fail:@"signing-timeout"]; });
    dispatch_async(_nativeQueue, ^{
        [_lock lock];
        BOOL active = [self activeLocked];
        [_lock unlock];
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
            if (!OBRelayQualifierMethodHasType(class_getClassMethod(signerClass, factory), 2, '@')) {
                [self fail:@"factory-unavailable"]; return;
            }
            [_lock lock];
            BOOL stillActive = [self activeLocked];
            [_lock unlock];
            if (!stillActive) return;
            id signer = ((id (*)(id, SEL))objc_msgSend)(signerClass, factory);
            Method method = class_getInstanceMethod(object_getClass(signer), NSSelectorFromString(@"signatureForData:completion:"));
            char payloadType[8] = {0}, completionType[8] = {0};
            if (method) {
                method_getArgumentType(method, 2, payloadType, sizeof(payloadType));
                method_getArgumentType(method, 3, completionType, sizeof(completionType));
            }
            if (!signer || !OBRelayQualifierMethodHasType(method, 4, 'v')
                || payloadType[0] != '@' || strcmp(completionType, "@?") != 0) {
                [self fail:@"selector-unavailable"]; return;
            }
            [self invokeWithSigner:signer];
        } @catch (NSException *exception) {
            (void)exception;
            [self fail:@"native-exception"];
        }
    });
}
- (BOOL)waitUntil:(double)deadline {
    double remaining = MAX(0.0, deadline - OBRelayQualifierNow());
    return dispatch_semaphore_wait(_ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC))) == 0;
}
- (NSMutableData *)consume {
    [_lock lock];
    NSMutableData *result = nil;
    if (!_consumed && _done && !_error && _emptySignature.length
        && OBRelayQualifierNow() < _deadline) {
        // Transfer the owned mutable buffer to the caller, which wipes it.
        result = _emptySignature;
        _emptySignature = nil;
    } else {
        [self clearLocked];
    }
    _consumed = YES;
    [_lock unlock];
    return result;
}
@end

@interface OBRelayEmptyQualifierGenerator ()
@property(nonatomic, strong) dispatch_queue_t waitQueue;
@end

@implementation OBRelayEmptyQualifierGenerator
- (instancetype)init {
    if ((self = [super init])) {
        _waitQueue = dispatch_queue_create("dev.openbubbles.relay.native.qualifier-wait", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)generateEmptyQualifierWithDeadline:(double)deadline
                                completion:(void (^)(NSMutableData * _Nullable))completion {
    OBRelayEmptySigningJob *job = [[OBRelayEmptySigningJob alloc] initWithDeadline:deadline];
    [job start];
    dispatch_async(self.waitQueue, ^{
        [job waitUntil:deadline];
        completion([job consume]);
    });
}
@end
