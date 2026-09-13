# Engineering document history

## 2026-09-12

- **Implemented**: priority 1 local chat-list visibility reconciliation in the
  isolated recent-first audit branch. Bounded keyset pages, coalesced Chat and
  Message hints, startup/disposal fencing, and existing-controller retention.
  Replaced omission characterizations with desired-behavior tests. No remote,
  coordinator, retained replay, scheduling, or transcript changes. See the
  follow-up section in the recent-first audit for bounds and remaining gates.
- **Added**: recent-first CloudKit V2 audit at base `883f001868ac64a160c20018b2fb46e3aedb029e`.
  Runtime unchanged; synthetic dependency model and actual chat watcher
  characterization support bounded local reconciliation as the first gate.
