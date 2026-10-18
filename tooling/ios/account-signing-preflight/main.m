// Credential-free, separate-app probe. Never returns or persists a signature.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

#ifndef OB_SOURCE_SHA
#define OB_SOURCE_SHA "local-unqualified"
#endif

@interface OBAccountSigningProbe : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *stages;
@property(nonatomic, strong) NSDate *started;
@property(nonatomic, strong) NSString *runIdentifier;
@property(nonatomic, strong) dispatch_queue_t nativeQueue;
@property(nonatomic) BOOL finished;
@end

// Type-check the two specific Objective-C message signatures before calling.
// Never discover/call arbitrary selectors or read any account/keychain object.
static BOOL OBMethodHasType(Method method, unsigned arguments, char result) {
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char encoding[16] = {0};
    method_getReturnType(method, encoding, sizeof(encoding));
    return encoding[0] == result;
}

@implementation OBAccountSigningProbe

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.status.text = @"Native iPhone account-signing check\n\nThis checks device-signing availability, not login. It uses no Apple Account password, verification code or relay code. Signatures are discarded; only result metadata is saved. ValidationRelay and messaging apps are not changed.";
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run one signing check" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.runButton addTarget:self action:@selector(runCheck) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status, self.runButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-24],
    ]];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)finish:(NSString *)disposition {
    NSAssert(NSThread.isMainThread, @"main queue required");
    if (self.finished) return;
    self.finished = YES;
    NSDictionary *metadata = @{
        @"schema": @1,
        @"source_sha": @OB_SOURCE_SHA,
        @"disposition": disposition,
        @"elapsed_ms": @((long long)(-[self.started timeIntervalSinceNow] * 1000)),
        @"stages": [self.stages copy],
        @"signatures_retained": @NO,
        @"account_credentials_supplied": @NO,
        @"login_qualified": @NO,
    };
    // Unique metadata-only file in this separate application's own Documents.
    // Never overwrite an earlier receipt, export keys, or copy other app data.
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    NSString *name = [NSString stringWithFormat:@"account-signing-%@.json", self.runIdentifier];
    NSURL *destination = [documents URLByAppendingPathComponent:name];
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:&error];
    BOOL saved = json && [json writeToURL:destination options:NSDataWritingWithoutOverwriting error:&error];
    self.status.text = [NSString stringWithFormat:
        @"Check finished: %@\n\n%@\n\nMetadata receipt %@. No signatures or account credentials were saved. This is not a login-success result.",
        disposition, self.stages.description, saved ? @"saved in this app's Documents" : @"could not be saved"];
}

- (void)signStage:(NSString *)stage payload:(NSData *)payload signer:(id)signer {
    if (self.finished) return;
    SEL selector = NSSelectorFromString(@"signatureForData:completion:");
    __weak OBAccountSigningProbe *weakSelf = self;
    void (^reply)(NSData *, NSError *) = ^(NSData *signature, NSError *error) {
        // Keep only bounded primitive metadata, never signature bytes/error text.
        BOOL validData = [signature isKindOfClass:NSData.class] && signature.length > 0;
        NSUInteger byteCount = [signature isKindOfClass:NSData.class] ? signature.length : 0;
        BOOL hasError = error != nil;
        NSInteger errorCode = [error isKindOfClass:NSError.class] ? error.code : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            OBAccountSigningProbe *owner = weakSelf;
            if (!owner || owner.finished) return;
            for (NSDictionary *existing in owner.stages) {
                if ([existing[@"stage"] isEqual:stage]) return;
            }
            [owner.stages addObject:@{@"stage": stage, @"signature_present": @(validData),
                @"signature_bytes": @(byteCount), @"error_present": @(hasError), @"error_code": @(errorCode)}];
            if (!validData || hasError) {
                [owner finish:@"native-signing-failed"];
            } else if ([stage isEqualToString:@"empty-payload"]) {
                NSData *body = [@"OpenBubbles account-signing preflight v1" dataUsingEncoding:NSUTF8StringEncoding];
                [owner signStage:@"fixed-harmless-payload" payload:body signer:signer];
            } else {
                [owner finish:@"native-signing-available-login-unverified"];
            }
        });
    };
    NSDate *deadline = [self.started dateByAddingTimeInterval:45];
    dispatch_async(self.nativeQueue, ^{
        if (deadline.timeIntervalSinceNow <= 0) return;
        @try {
            ((void (*)(id, SEL, NSData *, void (^)(NSData *, NSError *)))objc_msgSend)(signer, selector, payload, reply);
        } @catch (NSException *exception) {
            (void)exception;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finish:@"native-exception-details-not-retained"];
            });
        }
    });
}

- (void)runCheck {
    if (self.started) return; // One bounded check per launch, no retry loop.
    self.started = NSDate.date;
    self.runIdentifier = NSUUID.UUID.UUIDString;
    self.stages = [NSMutableArray new];
    self.nativeQueue = dispatch_queue_create("dev.openbubbles.diagnostics.accountsigning.native", DISPATCH_QUEUE_SERIAL);
    self.runButton.enabled = NO;
    self.status.text = @"Checking Apple's native account signer. No account login is being attempted. This check has a 45-second observation limit.";
    __weak OBAccountSigningProbe *weakSelf = self;
    // Install the observer before loading the framework or invoking its factory.
    // Native work is on a separate serial queue, never the UI/observer queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OBAccountSigningProbe *owner = weakSelf;
        if (owner && !owner.finished) [owner finish:@"observation-timed-out-native-completion-unqualified"];
    });
    dispatch_async(self.nativeQueue, ^{
    // Keep the system framework loaded for the full process/callback lifetime.
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount", RTLD_NOW | RTLD_LOCAL);
    });
    if (!framework) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finish:@"system-framework-unavailable"]; });
        return;
    }
    Class signerClass = NSClassFromString(@"AAAbsintheSigner");
    SEL shared = NSSelectorFromString(@"sharedSigner");
    if (!OBMethodHasType(class_getClassMethod(signerClass, shared), 2, '@')) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finish:@"native-class-or-factory-unavailable"]; });
        return;
    }
    id signer;
    @try {
        signer = ((id (*)(id, SEL))objc_msgSend)(signerClass, shared);
    } @catch (NSException *exception) {
        (void)exception;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finish:@"native-factory-exception-details-not-retained"]; });
        return;
    }
    Method method = class_getInstanceMethod(object_getClass(signer), NSSelectorFromString(@"signatureForData:completion:"));
    char payloadType[8] = {0}, completionType[8] = {0};
    if (method) {
        method_getArgumentType(method, 2, payloadType, sizeof(payloadType));
        method_getArgumentType(method, 3, completionType, sizeof(completionType));
    }
    if (!signer || !OBMethodHasType(method, 4, 'v') || payloadType[0] != '@' || strcmp(completionType, "@?") != 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finish:@"native-selector-signature-unavailable"]; });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        OBAccountSigningProbe *owner = weakSelf;
        if (owner && !owner.finished) [owner signStage:@"empty-payload" payload:NSData.data signer:signer];
    });
    // Apple's internal network operation has no cancellation API in this seam.
    // A timeout does NOT claim it canceled; close this separate app afterward.
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OBAccountSigningProbe.class));
    }
}
