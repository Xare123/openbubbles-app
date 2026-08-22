---
type: provenance_ledger
title: OpenBubbles Cloud Sync V2 Provenance Ledger
description: Per-idea record of borrowed protocol facts and patterns, their source licence, whether code or only a concept was taken, and the file that implements each one.
resource: openbubbles-app
tags: [licensing, provenance, cloudkit, sspl, apache-2.0, compliance]
timestamp: 2026-08-22
---

# Cloud Sync V2 provenance ledger

## Why this exists

[Open-source pattern review](CLOUD_SYNC_V2_OPEN_SOURCE_REVIEW.md) states the
rule: for every borrowed implementation idea, record the project, exact source
URL, licence, whether code or only a concept was used, and the OpenBubbles file
that implements it. That document holds a per-project table. This one holds the
per-idea entries the rule actually asks for, and it is a release gate.

## The distinction this ledger turns on

A field name, a wire type number, a zone name, and the grammar of an identifier
are **facts about Apple's protocol**. Observing that Apple encodes a reaction
parent as `p:<part>/<guid>` is a fact, and facts are not copyrightable.

A struct definition, a derive macro, a `.proto` file, and a function body are
**expression**. They carry the licence of the project that wrote them.

Every entry below records which of the two was taken. Where the source is
SSPL-1.0 or GPL-family, only facts were used and the implementation was written
independently against them.

## The rustpush boundary, stated precisely

`rustpush` is **SSPL-1.0** and ships an exception granting an MIT-style licence
to OpenBubbles itself, not to third parties. The application already depends on
it as a submodule and links it, which is a deliberate existing architecture
decision, not something this work introduced.

What this ledger governs is narrower: **no rustpush source may be copied into
the Apache-2.0 Dart or `rust/src` layer.** Protocol facts learned by reading it
may be, and each one is listed below.

## Ledger

### Apple protocol facts

| # | Fact taken | Source | Licence | Code or concept | Implemented in |
| --- | --- | --- | --- | --- | --- |
| 1 | Reaction parent is encoded `p:<part>/<guid>`, and as a **bare GUID with no prefix** when no part is targeted | [rustpush `messages.rs`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/messages.rs) `amk` construction | SSPL-1.0 | Fact only | `rust/src/cloud_sync_canonical_dto.rs` (`parse_associated_parent`), `lib/services/rustpush/cloud_sync/cloud_associated_message_parent_reference.dart` |
| 2 | Reply parent is `r:<part>:<guid>`, colon-separated, an independent grammar from the reaction form | same, `tg` field | SSPL-1.0 | Fact only | `rust/src/cloud_sync_canonical_dto.rs` (`parse_reply_parent`) |
| 3 | Owned attachment identity is `at_<part>_<guid>`, and the GUID may itself contain underscores | same, `transfer_guid` | SSPL-1.0 | Fact only | `lib/utils/attachment_guid_utils.dart`, `rust/src/cloud_sync_canonical_dto.rs` (`parse_owned_attachment_guid`) |
| 4 | `bp` and `bpdi` are IDS wire-payload keys, **not** CloudKit record fields; the record equivalent is `MessageProto.payloadData` | [rustpush `rawmessages.rs`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/rawmessages.rs) vs `cloud_messages.rs` | SSPL-1.0 | Fact only | No code change. Recorded because it prevented inventing presence rules for fields that do not exist on these records. |
| 5 | `filt`, `sqry`, `ste` are `i64`, not booleans | [rustpush `cloud_messages.rs`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs) | SSPL-1.0 | Fact only | Already correct before this review; verified, not changed |
| 6 | `ust`, `hbr`, `oui`, `osn`, `euh`, `bcg`, `ams`/`ampt`/`amc`/`amb`/`amd` live inside a `MessageSummaryInfo` plist at protobuf field 7, gzipped; `bcg` sits inside a `MessageEdit`; `ec` and `otr` are keyed by decimal-string part | same | SSPL-1.0 | Fact only | Already correct before this review; verified, not changed |
| 7 | Apple's summary plist omits empty collections rather than sending them, so there is no explicit-clear state in that plist | same, serde `skip_serializing_if` on collections | SSPL-1.0 | Fact only | `rust/src/cloud_sync_canonical_converter.rs` (empty `ec`/`rp` now reads as absent rather than a clear instruction) |
| 8 | Zone-to-record-type mapping for the three Manatee zones | same | SSPL-1.0 | Fact only | `rust/src/cloud_sync_native_fetch.rs` |
| 9 | `messageUpdateZone` and `recoverableMessageDeleteZone` exist and are not currently read | same, zone reset list | SSPL-1.0 | Fact only | Not implemented. Recorded as an open scope question in [path to production](CLOUD_SYNC_V2_PATH_TO_PRODUCTION.md). |
| 10 | PCS GCM additional authenticated data is scoped `zone-record-field`, so a wrong field name fails authentication rather than yielding wrong plaintext | [rustpush `pcs.rs`](https://github.com/OpenBubbles/rustpush/blob/master/src/icloud/pcs.rs) | SSPL-1.0 | Fact only | Not code. Informs live validation: field names are self-verifying against real data. |

### Wire-format facts

| # | Fact taken | Source | Licence | Code or concept | Implemented in |
| --- | --- | --- | --- | --- | --- |
| 11 | CloudKit's field value type enum includes `EMPTY_LIST = 9`, a distinct representation of "present but empty" | `rustpush/cloudkit-proto/src/cloudkit.proto`, vendored in-tree | SSPL-1.0 | Fact only | `rust/src/cloud_sync_canonical_converter.rs` records the observation as evidence; no decision reads it |
| 12 | Error codes `RESET_NEEDED = 17` and `FULL_RESET_NEEDED = 40` | same | SSPL-1.0 | Fact only | Not implemented. Feeds the rebootstrap requirement in the production-readiness notes. |

### Engineering patterns

| # | Pattern taken | Source | Licence | Code or concept | Implemented in |
| --- | --- | --- | --- | --- | --- |
| 13 | Windows provides no directory-sync primitive; a no-op is the correct implementation and durability rests on startup reconciliation | [Restic](https://github.com/restic/restic) `local_windows.go` | BSD-2-Clause | Concept only | `rust/src/cloud_sync_native_fetch.rs` (`sync_directory` on Windows) |
| 14 | Part-index semantics, and that `bp:` is a real GUID prefix for bubble/tapback messages in the local database schema | [imessage-exporter](https://github.com/ReagentX/imessage-exporter) `variants.rs` doc comments | **GPL-3.0** | Concept only, no code | Informed entry 4. No GPL code is present in this repository. |
| 15 | Exactly-once local projection is achieved by writing the cursor in the same transaction as the projected rows, with a sequence-guarded upsert, rather than a dedup table | CouchDB replication protocol (Apache-2.0), Replicache server-pull docs, Debezium docs | Apache-2.0 and documentation | Concept only | Not yet implemented. Recorded as a binding constraint for semantic apply. |
| 16 | Contiguous-prefix cursor with a separate high watermark, and a bounded gap set that stops admission rather than evicting | NATS JetStream docs, Apache Pulsar PIP-81, PostgreSQL replication slots | Apache-2.0 and documentation | Concept only | Partially present as the existing contiguous checkpoint. The bounded retry queue and stall timer are not implemented. |
| 17 | Server-authoritative field classification instead of CRDTs for a single-writer projection | [Figma multiplayer writeup](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/) | Article | Concept only | Not yet implemented. Recorded as a Phase 2 prerequisite. |
| 18 | One fsynced contiguous-prefix integer per blob, truncated to on startup | Restic, Syncthing (MPL-2.0) design docs | BSD-2-Clause, MPL-2.0 | Concept only, no code from either | Attachment materialisation design; not yet implemented |
| 19 | Two-level fault injection where a call site is armed per run and then fires probabilistically | FoundationDB `BUGGIFY` | Apache-2.0 | Concept only | Not yet implemented |
| 20 | Incrementing fail-on-Nth-operation loop for crash testing, run in both fail-once and fail-persistently modes | [SQLite testing](https://www.sqlite.org/testing.html) | Public domain | Concept only | Not yet implemented |

### Apple iOS 26 implementation evidence

These entries record protocol and orchestration facts observed in a fixed-commit
decompilation of Apple's iOS 26.1 Messages implementation. The mirror does not
grant a source-code licence. No function body, control flow, symbol layout, or
other expression from it is copied into OpenBubbles. The facts are corroborated
where possible with Apple's public CloudKit documentation.

| # | Fact taken | Source | Licence | Code or concept | Implemented in |
| --- | --- | --- | --- | --- | --- |
| 21 | Chat record saves use an atomic modify-records operation, while message and attachment saves use non-atomic operations with per-record outcomes | [iOS 26.1 chat factory](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore/IMDCKChatSyncCKOperationFactory.mm), [message factory](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore/IMDCKMessageSyncCKOperationFactory.mm), and [attachment factory](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore/IMDCKAttachmentSyncCKOperationFactory.mm); [Apple `isAtomic`](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/isatomic) | Binary-derived fact; Apple documentation | Fact only | Not implemented. Binding input to the Stage 4 batch and acknowledgement design. |
| 22 | Chat and message factories explicitly select raw save policy `1`, which SDK declarations identify as changed-keys. The attachment factory does not override the operation default; Apple's documented default is if-server-record-unchanged | Same fixed factory sources; [Apple `savePolicy`](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy) | Binary-derived fact; Apple documentation | Fact only | Not implemented. Stage 4 must represent save policy explicitly and test conflict behavior rather than inheriting one generic policy. |
| 23 | Apple's chat importer deliberately drops incoming chat-record deletions because IDS handles them in real time | [iOS 26.1 `IMDCKChatSyncController`](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore/IMDCKChatSyncController.mm) | Binary-derived fact; no source licence | Fact only | The read-only canary already quarantines all tombstones. Stage 4 must keep chat tombstones from deleting local conversations merely because CloudKit reported a deletion. |
| 24 | Chat, message, and attachment record deletes use non-atomic modify operations; the controllers deduplicate pending record IDs before scheduling deletion | Same fixed factories and controllers | Binary-derived fact; no source licence | Fact only | Not implemented. Stage 4 delete identity, deduplication, partial-result acknowledgement, and retry tests required. |
| 25 | The update-zone importer treats record deletion as unsupported and routes UT1/UT2 save conflicts through type-specific conflict handlers | [iOS 26.1 `IMDCKUpdateSyncController`](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore/IMDCKUpdateSyncController.mm) | Binary-derived fact; no source licence | Fact only | Not implemented. `messageUpdateZone` remains outside the first semantic canary and needs a separate conflict model before activation. |
| 26 | CloudKit has distinct HTTP-request UUID, per-operation UUID, record ETag/change tag, and change-feed ETag identities; none is a substitute for another | [Apple `CKDPOperation`](https://raw.githubusercontent.com/nst/iOS-Runtime-Headers/master/PrivateFrameworks/CloudKitDaemon.framework/CKDPOperation.h), [Apple `CKDPRecord`](https://raw.githubusercontent.com/nst/iOS-Runtime-Headers/master/PrivateFrameworks/CloudKitDaemon.framework/CKDPRecord.h), and the in-tree rustpush request builder | Header declarations and protocol facts | Fact only | The durable Stage 4 mutation receipt must persist both UUIDs and the predecessor record ETag. The current outbox does not yet satisfy this entry. |
| 27 | Apple's private save request and response models expose ETag, conflict, protection-tag, and time-statistics fields beyond the fields represented by the current rustpush protobuf | [Apple `CKDPRecordSaveRequest`](https://raw.githubusercontent.com/nst/iOS-Runtime-Headers/master/PrivateFrameworks/CloudKitDaemon.framework/CKDPRecordSaveRequest.h), [Apple `CKDPRecordSaveResponse`](https://raw.githubusercontent.com/nst/iOS-Runtime-Headers/master/PrivateFrameworks/CloudKitDaemon.framework/CKDPRecordSaveResponse.h), and [rustpush `cloudkit.proto`](https://github.com/OpenBubbles/rustpush/blob/master/cloudkit-proto/src/cloudkit.proto) | Header declarations; SSPL-1.0 local schema | Fact only | Not implemented. Wire numbers must come from a serialized fixture or another directly verified schema, never from guessing based on header property order. |
| 28 | The private error grammar includes request-already-processed, operation-lock, atomic-failure, stale-record-update, and record/zone protection-tag mismatch codes | [InflatableDonkey `cloud_kit.proto`](https://github.com/horrorho/InflatableDonkey/blob/master/src/main/resources/cloud_kit.proto) | MIT | Fact only | Existing rustpush classification covers only part of this set. Stage 4 needs fixture-backed typed outcomes before enabling writes. |
| 29 | `REQUEST_ALREADY_PROCESSED` without authoritative per-record results is not itself a commit receipt | Same private error grammar, compared with Apple's documented per-record modify results | MIT; Apple documentation | Conservative inference from verified facts | `CloudOutboxStatus.unknownOutcome` remains fail-closed. No replay or confirmation may be based on this error code alone. |
| 30 | Readback absence after an ambiguous delete does not prove that this operation deleted the record; another writer or a pre-existing absence can produce the same observation | Apple's optimistic-concurrency and per-record result model | Apple documentation | Conservative inference from verified facts | `reconcileUnknownOutcome` must remain unresolved unless a protected proof binds an authoritative operation result or stronger predecessor-version evidence. |
| 31 | Public CloudKit modify calls return one result per saved or deleted record, while atomic operations can fail the entire zone batch | [Apple `modifyRecords`](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)) | Apple documentation | Fact only | V2 must reject missing, duplicate, or unexpected private-operation results and may confirm only exact per-record successes. |
| 32 | A server-record-changed conflict supplies client, server, and ancestor records; a retry must merge onto the server record because it owns the current change tag | [Apple `serverRecordChanged`](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged) | Apple documentation | Fact only | The private writer needs fixture-proven predecessor ETag/change-tag fields and a typed conflict result before writes can be enabled. |
| 33 | Database and record-zone change tokens are opaque, persistable, and not interchangeable; token expiry requires a scoped refetch rather than interpreting token contents | [Apple `CKFetchDatabaseChangesOperation`](https://developer.apple.com/documentation/cloudkit/ckfetchdatabasechangesoperation), [Apple `CKFetchRecordZoneChangesOperation`](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation) | Apple documentation | Fact only | Keep token bytes protected and stream-scoped. Expiry must preserve local rows, reset only the affected checkpoint, and restart that stream from no token. |
| 34 | CloudKit subscriptions are change hints, not complete change records, and notifications may be coalesced | [Apple `CKDatabaseSubscription`](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription), [Apple `CKRecordZoneSubscription`](https://developer.apple.com/documentation/cloudkit/ckrecordzonesubscription) | Apple documentation | Fact only | Poll/fetch remains authoritative. Subscription setup must be idempotent and cannot replace checkpointed page fetching. |

## Sources deliberately not used

| Project | Licence | Why excluded |
| --- | --- | --- |
| Signal Desktop | AGPL-3.0 | Incompatible with the Apache-2.0 layer; architecture comparison only |
| mautrix/imessage | AGPL-3.0 | Same, and it reads a local database rather than CloudKit |
| imessage-exporter | GPL-3.0 | Concepts only, as recorded in entry 14 |
| Apple Security / CKKS mirror | Apple Public Source-style, no licence metadata on the mirror | Concepts only; also predates Advanced Data Protection |
| Decompiled iOS restoration mirrors | No source-code licence | Protocol and orchestration facts only, as recorded in entries 21-25; no expression copied |
| InflatableDonkey | MIT | Permissively licensed and reusable, but scoped to iOS 9 backups with no Manatee zones or per-field encryption. Nothing taken so far. |

## Maintenance

Add an entry whenever a protocol fact or pattern is taken from an outside
project, in the same change that implements it. An entry naming no
OpenBubbles file is acceptable only when the fact prevented work, as in entries
4 and 9, and that should be stated in the row.
