# Browser handoff

Start with the [project status and roadmap](docs/STATUS.md). Use this branch for the public handoff. The [source manifest](source/README.md) distinguishes committed public dependencies, local-only comparison IDs, working files and excerpts.

- Follow each claim to a dated entry in the [run index](evidence/README.md). Keep historical failures, ignored cases and test substitutions visible when adding evidence.
- Use [the test catalog](docs/TESTS.md) to locate source and recorded filters. The current assignment is migration and documentation. Build, CI, device, Alpha, live Canary, account and deployment work require a separate assignment.
- Keep new review material on a non-default project branch. Preserve the exact source or identify the selected range and any redaction. Verify that each linked dependency commit opens in its public repository before referencing it as a pin.
- Keep credentials, signing inputs, account or device identifiers, real messages, private logs, raw captures, databases, firmware and generated binaries outside this tree. Use synthetic placeholders and aggregate run records.

Update the canonical roadmap when a gate changes. Add the supporting dated result to the run index. Earlier local checkpoints and operating permissions are historical context.
