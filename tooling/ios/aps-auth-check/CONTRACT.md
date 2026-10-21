# One-shot native APS authentication diagnostic

Test-only, not a relay replacement or a general signer. Private key never leaves
the dedicated iPhone. No Apple account/OTP/IDS/PNR/message/CloudKit operation.
Bundle dev.openbubbles.diagnostics.apsauth, executable OBAPSAuthCheck, version1.
Own keychain group plus EXACT com.apple.apsd, no other rights. Group membership
is not OS-read-only; reviewed code must forbid mutation/private-key export.

Default launch does nothing. Only developer flag --ob-aps-auth-once-v1 starts
one loopback49177 listener, one connection,45second observation lifetime. Paired
USB only on the host; never a network forwarder/public listener. Host owns its
launch PID and stops only that process, closing all owned channels on failure.
Native backend work cancellation/side effects remain separately unqualified.

Phase1 host request exactly42ASCII bytes: OBAPSAU1:<32lowercase hex nonce>\n.
Reply four-byte big-endian length then<=16384UTF-8 JSON. Exact8fields:

- schema: integer1, not boolean.
- source_sha: exact expected40lowercase hex commit.
- nonce: exact request32lowercase hex.
- phase: certificate.
- status: ready, framework-unavailable, class-unavailable, abi-rejected,
  identity-unavailable, certificate-unavailable, key-unavailable,
  key-kind-rejected, public-key-mismatch, native-exception.
- certificate_der_b64: canonical standard Base64, decoded129..8192bytes if ready;
  otherwise null. This is PRIVATE runtime input, never log/persist/display it.
- key_bits: one of1024,2048,3072,4096 if ready, otherwise null.
- private_key_exported: boolean false.

Native exact ABI check for APSConnection.copyIdentity precedes invocation. It
obtains certificate/private-key references, requires RSA/valid size, compares
PUBLIC key representations, returns PUBLIC certificate DER only. No private-key
export, arbitrary keychain lookup, signature or mutation in phase1.

Only after a successful certificate reply, phase2 host sends EXACT17raw bytes
from production generate_nonce(NonceType::APNS): byte0=0, bytes1..8 unsigned
big-endian Unix milliseconds, bytes9..16 random. Require timestamp>0 and within
30000milliseconds of device clock, inclusive. One nonce only, no HTTP nonce,
body/topic/URL/path arguments or retries. Receive timeout15seconds, whole native
lifetime45seconds. Signature algorithm RSASignatureMessagePKCS1v15SHA1, exactly
once; verify it locally against that certificate before returning it.

Phase2 reply same four-byte length/16384 limit, exact9JSONfields:

- schema,source_sha,nonce,private_key_exported: same values/types as phase1.
- phase: signature.
- status: ready, nonce-rejected, signature-unavailable, verification-failed,
  native-exception.
- signature_b64: canonical standard Base64 of raw RSA signature, decoded length
  exactly key_bits/8 (128..512) if ready; otherwise null.
- signature_bytes: integer decoded size if ready; integer0 otherwise, never bool.
- native_verified: boolean true if ready; boolean false otherwise.

No raw certificate/signature/nonce/token/key values or arbitrary exception text
may be printed or retained. UI/receipts report only fixed outcomes/counts. JSON
parsers reject invalid UTF-8, duplicate/unknown/missing fields, nonfinite values,
bool-as-int, wrong source/nonce/phase, noncanonical Base64 and incoherent states.
Codec returns decoded bytes in memory only; callers must never log the dicts.

Windows qualifier uses one isolated process, no working profile/global keystore
replacement, activation or account state. Rust production nonce generation,
SHA1/PKCS1 semantics, signature prefix[1,1], TLS root/hostname/route and raw Connect
packet encoding must be reused. Use existing apns-security-v3 raw framing only
to permit strict bounded response parsing; this is not a TLS-verification bypass.
One logical APS Connect, no ResourceManager, reconnect, topics, SetState or ACKs.
Any routing/TCP alternatives remain finite production transport setup, not extra
APS authentication attempts. Validate native signature before Apple auth write.

Parent Python privately pipes public cert into the source-pinned Rust EXE as
u32BE length+DER (<=8192). Child writes kind1 byte+u32BE length17+APNs nonce to its
PRIVATE stdout pipe; parent forwards it once, then supplies u32BE size+raw native
signature on stdin. Child writes kind2 byte+u32BE JSON length<=4096 with sanitized
result, no other stdout. stderr empty or one fixed panic/error marker only.
Parent owns child deadlines/cleanup and verifies EXE/source/native-app pins.

Acceptance: native signature verifies locally AND one APS ConnectResponse status0
with token present, plus actual owned cleanup. Persist only fixed result fields
and counts, not credentials/proofs. This is fresh-client native-identity APS proof,
not new certificate issuance/account login/Android/SIM/CloudKit production proof.
