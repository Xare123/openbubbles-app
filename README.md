# OpenBubbles CloudKit browser review

**Start here.** This branch is the source of truth for the shareable OpenBubbles CloudKit review as of November 19, 2026. It contains reviewed source from the active Windows working trees, synthetic fixtures, and historical test results. The complete app and its account-bound build inputs remain outside this review tree.

| To answer this question | Open |
| --- | --- |
| What works, what is held, and what should I review next? | [Project status and roadmap](docs/STATUS.md) |
| Which app, native and Android dependencies did the desktop actually have? | [Source and dependency manifest](source/README.md) |
| Where is the relevant code or test? | [Test catalog](docs/TESTS.md) |
| Which version ran, what happened, and what did the run establish? | [Dated evidence and run index](evidence/README.md) |

**First browser task.** Trace field 31 from original wire bytes to the staged readback decision. Identify where the last published test stops and what evidence a reviewer would need at the next boundary. [Field 31 consumer](source/app/excerpts/classify_fetched_readback.rs) · [Synthetic consumer test](source/app/excerpts/classify_fetched_readback_test.rs) · [Roadmap](docs/STATUS.md#review-backlog)

The current assignment permits migration and documentation. Live-account writes, Alpha, live Canary, builds, deployments and new test runs are held. Use the [browser handoff](AGENTS.md) when continuing from GitHub.
