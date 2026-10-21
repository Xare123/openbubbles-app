// Bounded native push wire codec. Implements OBRelayPushProtocol.h.
// Strict bounds, canonical unpadded base64url, and every header, nonce,
// bag, and digest rule are enforced before signing, and the parser
// recomputes the MAC and compares it in constant time before trusting any
// field. No payloads, codes, or MACs are logged. No state is kept.
#import "OBRelayPushProtocol.h"
#import <CommonCrypto/CommonCrypto.h>

NSString *const OBRelayPushCommandPrefix = @"ob-push-v1.";

static const NSUInteger kMaxCommandLength = 256;
static const NSUInteger kHeaderLength = 58;
static const NSUInteger kNonceLength = 17;
static const NSUInteger kDigestLength = 20;
static const NSUInteger kMACLength = 32;
static const uint64_t kWindowMs = 30000;
static const uint64_t kInt64Max = 0x7FFFFFFFFFFFFFFFULL;

static const char kRequestLabel[] = "OBPushRequest1";
static const char kResponseLabel[] = "OBPushResponse1";

static BOOL IsValidTicketCode(NSString *code) {
    if (![code isKindOfClass:[NSString class]] || code.length != 19) return NO;
    for (NSUInteger i = 0; i < 19; i++) {
        unichar c = [code characterAtIndex:i];
        if (i == 4 || i == 9 || i == 14) {
            if (c != (unichar)'-') return NO;
        } else if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) {
            return NO;
        }
    }
    return YES;
}

static NSString *Base64URLEncode(NSData *data) {
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    NSMutableString *out = [b64 mutableCopy];
    [out replaceOccurrencesOfString:@"+" withString:@"-" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    while ([out hasSuffix:@"="]) [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    return out;
}

static NSData * _Nullable Base64URLDecodeCanonical(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == (unichar)'-' || c == (unichar)'_';
        if (!ok) return nil;
    }
    if (text.length % 4 == 1) return nil;
    NSMutableString *standard = [text mutableCopy];
    [standard replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, standard.length)];
    [standard replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, standard.length)];
    while (standard.length % 4 != 0) [standard appendString:@"="];
    NSData *raw = [[NSData alloc] initWithBase64EncodedString:standard options:0];
    if (!raw) return nil;
    if (![Base64URLEncode(raw) isEqualToString:text]) return nil;
    return raw;
}

static uint64_t ReadU64BE(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | (uint64_t)p[i];
    return v;
}

static BOOL BytesAllZero(const uint8_t *p, NSUInteger n) {
    for (NSUInteger i = 0; i < n; i++) {
        if (p[i] != 0) return NO;
    }
    return YES;
}

static BOOL WithinWindow(uint64_t value, uint64_t now) {
    if (value == 0 || value > kInt64Max) return NO;
    uint64_t diff = (value >= now) ? (value - now) : (now - value);
    return diff <= kWindowMs;
}

static NSData *RequestMAC(NSData *payload, NSData *key) {
    NSMutableData *input = [NSMutableData dataWithCapacity:sizeof(kRequestLabel) + payload.length];
    [input appendBytes:kRequestLabel length:sizeof(kRequestLabel)];
    [input appendData:payload];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, input.bytes, input.length, mac);
    return [NSData dataWithBytes:mac length:sizeof(mac)];
}

// Returns the operation (0, 1, 2) or -1. Checks every static field rule:
// exact lengths, version, op/length agreement, nonzero request_id, pin
// zero/nonzero per op, nonce tag, nonce timestamp range shape, bag range.
// Freshness against now_ms is the parser's job; range shape (nonzero, at
// most INT64_MAX) is enforced here so bad timestamps never get signed.
static int ValidatePayloadFields(NSData *payload) {
    if (![payload isKindOfClass:[NSData class]]) return -1;
    NSUInteger n = payload.length;
    if (n != 58 && n != 75 && n != 96) return -1;
    const uint8_t *p = (const uint8_t *)payload.bytes;
    if (p[0] != 1) return -1;
    uint8_t op = p[1];
    if (op > 2) return -1;
    if ((op == 0 && n != kHeaderLength) ||
        (op == 1 && n != kHeaderLength + kNonceLength) ||
        (op == 2 && n != kHeaderLength + kNonceLength + 1 + kDigestLength)) return -1;
    uint64_t issued = ReadU64BE(p + 2);
    if (issued == 0 || issued > kInt64Max) return -1;
    if (BytesAllZero(p + 10, 16)) return -1;
    BOOL pinZero = BytesAllZero(p + 26, 32);
    if (op == 0 ? !pinZero : pinZero) return -1;
    if (op == 0) return 0;
    uint8_t wantTag = (op == 1) ? 0 : 1;
    if (p[58] != wantTag) return -1;
    uint64_t nonceTs = ReadU64BE(p + 59);
    if (nonceTs == 0 || nonceTs > kInt64Max) return -1;
    if (op == 2 && (p[75] < 1 || p[75] > 4)) return -1;
    return (int)op;
}

NSString * _Nullable OBRelayPushMakeCommand(NSData * _Nullable payload, NSString * _Nullable code) {
    if (!IsValidTicketCode(code)) return nil;
    if (ValidatePayloadFields(payload) < 0) return nil;
    NSData *key = [code dataUsingEncoding:NSASCIIStringEncoding];
    if (!key || key.length == 0) return nil;
    NSData *mac = RequestMAC(payload, key);
    NSMutableData *raw = [NSMutableData dataWithCapacity:payload.length + kMACLength];
    [raw appendData:payload];
    [raw appendData:mac];
    NSString *command = [OBRelayPushCommandPrefix stringByAppendingString:Base64URLEncode(raw)];
    if (command.length > kMaxCommandLength) return nil;
    return command;
}

NSDictionary<NSString *, id> * _Nullable OBRelayPushParseCommand(
    NSString * _Nullable command, NSString * _Nullable code, uint64_t now_ms) {
    if (![command isKindOfClass:[NSString class]]) return nil;
    if (command.length > kMaxCommandLength) return nil;
    if (![command hasPrefix:OBRelayPushCommandPrefix]) return nil;
    if (!IsValidTicketCode(code)) return nil;
    if (now_ms == 0 || now_ms > kInt64Max) return nil;
    NSString *body = [command substringFromIndex:OBRelayPushCommandPrefix.length];
    NSData *raw = Base64URLDecodeCanonical(body);
    if (!raw) return nil;
    if (raw.length != 58 + 32 && raw.length != 75 + 32 && raw.length != 96 + 32) return nil;
    NSData *payload = [raw subdataWithRange:NSMakeRange(0, raw.length - kMACLength)];
    NSData *mac = [raw subdataWithRange:NSMakeRange(raw.length - kMACLength, kMACLength)];
    NSData *key = [code dataUsingEncoding:NSASCIIStringEncoding];
    if (!key || key.length == 0) return nil;
    if (!OBRelayPushConstantEqual(mac, RequestMAC(payload, key))) return nil;
    int op = ValidatePayloadFields(payload);
    if (op < 0) return nil;
    const uint8_t *p = (const uint8_t *)payload.bytes;
    uint64_t issued = ReadU64BE(p + 2);
    if (!WithinWindow(issued, now_ms)) return nil;
    NSData *nonce = [NSData data];
    NSNumber *bag = @0;
    NSData *digest = [NSData data];
    if (op != 0) {
        if (!WithinWindow(ReadU64BE(p + 59), now_ms)) return nil;
        nonce = [payload subdataWithRange:NSMakeRange(58, kNonceLength)];
        if (op == 2) {
            bag = @(p[75]);
            digest = [payload subdataWithRange:NSMakeRange(76, kDigestLength)];
        }
    }
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(raw.bytes, (CC_LONG)raw.length, sha);
    return @{
        @"operation": @(op),
        @"issued_ms": @(issued),
        @"request_id": [payload subdataWithRange:NSMakeRange(10, 16)],
        @"certificate_pin": [payload subdataWithRange:NSMakeRange(26, 32)],
        @"nonce": nonce,
        @"bag": bag,
        @"digest": digest,
        @"request_sha256": [NSData dataWithBytes:sha length:sizeof(sha)],
    };
}

NSData * _Nullable OBRelayPushResponseMAC(
    NSData * _Nullable requestSHA256, NSData * _Nullable certificate,
    NSData * _Nullable signature, NSString * _Nullable code) {
    if (![requestSHA256 isKindOfClass:[NSData class]] || requestSHA256.length != 32) return nil;
    if (![certificate isKindOfClass:[NSData class]]) return nil;
    if (certificate.length < 129 || certificate.length > 8192) return nil;
    if (![signature isKindOfClass:[NSData class]]) return nil;
    NSUInteger sigLen = signature.length;
    if (sigLen != 0 && sigLen != 128 && sigLen != 256 && sigLen != 384 && sigLen != 512) return nil;
    if (!IsValidTicketCode(code)) return nil;
    NSData *key = [code dataUsingEncoding:NSASCIIStringEncoding];
    if (!key || key.length == 0) return nil;
    NSMutableData *input = [NSMutableData data];
    [input appendBytes:kResponseLabel length:sizeof(kResponseLabel)];
    [input appendData:requestSHA256];
    uint32_t certLen = (uint32_t)certificate.length;
    uint8_t certLenBE[4] = {
        (uint8_t)(certLen >> 24), (uint8_t)(certLen >> 16),
        (uint8_t)(certLen >> 8), (uint8_t)certLen
    };
    [input appendBytes:certLenBE length:4];
    [input appendData:certificate];
    uint16_t sigLen16 = (uint16_t)sigLen;
    uint8_t sigLenBE[2] = { (uint8_t)(sigLen16 >> 8), (uint8_t)sigLen16 };
    [input appendBytes:sigLenBE length:2];
    [input appendData:signature];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, input.bytes, input.length, mac);
    return [NSData dataWithBytes:mac length:sizeof(mac)];
}

NSString * _Nullable OBRelayPushSHA256Hex(NSData * _Nullable data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, sha);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < 32; i++) [hex appendFormat:@"%02x", sha[i]];
    return hex;
}

BOOL OBRelayPushConstantEqual(NSData * _Nullable a, NSData * _Nullable b) {
    if (![a isKindOfClass:[NSData class]] || ![b isKindOfClass:[NSData class]]) return NO;
    if (a.length != b.length) return NO;
    const uint8_t *p = (const uint8_t *)a.bytes;
    const uint8_t *q = (const uint8_t *)b.bytes;
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < a.length; i++) diff |= (uint8_t)(p[i] ^ q[i]);
    return diff == 0;
}
