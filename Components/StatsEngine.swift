import Foundation
import SwiftUI

// MARK: - Stats data layer
// Everything the Stats tab shows is derived here from three sources:
//   • logged sets (AppStore.workouts)
//   • heart rate (stored workout vitals from Apple Health)
//   • Watch motion (SetMotionStore, or DemoMotion in demo mode)
// Nothing is invented outside demo mode. Weights are stored in lb and only
// converted for display (see StatsUnits).

// MARK: Units

enum StatsUnits {
    static var isKg: Bool { (UserDefaults.standard.string(forKey: "bst_units") ?? "lb") == "kg" }
    static var weightLabel: String { isKg ? "kg" : "lb" }
    static var depthLabel: String { isKg ? "cm" : "in" }

    static func weight(_ lb: Double) -> Double { isKg ? lb * 0.45359237 : lb }
    static func weightText(_ lb: Double, unit: Bool = true) -> String {
        let v = weight(lb)
        let s = (isKg && v < 100) ? String(format: "%.1f", v) : Int(v.rounded()).formatted()
        return unit ? "\(s) \(weightLabel)" : s
    }
    static func depth(_ meters: Double) -> Double { isKg ? meters * 100 : meters * 39.3701 }
    static func depthText(_ meters: Double) -> String {
        String(format: "%.1f %@", depth(meters), depthLabel)
    }
    static func velocityText(_ v: Double) -> String { String(format: "%.2f m/s", v) }
    static func secondsText(_ s: Double) -> String { String(format: "%.1fs", s) }
}

// MARK: Windows, categories, metrics

enum StatsWindow: String, CaseIterable, Identifiable {
    case w4 = "4W", w12 = "12W", m6 = "6M", y1 = "1Y", all = "All"
    var id: String { rawValue }
    var start: Date? {
        let cal = Calendar.current
        switch self {
        case .w4:  return cal.date(byAdding: .day, value: -28, to: Date())
        case .w12: return cal.date(byAdding: .day, value: -84, to: Date())
        case .m6:  return cal.date(byAdding: .month, value: -6, to: Date())
        case .y1:  return cal.date(byAdding: .year, value: -1, to: Date())
        case .all: return nil
        }
    }
    var label: String {
        switch self {
        case .w4: return "last 4 weeks"
        case .w12: return "last 12 weeks"
        case .m6: return "last 6 months"
        case .y1: return "last year"
        case .all: return "all time"
        }
    }
}

enum StatCategory: String, CaseIterable, Identifiable {
    case weight = "Weight", heartRate = "Heart Rate", sensor = "Sensor"
    var id: String { rawValue }
}

enum SensorMetric: String, CaseIterable, Identifiable {
    case speed = "Bar Speed"
    case speedLoss = "Speed Loss"
    case depth = "Depth"
    case pause = "Bottom Pause"
    case tempo = "Tempo"
    case tut = "Time Under Tension"
    case sticking = "Sticking Point"
    case grinds = "Grind Reps"
    case consistency = "Depth Consistency"
    case drift = "Bar Drift"
    case reps = "Reps Tracked"
    var id: String { rawValue }

    static let defaults: Set<SensorMetric> = [.speed, .speedLoss, .depth, .pause]
}

// MARK: SBD

enum SBDLift: String, CaseIterable, Identifiable {
    case squat = "Squat", bench = "Bench", deadlift = "Deadlift"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .squat: return Brand.volt
        case .bench: return Color(hex: 0x3D9BE0)
        case .deadlift: return Color(hex: 0xF2A03D)
        }
    }

    /// Competition-style lifts only; variations (front squat, incline, RDL…) don't count.
    static func classify(_ name: String) -> SBDLift? {
        let n = name.lowercased()
        if n.contains("squat") {
            let variants = ["front", "split", "goblet", "hack", "box", "zercher", "overhead", "safety", "belt", "pistol"]
            return variants.contains(where: { n.contains($0) }) ? nil : .squat
        }
        if n.contains("bench") {
            let variants = ["incline", "decline", "close", "dumbbell", "db", "floor", "spoto", "larsen", "board", "pin"]
            return variants.contains(where: { n.contains($0) }) ? nil : .bench
        }
        if n.contains("deadlift") {
            let variants = ["romanian", "rdl", "stiff", "trap", "hex", "single", "snatch"]
            return variants.contains(where: { n.contains($0) }) ? nil : .deadlift
        }
        return nil
    }

    /// Minimum velocity threshold — typical bar speed of a true 1-rep max (m/s).
    var mvt: Double {
        switch self {
        case .squat: return 0.30
        case .bench: return 0.17
        case .deadlift: return 0.15
        }
    }
}

/// DOTS strength score. Needs bodyweight and the scoring category the lifter chooses.
enum DOTS {
    static func score(totalKg: Double, bodyweightKg bw: Double, womens: Bool) -> Double? {
        guard totalKg > 0, bw > 30 else { return nil }
        let c: [Double] = womens
            ? [-57.96288, 13.6175032, -0.1126655495, 0.0005158568, -0.0000010706]
            : [-307.75076, 24.0900756, -0.1918759221, 0.0007391293, -0.000001093]
        let denom = c[0] + c[1] * bw + c[2] * bw * bw + c[3] * pow(bw, 3) + c[4] * pow(bw, 4)
        guard denom > 0 else { return nil }
        return totalKg * 500 / denom
    }
}

// MARK: Model

struct SetStat: Identifiable {
    var id: String              // set id
    var number: Int
    var reps: Int
    var weight: Double          // lb
    var rpe: Double?
    var loggedAt: Date?
    var motion: SetMotion?

    var e1RM: Double { ProgressEngine.oneRepMax(weight: weight, reps: reps) }
    var volume: Double { Double(reps) * weight }
}

struct ExerciseStat: Identifiable {
    var id: String              // exercise id
    var name: String
    var muscleGroup: String
    var sbd: SBDLift?
    var sets: [SetStat]

    var topWeight: Double { sets.map { $0.weight }.max() ?? 0 }
    var bestE1RM: Double { sets.map { $0.e1RM }.max() ?? 0 }
    var avgWeight: Double { sets.isEmpty ? 0 : sets.map { $0.weight }.reduce(0, +) / Double(sets.count) }
    var volume: Double { sets.map { $0.volume }.reduce(0, +) }
    var avgRPE: Double? {
        let r = sets.compactMap { $0.rpe }
        return r.isEmpty ? nil : Double(r.reduce(0, +)) / Double(r.count)
    }
    var motions: [SetMotion] { sets.compactMap { $0.motion } }
    var reps: [RepMotion] { motions.flatMap { $0.reps } }
    var hasMotion: Bool { !motions.isEmpty }
}

struct StatsSession: Identifiable {
    var id: String              // workout id
    var date: Date
    var title: String
    var exercises: [ExerciseStat]
    var hr: (avg: Int, peak: Int)?
    var durationMin: Int?
    var calories: Int?
    var notes: [StatNote] = []

    var volume: Double { exercises.map { $0.volume }.reduce(0, +) }
    var setCount: Int { exercises.map { $0.sets.count }.reduce(0, +) }
    var avgRPE: Double? {
        let r = exercises.flatMap { $0.sets.compactMap { $0.rpe } }
        return r.isEmpty ? nil : Double(r.reduce(0, +)) / Double(r.count)
    }
    var motions: [SetMotion] { exercises.flatMap { $0.motions } }
    var reps: [RepMotion] { motions.flatMap { $0.reps } }
    var hasMotion: Bool { !motions.isEmpty }
}

struct StatNote: Identifiable {
    enum Kind { case effort, depth, readiness }
    var id = UUID()
    var kind: Kind
    var exerciseName: String
    var setNumber: Int?
    var date: Date
    var text: String

    var icon: String {
        switch kind {
        case .effort: return "gauge.with.dots.needle.67percent"
        case .depth: return "arrow.down.to.line"
        case .readiness: return "bolt.fill"
        }
    }
}

enum StatsSubject: Hashable, Identifiable {
    case exercise(String)
    case workout(String)        // all sessions with this workout title
    case sbd
    case session(String)        // one workout, by id (from the calendar)

    var id: String {
        switch self {
        case .exercise(let n): return "ex:\(n)"
        case .workout(let t): return "wo:\(t)"
        case .sbd: return "sbd"
        case .session(let id): return "se:\(id)"
        }
    }
    var title: String {
        switch self {
        case .exercise(let n): return n
        case .workout(let t): return t
        case .sbd: return "SBD"
        case .session: return "Session"
        }
    }
}

// MARK: Charts

struct StatPoint: Identifiable {
    let id = UUID()
    var date: Date
    var value: Double
}

struct StatSeries: Identifiable {
    enum Style { case line, dashed, bar, points }
    var name: String
    var color: Color
    var style: Style
    var points: [StatPoint]
    var id: String { name }
}

struct StatReference: Identifiable {
    var label: String
    var value: Double
    var color: Color
    var id: String { label }
}

struct StatPanel: Identifiable {
    var id: String
    var category: StatCategory
    var title: String
    var series: [StatSeries]
    var format: (Double) -> String
    var caption: String? = nil
    /// Unit shown on the y-axis ("lb", "m/s", "bpm"…).
    var axisUnit: String = ""
    /// true = up is good, false = down is good, nil = neither (just information).
    var higherIsBetter: Bool? = true
    var references: [StatReference] = []

    var hasData: Bool { series.contains { !$0.points.isEmpty } }
    var usesBars: Bool { series.contains { $0.style == .bar } }
    var primary: StatSeries? { series.first { !$0.points.isEmpty } }
}

// MARK: - Engine

/// Where Stats reads from: your own data (the client app), or one client's data
/// fetched from the server (the coach's view of that client). Same screens either way.
@MainActor
struct StatsSource {
    var workouts: [Workout]
    var isDemo: Bool
    var motion: (_ workoutId: String, _ setId: String) -> SetMotion?
    var vitals: [String: WorkoutVitals]
    /// For DOTS. The client app reads it from Apple Health; the coach passes the client's latest check-in weight.
    var bodyweightLb: Double? = nil

    /// The signed-in client's own data.
    static func mine(_ store: AppStore) -> StatsSource {
        StatsSource(workouts: store.workouts,
                    isDemo: store.isDemoMode || APIConfig.useMock,
                    motion: { w, s in SetMotionStore.shared.motion(workoutId: w, setId: s) },
                    vitals: store.workoutVitals)
    }
}

@MainActor
struct StatsEngine {
    let source: StatsSource

    init(store: AppStore) { source = .mine(store) }
    init(source: StatsSource) { self.source = source }

    // MARK: Sessions

    /// Completed sessions in the window for a subject, oldest first, with notes attached.
    func sessions(for subject: StatsSubject, window: StatsWindow) -> [StatsSession] {
        let start = window.start
        let workouts = source.workouts
            .filter { $0.completed && (start == nil || $0.date >= start!) }
            .sorted { $0.date < $1.date }

        let wholeWorkout: Bool
        switch subject {
        case .workout, .session: wholeWorkout = true
        default: wholeWorkout = false
        }

        var out: [StatsSession] = []
        for w in workouts {
            let exercises: [Exercise]
            switch subject {
            case .exercise(let name): exercises = w.exercises.filter { $0.name == name }
            case .workout(let title): exercises = w.title == title ? w.exercises : []
            case .sbd: exercises = w.exercises.filter { SBDLift.classify($0.name) != nil }
            case .session(let id): exercises = w.id == id ? w.exercises : []
            }
            let stats = exercises.compactMap { exerciseStat($0, workoutId: w.id) }
            guard !stats.isEmpty else { continue }
            var s = StatsSession(id: w.id, date: w.date, title: w.title, exercises: stats)
            attachVitals(&s, wholeWorkout: wholeWorkout)
            out.append(s)
        }
        attachNotes(&out)
        return out
    }

    /// Every completed session (all exercises), for the dashboard.
    func allSessions(window: StatsWindow) -> [StatsSession] {
        let start = window.start
        var out: [StatsSession] = source.workouts
            .filter { $0.completed && (start == nil || $0.date >= start!) }
            .sorted { $0.date < $1.date }
            .compactMap { w in
                let stats = w.exercises.compactMap { exerciseStat($0, workoutId: w.id) }
                guard !stats.isEmpty else { return nil }
                var s = StatsSession(id: w.id, date: w.date, title: w.title, exercises: stats)
                attachVitals(&s, wholeWorkout: true)
                return s
            }
        attachNotes(&out)
        return out
    }

    private func exerciseStat(_ ex: Exercise, workoutId: String) -> ExerciseStat? {
        var sets: [SetStat] = []
        for (i, s) in ex.sets.enumerated() {
            guard let r = s.loggedReps, let wt = s.loggedWeight, r > 0 else { continue }
            sets.append(SetStat(id: s.id, number: i + 1, reps: r, weight: wt, rpe: s.rpe,
                                loggedAt: s.loggedAt,
                                motion: motion(workoutId: workoutId, exercise: ex, set: s, setIndex: i)))
        }
        guard !sets.isEmpty else { return nil }
        return ExerciseStat(id: ex.id, name: ex.name, muscleGroup: ex.muscleGroup,
                            sbd: SBDLift.classify(ex.name), sets: sets)
    }

    private func motion(workoutId: String, exercise: Exercise, set: ExerciseSet, setIndex: Int) -> SetMotion? {
        if source.isDemo {
            return DemoMotion.motion(workoutId: workoutId, exercise: exercise, set: set,
                                     setIndex: setIndex, workouts: source.workouts)
        }
        return source.motion(workoutId, set.id)
    }

    // MARK: Heart rate

    private func attachVitals(_ s: inout StatsSession, wholeWorkout: Bool) {
        if source.isDemo {
            let hrs = s.exercises.map { DemoMotion.heartRate(workoutId: s.id, exerciseName: $0.name, date: s.date) }
            if !hrs.isEmpty {
                s.hr = (avg: hrs.map { $0.avg }.reduce(0, +) / hrs.count, peak: hrs.map { $0.peak }.max() ?? 0)
            }
            if wholeWorkout {
                let d = DemoMotion.session(workoutId: s.id)
                s.durationMin = d.minutes
                s.calories = d.calories
            }
            return
        }
        guard let v = source.vitals[s.id] else { return }
        if wholeWorkout {
            if let a = v.avgHeartRate, let p = v.peakHeartRate { s.hr = (avg: a, peak: p) }
            s.durationMin = v.durationMinutes
            s.calories = v.activeCalories
            return
        }
        // Slice the series to when these exercises were actually trained.
        var stamps: [Date] = []
        for ex in s.exercises {
            for set in ex.sets {
                if let m = set.motion { stamps.append(m.start); stamps.append(m.end) }
                else if let t = set.loggedAt { stamps.append(t) }
            }
        }
        stamps.sort()
        guard let first = stamps.first, let last = stamps.last, v.heartRateSeries.count > 1 else { return }
        s.hr = HealthKitManager.heartRate(in: v.heartRateSeries, from: first.addingTimeInterval(-90), to: last)
    }

    // MARK: Notes (polite, never sent anywhere — shown where the data is reviewed)

    private func attachNotes(_ sessions: inout [StatsSession]) {
        // Typical depth per exercise from everything we have, for "shallower than usual".
        var depthBaseline: [String: Double] = [:]
        let allByName = Dictionary(grouping: sessions.flatMap { $0.exercises }, by: { $0.name })
        for (name, exs) in allByName {
            let t = exs.flatMap { $0.reps.map { $0.travelM } }.sorted()
            if t.count >= 10 { depthBaseline[name] = t[t.count / 2] }
        }

        for i in sessions.indices {
            var notes: [StatNote] = []
            let s = sessions[i]
            for ex in s.exercises {
                for set in ex.sets {
                    guard let m = set.motion, m.repCount >= 3 else { continue }
                    if let rpe = set.rpe, let loss = m.velocityLossPct {
                        let expected = Self.expectedRPE(velocityLoss: loss, grinds: m.grindRepCount)
                        if rpe - expected >= 2 {
                            notes.append(StatNote(kind: .effort, exerciseName: ex.name, setNumber: set.number, date: s.date,
                                text: "You rated set \(set.number) RPE \(rpe.rpeText), but bar speed held steady (only \(Int(loss.rounded()))% slower by the last rep). There may have been a rep or two left — useful to know for next time."))
                        } else if expected - rpe >= 2 {
                            notes.append(StatNote(kind: .effort, exerciseName: ex.name, setNumber: set.number, date: s.date,
                                text: "Bar speed dropped \(Int(loss.rounded()))% across set \(set.number), which usually means it was closer to a limit than RPE \(rpe.rpeText). Nothing wrong — just worth keeping in mind."))
                        }
                    }
                    if let base = depthBaseline[ex.name], m.averageTravelM < base * 0.9 {
                        let diff = StatsUnits.depth(base - m.averageTravelM)
                        notes.append(StatNote(kind: .depth, exerciseName: ex.name, setNumber: set.number, date: s.date,
                            text: String(format: "Set %d averaged about %.1f %@ less depth than your usual %@.",
                                         set.number, diff, StatsUnits.depthLabel, ex.name.lowercased())))
                    }
                }
            }
            sessions[i].notes = notes
        }
    }

    /// Rough RPE implied by speed loss within a set (velocity-based training rule of thumb).
    static func expectedRPE(velocityLoss: Double, grinds: Int) -> Double {
        if grinds > 0 { return max(9.5, velocityLoss >= 30 ? 10 : 9.5) }
        switch velocityLoss {
        case ..<10: return 6.5
        case ..<20: return 7.5
        case ..<30: return 8.5
        case ..<40: return 9.25
        default: return 10
        }
    }

    // MARK: Load–velocity profile

    /// Estimated 1RM from bar speed: line through (load, best rep speed) for this lift over
    /// the six weeks before `asOf`, extended down to the lift's 1RM speed.
    func velocityE1RM(exerciseName: String, asOf: Date, sessions all: [StatsSession]) -> Double? {
        let from = asOf.addingTimeInterval(-42 * 86400)
        var pts: [(load: Double, v: Double)] = []
        for s in all where s.date <= asOf && s.date >= from {
            for ex in s.exercises where ex.name == exerciseName {
                for set in ex.sets {
                    if let m = set.motion, let best = m.reps.map({ $0.meanVelocity }).max() {
                        pts.append((set.weight, best))
                    }
                }
            }
        }
        let loads = pts.map { $0.load }
        guard pts.count >= 4, let lo = loads.min(), let hi = loads.max(), hi > lo * 1.05 else { return nil }
        let n = Double(pts.count)
        let mx = loads.reduce(0, +) / n, my = pts.map { $0.v }.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for p in pts { sxy += (p.load - mx) * (p.v - my); sxx += (p.load - mx) * (p.load - mx) }
        guard sxx > 0 else { return nil }
        let b = sxy / sxx
        guard b < 0 else { return nil }
        let a = my - b * mx
        let mvt = SBDLift.classify(exerciseName)?.mvt ?? 0.25
        let e = (mvt - a) / b
        return e > hi && e < hi * 2 ? e : nil
    }

    /// Readiness: how the first set's best rep compared with this lift's usual speed at that load.
    func readiness(in all: [StatsSession]) -> StatNote? {
        guard let latest = all.last(where: { $0.hasMotion }) else { return nil }
        for ex in latest.exercises where ex.sbd != nil {
            guard let first = ex.sets.first, let m = first.motion,
                  let best = m.reps.map({ $0.meanVelocity }).max() else { continue }
            // Profile from earlier sessions only.
            var pts: [(Double, Double)] = []
            for s in all where s.date < latest.date {
                for e in s.exercises where e.name == ex.name {
                    for set in e.sets {
                        if let mm = set.motion, let b = mm.reps.map({ $0.meanVelocity }).max() { pts.append((set.weight, b)) }
                    }
                }
            }
            guard pts.count >= 4 else { continue }
            let n = Double(pts.count)
            let mx = pts.map { $0.0 }.reduce(0, +) / n, my = pts.map { $0.1 }.reduce(0, +) / n
            var sxy = 0.0, sxx = 0.0
            for p in pts { sxy += (p.0 - mx) * (p.1 - my); sxx += (p.0 - mx) * (p.0 - mx) }
            guard sxx > 0 else { continue }
            let b = sxy / sxx, a = my - b * mx
            let predicted = a + b * first.weight
            guard predicted > 0.05 else { continue }
            let pct = (best - predicted) / predicted * 100
            guard abs(pct) >= 3 else { continue }
            let text = pct > 0
                ? String(format: "Your first %@ set moved %.0f%% faster than usual for %@ — a good-day signal.",
                         ex.name.lowercased(), pct, StatsUnits.weightText(first.weight))
                : String(format: "Your first %@ set moved %.0f%% slower than usual for %@. Sleep, food and stress all show up here.",
                         ex.name.lowercased(), abs(pct), StatsUnits.weightText(first.weight))
            return StatNote(kind: .readiness, exerciseName: ex.name, setNumber: 1, date: latest.date, text: text)
        }
        return nil
    }

    // MARK: Panels

    func panels(for subject: StatsSubject, sessions: [StatsSession],
                categories: Set<StatCategory>, sensors: Set<SensorMetric>,
                bodyweightLb: Double?, womensDOTS: Bool?) -> [StatPanel] {
        var out: [StatPanel] = []
        let isSBD: Bool
        if case .sbd = subject { isSBD = true } else { isSBD = false }
        let isWorkout: Bool
        if case .workout = subject { isWorkout = true } else { isWorkout = false }
        let wfmt: (Double) -> String = { StatsUnits.weightText($0) }

        // Groups: one series per SBD lift, otherwise a single group.
        func groups() -> [(name: String, color: Color, pick: (ExerciseStat) -> Bool)] {
            if isSBD {
                return SBDLift.allCases.map { l in
                    (name: l.rawValue, color: l.color, pick: { (e: ExerciseStat) -> Bool in e.sbd == l })
                }
            }
            return [(name: "All", color: Brand.volt, pick: { (_: ExerciseStat) -> Bool in true })]
        }
        func series(_ name: String, _ color: Color, _ style: StatSeries.Style,
                    _ value: (StatsSession) -> Double?) -> StatSeries {
            StatSeries(name: name, color: color, style: style,
                       points: sessions.compactMap { s in value(s).map { StatPoint(date: s.date, value: $0) } })
        }
        func perGroup(_ style: StatSeries.Style, _ value: @escaping ([ExerciseStat]) -> Double?) -> [StatSeries] {
            groups().map { g in
                series(isSBD ? g.name : "Value", g.color, style) { s in
                    let ex = s.exercises.filter(g.pick)
                    return ex.isEmpty ? nil : value(ex)
                }
            }
        }

        // ---- Weight ----
        if categories.contains(.weight) {
            if isSBD {
                var total = StatSeries(name: "Total", color: Brand.volt, style: .line, points: [])
                var dots = StatSeries(name: "DOTS", color: Brand.text, style: .line, points: [])
                var best: [SBDLift: (Date, Double)] = [:]
                for s in sessions {
                    // Running best per lift; it lapses if the lift isn't trained for 8 weeks.
                    for ex in s.exercises {
                        if let l = ex.sbd { best[l] = (s.date, max(ex.bestE1RM, recent(best[l], s.date))) }
                    }
                    // Total counts each lift's best from the last 8 weeks.
                    let current = SBDLift.allCases.compactMap { l -> Double? in
                        guard let b = best[l], s.date.timeIntervalSince(b.0) <= 56 * 86400 else { return nil }
                        return b.1
                    }
                    if current.count == 3 {
                        let t = current.reduce(0, +)
                        total.points.append(StatPoint(date: s.date, value: t))
                        if let bw = bodyweightLb, let w = womensDOTS,
                           let d = DOTS.score(totalKg: t * 0.45359237, bodyweightKg: bw * 0.45359237, womens: w) {
                            dots.points.append(StatPoint(date: s.date, value: d))
                        }
                    }
                }
                out.append(StatPanel(id: "sbd-total", category: .weight, title: "SBD Total", series: [total], format: wfmt,
                                     caption: "Best estimated 1RM per lift from the trailing 8 weeks"))
                if !dots.points.isEmpty {
                    out.append(StatPanel(id: "sbd-dots", category: .weight, title: "DOTS", series: [dots],
                                         format: { String(format: "%.1f", $0) }, caption: "Using your latest bodyweight"))
                }
                out.append(StatPanel(id: "e1rm", category: .weight, title: "Estimated 1RM",
                                     series: perGroup(.line) { $0.map { $0.bestE1RM }.max() }, format: wfmt))
                out.append(StatPanel(id: "volume", category: .weight, title: "Volume",
                                     series: perGroup(.line) { $0.map { $0.volume }.reduce(0, +) }, format: wfmt))
            } else if isWorkout {
                out.append(StatPanel(id: "volume", category: .weight, title: "Volume",
                                     series: [series("Volume", Brand.volt, .bar) { $0.volume }], format: wfmt))
                out.append(StatPanel(id: "sets", category: .weight, title: "Sets Logged",
                                     series: [series("Sets", Color(hex: 0x3D9BE0), .bar) { Double($0.setCount) }],
                                     format: { "\(Int($0))" }))
            } else {
                var strength = [
                    series("Est. 1RM", Brand.volt, .line) { s in s.exercises.map { $0.bestE1RM }.max() },
                    series("Top Set", Brand.text, .points) { s in s.exercises.map { $0.topWeight }.max() },
                    series("Avg Working", Color(hex: 0x3D9BE0), .line) { s in s.exercises.first?.avgWeight }
                ]
                if case .exercise(let name) = subject {
                    let speed1RM = series("Speed-Based 1RM", Color(hex: 0xF2A03D), .dashed) { s in
                        velocityE1RM(exerciseName: name, asOf: s.date, sessions: sessions)
                    }
                    if !speed1RM.points.isEmpty { strength.append(speed1RM) }
                }
                out.append(StatPanel(id: "strength", category: .weight, title: "Strength", series: strength, format: wfmt))
                out.append(StatPanel(id: "volume", category: .weight, title: "Volume",
                                     series: [series("Volume", Brand.volt, .bar) { $0.volume }], format: wfmt))
            }
            out.append(StatPanel(id: "rpe", category: .weight, title: "Effort (RPE)",
                                 series: [series("RPE", Color(hex: 0xE63946), .line) { $0.avgRPE }],
                                 format: { String(format: "%.1f", $0) }))
        }

        // ---- Heart rate ----
        if categories.contains(.heartRate) {
            out.append(StatPanel(id: "hr", category: .heartRate, title: "Heart Rate", series: [
                series("Peak", Brand.volt, .line) { s in s.hr.map { Double($0.peak) } },
                series("Avg", Color(hex: 0x3D9BE0), .line) { s in s.hr.map { Double($0.avg) } }
            ], format: { "\(Int($0)) bpm" }))
            if isWorkout {
                out.append(StatPanel(id: "duration", category: .heartRate, title: "Duration",
                                     series: [series("Minutes", Color(hex: 0x3D9BE0), .bar) { $0.durationMin.map(Double.init) }],
                                     format: { "\(Int($0)) min" }))
                out.append(StatPanel(id: "calories", category: .heartRate, title: "Active Calories",
                                     series: [series("Calories", Color(hex: 0xF2A03D), .bar) { $0.calories.map(Double.init) }],
                                     format: { "\(Int($0)) cal" }))
            }
        }

        // ---- Sensor ----
        if categories.contains(.sensor) {
            func avg(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
            for metric in SensorMetric.allCases where sensors.contains(metric) {
                switch metric {
                case .speed:
                    var ser = perGroup(.line) { avg($0.flatMap { $0.reps.map { $0.meanVelocity } }) }
                    if !isSBD {
                        ser[0].name = "Avg"
                        ser.append(series("Best Rep", Brand.text, .points) { s in s.reps.map { $0.meanVelocity }.max() })
                    }
                    out.append(StatPanel(id: "s-speed", category: .sensor, title: "Bar Speed", series: ser,
                                         format: { StatsUnits.velocityText($0) }))
                case .speedLoss:
                    out.append(StatPanel(id: "s-loss", category: .sensor, title: "Speed Loss per Set",
                                         series: perGroup(.line) { avg($0.flatMap { $0.motions.compactMap { $0.velocityLossPct } }) },
                                         format: { "\(Int($0.rounded()))%" }, caption: "Higher = closer to failure"))
                case .depth:
                    out.append(StatPanel(id: "s-depth", category: .sensor, title: "Depth (Bar Travel)",
                                         series: perGroup(.line) { avg($0.flatMap { $0.reps.map { StatsUnits.depth($0.travelM) } }) },
                                         format: { String(format: "%.1f %@", $0, StatsUnits.depthLabel) }))
                case .pause:
                    out.append(StatPanel(id: "s-pause", category: .sensor, title: "Bottom Pause",
                                         series: perGroup(.line) { avg($0.flatMap { $0.reps.compactMap { $0.bottomPauseSec } }) },
                                         format: { StatsUnits.secondsText($0) },
                                         caption: "Bench pause = chest; deadlift pause = floor between reps"))
                case .tempo:
                    if isSBD {
                        out.append(StatPanel(id: "s-tempo", category: .sensor, title: "Lifting Time",
                                             series: perGroup(.line) { avg($0.flatMap { $0.reps.map { $0.concentricSec } }) },
                                             format: { StatsUnits.secondsText($0) }))
                    } else {
                        out.append(StatPanel(id: "s-tempo", category: .sensor, title: "Tempo", series: [
                            series("Lowering", Color(hex: 0x3D9BE0), .line) { s in avg(s.reps.compactMap { $0.eccentricSec }) },
                            series("Lifting", Brand.volt, .line) { s in avg(s.reps.map { $0.concentricSec }) }
                        ], format: { StatsUnits.secondsText($0) }))
                    }
                case .tut:
                    out.append(StatPanel(id: "s-tut", category: .sensor, title: "Time Under Tension",
                                         series: perGroup(isSBD ? .line : .bar) { ex in
                                             let m = ex.flatMap { $0.motions }
                                             return m.isEmpty ? nil : m.map { $0.timeUnderTensionSec }.reduce(0, +)
                                         },
                                         format: { "\(Int($0.rounded()))s" }))
                case .sticking:
                    out.append(StatPanel(id: "s-stick", category: .sensor, title: "Sticking Point",
                                         series: perGroup(.line) { avg($0.flatMap { $0.reps.compactMap { $0.stickingPoint.map { $0 * 100 } } }) },
                                         format: { "\(Int($0.rounded()))% up" }, caption: "Where the bar slows most on the way up"))
                case .grinds:
                    out.append(StatPanel(id: "s-grind", category: .sensor, title: "Grind Reps",
                                         series: perGroup(isSBD ? .line : .bar) { ex in
                                             ex.contains(where: { $0.hasMotion }) ? Double(ex.flatMap { $0.reps }.filter { $0.isGrind }.count) : nil
                                         },
                                         format: { "\(Int($0))" }))
                case .consistency:
                    out.append(StatPanel(id: "s-consist", category: .sensor, title: "Depth Consistency",
                                         series: perGroup(.line) { avg($0.flatMap { $0.motions.compactMap { $0.travelConsistencyPct } }) },
                                         format: { "\(Int($0.rounded()))%" }, caption: "100% = every rep the same depth"))
                case .drift:
                    out.append(StatPanel(id: "s-drift", category: .sensor, title: "Bar Drift",
                                         series: perGroup(.line) { avg($0.flatMap { $0.reps.map { StatsUnits.depth($0.driftM) } }) },
                                         format: { String(format: "%.1f %@", $0, StatsUnits.depthLabel) },
                                         caption: "Experimental — side-to-side wander on the way up"))
                case .reps:
                    out.append(StatPanel(id: "s-reps", category: .sensor, title: "Reps Tracked",
                                         series: perGroup(isSBD ? .line : .bar) { ex in
                                             ex.contains(where: { $0.hasMotion }) ? Double(ex.flatMap { $0.reps }.count) : nil
                                         },
                                         format: { "\(Int($0))" }))
                }
            }
        }
        return out.map { decorate($0, subject: subject) }
    }

    /// Axis units, which direction is "good", display-unit conversion, and reference lines.
    private func decorate(_ panel: StatPanel, subject: StatsSubject) -> StatPanel {
        var p = panel
        let weightPanels: Set<String> = ["sbd-total", "e1rm", "volume", "strength"]
        if weightPanels.contains(p.id) {
            // Convert to display units once, so axis ticks land on round numbers.
            for i in p.series.indices {
                for j in p.series[i].points.indices {
                    p.series[i].points[j].value = StatsUnits.weight(p.series[i].points[j].value)
                }
            }
            let label = StatsUnits.weightLabel
            p.format = { v in
                v >= 10_000 ? String(format: "%.1fk %@", v / 1000, label)
                    : (StatsUnits.isKg ? String(format: "%.1f %@", v, label) : "\(Int(v.rounded())) \(label)")
            }
            p.axisUnit = label
            p.higherIsBetter = true
        }
        switch p.id {
        case "strength":
            if case .exercise(let name) = subject {
                let best = source.workouts.filter { $0.completed }
                    .flatMap { $0.exercises.filter { $0.name == name }.flatMap { $0.sets } }
                    .compactMap { s -> Double? in
                        guard let r = s.loggedReps, let w = s.loggedWeight else { return nil }
                        return ProgressEngine.oneRepMax(weight: w, reps: r)
                    }.max()
                if let best { p.references = [StatReference(label: "PR", value: StatsUnits.weight(best), color: Brand.volt)] }
            }
        case "sbd-dots": p.axisUnit = "pts"
        case "sets": p.axisUnit = "sets"
        case "rpe":
            p.axisUnit = "RPE"; p.higherIsBetter = nil
            // A 3-session rolling average makes the direction readable.
            if let s0 = p.series.first, s0.points.count >= 3 {
                var trend = StatSeries(name: "Trend", color: Brand.text.opacity(0.6), style: .dashed, points: [])
                for i in s0.points.indices {
                    let lo = max(0, i - 2)
                    let w = s0.points[lo...i].map { $0.value }
                    trend.points.append(StatPoint(date: s0.points[i].date, value: w.reduce(0, +) / Double(w.count)))
                }
                p.series.append(trend)
            }
        case "hr": p.axisUnit = "bpm"; p.higherIsBetter = nil
        case "duration": p.axisUnit = "min"; p.higherIsBetter = nil
        case "calories": p.axisUnit = "cal"; p.higherIsBetter = nil
        case "s-speed":
            p.axisUnit = "m/s"
            if case .exercise(let name) = subject, let lift = SBDLift.classify(name) {
                p.references = [StatReference(label: "1RM speed", value: lift.mvt, color: Color(hex: 0xE63946))]
            }
        case "s-loss": p.axisUnit = "%"; p.higherIsBetter = false
        case "s-depth": p.axisUnit = StatsUnits.depthLabel; p.higherIsBetter = nil
        case "s-pause", "s-tempo", "s-tut": p.axisUnit = "sec"; p.higherIsBetter = nil
        case "s-stick": p.axisUnit = "% up"; p.higherIsBetter = nil
        case "s-grind": p.axisUnit = "reps"; p.higherIsBetter = false
        case "s-consist": p.axisUnit = "%"; p.higherIsBetter = true
        case "s-drift": p.axisUnit = StatsUnits.depthLabel; p.higherIsBetter = false
        case "s-reps": p.axisUnit = "reps"; p.higherIsBetter = nil
        default: break
        }
        return p
    }

    private func recent(_ b: (Date, Double)?, _ now: Date) -> Double {
        guard let b, now.timeIntervalSince(b.0) <= 56 * 86400 else { return 0 }
        return b.1
    }
}
