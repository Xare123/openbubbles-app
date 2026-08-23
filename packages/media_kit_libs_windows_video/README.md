# Audited Windows media-kit native bundle

This is a repo-local fork of `media_kit_libs_windows_video` 1.0.11. It keeps
the plugin name and registration ABI and replaces the hosted package through
the application path override.

Both architectures fail closed unless an ANGLE bundle built from the pinned
official Google ANGLE source is present and passes its manifest, SHA-256,
PE-machine, provenance, and license-inventory checks. The package never
downloads or accepts the unlicensed third-party ARM64 ANGLE bundle.

## Trust boundary

* ANGLE source: official `chromium.googlesource.com/angle/angle.git`, pinned.
* Build tools: official depot_tools, pinned.
* libmpv: pinned media-kit release assets, checked with committed SHA-256 values.
* Generated ANGLE DLLs: not committed. CI or a maintainer builds them from
  source and produces a manifest, license inventory, archive hash, and GitHub
  build-provenance attestation.
* Installed build evidence: sanitized manifests, hashes, notices, and ANGLE
  licenses under the runner's `data/native-media` directory. Absolute cache
  paths are never installed.
* Direct3D compiler/runtime: supplied by supported Windows versions, not copied
  from an unrelated prebuilt bundle.

Run the host-side checks:

```powershell
pwsh -NoProfile -File .\tool\test_native_media_scaffold.ps1
```

The application-level verifier and complete runner wrapper live under
`tooling/windows` at the repository root.

PowerShell 7 (`pwsh`) is required so native command arguments and captured
verification output retain exact boundaries when CMake invokes the resolver.

Build official ANGLE for the current Windows architecture:

```powershell
pwsh -NoProfile -File .\tool\build_official_angle.ps1 `
  -Architecture arm64 `
  -WorkRoot C:\Codex\OpenBubblesReview\build-cache\official-angle-arm64 `
  -OutputRoot .\windows\native\arm64\angle
```

See `docs/WINDOWS_ARM64_NATIVE_MEDIA.md` in the application repository for
release gates and integration instructions.

Public redistribution remains blocked until the exact libmpv/FFmpeg
transitive license inventory is complete. See `THIRD_PARTY_NOTICES.md`.
