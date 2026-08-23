---
type: implementation-guide
title: Windows ARM64 Native Media Supply Chain
description: Auditable x64 and ARM64 libmpv and ANGLE build, verification, CI, and release gates.
resource: packages/media_kit_libs_windows_video
tags:
  - windows
  - arm64
  - media-kit
  - supply-chain
  - provenance
timestamp: 2026-08-02
---

# Windows ARM64 native media supply chain

## Current status

The repo-local `media_kit_libs_windows_video` fork removes the remaining
architecture assumption from the native media package without accepting an
opaque ARM64 binary.

The scaffold is integrated through a repo-local dependency override. The
existing x64 input remains pinned, and CMake now selects either x64 or ARM64
explicitly and rejects every other architecture. Flutter's generated plugin
path installs the three runtime DLLs. The runner separately installs portable
provenance and the ANGLE license inventory under `data/native-media`.

The installed evidence deliberately excludes resolver and cache paths. CMake
fails before compilation if any required portable manifest, notice, or ANGLE
license directory is missing.

The package currently proves:

* x64 and ARM64 are selected explicitly from the CMake generator;
* libmpv assets are pinned by URL, source-build metadata, and SHA-256;
* ANGLE is built from pinned official Google source with pinned depot_tools;
* each accepted DLL is present in its manifest, has the committed hash, and
  has the expected PE machine;
* extra DLL or EXE files in the ANGLE bundle are rejected;
* generated ANGLE builds carry resolved source revisions, GN arguments,
  tool versions, runtime hashes, and a license-file inventory;
* installed evidence carries runtime hashes, source pins, the libmpv archive
  hash, the release gate, and sanitized ANGLE/license manifests without local
  absolute paths;
* a missing, altered, or wrong-architecture input stops CMake configuration.

No native binary or downloaded archive is committed.

## Dependency flow

```text
pinned Google ANGLE + pinned depot_tools
                 |
                 v
     build_official_angle.ps1
                 |
                 v
manifest + SHA-256 + PE machine + licenses + resolved revisions
                 |
                 v
       prepare_native_media.ps1  <--- pinned SHA-256 libmpv archive
                 |
                 v
     generated CMake paths + resolution record
                 |
                 v
      Flutter Windows runner bundles three DLLs
      libmpv-2.dll, libEGL.dll, libGLESv2.dll
```

Windows supplies the Direct3D compiler and Direct3D runtime. This fork does
not copy an untracked `d3dcompiler_47.dll` from an unrelated archive.

## Reviewed source pins

The machine-readable authority is
`packages/media_kit_libs_windows_video/provenance/native-dependencies.json`.

| Input | Pin |
| --- | --- |
| ANGLE | `cd05752a5137b5f068c11a7a3561e7441a34df75` |
| depot_tools | `e154c8eda5e63cbe85a765ae9d06e2b7af05139e` |
| libmpv builder | `8ddbe5472465950b87853789f7173f2eedc5586a` |
| mpv | `0f7858451817c5fd5ebdb74a807a7c997662c390` |
| libmpv release | `20241021`, separate committed SHA-256 per architecture |

A pin update is a supply-chain change. Review the source diff, licenses,
release assets, expected exports, and PE machines together.

## Local verification

Run the non-native tests on any Windows host:

```powershell
pwsh -NoProfile -File `
  .\packages\media_kit_libs_windows_video\tool\test_native_media_scaffold.ps1

pwsh -NoProfile -File `
  .\tooling\windows\verify_native_media_integration.ps1 `
  -RequireEphemeralSymlink
```

The tests create synthetic PE fixtures in a unique temporary directory and
prove the rejection paths for bad hashes, wrong architecture, missing files,
unlisted executables, evidence tampering, and path traversal. They also parse
every PowerShell file and confirm no binary or archive was committed.

Build ANGLE from official source:

```powershell
pwsh -NoProfile -File `
  .\packages\media_kit_libs_windows_video\tool\build_official_angle.ps1 `
  -Architecture arm64 `
  -WorkRoot C:\Codex\OpenBubblesReview\build-cache\angle-arm64 `
  -OutputRoot `
    .\packages\media_kit_libs_windows_video\windows\native\arm64\angle
```

Resolve the pinned libmpv archive and verify the combined inputs:

```powershell
pwsh -NoProfile -File `
  .\packages\media_kit_libs_windows_video\tool\prepare_native_media.ps1 `
  -Architecture arm64 `
  -AngleBundleRoot `
    .\packages\media_kit_libs_windows_video\windows\native\arm64\angle `
  -CacheRoot C:\Codex\OpenBubblesReview\build-cache\native-arm64 `
  -GeneratedCmakePath `
    C:\Codex\OpenBubblesReview\build-cache\native-arm64\native-media.cmake
```

Finally, run the DLL load and export smoke test on a native machine of the
same architecture:

```powershell
pwsh -NoProfile -File `
  .\packages\media_kit_libs_windows_video\tool\runtime_smoke.ps1 `
  -ResolutionPath `
    C:\Codex\OpenBubblesReview\build-cache\native-arm64\native-media-resolution.json
```

An x64 process is not accepted as ARM64 runtime evidence, even when Windows
emulation can launch it.

Build and verify the complete Flutter runner after the official ANGLE bundle
exists:

```powershell
pwsh -NoProfile -File `
  .\tooling\windows\build_verified_native_media_runner.ps1 `
  -Architecture arm64 `
  -AngleBundleRoot `
    C:\Codex\OpenBubblesReview\build-cache\official-angle-arm64 `
  -FlutterRoot C:\path\to\native-arm64-flutter `
  -Configuration release
```

The wrapper verifies that the Flutter/Dart toolchain matches the target,
builds without cleaning or overwriting app data, inventories every bundled PE
file, checks the three media-runtime hashes against installed evidence,
loads libmpv through the target-architecture Dart process, checks the evidence
and license layout, and runs the full three-DLL smoke test when the host
architecture matches.

The heavyweight source-build job in
`.github/workflows/windows-arm64-native-media.yml` is intentionally manual. It
builds official ANGLE and the complete runner on native x64 and ARM64 Windows
runners, rejects an emulated PowerShell process for the three-DLL load test,
and uploads only a short-lived, attested ANGLE engineering bundle. It does not
upload the application or libmpv while the redistribution gate is closed.
Ordinary pull requests still run the fast fail-closed scaffold and application
integration checks.

## Application integration

`pubspec.yaml` overrides `media_kit_libs_windows_video` to the local package,
while retaining the normal dependency declaration for upstream compatibility.
`pubspec.lock` must resolve version `1.0.11+openbubbles.1` from that relative
path. The integration verifier checks the pubspec, lockfile, Dart package
configuration, ephemeral Flutter symlink, generated plugin registration,
runner install rules, provenance gate, and absence of committed binaries.

The same override serves x64 and ARM64. There is no separate ARM-only Dart
package and no fallback to an x64 DLL on ARM64.

Before distributing a runner:

1. Build or consume CI-attested ANGLE bundles from the reviewed source pins.
2. Build both Windows runners with the matching native Flutter toolchain.
3. Confirm the runner PE machine and every bundled native DLL.
4. Confirm `data/native-media` contains the portable evidence, dependency
   manifest, third-party notice, libmpv extraction manifest, sanitized ANGLE
   manifest, and complete ANGLE license tree.
5. Run native DLL load/export smoke tests.
6. Exercise photo, audio, and video playback, seeking, full-screen navigation,
   attachment download, suspend/resume, and relaunch on both architectures.
7. Compare startup, first-frame latency, seek latency, memory, handles, and
   crash-free playback against the existing x64 release.

## Release gates

The following are still required before calling this production-ready:

- [ ] Official ANGLE x64 source build passes on a native x64 CI runner.
- [ ] Official ANGLE ARM64 cross-build and load test pass on a native Windows
      ARM64 CI runner.
- [ ] Flutter x64 and ARM64 runners compile and package the local fork.
- [ ] Playback and endurance testing pass on both architectures.
- [ ] Exact libmpv, FFmpeg, and linked-library source and license inventory is
      complete.
- [ ] Installer notices, LGPL source/relinkability obligations, and source
      offers are reviewed.
- [ ] Generated artifacts retain hashes, manifests, license inventory, and
      build provenance attestation.

The libmpv release metadata requests non-GPL builds, but flags alone do not
prove the final linked binary is redistributable under the intended terms.
Both reviewed archives contain eight entries and no license, notice, source
revision, or relinkability inventory. The pinned builder recipe also leaves
some transitive inputs on floating default branches or `main`, so the exact
linked source set cannot be reconstructed from the builder commit.
Public installer redistribution therefore remains blocked until the
transitive inventory is complete. Local engineering validation is not a
release approval.

## Failure handling

Do not delete or silently replace a cached file after a hash mismatch. Keep
the failed artifact for diagnosis, use a new clean cache path, and identify
whether the source pin, release asset, or local transport changed. Never fix a
failure by weakening a hash, PE, manifest, or source-origin check.
