---
type: design_proposal
title: Find My People secure-fetch implementation proposal
description: Concrete change set, contract reading, live unknowns, validation plan, decisions needed.
tags: [findmy, secure-fetch, proposal]
timestamp: 2026-09-16
---

# People secure-fetch proposal (for parent review, no code yet)

## Goal
Elicit the missing People relationship keys, fetch her live location, join it onto the roster entry in memory. No CloudKit persistence.

## Change set (rustpush/src/findmy.rs at 5862be3)
1. Key elicitation: new function beside make_searchparty_request (line 1427) posting intent distributeKeys, mode proactive, empty ids. Trigger is explicit user refresh only, never automatic at startup. Open: probe-host path or production-daemon refresh path.
2. Key delivery: arrives through FindMyClient::handle (line 2282) fmf path as a new payload variant. New match arm beside MappingPacket (line 2418): verify, store advertised id plus blob in a NEW in-memory People key store, ack with existing 244 app-ack.
3. Location fetch: new function modeled on sync_item_positions_with_writer_permit (line 1507) with People advertised IDs against the gateway fetch path, same P-224 ECDH decrypt as Items, newest wins, in-memory roster join.

## Contract reading
The single-pass contract test pins one receive_message site and one observer use inside handle. This adds neither, so no amendment needed on that reading; new match arms are a shared-source change needing CloudKit coordination. Parent review to confirm.

## Live unknowns (need bounded window)
People advertised-ID derivation, exact People fetch shape, where keys surface after mapping import.

## Validation plan
Fork CI compile plus mocked-242 unit tests, lane-signed runtime, one bounded window proving 242 delivery and roster join. Rollback is plain revert; persistence untouched.

## Decisions needed
1. Confirm handle-arm approach with no amendment, or require amendment first.
2. Approve trigger point: manual refresh only, and from which path.
3. Live window only after 1 and 2 plus CloudKit coordination.
