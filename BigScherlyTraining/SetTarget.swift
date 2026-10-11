import Foundation

// MARK: - Planned sets: the weight each one starts from
// Nothing new is written anywhere: every set still reads "reps × weight". What's new is the
// weight in that spot, worked out here so every screen, the Lock Screen card and the Watch agree.
//
// Kinds of set — fields on ExerciseSet, all optional, so older workouts read exactly as before:
//  • fixed weight   targetWeight > 0                       → that weight
//  • RPE            targetRpe, no weight: you pick it      → the last weight you used on this lift
//                                                            today, else last session's top set
//  • back-off       percent (−17 = 17% lighter)            → the heaviest set logged in this exercise
//                                                            less the %, on the plate step; "—" until
//                                                            one's logged (the empty weight box shows
//                                                            the % faded)
//  • AMRAP          amrap; targetReps = the minimum (0 = none: reps "—" until you've done it)
//  • bodyweight     no weight, no RPE, no %                → "BW"
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

enum SetTarget {

    // MARK: Weight step (Settings ▸ Weight steps)

    /// Small (2.5 lb / 1.25 kg) or standard (5 lb / 2.5 kg), in display units.
    static var displayStep: Double {
        let small = UserDefaults.standard.string(forKey: "bst_weight_step") == "small"
        return StatsUnits.isKg ? (small ? 1.25 : 2.5) : (small ? 2.5 : 5)
    }

    /// A weight in lb, rounded to the plate step in your units (so kg never shows 77.11).
    static func roundToStep(_ lb: Double) -> Double {
        let step = displayStep
        let shown = (StatsUnits.weight(lb) / step).rounded() * step
        return StatsUnits.isKg ? shown / 0.45359237 : shown
    }

    // MARK: Kinds

    static func isBackoff(_ s: ExerciseSet) -> Bool { s.percent != nil }
    static func isAmrap(_ s: ExerciseSet) -> Bool { s.amrap == true }
    /// You pick the weight: an RPE set with no weight on it.
    static func picksWeight(_ s: ExerciseSet) -> Bool { s.percent == nil && s.targetWeight <= 0 && s.targetRpe != nil }
    static func isBodyweight(_ s: ExerciseSet) -> Bool { s.percent == nil && s.targetWeight <= 0 && s.targetRpe == nil }
    /// A plain fixed-weight set (the plan's weight steps between these carry over).
    static func isFixed(_ s: ExerciseSet) -> Bool { s.percent == nil && s.targetWeight > 0 }

    // MARK: Weights (lb)

    /// What a back-off is taken from: the heaviest set logged so far in this exercise
    /// (back-off sets themselves don't count). Nil until one is logged.
    static func topLogged(_ ex: Exercise) -> Double? {
        ex.sets.filter { $0.percent == nil && $0.loggedReps != nil }
            .compactMap { $0.loggedWeight }.filter { $0 > 0 }.max()
    }

    /// The planned weight: fixed → its weight; back-off → the heaviest logged set less the %,
    /// on the plate step (nil until a set is logged); RPE and bodyweight → nil.
    static func plannedWeight(_ s: ExerciseSet, in ex: Exercise) -> Double? {
        if let p = s.percent {
            guard let top = topLogged(ex) else { return nil }
            return roundToStep(top * (1 + p / 100))
        }
        return s.targetWeight > 0 ? s.targetWeight : nil
    }

    /// Where the weight starts for a set that isn't a plain fixed one:
    ///  • back-off → its planned weight (nil until a heavier set is logged);
    ///  • RPE (you pick) → the last weight you used on this lift today, else the heaviest set from the
    ///    last time you logged this lift (finished workout or not);
    ///  • bodyweight → 0.
    /// Fixed sets carry the last set's weight plus the plan's step (the callers do that).
    static func startWeight(_ s: ExerciseSet, in ex: Exercise, workoutId: String? = nil,
                            workouts: [Workout]? = nil) -> Double? {
        if isBackoff(s) { return plannedWeight(s, in: ex) }
        if picksWeight(s) {
            if let w = ex.sets.last(where: { $0.loggedReps != nil && ($0.loggedWeight ?? 0) > 0 })?.loggedWeight { return w }
            // The most recent other workout where this lift has a logged weight (not just finished ones).
            let name = ex.name.trimmingCharacters(in: .whitespaces).lowercased()
            let past = (workouts ?? AppStore.shared.workouts)
                .filter { $0.id != workoutId }
                .sorted { $0.date > $1.date }
            for w in past {
                let logged = w.exercises
                    .filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }
                    .flatMap { $0.sets }
                    .filter { $0.loggedReps != nil }
                    .compactMap { $0.loggedWeight }.filter { $0 > 0 }
                if let top = logged.max() { return top }
            }
            return nil
        }
        if isBodyweight(s) { return 0 }
        return s.targetWeight
    }

    /// The weight that goes in a set's weight spot before it's logged (nil = not known yet).
    static func shownWeight(_ s: ExerciseSet, in ex: Exercise) -> Double? {
        if let w = plannedWeight(s, in: ex) { return w }
        if picksWeight(s) { return startWeight(s, in: ex, workoutId: currentWorkoutId(ex)).map(roundToStep) }
        return nil
    }

    /// The workout this exercise belongs to (so its own sets aren't treated as "last time").
    private static func currentWorkoutId(_ ex: Exercise) -> String? {
        AppStore.shared.workouts.first { w in w.exercises.contains { $0.id == ex.id } }?.id
    }

    // MARK: The spots: "reps × weight", as always

    /// A weight in your units, to the plate (172.5, 76.25 — never rounded to a whole number).
    static func weightText(_ lb: Double, unit: Bool = true) -> String {
        let v = (StatsUnits.weight(lb) * 100).rounded() / 100
        var n = String(format: "%.2f", v)
        while n.hasSuffix("0") { n.removeLast() }
        if n.hasSuffix(".") { n.removeLast() }
        return unit ? "\(n) \(StatsUnits.weightLabel)" : n
    }

    /// A back-off's %, only for the faded text in its empty weight box: "−17%".
    static func percentText(_ p: Double) -> String {
        let n = abs(p) == abs(p).rounded() ? String(Int(abs(p))) : String(format: "%.1f", abs(p))
        return (p < 0 ? "−" : "+") + n + "%"
    }

    /// The reps spot: the plan's reps (an AMRAP's minimum), or "—" for an AMRAP with none.
    static func repsText(_ s: ExerciseSet) -> String {
        isAmrap(s) && s.targetReps <= 0 ? "—" : "\(s.targetReps)"
    }

    /// The weight spot: the weight, "BW", or "—" (a back-off before anything's logged).
    static func weightSpot(_ s: ExerciseSet, in ex: Exercise, unit: Bool = true) -> String {
        if isBodyweight(s) { return "BW" }
        return shownWeight(s, in: ex).map { weightText($0, unit: unit) } ?? "—"
    }

    /// "5 × 275 lb", "3 × 170 lb", "3 × —", "5 × BW".
    static func text(_ s: ExerciseSet, in ex: Exercise, unit: Bool = true) -> String {
        "\(repsText(s)) × \(weightSpot(s, in: ex, unit: unit))"
    }

    /// The Lock Screen card's and the Watch's rows: "5 × 275", "3 × —", "5 × BW".
    static func short(_ s: ExerciseSet, in ex: Exercise) -> String { text(s, in: ex, unit: false) }

    /// The exercise in one line, as before: sets × the first set's reps, and its weight.
    static func summaryParts(_ ex: Exercise) -> (sets: String, weight: String) {
        guard let first = ex.sets.first else { return ("", "") }
        return ("\(ex.sets.count) × \(repsText(first))", weightSpot(first, in: ex))
    }

    /// "3 × 5 · 275 lb".
    static func summary(_ ex: Exercise) -> String {
        let p = summaryParts(ex)
        return "\(p.sets) · \(p.weight)"
    }

    /// "Rep 3 of 5" while lifting; an AMRAP with no minimum just counts: "Rep 3".
    static func repProgress(_ count: Int, _ s: ExerciseSet?) -> String {
        if let s, isAmrap(s), s.targetReps <= 0 { return "Rep \(count)" }
        return "Rep \(count) of \(max(s?.targetReps ?? count, 1))"
    }
}
