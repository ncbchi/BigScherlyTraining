import Foundation
import Combine

// MARK: - The client's adjustments to their macro plan
// The coach sets each day's targets. The client may:
//   • move a training day to another day in the SAME Monday–Sunday week (the
//     workout moves with it), never across weeks;
//   • log an extra activity, which can make that day a training day;
//   • choose to add calories burned (activity or lifting session) to the day's target,
//     fine-tuned ±20% because Watch calorie estimates aren't exact.
// Saved on this device and synced to the server (ServerSync). Cleared on logout.

struct ExtraActivity: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var day: Date                   // start of day
    var start: Date?
    var type: String                // "Run", "Walk", "Cycling"…
    var minutes: Int
    var reportedKcal: Int?          // as reported by the Watch / Health (or typed)
    var adjustPct: Double = 0       // −0.20…+0.20
    var addToTarget = false
    var countsAsTraining = true
    var fromHealth = false
    var healthId: String? = nil
    var avgHR: Int? = nil
    var peakHR: Int? = nil
    var rpe: Int? = nil

    var adjustedKcal: Int? { reportedKcal.map { Int((Double($0) * (1 + adjustPct)).rounded()) } }
}

/// Calories from a lifting session the client chose to add to that day's target.
struct SessionBurn: Codable, Equatable {
    var reportedKcal: Int
    var adjustPct: Double
    var day: Date
    var adjustedKcal: Int { Int((Double(reportedKcal) * (1 + adjustPct)).rounded()) }
}

struct WorkoutMove: Codable, Equatable {
    var original: Date
    var moved: Date
}

/// What a day actually comes out to after the client's adjustments.
struct EffectiveTargets: Equatable {
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var isTraining: Bool
    var reason: String?             // "moved from Wed", "from your 34-min run"
    var addedKcal: Int              // burned calories added on top
}

@MainActor
final class MacroPlanStore: ObservableObject {
    static let shared = MacroPlanStore()

    @Published private(set) var dayTypes: [String: Bool] = [:]          // dayKey → training?
    @Published private(set) var dayNotes: [String: String] = [:]        // dayKey → why
    @Published private(set) var moves: [String: WorkoutMove] = [:]      // workoutId → move
    @Published private(set) var activities: [ExtraActivity] = []
    @Published private(set) var sessionBurns: [String: SessionBurn] = [:] // workoutId → burn

    private let key = "bst_macro_plan"
    private let cal = Calendar.training

    private struct Saved: Codable {
        var dayTypes: [String: Bool]; var dayNotes: [String: String]
        var moves: [String: WorkoutMove]; var activities: [ExtraActivity]
        var sessionBurns: [String: SessionBurn]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            dayTypes = s.dayTypes; dayNotes = s.dayNotes; moves = s.moves
            activities = s.activities; sessionBurns = s.sessionBurns
        }
    }

    func dayKey(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Reading

    func activities(on day: Date) -> [ExtraActivity] {
        activities.filter { cal.isDate($0.day, inSameDayAs: day) }
    }

    /// Training or rest after the client's changes.
    func isTraining(_ macro: MacroDay) -> Bool {
        if activities(on: macro.date).contains(where: { $0.countsAsTraining }) { return true }
        return dayTypes[dayKey(macro.date)] ?? macro.isTrainingDay
    }

    /// Training per the plan + any moved days (ignores extra activities).
    func plannedTraining(_ macro: MacroDay) -> Bool {
        dayTypes[dayKey(macro.date)] ?? macro.isTrainingDay
    }

    /// The typical targets the coach set for a kind of day (most common in the plan).
    func typical(training: Bool, in plan: [MacroDay]) -> MacroDay? {
        let set = plan.filter { $0.isTrainingDay == training }
        let groups = Dictionary(grouping: set, by: { "\($0.calorieGoal)-\($0.proteinGoal)-\($0.carbGoal)-\($0.fatGoal)" })
        return groups.max { $0.value.count < $1.value.count }?.value.first
    }

    func targets(for day: MacroDay, plan: [MacroDay], workouts: [Workout]) -> EffectiveTargets {
        let training = isTraining(day)
        // If the type changed, use the coach's usual targets for that kind of day.
        let base: MacroDay = training == day.isTrainingDay ? day : (typical(training: training, in: plan) ?? day)
        var added = 0
        for a in activities(on: day.date) where a.addToTarget { added += a.adjustedKcal ?? 0 }
        for (wid, burn) in sessionBurns where cal.isDate(burn.day, inSameDayAs: day.date) {
            if workouts.contains(where: { $0.id == wid }) { added += burn.adjustedKcal }
        }
        var reason: String? = dayNotes[dayKey(day.date)]
        if let a = activities(on: day.date).first(where: { $0.countsAsTraining }), !day.isTrainingDay {
            reason = "from your \(a.minutes)-min \(a.type.lowercased())"
        }
        return EffectiveTargets(calories: base.calorieGoal + added, protein: base.proteinGoal,
                                carbs: base.carbGoal + added / 4, fat: base.fatGoal,
                                isTraining: training, reason: reason, addedKcal: added)
    }

    // MARK: Moving a training day (same week only)

    enum MoveError: Error { case differentWeek, inPast, completed }

    /// Move the training day `from` → `to` (same Monday–Sunday week). The workout on
    /// `from` (if any, not yet done) moves to `to`, keeping its time of day.
    func moveTrainingDay(from: Date, to: Date, store: AppStore) throws {
        guard cal.isSameTrainingWeek(from, to) else { throw MoveError.differentWeek }
        let today = cal.startOfDay(for: Date())
        guard cal.startOfDay(for: from) >= today, cal.startOfDay(for: to) >= today else { throw MoveError.inPast }
        var movedId: String? = nil
        if let i = store.workouts.firstIndex(where: { !$0.completed && cal.isDate($0.date, inSameDayAs: from) }) {
            let w = store.workouts[i]
            movedId = w.id
            let tod = cal.dateComponents([.hour, .minute], from: w.date)
            let newDate = cal.date(bySettingHour: tod.hour ?? 9, minute: tod.minute ?? 0, second: 0, of: to) ?? to
            let original = moves[w.id]?.original ?? w.date
            moves[w.id] = WorkoutMove(original: original, moved: newDate)
            store.workouts[i].date = newDate
        }
        let fromLabel = from.formatted(.dateTime.weekday(.abbreviated))
        let toLabel = to.formatted(.dateTime.weekday(.abbreviated))
        dayTypes[dayKey(from)] = false
        dayTypes[dayKey(to)] = true
        dayNotes[dayKey(to)] = "moved from \(fromLabel)"
        dayNotes[dayKey(from)] = "moved to \(toLabel)"
        save()
        store.sendActiveWorkoutToWatch()
        if let wid = movedId { ServerSync.shared.mark(.move(workoutId: wid)) }
        ServerSync.shared.mark(.day(dayKey(from)))
        ServerSync.shared.mark(.day(dayKey(to)))
    }

    /// Re-apply the client's moves after workouts reload from the server — unless the
    /// coach has since rescheduled that workout themselves.
    func applyMoves(to workouts: [Workout]) -> [Workout] {
        var out = workouts
        for i in out.indices {
            if let m = moves[out[i].id], !out[i].completed, abs(out[i].date.timeIntervalSince(m.original)) < 60 {
                out[i].date = m.moved
            }
        }
        return out
    }

    // MARK: Activities + burned calories

    func addActivity(_ a: ExtraActivity) {
        activities.removeAll { $0.id == a.id }
        activities.append(a)
        save()
        ServerSync.shared.mark(.activity(a.id))
    }

    func removeActivity(_ id: String) {
        activities.removeAll { $0.id == id }
        save()
        ServerSync.shared.mark(.activity(id))
    }

    func setSessionBurn(workoutId: String, _ burn: SessionBurn?) {
        sessionBurns[workoutId] = burn
        save()
        ServerSync.shared.mark(.burn(workoutId: workoutId))
    }

    // MARK: Server restore (new phone)

    var isEmpty: Bool { dayTypes.isEmpty && moves.isEmpty && activities.isEmpty && sessionBurns.isEmpty }

    /// Fill from the server without queuing anything back up.
    func restore(from p: APIPlanAdjustments) {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        func day(_ s: String) -> Date { f.date(from: s).map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date()) }
        for d in p.days {
            dayTypes[d.day] = d.isTraining
            if let n = d.note, !n.isEmpty { dayNotes[d.day] = n }
        }
        for a in p.activities where !activities.contains(where: { $0.id == a.id }) {
            activities.append(ExtraActivity(id: a.id, day: day(a.day), start: a.start, type: a.type, minutes: a.minutes,
                                            reportedKcal: a.reportedKcal, adjustPct: a.adjustPct, addToTarget: a.addToTarget,
                                            countsAsTraining: a.countsAsTraining, fromHealth: a.fromHealth, healthId: a.healthId,
                                            avgHR: a.avgHeartRate, peakHR: a.peakHeartRate, rpe: a.rpe))
        }
        for b in p.burns { sessionBurns[b.workoutId] = SessionBurn(reportedKcal: b.reportedKcal, adjustPct: b.adjustPct, day: day(b.day)) }
        for m in p.moves { moves[m.workoutId] = WorkoutMove(original: m.originalDate, moved: m.scheduledDate) }
        save()
    }

    func reset() {
        dayTypes = [:]; dayNotes = [:]; moves = [:]; activities = []; sessionBurns = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        let s = Saved(dayTypes: dayTypes, dayNotes: dayNotes, moves: moves,
                      activities: activities, sessionBurns: sessionBurns)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}
