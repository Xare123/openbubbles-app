# Ordinary-text rejection across close, reopen and retry — November 19, 2026

The new synthetic Dart/ObjectBox case passed together with the prior focused rejection regression on the final exact source bytes. It uses the real local-send journal, admission coordinator, plaintext encoder and ObjectBox gate with the existing fake native/staging boundary.

The added test is `ordinary text rejection survives close reopen and one retry`, in the group `durable local send handoff`, in `test/services/cloud_sync/cloud_sync_outbound_admission_test.dart`.

| Observation | Verified result |
| --- | --- |
| Final focused run | 2 passed, 0 failed, exit 0. One new close/reopen/retry case and one rerun of `confirmed ordinary text is held at provenance adoption`. |
| Database lifecycle | The first Store was closed. A distinct Store reopened the same temporary database directory. The existing writer owner and epoch were read and asserted before rebuilding the journal. |
| Durable text and intent | Exactly one Message and one intent remained, with the same local IDs, intent key, GUID, text, source hash and writer epoch. State 1 and confirmation version 2 remained ready according to `journal.readReady()`. No CloudKit record ID or admitted operation was created. |
| Mapping and outbox state | Zero outbox entities. A sorted snapshot of every record-map field across all zones matched the pre-attempt snapshot after each refusal and after reopen. |
| First attempt | Exact `cloud_sync_legacy_original_wire_unproven`, one fake Message stage, zero parent stages, one fake rollback and zero commits. |
| Single retry after reopen | The same exact refusal, one fresh fake Message stage, zero parent stages, one fake rollback and zero commits. The two attempts used distinct synthetic leases. |
| Combined attempt ledger | Two stages and two rollbacks for this new case, zero commits. Each attempt also checked the staged GUID, direct Chat, type, service and decoded synthetic text. |
| Instrumented bridge calls | Zero `crateApiApiSend` calls and zero calls to `crateApiApiCloudSyncPrepareMessageCreate`, `crateApiApiCloudSyncConsumePreparedMessageCreate` and `crateApiApiSaveMessages` during the new case. |

After reopen, the test reconstructs the authority, journal, synthetic auth snapshot/fence, ObjectBox adapter, coordinator, fake transport and timeline. Message, intent and Chat projection data are read from the reopened database. The test performs no reseeding after the close.

The ObjectBox database and journal/admission checks are real. Account/auth identity, positive IDS confirmation and the restored Chat proof originate in the existing synthetic fixture. The protector, Rust FFI codecs, stage allocation, recovery callback and lease rollback/commit boundary use fakes or mocks. Rollback assertions describe those fake calls. The installed ObjectBox runtime supplies database I/O.

The tested whole-module SHA-256 is `86fcaf8c3d00d152fc239a20e3b665789a160b5b845e67a8703030a6719f46c6`. The preserved pre-edit module SHA-256 is `98c00469909a89606b98d1c889bb70e9b72021d86df41321f78a277b21ca943d`. The existing native regression, production API, ObjectBox gate, journal and admission coordinator retained their recorded hashes. The same final Dart bytes were verified after the two-test run.

The [reviewed incremental patch](reviewed-test.patch) adds 134 lines to the test module, with zero deleted lines. It builds on the [earlier rejection fixture and spies](../2026-11-19-ordinary-text-rejection/README.md). Its paths are repository-relative, and its zero-context format requires `git apply --unidiff-zero` against the preserved full module. Execution requires the omitted full harness, app/generated bindings, resolved dependencies, prepared Flutter SDK and matching ObjectBox runtime. The browser snapshot contains reviewed evidence selections.

The command below uses portable executable names. The prepared ObjectBox DLL directory was on the process PATH. Dependency resolution and test asset bundling were disabled, and absolute local paths are omitted.

```powershell
flutter --no-version-check --suppress-analytics test --no-pub --no-test-assets --concurrency=2 --reporter expanded --name '^durable local send handoff (confirmed ordinary text is held at provenance adoption|ordinary text rejection survives close reopen and one retry)$' test/services/cloud_sync/cloud_sync_outbound_admission_test.dart
```

This result establishes same-process close/reopen durability and one explicit retry at the held Dart admission boundary. Process restart/crash recovery, real native protected storage and cryptographic lease cleanup, full production worker dispatch, CloudKit persistence/readback and independent restore remain unqualified. The bridge spy covers the named methods. The existing provenance and live/release holds remain in effect.
