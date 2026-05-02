# Querying

Building queries with sources, filters, and traversals.

## Sources

Every query starts at a `GraphStore` source method. The result is a ``NodeQuery`` you can
chain operators onto and finalise with a terminal call.

```swift
let everyone   = await store.nodes(labeled: "Person")
let one        = await store.node(id: aliceID)
let active     = await store.nodes(where: "active", equals: .bool(true))
let oldEnough  = await store.nodes(where: "age", greaterThan: .int(18))
let byScore    = await store.nodes(where: "score", in: [.int(1), .int(2), .int(3)])
```

## Filters

Chain `where` operators to narrow:

```swift
let result = await store.nodes(labeled: "Person")
    .where("active", equals: .bool(true))
    .where("age", greaterThan: .int(18))
```

## Traversal

Walk the graph from a starting set:

```swift
let friends = await store
    .node(id: aliceID)
    .traverse(direction: .outgoing, edgeType: "KNOWS", depth: .upTo(2))
```

Direction options are `.outgoing`, `.incoming`, `.both`. Depth options are `.exactly(n)` and
`.upTo(n)`.

## Terminals

```swift
let nodes:   [Node]               = try await query.collect()
let count:   Int                  = try await query.count()
let exists:  Bool                 = try await query.exists()
let first:   Node?                = try await query.first()
let bundle: (nodes: [Node], edges: [Edge]) = try await query.collectWithEdges()
```

## Shortest path

`GraphPath` exposes shortest-path search between two nodes:

```swift
if let path = try await store.shortestPath(from: aliceID, to: zoeID) {
    print(path.nodeIDs)
}
```
