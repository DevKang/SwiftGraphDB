# Enabling CloudKit sync

How to wire the CloudKit transport into your `GraphStore`.

## Requirements

- An app target with the iCloud capability and the **CloudKit** service enabled.
- A user signed into iCloud at runtime; without an account the transport stays offline and
  the local store keeps accepting writes.
- A custom CloudKit zone (default name `"SwiftGraphDB"`) in the user's private database.

## Wiring

Wrap a `CKContainer` with a ``CloudKitDatabase`` implementation, build the transport, and
register it through `enableSync`:

```swift
import SwiftGraphDB
import SwiftGraphDBCloudKit

let store = try await GraphStore.openInMemory()
let database = MyCloudKitDatabaseAdapter(container: .default(), zone: "SwiftGraphDB")
let transport = CloudKitGraphSyncTransport(
    backendID: SyncBackendID("primary"),
    database: database,
    configuration: .init(accountProbe: MyAccountProbe(container: .default()))
)

try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())
```

The reference repository ships a `MockCloudKitDatabase` and a `SharedMockCloudKitBackend` so
you can unit-test your wiring without an iCloud account.

## What the transport handles

- ``CloudKitGraphSyncTransport/Configuration`` controls batching (default 300 records),
  exponential backoff (capped at 5 minutes), and the iCloud account preflight.
- ``CloudKitGraphSyncTransport`` translates each ``GraphChange`` to a `CloudKitRecord` via
  ``RecordCodec``, splits oversize batches on `limitExceeded`, and respects `retryAfter`
  hints from the server.
- Errors typed for CloudKit are explicit: ``CloudKitTransportError`` for transient
  transport failures, ``CloudKitAccountError`` when the account is unavailable, and
  ``CloudKitConfigurationError`` for missing entitlements.

## What it does NOT handle

- The actual `CKSyncEngine`/`CKModifyRecordsOperation` plumbing — that's the
  ``CloudKitDatabase`` you provide.
- Cross-zone or shared-database scenarios — the protocol assumes one custom zone in the
  user's private database.

See ``ConflictResolution`` for resolver choice and ``OfflineBehaviour`` for what happens
when the network or account drops out.
