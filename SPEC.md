# SwiftGraphDB — Technical Specification

**Version:** 0.2-draft  
**Status:** Usable local engine / evolving public API  
**Last Updated:** 2026-05

---

## Document Purpose

This specification describes the target architecture, package boundaries, sync protocol, and implementation constraints for SwiftGraphDB. It is written for contributors, reviewers, and maintainers.

The README explains what the project is and how to start using it. This document explains how the system is intended to work internally, which parts are stable, and which decisions remain open.

---

## Design Summary

SwiftGraphDB is a local-first embedded graph database. The core package owns local graph semantics and durable storage. Sync is modeled as a backend-agnostic protocol over append-only graph changes.

The core package provides:

- property graph data model
- local graph store
- SQLite persistence
- traversal engine
- change journal
- sync protocol types
- conflict resolver hooks

The core package does **not** provide a concrete cloud backend. CloudKit, REST, Firebase, Supabase, or custom sync should be implemented as adapter packages.

This follows a pattern used by local-first systems: core data model and change protocol stay independent from transport and backend infrastructure.

---

## Design Stability

| Area | Status | Notes |
|---|---|---|
| Property graph model | Stable | Nodes, edges, labels, types, and properties are core concepts |
| Client-generated UUIDs | Stable | Required for offline-first local writes |
| Local SQLite persistence | Stable | SQLite is the durable source of truth |
| Change journal | Stable | Schema frozen for the 0.1.x line; adapter-side tables may evolve |
| Basic traversal API | Stable | Frozen for 0.1; covered by `PublicSurfaceTests` |
| Actor-based write serialization | Stable | Single-writer behaviour is part of the public contract |
| Sync protocol boundary | Stable | `GraphSyncTransport`, `GraphChange`, `GraphConflictResolver` frozen for 0.1 |
| CSR traversal internals | Stable-ish | Implementation may change without API break, but layout has settled |
| EdgeLog compaction | Stable-ish | Merge / tombstone rules covered by tests; tunables may move |
| Launch snapshot | Stable-ish | Format v1 frozen; future versions are accelerator-only |
| CloudKit adapter | Stable | Shipped as `SwiftGraphDBCloudKit` reference implementation, separate product |
| Typed schema layer | Future | Macro vs property-wrapper design deferred to post-0.1 |
| Query language frontend | Future | Out of scope for the core package |

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Package Boundaries](#2-package-boundaries)
3. [Data Model](#3-data-model)
4. [Core Storage Architecture](#4-core-storage-architecture)
5. [Persistence and Change Journal](#5-persistence-and-change-journal)
6. [In-Memory Layer](#6-in-memory-layer)
7. [Query Engine](#7-query-engine)
8. [Concurrency Model](#8-concurrency-model)
9. [Sync Protocol](#9-sync-protocol)
10. [Conflict Resolution](#10-conflict-resolution)
11. [Backend Adapters](#11-backend-adapters)
12. [Public API Design](#12-public-api-design)
13. [Performance Targets](#13-performance-targets)
14. [Stress Failure Modes and Mitigations](#14-stress-failure-modes-and-mitigations)
15. [Schema and Versioning](#15-schema-and-versioning)
16. [Testing Strategy](#16-testing-strategy)
17. [Open Questions](#17-open-questions)
18. [Appendix A: Design References](#appendix-a-design-references)
19. [Appendix B: Glossary](#appendix-b-glossary)

---

## 1. Goals and Non-Goals

### 1.1 Goals

- Provide an embedded property graph database for iOS and macOS applications
- Support on-device graph traversal without a server, daemon, JVM, or external database process
- Expose a Swift-native API using async/await and value-oriented model types
- Store durable graph data locally in SQLite
- Keep traversal paths optimized for relationship-heavy workloads
- Support graphs large enough for real mobile app use cases
- Be usable as a Swift Package with a single import for local graph usage
- Provide a backend-agnostic sync protocol for graph changes
- Keep concrete sync backends, including CloudKit, outside the core package

### 1.2 Non-Goals

This specification explicitly excludes the following from the core package. They may be revisited in future versions or separate packages.

- **Mandatory cloud sync.** The database must work fully offline and fully local.
- **Specific cloud backend.** The core package does not depend on CloudKit, Firebase, Supabase, REST servers, or any network service.
- **Multi-user collaboration policy.** The core can support sync mechanics, but product-level collaboration semantics are adapter or app concerns.
- **A query language.** No Cypher, SPARQL, SQL, or custom textual DSL in the core package. A query language may be added later as an optional frontend.
- **Distributed operation.** No sharding, cluster replication, leader election, or consensus algorithms.
- **Server deployment.** SwiftGraphDB is optimized for Apple app processes, not Linux server deployment.
- **Graph analytics engine.** Algorithms such as PageRank, community detection, and GPU acceleration are out of scope for the core engine.

---

## 2. Package Boundaries

SwiftGraphDB should be structured so that local graph storage remains useful without optional infrastructure.

### 2.1 Core Package: `SwiftGraphDB`

The core package contains:

- data model types
- local graph store
- SQLite persistence
- traversal engine
- query builder
- local transaction and concurrency behavior
- append-only change journal
- sync protocol types
- conflict resolver interfaces
- test utilities for in-memory and temporary-file stores

The core package must not require:

- CloudKit entitlements
- an iCloud account
- network access
- a configured CloudKit container
- backend SDKs such as Firebase or Supabase

### 2.2 CloudKit Adapter: `SwiftGraphDBCloudKit`

CloudKit support should live behind a clear module boundary.

```swift
import SwiftGraphDB
import SwiftGraphDBCloudKit

let graph = try await GraphStore.open(named: "MyGraph")
let transport = CloudKitGraphSyncTransport(
    container: .default,
    databaseScope: .private,
    zoneName: "graphdb-private"
)

try await graph.enableSync(transport: transport, resolver: .fieldLevelMerge())
```

The CloudKit adapter may depend on:

- CloudKit
- CKSyncEngine
- CloudKit record zones
- CloudKit retry and throttle behavior
- CloudKit change tags and server records

None of those concepts should be exposed through the core package API.

### 2.3 Future Extension Packages

Potential future packages:

- `SwiftGraphDBREST` — REST reference sync adapter
- `SwiftGraphDBFirebase` — Firebase adapter, if demand exists
- `SwiftGraphDBSupabase` — Supabase/Postgres adapter, if demand exists
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
| `revision` | `GraphRevision` | Local logical revision for sync and conflict detection |
| `isDeleted` | `Bool` | Tombstone marker for local deletion and sync propagation |

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
| `revision` | `GraphRevision` | Local logical revision for sync and conflict detection |
| `isDeleted` | `Bool` | Tombstone marker for local deletion and sync propagation |

Edges are directed. An undirected relationship can be modeled as two directed edges or traversed with direction-insensitive APIs.

### 3.3 PropertyValue

Properties are typed values. Supported primitive types are chosen to map cleanly to Codable, SQLite serialization, and backend adapter serialization.

```swift
public enum PropertyValue: Codable, Hashable, Sendable {
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

- Values must be `Codable`.
- Values should be deterministic when serialized.
- Equality and hashing must be stable for index usage.
- Large binary blobs are allowed but discouraged for hot traversal workloads.
- Adapter packages may impose stricter limits depending on backend capabilities.

### 3.4 IDs

Both `NodeID` and `EdgeID` are UUID-backed value types or typealiases.

```swift
public typealias NodeID = UUID
public typealias EdgeID = UUID
```

UUIDs are generated client-side at creation time. This avoids server round-trips and makes offline writes possible.

### 3.5 Revisions

Revisions are used to order local changes and detect conflicts across sync backends.

```swift
public struct GraphRevision: Codable, Hashable, Sendable {
    public var actorID: ActorID
    public var counter: Int64
    public var wallClock: Date
}
```

Initial revision semantics:

- Each store has a stable `actorID`.
- Each committed local write increments a monotonic local `counter`.
- `wallClock` is metadata and tie-breaker input, not the primary source of causality.
- Full vector clocks are intentionally deferred. They are more expressive but add storage and API complexity.

This revision model is sufficient for ordered local journals, backend checkpoints, and default three-way merge. It is not intended to prove full distributed causal ordering across arbitrary peers.

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
│              Change Journal                          │
│  Append-only committed graph changes                 │
│  Feeds sync transports and local audit/debug tools   │
├─────────────────────────────────────────────────────┤
│              Sync Protocol Boundary                  │
│  GraphChange + GraphSyncTransport + ConflictResolver │
└─────────────────────────────────────────────────────┘
```

### 4.1 Key Invariants

- SQLite is the durable source of truth.
- In-memory structures are rebuildable from SQLite.
- The change journal is append-only for committed mutations.
- Snapshots are launch accelerators only.
- Sync transports never mutate in-memory state directly.
- Local reads and writes must not depend on network availability.
- Backend-specific state is stored by backend ID and remains opaque to core.

### 4.2 Write Path

A successful local write must atomically:

1. Validate graph invariants.
2. Apply the node or edge mutation to SQLite.
3. Append a `GraphChange` to `change_journal`.
4. Update in-memory adjacency/index structures.
5. Notify observers and sync schedulers.

SQLite transaction boundaries must cover steps 2 and 3. If the process crashes after SQLite commit but before in-memory update, the in-memory state is rebuilt from SQLite on next open.

### 4.3 Read Path

Traversal-heavy reads should use in-memory topology. Property-heavy reads may fetch from SQLite or a bounded property cache.

Read paths must observe a consistent topology snapshot. They should not require repeated actor hops for each traversal step.

---

## 5. Persistence and Change Journal

### 5.1 SQLite Schema

The local database uses SQLite in WAL mode with the following core schema.

```sql
-- Node property storage
CREATE TABLE nodes (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    properties  BLOB NOT NULL,
    created_at  REAL NOT NULL,
    modified_at REAL NOT NULL,
    revision    TEXT NOT NULL,
    is_deleted  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_nodes_label ON nodes(label) WHERE is_deleted = 0;
CREATE INDEX idx_nodes_revision ON nodes(revision);

-- Edge storage
CREATE TABLE edges (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    from_id     TEXT NOT NULL REFERENCES nodes(id),
    to_id       TEXT NOT NULL REFERENCES nodes(id),
    properties  BLOB NOT NULL,
    created_at  REAL NOT NULL,
    modified_at REAL NOT NULL,
    revision    TEXT NOT NULL,
    is_deleted  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_edges_from ON edges(from_id) WHERE is_deleted = 0;
CREATE INDEX idx_edges_to   ON edges(to_id)   WHERE is_deleted = 0;
CREATE INDEX idx_edges_type ON edges(type)    WHERE is_deleted = 0;
CREATE INDEX idx_edges_revision ON edges(revision);

-- Append-only graph changes for sync adapters
CREATE TABLE change_journal (
    sequence       INTEGER PRIMARY KEY AUTOINCREMENT,
    change_id      TEXT NOT NULL UNIQUE,
    graph_id       TEXT NOT NULL,
    actor_id       TEXT NOT NULL,
    entity_kind    TEXT NOT NULL CHECK (entity_kind IN ('node', 'edge')),
    entity_id      TEXT NOT NULL,
    operation      TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
    payload        BLOB,
    base_revision  TEXT,
    revision       TEXT NOT NULL,
    created_at     REAL NOT NULL,
    compacted_at   REAL
);

CREATE INDEX idx_change_journal_entity ON change_journal(entity_kind, entity_id);
CREATE INDEX idx_change_journal_sequence ON change_journal(sequence);
CREATE INDEX idx_change_journal_uncompacted ON change_journal(sequence) WHERE compacted_at IS NULL;

-- Backend-specific checkpoints. The checkpoint bytes are opaque to core.
CREATE TABLE sync_checkpoints (
    backend_id      TEXT PRIMARY KEY,
    checkpoint      BLOB,
    high_watermark  INTEGER NOT NULL DEFAULT 0,
    updated_at      REAL NOT NULL
);

-- Last common synced base per backend and record.
CREATE TABLE sync_record_versions (
    backend_id            TEXT NOT NULL,
    entity_kind           TEXT NOT NULL CHECK (entity_kind IN ('node', 'edge')),
    entity_id             TEXT NOT NULL,
    last_synced_revision  TEXT NOT NULL,
    base_payload          BLOB,
    updated_at            REAL NOT NULL,
    PRIMARY KEY (backend_id, entity_kind, entity_id)
);

-- Schema version tracking
CREATE TABLE db_meta (
    key     TEXT PRIMARY KEY,
    value   TEXT NOT NULL
);

INSERT INTO db_meta VALUES ('schema_version', '2');
INSERT INTO db_meta VALUES ('graph_id', '<UUID generated at creation>');
INSERT INTO db_meta VALUES ('actor_id', '<UUID generated per local store>');
```

### 5.2 Backend-Specific Metadata

The core schema intentionally does not include CloudKit record names, server change tags, Firebase document paths, or REST ETags. Adapter packages may store backend-specific metadata in their own tables using a namespaced prefix, for example:

```sql
CREATE TABLE cloudkit_record_map (...);
CREATE TABLE rest_sync_etags (...);
```

Adapter tables must be optional and removable without corrupting the core local graph store.

### 5.3 WAL Configuration

Applied once on database open:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;   -- 128MB virtual mmap
PRAGMA cache_size = -32000;     -- 32MB page cache
PRAGMA wal_autocheckpoint = 100;
```

`synchronous = NORMAL` in WAL mode trades maximum power-loss durability for lower write latency. This is acceptable for many on-device single-user apps, but apps with stricter durability needs should be able to configure `synchronous = FULL`.

### 5.4 Launch Snapshot

On first launch and after major compactions, the adjacency structure may be serialized to a binary snapshot file alongside the SQLite database.

```text
Application Support/
  MyGraph/
    graph.sqlite
    graph.sqlite-wal
    graph.snapshot
    graph.snapshot.meta
```

The snapshot is purely a launch accelerator. It is never the source of truth. It is always rebuildable from SQLite.

### 5.5 Bulk Import

When inserting large numbers of nodes or edges at once, callers should use the bulk API:

```swift
try await graph.bulkInsert { batch in
    for node in thousandsOfNodes {
        batch.addNode(label: node.label, properties: node.properties)
    }
}
```

Bulk inserts are wrapped in a single SQLite transaction or bounded transaction chunks. Very large imports should avoid unbounded single transactions.

---

## 6. In-Memory Layer

### 6.1 Adjacency Representation

The target representation for optimized traversal is Compressed Sparse Row (CSR). CSR stores adjacency as contiguous arrays, which improves cache locality for graph traversal.

```swift
struct CSRAdjacency: Sendable {
    var offsets: [Int]
    var edges: [EdgeRecord]
}

struct EdgeRecord: Sendable {
    var toID: NodeID
    var edgeID: EdgeID
    var type: String
}
```

Both outgoing and incoming adjacency should be supported. Maintaining separate forward and reverse structures avoids full scans for incoming traversal.

### 6.2 Internal ID Mapping

Nodes are accessed externally by UUID but stored internally by a compact integer index.

```swift
var nodeIDToIndex: [NodeID: Int]
var indexToNodeID: [Int: NodeID]
```

The mapping is rebuildable from SQLite and should remain stable within a topology snapshot.

### 6.3 EdgeLog Write Buffer

Static CSR is expensive to update. Writes go to an EdgeLog first, then compact into CSR later.

```swift
struct EdgeLogEntry: Sendable {
    let edgeID: EdgeID
    let fromID: NodeID
    let toID: NodeID
    let type: String
    let revision: GraphRevision
    let operation: GraphOperation
}
```

During traversal, the engine reads CSR and overlays relevant EdgeLog entries. Newer EdgeLog entries win over older CSR state.

### 6.4 Label Index

```swift
var labelIndex: [String: Set<NodeID>]
```

Maps each label string to the set of all non-deleted node IDs with that label.

### 6.5 Property Indexes

Property indexes are opt-in. Maintaining an index on every property would consume too much memory for an on-device store.

```swift
var propertyIndex: [String: [PropertyValue: Set<NodeID>]]
```

Runtime index creation requires a background rebuild pass and should be treated as an evolving feature.

---

## 7. Query Engine

### 7.1 Public Query API

```swift
graph.nodes(labeled: "Person")
graph.node(id: someUUID)
graph.nodes(where: "age", greaterThan: .int(30))
```

Traversal operations:

```swift
.traverse(.outgoing, edge: "KNOWS")
.traverse(.incoming, edge: "KNOWS")
.traverse(.both, edge: "KNOWS", maxDepth: 3)
.traverse(.outgoing, maxDepth: .unlimited)
```

Collect operations:

```swift
.collect()
.collectWithEdges()
.count()
.first()
.exists()
```

### 7.2 Execution Model

Queries are executed as a lazy pipeline of operations:

```text
Source -> Filter -> Traverse -> Filter -> Collect
```

Each stage can be represented as an `AsyncSequence` or equivalent lazy iterator. Intermediate results should not be materialized unless required by a terminal operation.

### 7.3 Path Queries

```swift
let path = try await graph.shortestPath(from: aliceID, to: bobID, via: "KNOWS")
let paths = try await graph.allPaths(from: aliceID, to: bobID, maxDepth: 5)
```

Shortest path uses BFS for unweighted edges and Dijkstra when edge weights are provided.

---

## 8. Concurrency Model

### 8.1 MURSIW Semantics

SwiftGraphDB uses Multiple Reader, Single Writer semantics. This matches a local embedded database with many read-heavy UI queries and serialized writes.

### 8.2 Swift Actor Isolation

The `GraphActor` owns mutable in-memory state:

```swift
actor GraphActor {
    var csr: CSRAdjacency
    var edgeLog: [EdgeLogEntry]
    var labelIndex: [String: Set<NodeID>]
    var propertyCache: LRUCache<NodeID, [String: PropertyValue]>
    let sqliteStore: SQLiteStore
}
```

All writes serialize through the actor. Hot traversal reads should run against immutable topology snapshots after a short actor-isolated snapshot step.

### 8.3 Background Tasks

Compaction and sync scheduling run as structured concurrency tasks. Detached tasks must not mutate graph state directly; they should call actor-isolated APIs.

```swift
actor GraphActor {
    func startBackgroundTasks() {
        Task(priority: .background) {
            await self.runCompactionLoop()
        }
    }
}
```

---

## 9. Sync Protocol

### 9.1 Design Principle

The core sync design is change-based and backend-agnostic.

- Local writes append `GraphChange` records to `change_journal`.
- Sync transports push and pull batches of `GraphChange` values.
- Transport-specific checkpoints are opaque byte payloads.
- Conflict resolution is defined over graph records, not backend records.
- Backend adapters do not apply changes directly to the store.

### 9.2 GraphChange

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

public enum GraphOperation: String, Codable, Sendable {
    case upsert
    case delete
}

public struct GraphEntityRef: Codable, Sendable, Hashable {
    public let kind: GraphEntityKind
    public let id: UUID
}

public enum GraphEntityKind: String, Codable, Sendable {
    case node
    case edge
}
```

Rules:

- `payload` is required for `upsert`.
- `payload` is optional for `delete`, but tombstone metadata must be preserved.
- `sequence` is local to one store and used for journal ordering.
- `id` must be stable and globally unique.
- `revision` identifies the entity version after applying the change.
- `baseRevision` identifies the entity version the change was based on, if known.

### 9.3 ChangeBatch

```swift
public struct ChangeBatch: Codable, Sendable {
    public let graphID: GraphID
    public let backendID: SyncBackendID
    public let changes: [GraphChange]
    public let highWatermark: Int64
}
```

Batches should be bounded by count and serialized size. Backend adapters may impose stricter limits.

### 9.4 SyncCheckpoint

```swift
public struct SyncCheckpoint: Codable, Sendable, Hashable {
    public let backendID: SyncBackendID
    public let data: Data
}
```

The checkpoint is opaque to core. Examples:

- CloudKit server change token
- REST server cursor
- Firebase last update marker
- Supabase logical replication position
- local-file sync manifest version

### 9.5 GraphSyncTransport

```swift
public protocol GraphSyncTransport: Sendable {
    var backendID: SyncBackendID { get }

    func push(_ batch: ChangeBatch) async throws -> PushResult
    func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult
}
```

A transport is responsible for:

- serializing changes into backend-specific records or requests
- sending local changes
- fetching remote changes
- returning backend checkpoints
- reporting conflicts or validation failures
- honoring backend limits and retry hints

A transport is **not** responsible for:

- mutating `GraphStore` directly
- resolving graph conflicts
- enforcing graph invariants
- deciding tombstone retention
- exposing backend-specific concepts in core APIs

### 9.6 PushResult and PullResult

```swift
public struct PushResult: Sendable {
    public let accepted: [ChangeID]
    public let rejected: [SyncRejection]
    public let checkpoint: SyncCheckpoint?
}

public struct PullResult: Sendable {
    public let changes: [GraphChange]
    public let checkpoint: SyncCheckpoint
    public let hasMore: Bool
}

public struct SyncRejection: Sendable {
    public let changeID: ChangeID
    public let reason: SyncRejectionReason
}

public enum SyncRejectionReason: Sendable {
    case conflict(remote: GraphRecordPayload, base: GraphRecordPayload?)
    case validationFailed(String)
    case transient(String)
    case permanent(String)
}
```

### 9.7 Sync Loop

A default sync loop should follow this order:

1. Read unsynced local changes from `change_journal` after the backend high-watermark.
2. Push changes in sequence order.
3. Mark accepted changes for that backend.
4. Pull remote changes since the stored backend checkpoint.
5. Apply remote changes through the conflict resolver.
6. Update `sync_checkpoints` and `sync_record_versions` in one SQLite transaction.
7. Repeat while `hasMore == true`.

Sync must be retryable and idempotent. Re-sending an accepted change should not corrupt state.

### 9.8 Partial Sync and Subgraph Sync

The initial sync protocol assumes full-graph sync for one local graph. Partial sync is deferred because it affects:

- edge endpoint availability
- conflict detection
- tombstone retention
- query consistency
- backend checkpoint semantics

Adapters should not invent incompatible partial sync semantics before the core protocol defines them.

---

## 10. Conflict Resolution

### 10.1 Conflict Model

Conflict resolution is defined over graph records:

```swift
public struct GraphConflict: Sendable {
    public let backendID: SyncBackendID
    public let entity: GraphEntityRef
    public let base: GraphRecordPayload?
    public let local: GraphRecordPayload?
    public let remote: GraphRecordPayload
}
```

Definitions:

- `base`: last common synced version known to this backend
- `local`: current local version, or nil if locally deleted
- `remote`: incoming remote version

### 10.2 ConflictResolver

```swift
public protocol GraphConflictResolver: Sendable {
    func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution
}

public enum GraphConflictResolution: Sendable {
    case useLocal
    case useRemote
    case merge(GraphRecordPayload)
    case delete
    case fail(String)
}
```

### 10.3 Built-In Resolvers

Core should provide simple policies:

```swift
public struct RemoteWinsResolver: GraphConflictResolver { ... }
public struct LocalWinsResolver: GraphConflictResolver { ... }
public struct FieldLevelMergeResolver: GraphConflictResolver { ... }
```

Recommended default for early versions:

- Upsert vs upsert: field-level three-way merge
- Same-field conflict: remote wins by default
- Delete vs delete: delete
- Delete vs update: fail unless the app selects `remoteWins` or `deleteWins`

Delete/update conflicts are intentionally not silently resolved by the default resolver because silent deletion or resurrection can surprise users.

### 10.4 Graph Invariants During Merge

The merge result must preserve graph invariants:

- An edge cannot point to a missing non-deleted node.
- Deleting a node must tombstone or detach incident edges according to the configured policy.
- Remote edge upserts whose endpoints have not arrived yet should be deferred until dependencies arrive or rejected as invalid.
- Conflict resolution must not create duplicate edge IDs.
- Tombstones must be retained long enough for all configured backends to observe deletes.

### 10.5 Why Core Owns Conflict Semantics

Backends understand records, documents, rows, or blobs. They do not understand graph topology. Core must own conflict hooks because only core can validate node/edge relationships and preserve traversal correctness.

---

## 11. Backend Adapters

### 11.1 Adapter Contract

Every adapter must implement `GraphSyncTransport` and pass shared contract tests:

- push accepted changes
- pull remote changes
- preserve change IDs
- preserve revisions
- round-trip tombstones
- resume from checkpoint
- handle duplicate pushes idempotently
- surface conflicts without applying them directly

### 11.2 CloudKit Adapter

`SwiftGraphDBCloudKit` should be the first reference adapter.

Responsibilities:

- Map `GraphChange` to CloudKit records.
- Store CloudKit record IDs, change tags, and zone metadata in adapter-owned tables.
- Use a private database by default.
- Use a custom zone for graph records.
- Use `CKSyncEngine` when available.
- Respect CloudKit batching, retry, throttle, and account-state behavior.
- Convert CloudKit conflicts into `SyncRejectionReason.conflict` or pulled remote changes.

The core package should not expose `CKRecord`, `CKRecordZone.ID`, `CKSyncEngine`, or CloudKit change tokens.

### 11.3 REST Adapter

A REST adapter can be used as the simplest backend-independent reference.

Suggested endpoints:

```text
POST /graphdb/sync/push
POST /graphdb/sync/pull
```

Push request:

```json
{
  "graphID": "...",
  "backendID": "rest-main",
  "changes": [],
  "highWatermark": 123
}
```

Pull request:

```json
{
  "graphID": "...",
  "checkpoint": "opaque-server-cursor"
}
```

The server may choose its own canonical storage model as long as it preserves the `GraphChange` contract.

### 11.4 Adapter Versioning

Adapters should declare:

- supported sync protocol version
- supported payload format version
- backend-specific limits
- tombstone retention assumptions
- checkpoint compatibility rules

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

Deletes are soft deletes at the persistence layer. Physical cleanup is governed by tombstone retention.

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

let network = try await graph
    .node(id: aliceID)
    .traverse(.outgoing, edge: "KNOWS", maxDepth: 3)
    .collect()

let path = try await graph.shortestPath(from: aliceID, to: bobID)
```

### 12.5 Sync Control

```swift
try await graph.enableSync(
    transport: MySyncTransport(),
    resolver: FieldLevelMergeResolver()
)

for await status in graph.syncStatus {
    switch status {
    case .idle:
        break
    case .syncing(let backendID):
        showSyncIndicator(backendID)
    case .conflict(let conflict):
        presentConflict(conflict)
    case .error(let backendID, let error):
        handleSyncError(backendID, error)
    }
}

try await graph.syncNow(backendID: "cloudkit-private")
```

### 12.6 Schema Declaration (Optional)

For apps that want compile-time property safety:

```swift
struct PersonNode: GraphNodeSchema {
    static let label = "Person"

    @NodeProperty var name: String
    @NodeProperty var age: Int
    @NodeProperty(indexed: true) var email: String
}
```

This layer is additive. The underlying `[String: PropertyValue]` model remains available.

---

## 13. Performance Targets

These are engineering targets, not API guarantees. They should be measured on release builds, warm cache where applicable, and iPhone 12-class hardware or later unless otherwise stated.

| Operation | Target | Condition |
|---|---|---|
| Node lookup by ID | < 1ms | Hash index hit |
| 1-hop neighbor traversal | < 1ms | In-memory adjacency |
| 4-hop BFS traversal | < 10ms | 20K node graph, average degree 10 |
| Node insert | < 5ms | SQLite row + change journal append |
| Property fetch, cached | < 0.1ms | LRU cache hit |
| Property fetch, uncached | < 5ms | SQLite lookup |
| Launch with snapshot | < 100ms | mmap or equivalent snapshot load |
| Launch without snapshot | < 2s | SQLite rebuild, 100K nodes |
| Bulk import 20K nodes | < 3s | Bounded transaction batching |
| Sync push/pull | Background | Non-blocking to UI |

---

## 14. Stress Failure Modes and Mitigations

### 14.1 CSR Cache Thrash

**Scenario:** Deep traversal touching many cold nodes with scattered adjacency data.

**Mitigation:** Background vertex reordering. Nodes are sorted by access frequency so frequently co-traversed nodes are physically adjacent in adjacency arrays.

### 14.2 iOS Memory Pressure

**Scenario:** Device under memory pressure.

**Mitigation:** Properties are not stored in CSR. The LRU property cache is cleared first. Topology structures are compact and rebuildable.

### 14.3 WAL Unbounded Growth

**Scenario:** Rapid writes cause the WAL file to grow faster than checkpointing.

**Mitigation:** Lower autocheckpoint threshold, background checkpointing, bounded bulk import transactions, and explicit checkpoint API for apps with bursty writes.

### 14.4 Change Journal Growth

**Scenario:** Sync is disabled or unavailable for a long time.

**Mitigation:** Keep the change journal append-only until each configured backend reaches a safe high-watermark. Compact older changes into per-record base payloads only after tombstone and checkpoint requirements are satisfied.

### 14.5 Backend Throttling

**Scenario:** CloudKit, REST, or another backend rate-limits sync.

**Mitigation:** Transports return retryable errors and retry hints. The local store is unaffected. UI reads from local state.

### 14.6 Remote Edge Arrives Before Node

**Scenario:** Pull returns an edge before one or both endpoint nodes.

**Mitigation:** Apply nodes before edges within a batch. If endpoints are still missing, defer the edge in a pending-remote table or reject it as invalid according to adapter policy.

### 14.7 Delete / Update Conflict

**Scenario:** One device deletes a node while another updates it.

**Mitigation:** Default resolver fails the conflict rather than silently deleting or resurrecting data. Apps must choose a delete policy or provide a custom resolver.

---

## 15. Schema and Versioning

### 15.1 Database Schema Version

The `db_meta` table stores a `schema_version` integer. On open, SwiftGraphDB checks the version and applies migrations if needed.

```swift
enum Migration {
    static let migrations: [(version: Int, sql: String)] = [
        (1, createInitialSchema),
        (2, addChangeJournalAndSyncProtocolTables)
    ]
}
```

### 15.2 Sync Protocol Version

The sync protocol should have an explicit version independent of the SQLite schema.

```swift
public struct SyncProtocolVersion: Codable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
}
```

Breaking changes to `GraphChange` serialization require a major protocol version bump.

### 15.3 Payload Format Version

`GraphRecordPayload` should include a payload format version so adapters can reject unsupported records cleanly.

### 15.4 Graph Schema

Node labels and edge types are not enforced by the database engine. Any string is a valid label or edge type. Optional schema validation may be added as a higher-level layer.

---

## 16. Testing Strategy

### 16.1 Unit Tests

- Data model Codable round trips
- Revision ordering
- Change journal append behavior
- Conflict resolver behavior
- CSR traversal correctness
- Tombstone behavior

### 16.2 Integration Tests

- Full read/write cycles against an in-memory SQLite store
- Traversal correctness against known graph topologies
- WAL behavior under concurrent read/write actor tasks
- Change journal consistency after crash simulation

### 16.3 Sync Protocol Contract Tests

All adapters must pass shared contract tests using a fake backend harness:

- local write -> push -> remote pull
- remote write -> pull -> local apply
- duplicate push idempotency
- checkpoint resume
- upsert/upsert conflict
- delete/update conflict
- tombstone propagation
- large batch pagination
- transient backend failure and retry

### 16.4 Multi-Device Simulation

```swift
let backend = InMemorySyncBackend()
let device1 = try await GraphStore.openInMemory(actorID: .device1)
let device2 = try await GraphStore.openInMemory(actorID: .device2)

try await device1.enableSync(transport: backend.transport(for: .device1))
try await device2.enableSync(transport: backend.transport(for: .device2))

let id = try await device1.addNode(label: "Person", properties: ["name": .string("Alice")])
try await device1.syncNow()
try await device2.syncNow()

let node = try await device2.node(id: id)
XCTAssertEqual(node?.properties["name"], .string("Alice"))
```

### 16.5 Performance Tests

- Launch time with snapshot vs without snapshot
- Traversal throughput on CSR vs EdgeLog-heavy state
- Write throughput under sustained insert load
- WAL checkpoint behavior under burst writes
- Change journal growth and compaction
- Sync batch serialization cost

---

## 17. Open Questions

The original v2 open questions, with the resolution that ships in 0.1.0. Items marked
**Deferred** roll forward to a future Open Questions section once 0.1 is tagged.

**17.1 Sync protocol package location** — *Resolved.* Sync protocol types live in core
(`SwiftGraphDB`). Local writes always produce changes; adapters consume them.

**17.2 Revision model** — *Resolved for 0.1.* `(actorID, counter, wallClock)` ships as
`GraphRevision`. Adapter authors observe a `Comparable` ordering; vector clocks are deferred
to post-0.1 if real-world conflict patterns demand it.

**17.3 Tombstone retention** — *Resolved.* Tombstones are retained until every configured
backend has acknowledged the delete via `sync_record_versions`. Apps can configure an
additional grace window through the journal compaction policy (defaults to "keep forever").

**17.4 Delete/update conflict default** — *Resolved.* The default
`FieldLevelMergeResolver` falls through to `.useRemote` for delete-vs-update because deletes
in this codebase are explicit user actions. Apps that need different semantics implement a
custom `GraphConflictResolver`.

**17.5 Partial sync** — *Deferred.* Subgraph sync is not part of 0.1; the protocol assumes
the entire graph (or nothing) replicates per backend. Tracked for a future
`GraphSyncFilter`-style API.

**17.6 Snapshot file format** — *Resolved.* Format v1 ships: a custom packed format with
`SGDBSNP1` magic + CRC32 footer. Documented in §6.4 and validated by
`SnapshotFormatTests`.

**17.7 Property index declaration** — *Resolved for 0.1.* Indexes are declared at
`GraphStore.Options.propertyIndexSpecs` time. Runtime add/drop is deferred — easier to add
later without breaking anything.

**17.8 Typed schema layer** — *Deferred.* Out of scope for 0.1. Macro-based DSL is the
likely direction once Swift macro tooling settles.

**17.9 Query language frontend** — *Deferred (out of scope for v1).* The query builder
intentionally avoids leaking SQL or Cypher syntax so a future frontend can be added without
breaking the value-typed API.

---

## Appendix A: Design References

### Graph storage references

| Topic | Relevance |
|---|---|
| Kùzu Graph Database Management System | Columnar node storage, CSR-style adjacency, graph query execution |
| LiveGraph: Transactional Graph Storage | Transactional edge log design |
| LSMGraph: Multi-Level CSR | Write buffer plus read-optimized adjacency structures |
| A+ Indexes | Tunable adjacency list indexing |
| Columnar Storage for GDBMSs | Separating node/edge topology from properties |
| MVCC empirical evaluations | Concurrency tradeoffs for read-heavy workloads |
| Packed CSR | Dynamic CSR-style graph representation |

### Local-first and sync references

| Project / system | Design lesson |
|---|---|
| Automerge Repo | Core document state can be paired with pluggable storage and networking adapters |
| Yjs | Providers can handle network and persistence while the core data model remains provider-agnostic |
| Replicache | Push/pull sync contracts keep local-first client behavior independent from backend implementation |
| RxDB | Replication can target multiple backend types when conflict handling is modeled at the client/database layer |
| CloudKit / CKSyncEngine | Apple-specific adapter can provide strong private-user sync without becoming a core dependency |
| SQLite WAL | Durable local embedded storage with read/write concurrency tradeoffs suitable for app-local data |

---

## Appendix B: Glossary

| Term | Definition |
|---|---|
| **ActorID** | Stable identifier for one local store/device actor that produces revisions |
| **Backend adapter** | Package that maps `GraphChange` batches to a concrete backend such as CloudKit or REST |
| **Change journal** | Append-only SQLite table of committed graph changes |
| **Checkpoint** | Opaque backend cursor representing sync progress |
| **CSR** | Compressed Sparse Row — a two-array format for storing adjacency lists with cache-efficient sequential access |
| **EdgeLog** | Append-only buffer for hot edge writes before compaction into adjacency structures |
| **GraphChange** | Backend-agnostic representation of a committed node or edge mutation |
| **GraphRevision** | Logical revision `(actorID, counter, wallClock)` used for conflict detection |
| **MURSIW** | Multiple Reader Single Writer — many concurrent readers with one serialized writer |
| **MVCC** | Multi-Version Concurrency Control — stores multiple versions to support concurrent reads/writes |
| **Tombstone** | Soft-delete marker retained so deletion can be propagated to sync backends |
| **Transport** | Backend-specific IO implementation that pushes and pulls change batches |
| **WAL** | Write-Ahead Log — SQLite durability mechanism where changes are written to a log before checkpointing into the main database file |

---

*This specification is a living document. Sections marked as experimental or open questions are subject to change based on implementation findings and community discussion.*
