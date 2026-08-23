## 1.0.11+openbubbles.1

* Keep the upstream media-kit plugin registration and runtime contract.
* Resolve both x64 and ARM64 libmpv from one pinned, SHA-256 verified release.
* Require ANGLE to be built from the pinned official Google source checkout.
* Reject missing, unlisted, hash-mismatched, or wrong-architecture PE files.
* Generate source, toolchain, file-hash, and license provenance with each ANGLE bundle.
* Install portable runtime evidence and ANGLE license inventory without local paths.
* Add verified app-runner packaging and architecture-matched libmpv load checks.
* Record the unresolved libmpv transitive source and redistribution blockers.
* Add native x64 and ARM64 CI scaffolding without committing generated binaries.
