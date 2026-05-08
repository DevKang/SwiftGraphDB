# SwiftGraphDB

> An embedded property graph database for Swift apps, with a backend-agnostic sync protocol.

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2016%2B%20%7C%20macOS%2013%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Usable%20Local%20Engine-yellow.svg)]()

SwiftGraphDB is an open-source, embedded property graph database for Apple-platform apps. Use it when your app stores highly connected local data and needs graph traversal without running a server, a JVM, or an external database process.

The core package is local-first. It provides graph storage, traversal, SQLite-backed durability, a change journal, and sync protocol types. It does **not** require CloudKit, iCloud, network access, or a specific backend.

Sync is optional and pluggable. CloudKit support should live in a separate adapter package, such as `SwiftGraphDBCloudKit`, built on top of the same sync protocol used by REST, Firebase, Supabase, or custom transports.

---

## When Should I Use It?

SwiftGraphDB is a good fit when your app has local data shaped like a graph:

- personal knowledge graphs
- note links, backlinks, and references
- local recommendation or relationship networks
- offline-first social or contact graphs
- app-internal dependency graphs
- concept maps, entity graphs, and semantic links

Use SQLite, Core Data, GRDB, or SwiftData directly when your data is mostly tabular and relationship traversal is not a primary operation.

---

## Current Status

**0.1.0** ships the full local engine, the sync protocol, and a CloudKit reference adapter.
The public surface is frozen for the 0.1.x line — see
[`Scripts/public-api-allowlist.txt`](Scripts/public-api-allowlist.txt) and the
[Design Stability table in SPEC.md](SPEC.md#design-stability).

### Shipped in `SwiftGraphDB` (core)

- Property graph model: nodes, directed edges, labels, types, and properties
- Swift-native API for CRUD, queries, traversal, and shortest-path
- SQLite-backed local persistence with WAL-mode and partial indexes
- In-memory CSR adjacency + EdgeLog write buffer + compaction
- Launch snapshot format (`SGDBSNP1`) with CRC32 footer
- Property indexes declared at `GraphStore.Options` time
- Append-only change journal
- Backend-agnostic sync protocol (`GraphChange`, `GraphSyncTransport`, `GraphConflictResolver`)
- Three built-in resolvers: `FieldLevelMergeResolver`, `LocalWinsResolver`, `RemoteWinsResolver`
- `InMemorySyncBackend` for tests and SDK demos
- Reusable `GraphSyncContract<Transport>` for adapter authors

### Shipped in `SwiftGraphDBCloudKit` (optional, separate product)

- `CloudKitGraphSyncTransport` driving the sync protocol on top of a `CloudKitDatabase` abstraction
- `RecordCodec` for `GraphChange` ↔ `GDB_Node` / `GDB_Edge` mapping
- Batch chunking + `limitExceeded` halving + `retryAfter`-aware exponential backoff (5 min cap)
- iCloud account-state preflight via `CloudKitAccountStatusProbe`
- `MockCloudKitDatabase` and `SharedMockCloudKitBackend` for adapter testing

### Future package candidates (not shipped)

- `SwiftGraphDBREST` — possible REST reference adapter
- third-party adapters for Firebase, Supabase, custom servers, or local-file sync

---

## Quick Start

```swift
import SwiftGraphDB

// Open or create a local graph store.
let graph = try await GraphStore.open(named: "MyGraph")

// Insert nodes.
let alice = try await graph.addNode(label: "Person", properties: [
    "name": "Alice",
    "age": .int(32)
])
let bob = try await graph.addNode(label: "Person", properties: [
    "name": "Bob",
    "age": .int(28)
])

// Insert a directed edge.
_ = try await graph.addEdge(from: alice, to: bob, type: "KNOWS", properties: [
    "since": .int(2021)
])

// Traverse the graph.
let friends = try await graph
    .nodes(labeled: "Person")
    .where("name", equals: "Alice")
    .traverse(.outgoing, edge: "KNOWS", maxDepth: .bounded(2))
    .collect()
```

For a full SwiftUI sample exercising CRUD, queries, traversal, and the in-memory sync API end
to end, see [`Examples/QuickStart`](Examples/QuickStart).

---

## Optional Sync

SwiftGraphDB core does not know or care which backend you use. Sync is modeled as graph changes exchanged through a transport.

```swift
import SwiftGraphDB

let graph = try await GraphStore.open(named: "MyGraph")

try await graph.enableSync(
    transport: MySyncTransport(),
    resolver: FieldLevelMergeResolver(
        sameFieldConflict: .remoteWins,
        deleteConflict: .fail
    )
)
```

The core sync boundary is intentionally small:

```swift
public protocol GraphSyncTransport: Sendable {
    var backendID: SyncBackendID { get }

    func push(_ batch: ChangeBatch) async throws -> PushResult
    func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult
}
```

Transport adapters are responsible for network or backend-specific details. The core package remains responsible for local durability, change ordering, graph invariants, and conflict resolution hooks.

### CloudKit reference adapter

CloudKit is important for Apple-first apps, but it is not a requirement of the core database.

```swift
import SwiftGraphDB
import SwiftGraphDBCloudKit

let graph = try await GraphStore.open(named: "MyGraph")

let transport = CloudKitGraphSyncTransport(
    container: .default,
    databaseScope: .private,
    zoneName: "graphdb-private"
)

try await graph.enableSync(
    transport: transport,
    resolver: .fieldLevelMerge()
)
```

The CloudKit adapter can use `CKSyncEngine`, CloudKit record zones, retry behavior, and record mapping without leaking those concepts into the core package.

---

## Core Concepts

### Property graph

A graph contains nodes and directed edges. Both nodes and edges can carry properties.

```swift
let node = Node(
    id: UUID(),
    label: "Person",
    properties: ["name": .string("Alice")]
)

let edge = Edge(
    id: UUID(),
    type: "KNOWS",
    fromID: aliceID,
    toID: bobID,
    properties: ["since": .int(2021)]
)
```

### Local-first storage

SwiftGraphDB separates traversal from durability:

- in-memory graph structures handle traversal
- SQLite stores durable node and edge records
- an append-only change journal records local mutations for sync adapters
- optional indexes speed up common lookup paths
- optional snapshots accelerate launch and rebuild time

### Change-based sync

SwiftGraphDB syncs graph changes, not full database snapshots.

```swift
public struct GraphChange: Codable, Sendable, Hashable {
    public let id: ChangeID
    public let graphID: GraphID
    public let actorID: ActorID
    public let sequence: Int64
    public let entity: GraphEntityRef
    public let operation: GraphOperation
    public let payload: GraphRecordPayload?
    public let baseRevision: GraphRevision?
    public let revision: GraphRevision
    public let createdAt: Date
}
```

This makes sync incremental, testable, and portable across backends.

### Swift-native queries

SwiftGraphDB does not require Cypher, SPARQL, or SQL for everyday usage. Queries are expressed as fluent Swift APIs with async/await.

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│                    Swift Query API                          │
│         graph.nodes(labeled:).traverse(.outgoing)           │
├─────────────────────────────────────────────────────────────┤
│                   Graph Store / Actor                       │
│              Serialized writes · Concurrent reads           │
├──────────────────────────┬──────────────────────────────────┤
│    In-Memory Layer       │      Index Layer                 │
│                          │                                  │
│  Adjacency structures    │  Label index                     │
│  EdgeLog write buffer    │  Optional property indexes       │
│  Traversal engine        │  Primary key lookup              │
├──────────────────────────┴──────────────────────────────────┤
│                  Local Persistence Layer                    │
│                                                             │
│   SQLite in WAL mode       Optional launch snapshot         │
│   nodes / edges tables      Rebuildable from SQLite         │
│   change_journal            sync_checkpoints                │
├─────────────────────────────────────────────────────────────┤
│                  Sync Protocol Boundary                     │
│                                                             │
│   GraphChange · GraphSyncTransport · ConflictResolver       │
├─────────────────────────────────────────────────────────────┤
│                  Optional Adapter Packages                  │
│                                                             │
│   CloudKit · REST · Firebase · Supabase · custom backend    │
└─────────────────────────────────────────────────────────────┘
```

---

## Why Not Use SQLite Alone?

SQLite is excellent for embedded relational storage, and SwiftGraphDB uses SQLite for durability. The distinction is query shape.

Relational databases can model graphs, but multi-hop traversal often requires recursive queries, repeated joins, or application-managed traversal. For apps where relationship traversal is a primary operation, an adjacency-first graph layer can make queries simpler and keep hot traversal paths in memory.

SwiftGraphDB does not try to replace SQLite for relational data. It uses SQLite as the durable store and adds a Swift graph traversal layer on top.

---

## Comparison

| | SwiftGraphDB | SQLite | Core Data | Kùzu | Neo4j |
|---|---|---|---|---|---|
| Primary use case | Embedded app graph | Embedded relational DB | Apple object persistence | Embedded analytical graph DB | Server graph DB |
| Local app-process use | Yes | Yes | Yes | Yes | No |
| Swift-first API | Yes | No | Yes | Binding-dependent | Driver-dependent |
| Graph traversal API | Native | Manual / recursive SQL | Object graph oriented | Native | Native |
| External runtime | No | No | No | Native library | JVM / server |
| Pluggable sync protocol | Yes | Manual | CloudKit-specific option | No | Server-managed |
| CloudKit required | No | No | No | No | No |
| Best fit | Apple app graph traversal | Tables and SQL | App models and persistence | Larger analytical graph workloads | Multi-user server graph apps |

---

## Requirements

Core package:

- Swift 6.0+
- iOS 16.0+ / macOS 13.0+ target recommended
- Xcode 16.0+
- SQLite available through the platform

CloudKit adapter package:

- iOS 17.0+ / macOS 14.0+ when using `CKSyncEngine`
- CloudKit entitlements
- an active iCloud account on the user's device
- a configured CloudKit container

---

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/DevKang/SwiftGraphDB", from: "0.1.0")
]
```

CloudKit adapter, when published:

```swift
dependencies: [
    .package(url: "https://github.com/DevKang/SwiftGraphDBCloudKit", from: "0.1.0")
]
```

### Xcode

File → Add Package Dependencies → enter repository URL.

---

## Roadmap

### Shipped in 0.1.0

- [x] Property graph model
- [x] Node and edge CRUD
- [x] Local traversal API + shortest-path
- [x] SQLite persistence (WAL, partial indexes)
- [x] CSR traversal optimization
- [x] EdgeLog compaction
- [x] Launch snapshot format
- [x] Property index declaration API
- [x] Benchmark harness
- [x] Change journal
- [x] Backend-agnostic `GraphSyncTransport`
- [x] Conflict resolver API + three built-in resolvers
- [x] Sync adapter contract suite (`GraphSyncContract<Transport>`)
- [x] `SwiftGraphDBCloudKit` reference adapter

### Planned for 0.1.x

- [ ] Configurable tombstone retention beyond "all backends acknowledged"
- [ ] CKSyncEngine-backed `CloudKitDatabase` reference implementation
- [ ] Additional resolver presets (last-write-wins, CRDT counter examples)

### Targeted for 0.2 and beyond

- [ ] Typed schema layer (likely Swift macros)
- [ ] Partial / subgraph sync
- [ ] REST reference adapter
- [ ] Firebase / Supabase design notes

---

## Contributing

SwiftGraphDB is intended to be usable before public launch, but the API and internals are still evolving. Contributions are welcome.

Good first issues:

- Add traversal correctness tests
- Add benchmark fixtures for common app-sized graphs
- Improve `PropertyValue` Codable round-trip coverage
- Improve query builder examples
- Improve error messages
- Add sync transport contract tests using an in-memory fake backend

Design discussions:

- Open a GitHub Discussion before submitting large PRs.
- Backend adapters should not add dependencies to the core package.
- Sync-related changes should preserve the `GraphSyncTransport` boundary.

Please read [CONTRIBUTING.md](CONTRIBUTING.md), [SPEC.md](SPEC.md), and [CHANGELOG.md](CHANGELOG.md) before starting work.

---

## Design References

SwiftGraphDB's design is influenced by graph database storage research and local-first sync systems:

- **Kùzu** — columnar graph storage and CSR-style adjacency
- **LiveGraph** — transactional edge log design
- **LSMGraph** — write buffer plus read-optimized adjacency structures
- **A+ Indexes** — tunable adjacency list indexing
- **Automerge Repo** — pluggable storage and networking adapters
- **Yjs** — provider-based sync and persistence ecosystem
- **Replicache** — local-first push/pull sync contract
- **RxDB** — backend-independent replication with client-side conflict handling
- **CloudKit / CKSyncEngine** — Apple-specific reference backend for private user sync

---

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.

---

## Status

🟡 **Usable local engine / evolving public API** — The core database is designed to work locally without sync. Backend-agnostic sync protocol support is being specified. CloudKit belongs in a separate adapter package.

---

*Built with care for the Apple developer community.*
