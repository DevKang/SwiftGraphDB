# Modeling your data

How to translate your domain into nodes, edges, and property values.

## Nodes are labeled documents

A ``Node`` is a stable UUID, a `label` string, and a property bag. The label groups nodes by
type (`"Person"`, `"Document"`, `"Tag"`) and is the unit indexed by ``GraphStore/nodes(labeled:)``.

```swift
let alice = try await store.addNode(label: "Person", properties: [
    "name": "Alice",
    "age": .int(30),
    "active": .bool(true)
])
```

Properties are stored as ``PropertyValue`` and can hold strings, ints, doubles, bools, dates,
nested arrays, and dictionaries — see the type reference for the full enumeration. JSON-shaped
data round-trips cleanly.

## Edges are typed relationships

An ``Edge`` carries `from`, `to`, a `type` string, and its own property bag. Types are the
edge analogue of node labels — they group relationships by kind.

```swift
_ = try await store.addEdge(from: alice, to: bob, type: "KNOWS", properties: [
    "since": Date(),
    "weight": .double(0.8)
])
```

## Choosing labels and types

- Use **nouns** for labels (`"Person"`, `"Asset"`, `"Folder"`).
- Use **verbs or active phrases** for edge types (`"AUTHORED"`, `"FOLLOWS"`, `"CONTAINS"`).
- Keep cardinality low. A handful of labels and types reads better than dozens of one-off
  variants.

## Property index hints

Heavy filter targets benefit from a `PropertyIndexSpec` configured at open time. SwiftGraphDB
keeps an in-memory inverted index over each spec and uses it to accelerate
``GraphStore/nodes(where:equals:)`` and friends. See the README's "Indexing" section for
guidance.

## Updating and deleting

- `updateNode` replaces the property bag. Pass the full desired set, not a delta.
- `deleteNode` and `deleteEdge` perform soft deletes — the row is tombstoned so sync can
  propagate the removal.
