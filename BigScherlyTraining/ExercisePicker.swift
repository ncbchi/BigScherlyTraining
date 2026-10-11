import SwiftUI
import Combine

// MARK: - Exercise dropdown for the workout builder (Oct 8, 2026)
// The coach's own exercise library first, then ~190 standard gym exercises from the server.
// Type to filter ("inc db" finds Incline Dumbbell Press), tap a match to fill the name,
// muscle group, rest and default sets × reps. The chevron opens the whole list to browse.
// Anything typed that isn't in the list is kept as-is — a new exercise.

struct APICatalogExercise: Decodable, Identifiable, Hashable {
    let id: String?            // set for the coach's own exercises, nil for standard ones
    let name: String
    let muscleGroup: String
    let equipment: String
    let cues: String
    let videoUrl: String?
    let restSeconds: Int
    let defaultSets: Int
    let defaultReps: Int
    let source: String         // "mine" or "standard"

    var isMine: Bool { source == "mine" }
    var detail: String { [muscleGroup, equipment].filter { !$0.isEmpty }.joined(separator: " · ") }

    // Identifiable by name: names are unique in the catalog (the server drops a standard
    // exercise when the coach has one with the same name).
    var stableId: String { name.lowercased() }
}

extension APIClient {
    func exerciseCatalog() async throws -> [APICatalogExercise] { try await get("/admin/exercise-catalog") }
}

@MainActor
final class ExerciseCatalog: ObservableObject {
    static let shared = ExerciseCatalog()
    @Published private(set) var items: [APICatalogExercise] = []
    @Published private(set) var loaded = false
    private var loading = false

    /// Refreshes every time a builder opens, so a newly added library exercise shows up.
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if let x = try? await APIClient.shared.exerciseCatalog() {
            items = x
            loaded = true
        }
    }

    static let muscleOrder = ["Chest", "Back", "Shoulders", "Quads", "Hamstrings", "Glutes", "Calves",
                              "Biceps", "Triceps", "Forearms", "Core", "Full Body", "Cardio"]

    private static let aliases: [String: String] = [
        "db": "dumbbell", "dumbell": "dumbbell", "bb": "barbell", "kb": "kettlebell",
        "ohp": "overhead press", "rdl": "romanian deadlift", "sldl": "stiff leg",
        "bss": "bulgarian split squat", "ghr": "glute ham raise",
        "pullup": "pull up", "chinup": "chin up", "pushup": "push up", "situp": "sit up"
    ]

    /// Every word typed must start a word in the name, muscle group or equipment (or appear in it).
    static func matches(_ x: APICatalogExercise, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let hay = "\(x.name) \(x.muscleGroup) \(x.equipment)".lowercased()
        let words = hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        func hit(_ t: String) -> Bool { words.contains { $0.hasPrefix(t) } || hay.contains(t) }
        return q.split(separator: " ").map(String.init).allSatisfy { t in
            if hit(t) { return true }
            if let a = aliases[t] { return a.split(separator: " ").map(String.init).allSatisfy(hit) }
            return false
        }
    }

    /// Typed search: names that start with the query first, then the coach's own, then A–Z.
    func search(_ query: String, limit: Int? = nil) -> [APICatalogExercise] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = items.filter { Self.matches($0, q) }.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(q) ? 0 : 1, pb = b.name.lowercased().hasPrefix(q) ? 0 : 1
            if pa != pb { return pa < pb }
            if a.isMine != b.isMine { return a.isMine }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if let limit { return Array(hits.prefix(limit)) }
        return hits
    }
}

// MARK: - The field

struct ExerciseNameField: View {
    @Binding var name: String
    let onPick: (APICatalogExercise) -> Void

    @ObservedObject private var catalog = ExerciseCatalog.shared
    @FocusState private var focused: Bool
    @State private var browsing = false
    /// Hides suggestions right after a pick until the coach types again.
    @State private var justPicked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $name, prompt: Text("Exercise, e.g. Bench Press").foregroundColor(Brand.mute))
                    .font(BrandFont.display(26)).foregroundColor(Brand.text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        // Return picks the top match only if it's what they typed (ignoring case).
                        if let top = suggestions.first, top.name.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() {
                            pick(top)
                        }
                    }
                    .onChange(of: name) { _, _ in if focused { justPicked = false } }
                    .onChange(of: focused) { _, isOn in if isOn { justPicked = false } }
                Button { focused = false; browsing = true } label: {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .heavy))
                        .foregroundColor(Brand.onVolt)
                        .frame(width: 32, height: 32).background(Circle().fill(Brand.volt))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Browse all exercises")
            }
            if focused && !justPicked { suggestionList }
        }
        .sheet(isPresented: $browsing) {
            ExercisePickerSheet(current: name) { x in
                browsing = false
                pick(x)
            }
        }
        .task { if !catalog.loaded { await catalog.load() } }
    }

    private var query: String { name.trimmingCharacters(in: .whitespaces) }

    private var suggestions: [APICatalogExercise] {
        if query.isEmpty { return Array(catalog.items.filter { $0.isMine }.prefix(6)) }
        return catalog.search(query, limit: 7)
    }

    @ViewBuilder
    private var suggestionList: some View {
        let list = suggestions
        let exact = catalog.items.contains { $0.name.lowercased() == query.lowercased() }
        VStack(alignment: .leading, spacing: 0) {
            if !catalog.loaded {
                hint("Loading exercises…")
            } else if list.isEmpty {
                hint(query.isEmpty ? "Type to search, or tap ⌄ to browse every exercise."
                                   : "No match — “\(query)” will be added as a new exercise.")
            } else {
                Text(query.isEmpty ? "YOUR LIBRARY" : "MATCHES")
                    .font(BrandFont.body(9, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                ForEach(list, id: \.stableId) { x in
                    Button { pick(x) } label: { ExerciseRowLabel(item: x, query: query) }
                        .buttonStyle(.plain)
                }
                if !query.isEmpty && !exact {
                    hint("Or keep “\(query)” as typed.")
                } else if query.isEmpty {
                    hint("Type to search \(catalog.items.count) exercises, or tap ⌄ to browse.")
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
        .transition(.opacity)
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(BrandFont.body(12)).foregroundColor(Brand.mute)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }

    private func pick(_ x: APICatalogExercise) {
        justPicked = true
        name = x.name
        focused = false
        onPick(x)
    }
}

struct ExerciseRowLabel: View {
    let item: APICatalogExercise
    var query: String = ""
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if item.isMine {
                Text("YOURS").font(BrandFont.body(8, .heavy)).tracking(0.8).foregroundColor(Brand.onVolt)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Brand.volt))
            }
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundColor(Brand.voltText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - Browse everything

struct ExercisePickerSheet: View {
    let current: String
    let pick: (APICatalogExercise) -> Void
    @ObservedObject private var catalog = ExerciseCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(title: String, items: [APICatalogExercise])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hits = catalog.search(q)
            return hits.isEmpty ? [] : [("\(hits.count) MATCH\(hits.count == 1 ? "" : "ES")", hits)]
        }
        var out: [(String, [APICatalogExercise])] = []
        let mine = catalog.items.filter { $0.isMine }
        if !mine.isEmpty { out.append(("YOUR LIBRARY", mine.sorted { $0.name < $1.name })) }
        let std = catalog.items.filter { !$0.isMine }
        let byGroup = Dictionary(grouping: std, by: { $0.muscleGroup.isEmpty ? "Other" : $0.muscleGroup })
        let order = ExerciseCatalog.muscleOrder
        for g in byGroup.keys.sorted(by: { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }) {
            out.append((g.uppercased(), (byGroup[g] ?? []).sorted { $0.name < $1.name }))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(Brand.mute)
                        TextField("", text: $query, prompt: Text("Search exercises").foregroundColor(Brand.mute))
                            .foregroundColor(Brand.text).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))

                    if !catalog.loaded {
                        ProgressView().tint(Brand.voltText).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if groups.isEmpty {
                        Text("No match. Close this and type the name — it'll be added as a new exercise.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    ForEach(groups, id: \.title) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.title).font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                            VStack(spacing: 0) {
                                ForEach(g.items, id: \.stableId) { x in
                                    Button { pick(x) } label: {
                                        ExerciseRowLabel(item: x, selected: x.name.lowercased() == current.lowercased())
                                    }
                                    .buttonStyle(.plain)
                                    if x.stableId != g.items.last?.stableId {
                                        Divider().overlay(Brand.line).padding(.leading, 12)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Choose an exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Brand.bg)
        .task { await catalog.load() }
    }
}
