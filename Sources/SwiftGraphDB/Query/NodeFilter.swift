import Foundation

/// Predicate evaluated against a `Node`. Implemented as a `@Sendable` closure rather than a
/// struct of cases so apps can supply custom escape-hatch closures cheaply.
public struct NodeFilter: Sendable {
    let evaluate: @Sendable (Node) -> Bool
    public init(_ evaluate: @escaping @Sendable (Node) -> Bool) {
        self.evaluate = evaluate
    }
}
