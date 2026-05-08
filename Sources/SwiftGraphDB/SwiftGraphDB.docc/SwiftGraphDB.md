# ``SwiftGraphDB``

An embedded property graph database for Swift apps on iOS and macOS. SQLite is the durable
source of truth; an in-memory adjacency layer accelerates traversal. Optional sync is provided
through a backend-agnostic protocol; the CloudKit adapter ships separately.

## Overview

SwiftGraphDB is intentionally small and opinionated. The core engine is a single Swift package
target with no external dependencies — it builds on Apple's bundled `SQLite3`. The package
splits into two products:

- ``SwiftGraphDB`` — the core engine: storage, in-memory topology, queries, sync protocol.
- ``SwiftGraphDBCloudKit`` — an optional reference adapter that maps the sync protocol onto
  CloudKit. Apps that don't need cloud sync can ignore it entirely.

> Important: SQLite is the source of truth. Launch snapshots are accelerators, not
> authoritative. CloudKit, when enabled, is a replication layer; local reads and writes never
> depend on network availability.

## Quick start

```swift
import SwiftGraphDB

let store = try await GraphStore.openInMemory()
let alice = try await store.addNode(label: "Person", properties: ["name": "Alice"])
let bob   = try await store.addNode(label: "Person", properties: ["name": "Bob"])
_ = try await store.addEdge(from: alice, to: bob, type: "KNOWS", properties: [:])

let people = try await store.nodes(labeled: "Person").collect()
print(people.count)  // 2
```

## Topics

### Getting started

- ``GraphStore``
- <doc:ModelingYourData>
- <doc:Querying>

### Architecture

- <doc:ConcurrencyModel>
- <doc:SyncProtocol>

### Core types

- ``Node``
- ``Edge``
- ``PropertyValue``
- ``NodeQuery``
- ``GraphPath``

### Sync protocol

- ``GraphChange``
- ``GraphRevision``
- ``GraphSyncTransport``
- ``GraphConflictResolver``
- ``FieldLevelMergeResolver``
- ``LocalWinsResolver``
- ``RemoteWinsResolver``

## See also

- [SPEC.md](https://github.com/DevKang/SwiftGraphDB/blob/main/SPEC.md) — full architectural
  specification.
- [README.md](https://github.com/DevKang/SwiftGraphDB/blob/main/README.md) — installation,
  examples, design rationale.
- [CHANGELOG.md](https://github.com/DevKang/SwiftGraphDB/blob/main/CHANGELOG.md) — release notes.
- [CONTRIBUTING.md](https://github.com/DevKang/SwiftGraphDB/blob/main/CONTRIBUTING.md) —
  how to file bugs and submit PRs.
