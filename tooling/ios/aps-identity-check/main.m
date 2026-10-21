// Separate, one-use native APS metadata diagnostic. Never exports a private key.
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

#ifndef OB_SOURCE_SHA
#define OB_SOURCE_SHA "unqualified"
#endif
static BOOL OBUSBMode;
static const uint16_t OBPort = 49176;

static NSMutableDictionary *OBDefaults(NSString *nonce) {
    return [@{@"schema": @1, @"source_sha": @OB_SOURCE_SHA, @"nonce": nonce,
        @"outcome": @"identity-unavailable", @"identity_present": @NO,
        @"certificate_present": @NO, @"private_key_reference_present": @NO,
        @"certificate_copy_status": NSNull.null, @"private_key_copy_status": NSNull.null,
        @"key_type": @"none", @"key_bits": NSNull.null, @"token_present": NSNull.null,
        @"secure_enclave_token": NSNull.null, @"rsa_sha1_sign_supported": NSNull.null,
        @"public_keys_match": NSNull.null, @"private_key_exported": @NO,
        @"explicit_network_requests": @0, @"identity_invalidated": @NO,
        @"cache_flushed": @NO, @"native_backend_side_effects_unqualified": @YES} mutableCopy];
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

static NSDictionary *OBReadMetadata(NSString *nonce) {
    NSMutableDictionary *result = OBDefaults(nonce);
    SecIdentityRef identity = NULL;
    SecCertificateRef certificate = NULL;
    SecKeyRef privateKey = NULL, certificatePublicKey = NULL, derivedPublicKey = NULL;
    CFDataRef certificatePublicBytes = NULL, derivedPublicBytes = NULL;
    void *framework = NULL;
    @try {
        framework = dlopen("/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
                           RTLD_LAZY | RTLD_LOCAL);
        if (!framework) { result[@"outcome"] = @"framework-unavailable"; return result; }
        Class cls = NSClassFromString(@"APSConnection");
        if (!cls) { result[@"outcome"] = @"class-unavailable"; return result; }
        SEL selector = NSSelectorFromString(@"copyIdentity");
        if (!OBIdentityABI(cls, selector)) { result[@"outcome"] = @"abi-rejected"; return result; }
        // Only this reviewed class method, after its runtime ABI check. No
        // connection, topic/token request, cache invalidation or provisioning API.
        identity = ((SecIdentityRef (*)(id, SEL))objc_msgSend)(cls, selector);
        if (!identity) return result;
        if (CFGetTypeID(identity) != SecIdentityGetTypeID()) {
            result[@"outcome"] = @"identity-type-rejected"; return result;
        }
        result[@"identity_present"] = @YES;
        OSStatus certificateStatus = SecIdentityCopyCertificate(identity, &certificate);
        result[@"certificate_copy_status"] = @(certificateStatus);
        if (certificateStatus != errSecSuccess || !certificate) {
            result[@"outcome"] = @"certificate-unavailable"; return result;
        }
        result[@"certificate_present"] = @YES;
        OSStatus keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey);
        result[@"private_key_copy_status"] = @(keyStatus);
        if (keyStatus != errSecSuccess || !privateKey) {
            result[@"outcome"] = @"private-key-reference-unavailable"; return result;
        }
        result[@"private_key_reference_present"] = @YES;
        NSDictionary *attributes = CFBridgingRelease(SecKeyCopyAttributes(privateKey));
        id keyType = attributes[(__bridge id)kSecAttrKeyType];
        result[@"key_type"] = [keyType isEqual:(__bridge id)kSecAttrKeyTypeRSA] ? @"rsa"
            : [keyType isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom] ? @"ec" : @"other";
        id bits = attributes[(__bridge id)kSecAttrKeySizeInBits];
        if (bits && CFGetTypeID((__bridge CFTypeRef)bits) == CFNumberGetTypeID()) {
            long long count = [bits longLongValue];
            if (count >= 256 && count <= 16384) result[@"key_bits"] = @(count);
        }
        id token = attributes[(__bridge id)kSecAttrTokenID];
        result[@"token_present"] = @(token != nil);
        if (!token || [token isKindOfClass:NSString.class])
            result[@"secure_enclave_token"] = @([token isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave]);
        result[@"rsa_sha1_sign_supported"] = @(SecKeyIsAlgorithmSupported(
            privateKey, kSecKeyOperationTypeSign, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1));
        certificatePublicKey = SecCertificateCopyKey(certificate);
        derivedPublicKey = SecKeyCopyPublicKey(privateKey);
        if (!certificatePublicKey || !derivedPublicKey) {
            result[@"outcome"] = @"public-key-inspection-failed"; return result;
        }
        // PUBLIC keys only, kept transiently for equality. No private key data
        // is requested, returned, logged, persisted, signed or sent to the host.
        certificatePublicBytes = SecKeyCopyExternalRepresentation(certificatePublicKey, NULL);
        derivedPublicBytes = SecKeyCopyExternalRepresentation(derivedPublicKey, NULL);
        if (!certificatePublicBytes || !derivedPublicBytes
            || CFDataGetLength(certificatePublicBytes) <= 0 || CFDataGetLength(derivedPublicBytes) <= 0) {
            result[@"outcome"] = @"public-key-inspection-failed"; return result;
        }
        BOOL equal = CFEqual(certificatePublicBytes, derivedPublicBytes);
        result[@"public_keys_match"] = @(equal);
        result[@"outcome"] = result[@"key_bits"] == NSNull.null ? @"public-key-inspection-failed"
            : equal ? @"ready" : @"public-key-mismatch";
    } @catch (__unused NSException *exception) {
        result[@"outcome"] = @"native-exception";
    } @finally {
        if (derivedPublicBytes) CFRelease(derivedPublicBytes);
        if (certificatePublicBytes) CFRelease(certificatePublicBytes);
        if (derivedPublicKey) CFRelease(derivedPublicKey);
        if (certificatePublicKey) CFRelease(certificatePublicKey);
        if (privateKey) CFRelease(privateKey);
        if (certificate) CFRelease(certificate);
        if (identity) CFRelease(identity);
        if (framework) dlclose(framework);
    }
    return result;
}

static BOOL OBTransfer(int socket, void *buffer, size_t length, BOOL writing) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = writing ? send(socket, (char *)buffer + done, length - done, 0)
                                : recv(socket, (char *)buffer + done, length - done, 0);
        if (count <= 0) return NO;
        done += (size_t)count;
    }
    return YES;
}

@interface OBAPSMetadataApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextView *text;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) NSLock *fdLock;
@property(nonatomic) int listener;
@property(nonatomic) int peer;
@property(atomic) BOOL cancelled;
@property(nonatomic) BOOL started;
@property(atomic) BOOL finished;
@end

@implementation OBAPSMetadataApp
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
    self.text.text = @"APS Identity Check\n\nReads metadata from the native push identity. Does not export a private key, request Apple login, reset an identity or change the relay. Native backend side effects remain unqualified.\n\nOne check per launch.";
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.button setTitle:@"Run metadata check" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.button, self.text]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [self.button.heightAnchor constraintEqualToConstant:44]]];
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
    // Shutdown, not close: the worker retains descriptor ownership until it
    // unwinds. This prevents reuse races while a native framework call is busy.
    if (self.listener >= 0) shutdown(self.listener, SHUT_RDWR);
    if (self.peer >= 0) shutdown(self.peer, SHUT_RDWR);
    [self.fdLock unlock];
}
- (void)applicationWillResignActive:(UIApplication *)application {
    if (self.started && !self.finished) [self cancelSession];
    application.idleTimerDisabled = NO;
}
- (void)show:(NSString *)text {
    self.finished = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cancelled) self.text.text = text;
        UIApplication.sharedApplication.idleTimerDisabled = NO;
    });
}
- (void)start {
    if (self.started || self.cancelled) return;
    self.started = YES;
    self.button.enabled = NO;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.text.text = OBUSBMode ? @"Waiting for one paired-USB metadata request…" : @"Reading native APS identity metadata…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.started && !self.finished && !self.cancelled) {
            [self cancelSession];
            self.text.text = @"Observation ended. Native work cancellation remains unqualified. Close this diagnostic.";
            UIApplication.sharedApplication.idleTimerDisabled = NO;
        }
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int listener = -1, peer = -1;
        @try {
            if (self.cancelled) return;
            NSString *nonce = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
            if (OBUSBMode) {
                listener = socket(AF_INET, SOCK_STREAM, 0);
                if (listener < 0) { [self show:@"Metadata listener unavailable."]; return; }
                int reuse = 1;
                if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) return;
                struct sockaddr_in address = {0};
                address.sin_len = sizeof(address);
                address.sin_family = AF_INET;
                address.sin_port = htons(OBPort);
                address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0) {
                    [self show:@"Metadata listener could not bind."]; return;
                }
                [self.fdLock lock];
                if (self.cancelled) { [self.fdLock unlock]; return; }
                self.listener = listener;
                [self.fdLock unlock];
                peer = accept(listener, NULL, NULL);
                if (peer < 0 || self.cancelled) return;
                int yes = 1;
                struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
                if (setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0
                    || setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0
                    || setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) return;
                [self.fdLock lock];
                if (self.cancelled) { [self.fdLock unlock]; return; }
                self.peer = peer;
                [self.fdLock unlock];
                char request[42];
                if (!OBTransfer(peer, request, sizeof(request), NO)
                    || memcmp(request, "OBAPSID1:", 9) != 0 || request[41] != '\n') return;
                for (int i = 9; i < 41; i++)
                    if (!((request[i] >= '0' && request[i] <= '9') || (request[i] >= 'a' && request[i] <= 'f'))) return;
                nonce = [[NSString alloc] initWithBytes:request + 9 length:32 encoding:NSASCIIStringEncoding];
            }
            if (self.cancelled) return;
            NSDictionary *metadata = OBReadMetadata(nonce);
            NSData *data = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:NULL];
            if (!data || data.length > 8192 || self.cancelled) return;
            if (OBUSBMode) {
                uint32_t size = htonl((uint32_t)data.length);
                if (!OBTransfer(peer, &size, sizeof(size), YES)
                    || !OBTransfer(peer, (void *)data.bytes, data.length, YES)) return;
            }
            [self show:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        } @catch (__unused NSException *exception) {
            [self show:@"Metadata check failed; no native error or key values retained."];
        } @finally {
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
        if (argc == 2 && strcmp(argv[1], "--ob-aps-identity-meta-once-v1") == 0) OBUSBMode = YES;
        else if (argc != 1) return 2;
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OBAPSMetadataApp.class));
    }
}
