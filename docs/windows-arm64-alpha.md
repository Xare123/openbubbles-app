---
type: implementation-status
title: Windows ARM64 Alpha
description: Verified printing removal and remaining native dependency blockers for an OpenBubbles Windows ARM64 alpha.
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

## Blocker: media_kit

Current `media_kit_libs_windows_video` selects an ARM64 libmpv on its development
branch, but still consumes an x64 ANGLE archive. The package cannot provide native
ARM64 playback until both libmpv and ANGLE are ARM64.

The full-support work remains unmerged:

- <https://github.com/media-kit/media-kit/issues/867>
- <https://github.com/media-kit/media-kit/pull/1381>
- <https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/pull/6>

For the first alpha, use an ARM64-specific native-library stub or package override
that leaves `MEDIA_KIT_LIBS_AVAILABLE` false. Do not relabel an x64 DLL or remove
architecture checks. The ARM64 UI must then avoid initializing media_kit and offer
the existing external-file open path for audio and video attachments.

This alpha may conditionally disable:

- in-app audio playback;
- in-app and full-screen video playback;
- embedded video;
- send and receive sounds;
- custom sound previews.

Core messaging, attachment transfer and saving, image display, authentication, and
sync do not depend on in-app media playback.

## Verification boundary

The printing slice has focused Dart analysis and tests. Full-repository analysis
remains nonzero with 755 repository-level findings, including missing dependencies
in nested Cargokit and telephony example packages; the changed Dart files have no
analyzer findings.

A local Windows build was attempted but could not start because this workstation
does not have the Visual Studio Desktop development with C++ toolchain installed.
No native Windows ARM64 artifact has been produced or device-tested from this
branch.
