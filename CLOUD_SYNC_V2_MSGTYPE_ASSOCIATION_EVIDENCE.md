---
type: research-note
title: CloudKit msgType and Association Evidence
description: Source and Canary evidence for separating MessageEncryptedV3 class selection from associated-message semantics.
resource: OpenBubbles Cloud Sync V2
tags:
  - cloudkit
  - messages-in-icloud
  - reactions
  - provenance
timestamp: 2026-08-28T05:00:00Z
---

# CloudKit `msgType` and Association Evidence

## Decision

Treat top-level `MessageEncryptedV3.msgType` as a message-class gate and consistency signal. Determine reaction add/remove semantics from validated `msgProto.associatedMessageType` plus a valid parent reference. Do not require `msgType == 2` for a reaction, and do not infer a reaction from association presence alone.

## Evidence

- A bounded Pixel Canary run at build `6d8889b59fa5241d60568fc8bac3f335a10d0b9d` observed 38 unsupported records with the fixed-label shape `msgType=1` and association present. No identifiers or content were logged. See `artifacts/cloudkit-canary-33141215962/semantic-pull-redacted.md` in the review workspace.
- Apple's private runtime model keeps generic `IMItem.type` separate from `IMAssociatedMessageItem.associatedMessageType`, GUID, and range fields: [IMItem](https://github.com/nst/iOS-Runtime-Headers/blob/fbb634c78269b0169efdead80955ba64eaaa2f21/PrivateFrameworks/IMSharedUtilities.framework/IMItem.h#L628-L758), [IMAssociatedMessageItem](https://github.com/nst/iOS-Runtime-Headers/blob/fbb634c78269b0169efdead80955ba64eaaa2f21/PrivateFrameworks/IMSharedUtilities.framework/IMAssociatedMessageItem.h#L323-L376).
- RustPush groups `msgType` values 1 and 2 into one message-class variant, while values 3 through 7 select special classes. Its derived `reaction` boolean is an implementation convention, not an Apple schema guarantee: [RustPush decoder](https://github.com/OpenBubbles/rustpush/blob/0e0f13c6417f621be72d4e0e5cc2df89de55144e/src/imessage/cloud_messages.rs#L2465-L2603).
- Corten-Matrix widens that same message-class gate to include `msgType=0` after observing ordinary live records with zero: [Corten commit](https://github.com/lrhodin/corten-matrix/commit/a4b512aec925f25008dba01c7250bf3584350bd1).
- Beeper classifies reaction adds from `2000..2007` and removals from `3000..3007` using the associated-message field, not top-level `msgType`: [type mapping](https://github.com/beeper/platform-imessage/blob/cda1545b87db4aeb2ec266bd8f9f335eec67c323/src/IMessage/Sources/IMessage/Mappers/MessageMapperTypes.swift#L1035-L1074), [associated mapper](https://github.com/beeper/platform-imessage/blob/cda1545b87db4aeb2ec266bd8f9f335eec67c323/src/IMessage/Sources/IMessage/Mappers/MessageMapper%2BAssociated.swift#L583-L684).

## Conservative matrix

| Top-level class | Associated-message fields | Outcome |
|---|---|---|
| `0..=2` | None | Message-class candidate; preserve raw `msgType` in identity/digest and diagnostics. |
| `0..=2` | `2000..=2007` plus valid parent | Reaction add. |
| `0..=2` | `3000..=3007` plus valid parent | Reaction remove. |
| `0..=2` | Sticker or another known subtype | Handle only through its separately tested subtype path. |
| `0..=2` | Unknown type or malformed parent | Quarantine. |
| `3..=7` | None | Preserve/quarantine until each special class has a tested semantic mapping. |
| `3..=7` | Reaction association | Quarantine as a class/association conflict. |
| Unknown class | Any | Quarantine without discarding the encrypted record. |

## Remaining live gate

Build `698b796c7b29ed562fadfc685d6440f893d0326b` passed its full CI gates and was installed in place over the existing Canary with the stable Canary signing key. One manual read-only Shadow Sample completed all seven zones with 300 fetched records, 600 protected journal entries, zero rejected records, and an unchanged zero outbox. The existing shadow checkpoint selected a later page that did not emit the new allowlisted subtype labels, so this run does not independently classify the earlier 38 `msgType=1 + association` observations.

This does not block the conservative `0..=2` message-family correction because three independent sources establish the field separation and reaction subtype ranges, while every unimplemented outer class, malformed parent, and unknown association remains quarantined. Before production enablement, repeat the fixed-label subtype measurement through a separately reviewed diagnostic scope that can sample the original page without deleting the protected journal or resetting semantic state.
