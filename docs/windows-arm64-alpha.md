---
type: implementation-status
title: Windows ARM64 Alpha
description: Media acceptance work, verified native archive architecture, and remaining blockers for an OpenBubbles Windows ARM64 alpha.
resource: OpenBubbles
tags:
  - windows
  - arm64
  - flutter
timestamp: 2026-07-28
---

# Windows ARM64 Alpha

This branch is an incremental native Windows ARM64 enablement track. A successful
unit test, dependency solve, or x64 build is not a native ARM64 artifact. Do not
publish an ARM64 package until the complete application builds and runs on a
Windows ARM64 device.

## Completed: transcript PDF font

The `printing` plugin was only used to obtain `PdfGoogleFonts.openSansRegular()`.
No native print API was called. The plugin and its PDFium runtime are now removed.

Transcript export still loads the same Open Sans Regular file from Google Fonts
through a small pure-Dart loader. A successful load is cached in memory. A failed
load falls back to PDF Helvetica and is retried on the next export, matching the
previous behavior.

Focused tests verify:

- the exact existing Open Sans URL;
- successful font caching;
- generation of a PDF with the downloaded TrueType font;
- Helvetica fallback and retry after a download failure.

## Blocker: Flutter Windows ARM64 target

This workstation is running Windows 11 on ARM64 hardware. Flutter stable 3.44.8
still reports its Windows device as `windows-x64`, and `flutter build windows -h`
does not expose a Windows `--target-platform` option. The stock Flutter SDK
therefore cannot produce a native Windows ARM64 application here.

The relevant Flutter work remains open:

- <https://github.com/flutter/flutter/issues/62597>
- <https://github.com/flutter/flutter/issues/129808>
- <https://github.com/flutter/flutter/issues/136417>

This is blocker zero. The `windows-arm64` native-library selections in this branch
are preparatory and cannot be reached by a stock Flutter 3.44.8 Windows build.
Removing plugin-level x64 libraries is still useful, but it does not create a
native Flutter engine, runner, or AOT application.

The application also does not currently resolve on Flutter 3.44.8. Running
`flutter pub get` fails because `build_verify` 3.x, Flutter's pinned test packages,
and Freezed 2.x require incompatible analyzer and test versions. Moving from the
verified Flutter 3.24 dependency set to a future ARM64-capable Flutter toolchain
therefore requires a reviewed generator and test-stack migration.

## Blocker: ObjectBox

The locked ObjectBox 4.0.3 Windows plugin downloads an x64-only native library.
ObjectBox 5.3.2 publishes `objectbox-windows-arm64.zip`, but the supported upgrade
is not a one-line native-library replacement:

- `objectbox`, `objectbox_flutter_libs`, and `objectbox_generator` must move
  together to 5.3.2;
- ObjectBox 5.1 and later enforce generated-code compatibility, so
  `lib/objectbox.g.dart` must be regenerated;
- the generator requires Dart 3.7 or later, analyzer 8.1 or later, build 4, and
  source_gen 4;
- the current `encrypt` 5.0.3 dependency requires PointyCastle 3, while the new
  ObjectBox generator requires PointyCastle 4;
- the current Freezed 2 generator requires build 2, while the new ObjectBox
  generator requires build 4.

A dry dependency solve only reached a compatible package set after modeling both
a PointyCastle override and a Freezed 3 migration. That would change approximately
43 dependencies and could affect the large generated Rust bridge Freezed output.
The PointyCastle override is not an acceptable implementation because it violates
`encrypt`'s declared compatibility range.

The next supported ObjectBox slice therefore needs:

1. replacement or upgrade of the two AES-CBC helpers that currently use
   `encrypt`, with known-answer and backward-compatibility tests;
2. a reviewed Freezed 3 migration that does not casually rewrite the Rust bridge
   bindings;
3. targeted regeneration of `lib/objectbox.g.dart`;
4. tests that open an existing ObjectBox 4 database and exercise chat, message,
   contact, attachment, and settings reads and writes;
5. Android regression coverage because these dependency changes are global.

Upstream evidence:

- <https://github.com/objectbox/objectbox-c/releases/tag/v5.3.2>
- <https://github.com/objectbox/objectbox-dart/releases/tag/v5.3.2>

ObjectBox cannot be disabled for an alpha. It is the primary persistent store for
messages, chats, contacts, attachments, handles, scheduled messages, and themes.

## Media acceptance checkpoint

Receiving and downloading images, audio, and video share the same attachment
download path. HTTP-backed desktop downloads previously invoked the attachment UI
callback before downloaded bytes were written to disk. Audio and video could
therefore try to open an empty file. Downloaded bytes are now persisted before
metadata inspection and before the callback receives the playable path.

The in-app media paths are:

| Requirement | Application path | Native dependency | Checkpoint state |
| --- | --- | --- | --- |
| Receive/download photos | Backend download, then local attachment file | None beyond the backend and filesystem | Ordering fixed and unit-tested |
| Display JPEG/PNG/GIF/WebP photos | `Image.memory` through the Flutter engine | A Flutter Windows ARM64 engine that stock Flutter does not provide | Code path audited, native app unavailable |
| Display HEIC photos | Desktop currently skips HEIC-to-PNG conversion | No working Windows converter is wired in | Not met |
| Receive/download audio | Shared attachment download path | None beyond the backend and filesystem | Ordering fixed and unit-tested |
| Play audio in the message | media_kit `Player` | ARM64 libmpv | Native archives pinned, build and hardware test pending |
| Receive/download video | Shared attachment download path | None beyond the backend and filesystem | Ordering fixed and unit-tested |
| Play video in the message or fullscreen | media_kit `VideoController` and `Video` | ARM64 libmpv and ARM64 ANGLE | Native archives pinned, build and hardware test pending |

HEIC remains a specific photo-format blocker. The current
`flutter_image_compress` conversion is intentionally skipped on desktop. The
recent `heic_native` Windows package bundles dependencies built only for
`x64-windows`. An architecture-neutral Windows Imaging Component alternative is
available in `platform_image_converter`, but its current release requires Flutter
3.38 and Dart 3.10, while this application does not yet resolve on Flutter 3.44.8.
It also depends on a HEIC decoder being present in Windows. Adding either package
now would hide, not solve, the toolchain boundary.

The pub.dev release remains `media_kit_libs_windows_video` 1.0.11 and does not
contain ARM64 support. Upstream main labels unreleased 1.0.12 as ARM64-capable,
but its shared ANGLE URL still resolves to x64 DLLs. The full-support work remains
unmerged:

- <https://github.com/media-kit/media-kit/issues/867>
- <https://github.com/media-kit/media-kit/pull/1381>
- <https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/pull/6>

This branch vendors the locked 1.0.10 package and changes only its Windows native
artifact selection:

- x64 retains the package's original libmpv and ANGLE archives;
- ARM64 uses media-kit's `mpv-dev-aarch64-20241021-git-0f78584.7z`, pinned at
  SHA-256
  `d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae`;
- ARM64 uses the ANGLE artifact attached to the still-unmerged support work,
  pinned at SHA-256
  `151a9a191af3711cc90e1c415e0affc60854ed089fb3defdc8bbf023f3806083`;
- CMake rejects targets other than `windows-x64` and `windows-arm64`;
- the build verifies every extracted DLL's PE machine type before linking.

The downloaded archives were independently inspected. `libmpv-2.dll` and all
seven ARM64 ANGLE runtime DLLs report PE machine type `0xAA64`. The unchanged x64
archives also pass the verifier. This is static artifact evidence, not proof that
audio or video renders correctly on a Windows ARM64 device. The ARM64 ANGLE
archive comes from a contributor fork attached to unmerged upstream work, so it
must be replaced by a reviewed upstream release when one becomes available.

## Verification boundary

The printing and media slices have focused Dart analysis and tests. Media tests
cover byte persistence before playback, exact archive pins, explicit target
selection, and positive and negative PE machine checks. Full-repository analysis
remains nonzero with 755 repository-level findings, including missing dependencies
in nested Cargokit and telephony example packages.

A local Windows build cannot start because this workstation does not have the
Visual Studio Desktop development with C++ toolchain installed. Even with that
workload, stock Flutter currently targets x64 on this ARM64 device. ObjectBox then
remains a separate application-startup blocker. No native Windows ARM64 artifact
has been produced or device-tested from this branch. The photo, audio, and video
acceptance criteria remain unverified until a complete native ARM64 build is
installed on Windows ARM64 hardware and tested with received attachments.
