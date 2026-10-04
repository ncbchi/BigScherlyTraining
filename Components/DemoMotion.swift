import Foundation

// MARK: - Demo motion + heart rate
// Believable, stable sample data for demo mode (App Review) so Stats is fully
// populated without a Watch. Deterministic: the same set always gets the same
// numbers, so charts don't reshuffle between redraws. Never used for real users.

@MainActor
enum DemoMotion {
    private static var cache: [String: SetMotion?] = [:]
    private static var oneRM: [String: Double] = [:]

    /// Stable 0..<1 value from a string (FNV-1a), unlike hashValue which changes per launch.
    static func unit(_ s: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Double(h % 10_000) / 10_000
    }

    private struct Profile { var vmax: Double; var mvt: Double; var travel: Double; var ecc: Double; var pause: ClosedRange<Double>? }

    private static func profile(_ name: String) -> Profile? {
        let n = name.lowercased()
        switch SBDLift.classify(name) {
        case .squat: return Profile(vmax: 1.40, mvt: 0.30, travel: 0.56, ecc: 1.6, pause: nil)
        case .bench: return Profile(vmax: 1.20, mvt: 0.17, travel: 0.42, ecc: 1.3, pause: 0.55...1.05)
        case .deadlift: return Profile(vmax: 1.10, mvt: 0.15, travel: 0.58, ecc: 1.0, pause: 0.6...1.3)
        case nil: break
        }
        if n.contains("front squat") { return Profile(vmax: 1.35, mvt: 0.32, travel: 0.52, ecc: 1.5, pause: nil) }
        if n.contains("romanian") { return Profile(vmax: 1.10, mvt: 0.25, travel: 0.45, ecc: 1.8, pause: nil) }
        if n.contains("overhead press") { return Profile(vmax: 1.20, mvt: 0.19, travel: 0.50, ecc: 1.2, pause: nil) }
        if n.contains("row") { return Profile(vmax: 1.10, mvt: 0.40, travel: 0.35, ecc: 1.0, pause: nil) }
        return nil   // machines, cables, dumbbells: no wrist-on-bar data in the demo
    }

    static func motion(workoutId: String, exercise: Exercise, set: ExerciseSet,
                       setIndex: Int, workouts: [Workout]) -> SetMotion? {
        let key = "\(workoutId)|\(exercise.id)|\(set.id)"
        if let c = cache[key] { return c }
        let result = build(key: key, workoutId: workoutId, exercise: exercise, set: set,
                           setIndex: setIndex, workouts: workouts)
        cache[key] = result
        return result
    }

    private static func build(key: String, workoutId: String, exercise: Exercise, set: ExerciseSet,
                              setIndex: Int, workouts: [Workout]) -> SetMotion? {
        guard let p = profile(exercise.name), let reps = set.loggedReps, reps > 0,
              let load = set.loggedWeight, load > 0,
              let w = workouts.first(where: { $0.id == workoutId }) else { return nil }

        // 1RM ≈ 1.2 × heaviest logged load for this lift.
        if oneRM[exercise.name] == nil {
            let maxLoad = workouts.flatMap { $0.exercises.filter { $0.name == exercise.name }.flatMap { $0.sets } }
                .compactMap { $0.loggedWeight }.max() ?? load
            oneRM[exercise.name] = maxLoad * 1.2
        }
        let rel = min(0.97, load / (oneRM[exercise.name] ?? load * 1.2))
        let dayForm = 1 + (unit(workoutId + "form") - 0.5) * 0.08          // ±4% day to day
        let v0 = max(p.mvt + 0.05, (p.vmax - (p.vmax - p.mvt) * rel) * dayForm)

        // Speed loss tracks effort; roughly one set in eleven doesn't match its RPE.
        var loss: Double
        switch set.rpe ?? 8 {
        case ..<7.75: loss = 0.12
        case ..<8.75: loss = 0.20
        case ..<9.75: loss = 0.28
        default: loss = 0.37
        }
        let odd = unit(key + "odd")
        if odd < 0.09 { loss = (set.rpe ?? 8) >= 8 ? 0.06 : 0.36 }
        if reps < 3 { loss *= 0.5 }

        let exIndex = Double(w.exercises.firstIndex(where: { $0.id == exercise.id }) ?? 0)
        let base = (Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: w.date) ?? w.date)
            .addingTimeInterval(exIndex * 900 + Double(setIndex) * 200)
        let isDeadlift = SBDLift.classify(exercise.name) == .deadlift
        let shallowSet = unit(key + "shallow") < 0.06

        var t = base
        var out: [RepMotion] = []
        for i in 0..<reps {
            let frac = reps > 1 ? Double(i) / Double(reps - 1) : 0
            let jitter = 1 + (unit(key + "v\(i)") - 0.5) * 0.04
            let mean = max(p.mvt * 0.8, v0 * (1 - loss * pow(frac, 1.3)) * jitter)
            var travel = p.travel * (1 + (unit(key + "d\(i)") - 0.5) * 0.05)
            if shallowSet && i >= reps - 2 { travel *= 0.86 }
            let con = travel / mean
            let ecc: Double? = (isDeadlift && i == 0) ? nil : p.ecc * (1 + (unit(key + "e\(i)") - 0.5) * 0.15)
            let bottom: Double? = {
                if isDeadlift && i == 0 { return nil }
                if let r = p.pause { return r.lowerBound + (r.upperBound - r.lowerBound) * unit(key + "p\(i)") }
                return 0.03 + 0.06 * unit(key + "p\(i)")
            }()
            let top: Double? = i < reps - 1 ? 0.6 + unit(key + "t\(i)") * 0.8 : nil
            let sticking: Double? = mean < p.mvt + 0.12 ? 0.35 + unit(key + "s\(i)") * 0.2 : nil
            let start = t
            let end = start.addingTimeInterval((ecc ?? 0) + (bottom ?? 0) + con)
            out.append(RepMotion(index: i + 1, start: start, end: end,
                                 eccentricSec: ecc, bottomPauseSec: bottom, concentricSec: con,
                                 topPauseSec: top, travelM: travel, meanVelocity: mean,
                                 peakVelocity: mean * (1.5 + unit(key + "pk\(i)") * 0.2),
                                 stickingPoint: sticking,
                                 driftM: 0.012 + unit(key + "dr\(i)") * 0.02))
            t = end.addingTimeInterval(top ?? 0)
        }
        return SetMotion(id: key, workoutId: workoutId, exerciseId: exercise.id, setId: set.id,
                         exerciseName: exercise.name, start: base, end: t, reps: out,
                         autoDetected: true, analyzerVersion: 0)
    }

    // MARK: Heart rate + session

    /// Compound lifts run hotter; older sessions a little hotter (conditioning improves).
    static func heartRate(workoutId: String, exerciseName: String, date: Date) -> (avg: Int, peak: Int) {
        let n = exerciseName.lowercased()
        let heavy = ["squat", "deadlift", "bench", "press", "row", "clean"].contains { n.contains($0) }
        let daysAgo = max(0, Date().timeIntervalSince(date) / 86400)
        let drift = min(8, daysAgo / 240 * 8)
        let wobble = (unit(workoutId + exerciseName) - 0.5) * 6
        let avg = (heavy ? 140.0 : 122.0) + drift + wobble
        let peak = (heavy ? 166.0 : 144.0) + drift + wobble
        return (avg: Int(avg), peak: Int(peak))
    }

    static func session(workoutId: String) -> (minutes: Int, calories: Int) {
        let u = unit(workoutId + "session")
        return (minutes: 55 + Int(u * 22), calories: 340 + Int(u * 190))
    }
}
