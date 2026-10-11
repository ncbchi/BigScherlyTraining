import Foundation

// MARK: - Progress, PRs, and compliance
//
// Everything here is DERIVED from the client's actual logged sets (workouts marked
// completed, with loggedReps/loggedWeight filled in). Nothing is invented.
//
// PR celebration is deliberately throttled — the point is that a PR feels like an
// event, not a notification every time the bar goes up 1 lb. See `newPRs(...)`.

struct PersonalRecord: Identifiable, Codable, Equatable {
    var id: String
    var exercise: String
    var date: Date
    var weight: Double          // the top-set weight that earned it
    var reps: Int
    var estimatedOneRepMax: Double
    var previousBest: Double    // est. 1RM it beat (0 = first ever)

    var isFirstEver: Bool { previousBest <= 0 }
    var gain: Double { max(0, estimatedOneRepMax - previousBest) }
    var headline: String { "\(reps)×\(Int(weight)) — \(exercise)" }
}

enum ProgressEngine {

    // Epley, matching ExerciseHistorySession.estimatedOneRepMax so numbers agree everywhere.
    static func oneRepMax(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1 + Double(reps) / 30.0)
    }

    /// The lifts a PR actually matters for. Accessories move around too much for a
    /// celebration to mean anything, so they're tracked but never celebrated.
    static let mainLifts: Set<String> = [
        "Back Squat", "Front Squat", "Bench Press", "Deadlift",
        "Romanian Deadlift", "Overhead Press", "Barbell Row", "Weighted Pull-Up"
    ]
    static func isCelebratable(_ exercise: String, trainerTagged: Set<String>) -> Bool {
        mainLifts.contains(exercise) || trainerTagged.contains(exercise)
    }

    // MARK: Real history

    /// Every completed session for a lift, oldest first, built from actual logged sets.
    static func history(for exerciseName: String, workouts: [Workout]) -> [ExerciseHistorySession] {
        workouts
            .filter { $0.completed }
            .compactMap { w -> ExerciseHistorySession? in
                guard let ex = w.exercises.first(where: { $0.name == exerciseName }) else { return nil }
                // Only sets the client actually logged count as history.
                let logged: [LoggedSetRecord] = ex.sets.compactMap { s in
                    guard let r = s.loggedReps, let wt = s.loggedWeight, r > 0, wt > 0 else { return nil }
                    return LoggedSetRecord(id: s.id, reps: r, weight: wt, rpe: s.rpe)
                }
                guard !logged.isEmpty else { return nil }
                return ExerciseHistorySession(id: w.id, date: w.date, sets: logged)
            }
            .sorted { $0.date < $1.date }
    }

    /// Best est. 1RM ever hit for a lift, excluding an optional workout (used to ask
    /// "what was my best *before* this session?").
    static func bestOneRepMax(for exercise: String, workouts: [Workout],
                              excludingWorkout: String? = nil) -> Double {
        history(for: exercise, workouts: workouts)
            .filter { $0.id != excludingWorkout }
            .map { $0.estimatedOneRepMax }
            .max() ?? 0
    }

    // MARK: PR detection

    /// PRs earned by `workout`, after applying the anti-spam rules:
    ///
    ///  1. Only main lifts (or ones the trainer tagged) can be celebrated.
    ///  2. The new est. 1RM must beat the previous best by a real margin
    ///     (`minGainLb`) — no confetti for +1 lb of rounding.
    ///  3. One celebration per lift per `cooldownDays` (default 7).
    ///  4. Absurd jumps (>`sanityJump` over the old best) are treated as a typo and
    ///     skipped, so a fat-fingered "1350" doesn't crown a fake PR.
    ///  5. Only completed workouts with real logged sets qualify.
    static func newPRs(in workout: Workout,
                       allWorkouts: [Workout],
                       existing: [PersonalRecord],
                       trainerTagged: Set<String> = [],
                       minGainLb: Double = 2.5,
                       cooldownDays: Int = 7,
                       sanityJump: Double = 1.20) -> [PersonalRecord] {
        guard workout.completed else { return [] }
        let cal = Calendar.current
        var found: [PersonalRecord] = []

        for ex in workout.exercises {
            guard isCelebratable(ex.name, trainerTagged: trainerTagged) else { continue }

            // Best logged set in this session, by estimated 1RM.
            let candidates: [(w: Double, r: Int, e: Double)] = ex.sets.compactMap { s in
                guard let r = s.loggedReps, let wt = s.loggedWeight, r > 0, wt > 0 else { return nil }
                return (wt, r, oneRepMax(weight: wt, reps: r))
            }
            guard let top = candidates.max(by: { $0.e < $1.e }) else { continue }

            let prior = bestOneRepMax(for: ex.name, workouts: allWorkouts, excludingWorkout: workout.id)

            // Rule 2 — must be a meaningful improvement.
            guard top.e > prior + minGainLb else { continue }
            // Rule 4 — implausible jump = almost certainly a typo.
            if prior > 0 && top.e > prior * sanityJump { continue }
            // Rule 3 — don't celebrate the same lift twice in a week.
            if let last = existing.filter({ $0.exercise == ex.name }).map({ $0.date }).max() {
                let days = cal.dateComponents([.day], from: last, to: workout.date).day ?? 0
                if days < cooldownDays { continue }
            }

            found.append(PersonalRecord(
                id: "\(workout.id)_\(ex.name)",
                exercise: ex.name, date: workout.date,
                weight: top.w, reps: top.r,
                estimatedOneRepMax: top.e, previousBest: prior))
        }
        return found
    }

    /// All PRs across the client's history, honouring the same throttle. Used to
    /// backfill the trophy case the first time, and to keep it in sync.
    static func allPRs(workouts: [Workout], trainerTagged: Set<String> = []) -> [PersonalRecord] {
        var prs: [PersonalRecord] = []
        for w in workouts.filter({ $0.completed }).sorted(by: { $0.date < $1.date }) {
            prs.append(contentsOf: newPRs(in: w, allWorkouts: workouts,
                                          existing: prs, trainerTagged: trainerTagged))
        }
        return prs
    }

    // MARK: Logged vs target

    /// Did the client hit what was prescribed? Compares each logged set against target.
    struct Compliance {
        var setsHit: Int
        var setsTotal: Int
        var setsLogged: Int
        var rate: Double { setsTotal == 0 ? 0 : Double(setsHit) / Double(setsTotal) }
        var isComplete: Bool { setsLogged >= setsTotal }
    }

    /// A set "hits" when the client did at least the target reps at at least the
    /// target weight. Going heavier or doing more reps still counts as a hit.
    /// Back-off sets are measured against their worked-out weight (needs the exercise);
    /// RPE sets have no target weight; an AMRAP's reps target is its minimum.
    static func setHit(_ s: ExerciseSet, in ex: Exercise? = nil) -> Bool {
        guard let r = s.loggedReps, let w = s.loggedWeight else { return false }
        let goal = ex.flatMap { SetTarget.plannedWeight(s, in: $0) } ?? (s.percent == nil ? s.targetWeight : 0)
        return r >= s.targetReps && w >= goal
    }

    static func compliance(for workout: Workout) -> Compliance {
        let all = workout.exercises.flatMap { $0.sets }
        let hits = workout.exercises.reduce(0) { n, ex in n + ex.sets.filter { setHit($0, in: ex) }.count }
        return Compliance(
            setsHit: hits,
            setsTotal: all.count,
            setsLogged: all.filter { $0.loggedReps != nil && $0.loggedWeight != nil }.count)
    }

    static func compliance(for exercise: Exercise) -> Compliance {
        Compliance(
            setsHit: exercise.sets.filter { setHit($0, in: exercise) }.count,
            setsTotal: exercise.sets.count,
            setsLogged: exercise.sets.filter { $0.loggedReps != nil && $0.loggedWeight != nil }.count)
    }

    // MARK: Trend summary (for the History dashboard)

    struct LiftTrend: Identifiable {
        var id: String { exercise }
        var exercise: String
        var current: Double        // latest est. 1RM
        var best: Double
        var change: Double         // vs. first recorded session
        var sessions: Int
    }

    /// One row per lift the client has actually trained, best-progress first.
    static func trends(workouts: [Workout]) -> [LiftTrend] {
        let names = Set(workouts.filter { $0.completed }.flatMap { $0.exercises.map { $0.name } })
        return names.compactMap { name -> LiftTrend? in
            let h = history(for: name, workouts: workouts)
            guard let first = h.first, let last = h.last, h.count >= 1 else { return nil }
            return LiftTrend(exercise: name,
                             current: last.estimatedOneRepMax,
                             best: h.map { $0.estimatedOneRepMax }.max() ?? 0,
                             change: last.estimatedOneRepMax - first.estimatedOneRepMax,
                             sessions: h.count)
        }
        .sorted { $0.change > $1.change }
    }
}
