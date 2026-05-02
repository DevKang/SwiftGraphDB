# Concurrency model

SwiftGraphDB is **multiple-reader, single-writer** with strict Swift concurrency.

## The graph actor

Writes are serialised through ``GraphStore``'s internal `GraphActor`. Every mutation —
`addNode`, `addEdge`, `updateNode`, deletes — hops onto the actor before touching SQLite or
the in-memory adjacency.

This eliminates whole classes of race conditions. There is no shared mutable state for callers
to coordinate.

## Topology snapshots

Hot traversal paths cannot afford an actor hop per step. Instead, ``GraphStore`` exposes
a ``TopologySnapshot`` — an immutable, value-typed view of the in-memory adjacency at a point
in time. Read paths that only need topology (BFS, shortest path, label scans) operate against
the snapshot off-actor and avoid serialising on the writer.

Snapshots are cheap to take (a few pointers + COW arrays) and become stale as soon as the
actor commits a new write. For interactive UI, take a fresh snapshot per query batch; for
long-running analytics, snapshot once and run to completion.

## Property fetches

Property reads are not on the snapshot — they go to SQLite (LRU-cached). This keeps the
snapshot small and avoids paying serialisation cost on data that's not in the hot loop.

## Sync runs concurrently

When sync is enabled, the sync coordinator runs on its own task. It pushes journal rows and
applies remote changes through the same actor, so writes still serialise; concurrent reads
on snapshots are unaffected.

## Cancellation

Long queries respect cooperative cancellation. Wrap the `try await` in a `Task` and cancel it
when the user navigates away.

## See also

- ``GraphStore``
- ``TopologySnapshot``
- SPEC §8 — concurrency invariants and rationale.
