# SwiftGraphDB 0.1.0

A small, embedded property graph database for iOS and macOS apps. SQLite is the durable
source of truth; an in-memory adjacency layer accelerates traversal. Sync is optional and
backend-agnostic; CloudKit ships as a reference adapter in a separate package.

## What's in 0.1

- **Local engine.** Property graph CRUD, label/property indexes, BFS traversal, shortest
  path. SQLite WAL persistence with partial indexes filtered on `is_deleted = 0`.
- **In-memory topology.** CSR adjacency + EdgeLog write buffer + compaction. Hot reads run
  off-actor against a `TopologySnapshot`.
- **Launch snapshots.** Custom packed format with magic + CRC32 footer for fast cold start.
- **Sync protocol.** `GraphChange`, `GraphSyncTransport`, `GraphConflictResolver`, plus an
  append-only `change_journal` table. Three resolvers ship: field-level merge,
  local-wins, remote-wins.
- **Adapter contract suite.** `GraphSyncContract<Transport>` makes it cheap to TDD a new
  backend against the same assertions the in-memory and CloudKit adapters pass.
- **CloudKit reference adapter (separate product).** `CloudKitGraphSyncTransport` with batch
  chunking, `limitExceeded` halving, exponential backoff (5-minute cap), iCloud account
  preflight, and a typed configuration error hierarchy.

## Why this shape

- **Local-first by construction.** The architecture invariant is: local reads and writes
  never depend on the network. Sync is a replication layer, not a write path.
- **Backend-agnostic sync.** Apps that ship without iCloud get the same protocol. New
  adapters (REST, Firebase, custom) only implement two methods: `push` and `pull`.
- **Conservative public surface.** 111 public symbols, every one with a doc comment, every
  one frozen against an allowlist (`Scripts/public-api-allowlist.txt`). Drift fails CI.

## Known limitations

See [SPEC.md §17](../SPEC.md#17-open-questions) for the full list. Notable items deferred to
post-0.1:

- Partial / subgraph sync. Today the protocol assumes whole-graph replication per backend.
- Typed schema layer (likely Swift macros).
- Query language frontend (Cypher / SQL DSL).

## Platform support

- **`SwiftGraphDB`** — iOS 17+, macOS 14+, Swift 6.0 strict concurrency, no external
  dependencies.
- **`SwiftGraphDBCloudKit`** — adds an iCloud entitlement for runtime, but the package
  itself compiles and unit-tests without an iCloud account thanks to the
  `CloudKitDatabase` abstraction.

## Install

```swift
.package(url: "https://github.com/oomool/SwiftGraphDB.git", from: "0.1.0"),
```

## Try it

The [`Examples/QuickStart`](../Examples/QuickStart) app exercises the full public surface in
a SwiftUI sample — open it in Xcode and run on macOS or the iOS simulator.

## Thanks

Sync protocol design is heavily influenced by local-first systems where the change model is
intentionally independent of the network layer. The code passes 358 tests across the core
and the CloudKit adapter; the contract suite was an enormous time-saver during M9.

If you build a new adapter, file the contract-suite green run as part of the PR.
