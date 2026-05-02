import Foundation

/// Three-way conflict context: base (last common synced) + local + remote payloads.
public struct GraphConflict: Sendable {
    public let backendID: SyncBackendID
    public let entity: GraphEntityRef
    public let base: GraphRecordPayload?
    public let local: GraphRecordPayload?
    public let remote: GraphRecordPayload

    public init(
        backendID: SyncBackendID,
        entity: GraphEntityRef,
        base: GraphRecordPayload?,
        local: GraphRecordPayload?,
        remote: GraphRecordPayload
    ) {
        self.backendID = backendID
        self.entity = entity
        self.base = base
        self.local = local
        self.remote = remote
    }
}

public enum GraphConflictResolution: Sendable {
    case useLocal
    case useRemote
    case merge(GraphRecordPayload)
    case delete
    case fail(String)
}

public protocol GraphConflictResolver: Sendable {
    func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution
}

// MARK: - Built-in resolvers

public struct RemoteWinsResolver: GraphConflictResolver {
    public init() {}
    public func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution {
        if conflict.local == nil { return .useRemote }
        return .useRemote
    }
}

public struct LocalWinsResolver: GraphConflictResolver {
    public init() {}
    public func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution {
        if conflict.local == nil { return .useRemote } // nothing local to keep
        return .useLocal
    }
}

/// Field-level three-way merge of `properties`. Same-field collisions follow
/// `sameFieldConflict`; delete/update collisions follow `deleteConflict`.
public struct FieldLevelMergeResolver: GraphConflictResolver {

    public enum SameFieldPolicy: Sendable, Equatable {
        case localWins
        case remoteWins
        case fail
    }

    public enum DeletePolicy: Sendable, Equatable {
        case fail
        case deleteWins
        case remoteWins
    }

    public let sameFieldConflict: SameFieldPolicy
    public let deleteConflict: DeletePolicy

    public init(
        sameFieldConflict: SameFieldPolicy = .remoteWins,
        deleteConflict: DeletePolicy = .fail
    ) {
        self.sameFieldConflict = sameFieldConflict
        self.deleteConflict = deleteConflict
    }

    public func resolve(_ conflict: GraphConflict) async throws -> GraphConflictResolution {
        let base = conflict.base?.properties ?? [:]

        // Delete vs update.
        if conflict.local == nil {
            switch deleteConflict {
            case .fail: return .fail("delete vs update on \(conflict.entity.id)")
            case .deleteWins: return .delete
            case .remoteWins: return .useRemote
            }
        }
        let local = conflict.local!.properties
        let remote = conflict.remote.properties

        var merged = base // start from common ancestor
        let allKeys = Set(local.keys).union(remote.keys)

        for key in allKeys {
            let baseValue = base[key]
            let localValue = local[key]
            let remoteValue = remote[key]

            let localChanged = localValue != baseValue
            let remoteChanged = remoteValue != baseValue

            switch (localChanged, remoteChanged) {
            case (false, false):
                // Same as base.
                if let baseValue { merged[key] = baseValue }
            case (true, false):
                if let localValue { merged[key] = localValue } else { merged.removeValue(forKey: key) }
            case (false, true):
                if let remoteValue { merged[key] = remoteValue } else { merged.removeValue(forKey: key) }
            case (true, true):
                // Both changed.
                if localValue == remoteValue {
                    // Same value, no real conflict.
                    if let v = localValue { merged[key] = v } else { merged.removeValue(forKey: key) }
                } else {
                    switch sameFieldConflict {
                    case .localWins:
                        if let v = localValue { merged[key] = v } else { merged.removeValue(forKey: key) }
                    case .remoteWins:
                        if let v = remoteValue { merged[key] = v } else { merged.removeValue(forKey: key) }
                    case .fail:
                        return .fail("same-field conflict on \(conflict.entity.id) key=\(key)")
                    }
                }
            }
        }

        // Carry over node/edge metadata from the remote payload (fromID/toID/label/type are
        // identity-bearing — never invented by the merger).
        let payload = GraphRecordPayload(
            format: conflict.remote.format,
            properties: merged,
            label: conflict.remote.label ?? conflict.local?.label,
            type: conflict.remote.type ?? conflict.local?.type,
            fromID: conflict.remote.fromID ?? conflict.local?.fromID,
            toID: conflict.remote.toID ?? conflict.local?.toID
        )
        return .merge(payload)
    }
}
