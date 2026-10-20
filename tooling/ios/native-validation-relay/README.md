# Private native iPhone relay qualification

This is an independently implemented interoperability client for the existing
Beeper provider protocol, not a public release. It is not yet built, installed
or live-qualified. Do not substitute an account-signing proof for device NAC.

Source lineage: frozen Muse stage under project scratch/native-relay-stage;
parent reviewed all21 source files. Twenty hashes matched its handoff. Its
Info.plist hash was mistyped in that manifest; the full plist was independently
reviewed and actual baseline hash was
d9b1b4cb31ffc3316f339b4d96eac09457b771a3dcf054a2ba4299ebbadc3d2c.
No frozen evidence was overwritten. Import normalized new-source line endings.

The two native generators reuse this project's previously tested Signing5 and
Qualifier2 implementations, not unlicensed third-party implementations. See
nac/PROVENANCE.md for the independently authored native NAC adapter and the
functional IPC facts used to generate its client with the Apple SDK.

The five review-2 core files were imported after exact normalized baseline
checks. Parent review then replaced unsafe cross-thread completion buffers with
one serial result-transfer queue. Replies remain exact-task/epoch bound. There
is one native operation chain, busy requests fail without queueing, and a native
deadline quarantines generation until helper restart. This is not a claim that
private APIs are interruptible. Late mutable account proofs are wiped. Every
version response retains static ob_auth_capabilities=native-account-v1, even on
failure; the total bundle budget is45000ms. The Rust client never silently
selects legacy authentication when transient native proof generation fails.

tests/run-foundation-tests.sh executes production Dispatcher/Connection/Bundle
with synthetic generators/tasks, plus isolated registration-store fixtures.
These are real Foundation execution tests once run on Mac, not an iOS/private-
framework/account qualification. The original frozen Muse source and pending
independent review remain preserved in project scratch.

Parent additions include a native device-validation adapter, validated atomic
registration tuple storage, and app-local keep-awake while connected. Background
entry disconnects; foreground return resumes the existing registration. No
system lock/privacy settings are changed and no account credentials are accepted.

Required next gates: real Mac SDK/MIG compile and Foundation tests, ARM64 package
and signature checks, private TrollStore install, actual version/native-bundle
and genuine NAC exchanges, normal app-provider account/delegate authentication,
then registration and persisted restart. CloudKit remains a later independent
gate. No proof values belong in source, artifacts, logs or saved client Versions.
