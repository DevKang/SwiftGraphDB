# SwiftGraphDB — Technical Specification

**Version:** 0.1-draft  
**Status:** Usable local engine / evolving public API  
**Last Updated:** 2026-05

---

## Document Purpose

This specification describes the target architecture and implementation constraints for SwiftGraphDB. It is written for contributors, reviewers, and maintainers.

The README explains what the project is and how to start using it. This document explains how the system is intended to work internally, which parts are stable, and which decisions remain open.

---

## Design Stability

| Area | Status | Notes |
|---|---|---|
| Property graph model | Stable | Nodes, edges, labels, types, and properties are core concepts |
| Client-generated UUIDs | Stable | Required for offline-first local writes |
| Local SQLite persistence | Stable | SQLite is the durable source of truth |
| Basic traversal API | Stable-ish | API names may still change before 1.0 |
| Actor-based write serialization | Stable-ish | Public behavior should remain single-writer safe |
| CSR traversal internals | Experimental | Implementation detail; may change without API break |
| EdgeLog compaction | Experimental | Merge and tombstone rules need more testing |
| Launch snapshot | Planned / experimental | Snapshot is an accelerator, never source of truth |
| CloudKit sync | Optional / experimental | Implemented outside the core local engine |
| Typed schema layer | Planned | Macro vs property-wrapper design unresolved |
| Query language frontend | Future | Out of scope for the core package |

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Package Boundaries](#2-package-boundaries)
3. [Data Model](#3-data-model)
4. [Core Storage Architecture](#4-core-storage-architecture)
5. [In-Memory Layer](#5-in-memory-layer)
6. [Persistence Layer](#6-persistence-layer)
7. [Query Engine](#7-query-engine)
8. [Concurrency Model](#8-concurrency-model)
9. [Optional CloudKit Sync Module](#9-optional-cloudkit-sync-module)
10. [Performance Targets](#10-performance-targets)
11. [Stress Failure Modes and Mitigations](#11-stress-failure-modes-and-mitigations)
12. [Public API Design](#12-public-api-design)
13. [Schema and Versioning](#13-schema-and-versioning)
14. [Testing Strategy](#14-testing-strategy)
15. [Open Questions](#15-open-questions)
16. [Appendix A: Key Research Papers](#appendix-a-key-research-papers)
17. [Appendix B: Glossary](#appendix-b-glossary)

---

## 1. Goals and Non-Goals

### 1.1 Goals

- Provide an embedded property graph database for iOS and macOS applications
- Support on-device graph traversal without a server, daemon, JVM, or external database process
- Expose a Swift-native API using async/await and value-oriented model types
- Store durable graph data locally in SQLite
- Keep traversal paths optimized for relationship-heavy workloads
- Support graphs large enough for real mobile app use cases
- Be usable as a Swift Package with a single import
- Keep CloudKit sync optional and separate from the local core engine

### 1.2 Non-Goals

This specification explicitly excludes the following from the core package. They may be revisited in future versions or separate packages.

- **Multi-user collaboration.** The core database targets local, single-user app data. Shared CloudKit zones and multi-user conflict policies are out of scope for the core engine.
- **Mandatory cloud sync.** The database must work fully offline and fully local.
- **A query language.** No Cypher, SPARQL, SQL, or custom textual DSL in the core package. A query language may be added later as an optional frontend.
- **Distributed operation.** No sharding, cluster replication, leader election, or consensus algorithms.
- **Server deployment.** SwiftGraphDB is optimized for Apple app processes, not Linux server deployment.
- **Graph analytics engine.** Algorithms such as PageRank, community detection, and GPU acceleration are out of scope for the core engine.

---

## 2. Package Boundaries

SwiftGraphDB should be structured so that local graph storage remains useful without optional infrastructure.

### 2.1 Core Package

The core package contains:

- data model types
- local graph store
- SQLite persistence
- traversal engine
- query builder
- local transaction and concurrency behavior
- test utilities for in-memory and temporary-file stores

The core package must not require:

- CloudKit entitlements
- an iCloud account
- network access
- a configured CloudKit container

### 2.2 Optional Sync Package

CloudKit support should live behind a clear module boundary, for example:

```swift
import SwiftGraphDB
import SwiftGraphDBCloudKit

let graph = try await GraphStore.open(named: "MyGraph")
try await graph.enableCloudKitSync(container: .default)
```

The sync package may depend on CloudKit and CKSyncEngine. The core package should not.

### 2.3 Future Extension Packages

Potential future packages:

- `SwiftGraphDBSchema` — typed node/edge schema helpers
- `SwiftGraphDBCypher` — optional Cypher-compatible parser/frontend
- `SwiftGraphDBAlgorithms` — graph algorithms beyond core traversal
- `SwiftGraphDBBenchmarks` — reproducible benchmark datasets and harnesses

---

## 3. Data Model

SwiftGraphDB implements the Property Graph Model: entities are nodes, relationships are directed edges, and both can hold properties.

### 3.1 Nodes

A node represents an entity. Every node has:

| Field | Type | Description |
|---|---|---|
| `id` | `NodeID` | Globally unique identifier, assigned on creation |
| `label` | `String` | Primary type label such as `"Person"` or `"Concept"` |
| `properties` | `[String: PropertyValue]` | Arbitrary key-value pairs |
| `createdAt` | `Date` | Timestamp of creation |
| `modifiedAt` | `Date` | Timestamp of last modification |

Initial implementation supports one label per node. Multi-label support is intentionally deferred until clear use cases emerge, because it complicates indexing, API design, and sync conflict behavior.

### 3.2 Edges

An edge represents a directed relationship between two nodes. Every edge has:

| Field | Type | Description |
|---|---|---|
| `id` | `EdgeID` | Globally unique identifier |
| `type` | `String` | Relationship type such as `"KNOWS"` or `"REFERENCES"` |
| `fromID` | `NodeID` | Source node |
| `toID` | `NodeID` | Destination node |
| `properties` | `[String: PropertyValue]` | Arbitrary key-value pairs |
| `createdAt` | `Date` | Timestamp of creation |
| `modifiedAt` | `Date` | Timestamp of last modification |

Edges are directed. An undirected relationship can be modeled as two directed edges or traversed with direction-insensitive APIs.

### 3.3 PropertyValue

Properties are typed values. Supported primitive types are chosen to map cleanly to Codable, SQLite serialization, and optional CloudKit sync.

```swift
enum PropertyValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PropertyValue])
    case null
}
```

Design constraints:

- Values must be Codable.
- Values should be deterministic when serialized.
- Equality and hashing must be stable for index usage.
- Large binary blobs are allowed but discouraged for hot traversal workloads.

### 3.4 IDs

Both `NodeID` and `EdgeID` are UUID-backed value types or typealiases.

```swift
typealias NodeID = UUID
typealias EdgeID = UUID
```

UUIDs are generated client-side at creation time. This avoids server round-trips and makes offline writes possible.

---

## 4. Core Storage Architecture

The core architecture separates traversal speed from durable storage.

```text
┌─────────────────────────────────────────────────────┐
│              Query API                               │
│  Fluent Swift builders and async collection          │
├─────────────────────────────────────────────────────┤
│              In-Memory Layer                         │
│  Adjacency structures + EdgeLog + indexes            │
│  Handles traversal and hot lookup paths              │
├─────────────────────────────────────────────────────┤
│              Persistence Layer                       │
│  SQLite in WAL mode                                  │
│  Handles durability, recovery, and property storage  │
├─────────────────────────────────────────────────────┤
│              Optional Modules                        │
│  CloudKit sync, launch snapshots, typed schemas      │
└─────────────────────────────────────────────────────┘
```

### 4.1 Key Invariants

- SQLite is the durable source of truth.
- In-memory structures are rebuildable from SQLite.
- Snapshots are launch accelerators only.
- CloudKit, when enabled, is a replication layer only.
- Local reads and writes must not depend on network availability.

---

## 5. In-Memory Layer

### 5.1 Adjacency Representation

The target representation for optimized traversal is Compressed Sparse Row (CSR). CSR stores adjacency as contiguous arrays, which improves cache locality for graph traversal.

```swift
struct CSRAdjacency: Sendable {
    // offsets[i] = start index in edges for node with internal index i
    // offsets[i + 1] = end index, exclusive
    var offsets: [Int]

    // Neighbor records stored contiguously by source node.
    var edges: [EdgeRecord]
}

struct EdgeRecord: Sendable {
    var toID: NodeID
    var edgeID: EdgeID
    var type: String
}
```

Both outgoing and incoming adjacency should be supported. Maintaining separate forward and reverse structures avoids full scans for incoming traversal.

### 5.2 Internal ID Mapping

Public IDs are UUIDs. Hot traversal paths should use compact integer indexes internally.

```swift
var nodeIDToIndex: [NodeID: Int]
var indexToNodeID: [Int: NodeID]
```

The mapping must be rebuildable from SQLite and must remain consistent with tombstones and compaction.

### 5.3 EdgeLog Write Buffer

CSR is efficient for reads but expensive for frequent mutation. Recent edge writes are staged in an append-only EdgeLog.

```swift
struct EdgeLogEntry: Sendable {
    let edgeID: EdgeID
    let fromID: NodeID
    let toID: NodeID
    let type: String
    let timestamp: Date
    let operation: EdgeLogOperation
}

enum EdgeLogOperation: Sendable {
    case insert
    case delete
}
```

During traversal, results are composed from:

1. compacted adjacency structures
2. recent EdgeLog inserts
3. EdgeLog tombstones that suppress older edges

### 5.4 Compaction

Compaction merges the EdgeLog into the primary adjacency representation.

Compaction may be triggered by:

- EdgeLog size threshold
- memory pressure
- app backgrounding
- explicit `graph.compact()` call
- test-only deterministic compaction hooks

Compaction must preserve query correctness while running. Queries should observe a consistent snapshot, not a partially compacted state.

### 5.5 Label Index

```swift
var labelIndex: [String: Set<NodeID>]
```

The label index maps each label to the set of live node IDs with that label. It is updated synchronously on node creation, update, and deletion.

### 5.6 Property Indexes

Property indexes are optional. They should be created only for frequently queried equality predicates.

```swift
var propertyIndex: [String: [AnyHashable: Set<NodeID>]]
```

Open design point: whether property indexes can be added at runtime or only declared during schema/store setup.

### 5.7 Memory Budget

The in-memory layer should prioritize topology and indexes. Full property dictionaries should not be kept permanently in memory unless explicitly cached.

For a graph around 100K nodes and 500K edges, the target is to keep hot topology memory within ordinary iOS app budgets. Exact memory usage must be measured in release builds and documented in benchmarks.

---

## 6. Persistence Layer

### 6.1 SQLite Role

SQLite is the durable source of truth for:

- node records
- edge records
- properties
- tombstones
- schema version
- optional sync metadata

The graph can rebuild all in-memory traversal structures from SQLite.

### 6.2 SQLite Schema

```sql
CREATE TABLE nodes (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    properties  BLOB NOT NULL,
    created_at  REAL NOT NULL,
    modified_at REAL NOT NULL,
    is_deleted  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_nodes_label
ON nodes(label)
WHERE is_deleted = 0;

CREATE TABLE edges (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    from_id     TEXT NOT NULL REFERENCES nodes(id),
    to_id       TEXT NOT NULL REFERENCES nodes(id),
    properties  BLOB NOT NULL,
    created_at  REAL NOT NULL,
    modified_at REAL NOT NULL,
    is_deleted  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_edges_from
ON edges(from_id)
WHERE is_deleted = 0;

CREATE INDEX idx_edges_to
ON edges(to_id)
WHERE is_deleted = 0;

CREATE INDEX idx_edges_type
ON edges(type)
WHERE is_deleted = 0;

CREATE TABLE db_meta (
    key     TEXT PRIMARY KEY,
    value   TEXT NOT NULL
);
```

Optional modules may add tables such as `sync_metadata`, but the core schema should not require them.

### 6.3 WAL Configuration

SQLite should be opened in WAL mode for normal app usage.

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;
PRAGMA cache_size = -32000;
PRAGMA wal_autocheckpoint = 100;
```

Notes:

- WAL mode improves read/write coexistence for embedded workloads.
- `synchronous = NORMAL` is a pragmatic default for app-local data, but the durability tradeoff should be documented.
- Large bulk imports should use explicit transactions and may need checkpoint management.
- PRAGMA defaults may be made configurable for apps with stricter durability requirements.

### 6.4 Launch Snapshot

A launch snapshot is an optional accelerator.

```text
Application Support/
  MyGraph/
    graph.sqlite
    graph.sqlite-wal
    graph.snapshot
    graph.snapshot.meta
```

Snapshot invariants:

- The snapshot is never the source of truth.
- The snapshot is rebuildable from SQLite.
- Snapshot version must match database schema and snapshot format version.
- Corrupt or stale snapshots must be discarded safely.

Open design point: snapshot format. Options include raw binary arrays, FlatBuffers, or a custom portable format.

### 6.5 Bulk Import

Bulk import should batch writes in explicit SQLite transactions.

```swift
try await graph.bulkInsert { batch in
    for node in nodes {
        batch.addNode(label: node.label, properties: node.properties)
    }
}
```

Bulk import must avoid creating one SQLite transaction per row.

---

## 7. Query Engine

### 7.1 Public Query API

The public API should feel Swift-native and avoid requiring a textual query language.

```swift
let people = try await graph
    .nodes(labeled: "Person")
    .where("age", greaterThan: .int(25))
    .collect()

let network = try await graph
    .node(id: aliceID)
    .traverse(.outgoing, edge: "KNOWS", maxDepth: 3)
    .collect()
```

### 7.2 Execution Model

Internally, queries are modeled as a lazy pipeline.

```text
Source → Filter → Traverse → Filter → Collect
```

Stages may be represented as AsyncSequence or another lazy abstraction, but the public API should not expose unnecessary implementation details.

### 7.3 Source Operations

```swift
graph.nodes(labeled: "Person")
graph.node(id: someUUID)
graph.nodes(where: "age", greaterThan: .int(30))
```

### 7.4 Traversal Operations

```swift
.traverse(.outgoing, edge: "KNOWS")
.traverse(.incoming, edge: "KNOWS")
.traverse(.both, edge: "KNOWS", maxDepth: 3)
.traverse(.outgoing, maxDepth: .unlimited)
```

Traversal defaults to BFS. DFS may be exposed separately if there is a clear API need.

### 7.5 Path Queries

Path APIs are useful but should be stabilized after core traversal.

```swift
let path = try await graph.shortestPath(
    from: aliceID,
    to: bobID,
    via: "KNOWS"
)
```

Shortest path should use BFS for unweighted graphs and Dijkstra only when weights are provided.

### 7.6 Collect Operations

```swift
.collect()
.collectWithEdges()
.count()
.first()
.exists()
```

Collect operations materialize results. Until collection, the query should avoid unnecessary intermediate arrays.

---

## 8. Concurrency Model

### 8.1 Semantics

SwiftGraphDB uses a multiple-reader, single-writer model appropriate for local app data.

Requirements:

- writes are serialized
- reads can run concurrently when they observe immutable snapshots
- traversal should avoid actor-hopping per visited node
- public APIs must be safe under Swift concurrency checking

### 8.2 Actor Isolation

The graph actor owns mutable state.

```swift
actor GraphActor {
    var adjacency: CSRAdjacency
    var edgeLog: [EdgeLogEntry]
    var labelIndex: [String: Set<NodeID>]
    var propertyCache: LRUCache<NodeID, [String: PropertyValue]>
    let sqliteStore: SQLiteStore
}
```

### 8.3 Read Snapshot Pattern

Hot traversal should run against an immutable snapshot.

```swift
actor GraphActor {
    func snapshotTopology() -> TopologySnapshot {
        TopologySnapshot(adjacency: adjacency, edgeLog: edgeLog)
    }
}

let topology = await graphActor.snapshotTopology()
let results = BFSTraversal(topology: topology, from: startID)
```

This avoids repeated actor hops during traversal.

### 8.4 Background Tasks

Compaction, checkpointing, and optional sync run as structured background tasks. They must not block foreground reads longer than necessary.

---

## 9. Optional CloudKit Sync Module

CloudKit sync is an optional module, not part of the core local engine.

### 9.1 Overview

When enabled, CloudKit replicates local changes across a user's devices. The local SQLite store remains the source of truth.

```swift
try await graph.enableCloudKitSync(container: .default)
```

### 9.2 Platform Requirements

The sync module targets CKSyncEngine-compatible OS versions:

- iOS 17.0+
- iPadOS 17.0+
- macOS 14.0+
- Mac Catalyst 17.0+

Apps also need CloudKit entitlements and a configured container.

### 9.3 CloudKit Record Model

Two record types are sufficient for the initial sync design.

**Node record** (`GDB_Node`):

```text
id:          String
label:       String
properties:  Bytes
created_at:  Date
modified_at: Date
is_deleted:  Int64
```

**Edge record** (`GDB_Edge`):

```text
id:          String
type:        String
from_id:     String
to_id:       String
properties:  Bytes
created_at:  Date
modified_at: Date
is_deleted:  Int64
```

Records should live in a custom zone in the user's private database.

### 9.4 CKSyncEngine Integration

The sync module implements `CKSyncEngineDelegate`.

```swift
extension GraphSyncCoordinator: CKSyncEngineDelegate {
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Return pending local changes in safe batches.
    }

    func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .fetchedRecordZoneChanges(let changes):
            await applyRemoteChanges(changes)
        case .sentRecordZoneChanges(let changes):
            await markChangesSynced(changes)
        default:
            break
        }
    }
}
```

### 9.5 Conflict Resolution

Conflicts are resolved with a field-level three-way merge when possible.

Inputs:

- client record
- server record
- last-known ancestor record

Rules:

- if only the client changed a field, keep the client value
- if only the server changed a field, keep the server value
- if both changed the same field, server wins by default
- conflict decisions should be deterministic and tested

Applications may later need custom merge policies.

### 9.6 Batch Limits and Backoff

The sync module should use conservative batch sizes, such as 300 records per batch, and handle CloudKit limit errors by retrying with smaller batches.

The local store must remain usable while sync is delayed, throttled, offline, or waiting for retry.

### 9.7 Offline Behavior

When offline:

- reads and writes continue against the local store
- pending changes remain queued
- sync resumes when the system allows it
- no UI state should depend on an immediate CloudKit round-trip

---

## 10. Performance Targets

These are engineering targets, not API guarantees.

Measurements should be taken in release builds, on physical devices, with documented graph sizes, degree distributions, and cache conditions.

| Operation | Target | Condition |
|---|---|---|
| Node lookup by ID | < 1ms | Hash/index hit |
| 1-hop neighbor traversal | < 1ms | Warm in-memory topology |
| 4-hop BFS traversal | < 10ms | 20K node graph, average degree 10, warm topology |
| Node insert | < 5ms | Single local write, warm database |
| Property fetch, cached | < 0.1ms | LRU cache hit |
| Property fetch, uncached | < 5ms | SQLite lookup |
| Launch with valid snapshot | < 100ms | 100K node topology, mmap path |
| Launch without snapshot | < 2s | 100K nodes, rebuild path |
| Bulk import 20K nodes | < 3s | Explicit transaction |
| CloudKit sync delta | Background | Non-blocking to UI |

Benchmark results should include hardware, OS version, Swift version, build configuration, and dataset generator.

---

## 11. Stress Failure Modes and Mitigations

### 11.1 CSR Cache Thrash

**Scenario:** Deep traversal touches many cold nodes with scattered adjacency data.

**Failure:** CPU cache misses slow traversal.

**Mitigation:** Explore vertex reordering during compaction. Measure before enabling by default.

### 11.2 iOS Memory Pressure

**Scenario:** Large graph plus other app memory pressure.

**Failure:** App termination due to high resident memory.

**Mitigation:** Keep properties in SQLite, not permanently in the topology layer. Clear property caches on memory warning.

### 11.3 WAL Growth

**Scenario:** Sustained write bursts or large imports.

**Failure:** WAL grows and can affect disk usage or read performance.

**Mitigation:** Use explicit transactions, background checkpointing, and documented import APIs.

### 11.4 EdgeLog Growth

**Scenario:** Frequent writes without compaction.

**Failure:** Traversal must merge too many recent edge log entries.

**Mitigation:** Compact based on size threshold, app lifecycle, and explicit user calls.

### 11.5 CloudKit Throttling

**Scenario:** Large initial sync or frequent updates.

**Failure:** CloudKit returns throttling or limit errors.

**Mitigation:** Use CKSyncEngine, conservative batches, retry-after handling, and local-first UI.

### 11.6 Snapshot Invalidity

**Scenario:** Snapshot version mismatch, partial write, or corruption.

**Failure:** Startup cannot trust snapshot.

**Mitigation:** Validate metadata and checksum; discard and rebuild from SQLite.

---

## 12. Public API Design

### 12.1 Opening a Store

```swift
let graph = try await GraphStore.open(named: "MyGraph")
let graph = try await GraphStore.open(at: url)
let graph = try await GraphStore.openInMemory()
```

### 12.2 Node Operations

```swift
let id = try await graph.addNode(
    label: "Person",
    properties: ["name": .string("Alice"), "age": .int(32)]
)

let node = try await graph.node(id: id)

try await graph.updateNode(id: id, properties: ["age": .int(33)])
try await graph.deleteNode(id: id)
```

### 12.3 Edge Operations

```swift
let edgeID = try await graph.addEdge(
    from: aliceID,
    to: bobID,
    type: "KNOWS",
    properties: ["since": .int(2021)]
)

try await graph.deleteEdge(id: edgeID)
```

### 12.4 Query Builder

```swift
let people = try await graph
    .nodes(labeled: "Person")
    .where("age", greaterThan: .int(25))
    .collect()

let connected = try await graph
    .node(id: aliceID)
    .traverse(.outgoing, edge: "KNOWS")
    .where("id", equals: .string(bobID.uuidString))
    .exists()
```

### 12.5 Optional Sync Control

Sync APIs should be unavailable unless the optional CloudKit module is imported.

```swift
try await graph.enableCloudKitSync(container: .default)
try await graph.sync()

for await status in graph.syncStatus {
    // observe status
}
```

### 12.6 Optional Typed Schema Layer

Typed schema support is additive.

```swift
struct PersonNode: GraphNodeSchema {
    static let label = "Person"

    @NodeProperty var name: String
    @NodeProperty var age: Int
    @NodeProperty(indexed: true) var email: String
}
```

Open design point: whether this should be implemented with Swift macros, property wrappers, or both.

---

## 13. Schema and Versioning

### 13.1 Database Schema Version

`db_meta` stores schema metadata.

```sql
INSERT INTO db_meta VALUES ('schema_version', '1');
INSERT INTO db_meta VALUES ('graph_id', '<UUID generated at creation>');
```

Migrations are applied on open.

```swift
enum Migration {
    static let migrations: [(version: Int, sql: String)] = [
        (1, createInitialSchema)
    ]
}
```

### 13.2 CloudKit Schema Evolution

CloudKit schema changes must be additive unless a versioned migration plan exists. Optional module metadata should not affect local-only stores.

### 13.3 Graph Schema

Node labels and edge types are strings and are not enforced by the core engine. Optional schema validation may be added as a higher-level layer.

---

## 14. Testing Strategy

### 14.1 Unit Tests

- `PropertyValue` Codable round trips
- Node and edge equality/hashability
- adjacency operations
- EdgeLog merge rules
- label index updates
- property index behavior
- conflict resolution logic for optional sync

### 14.2 Integration Tests

- local read/write cycles against temporary SQLite stores
- traversal correctness against known graph topologies
- deletion and tombstone behavior
- rebuild from SQLite into in-memory topology
- WAL behavior under sustained write/read sequences

### 14.3 Sync Tests

Sync tests should follow a two-device simulation model.

```swift
let device1 = MockSyncEngine()
let device2 = MockSyncEngine()

let id = try await device1.graph.addNode(
    label: "Person",
    properties: ["name": .string("Alice")]
)

await device1.pushToServer()
await device2.pullFromServer()

try await device1.graph.updateNode(id: id, properties: ["age": .int(32)])
try await device2.graph.updateNode(id: id, properties: ["email": .string("alice@example.com")])

await device1.pushToServer()
await device2.pushToServer()
await device1.pullFromServer()
await device2.pullFromServer()
```

Expected result: both devices converge without losing independently changed fields.

### 14.4 Performance Tests

- launch time with and without snapshot
- traversal throughput under different graph shapes
- EdgeLog-heavy traversal overhead
- sustained insert throughput
- bulk import throughput
- SQLite WAL checkpoint behavior
- memory usage for topology at 10K, 100K, and 500K nodes

### 14.5 Contributor Test Guide

Before submitting a PR:

```bash
swift test
```

For targeted work:

```bash
swift test --filter TraversalTests
swift test --filter PersistenceTests
swift test --filter SyncTests
```

Benchmark tests are not required for ordinary PRs unless the PR changes storage layout, traversal, indexing, or compaction behavior.

---

## 15. Open Questions

### 15.1 EdgeLog merge strategy during traversal

When a traversal reads from both compacted adjacency and EdgeLog, EdgeLog entries should win because they are newer. The exact tombstone and duplicate-edge semantics need precise tests.

### 15.2 Snapshot file format

Options:

- raw binary arrays: fastest, least portable
- FlatBuffers: schema evolution, more tooling
- custom portable format: more control, more maintenance

### 15.3 Property index declaration

Should indexes be declared only when opening a store, or can they be added and dropped at runtime? Runtime changes require background rebuilds.

### 15.4 Soft delete retention

Deletes are soft initially to support sync and rebuild consistency. Hard deletion after a retention window is not yet designed.

### 15.5 CloudKit minimum deployment target

The sync module should target CKSyncEngine-supported platforms. The core package may still support local-only usage independently if practical.

### 15.6 Typed schema layer

Macros offer better compile-time validation. Property wrappers are simpler and more familiar. The design is unresolved.

### 15.7 Query language

A Cypher-compatible parser is out of scope for the core package. The query builder should still be designed so a separate frontend can compile into the same execution model.

---

## Appendix A: Key Research Papers

| Paper | Venue | Relevance |
|---|---|---|
| Kùzu Graph Database Management System | CIDR 2023 | Columnar node storage and CSR-style graph processing |
| LiveGraph: Transactional Graph Storage | VLDB 2020 | Transactional edge log design |
| LSMGraph: Multi-Level CSR | SIGMOD 2024 | Write buffering plus CSR-style read structures |
| A+ Indexes: Tunable Adjacency Lists | VLDB 2020 | Adjacency list index tradeoffs |
| Columnar Storage for GDBMSs | VLDB 2021 | Separating properties from topology |
| Empirical Evaluation of MVCC | VLDB 2017 | Concurrency model tradeoffs |
| CloudKit: Structured Storage for Mobile | VLDB 2018 | CloudKit architecture and change tracking |
| Packed CSR: Dynamic Graph Representation | IEEE 2018 | Dynamic CSR alternatives |

---

## Appendix B: Glossary

| Term | Definition |
|---|---|
| CSR | Compressed Sparse Row — a compact adjacency representation using offset and edge arrays |
| EdgeLog | Append-only buffer for recent edge changes before compaction |
| Index-free adjacency | Graph storage model optimized for following relationships rather than global lookups |
| WAL | Write-Ahead Log — SQLite journaling mode that improves read/write coexistence |
| CKSyncEngine | CloudKit framework API for managing app sync operations |
| LWW | Last Write Wins — conflict policy where the latest/server value wins for a field |
| Tombstone | Soft-delete marker used to propagate and reconcile deletion |
| Change token | CloudKit token representing a position in change history |
| Compaction | Process of merging recent writes into optimized read structures |

---

This specification is a living document. Sections marked experimental or open are expected to evolve based on implementation, benchmarks, and community feedback.
