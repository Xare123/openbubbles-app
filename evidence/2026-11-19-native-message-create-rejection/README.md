# Direct native Message-create rejection — November 19, 2026

One defensive regression passed in the actual application Rust test crate. It calls the production `cloud_sync_prepare_message_create` entry point with a synthetic descriptor that has no verified parent-Chat provenance or backing protected payload. The vector contains one item, the timeout is valid, and request/operation UUIDs are distinct and valid. The existing original-wire admission barrier returns `BindingMismatch`.

The test title is `message_create_without_verified_parent_chat_refuses_before_client_or_transport` in `rust/src/api/offline_native_owner_harness_tests.rs`. Its enclosing module already requires the isolated offline-owner feature and cfg. The source edit adds 68 lines to that test module.

| Observation | Result |
| --- | --- |
| Targeted execution | 1 passed, 0 failed, 0 ignored, 0 measured, 1,305 filtered out. Cargo exit 0. Compilation finished in 13m 58s; the test finished in 0.01s. |
| Production entry | The public Message-create preparation function returned `Some(BindingMismatch)`, with no prepared handle or handle-binding digest. |
| First-poll boundary | The result was immediately ready while the synthetic client's account-state write lock and Messages-container mutex were held. Continuing into the current auth-state read or writer-container warmup would wait on those held dependencies. |
| Prepared request observation | The existing offline pre-dispatch hook observed no prepared-request boundary, zero captured request-body bytes and zero final-check callback invocations. |
| Storage | The new synthetic scratch directory remained empty after the call. |
| Preserved source | The production API, native Message writer and transport, Cargo lockfile and existing Dart rejection test retained their recorded hashes. |

The client comes from the existing `account_only_fixture`, which uses synthetic in-memory account state and an `offline://network-forbidden` provider. The case creates no prepared save fixture or parent-source proof. It makes one direct preparation call and tests only rejection.

The first-poll result under held dependencies, together with the current API order, establishes this call's early return before client/auth or writer preparation. In the test title, `before_client_or_transport` names the held account/container dependency and final prepared-request boundaries observed here. Independent writer-entry and general HTTP call counts remain unmeasured by this app-crate harness. The existing hook observes the final prepared-request boundary. A dedicated parent-Chat validator and all behavior after the unchanged generic admission barrier remain unqualified.

The tested whole-module SHA-256 is `0f822ba527b9904f83d07dad967d0e978ad165f88f59220f8669438259a8412f`. The preserved pre-edit module SHA-256 is `aba0ed3444c84f03d26196b0bfb4cc42000d06cc65ff6392c99d5c2cb6d10bbf`. The application and native comparison IDs match the existing [dependency manifest](../../source/README.md#observed-dependency-graph). The source hashes describe the engineering working files.

The [reviewed test patch](reviewed-test.patch) contains only the 68-line addition, with zero deleted source lines. Its header paths are normalized to the original repository-relative test path. It uses zero context and requires `git apply --unidiff-zero` against the preserved full module. Buildability requires that module, the existing synthetic offline client/hook, full app and native source, generated inputs, resolved cached dependencies, initialized ARM64 MSVC environment and installed ObjectBox runtime/import library. The browser snapshot omits that build closure.

The recorded command below uses portable executable names. The prepared build reused the existing Cargo target and registry caches, `stable-aarch64-pc-windows-msvc`, `OPENBUBBLES_OFFLINE_OWNER_HARNESS=1`, and `RUSTFLAGS="--cfg tokio_unstable --cfg openbubbles_offline_owner_harness"`. Cached native TLS dependencies and the app test crate compiled with offline/locked settings and one build job. Absolute tool, checkout and cache paths are omitted.

```text
cargo test --offline --locked --manifest-path rust/Cargo.toml --lib --features native-store-owner,offline-native-owner-harness --jobs 1 api::api::offline_native_owner_harness_tests::message_create_without_verified_parent_chat_refuses_before_client_or_transport -- --exact --test-threads=1
```

Compilation completed with unused-code/OpenSSL PDB warnings and a dependency future-compatibility notice. This aggregate report excludes raw compiler logs and binaries. Accepted Message creation, full worker execution, authentication behavior beyond the barrier, CloudKit persistence/readback and independent restore remain unqualified. The existing provenance and live/release holds remain in effect.
