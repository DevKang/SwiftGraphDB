# Contributing to SwiftGraphDB

Thanks for your interest in contributing. This document covers the day-to-day workflow. For architectural context, read [SPEC.md](SPEC.md) and [CHANGELOG.md](CHANGELOG.md) first — especially the **Design Stability** table and **Open Questions** section, and the most recent direction recorded under `[Unreleased]`.

## Development setup

Requirements:

- Swift 6.0+
- Xcode 16.0+
- macOS 14+ for local development

Clone and build:

```bash
git clone https://github.com/DevKang/SwiftGraphDB.git
cd SwiftGraphDB
swift build
swift test
```

## Running tests

```bash
swift test                              # full suite
swift test --filter TraversalTests      # one test class
swift test --filter PersistenceTests
swift test --filter SyncTests
```

Benchmark tests are not required for ordinary PRs unless your change touches storage layout, traversal, indexing, or compaction.

## Before opening a PR

- `swift build` succeeds with no warnings under strict concurrency
- `swift test` passes
- New behavior has a unit or integration test
- Public API changes are reflected in [SPEC.md](SPEC.md)
- Storage-format or schema changes include a migration plan

## Areas that need design discussion first

Open a GitHub Discussion before starting work in these areas:

- public API shape (`GraphStore`, query builder, traversal)
- SQLite schema or persistence layout (especially the change journal)
- in-memory adjacency representation (CSR / EdgeLog)
- compaction policy
- the sync protocol boundary (`GraphChange`, `GraphSyncTransport`, `GraphConflictResolver`)
- the typed schema layer

Backend adapters (CloudKit, REST, Firebase, Supabase, custom) must not introduce dependencies into the core target. Land them as separate packages.

These are flagged in the **Design Stability** table in SPEC.md.

## Good first issues

- Traversal correctness tests
- Persistence round-trip tests
- Improved Quick Start examples
- Small benchmark datasets
- Better error messages and diagnostics
- Documentation for real-world app use cases

## Code style

- Follow the conventions in surrounding files
- Public types must be `Sendable` where the data model requires it
- No force-unwraps in non-test code
- Prefer `async throws` over completion handlers in public APIs

## License

By contributing, you agree your contributions are licensed under the [Apache License 2.0](LICENSE).
