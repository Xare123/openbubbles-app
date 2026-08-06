# Generated native inputs

No native executable, DLL, archive, or generated manifest belongs in Git.

`tool/build_official_angle.ps1` creates an architecture-specific `angle`
directory here for local integration. The committed provenance pins and
verification scripts determine whether CMake accepts it. CI builds the same
bundle from official source and publishes a short-lived artifact with build
attestation.

Expected local paths:

```text
native/
  arm64/angle/
  x64/angle/
```

The `.gitignore` intentionally blocks everything except this explanation.
