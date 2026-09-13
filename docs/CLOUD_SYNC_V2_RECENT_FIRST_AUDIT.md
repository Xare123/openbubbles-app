---
type: Decision Record
title: CloudKit V2 recent-first catch-up audit
description: Preserve remote cursor order; qualify bounded local visibility reconciliation before prioritizing retained replay.
resource: openbubbles-app
tags: [cloudkit, catch-up, dependency-replay, presentation, audit]
timestamp: 2026-09-12
---

# Priority 1 follow-up: local chat-list reconciliation

The original audit below is retained as baseline evidence. Its three chat-list
characterization tests have now been replaced by desired-behavior tests. The
separate follow-up patch changes only `lib/services/ui/chat/chats_service.dart`
at runtime. It does not implement transcript reconciliation, replay priority,
server direction changes, or background scheduling.

`ChatsService.onInit` now treats both Chat and Message ObjectBox notifications
as hints. `_requestVisibilityReconciliation` coalesces them behind one in-flight
scan and a dirty-again bit. `init` fences the scanner during existing initial
loading, then reconciles again so a stale initial snapshot cannot permanently
erase an admission. `onClose` invalidates every pending continuation.

`readVisibilityPage` returns at most 15 eligible chats, with a closed query per
page and event-loop yields between nonempty pages. Local keysets cover ordered
pins, remaining pins, and ordinary chats, using cached latest-message date and
ID as a tie-breaker, not an insertion high-water mark. Null dates are visited
too. Each page publishes one sorted list only if there are additions. Stable
scans remove formerly eligible entries while preserving in-memory drafts never
admitted from the database. Existing archive/unknown-sender helpers remain in
charge of their views. This is not a remote cursor or a new sync lane.

`ensureVisibilityController` checks the real `ChatManager` before creation:
reusing `createChatController` indiscriminately would reset active/alive flags.
Unchanged list objects/controllers remain intact. The reconciliation path does
not call `init`, `Chat.save`, the backend, native services, or notifications.
Existing initial-loader startup integrations are not invoked by DB hints.

Boundedness is precise: at most 15 Chat entities are returned/hydrated per
page, with one scanner, no growing OFFSET, no full-list `find`, and no list
emission for no-op hints. It is not a constant-time native scan guarantee.
ObjectBox still evaluates the existing eligibility backlink and sort; the
existing `Chat.sort`/preview hydration and full in-memory list sort also cost
work. Null/stale date caches cannot promise first-page true message recency;
the canonical V2 projection's existing monotonic cache remains a prerequisite.
No cache repair or schema migration is added here.

Remaining qualification: rendered app/frame latency on supported hardware,
production-size messages/attachments, and real startup integration. Tests cover
the real service scheduler and ObjectBox queries; the initial-loader race test
substitutes only its slow list-producing body to avoid startup native calls and
pruning. Most admission tests substitute controller construction; separate
cases exercise actual new controller creation and existing active-controller
reuse. No device or live-account test was authorized.

Follow-up validation: 155 tests passed with Flutter 3.44.8 x64, `--no-pub`,
ObjectBox 5.3.2 x64, and concurrency 2: 16 chat-visibility tests, two existing
chat-date repair tests, and 137 coordinator tests including the original
200-record/197-retained model. Targeted analysis of the changed service and
test reports no issues; `git diff --check` passes. The 3000-chat synthetic
fixture returned all 3000 GUIDs exactly once, newest cached dates first, via
203 queries with at most 15 results each. Final run: 2743 ms total, slowest
chat-page query 19519 microseconds, in the desktop test harness. This is not a
device frame benchmark and mostly uses a controller-construction observer.
The separate real-controller admission test recorded zero ObjectBox writes,
zero backend calls, and zero native service calls. Duplicate no-op hints caused
zero list emissions. An initial side-effect assertion compared UTC/local
DateTime representations; it was corrected to compare epoch milliseconds.

Integration order: retain the reference base, then audit commit `404aa522a`,
then this separate priority-1 follow-up. Parent review and authorized rendered
runtime qualification precede release. No parent integration, push, APK build,
credentials, schema change, native pin change, or device operation occurred.

# Original audit decision

No production runtime patch in this change. Deliver source audit, executable
baseline characterization, and a proof-gated design. First fix local visibility
reconciliation, then measure dependency-ready replay. Do not flip server
direction, reset/date-seek tokens, skip pages, or introduce a second remote lane.

The honest target is **newest usable among locally available records**, not
newest account-wide messages before the server has delivered them. History
fetch and projection are separate progress dimensions. Neither an empty remote
page nor an applied-change counter proves a complete, visible conversation.

## Isolation and evidence scope

- Reference: `agent/cloudkit-v2-update-seam`, app commit
  `883f001868ac64a160c20018b2fb46e3aedb029e`.
- Independent local clone: `C:\Codex\OpenBubblesReview\worktrees\cloudkit-v2-recent-first-audit`,
  branch `agent/cloudkit-v2-recent-first-audit`. Clone used `--no-hardlinks`;
  no shared Git worktree metadata. Local pinned dependency clones only:
  rustpush `b9ede83378195c56e17fa6e4d7d4826693f1c22e`, telephony_plus
  `5210e940dd92ae371f8c74eaeb552d0704034244`.
- Read applicable `C:\Codex\AGENTS.md`; no additional AGENTS.md was found in
  the reference checkout, fork, or cloned dependency source trees.
- Parent has seven generated-plugin edits and dirty rustpush source, plus a
  broken nested-submodule path. None was repaired, copied as implementation,
  or modified. This audit targets committed source, not those local overlays.
  At final readback the parent HEAD still matched, but its connection treemap
  and investigation log also had concurrent edits. This task made no writes
  there and does not certify other actors' parent changes as unchanged.
- No credentials, private profile/database, device, APK build/install, push,
  authenticated probe, or background job was used. Tests use synthetic stores.
  Public Apple documentation and checked-in historical reports are supporting
  evidence, not current live-server verification.

## Source audit

Paths below are repository-relative; line numbers refer to this base unless
the path is one of this change's new tests.

| Layer / symbol | Evidence and consequence |
| --- | --- |
| `rustpush/src/icloud/cloudkit.rs:2115`, `FetchRecordChangesOperation::new_with_limit` | V2 requests `newest_first=false`, all change kinds, a clamped record limit, and the exact supplied opaque continuation. `fetch_page_with_limit_and_access` preserves `response.change` and `sync_continuation_token`; incomplete pages must make token progress. This proves client request construction, not oldest message-date ordering. |
| `rustpush/src/imessage/cloud_messages.rs:3516`, `sync_records_page_with_container` | Uses lookup-only read access, `NO_ASSETS`, and `map_ordered_page_changes`. No message-date sort or date query is applied. `sync_*_page_for_read_authentication` validates the permit around access. |
| `rust/src/cloud_sync_native_fetch.rs:4123`, `decode_previous_checkpoint` / protected fetch | Unprotects the existing scoped checkpoint and forwards it. Native ceiling is 200 changes, not a guaranteed page size. Protected page leases retain source envelopes and candidate tokens. |
| `rustpush/src/imessage/cloud_messages.rs:3556`, `sync_records_without_deadline` | Legacy explicitly asks `newest_first=true`, then returns a `HashMap`, losing response event order within the page and coalescing duplicate record keys. That flag is evidence for apparent recent-first behavior, not a V2 continuation contract. |
| `lib/services/rustpush/rustpush_service.dart:4653`, legacy message loop | Legacy fetches chats and attachments before messages, repairs missing chat references, and has a message-time cutoff that can stop history. Those different prerequisites also affect apparent speed. Do not transplant its cutoff, direct mutation, or duplicate-delete behavior. |
| `cloud_sync_manual_semantic_pull_sampler.dart:160,639,1406` under `lib/services/rustpush/cloud_sync/` | Chats, then messages, then attachment metadata. Per zone/pass: four requests of at most 50, total 200 fresh changes; up to 150 retained replay attempts, 350 inbox budget, 200 fresh reserve. A reported 200 here can be four pages, not one live 200-record response. Actual report/probe origin must be established first. |
| `cloud_sync_engine.dart:790,1304,1502,1617,1925` | Recover retained barriers, bounded retained replay, pending inbox prefix, then sequential fetch/journal/apply. Pending candidate token promotes only after the page is terminal. Unknown/conflicting nonterminal predecessors stop later work. Explicit retention can release remote progress without pretending projection succeeded. Yield occurs after durable row state. |
| `objectbox_cloud_semantic_store_gateway.dart:2950,3009` | Applied floor and remote token differ. `_advanceContiguousApplied` does not count retained saves as canonical application; `_promotePendingFetchedTokenIfTerminal` accepts applied or explicitly retained rows. Never advance the applied floor to an arbitrarily selected recent row. |
| `objectbox_cloud_semantic_store_gateway.dart:650,470` | Retained candidates use ascending `updatedAtMs`, then fetch sequence. Failed attempts rotate durably via `max(now, old+1)`. This is fairness/attempt age, not sent time. Selection is native-query bounded before materialization. |
| `cloud_inbox_applier.dart:1042,1198,1861,1925` | Retained rows decode again, bind transient identity, revalidate active scope and fenced transactions, and use the existing merge/parent policy. Message snapshot parents mean reply/association parents, not chats. Chat ownership is a separate canonical dependency. Identity leases release before event-loop yields. |
| `cloud_sync_manual_semantic_pull_sampler.dart:829` | Exact retained sweep starts only after persisted three-zone remote-head evidence. Windows contain at most 32 rows, are bounded by captured fetch sequence, revalidate identity/checkpoints, and use up to three rounds to resolve late parents. Deep/reverse dependency chains may remain. No fresh network transport is created by the sweep. |
| `objectbox_canonical_semantic_entity_adapter.dart:1600,1761,1789,1886` | Messages require a uniquely proven chat under the proper dependency generation; ambiguous aliases cannot create placeholder routing. Replies require an existing same-chat parent. Reactions require the base message. Owned attachments require exact normalized GUID/part and message ownership, with no silent reparenting. Text does not wait for media bytes; metadata/body materialization are separate. |
| `cloud_sync_chat_presentation_repair.dart:14`; adapter `:1779` | Canonical message commit updates the chat's latest-date cache monotonically. Older backfill must not move a newer conversation backward. Existing maintenance and backfill tests cover this; no new cache fix is needed. |
| `lib/database/io/chat.dart:276,481,2343` | Normal message reads use descending message date; chat reads use pinned status then cached latest message date. `Chat.sort` respects pinning and latest message date. ObjectBox insertion ID is not conversation recency. |
| `lib/services/ui/chat/chats_service.dart:39` | Real watcher ignores zero-to-positive growth, chooses only `findFirst()` on a count increase, and sorts that query by descending Chat ID. A low-ID chat becoming eligible can select an already visible high-ID chat. Three new synthetic subscription tests reproduce these omissions. |
| `lib/services/ui/chat/chat_lifecycle_manager.dart:18` | Existing controllers observe Chat changes and update/sort existing list entries. That does not admit a missing conversation whose controller was never created. |
| `lib/services/ui/message/messages_service.dart:55,173` | New-message watcher uses ID-descending count delta, suppresses delivery from zero and while `isFetching`, yet still advances `currentCount`. Async listeners can overlap across attachment waits. These are source-level risks requiring dedicated race/scroll tests, not proven device symptoms here. Do not simply date-sort a count-delta query: older inserted rows could then be missed. |
| `lib/services/rustpush/rustpush_service.dart:10147` | Android background composition disables the exhaustive at-head sweep; ordinary bounded replay remains. `cloud_sync_android_work_policy.dart` describes dormant/guarded scheduling. Source existence is not proof that full history will automatically complete in background. |

Apple's public record-zone API defines server tokens as opaque per-zone
progress and warns against inferring order from token contents. It does not
specify the private Manatee `newest_first` field or compatibility when switching
direction midstream. [Apple record-zone changes documentation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation?language=objc).

### Existing contrary evidence

The checked-in September 7 report at
`docs/cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_THROUGH_2026-09-07.md:1039`
records: existing checkpoint returned zero rows with either direction;
fresh newest-first returned 200 rows including an exact saved-message match.
The probe at `rust/src/cloud_sync_native_fetch.rs:4252` explicitly does not
adopt those results. This is historical single-scenario evidence, not a live
test performed in this audit. It neither proves a direction flip is useful on
the existing cursor nor validates a complete second bootstrap lane.

## Why 200 records may produce only a few visible messages

For one all-save synthetic batch, the new engine test sets 197 dependency
results to `canonical_message_chat_unavailable`, with three independent saves
eligible. The unchanged real engine visits all 200 in sequence, reports three
applied and 197 retained, keeps every protected payload reference, and commits
the exact next token. Applied floor remains zero because the first retained row
is not projected. A new coordinator resumes at that token; even a terminal empty
response leaves the 197-record debt and degraded status intact.

This is an executable model, not a measurement of the user's live data. The
fake applier does not create real Messages or prove native decoding. Separate
ObjectBox adapter/gateway suites validate missing-chat retry, parent ownership,
transaction rollback, replay after reopen, and fair rotation.

In real data, add more reductions: repeated versions of one logical message,
reaction records, unsupported or out-of-scope saves, tombstones, missing reply
parents, ambiguous chats, and attachment metadata awaiting its owning message.
`fetched` in the engine is newly inserted journal rows, not necessarily raw
response length; `applied` includes replay and non-message changes, not new
visible-message count. Finally the list watcher may omit otherwise usable chats.

Minimal causal model:

`sequential remote pages -> durable records -> proven parents + semantic merge -> canonical rows -> UI reconciliation`

Optimizing only the first arrow cannot repair the other gates. Sorting existing
rows cannot reveal records that have not been delivered.

## Chosen implementation order and required proof

### 1. Bounded local visibility reconciliation, first priority

Replace count-delta admission in `ChatsService.onInit` with an idempotent,
coalesced reconciliation of eligible canonical chat identities. Preserve
nondeleted/datable-message eligibility, routing-stub and telephony filters,
pinning, archive/unknown-sender view semantics, drafts, selection and controller
ownership. A newly eligible chat can have any ID. Zero-to-positive and batched
changes must reconcile all affected chats, not just the count difference.

Recommended shape: a single in-flight read/reconcile with a dirty-again bit and
service-generation fence. Publish a bounded recent page first (reuse the
15-chat presentation batch as the initial candidate), then reconcile remaining
eligible identities in bounded pages. Revalidate when DB notifications arrive
during scanning; do not let a stale scan overwrite newer UI state. Retain
existing controllers for unchanged GUIDs and deduplicate admission. Listen to
the canonical Chat/Message changes needed for first-message eligibility and
same-count swaps. Do not scan every chat synchronously after every record.

For open transcripts, coalesce behind initial/history loading and reconcile
stable message identities after the load, rather than consuming suppressed
count deltas. Preserve the user's scroll anchor; older backfill is not a new
live-message notification or reason to scroll to the bottom. Do not use
`Chat.save`, remote service fallback, or writer admission just to refresh UI.

Proof before merge: replace the three characterization expectations with full
admission; add widget-level first-empty, batch, low-ID-late-parent, same-count
replace, deletion/filter, pin, duplicate-event, dispose/reopen and initial-load
race cases. Verify no controller duplication, native/remote calls, notification
spam or scroll jumps. Measure frame latency and bounded query work under a
multi-thousand-record synthetic import. Then inspect the actual rendered list
and open transcript under separately authorized runtime validation.

Why not a quick patch now: removing `currentCount != 0` fixes only one omission;
using `newCount-currentCount` highest IDs still misses old chats becoming
eligible. A full query on every record trades omission for import-time UI load.
Safe reconciliation crosses async loading/controller lifecycle and needs those
tests, so it is not a well-supported one-line production change.

### 2. Measure and selectively accelerate already-retained dependency replay

Keep one remote token chain and the fresh-fetch reserve. Instrument only fixed
counters and elapsed time: fresh/raw/journal counts separately, new canonical
message count versus updates/reactions, eligible chat count, replay examined /
resolved / still blocked, and UI publish delay. No plaintext IDs/content or
fine-grained message timestamps in telemetry. Establish where latency occurs
before changing retry allocation.

If ready children wait materially behind blocked rows, qualify a bounded
dependency-ready hint queue within the existing coordinator, not a new remote
lane. Hints must bind account, zone, checkpoint generation, change identity and
protected source. A hint never proves readiness: re-decode and use all existing
ownership/parent/merge checks inside the transaction. Parent commits may wake
their exact retained children; never invent chats or erase failed debt.

The current raw inbox lacks a trustworthy message-sent-time scheduling key.
`CloudFetchedChange.serverModifiedAt` and local retry age are not that key.
An initial implementation should prefer known ready dependencies and current
visible conversation demand, preserving the fair fallback. True message-date
priority requires a separately reviewed protected hint/index or a bounded
transient decoded window. Rank only independent, proven-ready work; keep
per-entity versions and ancestry safe. Never change inbox sequence, pending
token promotion, or fixed-window sweep cursor to reflect priority order.

Proof: child-before-parent across pages/zones, chains longer than three,
duplicate versions, conflicting aliases, stale generations, rollback, account
switch, cancellation, process restart, and starvation under continuous new
traffic. Preserve guaranteed fresh-fetch and older-replay capacity. Show final
canonical state equals the unprioritized run, with earlier useful UI visibility.

### 3. Background completion and optional server-order research

Use the existing scheduler, account interlock, bounded pass/window budgets and
durable checkpoints. Keep reporting remote-head, retained-save completion and
media-body completion separately. A pass cap is resumable, not completion;
three projection rounds cannot promise arbitrarily deep dependency resolution.
Prove interrupted/resumed work and foreground responsiveness before claiming
that full history continues automatically in background. Do not enable dormant
WorkManager paths as part of a presentation patch.

Only reconsider server direction after separately authorized isolated-account
evidence: complete multi-page runs in each mode, stable event/version coverage,
direction-bound cursor semantics, terminal-to-incremental behavior, concurrent
creates/edits/deletes, duplicate/change ordering, expiry/reset and restart.
Persist paired protected-token and DB evidence. One fresh 200-row probe and a
field name are insufficient. Public API docs cannot supply this private proof.

## Rejected approaches

- `newest_first=true` on an existing V2 cursor: continuity and ordering unproven.
- Fresh second lane or newest-only bootstrap: lacks coverage/dedup/reconciliation
  proof; more state and potential history holes.
- Date cutoff, date-seeking, discarded pages, token replacement: violates full
  history and opaque-token continuity.
- Reverse the pending inbox or exact sweep: causal barriers and ascending
  window progress are not presentation sort keys.
- Sort retained rows by server modification date, insertion ID or retry time
  and call it message recency: wrong semantics; may starve older parents.
- Force child projection, synthesize chat aliases or wait for every attachment
  byte: breaks ownership or delays usable text unnecessarily.
- Increase page/replay limits without measurement: more decode/UI work per
  pass, no guarantee of more usable messages.

## Validation and integration

426 tests passed across six focused files: engine, manual semantic sampler,
ObjectBox semantic gateway, canonical adapter, chat-date repair, and new actual
chat-subscription characterization. Baseline engine alone previously passed
136 tests. Four new tests were added (one engine model, three UI baseline cases).
The initial DB run failed with ObjectBox DLL loader error 126 and cascading
uninitialized-store failures; rerun passed after adding the DLL's `lib`
directory to the test process PATH. No system PATH or dependency version changed.

Tests used installed Flutter 3.44.8 x64 with `--no-pub --concurrency=2` and
ObjectBox 5.3.2 x64. Ignored package metadata was reconstructed from the
reference's non-secret resolved dependency files, with relative roots targeting
this fork and shared installed package caches. No package download or APK build.
The final engine fixture was explicitly bound to the semantic persistence lane
and its targeted rerun passed (1/1). Targeted Dart analysis reported no errors
or warnings, with one pre-existing `prefer_const_declarations` info at engine
test line 327. `git diff --check` passed. End-of-task C: free space was 67.32 GiB;
fork test output was about 208 MiB including ignored Dart metadata. No user
data or parent artifacts were deleted. No child agents were created.

Native Rust compilation, full suite, real rendered application, live CloudKit,
device background scheduling and independent-client convergence were not tested.

Integration: review/cherry-pick this audit/test commit only after the reference
base is present. It changes no runtime feature flag, schema, native dependency
pin or app version. The UI tests intentionally record existing omissions; in a
future fix convert them to desired completeness assertions, do not preserve
the bug to keep them green. Qualify stage 1 separately before stage 2. Stage 3
requires fresh authority and evidence. No integration into the parent was done.
