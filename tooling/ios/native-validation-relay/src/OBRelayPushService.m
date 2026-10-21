#import "OBRelayPushService.h"
#import "OBRelayPushProtocol.h"

static NSString *const OBReplayStore=@"ob.native-push.replay-v1";
static double OBPushNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static uint64_t OBPushWall(void) { return (uint64_t)(NSDate.date.timeIntervalSince1970*1000.0); }

@interface OBPushContext : NSObject
@property(nonatomic,copy) NSDictionary *request;
@property(nonatomic,copy) NSString *code;
@property(nonatomic,strong) id requestID;
@property(nonatomic,copy,nullable) OBRelayPushReply reply;
@property(nonatomic) double deadline;
@property(atomic) BOOL cancelled;
@end
@implementation OBPushContext
@end

@interface OBRelayPushService ()
@property(nonatomic,strong) NSUserDefaults *defaults;
@property(nonatomic,copy) OBRelayPushNativeOperation operation;
@property(nonatomic,strong) dispatch_queue_t control;
@property(nonatomic,strong) dispatch_queue_t nativeQueue;
@property(nonatomic,strong,nullable) OBPushContext *current;
@property(nonatomic) BOOL quarantined;
@end

@implementation OBRelayPushService
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults operation:(OBRelayPushNativeOperation)operation {
    if ((self=[super init])) {
        _defaults=defaults;_operation=[operation copy];_generationSeconds=7;
        _control=dispatch_queue_create("dev.openbubbles.relay.push-control",DISPATCH_QUEUE_SERIAL);
        _nativeQueue=dispatch_queue_create("dev.openbubbles.relay.push-native",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)invalidatePendingRequest {
    dispatch_async(self.control, ^{ self.current.cancelled=YES;self.current.reply=nil; });
}
- (void)respond:(NSDictionary *)data context:(OBPushContext *)context {
    OBRelayPushReply reply=context.reply;context.reply=nil;
    if (!reply || context.cancelled) return;
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"command":@"response",@"id":context.requestID,@"data":data}
        options:NSJSONWritingSortedKeys error:NULL];
    if (json.length) reply([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
}
- (BOOL)admitReplay:(NSDictionary *)request code:(NSString *)code now:(uint64_t)now {
    id prior=[self.defaults objectForKey:OBReplayStore];
    if (prior && (![prior isKindOfClass:NSDictionary.class] || [prior count]>512)) return NO;
    NSMutableDictionary *next=prior?[prior mutableCopy]:NSMutableDictionary.new;
    for (id key in next.allKeys) {
        id value=next[key];
        if (![key isKindOfClass:NSString.class] || [key length]!=64 || ![value isKindOfClass:NSNumber.class]
            || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
        uint64_t stamp=[value unsignedLongLongValue];
        if (!stamp || stamp>INT64_MAX || (stamp>now && stamp-now>30000)) return NO;
        if (now>stamp && now-stamp>60000) [next removeObjectForKey:key];
    }
    NSMutableData *binding=[[code dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [binding appendData:request[@"request_id"]];
    NSString *key=OBRelayPushSHA256Hex(binding);
    if (next[key] || next.count>=512) return NO;
    next[key]=request[@"issued_ms"];
    [self.defaults setObject:[next copy] forKey:OBReplayStore];
    // Consume before native signing. Persist only bounded replay metadata,
    // never tickets, raw commands, certificates or signatures.
    return [self.defaults synchronize];
}
- (void)handleCommand:(NSString *)command code:(NSString *)code requestID:(id)requestID reply:(OBRelayPushReply)reply {
    BOOL validID=([requestID isKindOfClass:NSString.class] && [requestID length]>0 && [requestID length]<=64)
        || ([requestID isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)requestID)!=CFBooleanGetTypeID()
            && [requestID doubleValue]>=0 && [requestID doubleValue]<=9007199254740991.0
            && [requestID doubleValue]==(double)[requestID unsignedLongLongValue]);
    if (!validID || !reply || ![command hasPrefix:@"ob-push-v1."]) return;
    double budget=self.generationSeconds>0 && self.generationSeconds<=7?self.generationSeconds:7;
    double deadline=OBPushNow()+budget;
    dispatch_async(self.control, ^{
        OBPushContext *context=OBPushContext.new;context.requestID=requestID;context.reply=reply;
        context.code=code;context.deadline=deadline;
        NSDictionary *failure=@{@"error":@"native-push-unavailable"};
        uint64_t now=OBPushWall();
        NSDictionary *request=OBRelayPushParseCommand(command,code,now);
        if (!request || self.current || self.quarantined || OBPushNow()>=deadline
            || ![self admitReplay:request code:code now:now]) { [self respond:failure context:context];return; }
        context.request=request;self.current=context;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,deadline-OBPushNow())*NSEC_PER_SEC)),self.control, ^{
            if (self.current==context) { self.quarantined=YES;[self respond:failure context:context];context.cancelled=YES; }
        });
        dispatch_async(self.nativeQueue, ^{
            NSDictionary *native=nil;
            if (!context.cancelled) {
                @try { native=self.operation(request); }
                @catch (__unused NSException *exception) { native=nil; }
            }
            dispatch_async(self.control, ^{
                if (self.current!=context) return;
                if (OBPushNow()>=context.deadline) self.quarantined=YES;
                if (!context.cancelled && !self.quarantined) {
                    NSData *cert=native[@"certificate"],*sig=native[@"signature"];
                    NSData *requestHash=request[@"request_sha256"];
                    NSData *mac=([cert isKindOfClass:NSData.class] && [sig isKindOfClass:NSData.class])
                        ? OBRelayPushResponseMAC(requestHash,cert,sig,code):nil;
                    NSDictionary *response=mac?@{@"ob_push_v1":@{@"schema":@1,
                        @"request_sha256":[requestHash base64EncodedStringWithOptions:0],
                        @"certificate":[cert base64EncodedStringWithOptions:0],
                        @"signature":[sig base64EncodedStringWithOptions:0],@"mac":[mac base64EncodedStringWithOptions:0]}}:failure;
                    [self respond:response context:context];
                } else if (!context.cancelled) [self respond:failure context:context];
                context.reply=nil;context.code=@"";self.current=nil;
            });
        });
    });
}
@end
