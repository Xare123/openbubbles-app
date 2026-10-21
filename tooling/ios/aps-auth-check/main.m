// One native APNs nonce signature. No private-key export or account operation.
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/time.h>
#import <unistd.h>
#import <string.h>
#import "nonce.h"

#ifndef OB_SOURCE_SHA
#define OB_SOURCE_SHA "unqualified"
#endif
static BOOL OBUSBMode;
static const uint16_t OBPort = 49177;

typedef struct {
    void *framework;
    SecIdentityRef identity;
    SecCertificateRef certificate;
    SecKeyRef privateKey;
    SecKeyRef certificatePublicKey;
    SecKeyRef derivedPublicKey;
    CFDataRef certificatePublicBytes;
    CFDataRef derivedPublicBytes;
    CFDataRef certificateDER;
    NSInteger keyBits;
} OBKeys;

static void OBReleaseKeys(OBKeys *keys) {
    if (keys->certificateDER) CFRelease(keys->certificateDER);
    if (keys->derivedPublicBytes) CFRelease(keys->derivedPublicBytes);
    if (keys->certificatePublicBytes) CFRelease(keys->certificatePublicBytes);
    if (keys->derivedPublicKey) CFRelease(keys->derivedPublicKey);
    if (keys->certificatePublicKey) CFRelease(keys->certificatePublicKey);
    if (keys->privateKey) CFRelease(keys->privateKey);
    if (keys->certificate) CFRelease(keys->certificate);
    if (keys->identity) CFRelease(keys->identity);
    if (keys->framework) dlclose(keys->framework);
    memset(keys, 0, sizeof(*keys));
}

static BOOL OBIdentityABI(Class cls, SEL selector) {
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char result[64] = {0}, receiver[16] = {0}, command[16] = {0};
    method_getReturnType(method, result, sizeof(result));
    method_getArgumentType(method, 0, receiver, sizeof(receiver));
    method_getArgumentType(method, 1, command, sizeof(command));
    return strcmp(result, "^{__SecIdentity=}") == 0
        && (receiver[0] == '@' || receiver[0] == '#') && command[0] == ':';
}

static NSString *OBAcquireKeys(OBKeys *keys) {
    keys->framework = dlopen("/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
                            RTLD_LAZY | RTLD_LOCAL);
    if (!keys->framework) return @"framework-unavailable";
    Class cls = NSClassFromString(@"APSConnection");
    if (!cls) return @"class-unavailable";
    SEL selector = NSSelectorFromString(@"copyIdentity");
    if (!OBIdentityABI(cls, selector)) return @"abi-rejected";
    keys->identity = ((SecIdentityRef (*)(id, SEL))objc_msgSend)(cls, selector);
    if (!keys->identity || CFGetTypeID(keys->identity) != SecIdentityGetTypeID())
        return @"identity-unavailable";
    if (SecIdentityCopyCertificate(keys->identity, &keys->certificate) != errSecSuccess || !keys->certificate)
        return @"certificate-unavailable";
    if (SecIdentityCopyPrivateKey(keys->identity, &keys->privateKey) != errSecSuccess || !keys->privateKey)
        return @"key-unavailable";
    NSDictionary *attributes = CFBridgingRelease(SecKeyCopyAttributes(keys->privateKey));
    id bits = attributes[(__bridge id)kSecAttrKeySizeInBits];
    if (![attributes[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeRSA]
        || !bits || CFGetTypeID((__bridge CFTypeRef)bits) != CFNumberGetTypeID())
        return @"key-kind-rejected";
    keys->keyBits = [bits integerValue];
    if ((keys->keyBits != 1024 && keys->keyBits != 2048 && keys->keyBits != 3072 && keys->keyBits != 4096)
        || !SecKeyIsAlgorithmSupported(keys->privateKey, kSecKeyOperationTypeSign,
                                       kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1))
        return @"key-kind-rejected";
    keys->certificatePublicKey = SecCertificateCopyKey(keys->certificate);
    keys->derivedPublicKey = SecKeyCopyPublicKey(keys->privateKey);
    if (!keys->certificatePublicKey || !keys->derivedPublicKey) return @"public-key-mismatch";
    // PUBLIC representations only. Never request the private representation.
    keys->certificatePublicBytes = SecKeyCopyExternalRepresentation(keys->certificatePublicKey, NULL);
    keys->derivedPublicBytes = SecKeyCopyExternalRepresentation(keys->derivedPublicKey, NULL);
    if (!keys->certificatePublicBytes || !keys->derivedPublicBytes
        || CFDataGetLength(keys->certificatePublicBytes) <= 0
        || !CFEqual(keys->certificatePublicBytes, keys->derivedPublicBytes)) return @"public-key-mismatch";
    keys->certificateDER = SecCertificateCopyData(keys->certificate);
    if (!keys->certificateDER || CFDataGetLength(keys->certificateDER) < 129
        || CFDataGetLength(keys->certificateDER) > 8192) return @"certificate-unavailable";
    return @"ready";
}

static NSMutableDictionary *OBReply(NSString *nonce, NSString *phase, NSString *status) {
    return [@{@"schema": @1, @"source_sha": @OB_SOURCE_SHA, @"nonce": nonce,
        @"phase": phase, @"status": status, @"private_key_exported": @NO} mutableCopy];
}

static BOOL OBTransfer(int fd, void *buffer, size_t length, BOOL writing) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = writing ? send(fd, (char *)buffer + done, length - done, 0)
                                : recv(fd, (char *)buffer + done, length - done, 0);
        if (count <= 0) return NO;
        done += (size_t)count;
    }
    return YES;
}

static BOOL OBSendJSON(int fd, NSDictionary *reply) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
    if (!data || data.length == 0 || data.length > 16384) return NO;
    uint32_t length = htonl((uint32_t)data.length);
    return OBTransfer(fd, &length, sizeof(length), YES)
        && OBTransfer(fd, (void *)data.bytes, data.length, YES);
}

@interface OBAPSAuthApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextView *text;
@property(nonatomic, strong) NSLock *fdLock;
@property(nonatomic) int listener;
@property(nonatomic) int peer;
@property(atomic) BOOL cancelled;
@property(nonatomic) BOOL started;
@property(atomic) BOOL finished;
@end

@implementation OBAPSAuthApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.listener = self.peer = -1;
    self.fdLock = [NSLock new];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.text = [UITextView new];
    self.text.editable = NO;
    self.text.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.text.text = @"APS Auth Check\n\nIdle. A source-bound paired-USB developer launch can request one native APNs nonce signature. The private key stays on this iPhone. No Apple account sign-in or reset. No proofs are shown or saved.\n\nSource: " @OB_SOURCE_SHA;
    self.text.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.text];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.text.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [self.text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16]]];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    if (OBUSBMode && !self.started) [self start];
}
- (void)cancelSession {
    self.cancelled = YES;
    [self.fdLock lock];
    // Worker owns close. Cancellation cannot reuse its descriptors during signing.
    if (self.listener >= 0) shutdown(self.listener, SHUT_RDWR);
    if (self.peer >= 0) shutdown(self.peer, SHUT_RDWR);
    [self.fdLock unlock];
}
- (void)applicationWillResignActive:(UIApplication *)application {
    if (self.started && !self.finished) [self cancelSession];
    application.idleTimerDisabled = NO;
}
- (void)showStatus:(NSString *)status {
    self.finished = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cancelled) self.text.text = [@"APS Auth Check\n\n" stringByAppendingString:status];
        UIApplication.sharedApplication.idleTimerDisabled = NO;
    });
}
- (void)start {
    if (self.started || self.cancelled) return;
    self.started = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.text.text = @"Waiting for one paired-USB request. No proofs are displayed.";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.started && !self.finished && !self.cancelled) {
            [self cancelSession];
            self.text.text = @"Observation ended. Native work cancellation remains unqualified.";
            UIApplication.sharedApplication.idleTimerDisabled = NO;
        }
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int listener = -1, peer = -1;
        OBKeys keys = {0};
        @try {
            if (self.cancelled) return;
            listener = socket(AF_INET, SOCK_STREAM, 0);
            if (listener < 0) { [self showStatus:@"listener-unavailable"]; return; }
            int yes = 1;
            if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) != 0) return;
            struct sockaddr_in address = {0};
            address.sin_len = sizeof(address);
            address.sin_family = AF_INET;
            address.sin_port = htons(OBPort);
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0) {
                [self showStatus:@"listener-bind-failed"]; return;
            }
            [self.fdLock lock];
            if (self.cancelled) { [self.fdLock unlock]; return; }
            self.listener = listener;
            [self.fdLock unlock];
            peer = accept(listener, NULL, NULL);
            if (peer < 0 || self.cancelled) return;
            struct timeval timeout = {.tv_sec = 15, .tv_usec = 0};
            if (setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0
                || setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0
                || setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) return;
            [self.fdLock lock];
            if (self.cancelled) { [self.fdLock unlock]; return; }
            self.peer = peer;
            [self.fdLock unlock];
            char request[42];
            if (!OBTransfer(peer, request, sizeof(request), NO)
                || memcmp(request, "OBAPSAU1:", 9) != 0 || request[41] != '\n') return;
            for (int i = 9; i < 41; ++i)
                if (!((request[i] >= '0' && request[i] <= '9') || (request[i] >= 'a' && request[i] <= 'f'))) return;
            NSString *nonce = [[NSString alloc] initWithBytes:request + 9 length:32 encoding:NSASCIIStringEncoding];
            NSString *status;
            @try { status = OBAcquireKeys(&keys); }
            @catch (__unused NSException *exception) { status = @"native-exception"; }
            if (self.cancelled) return;
            NSMutableDictionary *certificate = OBReply(nonce, @"certificate", status);
            BOOL ready = [status isEqualToString:@"ready"];
            certificate[@"certificate_der_b64"] = ready
                ? [(__bridge NSData *)keys.certificateDER base64EncodedStringWithOptions:0] : NSNull.null;
            certificate[@"key_bits"] = ready ? @(keys.keyBits) : NSNull.null;
            if (!OBSendJSON(peer, certificate) || !ready) { [self showStatus:status]; return; }

            uint8_t apnsNonce[17];
            if (!OBTransfer(peer, apnsNonce, sizeof(apnsNonce), NO) || self.cancelled) return;
            uint64_t now = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
            CFDataRef signature = NULL;
            BOOL verified = NO;
            NSString *signatureStatus = @"nonce-rejected";
            @try {
                if (ob_apns_nonce_valid(apnsNonce, sizeof(apnsNonce), now) && !self.cancelled) {
                    NSData *message = [NSData dataWithBytes:apnsNonce length:sizeof(apnsNonce)];
                    signature = SecKeyCreateSignature(keys.privateKey,
                        kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1, (__bridge CFDataRef)message, NULL);
                    signatureStatus = @"signature-unavailable";
                    if (signature && CFDataGetLength(signature) == keys.keyBits / 8) {
                        verified = SecKeyVerifySignature(keys.certificatePublicKey,
                            kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1, (__bridge CFDataRef)message, signature, NULL);
                        signatureStatus = verified ? @"ready" : @"verification-failed";
                    }
                }
                if (!self.cancelled) {
                    NSMutableDictionary *reply = OBReply(nonce, @"signature", signatureStatus);
                    reply[@"signature_b64"] = verified
                        ? [(__bridge NSData *)signature base64EncodedStringWithOptions:0] : NSNull.null;
                    reply[@"signature_bytes"] = verified ? @(CFDataGetLength(signature)) : @0;
                    reply[@"native_verified"] = @(verified);
                    if (OBSendJSON(peer, reply)) [self showStatus:signatureStatus];
                }
            } @catch (__unused NSException *exception) {
                NSMutableDictionary *reply = OBReply(nonce, @"signature", @"native-exception");
                reply[@"signature_b64"] = NSNull.null;
                reply[@"signature_bytes"] = @0;
                reply[@"native_verified"] = @NO;
                if (!self.cancelled) OBSendJSON(peer, reply);
                [self showStatus:@"native-exception"];
            } @finally { if (signature) CFRelease(signature); }
        } @catch (__unused NSException *exception) {
            [self showStatus:@"transport-failed"];
        } @finally {
            OBReleaseKeys(&keys);
            [self.fdLock lock];
            self.peer = self.listener = -1;
            if (peer >= 0) close(peer);
            if (listener >= 0) close(listener);
            [self.fdLock unlock];
        }
    });
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        OBUSBMode = argc == 2 && strcmp(argv[1], "--ob-aps-auth-once-v1") == 0;
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OBAPSAuthApp.class));
    }
}
