# Isolated Corten Mac-validation prototype

Not linked into the production OpenBubbles application. No APK or public release.
This is an AGPL-3.0 historical-source qualification tool, not an assertion of
licensing clearance for distribution of any combined product.

Adapted file: src/nac.rs, from lrhodin/corten-matrix commit
e2adc79d92f4b91fb0ef8bf16439c4411ffbb165, rustpush/open-absinthe/src/nac.rs.
Upstream SHA256: 1a6d7a81030c61f6c3930b61760dac8774a85b0203390cf81bc5daef7e9b0863.
Legacy LICENSE is preserved in LICENSE. Current Corten's MPL license does not
replace the historical license. The historical README credits JJTech0130's
nacserver and Unicorn Engine.

Modifications: emulator-only extraction; no relay, prefetched validation,
native-only backend, optional assembly enrichment, hardware randomization, or
private-value diagnostics. Added exact artifact admission, production-protobuf
input, response/memory/execution limits, return-address checks, and ordered
one-shot challenge processing. CFData range and CFString buffer behavior are
corrected to their actual length/capacity semantics.

Unicorn Rust bindings 2.1.3 declare GPL-2.0 and have their own COPYING file in the
Cargo source. All dependency licenses and compatibility must be reviewed before
shipping; this private test does not authorize relicensing. Original Corten used
2.1.5. This probe pins official 2.1.3 with pre-generated bindings to avoid a new
libclang install. Local Windows proof targets x64 using existing tooling because
the MSVC host setup assumes x86; Android/native ARM64 build remains unqualified.
The external Apple
IMDAppleServices artifact is not covered by either repository's license. It is
NOT vendored or redistributed with this source.

External artifact fetched from JJTech0130/nacserver commit
0a2aa2406542fb09c14a37db17ff14865b8aea29. Require 6222784 bytes,
SHA1 e1181ccad82e6629d52c6a006645ad87ee59bd13, and
SHA256 74c2a8fe826a478f14f6e17b3709a8b315e8c0e0e34e3fba6b9c4eee2f4516e9.

Real OABS input is supplied through private stdin only. No passwords, saved
profile, Apple account, iMessage sending, CloudKit upload or relay reservation
exists in this prototype. Network validation uses original Apple HTTPS names,
strict rustls certificates with the application's existing bundled roots, no
redirects and no automatic POST retries. A generated proof is not account
acceptance or release qualification.
