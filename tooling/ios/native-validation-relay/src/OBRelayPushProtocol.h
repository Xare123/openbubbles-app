// Bounded native push wire codec for the validation relay.
//
// Frozen contract. Command text is the literal prefix "ob-push-v1."
// followed by canonical unpadded base64url of payload || HMAC-SHA256 (32
// bytes). The whole command is at most 256 characters. The ticket code
// matches ^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$ and its raw ASCII bytes are the
// HMAC key. Request signature input is ASCII "OBPushRequest1", one NUL
// byte, then the payload bytes. The 58-byte header is version u8 (= 1),
// operation u8 (0 discovery, 1 APNS, 2 HTTP), issued_ms big-endian u64,
// request_id 16 bytes (not all zero), certificate_pin 32 bytes (all zero
// for op0, not all zero otherwise). op1 appends a 17-byte nonce (tag 0,
// big-endian timestamp_ms u64, 8 random bytes) for 75 bytes total. op2
// appends a 17-byte nonce (tag 1), a bag byte of 1..4, and a 20-byte
// digest for 96 bytes total. issued_ms and nonce timestamps must be within
// 30,000 ms of now_ms; zero and values above INT64_MAX are rejected using
// safe unsigned comparisons. The parser returns only derived trusted
// fields and logs nothing raw. Response MAC input is ASCII
// "OBPushResponse1", one NUL byte, requestSHA256 (32 bytes), certificate
// length u32BE, certificate DER (129..8192 bytes), signature length u16BE,
// raw RSA signature (0, 128, 256, 384, or 512 bytes). No replay store lives
// in this codec; the parent owns replay policy.
//
// Foundation and CommonCrypto only. No callbacks, no Swift.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OBRelayPushCommandPrefix;

// Builds a command from an unsigned payload (exactly 58, 75, or 96 bytes)
// and a ticket code. Returns nil unless the code matches the ticket shape
// and every payload field is inside the bounded contract except freshness
// against the clock, which only the parser can check. The ticket code
// never appears in the returned command.
extern NSString * _Nullable OBRelayPushMakeCommand(NSData * _Nullable payload, NSString * _Nullable code);

// Validates a command against a ticket code at now_ms (milliseconds since
// the Unix epoch). Returns the trusted fields dictionary or nil:
//   operation (NSNumber), issued_ms (NSNumber), request_id (NSData, 16),
//   certificate_pin (NSData, 32), nonce (NSData; empty for op0),
//   bag (NSNumber; 0 outside HTTP), digest (NSData; empty outside HTTP),
//   request_sha256 (NSData, 32: SHA-256 of the full decoded payload||mac).
extern NSDictionary<NSString *, id> * _Nullable OBRelayPushParseCommand(
    NSString * _Nullable command, NSString * _Nullable code, uint64_t now_ms);

// HMAC-SHA256 response authenticator bound to one request, one certificate,
// and one signature. Returns the 32-byte MAC or nil for out-of-range
// inputs. A zero-length signature is allowed and binds "no signature".
extern NSData * _Nullable OBRelayPushResponseMAC(
    NSData * _Nullable requestSHA256, NSData * _Nullable certificate,
    NSData * _Nullable signature, NSString * _Nullable code);

// Lowercase hex SHA-256 of data, or nil for nil input.
extern NSString * _Nullable OBRelayPushSHA256Hex(NSData * _Nullable data);

// Equality for MAC comparison. Length mismatch (or nil) returns NO.
// Equal-length inputs are compared over every byte with no early data exit.
extern BOOL OBRelayPushConstantEqual(NSData * _Nullable a, NSData * _Nullable b);

NS_ASSUME_NONNULL_END
