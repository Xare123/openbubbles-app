---
type: decision_record
title: ObjectBox Dependency Posture
description: What OpenBubbles actually depends on from ObjectBox, which licence covers which part, and the two conditions that would force this decision to be revisited.
resource: openbubbles-app
tags: [objectbox, licensing, dependencies, redistribution, decision]
timestamp: 2026-08-06
---

# Decision: ObjectBox dependency posture

## Status

Accepted, with two named review triggers. Recorded now because Cloud Sync V2 is
about to make ObjectBox the durability boundary for reconciled message data, and
a storage engine is expensive to change once a schema is frozen.

## What we actually depend on

Verified in the tree on 2026-08-06 rather than assumed:

| Component | Version | How it is used |
| --- | --- | --- |
| `objectbox` (Dart) | 5.3.2 | Official Dart binding, used throughout `lib/database` |
| `objectbox_flutter_libs` | 5.3.2 | Ships the native library into the app bundle |
| `objectbox_generator` | 5.3.2 | Build-time code generation |
| ObjectBox C native library | 5.3.2 | Loaded at runtime on Android and Windows |

**There is no Rust dependency on ObjectBox.** `rust/Cargo.toml` and
`rustpush/Cargo.toml` do not reference it, and the only occurrences in
`rust/src` are comments describing the Dart-side transaction boundary that
native work must not cross.

This matters because published commentary warns about the community Rust
binding `vaind/objectbox-rust`, which its owner archived on 2024-07-24. **That
warning does not apply here.** We use the official Dart binding, which is
maintained. Any future proposal to reach ObjectBox from Rust would be adopting
that archived-binding risk for the first time, and should be treated as a new
decision rather than an extension of this one.

## The licence split

The bindings are Apache-2.0. The **native library is proprietary** under the
ObjectBox Binary Licence, and ObjectBox's own FAQ describes the current terms as
temporary. So the app ships a proprietary binary inside an Apache-2.0
application.

This is not a new condition introduced by Cloud Sync V2. The app already
depends on ObjectBox for its entire local database. What Cloud Sync V2 changes
is the consequence of a future forced migration: reconciled CloudKit state,
checkpoints, journals, and quarantine records would all have to move with it.

## Decision

Continue with ObjectBox for Cloud Sync V2, for three reasons.

**Its durability contract is the one this design needs.** ObjectBox commits
synchronously to physical storage and waits for filesystem confirmation, with
MVCC and serialised writers. The exactly-once local projection this engine
depends on requires writing the checkpoint and the projected rows in a single
durable transaction, and that is available today.

**Switching now would be the more dangerous change.** The alternative is
migrating the app's whole local database, not just the sync tables, while the
CloudKit work is mid-flight and unvalidated against a live account.

**The licence exposure is bounded and already present.** A proprietary runtime
library inside a distributed application is a redistribution question, and
redistribution is already blocked on a separate and larger licensing item: the
libmpv and FFmpeg transitive inventory for the Windows media stack.

## Consequences

- The pending redistribution review must cover the ObjectBox Binary Licence
  explicitly, alongside libmpv and FFmpeg. It is currently unlisted.
- The repository has a `LICENSE` but no `NOTICE` or third-party notices file.
  One is needed before public distribution, and ObjectBox belongs in it.
- Schema changes stay behind the freeze the Cloud Sync V2 documents already
  require. A storage engine we cannot fork makes an unplanned migration more
  expensive, not less.

## Review triggers

Revisit this decision if either occurs:

1. **ObjectBox changes the binary licence terms** in a way that restricts
   redistribution in a shipped application. Their FAQ already signals the
   current terms are provisional.
2. **A proposal appears to access ObjectBox from Rust.** That would mean either
   depending on an archived community binding or writing and owning an FFI
   layer against a proprietary library, and neither is covered by this record.

## What was considered and rejected

**Moving the sync tables to SQLite while leaving the app on ObjectBox.** Two
storage engines with two durability models, and the single-transaction
checkpoint guarantee would have to span both. The guarantee is the point, so
splitting it is self-defeating.

**Migrating the whole app now.** Correct only if the licence forced it, which it
does not yet. Doing it during unvalidated CloudKit work would confound two large
risks at once.
