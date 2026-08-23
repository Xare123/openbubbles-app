---
type: build_runbook
title: OpenBubbles Windows ARM64 Host Build Environment
description: Verified toolchain layout and the non-obvious constraints for building the Rust bridge and running the test suites for Android, Windows ARM64, and Windows x64 from one Windows-on-ARM host.
resource: openbubbles-app
tags: [windows, arm64, x64, android, rust, objectbox, openssl, toolchain, testing]
timestamp: 2026-08-06
---

# OpenBubbles Windows ARM64 host build environment

## Decision

Drive all three architecture targets from one Windows-on-ARM host. Nothing here
changes shipped code; it records the host constraints that otherwise present as
unrelated failures (60+ Dart test errors, a missing proc-macro crate, an
OpenSSL Makefile that never appears).

Every item below was verified on this host on 2026-08-06. Where a constraint is
a host-policy interaction rather than a repository problem, that is stated.

## Toolchain layout

| Component | Path | Notes |
| --- | --- | --- |
| Flutter ARM64 | `C:\Codex\Toolchains\flutter-3.44.8-arm64` | Native host; Dart 3.12.2 |
| Flutter x64 | `C:\Codex\Toolchains\flutter-3.44.8` | Runs emulated |
| Cargo/rustup | `C:\Codex\Toolchains\cargo`, `C:\Codex\Toolchains\rustup` | Set `CARGO_HOME` and `RUSTUP_HOME` |
| MSVC | Visual Studio Build Tools 2022 17.14, MSVC 14.44.35207 | `Hostarm64` tools present |
| clang | `C:\Codex\Toolchains\LLVM-22.1.8-woa64-portable\bin` | Required by `ring`; see below |
| Android SDK/NDK | `C:\Codex\Toolchains\AndroidSdk`, NDK `26.1.10909125` | Host prebuilt is `windows-x86_64` |
| GNU make | `C:\Codex\Toolchains\android-build-bin\make.exe` | Needs Strawberry's mingw runtime DLLs on PATH |
| Perl modules | `C:\Codex\Toolchains\git-perl-extra` | Point `PERL5LIB` here |
| ObjectBox ARM64 | `C:\Codex\Toolchains\objectbox-windows-arm64-v5.3.2\lib` | Matches the pinned 5.3.2 |

Installed Rust targets: `aarch64-pc-windows-msvc`, `x86_64-pc-windows-msvc`,
`aarch64-linux-android`.

## Constraint: the Dart test host needs an architecture- and version-matched ObjectBox

`pubspec.yaml` pins the `objectbox` trio to 5.3.2. The Dart test host loads
`objectbox.dll` from `PATH`, so that library must match both the pinned version
and the architecture of the Flutter SDK's own `dart.exe`.

A stale 4.0.2 `objectbox.dll` still sits in this repository's
`build\windows\x64\runner\Release`. Selecting it fails 63 Cloud Sync tests with
`LateInitializationError: Local 'objectBox' has not been initialized`, which
names neither the version nor the library. `tooling\cloud_sync\verify_foundation.ps1`
now derives the host architecture from `dart.exe`, reads the pinned version from
`pubspec.yaml`, inspects each candidate library's PE machine type and embedded
version banner, and refuses to run on a mismatch.

Verified libraries:

- ARM64 host: `C:\Codex\Toolchains\objectbox-windows-arm64-v5.3.2\lib`
- x64 host: `..\cloudsync_objectbox5_sandbox\build\windows\x64\runner\Release`

## Constraint: `ring` needs clang for the ARM64 MSVC target

`ring` 0.17.8 assembles GNU-syntax `.S` sources for
`aarch64-pc-windows-msvc`. `cl.exe` cannot consume them, so `clang` must be
reachable or the build fails with `failed to find tool "clang"`. Put the
portable LLVM `bin` directory after the MSVC directories so `cl`, `link`, and
`lib` still resolve to Visual Studio.

Remove `CC`, `CXX`, `AR`, `LD`, `RANLIB`, `CFLAGS`, and `CXXFLAGS` before
building an MSVC target. The `cc` crate honours them ahead of `cl.exe`, and a
stale GNU value either fails compiler detection or produces the wrong machine
type. Drop Strawberry's `c\bin` from `PATH` for the same reason, but keep
`C:\Strawberry\perl\bin` because the OpenSSL build needs perl.

## Constraint: `ring` 0.16.20 cannot target ARM64 and was reachable only through a dead dependency

`icloud_auth` declared `rustls = "0.20.7"` and `rustls-pemfile = "1.0.1"` while
using neither; its `reqwest` uses `default-tls`, and `rustpush` itself uses
rustls 0.23.38. Those two unused declarations pulled `rustls` 0.20.9 and with it
`ring` 0.16.20, which predates ARM64 Windows support and fails in `build.rs`.

Removing them drops `ring` 0.16.20, `rustls` 0.20.9, `spin` 0.5.2,
`untrusted` 0.7.1, and `webpki` 0.22.4 and changes no other resolved package.
This edit lands in the `rustpush` submodule.

## Constraint: vendored OpenSSL for Android needs a Unix-path perl, GNU make, and forward-slash compiler paths

`openssl` is a vendored dependency, so the Android build compiles OpenSSL from
source. Three separate host requirements follow, each of which fails with a
different and unrelated-looking message:

1. **Configure needs Unix-style paths.** Strawberry's MSWin32 perl reports
   `This perl implementation doesn't produce Unix like paths` and no Makefile
   appears. Git's msys perl (`C:\Program Files\Git\usr\bin\perl.exe`) must win
   the `perl` lookup.
2. **Configure needs modules Git's minimal perl omits.** Point `PERL5LIB` at
   `C:\Codex\Toolchains\git-perl-extra`. `tooling\android\build_verified_alpha.ps1`
   converts that to a `//localhost/C$/...` UNC path first, because OpenSSL runs
   perl through a POSIX shell where the drive-letter colon would otherwise be
   read as a `PERL5LIB` separator.
3. **The generated Makefile routes `CC` through msys `sh`, which eats
   backslashes.** A Windows-style compiler path arrives as
   `C:CodexToolchains...clang.exe: command not found`. Set
   `CC_aarch64_linux_android`, `AR_aarch64_linux_android`, and
   `RANLIB_aarch64_linux_android` with forward slashes. Configure already
   supplies `--target=aarch64-linux-android24`, so plain `clang.exe` is
   correct; the `.cmd` wrapper is still right for the Cargo linker.

`make` must also be on `PATH`, and `android-build-bin\make.exe` links
`libintl-8.dll` from Strawberry's `c\bin`. Removing Strawberry entirely to force
msys perl makes `make` fail with `0xc0000135` (DLL not found). Order `PATH` so
Git's `usr\bin` precedes Strawberry rather than removing Strawberry.

## Host policy: Smart App Control blocks `cargo test` on the main crate

This host runs Smart App Control in enforcement mode
(`HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy` →
`VerifiedAndReputablePolicyState = 1`). It intermittently blocks freshly built,
unsigned binaries with `An Application Control policy has blocked this file.
(os error 4551)`.

This affects `cargo test` on `rust_lib_bluebubbles`, which builds
dev-dependencies and their proc-macro DLLs. A blocked proc-macro surfaces as the
misleading `error[E0463]: can't find crate for 'rinja_derive'` even though that
crate compiles and its DLL exists. Retrying gets different binaries through, so
the failure moves rather than clearing.

What this does and does not block:

- **Not affected:** `cargo build --release`, which needs no dev-dependencies.
  All three release libraries build cleanly.
- **Not affected:** the standalone `cloud_sync_protector_harness`, whose 39
  tests run on ARM64.
- **Affected:** `cargo test` on the main crate.

Do not disable Smart App Control to work around this; on Windows 11 it cannot be
re-enabled without reinstalling. Run the main crate's Rust tests on a host or CI
runner without the policy. This is the open item that the live-validation
document records as "run the x64 harness without triggering Windows Application
Control".

## Defect: CargoKit silently skipped the entire Rust build on Flutter 3.44.8

`rust_builder/cargokit/gradle/plugin.gradle` located Flutter's Gradle plugin by
comparing the fully qualified class name to `"FlutterPlugin"`. That matched while
Flutter's plugin was Groovy in the default package. Flutter 3.44.8 ships the
Kotlin rewrite as `com.flutter.gradle.FlutterPlugin`, so the comparison failed
and CargoKit printed `Flutter plugin not found, CargoKit plugin will not be
applied.` and returned.

The consequence is silent and serious: the Android build completes and reports
success while packaging no `librust_lib_bluebubbles.so` at all. A split ARM64
profile APK built before the fix contained `libflutter.so` and `libapp.so` but
no Rust bridge; `tooling\android\build_verified_alpha.ps1` is what caught it.
Its ABI assertion is the only thing standing between this failure mode and a
package that installs and then cannot work.

The fix accepts either the bare class name or any package-qualified
`.FlutterPlugin`. After it, the skip message no longer appears under
`flutter build`. Note that invoking a CargoKit Gradle task directly, rather than
through `flutter build`, legitimately prints the same message because the
Flutter plugin is not applied in that invocation; that is not a regression and
is not a valid way to test this.

`build_verified_alpha.ps1` also required `lib/arm64-v8a/libapp.so` for every
mode even though a debug package carries interpreted Dart in its asset bundle
instead. It now requires that entry only for profile and release.

### Host limit: memory, not correctness

Re-verifying a packaged APK after the CargoKit fix did not complete on this
host. With the fix in place Gradle additionally drives the Android cargo build,
including compiling OpenSSL from source in CargoKit's own target directory. This
machine has 15.6 GB of RAM, `android/gradle.properties` requests
`-Xmx6400M`, and with a browser and editor resident the daemon settles at
roughly 2.6 GB while free memory falls to about 1.4 GB. It then burns CPU
without writing build output, which is memory thrash rather than progress.

Before rerunning, free memory first and stop stale daemons
(`android\gradlew.bat --stop`), or lower `org.gradle.jvmargs`, or build on a
larger machine or CI runner:

```powershell
pwsh -NoProfile -File .\tooling\android\build_verified_alpha.ps1 -Mode profile -SplitPerAbi `
  -AndroidSdkRoot C:\Codex\Toolchains\AndroidSdk `
  -CargoHome C:\Codex\Toolchains\cargo -RustupHome C:\Codex\Toolchains\rustup `
  -ProtocPath C:\Codex\Toolchains\protoc-35.1-win64\bin\protoc.exe `
  -PerlExecutable "C:\Program Files\Git\usr\bin\perl.exe" `
  -PerlModuleRoot C:\Codex\Toolchains\git-perl-extra `
  -MakeExecutable C:\Codex\Toolchains\android-build-bin\make.exe
```

## Verified state on 2026-08-06

| Check | Result |
| --- | --- |
| Dart suite, ARM64 host | 388 tests pass |
| Cloud Sync Dart suite, x64 host | 294 tests pass |
| Cloud Sync focused analyzer | clean |
| `cloud_sync_protector_harness`, ARM64 | 39 tests pass |
| Kotlin unit tests, Alpha variant | 12 tests pass |
| `cargo check --locked --all-targets`, ARM64 | clean |
| Release library, `aarch64-pc-windows-msvc` | PE ARM64 |
| Release library, `x86_64-pc-windows-msvc` | PE x64 |
| Release library, `aarch64-linux-android` | ELF64 AArch64 |
| `cargo test`, main crate | blocked by host policy above |

No live CloudKit access, account mutation, or message send was performed.

## Deliberate gate: the Windows desktop build needs an ANGLE bundle built from source

`flutter build windows` fails at CMake configure on this host:

```text
Cannot find path '...\media_kit_libs_windows_video\windows\native\arm64\angle'
because it does not exist.
```

This is the repo-local `media_kit_libs_windows_video` fork failing closed on
purpose. Its README states that both architectures fail closed unless an ANGLE
bundle built from pinned official Google ANGLE source is present and passes its
manifest, SHA-256, PE-machine, provenance, and license-inventory checks, and
that the package never accepts the unlicensed third-party ARM64 ANGLE bundle.

`..\scratch\arm64-media-provenance` holds bare `angle-x64.7z`,
`libmpv-arm64.7z`, and `libmpv-x64.7z` with no manifest, license inventory, or
attestation beside them. **Do not stage those to satisfy the gate.** Produce a
bundle instead:

```powershell
pwsh -NoProfile -File .\packages\media_kit_libs_windows_video\tool\build_official_angle.ps1 -Architecture arm64 -WorkRoot C:\Codex\OpenBubblesReview\build-cache\official-angle-arm64 -OutputRoot .\packages\media_kit_libs_windows_video\windows\native\arm64\angle
```

That fetches pinned depot_tools and ANGLE source and runs a Chromium-scale
build, so treat it as a maintainer or CI step. Note also that
`provenance/native-dependencies.json` records libmpv redistribution as
`blocked_pending_transitive_license_inventory`, so this gate is not the only
thing standing between the current tree and a public Windows release.

This gate is unrelated to Cloud Sync. The CloudKit-relevant Windows artifact,
the Rust bridge, builds and verifies for both architectures.

## Not covered here

Android release signing needs a keystore and `android/key.properties`, neither
of which is present. The `alpha`, `beta`, and `prod` flavours use
`signingConfigs.release`, so only debug-signed packages can be produced on this
host.
