# Third-party provenance and license boundary

## media-kit package scaffold

The registration shim and package structure derive from
`media_kit_libs_windows_video` 1.0.11 in the MIT-licensed
`media-kit/media-kit` project.

## Google ANGLE

ANGLE is built only from the official Google source repository at the commit
recorded in `provenance/native-dependencies.json`. ANGLE uses a BSD-style
license and includes separately licensed third-party components. The build
tool copies the top-level ANGLE license and inventories license, notice,
copying, and `README.chromium` files from the pinned source checkout into the
generated native bundle.

No prebuilt ANGLE DLL from an unofficial fork is accepted.

## mpv, FFmpeg, and static dependencies

The selected libmpv release was produced by the source build identified in
`provenance/native-dependencies.json`. That build requests mpv with
`-Dgpl=false` and FFmpeg with `--disable-gpl --disable-nonfree`, but mpv
explicitly warns that flags alone do not prove that a resulting binary is
LGPL-only. The release archives do not contain a complete transitive license
inventory.

The pinned builder recipe was also audited at commit
`8ddbe5472465950b87853789f7173f2eedc5586a`. The mpv target has 13 direct
recipe dependencies and FFmpeg has 32. The release archives contain eight
entries per architecture, with no license, notice, source-revision manifest,
or relinkable object inventory. Several source recipes are not pinned to full
commits, including FFmpeg, OpenSSL, and libpng at their then-current default
branches, plus explicit `main` references for libjpeg-turbo, shaderc, and the
Vulkan loader. The final transitive source revisions therefore cannot be
reconstructed from the archive or builder commit alone.

Therefore:

* local builds and native validation may use the pinned assets;
* a public installer must not be released until its exact libmpv/FFmpeg
  transitive source and license inventory has been reviewed and bundled;
* release artifacts must retain the generated ANGLE license inventory and
  supply all LGPL notices, relinkability/source obligations, and source offers
  required by the verified native dependency set.

This fail-closed release gate is intentional. A working DLL is not sufficient
evidence that redistribution is compliant.
