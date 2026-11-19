# Source and dependency manifest

**November 19, 2026.** The review tree contains ordinary files. GitHub can display every published source selection without initializing a submodule. The source-file manifest records the original project path, inclusive line range, working-file SHA-256, published SHA-256, byte count and newline handling. [File manifest](../evidence/source-files.json) · [Git and lockfile manifest](dependencies.json)

## Public ancestry

The fork's default branch was `rustpush` at [e6b66003](https://github.com/Xare123/openbubbles-app/commit/e6b66003a238cd668b6d5097762e9c361ff4afae). GitHub's comparison places the [initial commit](https://github.com/Xare123/openbubbles-app/commit/303af4957fc454d12bb281012239d0965e864422) in that history. The new review branch uses that public commit as its parent and replaces its 2020 app scaffold with this review tree. The nearest public app checkpoint contains historical operating notes, tracked local configuration and prebuilt libraries. The earlier anchor keeps those files and the later private ancestry out of the new tree.

The active app HEAD was two commits beyond [the nearest public app checkpoint](https://github.com/Xare123/openbubbles-app/commit/022b6dda4f33abf87660c64f7e9ad73ab603ae98). Those two local app commits updated a native pointer and timestamp-related app code. The corresponding public checkpoint's [native gitlink](https://github.com/Xare123/rustpush/commit/19b2e210cd4f2cbffccf8b6499d3723b206d4876) is also two commits behind the native checkout. The default app revision used an [earlier native pin](https://github.com/OpenBubbles/rustpush/commit/a7fab473e7a33325a760635285db2860de8e1cb0). These public revisions provide comparison points. The reviewed files below come from the newer working trees.

## Observed dependency graph

All seven local indexes had zero staged changes. Counts below are porcelain entries with untracked files expanded. A changed child checkout can also appear as one modified entry in its parent.

| Local layer | Observed commit | Working state |
| --- | --- | --- |
| App | `3547d791d151dd408eede174c000f7b37966ff52` | Local comparison ID. Fork returned HTTP 422. 64 modified entries and 132 untracked. |
| App → rustpush | `201ea5ae4aeb37a2cbe44b424ae889179de46fbb` | Local comparison ID. Matches the app index pointer. Fork and upstream returned HTTP 422. 17 modified entries and 32 untracked. |
| rustpush → apple-private-apis | [12737cf2](https://github.com/Xare123/apple-private-apis/commit/12737cf23f8c6b6780fb56ec1f8484395367acc4) | Public commit. Six modified entries and five untracked. |
| rustpush → open-absinthe | [1f8dc73a](https://github.com/OpenBubbles/OpenAbsinthe-Stub/commit/1f8dc73a311e7b4d94a868972a6816c8a2c14e44) | Clean public stub. |
| apple-private-apis → clearadi | [663f33f9](https://github.com/OpenBubbles/clearadi-stub/commit/663f33f9d71b0df5436d04611755142df6db6a35) | Clean public stub. |
| App → telephony_plus | [5210e940](https://github.com/OpenBubbles/telephony_plus/commit/5210e940dd92ae371f8c74eaeb552d0704034244) | Clean. |
| telephony_plus → android-smsmms | [36f34f48](https://github.com/OpenBubbles/android-smsmms/commit/36f34f482dd5546c929f448d746c3124875a4faa) | Clean. |

The app Rust crate takes rustpush and keystore by local path. The native crate also uses its local protobuf schema, derive crate, authentication libraries and platform stubs. The working lockfiles select Flutter Rust Bridge 2.3.0 on both sides, prost 0.12.6, Dart ObjectBox 5.3.2 and window_manager 0.4.2. Full lockfile digests identify the inspected desktop inputs. [Dependency manifest](dependencies.json)

## Reviewed source

| Area | What to inspect |
| --- | --- |
| App Rust | Complete outgoing and received stage modules with their inline synthetic tests. Both whole-file hashes match the November 15 integration. [Outgoing stage](app/rust/src/cloud_sync_message_update_stage.rs) · [Received stage](app/rust/src/cloud_sync_received_message_update_stage.rs) |
| App consumer and lineage | Exact portions of the working bridge and lineage module show where the original bytes enter classification and which authority prerequisites remain. The larger bridge also contains account and writer paths. [Readback consumer](app/excerpts/classify_fetched_readback.rs) · [Consumer test](app/excerpts/classify_fetched_readback_test.rs) · [Lineage readback](app/excerpts/staged_lineage_readback.rs) |
| Dart | Source for legacy-write refusal, tracked work lifetime, immediate confirmation and post-commit presentation. [Dart source](app/lib/services/rustpush/cloud_sync) |
| App tests | Integrated classifier test module and two synthetic Dart bridge/FFI test files. The loaded-FFI suite also needs a matched library and a private synthetic fixture. [Classifier tests](app/rust/src/classification_discard_tests.rs) · [Dart tests](app/test/services/cloud_sync) · [Hint DTO and tests](app/excerpts/message_source_hint_bridge.rs) |
| Native | Original-wire validation, schema excerpts for field 34, aligned page sidecars, consistency checks and diagnostic redaction. Filenames carry original line ranges. Some declarations depend on omitted enclosing modules. [Validation](native/validation) · [Paging](native/paging) · [Schema](native/schema) · [Diagnostics](native/diagnostics) |
| Windows lifetime models | Two complete standard-library source files from isolated synthetic runs. [Coordinator](../fixtures/coordinator-shutdown/worker.rs) · [Native owner](../fixtures/native-owner/model.rs) |
| Windows and Android platform source | Three complete Windows runner files match the November 19 final-close assessment. Two Gradle excerpts identify the Android agent variant and debug ABI expansion. [Windows runner](app/windows/runner) · [Agent flavor](app/excerpts/android_agent_flavor.gradle) · [Debug ABIs](app/excerpts/android_debug_abis.gradle) |

Whole app files and standalone fixtures retain original bytes. Native excerpts use LF line endings. Binary-analysis annotations and their identifiers were omitted from the validator. The exact kept ranges are in the [file manifest](../evidence/source-files.json). The app license and the native license and exceptions accompany their respective source. The native selections include changes from the inspected fork working tree as of the snapshot date. [App license](../LICENSE) · [Native license](native/LICENSE) · [Native exceptions](native/LICENSE.exceptions)

## What remains local

- The dirty app, rustpush and authentication-library histories, unselected source, generated bindings, account/relay setup, writer dispatch, and test harnesses that substitute account authorization. The branch has no gitlinks pointing to the two local-only commits.
- Key-bearing native build inputs, signing and local configuration, protected fixtures, stored messages, raw device or network captures, firmware, databases, binaries, caches and original run logs. The Android source inventory's repaired second version still depended on excluded key-bearing inputs. It cannot reproduce a fresh package from public source.
- The full checkpoint, treemap, former chat and operating notes mix reusable findings with private operations. Their reviewed decisions and results are represented in the [roadmap](../docs/STATUS.md) and [run index](../evidence/README.md). Raw private notes and backup packages are outside the public provenance chain.
