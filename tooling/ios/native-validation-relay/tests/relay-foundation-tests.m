// Production dispatcher/connection with synthetic generators and socket objects.
// No UIKit, private frameworks, account, real socket, or device operation.
#import <Foundation/Foundation.h>
#import "OBRelayConnection.h"
#import "OBRelayAuthBundle.h"
#import "OBRelayIdentifiers.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

static _Atomic(NSUInteger) checks;
static void Check(BOOL yes, const char *name) {
    if (!yes) { fprintf(stderr, "FAIL native-relay: %s\n", name); exit(1); }
    atomic_fetch_add(&checks, 1);
}

static NSDictionary *Identifiers(void) {
    return @{@"software_build_id":@"fixture-build", @"software_name":@"fixture-os",
        @"software_version":@"fixture-version", @"serial_number":@"fixture-serial",
        @"hardware_version":@"fixture-model", @"unique_device_id":@"fixture-device"};
}
// Only this class is stubbed because its real implementation imports UIKit.
@implementation OBRelayIdentifiers
+ (NSDictionary *)versionIdentifiers { return Identifiers(); }
+ (NSString *)hardwareModel { return @"fixture-model"; }
@end

static NSDictionary *Headers(void) {
    return @{@"X-Apple-I-MD":@"fixture", @"X-Apple-I-MD-M":@"fixture",
        @"X-Apple-I-MD-RINFO":@"1", @"X-Mme-Device-Id":@"fixture-device",
        @"X-Mme-Client-Info":@"fixture", @"X-Apple-I-Client-Time":@"fixture",
        @"X-Apple-I-SRL-NO":@"fixture-serial", @"User-Agent":@"fixture"};
}

@interface Recorder : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *messages;
- (void)receive:(NSString *)text;
- (NSArray<NSDictionary *> *)snapshot;
- (BOOL)waitForCount:(NSUInteger)count;
@end
@implementation Recorder
- (instancetype)init { if ((self=[super init])) { _lock=[NSLock new]; _messages=[NSMutableArray new]; } return self; }
- (void)receive:(NSString *)text {
    id value=[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    Check([value isKindOfClass:NSDictionary.class], "reply is JSON dictionary");
    [self.lock lock]; [self.messages addObject:value]; [self.lock unlock];
}
- (NSArray *)snapshot { [self.lock lock]; NSArray *a=[self.messages copy]; [self.lock unlock]; return a; }
- (BOOL)waitForCount:(NSUInteger)count {
    double until=NSProcessInfo.processInfo.systemUptime+2;
    while (NSProcessInfo.processInfo.systemUptime<until) {
        if (self.snapshot.count>=count) return YES;
        [NSThread sleepForTimeInterval:0.005];
    }
    return NO;
}
@end

@interface FakeHeaders : NSObject <OBRelayHeaderGenerating>
@property(atomic) BOOL hold;
@property(atomic) NSUInteger calls;
@property(nonatomic, copy) void (^pending)(NSDictionary *);
@property(nonatomic, strong) dispatch_semaphore_t entered;
- (void)fulfill;
@end
@implementation FakeHeaders
- (instancetype)init { if ((self=[super init])) _entered=dispatch_semaphore_create(0); return self; }
- (void)fetchHeadersWithDeadline:(double)deadline completion:(void (^)(NSDictionary *))completion {
    (void)deadline; self.calls++;
    if (self.hold) { @synchronized(self) { self.pending=completion; } }
    else completion(Headers());
    dispatch_semaphore_signal(self.entered);
}
- (void)fulfill {
    void (^pending)(NSDictionary *);
    @synchronized(self) { pending=self.pending; self.pending=nil; }
    if (pending) pending(Headers());
}
@end

@interface FakeQualifier : NSObject <OBRelayEmptyQualifierGenerating>
@property(atomic) BOOL hold;
@property(atomic) NSUInteger calls;
@property(nonatomic, copy) void (^pending)(NSMutableData *);
@property(nonatomic, strong) dispatch_semaphore_t entered;
@property(nonatomic, strong) NSMutableData *lastProof;
- (void)fulfill;
@end
@implementation FakeQualifier
- (instancetype)init { if ((self=[super init])) _entered=dispatch_semaphore_create(0); return self; }
- (void)generateEmptyQualifierWithDeadline:(double)deadline completion:(void (^)(NSMutableData *))completion {
    (void)deadline; self.calls++;
    if (self.hold) { @synchronized(self) { self.pending=completion; } }
    else { self.lastProof=[[@"fixture-account-proof" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; completion(self.lastProof); }
    dispatch_semaphore_signal(self.entered);
}
- (void)fulfill {
    void (^pending)(NSMutableData *);
    @synchronized(self) { pending=self.pending; self.pending=nil; }
    self.lastProof=[[@"fixture-late-account-proof" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (pending) pending(self.lastProof);
}
@end

@interface FakeNAC : NSObject <OBNACValidating>
@property(atomic) NSUInteger calls;
@end
@implementation FakeNAC
- (void)generateValidationDataWithDeadline:(double)deadline completion:(void (^)(NSData *))completion {
    (void)deadline; self.calls++; completion([@"fixture-device-NAC" dataUsingEncoding:NSUTF8StringEncoding]);
}
@end

static BOOL Entered(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC))==0;
}
static void Drain(OBRelayDispatcher *dispatcher) { dispatch_sync([dispatcher valueForKey:@"controlQueue"], ^{}); }
static OBRelayDispatcher *Dispatcher(FakeHeaders *h, FakeQualifier *q, FakeNAC *n) {
    return [[OBRelayDispatcher alloc] initWithHeaderGenerator:h qualifierGenerator:q validator:n];
}
static void Version(OBRelayDispatcher *d, NSNumber *request, Recorder *r) {
    [d handleCommand:@"get-version-info" requestID:request identifiers:Identifiers() reply:^(NSString *text){ [r receive:text]; }];
}
static NSDictionary *Versions(Recorder *r, NSUInteger index) { return r.snapshot[index][@"data"][@"versions"]; }
static void AssertUnavailable(Recorder *r, NSUInteger index) {
    NSDictionary *v=Versions(r,index);
    Check([v[@"ob_auth_capabilities"] isEqual:@"native-account-v1"], "failure retains static capability");
    Check(v[@"ob_auth_bundle_v1"]==nil, "failure has no stale native bundle");
    Check(v.count==7, "six legacy fields preserved on failure");
}

// Fake sockets accept the production NSURLSessionWebSocketMessage, but never
// open a real socket or use NSURLSession's network task APIs.
@interface FakeTask : NSObject
@property(nonatomic, strong) Recorder *recorder;
@property(atomic) NSUInteger closes;
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completion;
- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason;
@end
@implementation FakeTask
- (instancetype)init { if ((self=[super init])) _recorder=[Recorder new]; return self; }
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completion {
    [self.recorder receive:message.string]; completion(nil);
}
- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    (void)code; (void)reason; self.closes++;
}
@end
@interface OBRelayConnection (Fixture)
- (void)handleText:(NSString *)text fromTask:(NSURLSessionWebSocketTask *)task;
- (void)teardownOnStateQueue;
@end

static void ConnectionCommand(OBRelayConnection *c, FakeTask *task, NSUInteger request) {
    NSString *text=[NSString stringWithFormat:@"{\"command\":\"get-version-info\",\"id\":%lu}",(unsigned long)request];
    [c handleText:text fromTask:(NSURLSessionWebSocketTask *)task];
}

int main(void) {
    @autoreleasepool {
        // Successful account bundle, and device NAC remains a separate route.
        FakeHeaders *h=[FakeHeaders new]; FakeQualifier *q=[FakeQualifier new]; FakeNAC *n=[FakeNAC new];
        OBRelayDispatcher *d=Dispatcher(h,q,n); Recorder *r=[Recorder new];
        Version(d,@1,r); Check([r waitForCount:1],"successful bundle replies"); Drain(d);
        Check(Versions(r,0)[@"ob_auth_bundle_v1"]!=nil,"successful bundle present");
        Check(q.lastProof.length==0,"successful mutable account proof wiped");
        Check(h.calls==1 && q.calls==1 && n.calls==0,"account bundle never calls NAC");
        [d handleCommand:@"get-validation-data" requestID:@2 identifiers:@{} reply:^(NSString *text){[r receive:text];}];
        Check([r waitForCount:2],"device validation replies"); Drain(d);
        NSData *nac=[[NSData alloc] initWithBase64EncodedString:r.snapshot[1][@"data"][@"data"] options:0];
        Check([nac isEqual:[@"fixture-device-NAC" dataUsingEncoding:NSUTF8StringEncoding]],"NAC bytes pass unchanged");
        Check(n.calls==1 && q.calls==1,"device validation never calls account qualifier");

        // Cancellation during qualifier transfer must wipe a late result.
        h=[FakeHeaders new]; q=[FakeQualifier new]; q.hold=YES; n=[FakeNAC new];
        d=Dispatcher(h,q,n); r=[Recorder new]; Version(d,@3,r);
        Check(Entered(q.entered),"held qualifier admitted"); [d invalidatePendingRequest]; Drain(d);
        [q fulfill]; Drain(d);
        Check(q.lastProof.length==0 && r.snapshot.count==0,"cancelled late proof wiped without reply");

        // A deadline has one failure reply and never starts additional hidden
        // native work, including after a late native callback eventually arrives.
        h=[FakeHeaders new]; q=[FakeQualifier new]; q.hold=YES; n=[FakeNAC new];
        d=Dispatcher(h,q,n); d.generationSeconds=0.03; r=[Recorder new]; Version(d,@4,r);
        Check(Entered(q.entered),"timeout qualifier admitted");
        Check([r waitForCount:1],"deadline produces bounded failure"); AssertUnavailable(r,0);
        [q fulfill]; Drain(d); Check(q.lastProof.length==0,"proof arriving after deadline wiped");
        Version(d,@5,r); Check([r waitForCount:2],"quarantined request replies unavailable"); Drain(d);
        AssertUnavailable(r,1); Check(h.calls==1 && q.calls==1,"timeout cannot grow native work");

        // The budget includes admission delay, not only eventual queue entry.
        h=[FakeHeaders new]; q=[FakeQualifier new]; n=[FakeNAC new]; d=Dispatcher(h,q,n);
        d.generationSeconds=0.01; r=[Recorder new]; dispatch_semaphore_t gate=dispatch_semaphore_create(0);
        dispatch_async([d valueForKey:@"controlQueue"], ^{ dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER); });
        Version(d,@6,r); [NSThread sleepForTimeInterval:0.025]; dispatch_semaphore_signal(gate);
        Check([r waitForCount:1],"delayed admission expires"); Drain(d); AssertUnavailable(r,0);
        Check(h.calls==0 && q.calls==0,"expired admission starts no native generator");

        // Real connection routing with fake tasks: replaced task is closed,
        // stale completion cannot send to replacement, and busy is bounded.
        h=[FakeHeaders new]; h.hold=YES; q=[FakeQualifier new]; n=[FakeNAC new]; d=Dispatcher(h,q,n);
        NSString *suite=[@"dev.openbubbles.relay.socket-fixture." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
        NSURL *url=[NSURL URLWithString:@"wss://fixture.invalid/api/v1/provider"];
        OBRelayRegistrationStore *store=[[OBRelayRegistrationStore alloc] initWithRelayURL:url defaults:defaults];
        OBRelayConnection *c=[[OBRelayConnection alloc] initWithDispatcher:d store:store url:url];
        FakeTask *a=[FakeTask new], *b=[FakeTask new];
        dispatch_queue_t state=[c valueForKey:@"stateQueue"];
        dispatch_sync(state, ^{ [c setValue:a forKey:@"task"]; [c setValue:@YES forKey:@"registered"]; [c setValue:@1 forKey:@"epoch"]; });
        ConnectionCommand(c,a,7); Check(Entered(h.entered),"old socket request starts once");
        dispatch_sync(state, ^{ [c teardownOnStateQueue]; [c setValue:b forKey:@"task"]; [c setValue:@YES forKey:@"registered"]; });
        for (NSUInteger i=0;i<20;i++) ConnectionCommand(c,b,100+i);
        Check([b.recorder waitForCount:20],"busy replacement requests finish without native queue");
        Check(h.calls==1 && a.closes==1,"one native call and exact old socket closed");
        [h fulfill]; Drain(d); dispatch_sync(state,^{});
        Check(a.recorder.snapshot.count==0 && b.recorder.snapshot.count==20,"late old result cannot reach either socket");
        for (NSUInteger i=0;i<20;i++) AssertUnavailable(b.recorder,i);
        h.hold=NO; ConnectionCommand(c,b,200);
        Check([b.recorder waitForCount:21],"replacement succeeds after old operation settles");
        Check(Versions(b.recorder,20)[@"ob_auth_bundle_v1"]!=nil,"fresh replacement owns successful reply");
        Check([b.recorder.snapshot[20][@"id"] isEqual:@200],"fresh reply retains exact request id");
        dispatch_sync(state,^{[c teardownOnStateQueue];});
        [[c valueForKey:@"session"] invalidateAndCancel];
        [defaults removePersistentDomainForName:suite];

        Check([OBRelayAuthBundle bundleStringWithHeaders:Headers() qualifier:[@"fixture" dataUsingEncoding:NSUTF8StringEncoding]
            elapsedMilliseconds:45001]==nil,"bundle builder enforces 45 second bound");
        printf("PASS native-relay %lu checks (production components, synthetic generators/tasks)\n",(unsigned long)atomic_load(&checks));
    }
    return 0;
}
