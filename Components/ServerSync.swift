import Foundation
import Combine

// MARK: - v1.1 server sync
//
// The phone is the only writer of the client's own notes, Watch motion and macro-plan
// changes, so sync is simple and robust:
//   • every local change marks a small key in an OUTBOX (persisted, survives restarts);
//   • the outbox is sent whenever the app is live (after a load, on foreground, and a
//     moment after each change); each key re-reads the CURRENT local value when sent,
//     so many edits to one thing collapse into one request;
//   • the first live launch after this update queues everything already on the phone;
//   • a new phone (empty local stores) restores from the server instead.
// Demo mode never syncs.

// MARK: API shapes (server v1.1)

struct APISetMotion: Decodable {
    let workoutId: String
    let exerciseId: String
    let setId: String
    let exerciseName: String
    let start: Date
    let end: Date
    let reps: [RepMotion]
    let autoDetected: Bool
    let analyzerVersion: Int

    func toModel() -> SetMotion {
        SetMotion(id: setId, workoutId: workoutId, exerciseId: exerciseId, setId: setId,
                  exerciseName: exerciseName, start: start, end: end, reps: reps,
                  autoDetected: autoDetected, analyzerVersion: analyzerVersion)
    }
}

struct APIDayOverride: Decodable { let day: String; let isTraining: Bool; let note: String? }
struct APIActivity: Decodable {
    let id: String; let day: String; let start: Date?; let type: String; let minutes: Int
    let reportedKcal: Int?; let adjustPct: Double; let addToTarget: Bool; let countsAsTraining: Bool
    let fromHealth: Bool; let healthId: String?; let avgHeartRate: Int?; let peakHeartRate: Int?; let rpe: Int?
}
struct APISessionBurn: Decodable { let workoutId: String; let day: String; let reportedKcal: Int; let adjustPct: Double }
struct APIWorkoutMove: Decodable { let workoutId: String; let title: String; let originalDate: Date; let scheduledDate: Date }
struct APIPlanAdjustments: Decodable {
    let days: [APIDayOverride]; let activities: [APIActivity]; let burns: [APISessionBurn]; let moves: [APIWorkoutMove]
}
struct APIWorkoutHealthRow: Decodable {
    let workoutId: String; let start: Date; let end: Date; let durationMinutes: Int
    let avgHeartRate: Int?; let peakHeartRate: Int?; let activeCalories: Int?
    let heartRateSeries: [APIHeartRatePoint]
    func toVitals() -> WorkoutVitals {
        WorkoutVitals(start: start, end: end, durationMinutes: durationMinutes,
                      avgHeartRate: avgHeartRate, peakHeartRate: peakHeartRate, activeCalories: activeCalories,
                      heartRateSeries: heartRateSeries.map { HeartRateSample(time: $0.t, bpm: $0.b) })
    }
}
struct APIHeartRatePoint: Decodable { let t: Date; let b: Int }

// MARK: API calls (server v1.1)

extension APIClient {
    private static let isoEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private func send(_ path: String, _ method: String, _ obj: Any? = nil) async throws {
        _ = try await request(path, method: method, body: try obj.map { try JSONSerialization.data(withJSONObject: $0) })
    }

    // Notes
    func saveExerciseNote(workoutId: String, exerciseId: String, text: String) async throws {
        try await send("/workouts/\(workoutId)/exercises/\(exerciseId)", "PATCH", ["clientNotes": text])
    }
    func saveWorkoutNote(workoutId: String, text: String) async throws {
        try await send("/workouts/\(workoutId)/note", "PATCH", ["note": text])
    }

    // Watch motion
    func uploadMotion(workoutId: String, motions: [SetMotion]) async throws {
        let data = try Self.isoEncoder.encode(motions)
        let list = try JSONSerialization.jsonObject(with: data)
        try await send("/workouts/\(workoutId)/motion", "PUT", ["motions": list])
    }
    func myMotion() async throws -> [APISetMotion] { try await get("/motion") }

    // Macro plan
    func planAdjustments() async throws -> APIPlanAdjustments { try await get("/plan-adjustments") }
    func moveWorkout(id: String, to date: Date) async throws {
        try await send("/workouts/\(id)/move", "POST", ["date": Self.iso(date)])
    }
    func setDayType(day: String, isTraining: Bool, note: String) async throws {
        try await send("/plan/days/\(day)", "PUT", ["isTraining": isTraining, "note": note])
    }
    func clearDayType(day: String) async throws { try await send("/plan/days/\(day)", "DELETE") }
    func saveActivity(_ a: ExtraActivity, day: String) async throws {
        var body: [String: Any] = ["id": a.id, "day": day, "type": a.type, "minutes": a.minutes,
                                   "adjustPct": a.adjustPct, "addToTarget": a.addToTarget,
                                   "countsAsTraining": a.countsAsTraining, "fromHealth": a.fromHealth]
        if let s = a.start { body["start"] = Self.iso(s) }
        if let k = a.reportedKcal { body["reportedKcal"] = k }
        if let h = a.healthId { body["healthId"] = h }
        if let h = a.avgHR { body["avgHeartRate"] = h }
        if let h = a.peakHR { body["peakHeartRate"] = h }
        if let r = a.rpe { body["rpe"] = r }
        try await send("/activities/\(a.id)", "PUT", body)
    }
    func deleteActivity(id: String) async throws { try await send("/activities/\(id)", "DELETE") }
    func saveSessionBurn(workoutId: String, day: String, kcal: Int, adjustPct: Double) async throws {
        try await send("/workouts/\(workoutId)/burn", "PUT", ["day": day, "reportedKcal": kcal, "adjustPct": adjustPct])
    }
    func deleteSessionBurn(workoutId: String) async throws { try await send("/workouts/\(workoutId)/burn", "DELETE") }

    // Coach (trainer) reads
    func trainerClientMotion(clientId: String) async throws -> [APISetMotion] { try await get("/admin/clients/\(clientId)/motion") }
    func trainerClientHealth(clientId: String) async throws -> [APIWorkoutHealthRow] { try await get("/admin/clients/\(clientId)/health") }
    func trainerClientPlan(clientId: String) async throws -> APIPlanAdjustments { try await get("/admin/clients/\(clientId)/plan-adjustments") }
    func trainerClientAwards(clientId: String) async throws -> [RosterAward] { try await get("/admin/clients/\(clientId)/awards") }
}

// MARK: - The outbox

@MainActor
final class ServerSync: ObservableObject {
    static let shared = ServerSync()

    /// Items waiting to go up. Shown nowhere; exposed for debugging.
    @Published private(set) var pending: Set<String> = []

    private weak var store: AppStore?
    private let pendingKey = "bst_sync_pending"
    private var flushing = false
    private var flushTask: Task<Void, Never>?

    private init() {
        pending = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
    }

    func attach(_ store: AppStore) { self.store = store }

    private var live: Bool { store?.isLive == true && store?.isTrainer == false && store?.isLoggedIn == true }

    // MARK: Marking (called by the stores when the user changes something)

    enum Item {
        case workoutNote(workoutId: String)
        case exerciseNote(workoutId: String, exerciseId: String)
        case motion(workoutId: String)
        case day(String)                 // yyyy-MM-dd
        case activity(String)
        case burn(workoutId: String)
        case move(workoutId: String)

        var key: String {
            switch self {
            case .workoutNote(let w): return "wn|\(w)"
            case .exerciseNote(let w, let e): return "en|\(w)|\(e)"
            case .motion(let w): return "mo|\(w)"
            case .day(let d): return "day|\(d)"
            case .activity(let id): return "act|\(id)"
            case .burn(let w): return "burn|\(w)"
            case .move(let w): return "move|\(w)"
            }
        }
    }

    func mark(_ item: Item) {
        guard live else { return }          // demo / trainer / logged out: nothing to sync
        pending.insert(item.key)
        persist()
        flushSoon()
    }

    /// Send shortly (debounced, so typing a note doesn't fire a request per keystroke).
    func flushSoon(after seconds: Double = 2) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    // MARK: After every live load

    /// Called by AppStore after workouts load: restore anything missing on this phone from
    /// the server, queue a one-time upload of what's only on this phone, then send.
    func afterLoad(apiWorkouts: [APIWorkout], clientId: String) async {
        guard live else { return }
        restoreNotes(from: apiWorkouts)
        await restoreMotionIfEmpty()
        await restorePlanIfEmpty()
        bootstrapIfNeeded(clientId: clientId)
        await flush()
    }

    private func restoreNotes(from workouts: [APIWorkout]) {
        let notes = WorkoutNoteStore.shared
        for w in workouts {
            if let n = w.clientNote, !n.isEmpty, notes.note(workoutId: w.id, target: WorkoutNoteStore.general) == nil,
               !pending.contains(Item.workoutNote(workoutId: w.id).key) {
                notes.set(n, workoutId: w.id, target: WorkoutNoteStore.general, sync: false)
            }
            for e in w.exercises where !e.clientNotes.isEmpty {
                if notes.note(workoutId: w.id, target: e.id) == nil,
                   !pending.contains(Item.exerciseNote(workoutId: w.id, exerciseId: e.id).key) {
                    notes.set(e.clientNotes, workoutId: w.id, target: e.id, sync: false)
                }
            }
        }
    }

    private func restoreMotionIfEmpty() async {
        guard SetMotionStore.shared.all.isEmpty,
              let list = try? await APIClient.shared.myMotion(), !list.isEmpty else { return }
        for m in list { SetMotionStore.shared.ingest(m.toModel(), sync: false) }
    }

    private func restorePlanIfEmpty() async {
        let plan = MacroPlanStore.shared
        guard plan.isEmpty, let p = try? await APIClient.shared.planAdjustments() else { return }
        plan.restore(from: p)
    }

    /// First live launch for this account after the update: queue everything already on
    /// the phone (notes, motion, plan changes) so nothing written before v1.1 is lost.
    private func bootstrapIfNeeded(clientId: String) {
        let flag = "bst_sync_bootstrapped_\(clientId)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        for k in WorkoutNoteStore.shared.notes.keys {
            let parts = k.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            pending.insert(parts[1] == WorkoutNoteStore.general
                           ? Item.workoutNote(workoutId: parts[0]).key
                           : Item.exerciseNote(workoutId: parts[0], exerciseId: parts[1]).key)
        }
        for w in Set(SetMotionStore.shared.all.map { $0.workoutId }) { pending.insert(Item.motion(workoutId: w).key) }
        let plan = MacroPlanStore.shared
        for d in plan.dayTypes.keys { pending.insert(Item.day(d).key) }
        for a in plan.activities { pending.insert(Item.activity(a.id).key) }
        for w in plan.sessionBurns.keys { pending.insert(Item.burn(workoutId: w).key) }
        for w in plan.moves.keys { pending.insert(Item.move(workoutId: w).key) }
        persist()
        UserDefaults.standard.set(true, forKey: flag)
    }

    // MARK: Sending

    func flush() async {
        guard live, !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        // Moves first, so day changes land against the workout's new date.
        let ordered = pending.sorted { a, b in (a.hasPrefix("move|") ? 0 : 1, a) < (b.hasPrefix("move|") ? 0 : 1, b) }
        for key in ordered {
            guard live else { return }
            do {
                try await send(key)
                pending.remove(key)
            } catch let e as APIClient.HTTPStatusError where (400..<500).contains(e.status) && e.status != 401 && e.status != 408 && e.status != 429 {
                pending.remove(key)          // the server will never accept this one (gone / not allowed) — drop it
            } catch {
                break                        // offline or server trouble — keep everything, try again later
            }
            persist()
        }
        persist()
    }

    private func send(_ key: String) async throws {
        let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let api = APIClient.shared
        let plan = MacroPlanStore.shared
        switch p[0] {
        case "wn":
            try await api.saveWorkoutNote(workoutId: p[1],
                text: WorkoutNoteStore.shared.note(workoutId: p[1], target: WorkoutNoteStore.general) ?? "")
        case "en":
            try await api.saveExerciseNote(workoutId: p[1], exerciseId: p[2],
                text: WorkoutNoteStore.shared.note(workoutId: p[1], target: p[2]) ?? "")
        case "mo":
            let list = SetMotionStore.shared.motions(forWorkout: p[1])
            if !list.isEmpty {
                for chunk in stride(from: 0, to: list.count, by: 150) {
                    try await api.uploadMotion(workoutId: p[1], motions: Array(list[chunk..<min(chunk + 150, list.count)]))
                }
            }
        case "day":
            if let isTraining = plan.dayTypes[p[1]] {
                try await api.setDayType(day: p[1], isTraining: isTraining, note: plan.dayNotes[p[1]] ?? "")
            } else {
                try await api.clearDayType(day: p[1])
            }
        case "act":
            if let a = plan.activities.first(where: { $0.id == p[1] }) {
                try await api.saveActivity(a, day: plan.dayKey(a.day))
            } else {
                try await api.deleteActivity(id: p[1])
            }
        case "burn":
            if let b = plan.sessionBurns[p[1]] {
                try await api.saveSessionBurn(workoutId: p[1], day: plan.dayKey(b.day), kcal: b.reportedKcal, adjustPct: b.adjustPct)
            } else {
                try await api.deleteSessionBurn(workoutId: p[1])
            }
        case "move":
            if let m = plan.moves[p[1]] {
                try await api.moveWorkout(id: p[1], to: m.moved)
            }
        default:
            break
        }
    }

    private func persist() { UserDefaults.standard.set(Array(pending), forKey: pendingKey) }

    /// Logout: forget the outbox (the next person on this phone must never send it).
    func reset() {
        flushTask?.cancel()
        pending = []
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}
