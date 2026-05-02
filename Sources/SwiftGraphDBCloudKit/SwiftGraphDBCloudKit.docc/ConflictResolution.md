# Conflict resolution

Choosing a resolver, or building your own.

## Built-in resolvers

The core ships three resolvers (see ``GraphConflictResolver``):

- ``FieldLevelMergeResolver`` — three-way merge per property. Each device keeps the field it
  wrote; ties on the same field fall back to revision ordering. **Recommended default for
  most apps**.
- ``LocalWinsResolver`` — drop the remote change when it conflicts.
- ``RemoteWinsResolver`` — replace local with remote on every conflict.

## When the defaults are not enough

For data with custom merge semantics — counters, sets, ordered lists, CRDT-style structures
— implement ``GraphConflictResolver`` yourself:

```swift
struct CounterMergeResolver: GraphConflictResolver {
    func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution {
        guard
            let local  = conflict.local?.properties["count"]?.asInt,
            let remote = conflict.remote.properties["count"]?.asInt,
            let base   = conflict.base?.properties["count"]?.asInt
        else { return .useRemote }

        let merged = base + (local - base) + (remote - base)
        var properties = conflict.remote.properties
        properties["count"] = .int(merged)
        return .merge(GraphRecordPayload(
            properties: properties,
            label: conflict.local?.label ?? conflict.remote.label
        ))
    }
}
```

## Why conflicts surface from the transport, not core

The ``CloudKitGraphSyncTransport`` returns conflicts from `push` as
``SyncRejectionReason``.`conflict(remote:base:)`. The sync coordinator then dispatches that
to your resolver. Adapters never resolve themselves — they pass the data up so applications
keep control of merge policy.
