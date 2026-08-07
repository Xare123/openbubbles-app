---
type: specification
title: OpenBubbles Cloud Sync V2 Field Ownership
description: Which fields the server owns, which the device owns, and the merge rule each class carries, so that semantic apply cannot silently overwrite local state.
resource: openbubbles-app
tags: [cloudkit, sync, merge, schema, phase2]
timestamp: 2026-08-06
---

# Cloud Sync V2 field ownership

## Why this exists before the adapter

Semantic apply is the first thing that writes CloudKit-derived data into the
local message tables. Without a written classification, "the server wins" is
implemented field by field from memory, and the first time it is wrong the
symptom is a user's local state being silently overwritten. That is discovered
from a bug report, not from a test.

This document is the input to that adapter. It is deliberately derived from
what the existing `applyFromCloud` path actually writes, not from what the
schema could theoretically carry.

## The three classes

**Server-immutable.** Content that cannot legitimately change after the message
exists. First valid canonical event wins. A later record carrying different
content is a conflict and is quarantined for diagnosis, never applied over the
existing value.

**Server-mutable.** State Apple continues to update. The server is the
authority, but a record may arrive carrying older state than we already hold,
because CloudKit gives no intra-batch ordering guarantee. Every write in this
class must go through a monotonic comparison rather than direct assignment.

**Device-owned.** Never written by projection under any circumstance. Not
"usually not" — the adapter must have no code path that assigns them.

## Message

### Server-immutable

`guid`, `dateCreated`, `isFromMe`, `handleId`, `handle`, `text`, `subject`,
`attributedBody`, `payloadData`, `hasApplePayloadData`, `balloonBundleId`,
`expressiveSendStyleId`, `threadOriginatorGuid`, `threadOriginatorPart`,
`associatedMessageGuid`, `associatedMessagePart`, `associatedMessageType`,
`associatedMessageEmoji`, `chat`.

Notes that matter for the adapter:

- `associatedMessageGuid` holds the **parsed** parent GUID, never Apple's
  `p:<part>/<guid>` wrapper. `associatedMessagePart` is null when Apple sent a
  bare GUID, which is its partless form. Both come from
  `CloudAssociatedMessageParentReference`.
- `associatedMessageType` is null for a reaction type this build has no name
  for. Null means "not a reaction row", not "unknown reaction".
- `text` and `attributedBody` are immutable **only for the original message**.
  Edits do not mutate them; they arrive as edit history, which is
  server-mutable below.

### Server-mutable

| Field | Merge rule |
| --- | --- |
| `dateRead` | Monotonic maximum. Never move backwards. |
| `dateDelivered` | Monotonic maximum. |
| `dateDeleted` | Set once by a server-confirmed tombstone. Never cleared by a later record. |
| `error` | Latest server value. |
| `hasAttachments` | Recomputed from attachment links, not copied. |
| `hasReactions` | Recomputed from child reaction rows, not copied. |
| edit history (`messageSummaryInfo`) | Union by Apple edit metadata. Never replaced wholesale, and an empty collection is not a clear instruction. |
| retracted parts | Union. A retraction is not undone by a later record that omits it. |

`Message.save()` already preserves the monotonic rule for `dateDelivered` and
`dateRead`; the adapter must not bypass it by assigning directly.

### Device-owned

`id`, `isBookmarked`, `hasBeenForwarded`, `stagingGuid`, `verificationFailed`,
`bigEmoji`, `datePlayed`, `country`, `hasDdResults`.

`ckRecordId` and `ckSyncState` are owned by the **legacy** CloudKit path.
Cloud Sync V2 must not write either. Doing so would make the two paths fight
over the same columns, and the record map exists precisely so V2 does not need
them.

#### Divergence from upstream on conversion failure

This branch changed how the legacy upload path sets `ckSyncState` when
`Message.toCloud()` throws, and a reviewer will notice, so the reasoning is
recorded here rather than left to a diff.

Upstream marks the message synced regardless of outcome:

```dart
} catch (e, s) {
  Logger.warn("Failure to convert to cloud", error: e, trace: s);
  continue;
} finally {
  message.ckSyncState = true;
}
```

A message that fails to convert is therefore recorded as crawled and is never
retried. It silently never reaches CloudKit. This branch drops the `finally`,
leaves `ckSyncState` false, releases any record id that was minted for the
failed attempt, and counts the message as retryable.

The trade is deliberate: upstream terminates but loses the message, and this
branch keeps the message but re-attempts it on every future sync. The
re-attempt is bounded within a pass. `CloudMessageUploadBatchResult.madeProgress`
is false when nothing converted, and the driver in `rustpush_service.dart`
breaks out and logs how many messages stayed queued, so a wholly unconvertible
backlog cannot spin.

What is still missing is persistence. Nothing records that a specific message
has failed conversion across sessions, so a permanently unconvertible message
is invisible unless someone reads the logs and correlates by hand. A pass that
converts some messages and not others never trips the `madeProgress` break, so
the stuck ones ride along indefinitely without being surfaced. Closing that
properly needs a durable per-message attempt count, which is an ObjectBox schema
change and is deliberately not being made ahead of the first live run. This
affects the upload direction only; the read-only sampler does not exercise it.

## Chat

**Server-immutable:** `guid`, `chatIdentifier`, `isGroup`, `style`.

**Server-mutable:** `displayName`, `participants` and the `handles` relation,
`groupVersion` (higher wins), `lastReadMessageGuid` (monotonic against local
read position), `photoAttachmentGuid`.

**Device-owned:** `id`, `isPinned`, `isMuted`, `muteType`, `muteArgs`,
`isArchived`, `hasUnreadMessage`, `textFieldText`, `textFieldAttachments`,
`customAvatarPath`, `pinIndex`, `autoSendReadReceipts`,
`autoSendTypingIndicators`.

Two locks already exist and are load-bearing: `lockChatName` and
`lockChatIcon`. When either is set the user has overridden that value
deliberately, and projection must skip the corresponding server-mutable field
even though the server owns it. This is the one place where a device-owned
decision outranks server authority.

## Attachment

**Server-immutable:** `guid`, `uti`, `mimeType`, `transferName`, `totalBytes`,
`isOutgoing`, `message` relation, owner part.

**Server-mutable:** none currently identified. Attachment metadata does not
change after upload in the shapes we handle.

**Device-owned:** `id`, `bytes`, `sourcePath`, local file placement, and
`metadata["cloud"]`, which the canonical mapping already says should move to
the protected record map rather than being written into entity metadata.

## Rules the adapter must follow

1. **No direct assignment to a server-mutable field.** Every one goes through a
   comparison helper. `cloud_merge_policy.dart` already has the monotonic
   helper and the `modifiedAt` and `retractedAt` comparisons; extend it rather
   than assigning in the adapter.
2. **No assignment to a device-owned field, ever.** Not conditionally, not with
   a null check.
3. **A conflicting server-immutable value is a quarantine**, not an overwrite.
   The record is preserved for diagnosis and the local row is left alone.
4. **Respect `lockChatName` and `lockChatIcon`** before writing the fields they
   guard.
5. **Recompute rather than copy** `hasAttachments` and `hasReactions`. They are
   derived, and copying them from a record makes them disagree with the rows
   they summarise.

## Why this removes the need for a per-row sequence number

The checkpoint, the inbox status, and the projected rows already commit inside
one ObjectBox write transaction, so a crash cannot apply a row without also
recording that it was applied. Exactly-once projection follows from that
transaction, not from a version column.

What the transaction does not prevent is a record carrying **older** state
overwriting newer state, since CloudKit gives no intra-batch ordering
guarantee. That is an ordering problem confined to the server-mutable set
above, and the monotonic rules there address it directly.

A per-row watermark would additionally require deciding what a single sequence
means for a row written from more than one zone. This classification dissolves
that question: a message body only ever comes from the message zone and an
attachment link only from the attachment zone, so field ownership already
partitions by zone.

Revisit if a second writer appears. Once Phase 3 uploads land, local mutations
compete with server state and "server wins" stops being sufficient on its own.

## Open items

- The device-owned lists were read from the current entity definitions. They
  must be re-checked whenever a field is added, and that check belongs in the
  schema-freeze review.
- `Chat.lastReadMessageGuid` needs a decision on whether the local read
  position may ever move backwards to match the server. It is currently listed
  as monotonic against the local position, which is the conservative reading.
