#import <Foundation/Foundation.h>
#import "OBRelayPushService.h"
#import "OBRelayPushProtocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSUInteger checks;
static void Check(BOOL value,NSString *name) { checks++;if (!value) { fprintf(stderr,"FAIL: %s\n",name.UTF8String);exit(1); } }
static uint64_t Now(void) { return (uint64_t)(NSDate.date.timeIntervalSince1970*1000); }
static NSString *Command(NSString *code,uint8_t requestID) {
    uint8_t bytes[58]={1,0};uint64_t stamp=Now();
    for (int i=0;i<8;i++) bytes[2+i]=(uint8_t)(stamp>>(56-i*8));
    memset(bytes+10,requestID,16);
    return OBRelayPushMakeCommand([NSData dataWithBytes:bytes length:sizeof(bytes)],code);
}
static NSDictionary *Reply(OBRelayPushService *service,NSString *command,NSString *code) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *result=nil;
    [service handleCommand:command code:code requestID:@7 reply:^(NSString *text) {
        result=[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        dispatch_semaphore_signal(done);
    }];
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"bounded reply");
    return result;
}
int main(void) { @autoreleasepool {
    NSString *suite=[@"dev.openbubbles.tests.push." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
    NSString *code=@"AAAA-BBBB-CCCC-DDDD";
    NSData *cert=[NSMutableData dataWithLength:129];
    __block NSUInteger calls=0;
    OBRelayPushNativeOperation operation=^NSDictionary *(NSDictionary *request) {
        (void)request;calls++;return @{@"certificate":cert,@"signature":NSData.data};
    };
    OBRelayPushService *service=[[OBRelayPushService alloc] initWithDefaults:defaults operation:operation];
    NSString *first=Command(code,1);
    NSDictionary *response=Reply(service,first,code);
    Check([response[@"data"][@"ob_push_v1"][@"schema"] isEqual:@1],@"authenticated discovery response");
    Check(calls==1,@"one admitted operation");
    Check(Reply(service,first,code)[@"data"][@"error"]!=nil,@"same-process replay denied");
    Check(calls==1,@"replay before native call");
    OBRelayPushService *restarted=[[OBRelayPushService alloc] initWithDefaults:
        [[NSUserDefaults alloc] initWithSuiteName:suite] operation:operation];
    Check(Reply(restarted,first,code)[@"data"][@"error"]!=nil,@"replay denied after service reopen");
    Check(calls==1,@"reopen never repeats native call");
    Check(Reply(service,Command(code,2),@"EEEE-FFFF-GGGG-HHHH")[@"data"][@"error"]!=nil,@"wrong ticket denied");
    Check(calls==1,@"wrong ticket before native call");
    NSString *slowSuite=[suite stringByAppendingString:@".slow"];
    NSUserDefaults *slowDefaults=[[NSUserDefaults alloc] initWithSuiteName:slowSuite];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    OBRelayPushService *slow=[[OBRelayPushService alloc] initWithDefaults:slowDefaults operation:^NSDictionary *(NSDictionary *request) {
        (void)request;dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        return @{@"certificate":cert,@"signature":NSData.data};
    }];
    slow.generationSeconds=0.05;
    __block NSUInteger slowReplies=0;dispatch_semaphore_t expired=dispatch_semaphore_create(0);
    [slow handleCommand:Command(code,3) code:code requestID:@1 reply:^(NSString *text) {
        slowReplies++;Check([text containsString:@"native-push-unavailable"],@"deadline failure");dispatch_semaphore_signal(expired);
    }];
    Check(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"slow operation entered");
    Check(Reply(slow,Command(code,4),code)[@"data"][@"error"]!=nil,@"busy rejected without queue");
    Check(dispatch_semaphore_wait(expired,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"deadline observed");
    dispatch_semaphore_signal(release);
    Check(Reply(slow,Command(code,5),code)[@"data"][@"error"]!=nil,@"quarantine survives completion");
    Check(slowReplies==1,@"late completion cannot produce second reply");
    NSDictionary *saved=[defaults dictionaryForKey:@"ob.native-push.replay-v1"];
    Check(saved.count==1,@"only admitted request persisted");
    NSString *description=saved.description;
    Check(![description containsString:code] && ![description containsString:first],@"no ticket or command saved");
    [defaults removePersistentDomainForName:suite];[slowDefaults removePersistentDomainForName:slowSuite];
    printf("native-push-service checks=%lu PASS\n",(unsigned long)checks);
    return 0;
} }
