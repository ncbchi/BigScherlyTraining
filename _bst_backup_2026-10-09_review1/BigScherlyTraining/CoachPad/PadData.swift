import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: the data behind Today, Inbox, Check-ins and Calendar
//
// Built only on endpoints the server already has (no DLL this round). Each client's workouts
// and check-ins are loaded once and refreshed quietly every minute, so counts and the live
// session stay current without disturbing anything being typed. Threads live in CoachData.
// Synchronized folder: no target step needed.

struct PadMoveResult: Decodable { let id: String?; let scheduledDate: Date? }

extension APIClient {
    /// Coach moves a session to another day (server: PUT /admin/workouts/{id}/move, round 6).
    func trainerMoveWorkout(id: String, to day: Date) async throws {
        let c = Calendar.training.dateComponents([.year, .month, .day], from: day)
        let stamp = String(format: "%04ld-%02ld-%02ldT12:00:00Z", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
        _ = try await request("/admin/workouts/\(id)/move", method: "PUT",
                              body: try JSONSerialization.data(withJSONObject: ["date": stamp]))
    }
}

/// One client session as the coach sees it: planned, lifting now, or done.
struct PadSession: Identifiable, Equatable {
    let id: String
    let clientId: String
    let clientName: String
    let title: String
    let day: Date                 // scheduled day (start of day, local)
    let programLabel: String?
    let completed: Bool
    let setsLogged: Int
    let setsTotal: Int
    let start: Date?              // first logged set
    let finish: Date?             // last logged set
    let lastLoggedAt: Date?
    let movedFrom: Date?          // the planned day, when it was moved
    let currentExercise: String?  // exercise of the last logged set
    let currentSetText: String?   // "135 × 6"
    let currentSetId: String?
    let avgRPE: Double?
    let usualStartMinute: Int?    // the client's usual first set, minutes after midnight
    let exerciseCount: Int

    nonisolated static func == (a: PadSession, b: PadSession) -> Bool {
        a.id == b.id && a.setsLogged == b.setsLogged && a.completed == b.completed && a.day == b.day && a.lastLoggedAt == b.lastLoggedAt
    }

    /// Lifting now: not finished, and a set logged in the last 20 minutes.
    var isLive: Bool {
        guard !completed, let l = lastLoggedAt else { return false }
        return Date().timeIntervalSince(l) < 20 * 60 && setsLogged < max(setsTotal, 1)
    }
    var isDone: Bool { completed || (setsTotal > 0 && setsLogged >= setsTotal) }
    var isMissed: Bool { !isDone && !isLive && day < Calendar.training.startOfDay(for: Date()) }
    var isPlanned: Bool { !isDone && !isLive && !isMissed }
    var fraction: Double { setsTotal > 0 ? Double(setsLogged) / Double(setsTotal) : 0 }

    /// Where it sits on the day: start time if any, else the client's usual start, else noon.
    var placeMinute: Int {
        let cal = Calendar.training
        if let s = start { return cal.component(.hour, from: s) * 60 + cal.component(.minute, from: s) }
        return usualStartMinute ?? 12 * 60
    }
}

@MainActor
final class PadData: ObservableObject {
    static let shared = PadData()

    @Published private(set) var workouts: [String: [Workout]] = [:]        // by client id
    @Published private(set) var apiWorkouts: [String: [APIWorkout]] = [:]
    @Published private(set) var motion: [String: [SetMotion]] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var adherence: [String: APISupplementAdherence] = [:]
    @Published private(set) var moves: [APIWorkoutMoved] = []
    @Published private(set) var assignments: [APIAssignment] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var refreshing = false
    @Published var snoozed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "bst_pad_snoozed") ?? [])

    private var autoTask: Task<Void, Never>?
    private var clientLoads: Set<String> = []

    var hasLoaded: Bool { loadedAt != nil }

    // MARK: Loading

    /// Everything the coach screens need, for the whole roster. Keeps what's there while it reloads.
    func refresh(roster: [RosterItem], force: Bool = true) async {
        guard !refreshing || force else { return }
        refreshing = true
        let api = APIClient.shared
        let data = CoachData.shared
        await withTaskGroup(of: (String, [APIWorkout]?).self) { group in
            for c in roster {
                group.addTask { (c.id, try? await api.trainerWorkouts(clientId: c.id)) }
            }
            for await (id, ws) in group {
                if let ws {
                    apiWorkouts[id] = ws
                    workouts[id] = ws.map { $0.toModel() }
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for c in roster { group.addTask { await data.loadCheckIns(c.id, force: true) } }
            group.addTask { [weak self] in
                let m = (try? await api.recentMoves(days: 7)) ?? []
                await MainActor.run { self?.moves = m }
            }
            group.addTask { [weak self] in
                let a = (try? await api.assignments()) ?? []
                await MainActor.run { self?.assignments = a }
            }
        }
        loadedAt = Date()
        refreshing = false
    }

    /// Per-client extras (bar speed, private note, supplement adherence), loaded when a client is opened.
    func loadContext(_ clientId: String, force: Bool = false) async {
        if !force, clientLoads.contains(clientId) { return }
        clientLoads.insert(clientId)
        let api = APIClient.shared
        async let m = try? await api.trainerClientMotion(clientId: clientId)
        async let n = try? await api.clientNote(clientId: clientId)
        async let a = try? await api.coachSupplementAdherence(clientId: clientId)
        let mv = await m, nv = await n, av = await a
        if let mv { motion[clientId] = mv.map { $0.toModel() } }
        if let nv { notes[clientId] = nv.body }
        if let av { adherence[clientId] = av }
    }

    func setNote(_ clientId: String, _ text: String) { notes[clientId] = text }

    /// Quiet refresh every minute while the iPad shell is up.
    func startAuto(store: AppStore) {
        autoTask?.cancel()
        autoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self, store.isLive, store.isTrainer else { continue }
                store.loadRoster()
                await self.refresh(roster: store.roster, force: false)
            }
        }
    }
    func stopAuto() { autoTask?.cancel(); autoTask = nil }

    func snooze(_ key: String) {
        snoozed.insert(key + "|" + Calendar.training.startOfDay(for: Date()).timeIntervalSince1970.description)
        UserDefaults.standard.set(Array(snoozed), forKey: "bst_pad_snoozed")
    }
    func unsnooze(_ key: String) {
        snoozed = snoozed.filter { !$0.hasPrefix(key + "|") }
        UserDefaults.standard.set(Array(snoozed), forKey: "bst_pad_snoozed")
    }
    /// Snoozed today = hidden until tomorrow.
    func isSnoozed(_ key: String) -> Bool {
        let today = Calendar.training.startOfDay(for: Date()).timeIntervalSince1970.description
        return snoozed.contains(key + "|" + today)
    }

    // MARK: Sessions

    func sessions(for roster: [RosterItem]) -> [PadSession] {
        roster.flatMap { c in sessions(client: c) }
    }

    func sessions(client c: RosterItem) -> [PadSession] {
        let cal = Calendar.training
        let ws = apiWorkouts[c.id] ?? []
        let usual = usualStartMinute(clientId: c.id)
        return ws.map { w in
            let sets = w.exercises.flatMap { ex in ex.sets.map { (ex, $0) } }
            let logged = sets.filter { $0.1.loggedReps != nil || $0.1.loggedWeight != nil }
            let times = logged.compactMap { $0.1.loggedAt }.sorted()
            let last = logged.max { ($0.1.loggedAt ?? .distantPast) < ($1.1.loggedAt ?? .distantPast) }
            let rpes = logged.compactMap { $0.1.rpe }
            var setText: String? = nil
            if let l = last, let r = l.1.loggedReps {
                let wt = l.1.loggedWeight ?? 0
                setText = wt > 0 ? "\(StatsUnits.weightText(wt, unit: false)) × \(r)" : "\(r) reps"
            }
            var movedFrom: Date? = nil
            if let o = w.originalDate, !cal.isDate(o, inSameDayAs: w.scheduledDate) { movedFrom = cal.startOfDay(for: o) }
            return PadSession(id: w.id, clientId: c.id, clientName: c.name, title: w.title,
                              day: cal.startOfDay(for: w.scheduledDate), programLabel: w.programLabel,
                              completed: w.completed, setsLogged: logged.count, setsTotal: sets.count,
                              start: times.first, finish: times.last, lastLoggedAt: times.last,
                              movedFrom: movedFrom,
                              currentExercise: last?.0.name, currentSetText: setText, currentSetId: last?.1.id,
                              avgRPE: rpes.isEmpty ? nil : rpes.reduce(0, +) / Double(rpes.count),
                              usualStartMinute: usual, exerciseCount: w.exercises.count)
        }
    }

    /// Median minute-of-day of the first logged set, over the last 8 weeks.
    func usualStartMinute(clientId: String) -> Int? {
        let cal = Calendar.training
        let since = cal.date(byAdding: .weekOfYear, value: -8, to: Date()) ?? Date()
        let starts: [Int] = (apiWorkouts[clientId] ?? []).compactMap { w in
            guard w.scheduledDate >= since else { return nil }
            let t = w.exercises.flatMap { $0.sets }.compactMap { $0.loggedAt }.min()
            guard let t else { return nil }
            return cal.component(.hour, from: t) * 60 + cal.component(.minute, from: t)
        }.sorted()
        guard !starts.isEmpty else { return nil }
        return starts[starts.count / 2]
    }

    /// Bar speed for a set, if the Watch recorded it.
    func velocity(clientId: String, setId: String) -> Double? {
        motion[clientId]?.first { $0.setId == setId }?.meanVelocity
    }

    /// e1RM PRs this week across a client's history (ProgressEngine's own throttle).
    func prsThisWeek(clientId: String) -> [PersonalRecord] {
        let cal = Calendar.training
        let start = cal.startOfWeek(for: Date())
        return ProgressEngine.allPRs(workouts: workouts[clientId] ?? []).filter { $0.date >= start }
    }

    /// Best estimated 1RM per main lift over the last 8 weeks.
    func bestLifts(clientId: String, weeks: Int = 8) -> [(name: String, e1rm: Double)] {
        let cal = Calendar.training
        let since = cal.date(byAdding: .weekOfYear, value: -weeks, to: Date()) ?? Date()
        let ws = (workouts[clientId] ?? []).filter { $0.date >= since }
        return ["Back Squat", "Bench Press", "Deadlift"].compactMap { name in
            let h = ProgressEngine.history(for: name, workouts: ws)
            guard let best = h.map({ $0.estimatedOneRepMax }).max(), best > 0 else { return nil }
            return (name, best)
        }
    }
}
