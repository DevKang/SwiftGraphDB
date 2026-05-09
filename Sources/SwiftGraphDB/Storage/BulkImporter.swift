import Foundation

/// Imports many nodes and edges in a single SQLite transaction. Per-row commits dominate
/// per-row insert cost, so wrapping a 20K-row import in one transaction is worth roughly an
/// order of magnitude. SPEC §10 budget: 20K nodes in under 3 seconds.
public struct BulkImporter: Sendable {

    public let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    /// Result of a successful `bulkInsert` call.
    public struct Summary: Sendable, Equatable {
        public var nodesInserted: Int
        public var edgesInserted: Int
    }

    /// Handle passed to a `bulkInsert` closure. Calls outside the closure throw.
    public final class Batch: @unchecked Sendable {
        fileprivate weak var store: SQLiteStore?
        fileprivate var nodesInserted = 0
        fileprivate var edgesInserted = 0
        fileprivate var alive = true

        fileprivate init(store: SQLiteStore) {
            self.store = store
        }

        /// Stage a node insert. Returns the assigned `NodeID` so subsequent `addEdge` calls
        /// can reference it. Errors are deferred to the surrounding `bulkInsert` (the closure
        /// stays simple — no `try` per call site).
        @discardableResult
        public func addNode(
            id: NodeID = IDFactory.live.nodeID(),
            label: String,
            properties: [String: PropertyValue] = [:]
        ) -> NodeID {
            do { try addNodeStrict(id: id, label: label, properties: properties) }
            catch { lastError = error }
            return id
        }

        @discardableResult
        public func addEdge(
            id: EdgeID = IDFactory.live.edgeID(),
            from: NodeID,
            to: NodeID,
            type: String,
            properties: [String: PropertyValue] = [:]
        ) -> EdgeID {
            do { try addEdgeStrict(id: id, from: from, to: to, type: type, properties: properties) }
            catch { lastError = error }
            return id
        }

        /// Throwing variant — the strict path the test seam uses to verify post-closure
        /// rejection.
        public func addNodeStrict(
            id: NodeID = IDFactory.live.nodeID(),
            label: String,
            properties: [String: PropertyValue] = [:]
        ) throws {
            try ensureAlive()
            let now = Date().timeIntervalSince1970
            let json = try PropertyCoding.encodeToString(properties)
            try store!.execute(
                """
                INSERT INTO nodes (id, label, properties, created_at, modified_at, is_deleted)
                VALUES (?, ?, ?, ?, ?, 0)
                """,
                [
                    .text(id.uuidString), .text(label), .text(json),
                    .real(now), .real(now),
                ]
            )
            nodesInserted += 1
        }

        public func addEdgeStrict(
            id: EdgeID = IDFactory.live.edgeID(),
            from: NodeID,
            to: NodeID,
            type: String,
            properties: [String: PropertyValue] = [:]
        ) throws {
            try ensureAlive()
            let now = Date().timeIntervalSince1970
            let json = try PropertyCoding.encodeToString(properties)
            try store!.execute(
                """
                INSERT INTO edges (id, type, from_id, to_id, properties, created_at, modified_at, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                [
                    .text(id.uuidString), .text(type),
                    .text(from.uuidString), .text(to.uuidString),
                    .text(json), .real(now), .real(now),
                ]
            )
            edgesInserted += 1
        }

        fileprivate var lastError: Error?

        fileprivate func ensureAlive() throws {
            guard alive, store != nil else {
                throw BulkImporterError.batchClosed
            }
        }
    }

    /// Run `body` inside a single SQLite transaction. Throwing rolls back the entire batch.
    /// Returns counts of inserted rows.
    @discardableResult
    public func bulkInsert(_ body: (Batch) throws -> Void) throws -> Summary {
        let batch = Batch(store: store)
        do {
            try store.transaction { _ in
                try body(batch)
                if let deferred = batch.lastError { throw deferred }
            }
        } catch {
            batch.alive = false
            throw error
        }
        batch.alive = false
        return Summary(nodesInserted: batch.nodesInserted, edgesInserted: batch.edgesInserted)
    }
}

/// Errors thrown by `BulkImporter` while validating or persisting a batch.
public enum BulkImporterError: Error, Equatable {
    /// Returned when a `Batch` is used after its `bulkInsert` closure has returned.
    case batchClosed
}
