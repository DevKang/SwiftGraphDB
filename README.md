# SwiftGraphDB

> An embedded property graph database for Swift apps.

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Usable%20Local%20Engine-yellow.svg)]()

SwiftGraphDB is an open-source, embedded property graph database for Apple platforms. Use it when your app stores highly connected local data and needs graph traversal without running a server, a JVM, or an external database process.

It is designed to be small, embeddable, Swift-native, and app-process local — closer to SQLite in deployment model than to a server graph database.

CloudKit sync is optional. The core database is local-first and works without iCloud.

---

## When Should I Use It?

SwiftGraphDB is a good fit when your app has local data shaped like a graph:

- personal knowledge graphs
- note links, backlinks, and references
- local recommendation or relationship networks
- offline-first social or contact graphs
- app-internal dependency graphs
- concept maps, entity graphs, and semantic links

Use SQLite, Core Data, or GRDB directly when your data is mostly tabular and you rarely traverse relationships beyond one or two hops.

---

## Current Status

SwiftGraphDB is intended to be usable as a local embedded graph database before the repository is opened publicly.

### Available in the core package

- Property graph model: nodes, directed edges, labels, types, and properties
- Swift-native API for creating nodes and edges
- Local traversal API for common graph queries
- Local persistence backed by SQLite
- Single-process usage for iOS and macOS apps

### Experimental or evolving

- CSR-backed traversal internals
- EdgeLog compaction strategy
- Launch snapshot format
- Property indexes
- Advanced path queries
- Performance tuning and benchmark coverage

### Optional module

- CloudKit sync via `CKSyncEngine`

The public API may still change before `1.0`. See [SPEC.md](SPEC.md) for design stability and open questions.

---

## Quick Start

```swift
import SwiftGraphDB

// Open or create a local graph store.
let graph = try await GraphStore.open(at: .applicationSupport("MyGraph"))

// Insert nodes.
let alice = try await graph.addNode(label: "Person", properties: [
    "name": "Alice",
    "age": 32
])

let bob = try await graph.addNode(label: "Person", properties: [
    "name": "Bob",
    "age": 28
])

// Insert a directed edge.
try await graph.addEdge(from: alice, to: bob, type: "KNOWS", properties: [
    "since": 2021
])

// Traverse the graph.
let friends = try await graph
    .nodes(labeled: "Person")
    .where("name", equals: "Alice")
    .traverse(.outgoing, edge: "KNOWS", maxDepth: 2)
    .collect()
```

---

## Optional: CloudKit Sync

CloudKit sync is not required to use SwiftGraphDB. The local SQLite store remains the source of truth; CloudKit is a replication layer for a user's private database.

```swift
try await graph.enableCloudKitSync(container: .default)

for await status in graph.syncStatus {
    switch status {
    case .idle:
        break
    case .syncing:
        showSyncIndicator()
    case .error(let error):
        handleSyncError(error)
    }
}
```

CloudKit sync requires:

- iOS 17.0+ / macOS 14.0+
- CloudKit entitlements
- an active iCloud account on the user's device
- a configured CloudKit container

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
- optional indexes speed up common lookup paths
- optional snapshots accelerate launch and rebuild time

### Swift-native queries

SwiftGraphDB does not require Cypher, SPARQL, or SQL for everyday usage. Queries are expressed as fluent Swift APIs with async/await.

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│                    Swift Query API                          │
│         graph.nodes(labeled:).traverse(.outgoing)           │
├─────────────────────────────────────────────────────────────┤
│                   Graph Actor / Store                       │
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
├─────────────────────────────────────────────────────────────┤
│                    Optional Sync Module                     │
│                                                             │
│   CKSyncEngine + CloudKit private database                  │
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
| CloudKit sync | Optional module | Manual | NSPersistentCloudKitContainer | No | No |
| Best fit | Apple app graph traversal | Tables and SQL | App models and persistence | Larger analytical graph workloads | Multi-user server graph apps |

---

## Requirements

- Swift 6.0+
- iOS 17.0+ / macOS 14.0+
- Xcode 16.0+
- CloudKit sync requires iCloud and CloudKit entitlements

---

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/oomool/SwiftGraphDB", from: "0.1.0")
]
```

Then add `SwiftGraphDB` to the target that uses it.

### Xcode

File → Add Package Dependencies → enter the repository URL.

---

## Roadmap

### Core engine

- [x] Property graph model
- [x] Node and edge CRUD
- [x] Basic local traversal
- [x] SQLite-backed local persistence
- [ ] Stable public API review
- [ ] Expanded traversal test suite
- [ ] Benchmark fixtures and reproducible measurements

### Storage and performance

- [ ] CSR traversal optimization
- [ ] EdgeLog compaction policy
- [ ] Optional property indexes
- [ ] Bulk import API
- [ ] Launch snapshot format

### Optional sync

- [ ] CloudKit module boundary
- [ ] CKSyncEngine integration
- [ ] Field-level conflict resolution tests
- [ ] Large initial sync batching
- [ ] Offline sync recovery tests

### Future exploration

- [ ] Typed schema layer
- [ ] Additional path query APIs
- [ ] Subgraph extraction
- [ ] Optional Cypher-compatible frontend package

---

## Contributing

Contributions are welcome, especially in areas that make the project easier to trust and easier to adopt.

Good first issues:

- Add traversal correctness tests
- Add persistence round-trip tests
- Improve Quick Start examples
- Add small benchmark datasets
- Improve error messages and diagnostics
- Document real-world app use cases
- Add examples for common graph models

For larger changes, please open a GitHub Discussion first. Storage layout, sync behavior, public API shape, and performance contracts should be discussed before implementation.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) and [SPEC.md](SPEC.md) before starting substantial work.

---

## Academic References

SwiftGraphDB's architecture is informed by database systems work on graph storage, adjacency layout, write buffering, and concurrency:

- **Kùzu** (CIDR 2023) — columnar node storage and CSR-style graph processing
- **LiveGraph** (VLDB 2020) — transactional edge log for graph storage
- **LSMGraph** (SIGMOD 2024) — write-optimized dynamic graph storage
- **A+ Indexes** (VLDB 2020) — tunable adjacency-list index design
- **Columnar Storage for GDBMSs** (VLDB 2021) — property/topology separation
- **MVCC Empirical Evaluation** (VLDB 2017) — concurrency tradeoffs for read-heavy workloads
- **CloudKit** (VLDB 2018) — structured cloud storage for mobile applications

---

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.

---

## Status

SwiftGraphDB is a usable local engine moving toward a stable public API. The repository should be opened only with working examples, passing tests, and a clearly marked boundary between core functionality and experimental modules.

