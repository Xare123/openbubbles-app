---
type: build_runbook
title: Bounded Windows native update lane
description: Parent-dispatched ARM64 native qualification without rebuilding the GUI or touching retained runtime data.
resource: openbubbles-app
tags: [windows, arm64, cloudkit, pilot, qualification]
timestamp: 2026-09-13
---

# Decision and current gate

Use the existing `windows-cloudkit-fast-loop.yml` on GitHub-hosted
`windows-11-arm`, selecting `artifact_mode=native-test-host`. No GCE, Windows VM
bootstrap, production signing, shared cache, or GUI/media rebuild is added.
The existing harness run [34642902373](https://github.com/Xare123/openbubbles-app/actions/runs/34642902373)
succeeded in 24m32s; this native-only variation has not been dispatched or timed.
It removes GUI compilation/assembly, not the necessary cold Rust dependency build.

`source_ref` intentionally has **no default**. Parent must first commit and review
the pending content-free diagnostics in `rust/src/cloud_sync_transient_bridge.rs`
along with the timestamp changes already present at `6f778c99eda7`.
That old SHA lacks the two new diagnostic tests and must not be dispatched for
this qualification. The supplied lowercase 40-character SHA must equal the
remote head of `agent/cloudkit-v2-update-seam`. Source/sidecar remain separate
exact checkouts. Preflight rejects absent diagnostics before toolchain setup.

# Qualification performed on the ephemeral host

- Clean source, initialized matching recursive submodules, existing launcher
  contracts, unchanged lockfiles, and pre/post source/binding SHA256 checks.
- Both existing PowerShell launcher contracts and the three focused Windows Dart
  test files, plus `objectbox_own_writer_precision_recovery_test.dart`.
- One job-local Cargo target directory for the debug ARM64 DLL and crate test
  executable. `cargo build --locked --lib`, then `cargo test --locked --lib
  --no-run`; no full Rust suite or live/account test is executed.
- Execute all seven `cloud_sync_message_update_compose::tests::` cases from the
  packaged test executable, including
  `authored_edit_milliseconds_survive_apple_seconds_roundtrip` and
  `original_timestamp_keeps_its_containing_millisecond`.
- Execute these two additional crate tests with `--exact`, without recompiling:
  `cloud_sync_transient_bridge::tests::message_required_masks_distinguish_absent_and_without_value`
  and `cloud_sync_transient_bridge::tests::message_extension_diagnostics_never_return_provider_values`.
  Missing names, zero tests, ignored cases, wrong counts, or failures reject output.
- Run all **51** encoder cases in `cloud_sync_local_send_encoder_test.dart`
  through FRB against the packaged DLL. This separately checks the actual cdylib;
  Rust unit tests exercise a distinct test executable, not the DLL itself.
- Every packaged PE must be ARM64. Load/unload the DLL. Preserve the exact
  ObjectBox 5.3.2 vendor DLL hash
  `9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5`.

Native bundle contains only `rust_lib_bluebubbles.dll`, `native-compose-tests.exe`
and `objectbox.dll`. It uses the exact source's Dart tests and the runner's native
Flutter/Dart SDK as its test host, not a rebuilt or redistributed Dart SDK.
Artifact retention remains three days and job timeout remains 90 minutes.
No running Windows job is automatically cancelled; Android run `34741584069`
and its workflow/concurrency are untouched.

# Signing, ABI, and assembly boundaries

`provenance.json` binds source/tree/submodules, sidecar/run/attempt, selected source
and generated FRB hashes, test-log hashes, artifact hashes, ARM64 types, and actual
Authenticode status. The archive has a SHA256 sidecar. Generated bindings are
not regenerated or borrowed. `build_identifier=null` in native mode is deliberate:
there is no newly compiled GUI/Dart assembly. `build_variant` is recorded but no
writer compile defines or live runtime gates are enabled in this mode.

**Signing gate:** this Windows cloud lane does not sign. The retained local
launcher requires its configured signing tool, an available unexpired private
certificate, valid expected-signer DLL signature, unchanged vendor ObjectBox
bytes, matching build receipt and actual acceptance by unchanged App Control.
Its `-SkipBuild` branch verifies, but does not import or sign, a new DLL;
`-BuildOnly` rebuilds. Neither is a native-only import/signing command.
No certificate store/private key was inspected and no signing operation occurred
in this task. Certificate availability and acceptance of the new bytes are untested.

Parent must retain the original unsigned archive/manifest, stage separately and
use the existing approved local signer only if authorized. Record unsigned-to-signed
hash lineage, signer verification, and rerun packaged-DLL tests/load under the
unchanged local policy before declaring local qualification. Do not re-sign
ObjectBox. A valid signature alone does not prove policy acceptance, per
[Microsoft's Smart App Control guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control).
Stop on a signer or policy failure; do not alter trust, secrets or policy.

Do not replace retained base `7f2569165`, relabel its native qualification, or write
a GUI assembly receipt pairing the old runner with a new source identifier.
Any later test-host launch must bind the reviewed Dart source and the actual
signed DLL hash separately. This patch issues no local launch/assembly receipt
and makes no live CloudKit claim. `artifact_mode=harness` retains the existing
GUI path; it is not the new nine-case native regression qualification.

# Parent review and dispatch

Only the Windows workflow, its existing `build_and_smoke.ps1`, and this document
belong to this patch. Preserve the pilot's pre-existing deleted
`.dart_tool/build/fcd1995bc647fb959e82ea360c6c2c9a/asset_graph.json`; do not stage it.
Review/commit/push only those three paths, then verify the remote pilot head is
the reviewed sidecar commit. Nothing was committed, pushed or triggered here.

After the final source commit is on the trusted branch, substitute its reviewed
full SHA and dispatch:

```powershell
gh workflow run windows-cloudkit-fast-loop.yml --repo Xare123/openbubbles-app --ref agent/gce-runner-pilot -f "source_ref=<FINAL_REVIEWED_40_HEX_SHA>" -f artifact_mode=native-test-host -f build_variant=read-only
```

Preparation checks: PowerShell AST parsing, inline workflow PowerShell parsing,
actionlint 1.7.12, `git diff --check`, and synthetic native-result/preflight
contracts. No native/Flutter build, artifact download, cache population, signing,
or account/profile operation ran locally. Actual source preflight rejects the
dirty worktree and its broken nested `clearadi` Git pointer; synthetic clean-Git
preflight is a contract test, not evidence that this checkout is qualified.
