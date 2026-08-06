---
type: design-spec
title: Cloud Sync V2 Canonical Mapping
description: Field-level contract between native CloudKit decoding, transient Flutter Rust Bridge payloads, canonical app entities, and content-free sync metadata.
resource: C:\Codex\OpenBubblesReview\openbubbles-app
tags:
  - openbubbles
  - cloud-sync-v2
  - cloudkit
  - reconciliation
  - privacy
timestamp: 2026-08-01
---

# Cloud Sync V2 Canonical Mapping

## Status and scope

This document is the reviewed semantic boundary required before Cloud Sync V2
may write a chat, message, reaction, attachment, or group photo into the
canonical application database.

It is based on the current Rust CloudKit structs and the existing Dart
`Chat.applyFromCloud`, `Message.applyFromCloud`, and
`Attachment.applyFromCloud` behavior. It is a mapping specification, not proof
that semantic pull is production-ready.

The current V2 decoder only produces a content-free identity projection. The
current Dart semantic payloads are deliberately narrow scaffolding. Neither is
yet sufficient to perform the mappings below. `semanticApply` must remain
disabled until the blockers and fixture gates in this document pass.

This specification does not cover SMS, RCS, iCloud Contacts, scheduled-message
zones, or general profile discovery. Shared profile records remain a separate,
opt-in module.

## Source of truth and terminology

The relevant sources are:

- `rustpush/src/imessage/cloud_messages.rs`: `CloudChat`, `CloudMessage`,
  `CloudAttachment`, `AttachmentMeta`, `MMCSAttachmentMeta`, and edit metadata.
- `rustpush/src/imessage/cloud_messages.proto`: the four message protobuf
  envelopes.
- `lib/database/io/chat.dart`: current chat lookup, upload, and download
  mapping.
- `lib/database/io/message.dart`: attributed-body, message, reaction, reply,
  edit, and retraction mapping.
- `lib/database/io/attachment.dart`: attachment identity and metadata mapping.
- `lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart`: dormant
  transient semantic payload and transactional apply boundary.
- `rust/src/cloud_sync_semantic_decoder.rs`: current native content-free
  projection and tombstone reversal.

The words **observed**, **proposed**, and **blocked** are used precisely:

- **Observed** means the current source establishes the format or behavior.
- **Proposed** means V2 should adopt the rule after the specified fixtures pass.
- **Blocked** means V2 must not apply that field yet.

## Data lanes and privacy classification

Cloud Sync V2 needs four distinct data lanes. Mixing them is a release blocker.

| Class | Meaning | Examples | Allowed lifetime and destination |
|---|---|---|---|
| `N0` native secret | Apple transport, PCS, or MMCS material that the Flutter layer does not need | DSID, PCS keys, raw record name, raw decrypted CloudKit record, MMCS signature, owner, URL, decryption key, `Asset` | Native memory or protected native storage only. Never cross FRB as plaintext. Never log. |
| `T1` transient canonical plaintext | Decrypted information needed to update the app's existing user-visible data | message GUID and body, sender handle, participant handles, chat name, attributed runs, edit text, attachment display name | May cross FRB only in a typed, redacted, non-serializable DTO. Consume immediately in the canonical write transaction. Never persist in sync journals, checkpoints, conflicts, or diagnostics. |
| `C1` canonical app data | User data the application already stores and renders | `Message`, `Chat`, `Handle`, `Attachment`, edit history, local materialized media file | May be stored in the existing canonical app entities. This is not sync metadata. Existing app backup and at-rest protections still apply. |
| `D0` durable content-free sync metadata | State needed for replay, merge, and recovery without user content | account-scoped HMAC identities, etag hash, content digest, protected-reference token, timestamps, counters, allowlisted safe code | May be stored in Cloud Sync V2 ObjectBox records and redacted diagnostics. |

`T1` and `C1` are intentionally different. A message body may be transiently
decoded and then written to the existing `Message` row because the app must
render it. The same body must never be copied into a V2 inbox, snapshot,
record-map, checkpoint, run record, or exception.

The protected raw-envelope reference is a `D0` opaque token. Resolving that
token yields `N0` data and must remain inside the native protector boundary.

## Common envelope rules

Every decoded mutation must carry:

1. account and zone scope, validated against the active generation;
2. ordered inbox `changeId`;
3. HMAC of the opaque server record ID;
4. HMAC of the logical entity identity;
5. Cloud entity kind and upsert or tombstone kind;
6. optional etag hash and validated server timestamps;
7. a protected raw-envelope reference;
8. a typed transient payload for an upsert, or a mapped logical identity for a
   tombstone.

The native decoder must validate record type, encrypted-record shape, required
identity fields, and PCS availability before returning a semantic DTO. Dart
must not receive a partially decoded raw `CloudChat`, `CloudMessage`, or
`CloudAttachment`.

Unknown optional fields are retained through the protected raw envelope.
Unknown or malformed core identity fields quarantine the event. Missing PCS or
an unclassified native/upstream error is retryable and must not be converted to
`malformedRecord`.

## Identity rules

### Scope

All HMAC identities are scoped to:

```
accountIdentityHash + container + database + zone + rebootstrapGeneration
```

The HMAC input also includes a versioned domain and entity kind. A hash from one
account, zone, generation, or entity kind must not resolve in another.

Raw Apple IDs may cross FRB only as `T1` values when the canonical app entity
needs them. Durable V2 metadata stores their HMACs, never their plaintext.

### Server record identity

`serverRecordIdHash` is the immutable identity of the CloudKit record envelope.
The raw record name remains `N0`. A record map binds:

```
serverRecordIdHash -> entity kind + logicalEntityKeyHash + protected server ID
```

Inbound duplicate logical records are mapping conflicts. V2 must not reproduce
the legacy behavior that deletes a prior server record while processing an
inbound page.

### Chat identity and aliases

**Proposed primary identity:** HMAC of `CloudChat.guid` under the chat identity
domain.

`group_id`, `original_group_id`, and `(service_name, chat_identifier)` are
aliases, not independent chat entities:

- group `CloudMessage.chat_id` normally resolves through `group_id`;
- direct `CloudMessage.chat_id` normally has
  `iMessage;-;<chat_identifier>` shape and may equal the chat GUID;
- legacy or restored records can refer to `original_group_id`.

Store each alias as an account-scoped HMAC that resolves to the primary chat
hash. A conflicting alias mapping quarantines the later mutation.

Display name and participant set are never identity. The current
`Chat.findFromCloud` participant/display-name fallback is useful for manual
legacy repair but is unsafe for deterministic V2 replay. It can merge two
different chats with the same members.

### Message identity

The primary identity is HMAC of `CloudMessage.guid` under the message domain.
The canonical `Message.guid` receives the plaintext GUID through the transient
DTO.

The message-to-chat link uses the HMAC of `chat_id` resolved through the chat
alias map. A missing parent chat defers the message. V2 must not attach it to a
"current" chat or create a chat from message content alone.

### Reaction identity

A reaction is a `CloudMessage` whose decoded
`associated_message_type` is in the validated add or removal range. Its
proposed logical identity is:

```
HMAC(reaction-domain, reactionGuid + NUL + parentGuid + NUL + parentPart)
```

Its parent link is the message-domain HMAC of `parentGuid`. The plaintext
reaction GUID is still stored in the canonical `Message.guid`.

The reaction is deferred if the parent is missing. An add and a removal are
separate immutable reaction records whose canonical reduction determines the
visible reaction state. Do not mutate or delete the parent message merely
because a reaction removal arrived.

A sticker (`associated_message_type == 2`) remains a message with a typed parent
association. It is not classified as a reaction because its attachment and
rendering semantics differ.

### Attachment identity and ownership

Observed CloudKit attachment IDs commonly use:

```
at_<decimal-part>_<message-guid>
```

Parse the prefix and decimal part, then treat the entire remaining suffix as
the message GUID. Do not use `split("_")[2]`, because that truncates a GUID that
contains an underscore.

For an owned attachment:

```
logical attachment key =
  HMAC(attachment-domain, messageGuid + NUL + decimalPart)
canonical local Attachment.guid = messageGuid + "_" + decimalPart
owner key = HMAC(message-domain, messageGuid)
```

For an attachment GUID that does not match the owned form, use an HMAC of the
complete raw attachment GUID and leave the owner unresolved. Filename, path,
MD5 prefix, record arrival order, and currently open conversation are never
identity.

### Group photo identity

A group photo is an embedded chat asset, not an independently trustworthy
message attachment. Its proposed subentity identity is:

```
HMAC(group-photo-domain, chatLogicalKeyHash + NUL + groupPhotoGuid)
```

The root `group_photo_guid` and
`properties.group_photo_guid` must agree when both are present. A mismatch
quarantines the photo mutation while allowing independently valid chat fields
to remain reviewable. A photo asset without a usable photo GUID is not applied.

The `Asset`, MMCS descriptors, and download credentials remain `N0`. Dart
receives only a protected local file reference after native verification and
materialization.

## Typed parent-reference parsing

### Reaction and sticker parent

Observed upload grammar:

```
p:<decimal-part>/<message-guid>
```

The native parser must:

1. require the exact `p:` prefix;
2. split once at the first `/` after the prefix;
3. require a non-negative decimal part that fits the canonical integer type;
4. require a non-empty GUID suffix;
5. return `{ parentGuid, parentPart, rawRangeLocation, rawRangeLength }`;
6. HMAC `parentGuid` before producing durable metadata.

The associated range is validation evidence. It must not be used to derive the
part from the reaction message's own attributed body. The current download
mapper does exactly that and also stores the unparsed `p:` wrapper in
`associatedMessageGuid`, so current parent lookup can fail.

`bp` and `bpdi` are balloon payload fields in the native incoming message
schema. They are not aliases for `p:`. No `bp:` parent wrapper should be
accepted without a sanitized CloudKit fixture proving a separate format.

### Thread reply parent

Observed upload grammar:

```
r:<part-string>:<message-guid>
```

Parse the `r:` prefix and the last separator. The middle substring is the part
string and the final non-empty substring is the parent GUID. A missing
separator, empty parent, or implausible part is an unresolved association and
must be quarantined or durably deferred, not silently discarded.

This grammar is independent of the reaction `p:` grammar. Sanitized fixtures
must determine whether colons can occur in real part strings or GUIDs before
the parser is declared final.

## Presence, clear, and default semantics

V2 must preserve field presence before Rust `Default` or Serde defaults erase
the distinction.

Use three semantic states for every optional or defaulted mutable field:

| State | Meaning | Merge behavior |
|---|---|---|
| absent | Field was not present in the decrypted record | Preserve the existing canonical value. |
| value | Field was present with a valid value, including an intentionally empty string or list | Apply according to field merge rules. |
| explicit clear | The schema and fixture prove that the present representation means removal | Clear only if the mutation is otherwise authoritative. |

Concrete FRB DTOs should use a non-generic `CloudFieldStateDto` plus a nullable
typed value, because bridge support for generic presence wrappers should not be
assumed.

Additional rules:

- Missing required identity is malformed. Empty required identity is malformed.
- A zero message read or delivery timestamp means no timestamp on creation. It
  must not erase a newer existing timestamp.
- `last_read_message_timestamp == 0` is not proof that the chat's latest date
  should be cleared.
- Negative attachment dates are valid wire values and must not be rejected.
- Negative attachment byte counts mean unknown for the current non-negative
  canonical size field. Do not clamp to zero.
- An absent vector or map is not automatically an explicit empty collection.
  The native presence bitmap must distinguish them.
- Unknown flag bits remain in the protected raw envelope. Known bits may be
  projected to typed canonical fields.
- A tombstone without server time remains a server-confirmed tombstone with a
  null `deletedAt`. Never invent the local clock time.

## Chat field mapping

| Cloud source | Canonical target | Classification | Absent/default and merge rule | Status |
|---|---|---:|---|---|
| `guid` | `Chat.guid` or stable cloud identity field, plus logical HMAC | `T1/C1`, HMAC `D0` | Required, non-empty, immutable. Never reconcile by display name. | Proposed after identity fixtures |
| `chat_identifier` | `Chat.chatIdentifier`, alias HMAC | `T1/C1`, HMAC `D0` | Required for current schema. A changed alias must not create a second chat. | Proposed |
| `group_id` | `Chat.cloudGuid`, alias HMAC | `T1/C1`, HMAC `D0` | Required for group relationship resolution. Empty is malformed. | Proposed |
| `original_group_id` | alias HMAC only, optionally canonical compatibility field | `T1`, HMAC `D0` | Preserve prior alias if absent. Conflict quarantines. | Proposed |
| `service_name` | service validation and chat route | `T1/C1` | Only validated `iMessage` is in V2 scope. Other services are unsupported, not coerced. | Proposed |
| `style` | `Chat.style` and validated group/direct classification | `C1` | Known observed values 43 and 45 may map. Unknown value is retained protected and does not change group routing. | Fixture required |
| `is_filtered` | no safe canonical target | protected `N0` | Preserve only in protected raw record. | Blocked |
| `successful_query` | no safe canonical target | protected `N0` | Upload default is observed, meaning is not established. | Blocked |
| `state` | no safe canonical target | protected `N0` | Value 3 is common, not a proven canonical state machine. | Blocked |
| `participants[].uri` | `Chat.handles` and `Handle` rows | `T1/C1`, set digest `D0` | Apply an authoritative participant set only on create or a valid higher group version. Respect account scope and URI normalization. | Proposed |
| `display_name` | `Chat.displayName` | `T1/C1`, digest `D0` | Absent preserves. Explicit clear requires a fixture. Respect `lockChatName`. | Proposed with clear fixture |
| `last_addressed_handle` | `Chat.usingHandle` | `T1/C1` | Normalize only recognized email/telephone handles. Empty or malformed preserves existing. | Proposed |
| `last_read_message_timestamp` | content-free snapshot timestamp; possibly chat latest-date hint | `D0` | Do not overwrite `dbOnlyLatestMessageDate` until fixtures prove the field's meaning. Zero preserves existing. | Blocked for canonical date |
| `prop001.syndication_type` | no safe canonical target | protected `N0` | Upload code sets 0, semantic meaning is marked as a guess. | Blocked |
| `proto001.unk1` | no canonical target | protected `N0` | Preserve protected. | Blocked |
| `properties.pv` | `Chat.groupVersion`, snapshot group version | `C1/D0` | Higher version wins. Equal version with different metadata digest is a conflict. Null cannot authorize group mutation. | Proposed |
| `properties.last_seen_message_guid` | `Chat.lastReadMessageGuid` | `T1/C1`, HMAC `D0` | Apply only when referenced message identity is valid. Missing parent may defer this subfield. | Proposed |
| `properties.group_photo_guid` | validated photo identity | `T1`, HMAC `D0` | Must agree with root photo GUID if both exist. | Proposed |
| `properties.last_modification_date` | group metadata modified time | `D0` | Validate finite/range. It is merge evidence, not local wall-clock authority. | Proposed |
| `properties.gpufc` | no safe canonical target | protected `N0` | Meaning unverified. | Blocked |
| `properties.number_of_times_respondedto_thread` | no safe canonical target | protected `N0` | Upload value is guessed. | Blocked |
| `properties.should_force_to_sms` | no V2 iMessage target | protected `N0` | Must not change SMS routing. | Blocked |
| `properties.message_handshake_state` | no safe canonical target | protected `N0` | Must not be used as authentication proof. | Blocked |
| `properties.legacy_group_identifiers` | alias candidates only after format validation | `T1`, HMAC `D0` | Never store plaintext in sync metadata or auto-merge on an unvalidated value. | Fixture required |
| root `group_photo_guid` | group-photo identity and `Chat.photoAttachmentGuid` compatibility value | `T1/C1`, HMAC `D0` | Absent preserves. Explicit clear requires presence evidence and authoritative group version. | Proposed with clear fixture |
| `group_photo: Asset` | `Chat.customAvatarPath` after verified materialization | native `N0`, protected reference `D0`, file `C1` | Network and file work occur outside ObjectBox transaction. Respect `lockChatIcon`. | Proposed after media adapter |
| CloudKit etag/create/modify/permission | semantic snapshot and record map | `D0` | Hash etag. Validate timestamps. Permission is safe numeric metadata but not authorization by itself. | Proposed |

The legacy `cloudData` field serializes the complete decrypted `CloudChat` for
later upload reconstruction. V2 must not copy a raw decrypted record into
Cloud Sync metadata or use `cloudData` as its semantic snapshot. Unknown fields
belong behind the protected raw-envelope reference.

## Message envelope mapping

| Cloud source | Canonical target | Classification | Absent/default and merge rule | Status |
|---|---|---:|---|---|
| `guid` | `Message.guid`, logical HMAC | `T1/C1`, HMAC `D0` | Required, non-empty, immutable. Conflicting immutable content for one GUID quarantines. | Proposed |
| `chat_id` | `Message.chat` through chat alias map | plaintext stays native/transient, HMAC `D0` | Missing parent chat defers. Do not split an arbitrary semicolon string by fixed index without grammar validation. | Proposed |
| `sender` | `Message.handle` and `handleId` | `T1/C1`, HMAC or digest `D0` | Empty is valid for from-me records. Otherwise normalize recognized handle syntax. | Proposed |
| `time` | `Message.dateCreated`, snapshot created time | `C1/D0` | Required Apple-epoch nanoseconds. Validate conversion and range. Immutable after first valid event. | Proposed |
| `utm` | server/update ordering evidence | `D0` | Optional unencrypted timestamp. It does not replace CloudKit system modification time without fixtures. | Fixture required |
| `msgType` | semantic classification | `D0` safe enum | Type 2 is an associated record in current upload code, but final classification also requires decoded proto fields. | Proposed |
| `eCode` | `Message.error` | `C1` | Present unencrypted integer. Do not turn an unknown code into a transport failure. | Proposed |
| `destination_caller_id` | validation against chat sending handle | `T1` | Do not mutate `Chat.usingHandle` from a single message without corroboration. | Blocked for write |
| `flags.IS_FROM_ME` | `Message.isFromMe` | `C1/D0` | Typed bit. Cross-check empty sender and account handles, but flags remain authoritative only after fixtures. | Proposed |
| `flags.IS_DELIVERED`, `IS_READ` | delivery/read booleans corroborating proto timestamps | `C1/D0` | A bit without a timestamp must not invent a date. | Proposed as validation |
| `flags.HAS_DD_RESULTS` | `Message.hasDdResults` | `C1` | Apply known bit. | Proposed |
| `flags.IS_FORWARD` | `Message.hasBeenForwarded` only if it represents the same semantic concept | `C1` | Current field is also used for local SMS forwarding. Do not conflate without fixture. | Blocked |
| `flags.WAS_DELIVERED_QUIETLY` | `Message.wasDeliveredQuietly` | `C1` | Apply known bit. | Proposed |
| `flags.DID_NOTIFY_RECIPIENT` | `Message.didNotifyRecipient` | `C1` | Apply known bit. | Proposed |
| other known and unknown flags | typed future fields or protected raw | `D0` or protected `N0` | Never truncate the protected representation merely because current Dart lacks a target. | Protected only |
| `service` | message/chat service validation | `T1/C1` | V2 accepts validated iMessage. SMS is outside scope and must not be silently imported. | Proposed |
| `msgProto3.unk2`, `unk3` | no safe canonical target | protected `N0` | Preserve protected. | Blocked |

### `MessageProto`

| Proto field | Canonical target | Classification | Absent/default and merge rule | Status |
|---|---|---:|---|---|
| `unk1` | no safe canonical target | protected `N0` | Upload code uses 1, meaning is not established. | Blocked |
| `subject` | `Message.subject` | `T1/C1`, digest `D0` | Absent preserves on an update. Explicit empty is a value. | Proposed |
| `text` | `Message.text` | `T1/C1`, digest `D0` | Use as plain-text representation. Do not discard a valid attributed body. | Proposed |
| `attributedBody` | `Message.attributedBody` | `T1/C1`, digest `D0` | Decode natively into validated strings, ranges, and attributes. Invalid ranges quarantine the content mutation. | Proposed |
| attributed run message part | `Attributes.messagePart` | `T1/C1`, part hash `D0` | Non-negative integer; stable per message part. | Proposed |
| attributed run attachment GUID | `Attributes.attachmentGuid` and deferred attachment link | `T1/C1`, attachment HMAC `D0` | Normalize with the safe attachment parser. Missing attachment defers the link, not the message body. | Proposed |
| mention | `Attributes.mention` | `T1/C1` | Validate range and handle-like value. Never log. | Proposed |
| audio transcript | `Attributes.audioTranscript` | `T1/C1`, digest `D0` | User content, never sync metadata. | Proposed |
| text effect and formatting | corresponding `Attributes` fields | `C1` | Unknown effects stay protected. | Proposed for known values |
| sticker data | `Attributes.stickerData` | `T1/C1`, digest `D0` | Validate numeric ranges and required strings. | Fixture required |
| `balloonBundleId` | `Message.balloonBundleId` | `T1/C1` | An allowlisted identifier may be stored. Unknown bundle is not an error. | Proposed |
| `payloadData` | decoded `Message.payloadData` for allowlisted extensions | `T1/C1`, digest `D0` | Decode outside the ObjectBox transaction. Unknown or failed payload stays protected without logging bytes or content. URL balloon support is currently incomplete. | Partial, fixture required |
| `messageSummaryInfo` | `Message.messageSummaryInfo` | `T1/C1`, edit/retraction digests `D0` | Apply only through the edit contract below. | Proposed after fixtures |
| `effect` | `Message.expressiveSendStyleId` | `T1/C1` | Allowlisted effect ID, absent preserves. | Proposed |
| `dateRead` | `Message.dateRead`, snapshot read time | `C1/D0` | Zero means no date on create. Merge by monotonic maximum. Never clear a newer date. | Proposed |
| `dateDelivered` | `Message.dateDelivered`, snapshot delivered time | `C1/D0` | Same monotonic rule as read time. | Proposed |
| `unk10`, `unk11`, `unk14` | no safe canonical target | protected `N0` | Preserve protected. | Blocked |
| `associatedMessageType` | sticker/reaction typed association | `C1/D0` | Validate exact ranges and reaction enum bounds before indexing. Unknown value preserves protected and does not create a reaction. | Proposed |
| `associatedMessageGuid` | `associatedMessageGuid`, `associatedMessagePart`, parent hash | `T1/C1`, HMAC `D0` | Parse exact `p:` grammar. Never store the wrapper as the canonical GUID. | Proposed, current legacy bug |
| `associatedMessageRangeLocation/Length` | association validation evidence | `C1/D0` | Validate against the parent part when available. Do not derive the part from the child body. | Proposed |

### `MessageProto2`, replies

| Proto field | Canonical target | Classification | Rule | Status |
|---|---|---:|---|---|
| `reply` | `threadOriginatorGuid`, `threadOriginatorPart`, parent hash | `T1/C1`, HMAC `D0` | Parse exact `r:` contract. Missing parent defers association only. | Proposed after grammar fixtures |

### `MessageProto4`

| Proto field | Canonical target | Classification | Rule | Status |
|---|---|---:|---|---|
| `associated_message_emoji` | `Message.associatedMessageEmoji` | `T1/C1` | Apply only with a valid associated-message type and parent. | Proposed |
| `service` | validation only | `T1` | Must agree with supported message service when present. | Proposed |
| `schedule_type`, `schedule_state` | no verified canonical mapping | protected `N0` | Scheduled-message behavior is out of V2 scope. | Blocked |
| `groupId` | chat alias validation | `T1`, HMAC `D0` | May corroborate `chat_id`; it must not silently reparent a message. | Fixture required |
| `sent_or_received_off_grid` | no verified canonical target | protected `N0` | Preserve protected until satellite/off-grid semantics are tested. | Blocked |

## Edit and retraction mapping

`MessageSummaryInfo` is mutable semantic state on the original message. It is
not a replacement message and must not overwrite immutable original content.

| Summary field | Canonical target | Rule | Status |
|---|---|---|---|
| `ec[part][]` | `editedContent[part]` | Part key must be a validated decimal part. Decode every `MessageEdit.t` as attributed content. Order by validated edit date, retain duplicates idempotently by digest. | Proposed |
| `MessageEdit.d` | `EditedContent.date`, edit-part modified time | Validate finite Apple timestamp representation. Never substitute local now. | Proposed |
| `MessageEdit.bcg` | no safe target | Preserve protected. Meaning is unverified. | Blocked |
| `ep` | `editedParts` | Deduplicate validated non-negative parts. A listed part without usable edit content is a conflict or deferred subfield. | Proposed |
| `otr[part].lo/le` | `originalTextRange[part]` | Validate non-negative range and bounds against original content when available. | Proposed |
| `rp` | `retractedParts` | Retraction applies to the listed part only. It does not tombstone the whole message. Merge with server-authoritative newer summary state. | Proposed |
| `ams`, `ampt`, `amc`, `amb`, `amd` | no verified target | Preserve protected. | Blocked |
| `ust`, `hbr`, `oui`, `osn`, `euh` | no verified target | Preserve protected. `euh` contains handles and must never enter diagnostics. | Blocked |

The snapshot stores only per-part HMAC, revision/date, and content digest.
Edited plaintext belongs only in the canonical `Message.messageSummaryInfo`.

When an edit and retraction mention the same part, a sanitized Apple fixture
must establish precedence. Until then, preserve the raw envelope and quarantine
that part-level mutation rather than choosing by local arrival order.

## Attachment and media mapping

| Cloud source | Canonical target | Classification | Absent/default and merge rule | Status |
|---|---|---:|---|---|
| `cm.aguid` | `Attachment.guid`, logical HMAC, owner hash/part | `T1/C1`, HMAC `D0` | Required, non-empty. Parse owned form safely. | Proposed |
| `cm.mimet` | `Attachment.mimeType` | `T1/C1` | Validate bounded MIME syntax. Absent preserves. | Proposed |
| `cm.t` | `Attachment.uti` | `T1/C1` | Bounded identifier. Absent preserves. | Proposed |
| `cm.tn` | `Attachment.transferName` | `T1/C1` | Treat as display name, sanitize path separators for local materialization. | Proposed |
| `cm.tb` | `Attachment.totalBytes` | `C1/D0` | Non-negative maps directly. Negative means unknown and must not become zero. | Proposed |
| `cm.ig` | `Attachment.isOutgoing` | `C1` | Apply present boolean. | Proposed |
| `cm.sdt`, `cm.cdt` | snapshot timing evidence | `D0` | Negative values are valid wire values. Canonical `Attachment` currently lacks date fields. | Snapshot only |
| `cm.st` | no current canonical transfer-state field | protected `N0` or safe enum `D0` | Do not infer file availability from this value alone. | Blocked for entity |
| `cm.is` | sticker association validation | `C1/D0` | Current `Attachment` has no sticker field. Corroborate parent message only after fixtures. | Fixture required |
| `cm.ha` | no current canonical target | protected `N0` | Hidden attachment behavior is unverified. | Blocked |
| `cm.fn`, `cm.pathc` | no local filesystem authority | `T1`, protected raw | Never materialize to the supplied Apple path. It may be retained only as transient compatibility data. | Blocked for path |
| `cm.vers` | schema compatibility evidence | `D0` | Unknown version should preserve protected record and block unsafe media apply. | Proposed |
| `cm.mdh` | weak source checksum hint | `D0` | It is only an observed MD5 prefix. Do not use as sole integrity proof or identity. | Validation hint only |
| `cm.aui.pgens` | no current canonical target | protected `N0` | Preview generation meaning is not established. | Blocked |
| `cm.ui.file-size`, UTI, MIME, name | validation against outer metadata | `T1/D0` | Normalize `NumOrString` without panics. Mismatch is diagnostic-safe conflict metadata. | Proposed |
| `cm.ui.inline-attachment`, `message-part` | native inline media source and part validation | native `N0`, part `D0` | Materialize bounded bytes outside transaction and verify owner/part. | Proposed after fixtures |
| `cm.ui.mmcs-*`, `decryption-key` | native MMCS downloader only | `N0` | Never cross FRB or enter canonical metadata. | Native only |
| `lqa: Asset` | verified protected media source | native `N0`, protected ref `D0` | Download, authenticate, and atomically stage outside ObjectBox transaction. | Proposed after media adapter |
| verified final file | canonical attachment path/file state | `C1` | Rename staged file atomically, then link file and entity in the canonical transaction or recovery journal. | Proposed |

The current attachment mapper stores the raw CloudKit record ID in
`Attachment.metadata["cloud"]`. V2 must use the protected record map instead.
The current upload helper also invents a macOS path ending in `test.png` and
uses current time for several fields. Those guessed upload defaults do not
define incoming canonical semantics.

## Proposed redacted FRB DTO contract

The following is contract pseudocode. It intentionally does not reuse the
generated raw CloudKit models.

```text
CloudCanonicalMutationDto
  scopeFingerprint: String                 // D0
  generation: u64                          // D0
  changeId: String                         // D0
  kind: CloudEntityKindDto                 // D0
  mutationKind: Upsert | Tombstone         // D0
  serverRecordIdHash: String               // D0
  logicalEntityKeyHash: String             // D0
  parentLogicalKeyHash: String?            // D0
  aliasKeyHashes: List<CloudAliasDto>       // D0
  etagHash: String?                        // D0
  serverCreatedAtMillis: i64?              // D0
  serverModifiedAtMillis: i64?             // D0
  protectedRawEnvelopeReference: String    // D0
  snapshot: CloudCanonicalSnapshotDto?     // D0, content-free
  payload: CloudCanonicalPayloadDto?       // T1, upsert only
  tombstone: CloudCanonicalTombstoneDto?   // D0, tombstone only
```

Concrete payload variants:

```text
CloudCanonicalChatDto
  guid, chatIdentifier, groupId, originalGroupId, service
  style
  participantHandles
  displayName + displayNameState
  lastAddressedHandle + state
  groupVersion + state
  lastSeenMessageGuid + state
  groupPhotoGuid + state
  verifiedGroupPhotoLocalReference + state

CloudCanonicalMessageDto
  guid
  chatAliasKeyHash
  senderHandle
  createdAt
  error
  service
  subject + state
  text + state
  attributedBodies + state
  balloonBundleId + state
  decodedExtensionPayload + state
  effect + state
  readAt + state
  deliveredAt + state
  knownFlags
  association: none | sticker | reactionAdd | reactionRemove
  parentGuid, parentPart, parentKeyHash
  associatedRangeLocation, associatedRangeLength
  replyParentGuid, replyPart, replyParentKeyHash
  edits, retractedParts
  associatedEmoji + state

CloudCanonicalAttachmentDto
  canonicalGuid
  ownerMessageKeyHash
  ownerPart
  uti + state
  mimeType + state
  transferName + state
  totalBytes + state
  isOutgoing + state
  verifiedLocalFileReference + state

CloudCanonicalGroupPhotoDto
  chatKeyHash
  photoKeyHash
  photoGuid
  verifiedLocalFileReference
```

Contract requirements:

- DTOs implement a fixed redacted `Debug` string and no content-bearing
  `Display`.
- DTOs have no JSON, plist, map, analytics, or persistence conversion.
- Raw record IDs, account IDs, PCS data, MMCS data, `Asset`, and raw CloudKit
  objects are absent from the DTO types.
- Payload fields are immutable for the duration of the Dart call.
- Dart consumes the payload immediately. It may copy values only into existing
  canonical `C1` entities.
- Errors expose only an allowlisted category, retry hint, and safe code.
- Native code clears temporary plaintext byte buffers where practical after
  bridge transfer and after protected re-encoding.
- The bridge schema is versioned. Unsupported schema versions defer or
  quarantine without a partial write.

## Canonical apply transaction

Network, PCS, protobuf/plist decoding, content hashing, MMCS download, and file
materialization happen before the ObjectBox transaction.

The synchronous canonical transaction must:

1. revalidate scope, generation, and coordinator lease;
2. check the applied `changeId`;
3. resolve primary and alias HMAC identities;
4. verify required parent entities or write a content-free deferred dependency;
5. read the existing content-free semantic snapshot;
6. run deterministic merge policy;
7. write the transient DTO into the existing canonical `Chat`, `Message`,
   `Handle`, or `Attachment` entities;
8. write the merged `D0` snapshot and record-map entry;
9. mark the inbox event applied;
10. commit all ObjectBox changes atomically.

No `await`, network call, native call, file read, hash calculation, media decode,
or UI notification is allowed inside that transaction.

The transaction must respect local user locks such as `lockChatName` and
`lockChatIcon`. A local UI preference is not CloudKit merge state.

## Sanitized fixture matrix

Every fixture must use synthetic GUIDs, handles, names, bodies, filenames,
record names, keys, and URLs. Test output must assert that none of those
sentinels appear in logs, snapshots, record maps, exceptions, or `toString`.

| Fixture | Required assertion |
|---|---|
| minimal direct chat | Primary chat and service/chat-identifier alias hashes resolve; no display-name/participant identity fallback. |
| group chat create with `pv` | Participants, group name, and aliases apply once; replay is a no-op. |
| higher group `pv` | Authoritative mutable group fields update; immutable identity does not. |
| equal `pv`, same digest | No-op. |
| equal `pv`, different digest | Content-free conflict, no guessed winner. |
| missing `pv` on existing group | Identity mapping may update, group-mutating fields preserve. |
| group photo asset and matching GUIDs | Verified protected file reference reaches canonical photo apply; secrets remain native. |
| mismatched root/property photo GUIDs | Photo submutation quarantines without corrupting chat. |
| explicit group photo clear | Clears only with proven presence encoding, authoritative version, and unlocked local icon. |
| normal text message | Attributed and plain text map, replay does not duplicate. |
| message before chat | Defers, then applies exactly once after alias resolution. |
| duplicate message with same immutable digest | No-op plus metadata merge. |
| duplicate GUID with different immutable body | Quarantine immutable-content conflict. |
| reaction add `p:0/<guid>` | Canonical parent GUID is bare GUID, part is 0, parent hash resolves. |
| reaction removal in 3000 range | Reduction removes matching reaction without deleting parent. |
| reaction before parent | Durable content-free dependency, successful replay after parent. |
| malformed `p:` wrapper | Quarantine without array bounds exception or plaintext log. |
| unknown reaction type or out-of-range enum index | Preserve protected, no reaction row. |
| sticker with parent and attachment | Remains associated message, not reaction; attachment link resolves. |
| reply `r:0:<guid>` | Separate reply parent and part map. |
| malformed reply | Association is deferred/quarantined without dropping base message. |
| edited part with `ec`, `ep`, and `otr` | Attributed edit, range, timestamp, and digest map idempotently. |
| multi-edit replay in different page grouping | Deterministic edit order and no duplicate revision. |
| retracted part in `rp` | Only listed part is retracted. |
| edit and retract same part | No guessed precedence until fixture-defined policy. |
| URL balloon | Base message remains usable; unsupported extension stays protected. |
| unknown extension payload | No payload bytes or content in warning/error text. |
| attachment `at_0_<guid-with-underscore>` | Parser retains entire suffix and correct owner. |
| standalone attachment GUID | Stable attachment identity with unresolved owner, no guessed message. |
| MMCS attachment | Key, signature, URL, and owner never cross FRB; verified file does. |
| inline attachment | Bounded bytes materialize and link to validated part. |
| negative attachment dates and size | Decode does not panic; size becomes unknown, date preserved as wire evidence. |
| `NumOrString` numeric/string/bool variants | Valid variants normalize safely; malformed value quarantines field or record per criticality. |
| omitted optional field versus explicit empty | Preserve versus value semantics remain distinct. |
| omitted `change_type` with valid record | Classified as upsert by validated record shape. |
| tombstone with server time | Prior record map resolves authoritative delete. |
| tombstone without server time | `deletedAt` remains null; no local time is invented. |
| tombstone without record map | Durable `tombstoneMappingMissing`; no entity guess or delete. |
| PCS unavailable | Retryable, protected inbox retained. |
| unknown native/upstream error | Retryable safe failure, not malformed quarantine. |
| process death after entity write attempt | Entity, snapshot, map, and replay marker all roll back or all commit. |
| account switch during decode | Scope revalidation rejects mutation before canonical write. |

## Current blockers

### Canonical ObjectBox adapter boundary

`ObjectBoxCanonicalSemanticEntityAdapter` now provides the synchronous,
default-off boundary used by a future semantic gateway composition. It is not a
general-purpose importer and must not be enabled by configuration alone.

The adapter requires all of the following for any transaction:

1. an exact active `CloudSyncScope` and rebootstrap generation supplied from
   already-loaded process state;
2. a synchronous, scope- and generation-bound resolver from a verified native
   transient DTO HMAC identity to a canonical plaintext GUID;
3. an explicit semantic-apply enablement flag; and
4. no network, filesystem, platform-keystore, hash, async, or UI work while
   the ObjectBox transaction is open.

Today it can only update a non-null display name on an already-existing,
unlocked `Chat`. It never creates chats from participant/display-name hints,
never writes a raw CloudKit ID or protected reference into a canonical entity,
and refuses message, attachment, reaction, group-photo, profile, and
tombstone mutations. This narrow implementation is intentional: the current
payloads do not carry the proven canonical GUIDs, field-presence bitmap,
direction, timestamps, relationship data, or materialized-media state required
for safe writes. The identity resolver is a seam for the future native DTO, not
a hash-reversal mechanism or a durable plaintext mapping table.

The next adapter expansion requires the typed native DTO and the fixture gates
below. Until then, a caller receives a typed safe failure and the enclosing
transaction rolls back atomically.

1. `rust/src/cloud_sync_semantic_decoder.rs` returns only an identity projection.
   It does not produce the rich canonical DTO or field-presence bitmap.
2. The generated/defaulted Rust record models can collapse missing required
   fields into empty or zero defaults. V2 must validate raw field presence
   before typed construction.
3. The existing Dart semantic payloads contain only a small subset of message,
   chat, attachment, and reaction data.
4. ~~`CloudSemanticTombstone.deletedAt` is required in Dart even though a valid
   server tombstone can omit its timestamp. It must become nullable.~~
   **Closed.** `deletedAt` is `DateTime?` and covered by Rust
   `tombstone_supports_present_or_missing_server_time` plus Dart cases in
   `cloud_inbox_applier_test.dart` and `cloud_sync_release_validation_test.dart`.
5. Dart currently treats `CloudFailureCategory.unknown` as non-retryable. An
   unclassified native/upstream failure must remain retryable unless the native
   boundary positively identifies malformed permanent data.

   **Correction (2026-08-06): do not fix this by flipping the enum.** The
   bounded-retry behavior this asks for already exists, assembled from three
   places: `CloudInboxApplier` only *returns* a quarantine without persisting
   it, and `CloudSyncEngine` re-promotes an `unknown` quarantine to retryable
   while `attemptCount + 1 < maximumUnknownAttempts`. Because
   `cloud_sync_engine.dart` gates on `error.category.isRetryable` first, making
   `unknown` unconditionally retryable would bypass `maximumUnknownAttempts`
   and turn a bounded retry into an unbounded one.

   The real remaining defect is narrower and belongs with the three-way
   outcome work: Rust classifies an unrecognized `PushError` as
   `RetryableUpstreamFailure`, but `CloudSyncProtectedFailureCategory` has no
   such member, so `native_protected_cloud_sync_transport.dart` collapses it to
   `CloudFailureCategory.unknown`. A positively-retryable native failure is
   therefore capped at `maximumUnknownAttempts` and then quarantined. Closing
   it means carrying a distinct retryable-native category across the bridge,
   which requires a binding regeneration.
6. Current legacy message download stores `p:<part>/<guid>` directly in
   `associatedMessageGuid` and derives the part from the child attributed body.
   This breaks canonical reaction-parent lookup. The V2 Rust converter is
   correct; `lib/database/io/message.dart` still does both.
7. ~~Current reaction type indexing can throw if Apple supplies an unknown value
   inside the broad numeric range.~~ **Closed for the legacy download path.**
   `ReactionTypes.fromAssociatedMessageType` bounds the lookup and returns null
   for an unnamed type, so the message still syncs without a reaction row.
   Covered by `test/helpers/reaction_helpers_test.dart`, which sweeps the whole
   2000-3999 range. The V2 Rust converter already used narrow ranges.
8. ~~Current attachment owner parsing uses fixed underscore indexes and can
   truncate identifiers.~~ **Closed.** `lib/utils/attachment_guid_utils.dart`
   parses the prefix, one decimal part, and the whole remaining suffix, and is
   now the single implementation behind all five former copies plus
   `Attachment.applyFromCloud`. Covered by
   `test/utils/attachment_guid_utils_test.dart`.
9. Current attachment mapping stores a raw CloudKit record ID in canonical
   attachment metadata rather than using the protected record map.
10. Current chat fallback identity uses display name and participant sets.
    Deterministic V2 reconciliation must not use it.
11. Current chat apply stores a serialized decrypted `CloudChat` in
    `cloudData`. V2 has no reviewed protected replacement for lossless
    round-trip upload.
12. Root versus property group-photo GUID precedence and explicit-clear
    encoding are not fixture-proven.
13. No V2 media adapter currently turns native `Asset` or MMCS state into an
    authenticated protected local file reference.
14. URL balloons, unknown extension payloads, scheduled/off-grid fields, legacy
    group aliases, and several summary properties have no safe canonical
    mapping.
15. The ObjectBox semantic gateway that atomically writes canonical entities,
    snapshots, mappings, dependency rows, and replay markers is not implemented.
16. Sanitized real-device fixtures for parent grammar, group versions, clear
    semantics, edits, retractions, and media have not passed on Android,
    Windows ARM64, and Windows x64.

## Implementation gates

Implement in this order:

1. Freeze sanitized fixtures and required-field presence rules.
2. Add private native canonical DTOs and tests without exposing FRB symbols.
3. Review redaction and secret-lane tests, then expose only the typed DTO
   facade through FRB and regenerate bindings once.
4. Expand Dart transient payloads and implement the synchronous ObjectBox
   canonical gateway.
5. Run replay, rollback, account-switch, parent-ordering, media-integrity, and
   cross-architecture fixture suites in read-only shadow comparison.
6. Enable semantic apply only behind a kill switch and staged validation plan.

No save, delete, tombstone apply, or production composition should be enabled
merely because the field mapping compiles.
