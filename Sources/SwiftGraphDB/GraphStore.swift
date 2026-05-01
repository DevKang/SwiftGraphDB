import Foundation

public actor GraphStore {
    public static func open(named name: String) async throws -> GraphStore {
        fatalError("Not implemented — see SPEC.md §6 (Persistence Layer)")
    }

    public static func open(at url: URL) async throws -> GraphStore {
        fatalError("Not implemented — see SPEC.md §6 (Persistence Layer)")
    }

    public static func openInMemory() async throws -> GraphStore {
        fatalError("Not implemented — see SPEC.md §6 (Persistence Layer)")
    }

    private init() {}
}
