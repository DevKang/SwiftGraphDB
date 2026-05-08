import SwiftUI
import SwiftGraphDB
#if canImport(AppKit)
import AppKit
#endif

@main
struct QuickStartApp: App {
    @StateObject private var model = GraphModel()

    init() {
        #if canImport(AppKit)
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

// MARK: - Model

struct PersonRow: Identifiable, Hashable {
    let id: NodeID
    let name: String
    let properties: [String: String]

    init(_ node: Node) {
        self.id = node.id
        if case .string(let s) = node.properties["name"] {
            self.name = s
        } else {
            self.name = "(unnamed)"
        }
        var props: [String: String] = [:]
        for (k, v) in node.properties where k != "name" {
            switch v {
            case .string(let s): props[k] = s
            case .int(let i):    props[k] = "\(i)"
            case .double(let d): props[k] = "\(d)"
            case .bool(let b):   props[k] = b ? "true" : "false"
            case .date(let d):   props[k] = d.formatted(date: .abbreviated, time: .omitted)
            case .data:          props[k] = "(data)"
            case .array:         props[k] = "(array)"
            case .null:          props[k] = "null"
            }
        }
        self.properties = props
    }
}

struct BreadcrumbItem: Identifiable {
    let index: Int
    let nodeID: NodeID
    let name: String
    var id: Int { index }
}

struct BreadcrumbView: View {
    let crumb: BreadcrumbItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if crumb.index > 0 {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button(crumb.name, action: action)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(isSelected ? .primary : .blue)
        }
    }
}

struct RelationshipRow: Identifiable, Hashable {
    let id: EdgeID
    let edgeType: String
    let targetID: NodeID
    let targetName: String
    let direction: Direction

    enum Direction: String, Hashable {
        case outgoing = "→"
        case incoming = "←"
    }
}

struct BenchmarkResult: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let elapsed: Duration
}

@MainActor
final class GraphModel: ObservableObject {
    @Published var allPeople: [PersonRow] = []
    @Published var searchText = ""
    @Published var selectedID: NodeID?
    @Published var relationships: [RelationshipRow] = []
    @Published var navigationStack: [(id: NodeID, name: String)] = []
    @Published var shortestPathResult: String?

    @Published var pairWithSecondaryStore = false
    @Published var secondaryPeople: [PersonRow] = []

    @Published var benchmarkResults: [BenchmarkResult] = []
    @Published var benchmarkRunning = false

    private var primary: GraphStore?
    private var secondary: GraphStore?
    private var backend: InMemorySyncBackend?
    private var primaryDevice = SyncBackendID("primary")
    private var secondaryDevice = SyncBackendID("secondary")

    var filteredPeople: [PersonRow] {
        if searchText.isEmpty { return allPeople }
        return allPeople.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func bootstrap() async {
        do {
            primary = try await GraphStore.openInMemory()
            try await seed(store: primary!)
            await refreshAll()
        } catch {
            print("bootstrap failed: \(error)")
        }
    }

    private func seed(store: GraphStore) async throws {
        let alice = try await store.addNode(label: "Person", properties: [
            "name": "Alice", "age": .int(32), "city": .string("Seoul")
        ])
        let bob = try await store.addNode(label: "Person", properties: [
            "name": "Bob", "age": .int(28), "city": .string("Busan")
        ])
        let cath = try await store.addNode(label: "Person", properties: [
            "name": "Cath", "age": .int(35), "city": .string("Incheon")
        ])
        let dee = try await store.addNode(label: "Person", properties: [
            "name": "Dee", "age": .int(24), "city": .string("Seoul")
        ])
        let eli = try await store.addNode(label: "Person", properties: [
            "name": "Eli", "age": .int(30), "city": .string("Daegu")
        ])
        _ = try await store.addEdge(from: alice, to: bob, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: alice, to: cath, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: bob, to: cath, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: bob, to: dee, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: cath, to: eli, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: dee, to: eli, type: "KNOWS", properties: [:])
        _ = try await store.addEdge(from: eli, to: alice, type: "KNOWS", properties: [:])
    }

    func refreshAll() async {
        guard let primary else { return }
        let nodes = (try? await primary.nodes(labeled: "Person").collect()) ?? []
        allPeople = nodes.map(PersonRow.init).sorted { $0.name < $1.name }
    }

    func addPerson(name: String, city: String) async {
        guard let primary, !name.isEmpty else { return }
        var props: [String: PropertyValue] = ["name": .string(name)]
        if !city.isEmpty { props["city"] = .string(city) }
        _ = try? await primary.addNode(label: "Person", properties: props)
        await refreshAll()
    }

    func deletePerson(_ id: NodeID) async {
        guard let primary else { return }
        try? await primary.deleteNode(id: id)
        if selectedID == id {
            selectedID = nil
            relationships = []
            navigationStack = []
        }
        await refreshAll()
    }

    func addRelationship(from: NodeID, to: NodeID, type: String) async {
        guard let primary else { return }
        _ = try? await primary.addEdge(from: from, to: to, type: type, properties: [:])
        await selectPerson(from, pushNav: false)
    }

    func deleteRelationship(_ edgeID: EdgeID) async {
        guard let primary else { return }
        try? await primary.deleteEdge(id: edgeID)
        if let sel = selectedID { await selectPerson(sel, pushNav: false) }
    }

    func selectPerson(_ id: NodeID, pushNav: Bool = true) async {
        selectedID = id
        guard let primary else { return }

        if pushNav {
            if let idx = navigationStack.firstIndex(where: { $0.id == id }) {
                navigationStack = Array(navigationStack.prefix(through: idx))
            } else {
                let name = allPeople.first(where: { $0.id == id })?.name ?? "?"
                navigationStack.append((id: id, name: name))
            }
        }

        var rels: [RelationshipRow] = []

        let outResult = try? await primary.node(id: id)
            .traverse(.outgoing, edge: nil, maxDepth: .bounded(1))
            .collectWithEdges()
        if let outResult {
            for edge in outResult.edges where edge.fromID == id {
                let targetNode = outResult.nodes.first(where: { $0.id == edge.toID })
                let name: String
                if let targetNode, case .string(let s) = targetNode.properties["name"] {
                    name = s
                } else {
                    name = "(unnamed)"
                }
                rels.append(RelationshipRow(
                    id: edge.id, edgeType: edge.type,
                    targetID: edge.toID, targetName: name,
                    direction: .outgoing
                ))
            }
        }

        let inResult = try? await primary.node(id: id)
            .traverse(.incoming, edge: nil, maxDepth: .bounded(1))
            .collectWithEdges()
        if let inResult {
            for edge in inResult.edges where edge.toID == id {
                let targetNode = inResult.nodes.first(where: { $0.id == edge.fromID })
                let name: String
                if let targetNode, case .string(let s) = targetNode.properties["name"] {
                    name = s
                } else {
                    name = "(unnamed)"
                }
                rels.append(RelationshipRow(
                    id: edge.id, edgeType: edge.type,
                    targetID: edge.fromID, targetName: name,
                    direction: .incoming
                ))
            }
        }

        relationships = rels
        shortestPathResult = nil
    }

    func findShortestPath(to targetID: NodeID) async {
        guard let primary, let from = selectedID else { return }
        do {
            let path = try await primary.shortestPath(from: from, to: targetID)
            if let path {
                let names = path.nodes.compactMap { node -> String? in
                    if case .string(let s) = node.properties["name"] { return s }
                    return nil
                }
                shortestPathResult = names.joined(separator: " → ") + " (length \(path.length))"
            } else {
                shortestPathResult = "No path found"
            }
        } catch {
            shortestPathResult = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Sync

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

    // MARK: - Benchmark

    private static let firstNames = [
        "Alice", "Bob", "Cath", "Dee", "Eli", "Fin", "Gil", "Hugo", "Iris", "Jack",
        "Kate", "Leo", "Mia", "Noah", "Olga", "Paul", "Quinn", "Rose", "Sam", "Tina",
        "Uma", "Vic", "Wendy", "Xavi", "Yuna", "Zack", "Amy", "Ben", "Clara", "Dan",
        "Eva", "Felix", "Grace", "Henry", "Ivy", "James", "Kira", "Luke", "Nora", "Oscar",
    ]
    private static let cities = [
        "Seoul", "Busan", "Incheon", "Daegu", "Daejeon", "Gwangju", "Ulsan", "Suwon",
        "Jeju", "Changwon", "Tokyo", "Osaka", "New York", "London", "Paris", "Berlin",
    ]
    private static let edgeTypes = [
        "KNOWS", "WORKS_WITH", "FRIENDS_WITH", "MENTORS", "FOLLOWS", "LIVES_NEAR",
    ]

    func runBenchmark(nodeCount: Int, edgesPerNode: Int) async {
        guard let primary else { return }
        benchmarkRunning = true
        benchmarkResults = []
        defer { benchmarkRunning = false }

        do {
            var results: [BenchmarkResult] = []
            var newNodeIDs: [NodeID] = []
            newNodeIDs.reserveCapacity(nodeCount)
            let clock = ContinuousClock()

            let t0 = clock.now
            for i in 0..<nodeCount {
                let firstName = Self.firstNames[i % Self.firstNames.count]
                let suffix = nodeCount > Self.firstNames.count ? " \(i / Self.firstNames.count + 1)" : ""
                let city = Self.cities[i % Self.cities.count]
                let age = Int64(20 + (i * 7 + 13) % 50)
                let id = try await primary.addNode(label: "Person", properties: [
                    "name": .string("\(firstName)\(suffix)"),
                    "age": .int(age),
                    "city": .string(city),
                ])
                newNodeIDs.append(id)
            }
            let d0 = clock.now - t0
            results.append(BenchmarkResult(
                label: "Insert \(nodeCount) nodes",
                detail: "\(String(format: "%.0f", Double(nodeCount) / d0.seconds)) nodes/sec",
                elapsed: d0
            ))
            benchmarkResults = results
            await refreshAll()

            var edgeCount = 0
            let t1 = clock.now
            for i in 0..<nodeCount {
                for _ in 0..<edgesPerNode {
                    let target = Int.random(in: 0..<nodeCount)
                    if target != i {
                        let edgeType = Self.edgeTypes[Int.random(in: 0..<Self.edgeTypes.count)]
                        _ = try await primary.addEdge(
                            from: newNodeIDs[i], to: newNodeIDs[target],
                            type: edgeType, properties: [:]
                        )
                        edgeCount += 1
                    }
                }
            }
            let d1 = clock.now - t1
            results.append(BenchmarkResult(
                label: "Insert \(edgeCount) edges (6 types)",
                detail: "\(String(format: "%.0f", Double(edgeCount) / d1.seconds)) edges/sec",
                elapsed: d1
            ))
            benchmarkResults = results

            let t2 = clock.now
            let all = try await primary.nodes(labeled: "Person").collect()
            let d2 = clock.now - t2
            results.append(BenchmarkResult(
                label: "Query all \(all.count) Person nodes", detail: "", elapsed: d2
            ))
            benchmarkResults = results

            let t3 = clock.now
            let filtered = try await primary.nodes(labeled: "Person")
                .where("city", equals: .string("Seoul")).collect()
            let d3 = clock.now - t3
            results.append(BenchmarkResult(
                label: "Filter city=Seoul → \(filtered.count)", detail: "", elapsed: d3
            ))
            benchmarkResults = results

            let startNode = newNodeIDs[0]

            let t4 = clock.now
            let hop1 = try await primary.node(id: startNode)
                .traverse(.outgoing, edge: nil, maxDepth: .bounded(1)).collect()
            let d4 = clock.now - t4
            results.append(BenchmarkResult(
                label: "1-hop (all types) → \(hop1.count)", detail: "", elapsed: d4
            ))
            benchmarkResults = results

            let t5 = clock.now
            let hop1Knows = try await primary.node(id: startNode)
                .traverse(.outgoing, edge: "KNOWS", maxDepth: .bounded(1)).collect()
            let d5 = clock.now - t5
            results.append(BenchmarkResult(
                label: "1-hop (KNOWS only) → \(hop1Knows.count)", detail: "", elapsed: d5
            ))
            benchmarkResults = results

            let t6 = clock.now
            let hop2 = try await primary.node(id: startNode)
                .traverse(.both, edge: nil, maxDepth: .bounded(2)).collect()
            let d6 = clock.now - t6
            results.append(BenchmarkResult(
                label: "2-hop bidirectional → \(hop2.count)", detail: "", elapsed: d6
            ))
            benchmarkResults = results

            let t7 = clock.now
            let hop3 = try await primary.node(id: startNode)
                .traverse(.outgoing, edge: nil, maxDepth: .bounded(3)).collect()
            let d7 = clock.now - t7
            results.append(BenchmarkResult(
                label: "3-hop outgoing → \(hop3.count)", detail: "", elapsed: d7
            ))
            benchmarkResults = results

            let farNode = newNodeIDs[nodeCount - 1]
            let t8 = clock.now
            let path = try await primary.shortestPath(from: startNode, to: farNode)
            let d8 = clock.now - t8
            let pathLen = path?.length ?? -1
            results.append(BenchmarkResult(
                label: "Shortest path (any) → \(pathLen < 0 ? "none" : "length \(pathLen)")",
                detail: "", elapsed: d8
            ))
            benchmarkResults = results

            let t9 = clock.now
            let pathKnows = try await primary.shortestPath(from: startNode, to: farNode, via: "KNOWS")
            let d9 = clock.now - t9
            let pathKLen = pathKnows?.length ?? -1
            results.append(BenchmarkResult(
                label: "Shortest path (KNOWS) → \(pathKLen < 0 ? "none" : "length \(pathKLen)")",
                detail: "", elapsed: d9
            ))
            benchmarkResults = results

            if let sel = selectedID {
                await selectPerson(sel, pushNav: false)
            }
        } catch {
            benchmarkResults.append(BenchmarkResult(
                label: "Error", detail: "\(error)", elapsed: .zero
            ))
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var model: GraphModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            DetailView(model: model)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @ObservedObject var model: GraphModel
    @State private var showAddSheet = false

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.filteredPeople) { person in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).fontWeight(.medium)
                        if let city = person.properties["city"] {
                            Text(city).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .tag(person.id)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        Task { await model.deletePerson(person.id) }
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search people")
        .navigationTitle("Graph Explorer")
        .toolbar {
            Button { showAddSheet = true } label: {
                Image(systemName: "person.badge.plus")
            }
        }
        .onChange(of: model.selectedID) { _, new in
            if let new { Task { await model.selectPerson(new) } }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPersonSheet(model: model, isPresented: $showAddSheet)
        }
    }
}

struct AddPersonSheet: View {
    @ObservedObject var model: GraphModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var city = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Person").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("City (optional)", text: $city)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    Task {
                        await model.addPerson(name: name, city: city)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: Detail

struct DetailView: View {
    @ObservedObject var model: GraphModel

    var body: some View {
        if let id = model.selectedID,
           let person = model.allPeople.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    breadcrumbBar
                    personCard(person)
                    relationshipsSection
                    shortestPathSection
                    Divider().padding(.vertical, 12)
                    syncSection
                    Divider().padding(.vertical, 12)
                    benchmarkSection
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("Select a person to explore their relationships")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Breadcrumb

    @ViewBuilder
    private var breadcrumbBar: some View {
        if model.navigationStack.count > 1 {
            HStack(spacing: 4) {
                let stack = model.navigationStack
                let selected = model.selectedID
                ForEach(breadcrumbItems(stack)) { crumb in
                    BreadcrumbView(crumb: crumb, isSelected: crumb.nodeID == selected) {
                        Task { await model.selectPerson(crumb.nodeID) }
                    }
                }
                Spacer()
            }
            .padding(.bottom, 8)
        }
    }

    private func breadcrumbItems(_ stack: [(id: NodeID, name: String)]) -> [BreadcrumbItem] {
        stack.enumerated().map {
            BreadcrumbItem(index: $0.offset, nodeID: $0.element.id, name: $0.element.name)
        }
    }

    // MARK: Person Card

    private func personCard(_ person: PersonRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "person.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                Text(person.name)
                    .font(.title2).bold()
                Spacer()
                Text(person.id.uuidString.prefix(8))
                    .font(.caption).monospaced()
                    .foregroundStyle(.tertiary)
            }
            if !person.properties.isEmpty {
                HStack(spacing: 12) {
                    ForEach(person.properties.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        Label(v, systemImage: iconForProperty(k))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }

    private func edgeColor(_ type: String) -> Color {
        switch type {
        case "KNOWS":        return .blue
        case "WORKS_WITH":   return .purple
        case "FRIENDS_WITH": return .green
        case "MENTORS":      return .orange
        case "FOLLOWS":      return .pink
        case "LIVES_NEAR":   return .teal
        default:             return .gray
        }
    }

    private func iconForProperty(_ key: String) -> String {
        switch key {
        case "city": return "mappin"
        case "age": return "number"
        default: return "tag"
        }
    }

    // MARK: Relationships

    @ViewBuilder
    private var relationshipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Relationships (\(model.relationships.count))")
                    .font(.headline)
                Spacer()
                AddRelationshipMenu(model: model)
            }

            if model.relationships.isEmpty {
                Text("No relationships yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let outgoing = model.relationships.filter { $0.direction == .outgoing }
                let incoming = model.relationships.filter { $0.direction == .incoming }

                if !outgoing.isEmpty {
                    let grouped = Dictionary(grouping: outgoing, by: \.edgeType)
                    let sortedTypes = grouped.keys.sorted()
                    HStack(spacing: 4) {
                        Text("Outgoing").font(.subheadline).foregroundStyle(.secondary)
                        Text("(\(outgoing.count))").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                    ForEach(sortedTypes, id: \.self) { type in
                        let rels = grouped[type]!
                        DisclosureGroup {
                            ForEach(rels) { rel in
                                relationshipCard(rel)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(type).font(.caption).bold()
                                    .foregroundColor(edgeColor(type))
                                Text("(\(rels.count))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !incoming.isEmpty {
                    let grouped = Dictionary(grouping: incoming, by: \.edgeType)
                    let sortedTypes = grouped.keys.sorted()
                    HStack(spacing: 4) {
                        Text("Incoming").font(.subheadline).foregroundStyle(.secondary)
                        Text("(\(incoming.count))").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                    ForEach(sortedTypes, id: \.self) { type in
                        let rels = grouped[type]!
                        DisclosureGroup {
                            ForEach(rels) { rel in
                                relationshipCard(rel)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(type).font(.caption).bold()
                                    .foregroundColor(edgeColor(type))
                                Text("(\(rels.count))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func relationshipCard(_ rel: RelationshipRow) -> some View {
        HStack(spacing: 10) {
            Text(rel.direction.rawValue)
                .font(.title3)
                .foregroundStyle(rel.direction == .outgoing ? .blue : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(rel.targetName).fontWeight(.medium)
                Text(rel.edgeType)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(edgeColor(rel.edgeType).opacity(0.15), in: Capsule())
                    .foregroundColor(edgeColor(rel.edgeType))
            }
            Spacer()

            Button {
                Task { await model.findShortestPath(to: rel.targetID) }
            } label: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Find shortest path")

            Button {
                Task { await model.selectPerson(rel.targetID) }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .foregroundStyle(.blue)
            .help("Navigate to \(rel.targetName)")

            Button(role: .destructive) {
                Task { await model.deleteRelationship(rel.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Shortest Path

    @ViewBuilder
    private var shortestPathSection: some View {
        if let result = model.shortestPathResult {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortest Path").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.green)
                    Text(result)
                        .font(.callout).monospaced()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 8)
        }
    }

    // MARK: Sync

    @ViewBuilder
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pair with secondary store (in-memory sync)",
                   isOn: Binding(
                        get: { model.pairWithSecondaryStore },
                        set: { _ in Task { await model.togglePairing() } }
                   ))
            if model.pairWithSecondaryStore {
                Text("Secondary store: \(model.secondaryPeople.count) people")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Benchmark

    @ViewBuilder
    private var benchmarkSection: some View {
        BenchmarkView(model: model)
    }
}

// MARK: Add Relationship

struct AddRelationshipMenu: View {
    @ObservedObject var model: GraphModel
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Add", systemImage: "link.badge.plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.selectedID == nil)
        .sheet(isPresented: $showSheet) {
            AddRelationshipSheet(model: model, isPresented: $showSheet)
        }
    }
}

struct AddRelationshipSheet: View {
    @ObservedObject var model: GraphModel
    @Binding var isPresented: Bool
    @State private var targetID: NodeID?
    @State private var edgeType = "KNOWS"
    @State private var customEdgeType = ""

    private static let edgeTypes = [
        "KNOWS", "WORKS_WITH", "FRIENDS_WITH", "MENTORS", "FOLLOWS", "LIVES_NEAR", "(custom)",
    ]

    var resolvedEdgeType: String {
        edgeType == "(custom)" ? customEdgeType : edgeType
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Relationship").font(.headline)
            Picker("Target", selection: $targetID) {
                Text("Choose...").tag(NodeID?.none)
                ForEach(model.allPeople.filter { $0.id != model.selectedID }) { p in
                    Text(p.name).tag(NodeID?.some(p.id))
                }
            }
            Picker("Type", selection: $edgeType) {
                ForEach(Self.edgeTypes, id: \.self) { t in
                    Text(t).tag(t)
                }
            }
            if edgeType == "(custom)" {
                TextField("Custom edge type", text: $customEdgeType)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    if let from = model.selectedID, let to = targetID {
                        Task {
                            await model.addRelationship(from: from, to: to, type: resolvedEdgeType)
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targetID == nil || resolvedEdgeType.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: Benchmark View

struct BenchmarkView: View {
    @ObservedObject var model: GraphModel
    @State private var nodeCount = 100
    @State private var edgesPerNode = 5
    @State private var expanded = false

    private static let presets = [
        ("Tiny", 50, 3),
        ("Small", 200, 4),
        ("Medium", 500, 5),
        ("Large", 1_000, 8),
        ("XL", 3_000, 10),
    ]

    var body: some View {
        DisclosureGroup("Benchmark — Generate Complex Graph", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generates real Person nodes with names, cities, ages and 6 edge types: KNOWS, WORKS_WITH, FRIENDS_WITH, MENTORS, FOLLOWS, LIVES_NEAR. All nodes appear in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.0) { label, n, e in
                        Button("\(label) (\(n))") {
                            nodeCount = n; edgesPerNode = e
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.benchmarkRunning)
                    }
                }

                HStack(spacing: 16) {
                    LabeledContent("Nodes") {
                        TextField("", value: $nodeCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    LabeledContent("Edges/node") {
                        TextField("", value: $edgesPerNode, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                    }
                    Button {
                        Task { await model.runBenchmark(nodeCount: nodeCount, edgesPerNode: edgesPerNode) }
                    } label: {
                        if model.benchmarkRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .disabled(model.benchmarkRunning)

                    Text("Total: \(nodeCount) nodes, ~\(nodeCount * edgesPerNode) edges")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !model.benchmarkResults.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Operation").bold().font(.caption)
                            Text("Time").bold().font(.caption)
                            Text("Throughput").bold().font(.caption)
                        }
                        Divider()
                        ForEach(model.benchmarkResults) { r in
                            GridRow {
                                Text(r.label).font(.callout)
                                Text(r.elapsed.formatted).font(.callout).monospacedDigit()
                                Text(r.detail).font(.callout)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }
}

// MARK: - Helpers

extension Duration {
    var seconds: Double {
        let (s, att) = components
        return Double(s) + Double(att) / 1_000_000_000_000_000_000.0
    }

    var formatted: String {
        let s = seconds
        if s < 0.001 {
            return String(format: "%.1f us", s * 1_000_000)
        } else if s < 1 {
            return String(format: "%.2f ms", s * 1000)
        } else {
            return String(format: "%.3f s", s)
        }
    }
}
