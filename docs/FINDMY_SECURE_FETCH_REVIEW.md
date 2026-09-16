---
type: design_review
title: Find My People secure-fetch integration review
description: Production-handler map, Items reference path, and the missing People halves with contract boundaries.
tags: [findmy, secure-fetch, review]
timestamp: 2026-09-16
---

# People secure-fetch integration review (groundwork, no code, no live use)

## Production handler map (rustpush/src/findmy.rs at 5862be3)

- FindMyClient::handle at line 2282 is the single IDS ingress. It calls
  receive_message once for the fmf, fmd, and itemsharing-crossaccount
  topics, then runs the single-pass observer prefix on the decrypted result.
- itemsharing-crossaccount arms parse ItemSharingMessage: type 2 runs the
  share-acceptance workflow under a CloudKit writer permit, type 7 deletes
  remote records under the same permit.
- FMF/FMD arms parse FMFPayload. The only arm, MappingPacket at line
  2418, sends the 244 acknowledgement and calls daemon.import with the
  mapping-token URL. import at line 3039 only posts that URL for
  server-side association; it stores no key material.

## Items reference path (working today)

- sync_items at line 1005, positions at line 1507: advertised IDs derive at
  line 1548 as base64 of SHA-256 over the P-224 public key x coordinate.
- POST to findmyservice/v2/fetch at line 1652 with time window, then per
  report ECDH plus SHA-256 KDF plus AES-GCM decrypt, newest wins, joined via
  share_state circle secrets. Android Items locations prove this path live.

## Missing People halves (both, per the upstream protocol read)

1. Key acquisition: no distributeKeys proactive SearchParty POST exists, so
   no People relationship-key delivery is ever elicited.
2. Location fetch: no People fetch plus decrypt plus roster join exists. The
   Friends client only calls legacy initClient, refreshClient,
   selFriend/refreshClient, and import, none of which can yield her
   coordinates on either client.

## Contract and coordination boundaries

- test/services/findmy/find_my_single_pass_observer_contract_test.dart
  pins exactly one receive_message call site and one
  observe_ids242_single_pass use inside handle. People key delivery must
  therefore flow through handle; a second ingress point needs a
  parent-owned review amending that contract test first.
- New match arms, a People key store (advertised id plus private blob,
  in-memory join onto the roster, no CloudKit persistence), and any
  distributeKeys request shape are shared-source changes: coordinate with
  CloudKit task 01a098ec-c448-73a1-a73f-696d142de228 and hold implementation
  until after its window release plus parent review.
- Live unknowns unchanged: whether the sharing device answers a key request,
  what the server returns for this share, the People advertised-ID
  derivation, and the exact People fetch shape.
