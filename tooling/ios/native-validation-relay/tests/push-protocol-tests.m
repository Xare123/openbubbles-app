// Standalone Foundation host test for the production push wire codec.
// Tests the real codec (OBRelayPushProtocol.h/.m); there is no mocked
// duplicate parser. Synthetic fixtures only: fixed ticket codes, fixed ids,
// fixed pins, fixed timestamps. Covers valid op0/op1/op2 round trips, two
// frozen known-answer vectors (the parent-frozen cross-language op0 vector
// plus a local synthetic-ticket vector), malformed and truncated inputs,
// canonical base64url enforcement, wrong code and MAC rejection, field rule
// violations, stale and future timestamps (including uint64 boundaries),
// nonce tag and time rules, bag range, and response MAC binding.
// Host execution needs an Apple SDK; on other hosts record UNRUN.
#import <Foundation/Foundation.h>
#import "OBRelayPushProtocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSUInteger gChecks = 0;
static void Check(BOOL ok, const char *name) {
    if (!ok) { fprintf(stderr, "FAIL push-protocol: %s\n", name); exit(1); }
    gChecks++;
}

static void AppendU64BE(NSMutableData *d, uint64_t v) {
    uint8_t b[8];
    for (int i = 7; i >= 0; i--) { b[i] = (uint8_t)(v & 0xFF); v >>= 8; }
    [d appendBytes:b length:8];
}

static NSData *FixedRequestID(void) {
    uint8_t b[16];
    for (int i = 0; i < 16; i++) b[i] = (uint8_t)(i + 1);
    return [NSData dataWithBytes:b length:16];
}

static NSData *FixedPin(void) {
    NSMutableData *d = [NSMutableData dataWithLength:32];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (int i = 0; i < 32; i++) p[i] = (uint8_t)(0xA0 + (i & 0x0F));
    return d;
}

static NSData *PayloadWith(uint8_t op, uint64_t issued, NSData *rid, NSData *pin,
                            uint8_t tag, uint64_t nonceTs, NSData *rand8,
                            uint8_t bag, NSData *digest) {
    NSMutableData *d = [NSMutableData data];
    uint8_t version = 1;
    [d appendBytes:&version length:1];
    [d appendBytes:&op length:1];
    AppendU64BE(d, issued);
    [d appendData:rid];
    [d appendData:pin];
    if (op == 1 || op == 2) {
        [d appendBytes:&tag length:1];
        AppendU64BE(d, nonceTs);
        [d appendData:rand8];
        if (op == 2) {
            [d appendBytes:&bag length:1];
            [d appendData:digest];
        }
    }
    return d;
}

static NSData *Mutated(NSData *p, NSUInteger index, uint8_t value) {
    NSMutableData *m = [p mutableCopy];
    ((uint8_t *)m.mutableBytes)[index] = value;
    return m;
}

static NSString *HexOf(NSData *d) {
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    const uint8_t *p = (const uint8_t *)d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static int B64Value(unichar c) {
    if (c >= 'A' && c <= 'Z') return (int)(c - 'A');
    if (c >= 'a' && c <= 'z') return (int)(c - 'a' + 26);
    if (c >= '0' && c <= '9') return (int)(c - '0' + 52);
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

static unichar B64Char(int v) {
    static const char kAlpha[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    if (v < 0 || v > 63) return (unichar)'A';
    return (unichar)kAlpha[v];
}

int main(void) {
    @autoreleasepool {
        NSString *xlangCode = @"AAAA-BBBB-CCCC-DDDD";
        NSString *vecCode = @"OBP1-TEST-VEC1-0001";
        NSString *code = @"SYNT-H00P-TEST-0001";
        NSString *otherCode = @"DIFF-EREN-T000-0001";
        const uint64_t now = 1750000000000ULL;
        const uint64_t xlangNow = 1800000000000ULL;
        NSData *rid = FixedRequestID();
        NSData *pin = FixedPin();
        NSMutableData *zeroPin = [NSMutableData dataWithLength:32];
        NSMutableData *zeroID = [NSMutableData dataWithLength:16];
        uint8_t randBytes[8] = {0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7};
        NSData *rand8 = [NSData dataWithBytes:randBytes length:8];
        uint8_t digestBytes[20];
        for (int i = 0; i < 20; i++) digestBytes[i] = (uint8_t)(0xD0 + i);
        NSData *digest20 = [NSData dataWithBytes:digestBytes length:20];

        // Parent-frozen cross-language vector, verified against an
        // independent Python HMAC-SHA256 reference: code
        // AAAA-BBBB-CCCC-DDDD, version 1, op0, issued 1800000000000,
        // request_id sixteen 0x01 bytes, pin 32 zero bytes, domain
        // "OBPushRequest1" + NUL + payload, MAC
        // 4946de28f864169936eb6797aef9d34f568123eba1493c0f15f355a82e7bce72.
        NSMutableData *xlangID = [NSMutableData dataWithLength:16];
        memset(xlangID.mutableBytes, 0x01, 16);
        NSData *xlangPayload = PayloadWith(0, xlangNow, xlangID, zeroPin, 0, 0, rand8, 0, digest20);
        Check(xlangPayload.length == 58, "xlang payload is 58 bytes");
        NSString *xlangCommand = OBRelayPushMakeCommand(xlangPayload, xlangCode);
        Check([xlangCommand isEqualToString:@"ob-push-v1.AQAAAAGjGFxQAAEBAQEBAQEBAQEBAQEBAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElG3ij4ZBaZNutnl675009WgSProUk8DxXzVague85y"], "xlang HMAC vector command bytes");
        NSDictionary *xlangFields = OBRelayPushParseCommand(xlangCommand, xlangCode, xlangNow);
        Check(xlangFields != nil, "xlang vector parses");
        Check([xlangFields[@"operation"] isEqual:@0], "xlang trusted operation");
        Check([xlangFields[@"issued_ms"] isEqual:@(xlangNow)], "xlang trusted issued_ms");
        Check([HexOf(xlangFields[@"request_sha256"]) isEqualToString:@"c3b9079b502835ff933c27c5c49ad0722f9eb9747433ffdd0bcf2c271377bf79"], "xlang trusted request_sha256");

        // Valid op0 round trip with a synthetic ticket.
        NSData *p0 = PayloadWith(0, now, rid, zeroPin, 0, 0, rand8, 0, digest20);
        Check(p0.length == 58, "op0 payload is 58 bytes");
        NSString *c0 = OBRelayPushMakeCommand(p0, code);
        Check(c0 != nil, "op0 make succeeds");
        Check(c0.length <= 256, "op0 command within 256 chars");
        Check([c0 hasPrefix:@"ob-push-v1."], "op0 command prefix");
        Check([c0 rangeOfString:code].location == NSNotFound, "ticket code never in command path");
        NSDictionary *f0 = OBRelayPushParseCommand(c0, code, now);
        Check(f0 != nil, "op0 parse succeeds");
        Check([f0[@"operation"] isEqual:@0], "op0 trusted operation");
        Check([f0[@"issued_ms"] isEqual:@(now)], "op0 trusted issued_ms");
        Check([f0[@"request_id"] isEqualToData:rid], "op0 trusted request_id");
        Check([f0[@"certificate_pin"] length] == 32, "op0 trusted pin length");
        Check([f0[@"nonce"] length] == 0, "op0 empty nonce");
        Check([f0[@"bag"] isEqual:@0], "op0 bag zero");
        Check([f0[@"digest"] length] == 0, "op0 empty digest");
        Check([f0[@"request_sha256"] length] == 32, "op0 trusted request_sha256 length");

        // Local synthetic-ticket known-answer vector: op0, issued
        // 1750000000000, id 01..10, zero pin, ticket OBP1-TEST-VEC1-0001.
        // The command string pins HMAC
        // 949746f530b3050edb39816145824cc5179c4e28fc1160497c0c7ec02f0f54f1.
        NSData *vecPayload = PayloadWith(0, now, rid, zeroPin, 0, 0, rand8, 0, digest20);
        NSString *vecCommand = OBRelayPushMakeCommand(vecPayload, vecCode);
        Check([vecCommand isEqualToString:@"ob-push-v1.AQAAAAGXdCDcAAECAwQFBgcICQoLDA0ODxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJSXRvUwswUO2zmBYUWCTMUXnE4o_BFgSXwMfsAvD1Tx"], "known HMAC vector command bytes");
        NSDictionary *vecFields = OBRelayPushParseCommand(vecCommand, vecCode, now);
        Check(vecFields != nil, "known vector parses");
        Check([HexOf(vecFields[@"request_sha256"]) isEqualToString:@"0cb20564e699b6c4a587d5d16ce95991b36b3a843803bdc942f896abc9d382f2"], "known vector request_sha256");

        // Valid op1 and op2 round trips.
        NSData *p1 = PayloadWith(1, now, rid, pin, 0, now, rand8, 0, digest20);
        Check(p1.length == 75, "op1 payload is 75 bytes");
        NSString *c1 = OBRelayPushMakeCommand(p1, code);
        Check(c1 != nil, "op1 make succeeds");
        NSDictionary *f1 = OBRelayPushParseCommand(c1, code, now);
        Check(f1 != nil, "op1 parse succeeds");
        Check([f1[@"operation"] isEqual:@1], "op1 trusted operation");
        Check([f1[@"nonce"] length] == 17, "op1 nonce length");
        Check(((const uint8_t *)[f1[@"nonce"] bytes])[0] == 0, "op1 nonce tag");
        Check([f1[@"certificate_pin"] isEqualToData:pin], "op1 trusted pin");
        Check([f1[@"bag"] isEqual:@0], "op1 bag zero");
        Check([f1[@"digest"] length] == 0, "op1 empty digest");
        NSData *p2 = PayloadWith(2, now, rid, pin, 1, now, rand8, 2, digest20);
        Check(p2.length == 96, "op2 payload is 96 bytes");
        NSString *c2 = OBRelayPushMakeCommand(p2, code);
        Check(c2 != nil, "op2 make succeeds");
        NSDictionary *f2 = OBRelayPushParseCommand(c2, code, now);
        Check(f2 != nil, "op2 parse succeeds");
        Check([f2[@"bag"] isEqual:@2], "op2 trusted bag");
        Check([f2[@"digest"] isEqualToData:digest20], "op2 trusted digest");
        Check(((const uint8_t *)[f2[@"nonce"] bytes])[0] == 1, "op2 nonce tag");

        // Malformed, truncated, padded, and wrong-length inputs.
        NSString *body0 = [c0 substringFromIndex:11];
        Check(OBRelayPushParseCommand([@"ob-push-v2." stringByAppendingString:body0], code, now) == nil, "wrong prefix rejected");
        Check(OBRelayPushParseCommand([c0 substringToIndex:c0.length - 1], code, now) == nil, "truncation rejected");
        Check(OBRelayPushParseCommand([@"ob-push-v1.+" stringByAppendingString:[body0 substringFromIndex:1]], code, now) == nil, "non-alphabet char rejected");
        Check(OBRelayPushParseCommand([c0 stringByAppendingString:@"="], code, now) == nil, "padding rejected");
        Check(OBRelayPushParseCommand(@"ob-push-v1.ABCDE", code, now) == nil, "bad quantum length rejected");
        Check(OBRelayPushParseCommand(@"", code, now) == nil, "empty command rejected");
        Check(OBRelayPushParseCommand(nil, code, now) == nil, "nil command rejected");
        Check(OBRelayPushParseCommand(c0, nil, now) == nil, "nil code rejected");
        Check(OBRelayPushMakeCommand(nil, code) == nil, "nil payload rejected");
        Check(OBRelayPushMakeCommand(p0, nil) == nil, "nil make code rejected");
        Check(OBRelayPushMakeCommand([NSMutableData dataWithLength:59], code) == nil, "59-byte payload rejected");
        Check(OBRelayPushMakeCommand([NSData data], code) == nil, "empty payload rejected");
        NSString *tooLong = [c0 stringByPaddingToLength:(c0.length + 200) withString:@"A" startingAtIndex:0];
        Check(tooLong.length > 256, "overlong fixture really long");
        Check(OBRelayPushParseCommand(tooLong, code, now) == nil, "overlong command rejected");
        Check(OBRelayPushParseCommand([c0 stringByAppendingString:@"AAAA"], code, now) == nil, "wrong decoded length rejected");

        // Non-canonical trailing bits: op1 body is 143 chars, so the final
        // quantum leaves 2 unused bits. Flipping them keeps the decoded
        // bytes (and MAC) identical, so only the canonical re-encode check
        // can reject this input.
        NSString *body1 = [c1 substringFromIndex:11];
        Check(body1.length == 143, "op1 body length pins trailing-bits quantum");
        unichar lastChar = [body1 characterAtIndex:body1.length - 1];
        int lastVal = B64Value(lastChar);
        Check(lastVal >= 0, "op1 body ends in base64url char");
        Check((lastVal & 3) == 0, "canonical fixture has zero trailing bits");
        int altVal = (lastVal & ~3) | ((lastVal + 1) & 3);
        NSMutableString *nonCanon = [body1 mutableCopy];
        [nonCanon replaceCharactersInRange:NSMakeRange(body1.length - 1, 1)
                                withString:[NSString stringWithFormat:@"%C", B64Char(altVal)]];
        Check(OBRelayPushParseCommand([@"ob-push-v1." stringByAppendingString:nonCanon], code, now) == nil, "non-canonical trailing bits rejected");

        // Wrong code and wrong MAC.
        Check(OBRelayPushParseCommand(c0, otherCode, now) == nil, "wrong code rejected");
        Check(OBRelayPushParseCommand(c0, @"synt-h00p-test-0001", now) == nil, "lowercase code rejected");
        Check(OBRelayPushMakeCommand(p0, @"SHORT") == nil, "short code rejected");
        unichar tailChar = [body0 characterAtIndex:body0.length - 1];
        unichar tailFlip = (tailChar == 'A') ? 'B' : 'A';
        NSMutableString *macFlip = [body0 mutableCopy];
        [macFlip replaceCharactersInRange:NSMakeRange(body0.length - 1, 1)
                               withString:[NSString stringWithFormat:@"%C", tailFlip]];
        Check(OBRelayPushParseCommand([@"ob-push-v1." stringByAppendingString:macFlip], code, now) == nil, "tampered MAC rejected");

        // Field rule violations are refused before signing.
        Check(OBRelayPushMakeCommand(Mutated(p0, 0, 2), code) == nil, "bad version rejected");
        Check(OBRelayPushMakeCommand(Mutated(p0, 1, 3), code) == nil, "bad op rejected");
        Check(OBRelayPushMakeCommand(Mutated(p0, 1, 1), code) == nil, "op/length mismatch rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(0, now, rid, pin, 0, 0, rand8, 0, digest20), code) == nil, "op0 nonzero pin rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(1, now, rid, zeroPin, 0, now, rand8, 0, digest20), code) == nil, "op1 zero pin rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(2, now, rid, zeroPin, 1, now, rand8, 2, digest20), code) == nil, "op2 zero pin rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(1, now, zeroID, pin, 0, now, rand8, 0, digest20), code) == nil, "zero request_id rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(1, now, rid, pin, 1, now, rand8, 0, digest20), code) == nil, "op1 wrong nonce tag rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(2, now, rid, pin, 0, now, rand8, 2, digest20), code) == nil, "op2 wrong nonce tag rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(2, now, rid, pin, 1, now, rand8, 0, digest20), code) == nil, "bag 0 rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(2, now, rid, pin, 1, now, rand8, 5, digest20), code) == nil, "bag 5 rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(0, 0, rid, zeroPin, 0, 0, rand8, 0, digest20), code) == nil, "zero issued_ms rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(0, UINT64_MAX, rid, zeroPin, 0, 0, rand8, 0, digest20), code) == nil, "issued_ms above INT64_MAX rejected");
        Check(OBRelayPushMakeCommand(PayloadWith(1, now, rid, pin, 0, 0, rand8, 0, digest20), code) == nil, "zero nonce timestamp rejected");
        NSDictionary *bag1 = OBRelayPushParseCommand(OBRelayPushMakeCommand(PayloadWith(2, now, rid, pin, 1, now, rand8, 1, digest20), code), code, now);
        Check(bag1 != nil && [bag1[@"bag"] isEqual:@1], "bag 1 accepted");
        NSDictionary *bag4 = OBRelayPushParseCommand(OBRelayPushMakeCommand(PayloadWith(2, now, rid, pin, 1, now, rand8, 4, digest20), code), code, now);
        Check(bag4 != nil && [bag4[@"bag"] isEqual:@4], "bag 4 accepted");

        // Freshness window: exact edges pass, one millisecond beyond fails.
        NSString *staleC = OBRelayPushMakeCommand(PayloadWith(0, now - 30001, rid, zeroPin, 0, 0, rand8, 0, digest20), code);
        Check(staleC != nil, "stale payload still signs");
        Check(OBRelayPushParseCommand(staleC, code, now) == nil, "stale issued_ms rejected");
        NSString *futureC = OBRelayPushMakeCommand(PayloadWith(0, now + 30001, rid, zeroPin, 0, 0, rand8, 0, digest20), code);
        Check(OBRelayPushParseCommand(futureC, code, now) == nil, "future issued_ms rejected");
        Check(OBRelayPushParseCommand(OBRelayPushMakeCommand(PayloadWith(0, now - 30000, rid, zeroPin, 0, 0, rand8, 0, digest20), code), code, now) != nil, "old edge accepted");
        Check(OBRelayPushParseCommand(OBRelayPushMakeCommand(PayloadWith(0, now + 30000, rid, zeroPin, 0, 0, rand8, 0, digest20), code), code, now) != nil, "new edge accepted");
        Check(OBRelayPushParseCommand(c0, code, 0) == nil, "zero now_ms rejected explicitly");
        Check(OBRelayPushParseCommand(c0, code, UINT64_MAX) == nil, "now_ms above INT64_MAX rejected explicitly");
        Check(OBRelayPushParseCommand(OBRelayPushMakeCommand(PayloadWith(0, 30001, rid, zeroPin, 0, 0, rand8, 0, digest20), code), code, 0) == nil, "zero now beyond edge rejected");
        NSString *hugeIssued = OBRelayPushMakeCommand(PayloadWith(0, (uint64_t)INT64_MAX, rid, zeroPin, 0, 0, rand8, 0, digest20), code);
        Check(hugeIssued != nil, "INT64_MAX payload still signs");
        Check(OBRelayPushParseCommand(hugeIssued, code, 0) == nil, "INT64_MAX far from zero now rejected");
        Check(OBRelayPushParseCommand(hugeIssued, code, UINT64_MAX) == nil, "uint64 overflow now rejected safely");

        // Nonce freshness follows the same window.
        NSString *staleNC = OBRelayPushMakeCommand(PayloadWith(1, now, rid, pin, 0, now - 30001, rand8, 0, digest20), code);
        Check(staleNC != nil, "stale nonce still signs");
        Check(OBRelayPushParseCommand(staleNC, code, now) == nil, "stale nonce rejected");
        NSString *futureNC = OBRelayPushMakeCommand(PayloadWith(1, now, rid, pin, 0, now + 30001, rand8, 0, digest20), code);
        Check(OBRelayPushParseCommand(futureNC, code, now) == nil, "future nonce rejected");

        // Response MAC binding with a synthetic 129-byte certificate and
        // 128 bytes of synthetic signature material.
        NSData *reqHash = vecFields[@"request_sha256"];
        NSMutableData *cert = [NSMutableData dataWithLength:129];
        uint8_t *certBytes = (uint8_t *)cert.mutableBytes;
        for (int i = 0; i < 129; i++) certBytes[i] = (uint8_t)(i & 0xFF);
        certBytes[0] = 0x30;
        NSMutableData *sig = [NSMutableData dataWithLength:128];
        memset(sig.mutableBytes, 0x55, 128);
        NSData *resp = OBRelayPushResponseMAC(reqHash, cert, sig, vecCode);
        Check(resp != nil && resp.length == 32, "response MAC length");
        Check([HexOf(resp) isEqualToString:@"9873d6af66488e2659c6642f79a2e9541e072ae85a02b85a545c0fc794e631a6"], "response known vector");
        NSMutableData *cert2 = [cert mutableCopy];
        ((uint8_t *)cert2.mutableBytes)[128] ^= 0x01;
        Check(![OBRelayPushResponseMAC(reqHash, cert2, sig, vecCode) isEqualToData:resp], "response binds certificate");
        NSMutableData *sig2 = [sig mutableCopy];
        ((uint8_t *)sig2.mutableBytes)[0] ^= 0x01;
        Check(![OBRelayPushResponseMAC(reqHash, cert, sig2, vecCode) isEqualToData:resp], "response binds signature");
        Check(![OBRelayPushResponseMAC(reqHash, cert, sig, otherCode) isEqualToData:resp], "response binds code");
        Check(OBRelayPushResponseMAC(reqHash, [NSMutableData dataWithLength:128], sig, vecCode) == nil, "short cert rejected");
        Check(OBRelayPushResponseMAC(reqHash, [NSMutableData dataWithLength:8193], sig, vecCode) == nil, "long cert rejected");
        Check(OBRelayPushResponseMAC(reqHash, cert, [NSMutableData dataWithLength:100], vecCode) == nil, "bad sig length rejected");
        Check(OBRelayPushResponseMAC(reqHash, cert, [NSData data], vecCode) != nil, "empty signature binds");
        Check(OBRelayPushResponseMAC([NSMutableData dataWithLength:31], cert, sig, vecCode) == nil, "short hash rejected");
        Check(OBRelayPushResponseMAC(reqHash, cert, sig, @"bad-code") == nil, "malformed code rejected");
        for (NSNumber *sigLen in @[@128, @256, @384, @512]) {
            NSData *s = [NSMutableData dataWithLength:[sigLen unsignedIntegerValue]];
            Check(OBRelayPushResponseMAC(reqHash, cert, s, vecCode) != nil, "allowed signature length binds");
        }

        // Primitives: SHA-256 hex vector and constant-time equality.
        Check([OBRelayPushSHA256Hex([@"abc" dataUsingEncoding:NSASCIIStringEncoding]) isEqualToString:@"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"], "sha256 hex vector");
        Check(OBRelayPushSHA256Hex(nil) == nil, "sha256 nil rejected");
        NSData *macA = [@"mac-fixture-one" dataUsingEncoding:NSASCIIStringEncoding];
        NSData *macB = [macA copy];
        NSMutableData *macC = [macA mutableCopy];
        ((uint8_t *)macC.mutableBytes)[0] ^= 0x01;
        Check(OBRelayPushConstantEqual(macA, macB), "constant equal same");
        Check(!OBRelayPushConstantEqual(macA, macC), "constant equal differs");
        Check(!OBRelayPushConstantEqual(macA, [@"short" dataUsingEncoding:NSASCIIStringEncoding]), "constant equal length mismatch");
        Check(!OBRelayPushConstantEqual(nil, macA), "constant equal nil");

        printf("PASS push-protocol %lu checks (synthetic fixtures only)\n", (unsigned long)gChecks);
    }
    return 0;
}
