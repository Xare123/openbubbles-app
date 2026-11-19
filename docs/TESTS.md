# Test catalog

Use this catalog to locate the implementation and the tests behind a claim. Dates, exit states, counts and failure explanations belong in the [run index](../evidence/README.md). Exact historical Rust filters and counts are in the [run data](../evidence/run-data.json).

| Question | Test or source to read | Execution context |
| --- | --- | --- |
| Can typed equality collapse absent and empty field 31? | `present_empty31_is_not_the_same_predecessor_as_absent31` and `wire_readback_distinguishes_absent31_from_present_empty31`. [Outgoing stage tests](../source/app/rust/src/cloud_sync_message_update_stage.rs) | Integrated app Rust crate. Synthetic records. |
| What happens after a legacy stage reopens without its presence witness? | `legacy_v1_cold_reopen_without_field31_witness_cannot_claim_commit`. [Received stage tests](../source/app/rust/src/cloud_sync_received_message_update_stage.rs) | Integrated offline stage and protected-store fixture. |
| Does the API use the fetched original bytes? | `reconcile_consumer_uses_strict_fetched_original_wire_for_staged_classification` covers equal, changed and forbidden shapes and a typed-only fetch. [Consumer](../source/app/excerpts/classify_fetched_readback.rs) · [Test](../source/app/excerpts/classify_fetched_readback_test.rs) | Actual readback helper with a strict synthetic fetch. Issuance of admission by a real lookup is a separate boundary. |
| Does the selected native page retain original wire and refuse a field 33 page atomically? | Read the raw parser, aligned sidecar and original-pair check. Supplemental tests cover multi-record size, record count and whole-page byte limits. [Parser and tests](../source/native/paging) · [Original regression outcomes](../evidence/run-data.json) | Native synthetic including mocked transport. The original mocked account transport stays local. Separate Dart store cases exercise refusal and reopen. |
| Is optional field 34 metadata preserved? | `record34_timestamps_preserve_original_record_and_typed_content` and `field34_survives_projection_protected_restart_and_received_update_encoding`. [Native tests](../source/native/validation/cloudkit_received_wire.L602-1633.rs) · [Schema](../source/native/schema) · [App tests](../source/app/rust/src/cloud_sync_received_message_update_stage.rs) | Native wire tests and a separate nine-case Windows native/Dart/ObjectBox fixture. |
| Can a source-root hint grant permission? | DTO mapping, incomplete enumeration refusal, adapter mapping and loaded-library synthetic tests. [DTO and refusal tests](../source/app/excerpts/message_source_hint_bridge.rs) · [Dart suites](../source/app/test/services/cloud_sync) | Mock adapter and separately matched local DLL. A hint assists retention. Authority checks remain independent. |
| What do the legacy adoption failures cover? | Twelve original cases stop at `cloud_sync_legacy_original_wire_unproven`. [Freeze source](../source/app/lib/services/rustpush/cloud_sync/cloud_sync_legacy_write_freeze.dart) · [Failure counts](../evidence/run-data.json) | Integrated offline Dart. The intended deeper transaction paths remain unverified. |
| Does a confirmed ordinary direct text remain durable when create adoption is refused? | `confirmed ordinary text is held at provenance adoption`. [Reviewed test patch](../evidence/2026-11-19-ordinary-text-rejection/reviewed-test.patch) · [Dated result and command](../evidence/2026-11-19-ordinary-text-rejection/README.md) | Real journal, Dart plaintext encoder, coordinator and ObjectBox gate, with synthetic Chat/auth/confirmation and mocked native codecs/staging. One distinct test passed. Execution requires the omitted full harness and resolved dependencies. |
| Does native Message-create preparation reject a descriptor without verified parent-Chat provenance before client dependencies? | `message_create_without_verified_parent_chat_refuses_before_client_or_transport`. [Reviewed test patch](../evidence/2026-11-19-native-message-create-rejection/reviewed-test.patch) · [Dated result and exact filter](../evidence/2026-11-19-native-message-create-rejection/README.md) | Actual app Rust test crate, synthetic account-only client, held account/container locks and existing pre-dispatch hook. 1 passed, 0 failed, 1,305 filtered. Measures early generic admission refusal and an unreached prepared-request boundary. Independent HTTP/writer-entry counts and downstream behavior remain unqualified. |
| Can the classifier reject invalid input and suppress results after cancellation? | Eight cases cover malformed/duplicate shape, budget/truncation, closed output and cancellation. [Actual app-crate test module](../source/app/rust/src/classification_discard_tests.rs) | The parent module includes it under `cfg(test)`. No production acquisition path was exercised. |
| Does a synthetic owner retain work through close? | Tests cover held input, quiescence, duplicate shutdown, timeout observation, worker joins and close-to-tray behavior. [Coordinator](../fixtures/coordinator-shutdown/worker.rs) · [Native owner](../fixtures/native-owner/model.rs) | Isolated standard-library models. The Windows broker used a fake session and a message-only window. |

## Historical commands

These examples preserve recorded flags. They are documentation for a separately authorized offline environment. App-crate commands require a fully prepared source checkout and its matched dependencies. This branch contains the standalone models and reviewed slices.

**Field 31 and API readback.** The November 15 follow-up compiled once with the default stack, one job and the Windows ARM64 MSVC toolchain. It then invoked the resulting Rust test executable with exact or module filters. The published results retain the original filters and filtered-out counts.

```text
cargo test --offline --locked --manifest-path rust/Cargo.toml --lib --features native-store-owner,offline-native-owner-harness --no-run --message-format json
<app-test-executable> --exact api::api::cloud_sync_message_update_prepare_tests::reconcile_consumer_uses_strict_fetched_original_wire_for_staged_classification
```

**Selected native paging regressions.** The first filter below selected the original six cases. The supplemental filter selected two additional cases. The separate 17-case affected run is recorded in the ledger.

```text
<native-test-executable> cloudkit::cloud_sync_transport_tests::co_ --test-threads=1 --nocapture --skip co_extra_
<native-test-executable> co_final_ --test-threads=1 --nocapture
```

**Actual app-crate classifier.** Windows ARM64, stable rustc 1.98.1, pre-existing resolved cache and one compilation job.

```text
cargo test --offline --locked --manifest-path rust/Cargo.toml --lib --features native-store-owner,offline-native-owner-harness --jobs 1 classification_discard_tests -- --test-threads=1
```

**Standalone lifetime fixtures.** The same recorded command shape applies to either of the two published `.rs` files. Use an isolated output location for the executable. Only synthetic inputs and the Rust standard library were used.

```text
rustc --edition=2021 --test <fixture-source.rs> -C debuginfo=0 -o <fixture-test.exe>
<fixture-test.exe> --test-threads=1
```

**Dart engine and inbox.** The November 15 focused run used Flutter 3.44.8, Dart 3.12.2, an already-resolved workspace and concurrency two. The two suite names are preserved so a reviewer can distinguish them from the adjacent 200-case batch.

```text
flutter test --no-pub --concurrency=2 test/services/cloud_sync/cloud_sync_engine_test.dart test/services/cloud_sync/cloud_inbox_applier_test.dart
```
