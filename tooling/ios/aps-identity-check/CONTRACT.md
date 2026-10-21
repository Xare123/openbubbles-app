# Native APS identity metadata diagnostic

This is a separate diagnostic, not a relay/account change or key exporter.
Bundle: `dev.openbubbles.diagnostics.apsidentity`, version1, executable
`OBAPSIdentityCheck`. Default launch does nothing until its one-use button.
Developer launch accepts only `--ob-aps-identity-meta-once-v1` and opens one
loopback-only USB metadata exchange on port49176 with a45second lifetime.

Interface evidence: iOS15.3.1 RuntimeBrowser APSConnection.h at
https://github.com/yuzhouheike/iOS15.3.1-Runtime-Headers/blob/44a5b62df41f5f20d8af6dead3b426a7b401e118/PrivateFrameworks/ApplePushService.framework/APSConnection.h
declares `+(SecIdentityRef)copyIdentity`. Actual15.7.9 runtime must pass the exact
two-argument, SecIdentity-pointer-return ABI check before invocation. This is not
proof of entitlement availability, accepted APNs credentials or Android support.

Request: exactly42ASCII bytes `OBAPSID1:<32 lowercase hex nonce>\n`.
One connection/request, no arbitrary arguments/body/path/URL, no retries after
connect. Response: four-byte big-endian length then <=8192UTF-8 JSON bytes.
Host validates source SHA and fresh request nonce, duplicate-key rejection and
exact field/type sets before retaining the metadata. No generic remote control.

JSON always has these fields:

| Field | Exact type / values |
|---|---|
| schema | integer1, not boolean |
| source_sha | exact expected40lowercase hex commit |
| nonce | exact expected32lowercase hex |
| outcome | ready, framework-unavailable, class-unavailable, abi-rejected, identity-unavailable, identity-type-rejected, certificate-unavailable, private-key-reference-unavailable, public-key-inspection-failed, public-key-mismatch, native-exception |
| identity_present | bool |
| certificate_present | bool |
| private_key_reference_present | bool |
| certificate_copy_status | signed32-bit integer or null |
| private_key_copy_status | signed32-bit integer or null |
| key_type | rsa, ec, other, none |
| key_bits | integer256..16384 or null |
| token_present | bool or null |
| secure_enclave_token | bool or null |
| rsa_sha1_sign_supported | bool or null |
| public_keys_match | bool or null |
| private_key_exported | false |
| explicit_network_requests | integer0, not boolean |
| identity_invalidated | false |
| cache_flushed | false |
| native_backend_side_effects_unqualified | true |

`ready` requires identity/certificate/key references present, both copy statuses0,
non-none key type/non-null valid bits and public_keys_match=true. It means only
that native metadata/reference inspection succeeded. It proves neither private
key exportability nor APS login, phone-number registration or CloudKit.

Only Security public API attribute fields, fixed categorical values and statuses
may be emitted. No identity/certificate/private-key/header values, subject, device
IDs or arbitrary NSError/exception descriptions. Public-key bytes may exist only
transiently for matching the certificate and key reference. Never call
SecKeyCopyExternalRepresentation on a private key, SecKeyCreateSignature,
SecItemCopyMatching, identity invalidation/cache flush, notification registration,
activation/account methods or an HTTP client. The native implementation behind
copyIdentity may touch its own state; do not claim that behavior was disproved.
No root/helper/entitlement escalation or Apple identity spoofing is part of this
initial probe. Preserve every pre-existing app and saved profile.
