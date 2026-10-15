import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Coach HQ on iPad: Library (3.1.8, Oct 10, 2026 · canvas row "3.1.8 Library")
//
// Shelves that say what they're doing for you: Exercises, Workouts, Programs, Forms, Nutrition,
// Messages, Targets & awards, Imports, with a Home that shows what's in use and what to tidy.
// Every item says who has it and how it's going. Giving is the same on every shelf: drag it onto
// a face in the dock, or Give to…. One search across every shelf.
// Built on endpoints the 2.1.0 server already has (exercise-library browse/detail/bulk/import,
// workout-library browse/assign, programs, check-in forms, supplement templates). No DLL.
// This file: the API models, the store, the page (bar, rail, search, dock) and the give router.
// The shelves are in PadLibraryHome / PadLibraryExercises / PadLibraryPlans / PadLibraryShelves.
// Synchronized folder: no target step needed.

// MARK: - API models

struct LibClientChip: Decodable, Hashable {
    let id: String
    let initials: String
    let name: String
}

/// One exercise as the library browse returns it: yours, standard, or a name only typed into workouts.
struct LibExercise: Decodable, Identifiable, Hashable {
    let key: String
    let serverId: String?
    let source: String              // "mine" · "standard" · "programmed" (typed only)
    let name: String
    let muscleGroup: String
    let secondary: String
    let equipment: String
    let pattern: String
    let mechanics: String
    let laterality: String
    let level: String
    let tags: [String]
    let cues: String
    let hasCues: Bool
    let videoUrl: String?
    let defaultSets: Int
    let defaultReps: Int
    let restSeconds: Int
    let loadText: String
    let used30: Int
    let spark: [Int]
    let totalTimes: Int
    let clients: [LibClientChip]
    let lastUsed: Date?
    let basedOn: String?

    var id: String { key }
    var isMine: Bool { source == "mine" }
    var isTyped: Bool { source == "programmed" }
    var hasVideo: Bool { !(videoUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var secondaryList: [String] { secondary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var cueLines: [String] { cues.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var detailLine: String { [pattern, equipment].filter { !$0.isEmpty }.joined(separator: " · ") }

    enum CodingKeys: String, CodingKey {
        case key, source, name, muscleGroup, secondary, equipment, pattern, mechanics, laterality, level, tags, cues, hasCues
        case videoUrl, defaultSets, defaultReps, restSeconds, loadText, used30, spark, totalTimes, clients, lastUsed, basedOn
        case serverId = "id"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        source = (try? c.decode(String.self, forKey: .source)) ?? "standard"
        name = try c.decode(String.self, forKey: .name)
        muscleGroup = (try? c.decode(String.self, forKey: .muscleGroup)) ?? ""
        secondary = (try? c.decode(String.self, forKey: .secondary)) ?? ""
        equipment = (try? c.decode(String.self, forKey: .equipment)) ?? ""
        pattern = (try? c.decode(String.self, forKey: .pattern)) ?? ""
        mechanics = (try? c.decode(String.self, forKey: .mechanics)) ?? ""
        laterality = (try? c.decode(String.self, forKey: .laterality)) ?? ""
        level = (try? c.decode(String.self, forKey: .level)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        cues = (try? c.decode(String.self, forKey: .cues)) ?? ""
        hasCues = (try? c.decode(Bool.self, forKey: .hasCues)) ?? false
        videoUrl = try? c.decodeIfPresent(String.self, forKey: .videoUrl)
        defaultSets = (try? c.decode(Int.self, forKey: .defaultSets)) ?? 3
        defaultReps = (try? c.decode(Int.self, forKey: .defaultReps)) ?? 8
        restSeconds = (try? c.decode(Int.self, forKey: .restSeconds)) ?? 90
        loadText = (try? c.decode(String.self, forKey: .loadText)) ?? ""
        used30 = (try? c.decode(Int.self, forKey: .used30)) ?? 0
        spark = (try? c.decode([Int].self, forKey: .spark)) ?? []
        totalTimes = (try? c.decode(Int.self, forKey: .totalTimes)) ?? 0
        clients = (try? c.decode([LibClientChip].self, forKey: .clients)) ?? []
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
        basedOn = try? c.decodeIfPresent(String.self, forKey: .basedOn)
    }
}

struct LibExerciseDetail: Decodable {
    struct Prescription: Decodable, Hashable {
        let goal: String
        let sets: Int
        let reps: String
        let load: String?
        let rest: Int?
        let tempo: String?
        let isDefault: Bool?
    }
    struct Rung: Decodable, Hashable { let name: String; let exists: Bool; let current: Bool }
    struct Usage: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let initials: String
        let sessions30: Int?
        let bestSet: String?
        let e1rm: Double?
        let trend: [Double?]
        let change: Double?
        let last: Date?
    }
    struct UsedIn: Decodable, Hashable { let kind: String; let id: String; let name: String }
    struct History: Decodable, Hashable { let at: Date; let text: String }

    let item: LibExercise
    let faults: String?
    let prescriptions: [Prescription]
    let ladder: [Rung]
    let swaps: [String]
    let clientUsage: [Usage]
    let usedIn: [UsedIn]
    let history: [History]
    let sessions30: Int?

    enum CodingKeys: String, CodingKey { case item, faults, prescriptions, ladder, swaps, clientUsage, usedIn, history, sessions30 }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        item = try c.decode(LibExercise.self, forKey: .item)
        faults = try? c.decodeIfPresent(String.self, forKey: .faults)
        prescriptions = (try? c.decode([Prescription].self, forKey: .prescriptions)) ?? []
        ladder = (try? c.decode([Rung].self, forKey: .ladder)) ?? []
        swaps = (try? c.decode([String].self, forKey: .swaps)) ?? []
        clientUsage = (try? c.decode([Usage].self, forKey: .clientUsage)) ?? []
        usedIn = (try? c.decode([UsedIn].self, forKey: .usedIn)) ?? []
        history = (try? c.decode([History].self, forKey: .history)) ?? []
        sessions30 = try? c.decodeIfPresent(Int.self, forKey: .sessions30)
    }

    var faultLines: [(fault: String, fix: String)] {
        (faults ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            let parts = line.components(separatedBy: "→")
            if parts.count >= 2 { return (parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: "→").trimmingCharacters(in: .whitespaces)) }
            return (line, "")
        }
    }
}

/// A saved workout as the workout-library browse returns it: steps, focus split, who it's given to.
struct LibWorkout: Decodable, Identifiable, Hashable {
    struct Step: Decodable, Hashable { let name: String; let muscleGroup: String?; let sets: Int; let rx: String?; let restSeconds: Int? }
    struct Given: Decodable, Hashable, Identifiable {
        let clientId: String
        let name: String
        let times: Int
        let last: Date?
        let next: Date?
        var id: String { clientId }
    }
    let id: String
    let title: String
    let tags: [String]
    let summary: String
    let exerciseCount: Int
    let setCount: Int
    let estMinutes: Int
    let legs: Double
    let push: Double
    let pull: Double
    let other: Double
    let given: Int
    let clientCount: Int
    let lastGiven: Date?
    let steps: [Step]
    let setsPerMuscle: [String: Int]
    let givenTo: [Given]
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, tags, summary, exerciseCount, setCount, estMinutes, legs, push, pull, other, given, clientCount, lastGiven, steps, setsPerMuscle, givenTo, createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Workout"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        exerciseCount = (try? c.decode(Int.self, forKey: .exerciseCount)) ?? 0
        setCount = (try? c.decode(Int.self, forKey: .setCount)) ?? 0
        estMinutes = (try? c.decode(Int.self, forKey: .estMinutes)) ?? 0
        legs = (try? c.decode(Double.self, forKey: .legs)) ?? 0
        push = (try? c.decode(Double.self, forKey: .push)) ?? 0
        pull = (try? c.decode(Double.self, forKey: .pull)) ?? 0
        other = (try? c.decode(Double.self, forKey: .other)) ?? 0
        given = (try? c.decode(Int.self, forKey: .given)) ?? 0
        clientCount = (try? c.decode(Int.self, forKey: .clientCount)) ?? 0
        lastGiven = try? c.decodeIfPresent(Date.self, forKey: .lastGiven)
        steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
        setsPerMuscle = (try? c.decode([String: Int].self, forKey: .setsPerMuscle)) ?? [:]
        givenTo = (try? c.decode([Given].self, forKey: .givenTo)) ?? []
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// "Legs", "Push", "Pull", "Mixed": the biggest share, if it's most of the workout.
    var focus: String {
        let parts: [(String, Double)] = [("Legs", legs), ("Push", push), ("Pull", pull), ("Other", other)]
        guard let top = parts.max(by: { $0.1 < $1.1 }), top.1 >= 0.6 else { return "Mixed" }
        return top.0 == "Other" ? "Accessories" : top.0
    }
}

struct LibSuppTemplate: Decodable {
    struct Item: Decodable, Hashable {
        let name: String
        let doseAmount: Double?
        let doseUnit: String?
        let timingKind: String?
        let instructions: String?
        let stackName: String?
    }
    let id: String
    let name: String
    let items: [Item]
}

struct LibAssignResult: Decodable { let created: Int? }
struct LibImportResult: Decodable { let added: Int?; let updated: Int?; let skipped: [String]? }

extension APIClient {
    private func libBody(_ d: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: d) }

    func libraryExercises() async throws -> [LibExercise] { try await get("/admin/exercise-library/browse") }
    func libraryExercise(name: String) async throws -> LibExerciseDetail {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? name
        return try await get("/admin/exercise-library/detail?name=\(q)")
    }
    func saveLibraryExercise(id: String?, body: [String: Any]) async throws {
        if let id { _ = try await request("/admin/exercise-library/\(id)", method: "PUT", body: try libBody(body)) }
        else { _ = try await request("/admin/exercise-library", method: "POST", body: try libBody(body)) }
    }
    func deleteLibraryExercise(id: String) async throws { _ = try await request("/admin/exercise-library/\(id)", method: "DELETE") }
    func importLibraryExercises(rows: [[String: Any]]) async throws -> LibImportResult {
        let data = try await request("/admin/exercise-library/import-csv", method: "POST", body: try libBody(["rows": rows]))
        return try decoder.decode(LibImportResult.self, from: data)
    }

    func libraryWorkouts() async throws -> [LibWorkout] { try await get("/admin/workout-library/browse") }
    /// Puts a saved workout on a client's calendar, one session per date.
    func giveLibraryWorkout(id: String, clientId: String, days: [Date]) async throws -> Int {
        let cal = Calendar.training
        let stamps: [String] = days.map { d in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04ld-%02ld-%02ldT12:00:00Z", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
        }
        let data = try await request("/admin/workout-library/\(id)/assign", method: "POST", body: try libBody(["clientId": clientId, "dates": stamps]))
        return (try? decoder.decode(LibAssignResult.self, from: data))?.created ?? days.count
    }
    func duplicateLibraryWorkout(id: String) async throws {
        // Same as Coach HQ: read it back raw and post it again as "(copy)".
        let raw = try await request("/admin/workout-library/\(id)", method: "GET")
        guard let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        let title = (obj["title"] as? String) ?? "Workout"
        let exs = obj["exercises"] ?? []
        _ = try await request("/admin/workout-library", method: "POST", body: try libBody(["title": "\(title) (copy)", "exercises": exs]))
    }
    func deleteLibraryWorkout(id: String) async throws { _ = try await request("/admin/workout-library/\(id)", method: "DELETE") }
    func duplicateProgram(id: String) async throws { _ = try await request("/admin/programs/\(id)/duplicate", method: "POST") }
    func supplementTemplate(id: String) async throws -> LibSuppTemplate { try await get("/admin/supplement-templates/\(id)") }
}

// MARK: - Shelves

enum PadLibraryShelf: String, CaseIterable, Identifiable {
    case home, exercises, workouts, programs, forms, nutrition, messages, targets, imports
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .exercises: return "Exercises"
        case .workouts: return "Workouts"
        case .programs: return "Programs"
        case .forms: return "Forms"
        case .nutrition: return "Nutrition"
        case .messages: return "Messages"
        case .targets: return "Targets & awards"
        case .imports: return "Imports"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .exercises: return "dumbbell"
        case .workouts: return "list.bullet"
        case .programs: return "calendar"
        case .forms: return "doc.text"
        case .nutrition: return "leaf"
        case .messages: return "text.bubble"
        case .targets: return "trophy"
        case .imports: return "square.and.arrow.down"
        }
    }
}

/// What can be given to a client, and how it travels in a drag ("kind|id").
enum PadLibraryItem: Hashable {
    case exercise(String)       // key
    case workout(String)
    case program(String)
    case form(String)           // "" = the default form
    case supplement(String)
    case target(String)

    var payload: String {
        switch self {
        case .exercise(let k): return "exercise|" + k
        case .workout(let k): return "workout|" + k
        case .program(let k): return "program|" + k
        case .form(let k): return "form|" + k
        case .supplement(let k): return "supplement|" + k
        case .target(let k): return "target|" + k
        }
    }
    static func from(_ s: String) -> PadLibraryItem? {
        let parts = s.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "exercise": return .exercise(parts[1])
        case "workout": return .workout(parts[1])
        case "program": return .program(parts[1])
        case "form": return .form(parts[1])
        case "supplement": return .supplement(parts[1])
        case "target": return .target(parts[1])
        default: return nil
        }
    }
}

// MARK: - Local bits (kept on this iPad)

/// How often each saved reply gets used, counted on this iPad when you tap one in Inbox or Check-ins.
enum PadReplyUses {
    private static let key = "bst_pad_reply_uses"
    private static let lastKey = "bst_pad_reply_last"
    static func count(_ text: String) -> Int { (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[text] ?? 0 }
    static func last(_ text: String) -> Date? {
        guard let t = (UserDefaults.standard.dictionary(forKey: lastKey) as? [String: Double])?[text] else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    static func used(_ text: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        d[text, default: 0] += 1
        UserDefaults.standard.set(d, forKey: key)
        var l = (UserDefaults.standard.dictionary(forKey: lastKey) as? [String: Double]) ?? [:]
        l[text] = Date().timeIntervalSince1970
        UserDefaults.standard.set(l, forKey: lastKey)
    }
}

/// The starters you tap for Notes for next time during Live. Edited in Library ▸ Messages.
enum PadLiveStarters {
    private static let key = "bst_pad_live_starters"
    static let builtIn: [String] = ["Go up 5 lb", "Same weight, cleaner", "Pause reps", "Slow the lowering", "Brace before the unrack"]
    static var list: [String] {
        get {
            let l = UserDefaults.standard.stringArray(forKey: key) ?? []
            return l.isEmpty ? builtIn : l
        }
        set {
            let clean = newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(clean, forKey: key)
        }
    }
}

// MARK: - The store

@MainActor
final class PadLibraryStore: ObservableObject {
    static let shared = PadLibraryStore()

    @Published var shelf: PadLibraryShelf = .home
    @Published var query = ""
    @Published var searchOpen = false

    @Published private(set) var exercises: [LibExercise] = []
    @Published private(set) var workouts: [LibWorkout] = []
    @Published private(set) var programs: [APIProgramSummary] = []
    @Published private(set) var programDocs: [String: APIProgramDetail] = [:]
    @Published private(set) var forms: [APICheckInForm] = []
    @Published private(set) var clientForms: [String: String] = [:]      // client id → form id ("" = default)
    @Published private(set) var templates: [APISupplementTemplate] = []
    @Published private(set) var templateDetails: [String: LibSuppTemplate] = [:]
    @Published private(set) var awards: [RosterAward] = []
    @Published private(set) var details: [String: LibExerciseDetail] = [:]   // by exercise key
    @Published private(set) var loaded = false
    @Published private(set) var failed = false

    // Selection, per shelf
    @Published var exerciseKey: String?
    @Published var workoutId: String?
    @Published var programId: String?
    @Published var formId: String?           // "" = default form
    @Published var templateId: String?
    @Published var replyText: String?
    @Published var targetTemplateId: String?

    // Exercise filters
    @Published var muscles: Set<String> = []
    @Published var pattern: String?
    @Published var equipment: String?
    @Published var source = "all"            // all · mine · standard · typed
    @Published var inUseOnly = false
    @Published var tag: String?
    @Published var exQuery = ""
    @Published var noCuesOnly = false

    /// Programs: what they did for everyone who ran them (worked out from PadData; see PadLibraryPlans).
    @Published var programResults: [String: PadLibraryProgramResult] = [:]
    var resultsStamp: Date?

    @Published var replyUsesVersion = 0
    @Published var startersVersion = 0

    private var loading = false

    // MARK: Loading

    func load(store: AppStore, force: Bool = false) async {
        guard store.isLive else { loaded = true; return }
        if loading { return }
        if loaded && !force { return }
        loading = true
        defer { loading = false }
        let api = APIClient.shared
        async let ex = try? await api.libraryExercises()
        async let wo = try? await api.libraryWorkouts()
        async let pr = try? await api.programs()
        async let fo = try? await api.checkInForms()
        async let te = try? await api.supplementTemplates()
        async let aw = try? await api.recentAwards(days: 90)
        let exv = await ex, wov = await wo, prv = await pr, fov = await fo, tev = await te, awv = await aw
        if let exv { exercises = exv }
        if let wov { workouts = wov }
        if let prv { programs = prv }
        if let fov { forms = fov }
        if let tev { templates = tev }
        if let awv { awards = awv }
        failed = exv == nil && wov == nil && prv == nil
        loaded = true
        await PadTargets.shared.load(store: store)
        await loadProgramDocs()
        if !PadData.shared.hasLoaded { await PadData.shared.refresh(roster: store.roster) }
        computeResults(store: store)
    }

    func reloadExercises() async {
        if let x = try? await APIClient.shared.libraryExercises() { exercises = x }
        details = [:]
    }
    func reloadWorkouts() async { if let x = try? await APIClient.shared.libraryWorkouts() { workouts = x } }
    func reloadPrograms() async {
        if let x = try? await APIClient.shared.programs() { programs = x }
        await loadProgramDocs(force: true)
    }
    func reloadForms(store: AppStore) async {
        if let x = try? await APIClient.shared.checkInForms() { forms = x }
        await loadClientForms(store: store, force: true)
    }

    func loadProgramDocs(force: Bool = false) async {
        let want = programs.filter { force || programDocs[$0.id] == nil }
        await withTaskGroup(of: (String, APIProgramDetail?).self) { group in
            for p in want { group.addTask { (p.id, try? await APIClient.shared.program(p.id)) } }
            for await (id, d) in group { if let d { programDocs[id] = d } }
        }
    }

    func detail(_ x: LibExercise) async {
        if details[x.key] != nil { return }
        if let d = try? await APIClient.shared.libraryExercise(name: x.name) { details[x.key] = d }
    }
    func refreshDetail(_ x: LibExercise) async {
        if let d = try? await APIClient.shared.libraryExercise(name: x.name) { details[x.key] = d }
    }

    func templateDetail(_ id: String) async {
        if templateDetails[id] != nil { return }
        if let d = try? await APIClient.shared.supplementTemplate(id: id) { templateDetails[id] = d }
    }

    /// Which form each client is on (one call per client; quiet).
    func loadClientForms(store: AppStore, force: Bool = false) async {
        let missing = store.roster.filter { force || clientForms[$0.id] == nil }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (String, String?).self) { group in
            for c in missing {
                group.addTask {
                    guard let f = try? await APIClient.shared.clientCheckInForm(clientId: c.id) else { return (c.id, nil) }
                    return (c.id, f.formId ?? "")
                }
            }
            for await (id, f) in group { if let f { clientForms[id] = f } }
        }
    }
    func setClientForm(_ clientId: String, _ formId: String) { clientForms[clientId] = formId }

    // MARK: Derived

    var mine: [LibExercise] { exercises.filter { $0.isMine } }
    var typed: [LibExercise] { exercises.filter { $0.isTyped } }
    var usedMissingCues: [LibExercise] { exercises.filter { $0.used30 > 0 && !$0.hasCues && !$0.isTyped } }

    /// Saved workouts that are the same exercises as another one (a copy left behind).
    var duplicateWorkouts: [(copy: LibWorkout, of: LibWorkout)] {
        var out: [(copy: LibWorkout, of: LibWorkout)] = []
        let sorted = workouts.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        for (i, w) in sorted.enumerated() {
            let sig = w.steps.map { $0.name.lowercased() }.joined(separator: "|")
            guard !sig.isEmpty else { continue }
            if let first = sorted.prefix(i).first(where: { $0.steps.map { $0.name.lowercased() }.joined(separator: "|") == sig }) {
                out.append((w, first))
            }
        }
        return out
    }

    /// The standard exercise a typed name most likely means ("DB Bulgarian split" → Bulgarian Split Squat).
    func likelyMatch(_ typedName: String) -> LibExercise? {
        let words = Set(typedName.lowercased().replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !words.isEmpty else { return nil }
        var best: (LibExercise, Int)? = nil
        for x in exercises where !x.isTyped {
            let xw = Set(x.name.lowercased().split(separator: " ").map(String.init))
            let n = words.intersection(xw).count
            if n >= 2 || (n == 1 && words.count == 1) {
                if best == nil || n > best!.1 { best = (x, n) }
            }
        }
        return best?.0
    }

    var tidyCount: Int { typed.count + duplicateWorkouts.count + (usedMissingCues.isEmpty ? 0 : 1) }

    var allTags: [(tag: String, count: Int)] {
        var d: [String: Int] = [:]
        for x in exercises { for t in x.tags { d[t, default: 0] += 1 } }
        for w in workouts { for t in w.tags { d[t, default: 0] += 1 } }
        return d.map { (tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    func exercise(_ key: String) -> LibExercise? { exercises.first { $0.key == key } }
    func exercise(named name: String) -> LibExercise? { exercises.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func workout(_ id: String) -> LibWorkout? { workouts.first { $0.id == id } }
    func program(_ id: String) -> APIProgramSummary? { programs.first { $0.id == id } }
    func form(_ id: String) -> APICheckInForm? { forms.first { $0.id == id } }
    func template(_ id: String) -> APISupplementTemplate? { templates.first { $0.id == id } }

    func name(of item: PadLibraryItem) -> String {
        switch item {
        case .exercise(let k): return exercise(k)?.name ?? k
        case .workout(let k): return workout(k)?.title ?? "Workout"
        case .program(let k): return program(k)?.name ?? "Program"
        case .form(let k): return k.isEmpty ? "Default form" : (form(k)?.name ?? "Form")
        case .supplement(let k): return template(k)?.name ?? "Template"
        case .target(let k): return PadTargets.shared.templates.first { $0.id == k }?.title ?? "Target"
        }
    }

    func open(_ s: PadLibraryShelf) {
        withAnimation(.easeOut(duration: 0.15)) { shelf = s }
    }
}

// MARK: - Sheets the page can show

enum PadLibrarySheet: Identifiable {
    case builder(RosterItem, [DraftExercise])
    case giveWorkout(LibWorkout, RosterItem)
    case giveProgram(APIProgramSummary, String?)
    case giveTarget(RosterItem, PadTargetTemplate)
    case exerciseEditor(LibExercise?)
    case formEditor(APICheckInForm?)
    case defaultFormEditor
    case newForm
    case programDetail(APIProgramSummary)
    case importRows([[String: String]])

    var id: String {
        switch self {
        case .builder(let c, _): return "builder" + c.id
        case .giveWorkout(let w, let c): return "gw" + w.id + c.id
        case .giveProgram(let p, let c): return "gp" + p.id + (c ?? "")
        case .giveTarget(let c, let t): return "gt" + c.id + t.id
        case .exerciseEditor(let x): return "ed" + (x?.key ?? "new")
        case .formEditor(let f): return "fe" + (f?.id ?? "")
        case .defaultFormEditor: return "fd"
        case .newForm: return "fn"
        case .programDetail(let p): return "pd" + p.id
        case .importRows(let r): return "im\(r.count)"
        }
    }
}

/// Actions every shelf can reach (give, open a sheet), passed down the environment.
struct PadLibraryActions {
    var give: (PadLibraryItem, RosterItem) -> Void = { _, _ in }
    var sheet: (PadLibrarySheet) -> Void = { _ in }
}
private struct PadLibraryActionsKey: EnvironmentKey { static let defaultValue = PadLibraryActions() }
extension EnvironmentValues {
    var padLibrary: PadLibraryActions { get { self[PadLibraryActionsKey.self] } set { self[PadLibraryActionsKey.self] = newValue } }
}

// MARK: - The page

struct PadLibraryView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padGo) private var go
    @State private var sheet: PadLibrarySheet?
    @State private var confirmForm: (item: String, client: RosterItem)?
    @State private var confirmSupp: (item: String, client: RosterItem)?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Library", facts: facts) {
                searchField
                newMenu
            }
            HStack(spacing: 0) {
                PadLibraryRail()
                Rectangle().fill(Pad.line).frame(width: 1)
                VStack(spacing: 0) {
                    shelfView.frame(maxWidth: .infinity, maxHeight: .infinity)
                    PadLibraryDock()
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if lib.searchOpen && !lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                PadLibrarySearchResults { searchFocused = false }
                    .padding(.top, 70).padding(.trailing, 150)
            }
        }
        .environment(\.padLibrary, PadLibraryActions(give: give, sheet: { sheet = $0 }))
        .task { await lib.load(store: store) }
        .refreshable { await lib.load(store: store, force: true) }
        .sheet(item: $sheet, onDismiss: { Task { await lib.load(store: store, force: true) } }) { s in sheetView(s) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmForm != nil }, set: { if !$0 { confirmForm = nil } }), titleVisibility: .visible) {
            Button("Give it") { if let c = confirmForm { giveForm(c.item, to: c.client) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Applies from their next check-in. Past check-ins keep their answers.") }
        .confirmationDialog(confirmSuppTitle, isPresented: Binding(get: { confirmSupp != nil }, set: { if !$0 { confirmSupp = nil } }), titleVisibility: .visible) {
            Button("Add them") { if let c = confirmSupp { giveSupplements(c.item, to: c.client) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Adds the template's supplements to their protocol. Anything they already take stays.") }
    }

    private var confirmTitle: String {
        guard let c = confirmForm else { return "" }
        return "Give \(c.client.name.firstName) “\(lib.name(of: .form(c.item)))”?"
    }
    private var confirmSuppTitle: String {
        guard let c = confirmSupp else { return "" }
        return "Add “\(lib.name(of: .supplement(c.item)))” to \(c.client.name.firstName)'s supplements?"
    }

    // MARK: Bar

    private var facts: [PadFact] {
        guard lib.loaded else { return [] }
        var out: [PadFact] = [
            PadFact(bold: "\(lib.exercises.filter { !$0.isTyped }.count)", tail: " exercises", run: { lib.open(.exercises) }),
            PadFact(bold: "\(lib.workouts.count)", tail: " workouts", run: { lib.open(.workouts) }),
            PadFact(bold: "\(lib.programs.count)", tail: lib.programs.count == 1 ? " program" : " programs", run: { lib.open(.programs) }),
            PadFact(bold: "\(lib.forms.count + 1)", tail: " forms", run: { lib.open(.forms) }),
        ]
        let t = lib.tidyCount
        if t > 0 { out.append(PadFact(bold: "\(t)", tail: " to tidy", warn: true, run: { lib.open(.home) })) }
        return out
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.mute)
            TextField("Search the library", text: $lib.query)
                .font(PadFont.ui(15)).foregroundColor(Pad.text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($searchFocused)
                .onChange(of: searchFocused) { _, f in if f { lib.searchOpen = true } }
                .onChange(of: lib.query) { _, _ in lib.searchOpen = true }
                .onSubmit { lib.searchOpen = true }
            if !lib.query.isEmpty {
                Button { lib.query = ""; lib.searchOpen = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(Pad.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 250, height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
    }

    private var newMenu: some View {
        Menu {
            Button { sheet = .exerciseEditor(nil) } label: { Label("Exercise", systemImage: "dumbbell") }
            Button { sheet = .newForm } label: { Label("Check-in form", systemImage: "doc.text") }
            Button { lib.open(.messages); PadLibraryMessagesNew.shared.reply = true } label: { Label("Saved reply", systemImage: "text.bubble") }
            Button { lib.open(.messages); PadLibraryMessagesNew.shared.starter = true } label: { Label("Note for next time starter", systemImage: "note.text") }
            Button { lib.open(.imports) } label: { Label("Import exercises from a CSV", systemImage: "square.and.arrow.down") }
        } label: {
            PadMenuLabel(text: "New", kind: .primary, icon: "plus")
        }
    }

    // MARK: Shelves

    @ViewBuilder
    private var shelfView: some View {
        switch lib.shelf {
        case .home: PadLibraryHome()
        case .exercises: PadLibraryExercises()
        case .workouts: PadLibraryWorkouts()
        case .programs: PadLibraryPrograms()
        case .forms: PadLibraryForms()
        case .nutrition: PadLibraryNutrition()
        case .messages: PadLibraryMessages()
        case .targets: PadLibraryTargets()
        case .imports: PadLibraryImports()
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ s: PadLibrarySheet) -> some View {
        switch s {
        case .builder(let c, let drafts):
            WorkoutBuilderView(clientId: c.id, clientName: c.id == store.selfClientId ? "" : c.name, startWith: drafts) {
                Task { await PadData.shared.refresh(roster: store.roster) }
            }
        case .giveWorkout(let w, let c):
            PadLibraryGiveWorkoutSheet(workout: w, client: c)
        case .giveProgram(let p, let c):
            AssignProgramSheet(programId: p.id, programName: p.name, preselected: c) {
                Task { await PadData.shared.refresh(roster: store.roster) }
            }
        case .giveTarget(let c, let t):
            PadTargetSheet(facts: PadInsights.facts(c, store: store), existing: nil, startFrom: t)
        case .exerciseEditor(let x):
            PadLibraryExerciseEditor(base: x)
        case .formEditor(let f):
            CheckInFormEditor(form: f)
        case .defaultFormEditor:
            CheckInFormEditor()
        case .newForm:
            CheckInFormEditor(newForm: true)
        case .programDetail(let p):
            NavigationStack { CoachProgramDetailView(summary: p) { Task { await lib.reloadPrograms() } } }
        case .importRows(let rows):
            PadLibraryImportSheet(rows: rows)
        }
    }

    // MARK: Giving

    private func give(_ item: PadLibraryItem, _ c: RosterItem) {
        switch item {
        case .exercise(let k):
            guard let x = lib.exercise(k) else { return }
            sheet = .builder(c, [PadLibraryExercises.draft(x)])
        case .workout(let k):
            guard let w = lib.workout(k) else { return }
            sheet = .giveWorkout(w, c)
        case .program(let k):
            guard let p = lib.program(k) else { return }
            sheet = .giveProgram(p, c.id)
        case .form(let k):
            confirmForm = (k, c)
        case .supplement(let k):
            confirmSupp = (k, c)
        case .target(let k):
            guard let t = PadTargets.shared.templates.first(where: { $0.id == k }) else { return }
            sheet = .giveTarget(c, t)
        }
    }

    private func giveForm(_ formId: String, to c: RosterItem) {
        let before: String? = lib.clientForms[c.id]
        Task {
            do {
                _ = try await APIClient.shared.assignCheckInForm(clientId: c.id, formId: formId.isEmpty ? nil : formId)
                lib.setClientForm(c.id, formId)
                await lib.reloadForms(store: store)
                PadToasts.shared.show("\(c.name.firstName) is on “\(lib.name(of: .form(formId)))” from their next check-in",
                                      action: before == nil ? nil : "Undo") {
                    guard let before else { return }
                    Task {
                        _ = try? await APIClient.shared.assignCheckInForm(clientId: c.id, formId: before.isEmpty ? nil : before)
                        lib.setClientForm(c.id, before)
                        await lib.reloadForms(store: store)
                    }
                }
            } catch {
                PadToasts.shared.show("Couldn't change \(c.name.firstName)'s form. Try again.")
            }
        }
    }

    private func giveSupplements(_ templateId: String, to c: RosterItem) {
        Task {
            do {
                try await APIClient.shared.applySupplementTemplate(clientId: c.id, templateId: templateId)
                PadToasts.shared.show("Added to \(c.name.firstName)'s supplements")
                await PadData.shared.loadContext(c.id, force: true)
            } catch {
                PadToasts.shared.show("Couldn't add them. Try again.")
            }
        }
    }
}

/// "New ▾" asks the Messages shelf to start a new reply or starter.
@MainActor
final class PadLibraryMessagesNew: ObservableObject {
    static let shared = PadLibraryMessagesNew()
    @Published var reply = false
    @Published var starter = false
}

// MARK: - The shelf rail

struct PadLibraryRail: View {
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var targets = PadTargets.shared
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(PadLibraryShelf.allCases) { s in row(s) }
                let tags = Array(lib.allTags.prefix(8))
                if !tags.isEmpty {
                    PadLab("TAGS", color: Pad.faint, size: 11).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                    ForEach(tags, id: \.tag) { t in tagRow(t.tag, t.count) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
        .frame(width: 210)
        .background(Pad.isLight ? Color(hex: 0xEFEFEB) : Pad.well)
    }

    private func count(_ s: PadLibraryShelf) -> String {
        guard lib.loaded else { return "" }
        switch s {
        case .home, .imports: return ""
        case .exercises: return "\(lib.exercises.filter { !$0.isTyped }.count)"
        case .workouts: return "\(lib.workouts.count)"
        case .programs: return "\(lib.programs.count)"
        case .forms: return "\(lib.forms.count + 1)"
        case .nutrition: return "\(lib.templates.count)"
        case .messages: return "\(store.savedReplies.count + PadLiveStarters.list.count)"
        case .targets: return "\(targets.templates.count)"
        }
    }

    private func row(_ s: PadLibraryShelf) -> some View {
        let on: Bool = lib.shelf == s
        return Button { lib.open(s) } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon).font(.system(size: 15, weight: .semibold)).foregroundColor(on ? Pad.text : Pad.mute).frame(width: 22)
                Text(s.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                Spacer(minLength: 4)
                if s == .home && lib.tidyCount > 0 {
                    Text("\(lib.tidyCount)").font(PadFont.cond(13)).foregroundColor(Pad.orange)
                } else {
                    Text(count(s)).font(PadFont.cond(13)).foregroundColor(Pad.faint)
                }
            }
            .padding(.horizontal, 10).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.surface : Color.clear))
            .overlay(alignment: .leading) {
                if on { RoundedRectangle(cornerRadius: 2).fill(Pad.text).frame(width: 3, height: 26) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .keyboardShortcut(shortcut(s), modifiers: [.command, .option])
    }

    private func shortcut(_ s: PadLibraryShelf) -> KeyEquivalent {
        let i = PadLibraryShelf.allCases.firstIndex(of: s) ?? 0
        return KeyEquivalent(Character(String(i + 1)))
    }

    private func tagRow(_ t: String, _ n: Int) -> some View {
        let on: Bool = lib.tag == t && lib.shelf == .exercises
        return Button {
            lib.tag = on ? nil : t
            lib.open(.exercises)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(PadLibraryKit.tagColor(t)).frame(width: 9, height: 9)
                Text(t).font(PadFont.ui(14)).foregroundColor(on ? Pad.text : Pad.mute).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(n)").font(PadFont.cond(12)).foregroundColor(Pad.faint)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Pad.surface : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - The dock: drag anything onto someone to give it

struct PadLibraryDock: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions
    @State private var hot: String?

    private var people: [RosterItem] {
        var out: [RosterItem] = []
        if let me = store.selfClientId { out.append(RosterItem.stub(me, "You")) }
        out += store.roster.sorted { $0.name < $1.name }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Pad.line2).frame(height: 1)
            HStack(spacing: 14) {
                Text("Drag anything onto someone to give it").font(PadFont.cond(13)).foregroundColor(Pad.mute)
                    .frame(width: 130, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { ForEach(people) { c in face(c) } }
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 20).frame(height: 84)
            .background(Pad.surface.opacity(0.94))
        }
    }

    private func face(_ c: RosterItem) -> some View {
        let isHot: Bool = hot == c.id
        return VStack(spacing: 4) {
            PadAvatar(name: c.name, size: 44, volt: isHot)
                .overlay(Circle().stroke(isHot ? Pad.volt : Color.clear, lineWidth: 3).padding(-5))
            Text(c.id == store.selfClientId ? "You" : c.name).font(PadFont.cond(12)).foregroundColor(isHot ? Pad.text : Pad.mute).lineLimit(1)
        }
        .frame(width: 62)
        .scaleEffect(isHot ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isHot)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let item = PadLibraryItem.from(s) else { return false }
            actions.give(item, c)
            return true
        } isTargeted: { on in
            if on { hot = c.id } else if hot == c.id { hot = nil }
        }
        .accessibilityLabel("Give to \(c.name)")
    }
}

/// "Give to…": the same people as the dock, as a menu.
struct PadLibraryGiveMenu: View {
    let item: PadLibraryItem
    var label = "Give to…"
    var small = true
    @EnvironmentObject var store: AppStore
    @Environment(\.padLibrary) private var actions
    var body: some View {
        Menu {
            if let me = store.selfClientId {
                Button("You — your own training") { actions.give(item, RosterItem.stub(me, store.trainerName.isEmpty ? "You" : store.trainerName)) }
            }
            ForEach(store.roster.sorted { $0.name < $1.name }) { c in
                Button(c.name) { actions.give(item, c) }
            }
        } label: {
            PadLibraryDarkLabel(text: label, icon: "gift")
        }
    }
}

// MARK: - One search for the whole Library

struct PadLibrarySearchResults: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var targets = PadTargets.shared
    @Environment(\.padGo) private var go
    var done: () -> Void

    struct Hit: Identifiable {
        let id: String
        let icon: String
        let title: String
        let sub: String
        let open: () -> Void
    }

    private var q: String { lib.query.trimmingCharacters(in: .whitespaces).lowercased() }
    private func hit(_ s: String) -> Bool { PadLibraryKit.matches(s, q) }

    private var groups: [(name: String, hits: [Hit])] {
        let L = lib
        var out: [(name: String, hits: [Hit])] = []
        let ex: [Hit] = L.exercises.filter { hit($0.name) || $0.tags.contains(where: { hit($0) }) || hit($0.muscleGroup) }
            .sorted { $0.used30 > $1.used30 }.prefix(4).map { x in
                Hit(id: "x" + x.key, icon: "dumbbell", title: x.name,
                    sub: [x.isMine ? "yours" : (x.isTyped ? "typed" : "standard"), x.clients.isEmpty ? nil : x.clients.count.plural("client")].compactMap { $0 }.joined(separator: " · "),
                    open: { L.exerciseKey = x.key; L.open(.exercises) })
            }
        if !ex.isEmpty { out.append(("Exercises", ex)) }
        let wo: [Hit] = L.workouts.filter { hit($0.title) || hit($0.summary) }.prefix(3).map { w in
            Hit(id: "w" + w.id, icon: "list.bullet", title: w.title, sub: w.given > 0 ? "given \(w.given) times" : w.summary,
                open: { L.workoutId = w.id; L.open(.workouts) })
        }
        if !wo.isEmpty { out.append(("Workouts", wo)) }
        let pr: [Hit] = L.programs.filter { p in hit(p.name) || hit(p.description) || (L.programDocs[p.id]?.doc.blocks.contains { b in b.days.contains { d in d.exercises.contains { hit($0.name) } } } ?? false) }
            .prefix(3).map { p in
                Hit(id: "p" + p.id, icon: "calendar", title: p.name, sub: "\(p.weeks) weeks · \(p.daysPerWeek) days", open: { L.programId = p.id; L.open(.programs) })
            }
        if !pr.isEmpty { out.append(("Programs", pr)) }
        let fo: [Hit] = L.forms.filter { hit($0.name) }.prefix(3).map { f in
            Hit(id: "f" + f.id, icon: "doc.text", title: f.name, sub: f.clientCount.plural("client"), open: { L.formId = f.id; L.open(.forms) })
        }
        if !fo.isEmpty { out.append(("Forms", fo)) }
        let te: [Hit] = L.templates.filter { hit($0.name) }.prefix(3).map { t in
            Hit(id: "t" + t.id, icon: "leaf", title: t.name, sub: t.itemCount.plural("supplement"), open: { L.templateId = t.id; L.open(.nutrition) })
        }
        if !te.isEmpty { out.append(("Nutrition", te)) }
        let re: [Hit] = (store.savedReplies.filter { hit($0) } + PadLiveStarters.list.filter { hit($0) }).prefix(3).map { r in
            Hit(id: "r" + r, icon: "text.bubble", title: r, sub: "\(PadReplyUses.count(r)) uses", open: { L.replyText = r; L.open(.messages) })
        }
        if !re.isEmpty { out.append(("Messages", re)) }
        let tg: [Hit] = targets.templates.filter { hit($0.title) || hit($0.lift) }.prefix(3).map { t in
            Hit(id: "g" + t.id, icon: "trophy", title: t.title, sub: PadLibraryTargets.rule(t), open: { L.targetTemplateId = t.id; L.open(.targets) })
        }
        if !tg.isEmpty { out.append(("Targets", tg)) }
        let pe: [Hit] = store.roster.filter { hit($0.name) }.prefix(3).map { c in
            Hit(id: "c" + c.id, icon: "person", title: c.name, sub: c.goal, open: { PadOpen.client(c.id, go: go) })
        }
        if !pe.isEmpty { out.append(("People", pe)) }
        return out
    }

    var body: some View {
        let gs = groups
        let n: Int = gs.map { $0.hits.count }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                PadLab(n == 0 ? "Nothing in the library matches “\(lib.query)”" : "\(n.plural("result")) · \(gs.count) \(gs.count == 1 ? "shelf" : "shelves")", color: Pad.mute, size: 12)
                Spacer()
                Button { lib.searchOpen = false; done() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Pad.mute) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(Pad.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(gs, id: \.name) { g in
                        PadLab(g.name.uppercased(), color: Pad.faint, size: 11).padding(.horizontal, 16).padding(.top, 8)
                        ForEach(g.hits) { h in
                            Button { h.open(); lib.searchOpen = false; done() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: h.icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.text)
                                        .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
                                    Text(h.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                                    Text(h.sub).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 16).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Pad.line2, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.22), radius: 26, x: 0, y: 14)
    }
}

// MARK: - Small shared pieces

enum PadLibraryKit {
    /// Every word typed appears somewhere ("inc db" finds Incline DB Press).
    static func matches(_ s: String, _ q: String) -> Bool {
        let words = q.lowercased().split(separator: " ").map(String.init)
        if words.isEmpty { return true }
        let hay = s.lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    static func tagColor(_ t: String) -> Color {
        let palette: [Color] = [Pad.volt, Pad.text, Pad.orange, Color(hex: 0xB9BAB5), Pad.green, Pad.blue]
        var h = 0
        for u in t.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        return PadDay.agoText(d)
    }

    /// 90 → "1:30", 45 → "0:45".
    static func rest(_ sec: Int) -> String { String(format: "%d:%02d", sec / 60, sec % 60) }

    static let lowerMuscles: Set<String> = ["Quads", "Hamstrings", "Glutes", "Calves", "Legs", "Adductors", "Abductors"]
    static let upperMuscles: Set<String> = ["Chest", "Back", "Shoulders", "Biceps", "Triceps", "Forearms", "Lats", "Traps"]
    static func isLower(_ m: String) -> Bool { lowerMuscles.contains(m) }

    /// A day's focus from its exercises' muscles, weighted by sets: 0 lower · 1 upper · 2 full.
    static func focus(_ parts: [(muscle: String, sets: Int)]) -> Int {
        let total = parts.map { max($0.sets, 1) }.reduce(0, +)
        guard total > 0 else { return 2 }
        let lower = parts.filter { lowerMuscles.contains($0.muscle) }.map { max($0.sets, 1) }.reduce(0, +)
        let upper = parts.filter { upperMuscles.contains($0.muscle) }.map { max($0.sets, 1) }.reduce(0, +)
        if Double(lower) / Double(total) >= 0.6 { return 0 }
        if Double(upper) / Double(total) >= 0.6 { return 1 }
        return 2
    }

    /// Program weekday (Monday = 0) → "Mon".
    static func weekday(_ i: Int) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return names[((i % 7) + 7) % 7]
    }
}

/// Tiny bar spark (the browse's 10 buckets).
struct PadLibrarySpark: View {
    let values: [Int]
    var width: CGFloat = 64
    var height: CGFloat = 22
    var body: some View {
        let m: Int = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == values.count - 1 ? Pad.text : Pad.text.opacity(0.35))
                    .frame(height: max(2, height * CGFloat(v) / CGFloat(m)))
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// A line spark from optional points (gaps skipped), dot on the last.
struct PadLibraryLine: View {
    let values: [Double?]
    var width: CGFloat = 96
    var height: CGFloat = 24
    var color: Color = Pad.text
    var body: some View {
        let pts: [(Int, Double)] = values.enumerated().compactMap { i, v in v.map { (i, $0) } }
        let lo: Double = pts.map { $0.1 }.min() ?? 0
        let hi: Double = pts.map { $0.1 }.max() ?? 1
        let span: Double = max(hi - lo, 1)
        let n: Int = max(values.count - 1, 1)
        Canvas { ctx, size in
            guard pts.count >= 2 else { return }
            var path = Path()
            for (k, p) in pts.enumerated() {
                let x = size.width * CGFloat(p.0) / CGFloat(n)
                let y = size.height - 3 - (size.height - 6) * CGFloat((p.1 - lo) / span)
                if k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let l = pts.last {
                let x = size.width * CGFloat(l.0) / CGFloat(n)
                let y = size.height - 3 - (size.height - 6) * CGFloat((l.1 - lo) / span)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// A shelf's list column with its header row.
struct PadLibraryColumn<Header: View, Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            header()
            Rectangle().fill(Pad.line).frame(height: 1)
            ScrollView { VStack(spacing: 0) { content() } }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity)
    }
}

/// A selectable row in a shelf's list: inset bar and white fill when selected.
struct PadLibraryRowStyle: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.surface : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.text).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
            .contentShape(Rectangle())
    }
}
extension View {
    func padLibraryRow(_ on: Bool) -> some View { modifier(PadLibraryRowStyle(on: on)) }
}

/// The one dark button on an item ("Give to…").
struct PadLibraryDarkLabel: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
            Text(text).font(PadFont.ui(14, .semibold)).lineLimit(1)
        }
        .foregroundColor(Pad.isLight ? .white : Pad.ink)
        .padding(.horizontal, 13).frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(Pad.text))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// An inspector's empty state.
struct PadLibraryPick: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold)).foregroundColor(Pad.faint)
            Text(title).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            Text(text).font(PadFont.ui(14)).foregroundColor(Pad.mute).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
