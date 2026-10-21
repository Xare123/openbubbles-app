#import "OBRelayDispatcher.h"
#import "OBRelayAuthBundle.h"
#import <math.h>

static NSString *const OBRelayCapabilitiesField = @"ob_auth_capabilities";
static NSString *const OBRelayCapabilitiesValue = @"native-account-v1";
static const double OBRelayMaximumGenerationSeconds = 45.0;
static double OBRelayDispatchNow(void) { return NSProcessInfo.processInfo.systemUptime; }

typedef NS_ENUM(NSUInteger, OBRelayPhase) {
    OBRelayPhaseHeaders, OBRelayPhaseQualifier, OBRelayPhaseNAC, OBRelayPhaseDone
};

// All context fields and result transfers are confined to controlQueue.
// Native completion blocks only enqueue their transferred result; no shared
// __block buffers, cross-thread timeout writes or semaphore handoff exist.
@interface OBRelayRequestContext : NSObject
@property(nonatomic, copy) NSString *command;
@property(nonatomic, strong) id requestID;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *identifiers;
@property(nonatomic, copy, nullable) OBRelayReply reply;
@property(nonatomic) double admission;
@property(nonatomic) double deadline;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL responded;
@property(nonatomic) OBRelayPhase phase;
@end
@implementation OBRelayRequestContext
@end

@interface OBRelayDispatcher ()
@property(nonatomic, strong) id<OBRelayHeaderGenerating> headerGenerator;
@property(nonatomic, strong) id<OBRelayEmptyQualifierGenerating> qualifierGenerator;
@property(nonatomic, strong) id<OBNACValidating> validator;
@property(nonatomic, strong) dispatch_queue_t controlQueue;
@property(nonatomic, strong, nullable) OBRelayRequestContext *current;
@property(nonatomic) BOOL quarantined;
@end

@implementation OBRelayDispatcher
- (instancetype)initWithHeaderGenerator:(id<OBRelayHeaderGenerating>)headerGenerator
                    qualifierGenerator:(id<OBRelayEmptyQualifierGenerating>)qualifierGenerator
                               validator:(id<OBNACValidating>)validator {
    if ((self = [super init])) {
        _headerGenerator = headerGenerator;
        _qualifierGenerator = qualifierGenerator;
        _validator = validator;
        _generationSeconds = OBRelayMaximumGenerationSeconds;
        _controlQueue = dispatch_queue_create("dev.openbubbles.relay.dispatch-control", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (double)budget {
    double value = self.generationSeconds;
    return value > 0 && value <= OBRelayMaximumGenerationSeconds
        ? value : OBRelayMaximumGenerationSeconds;
}

- (NSDictionary *)versionsForContext:(OBRelayRequestContext *)context bundle:(NSString *)bundle {
    NSMutableDictionary *versions = [context.identifiers mutableCopy];
    versions[OBRelayCapabilitiesField] = OBRelayCapabilitiesValue;
    if (self.nativePushEnabled) versions[@"ob_push_capabilities"] = @"native-push-v1";
    if (bundle) versions[OBRelayAuthBundleField] = bundle;
    return @{@"versions":[versions copy]};
}

- (void)respond:(NSDictionary *)data context:(OBRelayRequestContext *)context {
    if (context.responded) return;
    context.responded = YES;
    OBRelayReply reply = context.reply;
    context.reply = nil;
    if (context.cancelled || !reply) return;
    NSDictionary *response = @{@"command":@"response", @"id":context.requestID, @"data":data};
    NSData *json = [NSJSONSerialization dataWithJSONObject:response
        options:NSJSONWritingSortedKeys error:NULL];
    NSString *text = json.length ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (text) reply(text);
}

- (void)respondUnavailable:(OBRelayRequestContext *)context {
    [self respond:[context.command isEqualToString:@"get-version-info"]
        ? [self versionsForContext:context bundle:nil]
        : @{@"error":@"validator-unavailable"} context:context];
}

// Timeout is an actual observer deadline, not a claim to interrupt private APIs.
// A deadline quarantines new generation until this helper is restarted. That
// avoids accumulating hidden native calls even if a generator reports its own
// timeout while the underlying private call has not returned.
- (void)expire:(OBRelayRequestContext *)context {
    if (self.current != context || context.phase == OBRelayPhaseDone) return;
    self.quarantined = YES;
    [self respondUnavailable:context];
    context.cancelled = YES;
}

- (BOOL)active:(OBRelayRequestContext *)context phase:(OBRelayPhase)phase {
    if (self.current != context || context.phase != phase || context.cancelled || context.responded)
        return NO;
    if (OBRelayDispatchNow() >= context.deadline) {
        [self expire:context];
        return NO;
    }
    return YES;
}

- (void)settle:(OBRelayRequestContext *)context {
    if (self.current != context) return;
    if (OBRelayDispatchNow() >= context.deadline) self.quarantined = YES;
    context.phase = OBRelayPhaseDone;
    context.reply = nil;
    self.current = nil;
}

- (void)startHeaders:(OBRelayRequestContext *)context {
    if (![self active:context phase:OBRelayPhaseHeaders]) { [self settle:context]; return; }
    if (context.identifiers.count != 6) {
        [self respondUnavailable:context];
        [self settle:context];
        return;
    }
    [self.headerGenerator fetchHeadersWithDeadline:context.deadline completion:^(NSDictionary *headers) {
        dispatch_async(self.controlQueue, ^{
            if (![self active:context phase:OBRelayPhaseHeaders]) {
                // A duplicate callback cannot settle another active phase.
                if (context.phase == OBRelayPhaseHeaders) [self settle:context];
                return;
            }
            if (!headers) {
                [self respondUnavailable:context]; [self settle:context]; return;
            }
            context.phase = OBRelayPhaseQualifier;
            [self.qualifierGenerator generateEmptyQualifierWithDeadline:context.deadline
                completion:^(NSMutableData *proof) {
                dispatch_async(self.controlQueue, ^{
                    if (![self active:context phase:OBRelayPhaseQualifier]) {
                        OBRelayWipe(proof);
                        if (context.phase == OBRelayPhaseQualifier) [self settle:context];
                        return;
                    }
                    long long elapsed = llround((OBRelayDispatchNow() - context.admission) * 1000.0);
                    NSString *bundle = proof ? [OBRelayAuthBundle bundleStringWithHeaders:headers
                        qualifier:proof elapsedMilliseconds:elapsed] : nil;
                    OBRelayWipe(proof);
                    [self respond:[self versionsForContext:context bundle:bundle] context:context];
                    [self settle:context];
                });
            }];
        });
    }];
}

- (void)startNAC:(OBRelayRequestContext *)context {
    if (![self active:context phase:OBRelayPhaseNAC]) { [self settle:context]; return; }
    [self.validator generateValidationDataWithDeadline:context.deadline completion:^(NSData *data) {
        dispatch_async(self.controlQueue, ^{
            if (![self active:context phase:OBRelayPhaseNAC]) {
                if (context.phase == OBRelayPhaseNAC) [self settle:context];
                return;
            }
            if (data.length)
                [self respond:@{@"data":[data base64EncodedStringWithOptions:0]} context:context];
            else
                [self respondUnavailable:context];
            [self settle:context];
        });
    }];
}

- (void)invalidatePendingRequest {
    dispatch_async(self.controlQueue, ^{
        self.current.cancelled = YES;
        self.current.responded = YES;
        self.current.reply = nil;
        // Keep the in-flight reservation until its callback really arrives.
        // No native cancellation or fresh work is attempted on a replacement.
    });
}

- (void)handleCommand:(NSString *)command
            requestID:(id)requestID
          identifiers:(NSDictionary<NSString *, NSString *> *)identifiers
                reply:(OBRelayReply)reply {
    if (![command isEqualToString:@"get-version-info"]
        && ![command isEqualToString:@"get-validation-data"]) return;
    if (!requestID || requestID == NSNull.null || !reply) return;
    double admission = OBRelayDispatchNow();
    double budget = [self budget];
    dispatch_async(self.controlQueue, ^{
        OBRelayRequestContext *context = [OBRelayRequestContext new];
        context.command = command;
        context.requestID = requestID;
        context.identifiers = identifiers ?: @{};
        context.reply = reply;
        context.admission = admission;
        context.deadline = admission + budget;
        context.phase = [command isEqualToString:@"get-version-info"] ? OBRelayPhaseHeaders : OBRelayPhaseNAC;
        // One physical operation chain, no pending native queue or blocked
        // global workers. A busy replacement gets an immediate safe failure.
        if (self.current || self.quarantined) {
            [self respondUnavailable:context];
            return;
        }
        self.current = context;
        double remaining = context.deadline - OBRelayDispatchNow();
        if (remaining <= 0) {
            [self expire:context]; [self settle:context]; return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)),
            self.controlQueue, ^{ [self expire:context]; });
        if (context.phase == OBRelayPhaseHeaders) [self startHeaders:context];
        else [self startNAC:context];
    });
}
@end
