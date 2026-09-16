---
type: design
title: CloudKit incoming-message archival gap and implementation boundary
description: Source-backed coverage gap and minimum separate archival path required before claiming complete two-way sync.
resource: openbubbles-app
tags: [cloudkit, receive, archive, production-gate]
timestamp: 2026-09-16
---

# Decision

Incoming archival is a missing production capability, not a reason to relax the
outgoing positive-receipt gate. No received message may be represented as a
successful outgoing send, and archive work must never send an IDS message.
This design is not an implemented or qualified upload path.

## Verified coverage at product f027aad2a

| Origin | Current path | Archive result |
| --- | --- | --- |
| Locally composed send | Fresh origin, positive native IDS receipt, local-send journal, protected outbox | Supported by the separately qualified send lane. |
| Incoming iMessage | Native receive, incoming queue, ActionHandler, local Message | No V2 archive intent producer. |
| Own message mirrored from another device | Same receive path | No fresh local-send intent; isFromMe alone is not submission evidence. |
| Existing CloudKit history | Protected read and canonical projection | Must not feed a new archive loop. |
| Older local/Alpha history | Legacy bulk-upload candidate only | Legacy writes are disabled under V2 ownership; import requires separate explicit disposition. |

Source anchors: `RustPushService.handleMsgInner`, `reflectMessageDyn`,
`IncomingQueue`, `ActionHandler.handleNewMessage`, `Chat.addMessage`,
`CloudSyncLocalSendIdentity.capture`, `CloudSyncLocalSendJournal.readReady`,
`CloudSyncProductionLocalSendAdapter`, and the legacy `uploadMessages` guard.
The local-send consumer explicitly drains its journal, not arbitrary Message
rows. The legacy query selects unsynced rows without a from-me filter, but that
writer is intentionally fenced off in a V2-owned installation.

This means an incoming thread can remain only local unless another client
uploads it. It does **not** prove that the missing 27 Alpha GUIDs are absent from
Apple: canonical-table absence is weaker than a protected raw-cache/remote
presence check. The 6,252 retained records must not be ignored in that diagnosis.

## Minimum implementation sequence

1. Define a separate received-archive origin and durable intent after incoming
   persistence succeeds. Preserve account/store provenance, the exact original
   GUID, sender, direction, timestamp, chat route and content digest. Observe
   existing certified delivery; do not emit an extra acknowledgement or invent
   a send receipt. An older-history importer remains a different entry point.
2. Capture an immutable source before queueing work. Reuse protected source and
   archive/outbox machinery where its contracts fit. Keep local-send eligibility,
   positive receipt, one-time send claim and unknown-send rules unchanged.
   Admission must check the V2 record-map/snapshot and existing local-send
   journal, not just legacy ckRecordId/ckSyncState flags. An echoed local send
   cannot acquire a second identity merely because it arrived on the receiver.
3. Resolve the exact protected chat dependency. A group ID/name/member guess is
   insufficient; preserve validated canonical row IDs and record-map bindings.
   The saved canonical group passes local structural proof, but the split live
   row is provisional. A binding check on a copy is not live write permission.
4. Establish record naming and logical-message deduplication against existing
   Apple records before enabling creates. Already-present identical data is
   adopted without a new create; divergent or incomplete evidence is retained.
   Do not equate absence of a newly chosen record name with logical-message
   absence. Pin the request/operation identity before any external save.
5. Reuse create-only save, exact readback, durable record-map adoption and
   restart recovery. Unknown outcomes reconcile by readback only. No legacy
   uploader fallback, blind retry, new record ID after timeout, or remote delete.
6. Expose the received-archive capability truthfully through Profile. Until it
   works, the existing automatic-upload switch must not be described as a full
   backup of incoming/mirrored conversations.

`Message.toCloud` is a useful legacy encoding reference, not a blanket safe
replacement for the V2 encoder. It must not reconstruct or overwrite existing
records and discard unknown fields. First prove fresh received text encoding,
then group, media and mutation interplay before a full production claim.

## Required evidence

- Current incoming, mirrored, restored, unverified, and older imported origins
  remain distinguishable. No source is silently promoted between lanes.
- Crash/restart before save, during uncertain save and after readback produces
  no IDS resend, duplicate archive or lost durable candidate.
- A message independently uploaded by another Apple client is not duplicated or
  overwritten by the new lane.
- Direct and group sender/body/time remain correct; attachments and reply/edit/
  unsend behavior stay explicitly scoped and tested.
- An independent Apple client consumes the archived result correctly. A
  successful read through the same custom encoder/decoder is not that proof.

## Existing split-group repair

The observed live row has 13 incoming messages and no local-send/adopted-send/
mutation journal references. Its exact GUID matches the canonical cloudGuid,
and that canonical row passes the production local group-binding validator.
These are prerequisites, not authority to call `Chat.merge`: that method only
fills UI values and does not transact Message relations or protected bindings.
Do not rename/rekey canonical rows, move messages, or hide the split until a
separately reviewed local repair preserves every dependency and user setting.

Prefer finishing the received-archive origin and its relationship handling
over an unrelated destructive chat merge. No live data has been changed by
this investigation.
