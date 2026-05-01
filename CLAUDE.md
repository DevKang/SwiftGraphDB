# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

SwiftGraphDB is an embedded property graph database for iOS and macOS apps, distributed as a Swift Package. SQLite is the durable source of truth; an in-memory adjacency layer (CSR + EdgeLog) handles traversal. CloudKit sync lives in a separate, optional product.

The full architectural specification is in [SPEC.md](SPEC.md). Read it before non-trivial changes — it documents which areas are stable vs experimental and lists explicit open design questions.

## Build & test

```bash
swift build
swift test
swift test --filter TraversalTests       # single test class
```

The package targets Swift 6 with strict concurrency enabled. Build warnings under strict concurrency should be fixed, not suppressed.

## Package layout

Two library products in one `Package.swift`:

- `SwiftGraphDB` — core engine. Must not depend on CloudKit, network access, or an iCloud account. Code under `Sources/SwiftGraphDB/`.
- `SwiftGraphDBCloudKit` — optional sync module that depends on `SwiftGraphDB`. Code under `Sources/SwiftGraphDBCloudKit/`.

This boundary is load-bearing: the core package must remain usable in apps that have no CloudKit entitlement. Don't introduce CloudKit imports or types into the core target.

## Architectural invariants

These come from SPEC.md §4.1 and must hold across changes:

- SQLite is the durable source of truth. In-memory structures are always rebuildable from SQLite.
- Launch snapshots are accelerators, never authoritative — discard on any version mismatch or corruption.
- CloudKit, when enabled, is a replication layer. It does not gate local reads or writes.
- Local reads/writes do not depend on network availability.
- Concurrency model is multiple-reader, single-writer. Writes are serialized through the graph actor; hot traversal runs against an immutable topology snapshot to avoid actor-hopping per node (SPEC.md §8.3).

## Public API stability

The public API is pre-1.0 and may still change. The **Design Stability** table at the top of SPEC.md is the source of truth for what's stable, stable-ish, experimental, or planned. When adding or changing public surface, update that table and §12 of SPEC.md in the same change.

## Storage & schema changes

Any change to:

- the SQLite schema (SPEC.md §6.2)
- on-disk snapshot format (§6.4)
- in-memory adjacency representation (§5.1)
- CloudKit record types (§9.3)

requires a migration plan in the PR. Schema version lives in `db_meta`; bump it and add a migration entry rather than mutating prior migrations.

## Testing expectations

Match tests to SPEC.md §14:

- Unit: `PropertyValue` Codable round trips, adjacency ops, EdgeLog merge rules, label/property index updates, conflict resolution.
- Integration: temp-file SQLite stores, traversal correctness on known topologies, tombstone/rebuild behavior, WAL under sustained write/read.
- Sync: two-device simulation (see §14.3) — both devices must converge without losing independently changed fields.

Performance tests are only required when a change touches storage layout, traversal, indexing, or compaction.

## What not to add to the core package

Per SPEC.md §1.2, these are explicitly out of scope for the core target — push back if a PR introduces them:

- a textual query language (Cypher/SPARQL/SQL DSL)
- multi-user collaboration / shared CloudKit zones
- distributed operation, sharding, consensus
- graph analytics algorithms (PageRank, community detection)
- mandatory cloud sync
