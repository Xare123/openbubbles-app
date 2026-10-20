// Executable Foundation fixtures. No real defaults, network, device or account.
#import <Foundation/Foundation.h>
#import "OBRelayRegistrationStore.h"
#include <stdio.h>
#include <stdlib.h>

static NSUInteger checks;
static void Check(BOOL condition, NSString *name) {
    if (!condition) {
        fprintf(stderr, "FAIL registration-store: %s\n", name.UTF8String);
        exit(1);
    }
    checks++;
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"dev.openbubbles.relay.fixture." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSURL *url = [NSURL URLWithString:@"wss://fixture.invalid/api/v1/provider"];
        @try {
            OBRelayRegistrationStore *store = [[OBRelayRegistrationStore alloc] initWithRelayURL:url defaults:defaults];
            Check(!store.hasSavedRegistration, @"fresh store has no tuple");
            Check([[store registerDataWithHardwareModel:nil] count] == 0, @"fresh request has no private fields");
            Check([store acceptRegistrationData:@{@"code":@"ABCD-EF12-3456-GH78", @"secret":@"fixture-only",
                @"ob_auth_bundle_v1":@"must-not-save", @"password":@"must-not-save"}] != nil, @"valid tuple accepted");
            NSDictionary *saved = [defaults objectForKey:@"dev.openbubbles.relay.registration-v1"];
            Check([[NSSet setWithArray:saved.allKeys] isEqualToSet:[NSSet setWithArray:@[@"code", @"secret", @"url"]]],
                @"only tuple fields persisted");
            OBRelayRegistrationStore *reopened = [[OBRelayRegistrationStore alloc] initWithRelayURL:url defaults:defaults];
            Check(reopened.hasSavedRegistration && [reopened.code isEqualToString:store.code]
                && [reopened.secret isEqualToString:store.secret], @"tuple survives reconstructed store");
            NSDictionary *request = [reopened registerDataWithHardwareModel:@"fixture-model"];
            Check(request.count == 3 && [request[@"versions"] isEqual:@{@"hardware_version":@"fixture-model"}],
                @"registration request contains only tuple and model");
            OBRelayRegistrationStore *other = [[OBRelayRegistrationStore alloc]
                initWithRelayURL:[NSURL URLWithString:@"wss://other.invalid/api/v1/provider"] defaults:defaults];
            Check(!other.hasSavedRegistration, @"different origin cannot consume saved tuple");
            for (id invalid in @[@{}, @{@"code":@"123456", @"secret":@"fixture-only"},
                @{@"code":@"abcd-ef12-3456-gh78", @"secret":@"fixture-only"},
                @{@"code":@"ABCD-EF12-3456-GH78", @"secret":@""},
                @{@"code":@"ABCD-EF12-3456-GH78", @"secret":@"line\nbreak"}]) {
                Check([store acceptRegistrationData:invalid] == nil, @"malformed tuple rejected");
                Check([[defaults objectForKey:@"dev.openbubbles.relay.registration-v1"] isEqual:saved],
                    @"rejection leaves existing tuple unchanged");
            }
            [defaults removeObjectForKey:@"dev.openbubbles.relay.registration-v1"];
            [defaults setObject:@"ABCD-EF12-3456-GH78" forKey:@"dev.openbubbles.relay.savedCode"];
            [defaults setObject:@"fixture-only" forKey:@"dev.openbubbles.relay.savedSecret"];
            [defaults setObject:url.absoluteString forKey:@"dev.openbubbles.relay.savedURL"];
            OBRelayRegistrationStore *legacy = [[OBRelayRegistrationStore alloc] initWithRelayURL:url defaults:defaults];
            Check(legacy.hasSavedRegistration, @"legacy tuple remains readable");
            Check([defaults objectForKey:@"dev.openbubbles.relay.savedCode"] != nil
                && [defaults objectForKey:@"dev.openbubbles.relay.registration-v1"] == nil,
                @"legacy read does not delete or rewrite recovery data");
            printf("PASS registration-store %lu checks (synthetic isolated defaults)\n", (unsigned long)checks);
        } @finally {
            // This exact randomized suite was created by this fixture only.
            [defaults removePersistentDomainForName:suite];
        }
    }
    return 0;
}
