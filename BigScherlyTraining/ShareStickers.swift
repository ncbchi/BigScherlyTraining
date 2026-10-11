import SwiftUI
import UIKit

// MARK: - What goes on a share card (Oct 9, 2026)
// Four kinds of thing: our own lifting stickers (drawn here, so they're sharp at any size),
// stickers filled in from the lifter's real data, GIPHY GIFs and stickers, and text.
// Everything is drawn in the card's layout points (360 wide); the editor scales the card.
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

struct ShareItem: Identifiable, Equatable {
    let id: UUID
    var kind: ShareItemKind
    var position: CGPoint
    var scale: CGFloat = 1
    var rotation: Double = 0      // degrees

    init(kind: ShareItemKind, position: CGPoint, scale: CGFloat = 1, rotation: Double = 0) {
        self.id = UUID()
        self.kind = kind
        self.position = position
        self.scale = scale
        self.rotation = rotation
    }

    var moves: Bool {
        switch kind {
        case .gif: return true
        case .pack(let p): return p.animated
        default: return false
        }
    }
}

enum ShareItemKind: Equatable {
    case pack(SharePack)
    case data(ShareDataKind, ShareDataStyle)
    case gif(ShareGif)
    case text(ShareText)
}

// MARK: - Our lifting sticker pack

enum SharePack: String, CaseIterable, Identifiable {
    case pr, plate, barbell, crown, oneMore, flame, kettlebell, noRep, chalk, legDay, timer, big, lightWeight
    case logo
    case queens, beastMode, sendIt, gains, newPB, lockout, restDay, heart, trophy, dumbbell, bolt, muscle, sweat, hundred
    var id: String { rawValue }

    /// Words the sticker search matches.
    var keywords: String {
        switch self {
        case .pr: return "pr record personal best new"
        case .plate: return "plate 45 20 weight bumper"
        case .barbell: return "barbell bar loaded squat bench deadlift"
        case .crown: return "crown queen king queens win"
        case .oneMore: return "one more rep set"
        case .flame: return "flame fire streak hot"
        case .kettlebell: return "kettlebell bell swing"
        case .noRep: return "no rep depth fail"
        case .chalk: return "chalk hand grip"
        case .legDay: return "leg day legs squat"
        case .timer: return "timer rest clock stopwatch"
        case .big: return "big gains strong"
        case .lightWeight: return "light weight baby easy"
        case .logo: return "logo big scherly"
        case .queens: return "queens rainbow pride lgbtq"
        case .beastMode: return "beast mode savage"
        case .sendIt: return "send it go"
        case .gains: return "gains growth"
        case .newPB: return "new pr personal record best"
        case .lockout: return "lockout locked out"
        case .restDay: return "rest day recovery"
        case .heart: return "heart love pride rainbow"
        case .trophy: return "trophy win winner"
        case .dumbbell: return "dumbbell weights"
        case .bolt: return "bolt energy power fast"
        case .muscle: return "muscle flex strong arm"
        case .sweat: return "sweat hard work"
        case .hundred: return "100 hundred perfect"
        }
    }

    var animated: Bool { self == .pr || self == .flame || self == .timer }
}

// MARK: - Data stickers

enum ShareDataKind: String, CaseIterable, Identifiable {
    case pr, workout, stats, streak, topLift, date, award, barSpeed, today, estMax, volume, trend, crewWeek, crewTrained, crewAwards
    // More (Oct 9, 2026)
    case heaviestSet, totalReps, avgRPE, exercises, sessionPRs
    case peakSpeed, tut, depth, pausedReps
    case weekCount, monthCount, weeklySets, consistency, liftTrend, big3, prsMonth
    case allTime, lifetimeVolume, prCount, awardsTotal, checkIns
    var id: String { rawValue }

    var chip: String {
        switch self {
        case .pr: return "PR"
        case .barSpeed: return "BAR SPEED"
        case .streak: return "STREAK"
        case .today: return "TODAY"
        case .estMax: return "EST. MAX"
        case .volume: return "VOLUME"
        case .trend: return "12 WEEKS"
        case .award: return "AWARD"
        case .date: return "DATE"
        case .topLift: return "TOP LIFT"
        case .stats: return "STATS"
        case .workout: return "WORKOUT"
        case .crewWeek: return "WORKOUTS"
        case .crewTrained: return "TRAINED"
        case .crewAwards: return "AWARDS"
        case .heaviestSet: return "HEAVIEST SET"
        case .totalReps: return "TOTAL REPS"
        case .avgRPE: return "AVG RPE"
        case .exercises: return "EXERCISES"
        case .sessionPRs: return "PRS TODAY"
        case .peakSpeed: return "PEAK SPEED"
        case .tut: return "UNDER TENSION"
        case .depth: return "DEPTH"
        case .pausedReps: return "PAUSED REPS"
        case .weekCount: return "THIS WEEK"
        case .monthCount: return "THIS MONTH"
        case .weeklySets: return "WEEKLY SETS"
        case .consistency: return "WEEKS TRAINED"
        case .liftTrend: return "LIFT TREND"
        case .big3: return "BIG 3"
        case .prsMonth: return "PRS THIS MONTH"
        case .allTime: return "ALL TIME"
        case .lifetimeVolume: return "LIFETIME"
        case .prCount: return "ALL PRS"
        case .awardsTotal: return "AWARDS"
        case .checkIns: return "CHECK-INS"
        }
    }

    var icon: String {
        switch self {
        case .pr: return "trophy.fill"
        case .barSpeed: return "applewatch"
        case .streak: return "flame.fill"
        case .today: return "list.bullet"
        case .estMax: return "gauge.with.needle"
        case .volume: return "chart.bar.fill"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .award: return "rosette"
        case .date: return "calendar"
        case .topLift: return "arrow.up.circle.fill"
        case .stats: return "chart.bar.fill"
        case .workout: return "dumbbell.fill"
        case .crewWeek: return "dumbbell.fill"
        case .crewTrained: return "person.3.fill"
        case .crewAwards: return "rosette"
        case .heaviestSet: return "scalemass.fill"
        case .totalReps: return "repeat"
        case .avgRPE: return "gauge.with.dots.needle.67percent"
        case .exercises: return "list.bullet"
        case .sessionPRs: return "trophy.fill"
        case .peakSpeed: return "bolt.fill"
        case .tut: return "timer"
        case .depth: return "arrow.down.to.line"
        case .pausedReps: return "pause.fill"
        case .weekCount: return "calendar"
        case .monthCount: return "calendar"
        case .weeklySets: return "chart.bar.fill"
        case .consistency: return "checkmark.seal.fill"
        case .liftTrend: return "chart.line.uptrend.xyaxis"
        case .big3: return "dumbbell.fill"
        case .prsMonth: return "trophy"
        case .allTime: return "infinity"
        case .lifetimeVolume: return "mountain.2.fill"
        case .prCount: return "trophy.fill"
        case .awardsTotal: return "rosette"
        case .checkIns: return "checkmark.circle.fill"
        }
    }

    /// The chip's colour pair (Instagram-style gradient text on a white chip).
    var tint: [Color] {
        switch self {
        case .pr, .volume, .crewWeek, .stats: return [Color(red: 0.36, green: 0.48, blue: 0.07), Color(red: 0.20, green: 0.48, blue: 0.12)]
        case .barSpeed, .crewTrained: return [Color(red: 0.05, green: 0.62, blue: 0.54), Color(red: 0.11, green: 0.48, blue: 0.84)]
        case .streak: return [Color(red: 0.96, green: 0.42, blue: 0.12), Color(red: 0.90, green: 0.22, blue: 0.23)]
        case .today, .trend: return [Color(red: 0.84, green: 0.14, blue: 0.48), Color(red: 0.54, green: 0.31, blue: 0.75)]
        case .estMax, .date, .topLift, .workout: return [Color(red: 0.11, green: 0.36, blue: 0.84), Color(red: 0.42, green: 0.25, blue: 0.85)]
        case .award, .crewAwards: return [Color(red: 0.85, green: 0.55, blue: 0.05), Color(red: 0.90, green: 0.36, blue: 0.10)]
        default: return [Color(red: 0.11, green: 0.36, blue: 0.84), Color(red: 0.42, green: 0.25, blue: 0.85)]
        }
    }
}

extension ShareDataKind {
    /// How each one first lands on the card (tap it to cycle).
    var defaultStyle: ShareDataStyle {
        switch self {
        case .pr, .topLift, .award, .sessionPRs: return .solid
        default: return .glass
        }
    }
}

enum ShareDataStyle: CaseIterable, Equatable {
    case solid, glass, plain
    var next: ShareDataStyle {
        switch self {
        case .solid: return .glass
        case .glass: return .plain
        case .plain: return .solid
        }
    }
}

struct ShareStatCell: Equatable {
    var value: String
    var label: String
}

struct ShareDataModel: Equatable {
    var eyebrow: String
    var value: String
    var unit: String = ""
    var foot: String? = nil
    var series: [Double]? = nil
    var bars: Bool = false
    var watch: Bool = false
    /// A one-line capsule (streak, top lift, date), like the original stickers.
    var pill: Bool = false
    var icon: String? = nil
    /// A row of numbers (the original Stats sticker).
    var cells: [ShareStatCell] = []
}

/// Turns the lifter's real data (or the crew's week) into stickers. A sticker only shows
/// up in the trays when there's something true to put on it.
struct ShareDataSource {
    let store: AppStore
    let crew: CrewShare?

    var available: [ShareDataKind] { ShareDataKind.allCases.filter { model($0) != nil } }

    func model(_ k: ShareDataKind) -> ShareDataModel? {
        if let c = crew {
            switch k {
            case .crewWeek:
                return ShareDataModel(eyebrow: "The crew this week", value: "\(c.workouts)",
                                      unit: c.workouts == 1 ? "workout" : "workouts",
                                      foot: "\(c.athletes) athletes")
            case .crewTrained:
                return ShareDataModel(eyebrow: "Trained this week", value: "\(c.trainedThisWeek)",
                                      unit: "of \(c.athletes)", foot: "athletes")
            case .crewAwards:
                guard c.awards > 0 else { return nil }
                return ShareDataModel(eyebrow: "Earned this week", value: "\(c.awards)",
                                      unit: c.awards == 1 ? "award" : "awards")
            case .date:
                return ShareDataModel(eyebrow: "", value: "WEEK OF " + c.weekStart.formatted(.dateTime.month(.abbreviated).day()).uppercased(),
                                      pill: true)
            case .stats:
                return ShareDataModel(eyebrow: "", value: "",
                                      cells: [ShareStatCell(value: "\(c.workouts)", label: "WORKOUTS"),
                                              ShareStatCell(value: "\(c.athletes)", label: "ATHLETES"),
                                              ShareStatCell(value: "\(c.awards)", label: "AWARDS")])
            case .workout:
                return ShareDataModel(eyebrow: "WEEK OF " + c.weekStart.formatted(.dateTime.month(.abbreviated).day()).uppercased(),
                                      value: "THE CREW THIS WEEK")
            case .topLift:
                return ShareDataModel(eyebrow: "", value: "\(c.trainedThisWeek) TRAINED THIS WEEK", pill: true)
            default:
                return nil
            }
        }
        let stats = store.shareStats
        switch k {
        case .pr:
            guard let pr = store.lastPRForShare else { return nil }
            var foot = "× \(pr.reps)"
            if !pr.isFirstEver && pr.gain >= 1 { foot += "  ·  e1RM +\(StatsUnits.weightText(pr.gain))" }
            return ShareDataModel(eyebrow: (pr.isFirstEver ? "FIRST RECORD" : "NEW PR"),
                                  value: "\(pr.exercise.uppercased()) \(StatsUnits.weightText(pr.weight, unit: false))",
                                  foot: foot)
        case .estMax:
            guard let ex = store.lastPRForShare?.exercise,
                  let best = store.personalRecords.filter({ $0.exercise == ex })
                    .max(by: { $0.estimatedOneRepMax < $1.estimatedOneRepMax }),
                  best.estimatedOneRepMax > 0 else { return nil }
            return ShareDataModel(eyebrow: "Estimated max · \(ex)",
                                  value: StatsUnits.weightText(best.estimatedOneRepMax, unit: false),
                                  unit: StatsUnits.weightLabel,
                                  foot: "from \(best.reps) × \(StatsUnits.weightText(best.weight))")
        case .barSpeed:
            guard let m = latestMotion, !m.reps.isEmpty else { return nil }
            let loss = m.velocityLossPct.map { "−\(Int($0.rounded()))% by rep \(m.repCount)" }
            return ShareDataModel(eyebrow: "Bar speed · \(m.exerciseName)",
                                  value: String(format: "%.2f", m.meanVelocity), unit: "m/s",
                                  foot: loss, series: m.reps.map { $0.meanVelocity }, watch: true)
        case .streak:
            let n = store.weekStreak
            guard n >= 1 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n)-WEEK STREAK", pill: true, icon: "flame.fill")
        case .today:
            guard stats.setCount > 0 || stats.totalWeight > 0 else { return nil }
            return ShareDataModel(eyebrow: workoutTitle,
                                  value: StatsUnits.weightText(stats.totalWeight, unit: false),
                                  unit: StatsUnits.weightLabel,
                                  foot: "\(stats.setCount) sets  ·  \(stats.duration)")
        case .volume:
            let recent = Array(store.pastWorkouts.prefix(6).reversed()).map(volume)
            guard stats.totalWeight > 0 || (recent.last ?? 0) > 0 else { return nil }
            return ShareDataModel(eyebrow: "Volume today",
                                  value: StatsUnits.weightText(stats.totalWeight > 0 ? stats.totalWeight : (recent.last ?? 0), unit: false),
                                  unit: StatsUnits.weightLabel,
                                  series: recent.count >= 2 ? recent : nil, bars: true)
        case .trend:
            let weeks = weeklyVolume(12)
            let used = weeks.filter { $0 > 0 }
            guard used.count >= 3 else { return nil }
            let first = average(Array(weeks.prefix(4)).filter { $0 > 0 })
            let last = average(Array(weeks.suffix(4)).filter { $0 > 0 })
            let pct = first > 0 ? (last - first) / first * 100 : 0
            return ShareDataModel(eyebrow: "12 weeks · volume",
                                  value: (pct >= 0 ? "+" : "−") + "\(Int(abs(pct).rounded()))%",
                                  foot: pct >= 0 ? "and climbing" : "deload weeks count too",
                                  series: weeks)
        case .award:
            guard let aw = store.awardToShare, aw.isShareable else { return nil }
            let s0 = aw.shareStats.first
            return ShareDataModel(eyebrow: aw.title.uppercased(), value: s0.map { "\($0.value) \($0.label)" } ?? aw.title,
                                  icon: aw.icon)
        case .date:
            return ShareDataModel(eyebrow: "", value: stats.date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased(),
                                  pill: true)
        case .topLift:
            let t = stats.topLift.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return ShareDataModel(eyebrow: "", value: t, pill: true)
        case .workout:
            return ShareDataModel(eyebrow: stats.date.formatted(.dateTime.month(.abbreviated).day()).uppercased(),
                                  value: workoutTitle.uppercased())
        case .heaviestSet:
            guard let w = sessionWorkout,
                  let best = loggedSets(w).max(by: { $0.1.loggedWeight ?? 0 < $1.1.loggedWeight ?? 0 }),
                  let wt = best.1.loggedWeight, wt > 0 else { return nil }
            return ShareDataModel(eyebrow: "Heaviest set · \(best.0)", value: StatsUnits.weightText(wt, unit: false),
                                  unit: StatsUnits.weightLabel, foot: "× \(best.1.loggedReps ?? 0)")
        case .totalReps:
            guard let w = sessionWorkout else { return nil }
            let n = loggedSets(w).reduce(0) { $0 + ($1.1.loggedReps ?? 0) }
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "Total reps", value: "\(n)", unit: "reps", foot: "\(loggedSets(w).count) sets")
        case .avgRPE:
            guard let w = sessionWorkout else { return nil }
            let r = loggedSets(w).compactMap { $0.1.rpe }
            guard !r.isEmpty else { return nil }
            return ShareDataModel(eyebrow: "Average RPE", value: String(format: "%.1f", average(r)), foot: "\(r.count) sets rated")
        case .exercises:
            guard let w = sessionWorkout else { return nil }
            let n = w.exercises.filter { e in e.sets.contains { $0.loggedReps != nil } }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) EXERCISE\(n == 1 ? "" : "S")", pill: true, icon: "list.bullet")
        case .sessionPRs:
            let n = store.personalRecords.filter { Calendar.current.isDate($0.date, inSameDayAs: stats.date) }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) NEW PR\(n == 1 ? "" : "S") TODAY", pill: true, icon: "trophy.fill")
        case .peakSpeed:
            let ms = dayMotions
            guard let peak = ms.map({ $0.peakVelocity }).max(), peak > 0 else { return nil }
            return ShareDataModel(eyebrow: "Peak bar speed", value: String(format: "%.2f", peak), unit: "m/s",
                                  foot: ms.max(by: { $0.peakVelocity < $1.peakVelocity })?.exerciseName, watch: true)
        case .tut:
            let secs = dayMotions.reduce(0) { $0 + $1.timeUnderTensionSec }
            guard secs > 0 else { return nil }
            return ShareDataModel(eyebrow: "Time under tension", value: "\(Int(secs) / 60):" + String(format: "%02d", Int(secs) % 60),
                                  foot: "\(dayMotions.reduce(0) { $0 + $1.repCount }) reps tracked", watch: true)
        case .depth:
            let c = dayMotions.compactMap { $0.travelConsistencyPct }
            guard !c.isEmpty else { return nil }
            return ShareDataModel(eyebrow: "Depth consistency", value: "\(Int(average(c).rounded()))%", foot: "rep to rep", watch: true)
        case .pausedReps:
            let n = dayMotions.reduce(0) { $0 + $1.pausedRepCount }
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) PAUSED REP\(n == 1 ? "" : "S")", pill: true, icon: "pause.fill")
        case .weekCount:
            let cal = Calendar.training
            let n = store.pastWorkouts.filter { cal.isSameTrainingWeek($0.date, Date()) }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "This week", value: "\(n)", unit: n == 1 ? "workout" : "workouts")
        case .monthCount:
            let n = store.pastWorkouts.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: Date().formatted(.dateTime.month(.wide)), value: "\(n)", unit: n == 1 ? "workout" : "workouts")
        case .weeklySets:
            let weeks = weeklySetCounts(12)
            guard weeks.filter({ $0 > 0 }).count >= 2 else { return nil }
            return ShareDataModel(eyebrow: "Sets per week", value: "\(Int(weeks.last ?? 0))", unit: "sets",
                                  foot: "12-week view", series: weeks, bars: true)
        case .consistency:
            let n = weeklyVolume(12).filter { $0 > 0 }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "Weeks trained", value: "\(n)/12", foot: "last 12 weeks")
        case .liftTrend:
            guard let ex = store.lastPRForShare?.exercise else { return nil }
            let prs = store.personalRecords.filter { $0.exercise == ex }.sorted { $0.date < $1.date }
            guard prs.count >= 2, let first = prs.first, let last = prs.last else { return nil }
            return ShareDataModel(eyebrow: "\(ex) · est. max", value: StatsUnits.weightText(last.estimatedOneRepMax, unit: false),
                                  unit: StatsUnits.weightLabel,
                                  foot: "+\(StatsUnits.weightText(max(0, last.estimatedOneRepMax - first.estimatedOneRepMax))) since \(first.date.formatted(.dateTime.month(.abbreviated)))",
                                  series: prs.map { $0.estimatedOneRepMax })
        case .big3:
            let best: (String) -> Double? = { name in
                store.personalRecords.filter { $0.exercise == name }.map { $0.estimatedOneRepMax }.max()
            }
            let sq = best("Back Squat"), bp = best("Bench Press"), dl = best("Deadlift")
            let parts = [("S", sq), ("B", bp), ("D", dl)].compactMap { k, v in v.map { (k, $0) } }
            guard parts.count >= 2 else { return nil }
            return ShareDataModel(eyebrow: "Big 3 total", value: StatsUnits.weightText(parts.reduce(0) { $0 + $1.1 }, unit: false),
                                  unit: StatsUnits.weightLabel,
                                  foot: parts.map { "\($0.0) \(StatsUnits.weightText($0.1, unit: false))" }.joined(separator: " · "))
        case .prsMonth:
            let n = store.personalRecords.filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) PR\(n == 1 ? "" : "S") THIS MONTH", pill: true, icon: "trophy")
        case .allTime:
            let n = store.pastWorkouts.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "All time", value: "\(n)", unit: n == 1 ? "session" : "sessions")
        case .lifetimeVolume:
            let v = store.pastWorkouts.reduce(0) { $0 + volume($1) }
            guard v > 0 else { return nil }
            let shown = StatsUnits.weight(v)
            let txt = shown >= 1_000_000 ? String(format: "%.1fM", shown / 1_000_000)
                    : shown >= 10_000 ? String(format: "%.0fK", shown / 1_000) : "\(Int(shown))"
            return ShareDataModel(eyebrow: "Lifetime volume", value: txt, unit: StatsUnits.weightLabel, foot: "moved, all time")
        case .prCount:
            let n = store.personalRecords.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) ALL-TIME PR\(n == 1 ? "" : "S")", pill: true, icon: "trophy.fill")
        case .awardsTotal:
            let n = store.awards.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) AWARD\(n == 1 ? "" : "S")", pill: true, icon: "rosette")
        case .checkIns:
            let n = store.checkIns.filter { $0.status != .draft }.count
            guard n > 0 else { return nil }
            return ShareDataModel(eyebrow: "", value: "\(n) CHECK-IN\(n == 1 ? "" : "S")", pill: true, icon: "checkmark.circle.fill")
        case .stats:
            return ShareDataModel(eyebrow: "", value: "",
                                  cells: [ShareStatCell(value: StatsUnits.weightText(stats.totalWeight, unit: false), label: StatsUnits.weightLabel.uppercased()),
                                          ShareStatCell(value: stats.duration, label: "TIME"),
                                          ShareStatCell(value: "\(stats.setCount)", label: "SETS")])
        default:
            return nil
        }
    }

    private var workoutTitle: String {
        store.workouts.first { Calendar.current.isDate($0.date, inSameDayAs: store.shareStats.date) }?.title ?? "Today's session"
    }

    /// The workout the share card is about (the session's date).
    private var sessionWorkout: Workout? {
        store.workouts.first { Calendar.current.isDate($0.date, inSameDayAs: store.shareStats.date) && $0.exercises.contains { e in e.sets.contains { $0.loggedReps != nil } } }
            ?? store.pastWorkouts.first
    }

    /// (exercise name, set) for every logged set.
    private func loggedSets(_ w: Workout) -> [(String, ExerciseSet)] {
        w.exercises.flatMap { e in e.sets.filter { $0.loggedReps != nil }.map { (e.name, $0) } }
    }

    /// Watch sets from the most recent day that has any.
    private var dayMotions: [SetMotion] {
        let all = SetMotionStore.shared.all
        guard let last = all.last else { return [] }
        return all.filter { Calendar.current.isDate($0.start, inSameDayAs: last.start) }
    }

    /// Oldest first.
    private func weeklySetCounts(_ n: Int) -> [Double] {
        let cal = Calendar.training
        let now = Date()
        return (0..<n).reversed().map { back in
            guard let day = cal.date(byAdding: .weekOfYear, value: -back, to: now) else { return 0 }
            return Double(store.pastWorkouts
                .filter { cal.isDate($0.date, equalTo: day, toGranularity: .weekOfYear) }
                .reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.filter { $0.loggedReps != nil }.count } })
        }
    }

    private var latestMotion: SetMotion? {
        let all = SetMotionStore.shared.all
        return all.last(where: { Calendar.current.isDateInToday($0.start) }) ?? all.last
    }

    private func volume(_ w: Workout) -> Double {
        w.exercises.reduce(0) { $0 + $1.sets.reduce(0) { $0 + $1.volume } }
    }

    /// Oldest first.
    private func weeklyVolume(_ n: Int) -> [Double] {
        let cal = Calendar.training
        let now = Date()
        return (0..<n).reversed().map { back in
            guard let day = cal.date(byAdding: .weekOfYear, value: -back, to: now) else { return 0 }
            return store.pastWorkouts
                .filter { cal.isDate($0.date, equalTo: day, toGranularity: .weekOfYear) }
                .reduce(0) { $0 + volume($1) }
        }
    }

    private func average(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
}

/// Stat stickers at the size of the originals: they sit on a photo, not over it.
/// Three looks (tap to cycle): solid accent, dark, and bare text.
struct ShareDataStickerView: View {
    let model: ShareDataModel
    let style: ShareDataStyle

    private var fg: Color { style == .solid ? Brand.onVolt : .white }
    private var accentInk: Color { style == .solid ? Brand.onVolt : Brand.volt }

    var body: some View {
        if model.pill {
            pill
        } else if !model.cells.isEmpty {
            boxed(statsRow, radius: 16)
        } else {
            boxed(card, radius: 16)
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            if let i = model.icon { Image(systemName: i).font(.system(size: 12, weight: .bold)).foregroundColor(accentInk) }
            Text(model.value).font(BrandFont.body(13, .heavy)).lineLimit(1)
        }
        .foregroundColor(fg)
        .padding(.horizontal, 14).frame(height: 36)
        .fixedSize()
        .background {
            switch style {
            case .solid: Capsule().fill(Brand.volt)
            case .glass: Capsule().fill(Color.black.opacity(0.65)).overlay(Capsule().stroke(Brand.volt, lineWidth: 2))
            case .plain: Color.clear
            }
        }
        .shadow(color: .black.opacity(style == .plain ? 0.7 : 0.3), radius: style == .plain ? 4 : 6, x: 0, y: 2)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.eyebrow.isEmpty || model.watch {
                HStack(spacing: 5) {
                    if let i = model.icon { Image(systemName: i).font(.system(size: 9, weight: .heavy)) }
                    Text(model.eyebrow.uppercased()).font(BrandFont.body(9, .heavy)).tracking(1.2).lineLimit(1)
                    if model.watch { Image(systemName: "applewatch").font(.system(size: 9, weight: .bold)) }
                }
                .foregroundColor(style == .solid ? fg.opacity(0.75) : accentInk)
            }
            if let s = model.series, s.count >= 2 {
                ShareSpark(values: s, bars: model.bars, color: accentInk)
                    .frame(width: 96, height: 20)
                    .padding(.vertical, 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(model.value).font(BrandFont.display(model.value.count > 12 ? 22 : 28)).lineLimit(1)
                if !model.unit.isEmpty { Text(model.unit).font(BrandFont.display(14)) }
            }
            .foregroundColor(fg)
            if let f = model.foot {
                Text(f).font(BrandFont.body(10, .heavy)).foregroundColor(fg.opacity(0.8)).lineLimit(1)
            }
        }
        .fixedSize()
    }

    private var statsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(model.cells.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.value).font(BrandFont.display(24)).foregroundColor(fg).lineLimit(1)
                    Text(c.label).font(BrandFont.body(8, .heavy)).tracking(1).foregroundColor(fg.opacity(0.7))
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func boxed<V: View>(_ v: V, radius: CGFloat) -> some View {
        switch style {
        case .solid:
            v.padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Brand.volt))
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
        case .glass:
            v.padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        case .plain:
            v.shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
        }
    }
}

/// A small line (or bar) chart for a data sticker.
struct ShareSpark: View {
    let values: [Double]
    var bars = false
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let lo = bars ? 0 : (values.min() ?? 0)
            let hi = values.max() ?? 1
            let span = max(hi - lo, 0.0001)
            if bars {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(i == values.count - 1 ? 1 : 0.45))
                            .frame(height: max(3, CGFloat((v - lo) / span) * h))
                    }
                }
                .frame(width: w, height: h, alignment: .bottom)
            } else {
                let pts: [CGPoint] = values.enumerated().map { i, v in
                    CGPoint(x: w * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                            y: h - 3 - (h - 6) * CGFloat((v - lo) / span))
                }
                ZStack {
                    Path { p in
                        guard let f = pts.first else { return }
                        p.move(to: CGPoint(x: f.x, y: h))
                        for q in pts { p.addLine(to: q) }
                        p.addLine(to: CGPoint(x: pts.last?.x ?? w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        guard let f = pts.first else { return }
                        p.move(to: f)
                        for q in pts.dropFirst() { p.addLine(to: q) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    if let l = pts.last {
                        Circle().fill(color).frame(width: 7, height: 7).position(l)
                    }
                }
            }
        }
    }
}

// MARK: - Text

enum ShareTextFont: String, CaseIterable, Identifiable {
    case classic = "Classic", strong = "Strong", modern = "Modern", typewriter = "Typewriter"
    var id: String { rawValue }
    func font(_ size: CGFloat) -> Font {
        switch self {
        case .classic: return .system(size: size * 0.8, weight: .bold)
        case .strong: return BrandFont.display(size)
        case .modern: return .system(size: size * 0.78, weight: .light)
        case .typewriter: return .custom("Courier-Bold", size: size * 0.74)
        }
    }
}

enum ShareTextBacking: CaseIterable, Equatable {
    case none, solid, accent
    var next: ShareTextBacking {
        switch self {
        case .none: return .solid
        case .solid: return .accent
        case .accent: return .none
        }
    }
}

enum ShareTextPalette {
    static let count = 8
    /// Slot 1 is the lifter's accent.
    static func color(_ i: Int) -> Color {
        switch i {
        case 1: return Brand.volt
        case 2: return .black
        case 3: return Color(red: 1.0, green: 0.18, blue: 0.58)
        case 4: return Color(red: 0.11, green: 0.36, blue: 0.84)
        case 5: return Color(red: 0.95, green: 0.63, blue: 0.24)
        case 6: return Color(red: 0.11, green: 0.60, blue: 0.34)
        case 7: return Color(red: 0.90, green: 0.22, blue: 0.23)
        default: return .white
        }
    }
    /// Black or white, whichever reads on `c`.
    static func onColor(_ c: Color) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }
}

struct ShareText: Equatable {
    var text: String = ""
    var font: ShareTextFont = .strong
    var color: Int = 0
    var backing: ShareTextBacking = .none
    var size: CGFloat = 46
}

struct ShareTextView: View {
    let t: ShareText

    var body: some View {
        let c = ShareTextPalette.color(t.color)
        let words = Text(t.text.isEmpty ? " " : t.text)
            .font(t.font.font(t.size))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 310)
            .fixedSize(horizontal: false, vertical: true)
        switch t.backing {
        case .none:
            words.foregroundColor(c).shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
        case .solid:
            words.foregroundColor(ShareTextPalette.onColor(c))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c))
        case .accent:
            words.foregroundColor(Brand.onVolt)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.volt))
        }
    }
}

// MARK: - One item on the card

/// Takes only what it draws (not the position), and is Equatable, so moving one sticker
/// never redraws the others, or itself.
struct ShareItemView: View, Equatable {
    let kind: ShareItemKind
    let model: ShareDataModel?

    var body: some View {
        switch kind {
        case .pack(let p):
            // Still stickers are a flat picture (cheap to move); only the moving ones stay live.
            if !p.animated, let img = SharePackImages.image(p) {
                Image(uiImage: img)
            } else {
                SharePackView(pack: p)
            }
        case .data(_, let s):
            if let m = model { ShareDataStickerView(model: m, style: s) }
        case .gif(let g):
            ShareGifImage(url: g.full, maxPixel: ShareGifImage.cardPixel, maxFrames: ShareGifImage.cardFrames)
                .aspectRatio(g.aspect, contentMode: .fit)
                .frame(width: g.isSticker ? 160 : 210)
                .clipShape(RoundedRectangle(cornerRadius: g.isSticker ? 0 : 14, style: .continuous))
        case .text(let t):
            ShareTextView(t: t)
        }
    }
}

// MARK: - Die-cut look: a white border around any shape, like a real sticker

extension View {
    func shareDieCut(_ w: CGFloat = 4, dark: Bool = false) -> some View {
        background {
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let a = Double(i) / 8 * 2 * .pi
                    self.brightness(dark ? -1 : 1)
                        .offset(x: CGFloat(cos(a)) * w, y: CGFloat(sin(a)) * w)
                }
            }
        }
    }
}

// MARK: - Looping motion, played by Core Animation (no per-frame body work).
// When the export pins a time, the same pose is computed for that moment instead.

private struct ShareSpin: ViewModifier {
    let period: Double
    @Environment(\.shareStickerTime) private var pinned
    @State private var on = false
    func body(content: Content) -> some View {
        if let t = pinned {
            content.rotationEffect(.degrees(t.truncatingRemainder(dividingBy: period) / period * 360))
        } else {
            content
                .rotationEffect(.degrees(on ? 360 : 0))
                .animation(.linear(duration: period).repeatForever(autoreverses: false), value: on)
                .onAppear { on = true }
        }
    }
}

private struct ShareFlicker: ViewModifier {
    @Environment(\.shareStickerTime) private var pinned
    @State private var on = false
    func body(content: Content) -> some View {
        if let t = pinned {
            content.scaleEffect(x: 1, y: 1 + 0.05 * CGFloat(sin(t * 9)), anchor: .bottom)
        } else {
            content
                .scaleEffect(x: on ? 0.98 : 1.02, y: on ? 1.06 : 0.96, anchor: .bottom)
                .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: on)
                .onAppear { on = true }
        }
    }
}

struct ShareBurst: Shape {
    var points = 12
    var inner: CGFloat = 0.8
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let R = min(r.width, r.height) / 2
        var p = Path()
        for i in 0..<(points * 2) {
            let a = Double(i) / Double(points * 2) * 2 * .pi - .pi / 2
            let rad = i.isMultiple(of: 2) ? R : R * inner
            let q = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}

struct ShareBanner: Shape {
    func path(in r: CGRect) -> Path {
        let n = r.height * 0.32
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - n, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + n, y: r.midY))
        p.closeSubpath()
        return p
    }
}

// MARK: - The pack as flat pictures
// Each sticker is drawn once (outline, shadow and all) into an image at export resolution and
// reused: the tray shows 28 of them without re-drawing a single layer per frame. Keyed by the
// accent, so a theme change redraws them in the new colour.

enum SharePackImages {
    private static var cache: [String: UIImage] = [:]

    static func image(_ p: SharePack) -> UIImage? {
        let key = "\(p.rawValue)#\(ThemeStore.shared.accent)"
        if let hit = cache[key] { return hit }
        let r = ImageRenderer(content: SharePackView(pack: p)
            .environment(\.shareStickerTime, 0)
            .padding(12))                       // room for the shadow
        r.scale = 3
        guard let img = r.uiImage else { return nil }
        cache[key] = img
        return img
    }

    /// Draw them ahead of time, a few per frame, so the tray opens instantly.
    static func prewarm() async {
        for p in SharePack.allCases {
            _ = image(p)
            await Task.yield()
        }
    }
}

// MARK: - The pack, drawn

struct SharePackView: View {
    let pack: SharePack

    private static let ink = Color(white: 0.07)
    private static let red = Color(red: 0.84, green: 0.16, blue: 0.22)
    private static let blue = Color(red: 0.11, green: 0.36, blue: 0.84)
    private static let gold = [Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.85, green: 0.6, blue: 0.12)]

    var body: some View {
        art.shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)
    }

    @ViewBuilder private var art: some View {
        switch pack {
        case .pr:
            ZStack {
                ShareBurst(points: 12, inner: 0.84).fill(Brand.volt)
                    .modifier(ShareSpin(period: 24))
                Text("PR").font(BrandFont.display(44)).foregroundColor(Brand.onVolt)
            }
            .frame(width: 96, height: 96)
            .shareDieCut(4)
        case .plate:
            ZStack {
                Circle().fill(Self.blue)
                Circle().inset(by: 10).stroke(Color(red: 0.05, green: 0.2, blue: 0.5), lineWidth: 3)
                Circle().fill(Color(white: 0.82)).frame(width: 26, height: 26)
                Circle().fill(Color(white: 0.45)).frame(width: 12, height: 12)
                Text(StatsUnits.isKg ? "20" : "45").font(BrandFont.display(19)).foregroundColor(.white)
                    .offset(y: -30)
            }
            .frame(width: 92, height: 92)
            .shareDieCut(4)
        case .barbell:
            // Heaviest plate innermost, always.
            HStack(spacing: 2) {
                sleeveEnd
                plateBar(Self.blue, 44)
                plateBar(Self.red, 56)
                Rectangle().fill(Color(white: 0.75)).frame(width: 44, height: 6)
                plateBar(Self.red, 56)
                plateBar(Self.blue, 44)
                sleeveEnd
            }
            .padding(4)
            .shareDieCut(4)
        case .crown:
            Image(systemName: "crown.fill").font(.system(size: 62))
                .foregroundStyle(LinearGradient(colors: Self.gold, startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    HStack(spacing: 6) {
                        ForEach([Self.red, Color.orange, Color.yellow, Color.green, Self.blue], id: \.self) { c in
                            Circle().fill(c).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.bottom, 14)
                }
                .shareDieCut(4)
        case .oneMore:
            Text("ONE MORE").font(BrandFont.display(28)).foregroundColor(Brand.volt)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Capsule().fill(Self.ink))
                .rotationEffect(.degrees(-4))
                .shareDieCut(4)
        case .flame:
            Image(systemName: "flame.fill").font(.system(size: 70))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.2), Color(red: 1, green: 0.45, blue: 0.1), Self.red],
                                                startPoint: .top, endPoint: .bottom))
                .modifier(ShareFlicker())
                .shareDieCut(4)
        case .kettlebell:
            ZStack {
                Circle().stroke(Self.ink, lineWidth: 10).frame(width: 40, height: 40).offset(y: -24)
                Circle().fill(Self.ink).frame(width: 66, height: 66).offset(y: 8)
                Circle().trim(from: 0.55, to: 0.72).stroke(Brand.volt.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48).offset(y: 8)
            }
            .frame(width: 80, height: 100)
            .shareDieCut(4)
        case .noRep:
            Text("NO REP").font(BrandFont.display(30)).foregroundColor(Self.red)
                .padding(.horizontal, 12).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.red, lineWidth: 3))
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .rotationEffect(.degrees(-10))
        case .chalk:
            ZStack {
                Image(systemName: "hand.raised.fill").font(.system(size: 62)).foregroundColor(Color(white: 0.88))
                ForEach(0..<6, id: \.self) { i in
                    let pts: [(CGFloat, CGFloat, CGFloat)] = [(-38, -30, 4), (36, -36, 3), (42, 2, 5), (-42, 8, 3), (30, 34, 3), (-30, 36, 4)]
                    Circle().fill(Color.white.opacity(0.9)).frame(width: pts[i].2, height: pts[i].2)
                        .offset(x: pts[i].0, y: pts[i].1)
                }
            }
            .frame(width: 100, height: 96)
            .shareDieCut(3, dark: true)
        case .legDay:
            Text("LEG DAY").font(BrandFont.display(28)).foregroundColor(.white)
                .padding(.horizontal, 22).padding(.vertical, 6)
                .background(ShareBanner().fill(Color(red: 0.54, green: 0.31, blue: 0.75)))
                .shareDieCut(4)
        case .timer:
            Group {
                ZStack {
                    Circle().fill(Color(white: 0.96))
                    Circle().inset(by: 8).stroke(Color(white: 0.8), lineWidth: 2)
                    Circle().trim(from: 0, to: 0.18).stroke(Brand.volt, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(14)
                    Capsule().fill(Self.ink).frame(width: 5, height: 26).offset(y: -12)
                        .frame(width: 76, height: 76)
                        .modifier(ShareSpin(period: 6))
                    Circle().fill(Self.ink).frame(width: 9, height: 9)
                }
                .frame(width: 76, height: 76)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.96)).frame(width: 18, height: 10).offset(y: -9)
                }
            }
            .shareDieCut(4)
        case .big:
            Text("BIG").font(BrandFont.display(70)).foregroundColor(Brand.volt)
                .shareDieCut(2, dark: true)
                .shareDieCut(5)
        case .lightWeight:
            VStack(spacing: -10) {
                Text("LIGHT")
                Text("WEIGHT")
            }
            .font(BrandFont.display(38)).foregroundColor(.white)
            .rotationEffect(.degrees(-6))
            .shareDieCut(2, dark: true)
            .shareDieCut(4)
        case .logo:
            Image("logoVolt").renderingMode(.template).resizable().scaledToFit()
                .foregroundColor(Brand.volt)
                .frame(width: 130)
        case .queens:
            Text("QUEENS").font(BrandFont.display(40))
                .foregroundStyle(LinearGradient(colors: Self.rainbow, startPoint: .leading, endPoint: .trailing))
                .shareDieCut(2, dark: true)
                .shareDieCut(4)
        case .beastMode:
            word(["BEAST", "MODE"], fg: .white, bg: Self.red, tilt: -5)
        case .sendIt:
            word(["SEND IT"], fg: Brand.onVolt, bg: Brand.volt, tilt: 4)
        case .gains:
            Text("GAINS").font(BrandFont.display(46)).foregroundColor(Brand.volt)
                .shareDieCut(2, dark: true).shareDieCut(4)
        case .newPB:
            word(["NEW PR"], fg: .white, bg: Self.blue, tilt: -3)
        case .lockout:
            word(["LOCKOUT"], fg: Brand.volt, bg: Self.ink, tilt: 3)
        case .restDay:
            word(["REST", "DAY"], fg: Self.ink, bg: Color(red: 0.75, green: 0.88, blue: 1.0), tilt: -4)
        case .heart:
            Image(systemName: "heart.fill").font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: Self.rainbow, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shareDieCut(4)
        case .trophy:
            Image(systemName: "trophy.fill").font(.system(size: 60))
                .foregroundStyle(LinearGradient(colors: Self.gold, startPoint: .top, endPoint: .bottom))
                .shareDieCut(4)
        case .dumbbell:
            Image(systemName: "dumbbell.fill").font(.system(size: 54)).foregroundColor(Self.ink)
                .rotationEffect(.degrees(-20))
                .shareDieCut(4)
        case .bolt:
            Image(systemName: "bolt.fill").font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.3), Color(red: 1, green: 0.6, blue: 0.1)], startPoint: .top, endPoint: .bottom))
                .shareDieCut(4)
        case .muscle:
            Text("💪").font(.system(size: 64)).shareDieCut(4)
        case .sweat:
            Text("💦").font(.system(size: 60)).shareDieCut(4)
        case .hundred:
            Text("💯").font(.system(size: 62)).shareDieCut(4)
        }
    }

    private static let rainbow = [Color(hex: 0xE63946), Color(hex: 0xF2A03D), Color(hex: 0xE9D948),
                                  Color(hex: 0x3FA35B), Color(hex: 0x3D6FE0), Color(hex: 0x8A4FBF)]

    /// A word (or two) on a tilted colour block with the white sticker edge.
    private func word(_ lines: [String], fg: Color, bg: Color, tilt: Double) -> some View {
        VStack(spacing: -6) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(BrandFont.display(30)).foregroundColor(fg)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
        .rotationEffect(.degrees(tilt))
        .shareDieCut(4)
    }

    private var sleeveEnd: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.7)).frame(width: 12, height: 9)
    }

    private func plateBar(_ c: Color, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: h)
    }
}
