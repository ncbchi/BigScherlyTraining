import SwiftUI

// MARK: - Coach HQ on iPad: Live demo (Oct 10, 2026)
//
// Two made-up clients mid-session, so the Live screen can be seen without a phone or Bluetooth.
// Live ▸ "See it with demo data". Everything a phone would send is simulated once a second: the
// set loop (ready → lifting, a rep every few seconds → the Watch sees the set end → logged → rest),
// each rep's bar speed (slowing through the set), heart rate rising and falling, the plan filling in.
// The coach pad drives it: Start / End / Log set, rest presets, +30 s, Skip rest. Nothing is saved or
// sent anywhere. Closing Live ends the demo. Synchronized folder: no target step needed.

@MainActor
final class PadLiveDemo {
    static let shared = PadLiveDemo()
    static let prefix = "demo-"
    private static let restSeconds = 45           // shortened so a full loop is quick to watch
    private static let maxHR = 190.0

    /// Their "usual" bar speed per lift (the dashed line), and best e1RM before today (Alex's squat is
    /// set up so today's 5 × 225 shows the PR alert).
    static func usual(_ exercise: String) -> Double? { usualSpeeds[exercise] }
    static func best(_ exercise: String) -> Double? { bests[exercise] }
    private static let usualSpeeds: [String: Double] = [
        "Back Squat": 0.58, "Romanian Deadlift": 0.52, "Walking Lunge": 0.70,
        "Bench Press": 0.50, "Barbell Row": 0.62, "Overhead Press": 0.55]
    private static let bests: [String: Double] = [
        "Back Squat": 255, "Romanian Deadlift": 240, "Bench Press": 190, "Barbell Row": 180, "Overhead Press": 120]

    final class Sim {
        let id: UUID
        let clientId: String
        let name: String
        var workout: Workout
        let openedAt: Date
        var stage: LiveStage = .ready
        var exIndex = 0
        var setIndex = 0
        var setStart: Date?
        var restStart: Date?
        var restEnd: Date?
        var logNeeded = false
        var reps: [RepMotion] = []
        var nextRepAt: Date?
        var lastRepAt: Date?
        var autoLogAt: Date?
        var autoStartAt: Date?
        var lastSpeeds: [Double] = []
        var lastLabel: String?
        var lastSet: LiveLastSet?          // the last set's reps (the Coach notes window)
        var hr: Double = 110

        init(id: UUID, clientId: String, name: String, workout: Workout, openedAt: Date) {
            self.id = id; self.clientId = clientId; self.name = name; self.workout = workout; self.openedAt = openedAt
        }
    }

    private var sims: [UUID: Sim] = [:]
    private var loop: Task<Void, Never>?

    private let alexId = UUID(uuidString: "D3A00000-0000-4000-8000-000000000001")!
    private let jordanId = UUID(uuidString: "D3A00000-0000-4000-8000-000000000002")!

    // MARK: Start / stop

    func start() {
        let link = PadLiveLink.shared
        let now = Date()
        if sims[alexId] == nil {
            let a = makeAlex(now)
            sims[a.id] = a
            link.demoAdd(a.id, hello: hello(a), workout: LiveWorkoutSnap(a.workout), hr: seedHR(now, base: 118), finished: seedFinished(a, now))
        }
        if sims[jordanId] == nil {
            let j = makeJordan(now)
            sims[j.id] = j
            link.demoAdd(j.id, hello: hello(j), workout: LiveWorkoutSnap(j.workout), hr: seedHR(now, base: 112), finished: seedFinished(j, now))
        }
        link.selected = alexId
        tickAll()
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    guard let self, !self.sims.isEmpty else { return }
                    self.tickAll()
                }
            }
        }
    }

    func remove(_ id: UUID) {
        sims[id] = nil
        if sims.isEmpty { loop?.cancel(); loop = nil }
    }

    /// Next set changed on the iPad: the plan changes here instead of on the server.
    func edit(_ id: UUID, _ change: (inout Workout) -> Void) {
        guard let s = sims[id] else { return }
        let curId: String? = currentSet(s)?.id
        change(&s.workout)
        for ei in s.workout.exercises.indices {
            for si in s.workout.exercises[ei].sets.indices where s.workout.exercises[ei].sets[si].id.isEmpty {
                s.workout.exercises[ei].sets[si].id = "demo-new-" + String(UUID().uuidString.prefix(8))
            }
        }
        // Stay on the same set; if it went, the first one not logged.
        var found = false
        if let curId {
            for (ei, e) in s.workout.exercises.enumerated() {
                if let si = e.sets.firstIndex(where: { $0.id == curId }) { s.exIndex = ei; s.setIndex = si; found = true }
            }
        }
        if !found {
            for (ei, e) in s.workout.exercises.enumerated() {
                if let si = e.sets.firstIndex(where: { $0.loggedReps == nil }) { s.exIndex = ei; s.setIndex = si; found = true; break }
            }
        }
        push(s, Date(), sendPlan: true)
    }

    /// The weight a set is lifted at: its own, or a back-off from the heaviest set logged in the exercise.
    private func weight(_ ex: Exercise, _ st: ExerciseSet) -> Double {
        guard let pct = st.percent else { return st.targetWeight }
        let top: Double = ex.sets.compactMap { $0.loggedWeight }.max() ?? 0
        return (top * (1 + pct / 100) / 5).rounded() * 5
    }

    /// Live closed: the demo goes with it.
    func stopAll() {
        for id in Array(sims.keys) { PadLiveLink.shared.unfollow(id) }
        sims = [:]
        loop?.cancel(); loop = nil
    }

    // MARK: The coach pad

    func run(_ cmd: LiveCommand, _ id: UUID) {
        guard let s = sims[id] else { return }
        let now = Date()
        switch cmd.t {
        case "startSet":
            if s.logNeeded { log(s, now) }
            if s.stage != .done { startSet(s, now) }
        case "endSet":
            if s.stage == .lifting, !s.logNeeded { setEnded(s, now) }
        case "logSet":
            if s.logNeeded { log(s, now) }
        case "rest":
            guard !s.logNeeded, s.stage != .done else { break }
            rest(s, seconds: cmd.seconds ?? Self.restSeconds, now)
        case "addRest":
            if s.stage == .resting, let e = s.restEnd { s.restEnd = max(e, now).addingTimeInterval(TimeInterval(cmd.seconds ?? 30)) }
        case "skipRest":
            if s.stage == .resting { ready(s, now) }
        default:
            break                                   // cue / reload: nothing to simulate (the toast says it was sent)
        }
        push(s, now, sendPlan: false)
    }

    // MARK: The loop

    private func tickAll() {
        let now = Date()
        for s in sims.values { tick(s, now) }
    }

    private func tick(_ s: Sim, _ now: Date) {
        switch s.stage {
        case .ready:
            if let t = s.autoStartAt, t <= now { startSet(s, now) }
        case .lifting:
            let target: Int = currentSet(s)?.targetReps ?? 5
            if !s.logNeeded, s.reps.count < target, let t = s.nextRepAt, t <= now {
                addRep(s, now)
                s.nextRepAt = now.addingTimeInterval(Double.random(in: 2.4...3.2))
            }
            if !s.logNeeded, s.reps.count >= target, let l = s.lastRepAt, now.timeIntervalSince(l) >= 3 { setEnded(s, now) }
            if s.logNeeded, let t = s.autoLogAt, t <= now { log(s, now) }
        case .resting:
            if let e = s.restEnd, e <= now { ready(s, now) }
        case .done:
            break
        }
        // Heart rate drifts toward where this part of the set loop puts it.
        let goal: Double
        switch s.stage {
        case .lifting: goal = s.logNeeded ? 142 : 150 + Double(s.setIndex) * 3
        case .resting: goal = 106
        case .ready: goal = 112
        case .done: goal = 98
        }
        s.hr += (goal - s.hr) * 0.12 + Double.random(in: -1.5...1.5)
        push(s, now, sendPlan: false)
    }

    private func startSet(_ s: Sim, _ now: Date) {
        s.stage = .lifting
        s.setStart = now
        s.restStart = nil; s.restEnd = nil
        s.reps = []
        s.logNeeded = false
        s.autoStartAt = nil
        s.nextRepAt = now.addingTimeInterval(2.5)
        s.lastRepAt = nil
    }

    /// The Watch saw the bar stop: waiting to be logged (the client logs it a few seconds later).
    private func setEnded(_ s: Sim, _ now: Date) {
        s.logNeeded = true
        s.autoLogAt = now.addingTimeInterval(6)
    }

    private func rest(_ s: Sim, seconds: Int, _ now: Date) {
        s.stage = .resting
        s.setStart = nil
        s.restStart = now
        s.restEnd = now.addingTimeInterval(TimeInterval(max(10, seconds)))
    }

    private func ready(_ s: Sim, _ now: Date) {
        s.stage = .ready
        s.restStart = nil; s.restEnd = nil
        s.autoStartAt = now.addingTimeInterval(8)
    }

    private func addRep(_ s: Sim, _ now: Date) {
        guard let ex = currentExercise(s) else { return }
        let base: Double = (Self.usualSpeeds[ex.name] ?? 0.55) * (1.05 - 0.025 * Double(s.setIndex))
        let k: Int = s.reps.count
        var v: Double = base * (1 - 0.04 * Double(k)) + Double.random(in: -0.015...0.015)
        let lastSet: Bool = s.setIndex == ex.sets.count - 1
        let lastRep: Bool = k == (currentSet(s)?.targetReps ?? 5) - 1
        if lastSet && lastRep { v -= 0.08 }                     // the final rep of the final set grinds a little
        v = max(0.15, v)
        let travel: Double = 0.55
        let con: Double = travel / v
        let start: Date = now.addingTimeInterval(-(con + 1.7))
        s.reps.append(RepMotion(index: k + 1, start: start, end: now, eccentricSec: Double.random(in: 1.4...1.9),
                                bottomPauseSec: Double.random(in: 0.05...0.2), concentricSec: con,
                                topPauseSec: 0.6, travelM: travel, meanVelocity: v, peakVelocity: v * 1.6,
                                stickingPoint: 0.4, driftM: 0.02))
        s.lastRepAt = now
    }

    /// The set goes into the plan, its reps become "last set", and rest starts (or the session's done).
    private func log(_ s: Sim, _ now: Date) {
        guard s.exIndex < s.workout.exercises.count, s.setIndex < s.workout.exercises[s.exIndex].sets.count else { return }
        let ex = s.workout.exercises[s.exIndex]
        let st = ex.sets[s.setIndex]
        let speeds: [Double] = s.reps.map { $0.meanVelocity }
        s.workout.exercises[s.exIndex].sets[s.setIndex].loggedReps = s.reps.isEmpty ? st.targetReps : s.reps.count
        s.workout.exercises[s.exIndex].sets[s.setIndex].loggedWeight = weight(ex, st)
        s.workout.exercises[s.exIndex].sets[s.setIndex].rpe = min(9.5, 7.5 + 0.5 * Double(s.setIndex))
        s.workout.exercises[s.exIndex].sets[s.setIndex].loggedAt = now
        if !speeds.isEmpty {
            s.lastSet = LiveLastSet(exerciseId: ex.id, setId: st.id, setNumber: s.setIndex + 1, reps: s.reps)
            s.lastSpeeds = speeds
            s.lastLabel = "\(ex.name) · Set \(s.setIndex + 1)"
        }
        s.logNeeded = false
        s.autoLogAt = nil
        s.reps = []
        s.setStart = nil
        if s.setIndex + 1 < ex.sets.count {
            s.setIndex += 1
        } else if s.exIndex + 1 < s.workout.exercises.count {
            s.exIndex += 1
            s.setIndex = 0
        } else {
            s.stage = .done
            s.workout.completed = true
            push(s, now, sendPlan: true)
            return
        }
        rest(s, seconds: Self.restSeconds, now)
        push(s, now, sendPlan: true)
    }

    // MARK: What the "phone" sends

    private func push(_ s: Sim, _ now: Date, sendPlan: Bool) {
        let msg = LiveStateMsg(at: now, card: card(s, now), liveReps: s.reps, hr: Int(s.hr.rounded()),
                               watchLive: true, elapsedSince: s.openedAt, lastSet: s.lastSet)
        PadLiveLink.shared.demoUpdate(s.id, workout: sendPlan ? LiveWorkoutSnap(s.workout) : nil, state: msg)
    }

    private func card(_ s: Sim, _ now: Date) -> WorkoutActivityAttributes.ContentState {
        var c = WorkoutActivityAttributes.ContentState(startedAt: s.openedAt)
        let exs = s.workout.exercises
        let ex: Exercise? = exs.isEmpty ? nil : exs[min(s.exIndex, exs.count - 1)]
        c.stage = s.stage
        if let ex {
            let st = ex.sets[min(s.setIndex, ex.sets.count - 1)]
            c.exercise = ex.name
            c.setNumber = min(s.setIndex + 1, ex.sets.count)
            c.setCount = ex.sets.count
            c.goalReps = st.targetReps
            let lb: Double = weight(ex, st)
            let reps: String = st.amrap == true ? "\(st.targetReps)+" : "\(st.targetReps)"
            c.goalWeight = lb
            c.unit = "lb"
            c.editSet = c.setNumber                                    // the Log set tile: the set just done
            c.dReps = s.reps.isEmpty ? st.targetReps : s.reps.count
            c.dWeight = lb
            c.doneByWatch = s.logNeeded ? true : nil
            c.goalText = lb > 0 ? "\(reps) × \(Int(lb)) lb" : "\(reps) × BW"
        }
        c.restStart = s.restStart
        c.restEnd = s.restEnd
        c.setStart = s.setStart
        c.logNeeded = s.logNeeded
        c.restSeconds = Self.restSeconds
        let bpm: Int = Int(s.hr.rounded())
        let pct: Int = Int((s.hr / Self.maxHR * 100).rounded())
        c.hr = bpm
        c.hrPct = pct
        c.hrMax = Int(Self.maxHR)
        var zone: Int = 5
        if pct < 60 { zone = 1 } else if pct < 70 { zone = 2 } else if pct < 80 { zone = 3 } else if pct < 90 { zone = 4 }
        c.hrZone = zone
        c.lastSet = s.lastLabel
        c.speeds = s.lastSpeeds
        if let first = s.lastSpeeds.first, let last = s.lastSpeeds.last, first > 0 {
            let loss: Int = Int(((first - last) / first * 100).rounded())
            c.speedLoss = loss
            c.peakSpeed = (s.lastSpeeds.max() ?? 0) * 1.6
            let effort: String = loss >= 20 ? "Hard" : (loss >= 10 ? "Solid" : "Easy")
            let rpe: Double = loss >= 20 ? 9 : (loss >= 10 ? 8 : 7)
            c.effort = effort
            c.tempo = "3-0-1-1"
            c.dRPE = rpe
            c.rpeWhy = "speed dropped \(loss)%" + (loss >= 20 ? " · last rep a grind" : "")
        }
        // Up next: the set after this one in the plan.
        if let ex, s.setIndex + 1 < ex.sets.count {
            let nx = ex.sets[s.setIndex + 1]
            c.upNext = "\(ex.name) · \(nx.targetReps) × \(Int(nx.targetWeight)) lb"
        } else if s.exIndex + 1 < exs.count {
            let ne = exs[s.exIndex + 1]
            c.upNext = ne.name
        }
        let all: [ExerciseSet] = exs.flatMap { $0.sets }
        c.setsDone = all.filter { $0.loggedReps != nil }.count
        c.setsTotal = all.count
        c.exTotal = exs.count
        c.exDone = exs.filter { e in e.sets.allSatisfy { $0.loggedReps != nil } }.count
        return c
    }

    private func hello(_ s: Sim) -> LiveHello {
        LiveHello(clientId: s.clientId, name: s.name, allowed: true, asking: false, workoutId: s.workout.id)
    }

    private func currentExercise(_ s: Sim) -> Exercise? {
        s.exIndex < s.workout.exercises.count ? s.workout.exercises[s.exIndex] : nil
    }

    private func currentSet(_ s: Sim) -> ExerciseSet? {
        guard let ex = currentExercise(s), s.setIndex < ex.sets.count else { return nil }
        return ex.sets[s.setIndex]
    }

    // MARK: The two made-up clients

    private func sets(_ n: Int, _ reps: Int, _ lb: Double, _ tag: String) -> [ExerciseSet] {
        (0..<n).map { i in ExerciseSet(id: "\(tag)-s\(i)", targetReps: reps, targetWeight: lb) }
    }

    private func exercise(_ id: String, _ name: String, _ group: String, _ sets: [ExerciseSet]) -> Exercise {
        Exercise(id: id, name: name, muscleGroup: group, description: "", coachNotes: "", sets: sets, restSeconds: Self.restSeconds)
    }

    /// Alex: Back Squat, two sets done, about to start the third.
    private func makeAlex(_ now: Date) -> Sim {
        var w = Workout(id: "demo-w-alex", title: "Lower A", date: now, exercises: [
            exercise("demo-a-sq", "Back Squat", "Legs", sets(4, 5, 225, "a-sq")),
            exercise("demo-a-rdl", "Romanian Deadlift", "Hamstrings", sets(3, 8, 185, "a-rdl")),
            exercise("demo-a-lu", "Walking Lunge", "Legs", sets(3, 10, 40, "a-lu"))])
        for i in 0..<2 {
            w.exercises[0].sets[i].loggedReps = 5
            w.exercises[0].sets[i].loggedWeight = 225
            w.exercises[0].sets[i].rpe = 7.5 + 0.5 * Double(i)
            w.exercises[0].sets[i].loggedAt = now.addingTimeInterval(TimeInterval(-420 + i * 180))
        }
        let s = Sim(id: alexId, clientId: Self.prefix + "alex", name: "Alex Rivera", workout: w, openedAt: now.addingTimeInterval(-22 * 60))
        s.setIndex = 2
        s.lastSpeeds = [0.61, 0.60, 0.57, 0.55, 0.52]
        s.lastLabel = "Back Squat · Set 2"
        s.lastSet = LiveLastSet(exerciseId: "demo-a-sq", setId: "a-sq-s1", setNumber: 2, reps: fakeReps(s.lastSpeeds, end: now.addingTimeInterval(-240)))
        s.hr = 116
        s.autoStartAt = now.addingTimeInterval(4)
        return s
    }

    /// Jordan: Bench Press, one set done, resting.
    private func makeJordan(_ now: Date) -> Sim {
        var w = Workout(id: "demo-w-jordan", title: "Upper B", date: now, exercises: [
            exercise("demo-j-bp", "Bench Press", "Chest", sets(4, 6, 155, "j-bp")),
            exercise("demo-j-row", "Barbell Row", "Back", sets(3, 8, 135, "j-row")),
            exercise("demo-j-ohp", "Overhead Press", "Shoulders", sets(3, 8, 95, "j-ohp"))])
        w.exercises[0].sets[0].loggedReps = 6
        w.exercises[0].sets[0].loggedWeight = 155
        w.exercises[0].sets[0].rpe = 7.5
        w.exercises[0].sets[0].loggedAt = now.addingTimeInterval(-25)
        let s = Sim(id: jordanId, clientId: Self.prefix + "jordan", name: "Jordan Lee", workout: w, openedAt: now.addingTimeInterval(-9 * 60))
        s.setIndex = 1
        s.lastSpeeds = [0.53, 0.52, 0.50, 0.48, 0.46, 0.43]
        s.lastLabel = "Bench Press · Set 1"
        s.lastSet = LiveLastSet(exerciseId: "demo-j-bp", setId: "j-bp-s0", setNumber: 1, reps: fakeReps(s.lastSpeeds, end: now.addingTimeInterval(-30)))
        s.hr = 124
        s.stage = .resting
        s.restStart = now.addingTimeInterval(-15)
        s.restEnd = now.addingTimeInterval(30)
        return s
    }

    /// Reps for a set that's already done (the seeded "last set").
    private func fakeReps(_ speeds: [Double], end: Date) -> [RepMotion] {
        var out: [RepMotion] = []
        for (i, v) in speeds.enumerated() {
            let con: Double = 0.55 / max(v, 0.15)
            let t: Date = end.addingTimeInterval(Double(i - speeds.count) * 3)
            out.append(RepMotion(index: i + 1, start: t.addingTimeInterval(-(con + 1.7)), end: t, eccentricSec: 1.6 + Double(i) * 0.05,
                                 bottomPauseSec: 0.12, concentricSec: con, topPauseSec: 0.6, travelM: 0.55,
                                 meanVelocity: v, peakVelocity: v * 1.6, stickingPoint: 0.4, driftM: 0.02))
        }
        return out
    }

    /// Twenty minutes of heart rate: up with each set, down through rest.
    private func seedHR(_ now: Date, base: Double) -> [PadLiveHR] {
        var out: [PadLiveHR] = []
        var t: Double = -20 * 60
        while t < 0 {
            let phase: Double = (t.truncatingRemainder(dividingBy: 180) + 180) / 180     // a set every 3 minutes
            let lift: Double = phase < 0.25 ? phase / 0.25 : max(0, 1 - (phase - 0.25) / 0.5)
            let bpm: Double = base - 10 + lift * 38 + Double.random(in: -2...2)
            out.append(PadLiveHR(at: now.addingTimeInterval(t), bpm: Int(bpm.rounded())))
            t += 5
        }
        return out
    }

    private func seedFinished(_ s: Sim, _ now: Date) -> [PadLiveSetDone] {
        guard let label = s.lastLabel, !s.lastSpeeds.isEmpty else { return [] }
        var out: [PadLiveSetDone] = []
        if s.setIndex >= 2, let ex = s.workout.exercises.first {
            let earlier: [Double] = s.lastSpeeds.map { $0 + 0.02 }
            out.append(PadLiveSetDone(id: "seed-1-\(s.id)", label: "\(ex.name) · Set 1", at: now.addingTimeInterval(-420),
                                      speeds: earlier, loss: 13, effort: "Solid"))
        }
        let first: Double = s.lastSpeeds.first ?? 1
        let last: Double = s.lastSpeeds.last ?? 1
        let loss: Int = Int(((first - last) / first * 100).rounded())
        out.append(PadLiveSetDone(id: "seed-2-\(s.id)", label: label, at: now.addingTimeInterval(-240),
                                  speeds: s.lastSpeeds, loss: loss, effort: loss >= 20 ? "Hard" : "Solid"))
        return out
    }
}
