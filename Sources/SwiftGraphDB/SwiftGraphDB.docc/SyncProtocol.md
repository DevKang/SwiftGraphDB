# Sync protocol

Backend-agnostic replication for SwiftGraphDB.

## Overview

SwiftGraphDB ships a sync protocol that any cooperating backend can implement. The CloudKit
adapter (``SwiftGraphDBCloudKit``) is the reference implementation; an in-memory backend
(``InMemorySyncBackend``) is provided for tests and for SDK demos.

The core guarantees:

- Local reads and writes never depend on the network.
- Every committed write produces a durable ``GraphChange`` in `change_journal`.
- The sync loop drives push → pull → resolve → checkpoint per backend.

## Key types

- ``GraphChange`` — one committed mutation, in a backend-agnostic shape.
- ``GraphRevision`` — `(actorID, counter, wallClock)` tuple used to order changes.
- ``GraphSyncTransport`` — the boundary between core and any backend.
- ``GraphConflictResolver`` — your decision logic when remote and local diverge.

See SPEC §9 (the change journal), §10 (the sync loop), §11 (the transport contract) for
exhaustive detail.

## Enabling sync

```swift
let backend   = InMemorySyncBackend()
let device    = SyncBackendID("device-A")
let transport = await backend.transport(for: device)

try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())

// Drive a round manually:
let result = try await store.syncNow(backendID: device)
print("pushed \(result.pushed), applied \(result.applied)")

// Or observe status:
for await status in store.syncStatus {
    print(status)
}
```

## Conflict resolution

Three resolvers ship in core:

- ``FieldLevelMergeResolver`` — three-way merge per property. Each side keeps the field it
  changed; conflicts on the same field fall back to revision ordering.
- ``LocalWinsResolver`` — drop the remote change when it conflicts with a local divergence.
- ``RemoteWinsResolver`` — replace local with remote on every conflict.

For domain-specific rules (e.g. CRDT counters, list merges), implement
``GraphConflictResolver`` yourself.

## Writing a custom backend

`GraphSyncTransport` has two methods: `push(_:)` and `pull(since:)`. The contract suite
(``GraphSyncContract``) makes it cheap to TDD a new adapter against the same assertions
the in-memory and CloudKit backends pass.

```swift
struct MyTransport: GraphSyncTransport {
    let backendID: SyncBackendID
    func push(_ batch: ChangeBatch) async throws -> PushResult { /* ... */ }
    func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult { /* ... */ }
}
```

## See also

- ``SwiftGraphDBCloudKit`` — reference adapter.
- SPEC §9, §10, §11.
