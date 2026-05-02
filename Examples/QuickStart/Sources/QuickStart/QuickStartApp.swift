import SwiftUI
import SwiftGraphDB
#if canImport(AppKit)
import AppKit
#endif

// Minimal SwiftUI sample exercising the SwiftGraphDB public surface end to end.
// Run with `swift run QuickStart` from Examples/QuickStart, or open the folder in Xcode
// and pick the QuickStart scheme on the My Mac (Designed for iPad) destination.

@main
struct QuickStartApp: App {
    @StateObject private var model = GraphModel()

    init() {
        #if canImport(AppKit)
        // SwiftPM executable products launch as `.accessory` by default, which means the
        // window is created but never activates. Promote to a regular app and bring it
        // forward so the sample actually shows up when run from `swift run` or Xcode.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.bootstrap() }
        }
    }
}

@MainActor
final class GraphModel: ObservableObject {
    @Published var people: [PersonRow] = []
    @Published var neighbours: [PersonRow] = []
    @Published var selectedID: NodeID?
    @Published var pairWithSecondaryStore = false
    @Published var secondaryPeople: [PersonRow] = []

    private var primary: GraphStore?
    private var secondary: GraphStore?
    private var backend: InMemorySyncBackend?
    private var primaryDevice = SyncBackendID("primary")
    private var secondaryDevice = SyncBackendID("secondary")

    func bootstrap() async {
        do {
            primary = try await GraphStore.openInMemory()
            try await seed(store: primary!)
            await refreshPrimary()
        } catch {
            print("bootstrap failed: \(error)")
        }
    }

    private func seed(store: GraphStore) async throws {
        let alice = try await store.addNode(label: "Person", properties: ["name": "Alice"])
        let bob   = try await store.addNode(label: "Person", properties: ["name": "Bob"])
        let cath  = try await store.addNode(label: "Person", properties: ["name": "Cath"])
        _ = try await store.addEdge(from: alice, to: bob, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: alice, to: cath, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: bob, to: cath, type: "KNOWS", properties: [:])
    }

    func refreshPrimary() async {
        guard let primary else { return }
        let nodes = (try? await primary.nodes(labeled: "Person").collect()) ?? []
        people = nodes.map(PersonRow.init)
    }

    func addRandomPerson() async {
        guard let primary else { return }
        let names = ["Dee", "Eli", "Fin", "Gil", "Hugo", "Iris"]
        let name = names.randomElement() ?? "Anon"
        _ = try? await primary.addNode(label: "Person", properties: ["name": .string(name)])
        await refreshPrimary()
    }

    func selectPerson(_ id: NodeID) async {
        selectedID = id
        guard let primary else { return }
        let traversal = await primary.node(id: id).traverse(
            .outgoing, edge: "KNOWS", maxDepth: .bounded(1)
        )
        let nodes = (try? await traversal.collect()) ?? []
        // The starting node is included; drop it for the "1-hop" view.
        neighbours = nodes
            .filter { $0.id != id }
            .map(PersonRow.init)
    }

    func togglePairing() async {
        if pairWithSecondaryStore {
            await tearDownSecondary()
        } else {
            await spinUpSecondary()
        }
        pairWithSecondaryStore.toggle()
    }

    private func spinUpSecondary() async {
        guard let primary else { return }
        do {
            let backend = InMemorySyncBackend()
            self.backend = backend
            secondary = try await GraphStore.openInMemory()

            let primaryTransport = await backend.transport(for: primaryDevice)
            let secondaryTransport = await backend.transport(for: secondaryDevice)
            let resolver = FieldLevelMergeResolver()
            try await primary.enableSync(transport: primaryTransport, resolver: resolver)
            try await secondary!.enableSync(transport: secondaryTransport, resolver: resolver)

            _ = try await primary.syncNow(backendID: primaryDevice)
            _ = try await secondary!.syncNow(backendID: secondaryDevice)

            let nodes = (try? await secondary!.nodes(labeled: "Person").collect()) ?? []
            secondaryPeople = nodes.map(PersonRow.init)
        } catch {
            print("pairing failed: \(error)")
        }
    }

    private func tearDownSecondary() async {
        if let primary { await primary.disableSync(backendID: primaryDevice) }
        if let secondary {
            await secondary.disableSync(backendID: secondaryDevice)
            await secondary.close()
        }
        secondary = nil
        backend = nil
        secondaryPeople = []
    }
}

struct PersonRow: Identifiable, Hashable {
    let id: NodeID
    let name: String

    init(_ node: Node) {
        self.id = node.id
        if case .string(let s) = node.properties["name"] {
            self.name = s
        } else {
            self.name = "(unnamed)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: GraphModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section("People") {
                    ForEach(model.people) { person in
                        Text(person.name).tag(person.id)
                    }
                }
            }
            .toolbar {
                Button {
                    Task { await model.addRandomPerson() }
                } label: { Image(systemName: "plus") }
            }
            .navigationTitle("SwiftGraphDB")
            .onChange(of: model.selectedID) { _, new in
                if let new { Task { await model.selectPerson(new) } }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Pair with secondary store (in-memory sync)",
                       isOn: Binding(
                            get: { model.pairWithSecondaryStore },
                            set: { _ in Task { await model.togglePairing() } }
                       ))
                Divider()
                if let id = model.selectedID, let person = model.people.first(where: { $0.id == id }) {
                    Text("\(person.name)'s 1-hop KNOWS neighbours")
                        .font(.headline)
                    ForEach(model.neighbours) { row in
                        Text(row.name)
                    }
                } else {
                    Text("Pick a person on the left.").foregroundStyle(.secondary)
                }
                if model.pairWithSecondaryStore {
                    Divider()
                    Text("Secondary store sees: \(model.secondaryPeople.count) people")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        }
    }
}
