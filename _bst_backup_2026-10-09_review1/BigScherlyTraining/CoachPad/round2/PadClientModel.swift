import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: what the Clients workspace knows about each client (Oct 9, 2026)
//
// Everything here is worked out from data the app already loads (workouts, check-ins, programs,
// threads, supplement adherence). The one new thing is each client's "renews on" date, which the
// coach types in; it's kept on the server in the coach's settings (key "clientRenewals"), the same
// store the saved replies use, so no server change was needed.
// Synchronized folder: no target step needed.

// MARK: Renewal dates

@MainActor
final class PadRenewals: ObservableObject {
    static let shared = PadRenewals()
    static let key = "clientRenewals"
    @Published private(set) var dates: [String: Date] = [:]
    private var loaded = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.training.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: "bst_pad_renewals") as? [String: String] {
            dates = d.compactMapValues { Self.stamp.date(from: $0) }
        }
    }

    func load(store: AppStore) async {
        guard store.isLive, !loaded else { return }
        loaded = true
        guard let s = try? await APIClient.shared.trainerSetting(Self.key), let json = s.json,
              let map = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return }
        dates = map.compactMapValues { Self.stamp.date(from: $0) }
        cache()
    }

    func set(_ date: Date?, for clientId: String, store: AppStore) {
        if let date { dates[clientId] = Calendar.training.startOfDay(for: date) } else { dates[clientId] = nil }
        cache()
        guard store.isLive else { return }
        let map = dates.mapValues { Self.stamp.string(from: $0) }
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else { return }
        Task { _ = try? await APIClient.shared.saveTrainerSetting(Self.key, json: json) }
    }

    private func cache() {
        UserDefaults.standard.set(dates.mapValues { Self.stamp.string(from: $0) }, forKey: "bst_pad_renewals")
    }
}

// MARK: One client, worked out

enum PadRisk: Int, Comparable {
    case low, watch, high
    static func < (a: PadRisk, b: PadRisk) -> Bool { a.rawValue < b.rawValue }
    var label: String { self == .high ? "High" : (self == .watch ? "Watch" : "Low") }
}

enum PadWeekMark {
    case sent, missed, waiting, open, before   // before = they weren't a client yet
    /// A check-in came in that week (answered or still waiting).
    var isSent: Bool {
        switch self { case .sent, .waiting: return true; default: return false }
    }
    /// The week counts toward the on-time rate (they were a client and the week is over or answered).
    var counts: Bool {
        switch self { case .sent, .waiting, .missed: return true; default: return false }
    }
    var fill: Color {
        switch self {
        case .sent: return Pad.volt
        case .missed: return Pad.orange
        case .before: return Pad.raised.opacity(0.5)
        default: return Color.clear
        }
    }
    var stroke: Color {
        switch self {
        case .waiting: return Pad.volt
        case .open: return Pad.line2
        default: return Color.clear
        }
    }
}

struct PadLiftTrend {
    let lift: String          // "Back Squat"
    let change: Double?       // e1RM, last 4 weeks vs the 4 before (lb); nil = nothing to compare yet
    let current: Double
    var short: String { lift.replacingOccurrences(of: "Back ", with: "").replacingOccurrences(of: " Press", with: "") }
    var isFlat: Bool { change.map { abs($0) < 2.5 } ?? false }
    var delta: Double { change ?? 0 }
}

struct PadClientFacts: Identifiable {
    let client: RosterItem
    var id: String { client.id }

    var weekly: [Int] = []                 // sessions done per week, 8 weeks, oldest first (last = this week)
    var plannedThisWeek = 0
    var doneThisWeek = 0
    var usualPerWeek: Double = 0
    var lastTrained: Date?
    var daysSince: Int?
    var usualGap: Double?
    var missedStreak = 0
    var missedOfLast4 = 0
    var done28 = 0
    var planned28 = 0
    var donePrev28 = 0
    var lastCheckIn: APICheckIn?
    var waiting: APICheckIn?
    var checkInLateDays = 0
    var checkInWeeks: [PadWeekMark] = []   // 12, oldest first
    var lift: PadLiftTrend?
    var assignment: APIAssignment?
    var endingSoon = false
    var nothingAfter = false
    var renewsOn: Date?
    var isNew = false
    var firstSeen: Date?
    var worry: String?                      // the check-in words that sounded worrying
    var shorterAsk = false                  // last check-in asked for shorter/fewer sessions
    var score = 0
    var risk: PadRisk = .low
    var reasons: [String] = []
    var needs = 0                           // "needs you most" sort key
    var flagged = false

    var name: String { client.name }
    var first: String { client.name.firstName }
    var paused: Bool { assignment == nil && (daysSince ?? 0) > 45 && planned28 == 0 }

    var renewDays: Int? {
        guard let r = renewsOn else { return nil }
        return Calendar.training.dateComponents([.day], from: Calendar.training.startOfDay(for: Date()), to: r).day
    }

    /// The status line on the roster.
    var status: (text: String, color: Color, sub: String) {
        if risk == .high {
            return ("At risk", Pad.orange, daysSince.map { "\($0) days since trained" } ?? "\(missedStreak) missed in a row")
        }
        if let w = waiting {
            return ("Reply waiting", Pad.volt, flagged ? "Flagged answer" : "sent \(w.date.padAgo)")
        }
        if client.unreadMessages > 0 { return ("\(client.unreadMessages) unread", Pad.volt, "in chat") }
        if endingSoon, nothingAfter, let a = assignment {
            let d = Calendar.training.dateComponents([.day], from: Date(), to: a.endDate).day ?? 0
            return ("Program ending", Pad.blue, "\(max(d, 0).plural("day")), nothing after")
        }
        if isNew, let f = firstSeen { return ("New", Pad.blue, "since \(f.formatted(.dateTime.month(.abbreviated).day()))") }
        // "Slipping" is about training only (missed or fewer sessions); not a risk label.
        if risk == .watch, missedOfLast4 >= 1 || missedStreak >= 1 || (daysSince ?? 0) >= 5 {
            return ("Slipping", Pad.orange.opacity(0.65), reasons.first.map { Self.shorten($0) } ?? "")
        }
        if paused { return ("Paused", Pad.faint, "no plan") }
        if let d = daysSince, d == 0 { return ("On track", Pad.green, "trained today") }
        return ("On track", Pad.green, daysSince.map { "trained \($0 == 1 ? "yesterday" : "\($0) days ago")" } ?? "")
    }

    private static func shorten(_ s: String) -> String {
        let c = s.split(separator: ".").first.map(String.init) ?? s
        return c.count > 30 ? String(c.prefix(29)) + "…" : c
    }
}

@MainActor
enum PadInsights {
    static let worryWords = ["busy", "insane", "stress", "exhaust", "overwhelm", "money", "cancel", "quit", "pause",
                             "break from", "too much", "can't keep", "cant keep", "burnt", "burned out", "behind"]
    static let shorterWords = ["shorter", "less time", "fewer", "cut back", "45 min", "30 min"]

    static func facts(_ c: RosterItem, store: AppStore) -> PadClientFacts {
        let cal = Calendar.training
        let data = PadData.shared
        let today = cal.startOfDay(for: Date())
        var f = PadClientFacts(client: c)

        // Sessions
        let sessions = data.sessions(client: c).sorted { $0.day < $1.day }
        let weekStart = cal.startOfWeek(for: Date())
        f.weekly = (0..<8).map { i in
            let s = cal.date(byAdding: .weekOfYear, value: i - 7, to: weekStart) ?? weekStart
            let e = cal.date(byAdding: .day, value: 7, to: s) ?? s
            return sessions.filter { $0.isDone && $0.day >= s && $0.day < e }.count
        }
        let thisWeek = sessions.filter { $0.day >= weekStart && $0.day < (cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart) }
        f.plannedThisWeek = thisWeek.count
        f.doneThisWeek = thisWeek.filter { $0.isDone }.count
        let prior = Array(f.weekly.prefix(7)).filter { $0 > 0 }
        f.usualPerWeek = prior.isEmpty ? 0 : Double(prior.reduce(0, +)) / Double(prior.count)

        let doneDays = sessions.filter { $0.isDone }.map { $0.finish.map { cal.startOfDay(for: $0) } ?? $0.day }
        f.lastTrained = doneDays.max()
        f.daysSince = f.lastTrained.map { cal.dateComponents([.day], from: $0, to: today).day ?? 0 }
        f.firstSeen = sessions.first?.day
        if let fs = f.firstSeen { f.isNew = (cal.dateComponents([.day], from: fs, to: today).day ?? 99) < 28 }
        let since8 = cal.date(byAdding: .weekOfYear, value: -8, to: today) ?? today
        let recentDays = Array(Set(doneDays.filter { $0 >= since8 })).sorted()
        if recentDays.count >= 3 {
            let gaps = zip(recentDays.dropFirst(), recentDays).map { Double(cal.dateComponents([.day], from: $1, to: $0).day ?? 0) }
            f.usualGap = gaps.reduce(0, +) / Double(gaps.count)
        }
        let past = sessions.filter { $0.day < today }
        for s in past.reversed() { if s.isMissed { f.missedStreak += 1 } else if s.isDone { break } }
        f.missedOfLast4 = past.suffix(4).filter { $0.isMissed }.count
        let d28 = cal.date(byAdding: .day, value: -28, to: today) ?? today
        let d56 = cal.date(byAdding: .day, value: -56, to: today) ?? today
        f.done28 = sessions.filter { $0.isDone && $0.day >= d28 && $0.day <= today }.count
        f.planned28 = sessions.filter { $0.day >= d28 && $0.day < today }.count + sessions.filter { cal.isDateInToday($0.day) && $0.isDone }.count
        f.donePrev28 = sessions.filter { $0.isDone && $0.day >= d56 && $0.day < d28 }.count

        // Check-ins
        let cis = (CoachData.shared.checkIns[c.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }
        f.lastCheckIn = cis.last
        f.waiting = store.checkInQueue.first { $0.clientId == c.id }?.checkIn
        if let w = f.waiting { f.flagged = PadCheckInReview.flaggedLine(w) != nil }
        if f.waiting == nil, let l = cis.last {
            f.checkInLateDays = max(0, (cal.dateComponents([.day], from: cal.startOfDay(for: l.date), to: today).day ?? 0) - 7)
        }
        let startedOn = [f.firstSeen, cis.first?.date].compactMap { $0 }.min()
        f.checkInWeeks = (0..<12).map { i in
            let s = cal.date(byAdding: .weekOfYear, value: i - 11, to: weekStart) ?? weekStart
            let e = cal.date(byAdding: .day, value: 7, to: s) ?? s
            if let st = startedOn, e <= cal.startOfDay(for: st) { return .before }
            if startedOn == nil { return .before }
            let inWeek = cis.filter { $0.date >= s && $0.date < e }
            if let w = f.waiting, w.date >= s, w.date < e { return .waiting }
            if !inWeek.isEmpty { return .sent }
            return i == 11 ? .open : .missed
        }
        if let l = cis.last {
            let text = l.fields.filter { Double($0.value) == nil }.map { $0.value }
            if let hit = text.first(where: { t in worryWords.contains { t.lowercased().contains($0) } }) {
                f.worry = hit.count > 70 ? String(hit.prefix(68)) + "…" : hit
            }
            f.shorterAsk = text.contains { t in shorterWords.contains { t.lowercased().contains($0) } }
        }

        // Lifts
        f.lift = liftTrend(clientId: c.id)

        // Program
        let mine = data.assignments.filter { $0.clientId == c.id }
        f.assignment = mine.filter { $0.status.lowercased() != "ended" && $0.endDate >= today }.min { $0.endDate < $1.endDate }
        if let a = f.assignment {
            let left = cal.dateComponents([.day], from: today, to: a.endDate).day ?? 99
            f.endingSoon = left <= 14
            f.nothingAfter = !mine.contains { $0.id != a.id && $0.startDate >= a.endDate.addingTimeInterval(-86_400) }
                && !sessions.contains { $0.day > a.endDate }
        }

        f.renewsOn = PadRenewals.shared.dates[c.id]
        score(&f)
        return f
    }

    static func liftTrend(clientId: String) -> PadLiftTrend? {
        let cal = Calendar.training
        let ws = PadData.shared.workouts[clientId] ?? []
        let today = Date()
        let d28 = cal.date(byAdding: .day, value: -28, to: today) ?? today
        let d56 = cal.date(byAdding: .day, value: -56, to: today) ?? today
        let names = ws.filter { $0.completed && $0.date >= d56 }.flatMap { $0.exercises.map { $0.name } }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let main = counts.sorted { $0.value > $1.value }.prefix(4).map { $0.key }
        let trends: [PadLiftTrend] = main.compactMap { n in
            let h = ProgressEngine.history(for: n, workouts: ws)
            let now = h.filter { $0.date >= d28 }.map { $0.estimatedOneRepMax }.max()
            let before = h.filter { $0.date >= d56 && $0.date < d28 }.map { $0.estimatedOneRepMax }.max()
            guard let now, now > 0 else { return nil }
            return PadLiftTrend(lift: n, change: before.map { now - $0 }, current: now)
        }
        let moving = trends.filter { $0.change != nil && !$0.isFlat }.max { abs($0.delta) < abs($1.delta) }
        return moving ?? trends.first
    }

    /// Flight risk: points for each warning sign; the reasons are written the way you'd say them.
    static func score(_ f: inout PadClientFacts) {
        var pts = 0
        var why: [String] = []
        let usual = f.usualGap ?? 2.5
        if let d = f.daysSince, d >= 5, Double(d) >= usual * 2.5 {
            pts += d >= 9 ? 35 : 25
            why.append("\(d) days since training. Usual gap is \(Int(usual.rounded())).")
        }
        if f.missedStreak >= 2 {
            pts += f.missedStreak >= 3 ? 22 : 15
            why.append("Missed \(f.missedStreak) planned sessions in a row.")
        } else if f.missedOfLast4 >= 1, f.usualPerWeek > 0 {
            pts += 6
            why.append("Missed \(f.missedOfLast4) of the last 4 sessions.")
        }
        if f.usualPerWeek >= 1, Double(f.weekly.suffix(2).reduce(0, +)) / 2 < f.usualPerWeek * 0.6 {
            pts += 10
            let recent2: Int = f.weekly.suffix(2).reduce(0, +)
            why.append("Training less: \(recent2.plural("session")) in 2 weeks, usually \(Int((f.usualPerWeek * 2).rounded())).")
        }
        if f.checkInLateDays >= 2 {
            pts += f.checkInLateDays >= 4 ? 15 : 8
            why.append("Check-in \(f.checkInLateDays) days late.")
        }
        if f.endingSoon && f.nothingAfter, let a = f.assignment {
            pts += 10
            why.append("Program ends \(a.endDate.formatted(.dateTime.month(.abbreviated).day())) with nothing after it.")
        }
        if let w = f.worry {
            pts += 10
            why.append("Last check-in: “\(w)”")
        }
        if let r = f.renewDays, r >= 0, r <= 30, pts >= 15 {
            pts += 15
            why.append("Renews \(f.renewsOn!.formatted(.dateTime.month(.abbreviated).day())), in \(r.plural("day")).")
        }
        f.score = min(pts, 100)
        // "At risk" only when it's real: plenty of warning signs AND they've actually stopped training
        // (a long gap or a run of missed sessions). Late check-ins or a renewal date alone never count.
        let stopped = (f.daysSince.map { $0 >= 7 && Double($0) >= usual * 2.5 } ?? false) || f.missedStreak >= 2
        f.risk = (pts >= 55 && stopped) ? .high : (pts >= 22 ? .watch : .low)
        f.reasons = why

        var n = 0
        if let w = f.waiting { n += 50 + min(Int(Date().timeIntervalSince(w.date) / 3600), 40) }
        if f.client.unreadMessages > 0 { n += 40 }
        if f.risk == .high { n += 70 } else if f.risk == .watch { n += 25 }
        if f.endingSoon && f.nothingAfter { n += 20 }
        if f.isNew { n += 5 }
        f.needs = n
    }

    // MARK: Things worth noticing (the coach layer)

    struct Notice: Identifiable {
        var id: String { icon + text }
        let icon: String
        let tint: Color
        let text: String
        let aside: String
    }

    static func notices(_ f: PadClientFacts) -> [Notice] {
        let data = PadData.shared
        let cal = Calendar.training
        var out: [Notice] = []
        if let l = f.lift, l.isFlat {
            out.append(Notice(icon: "chart.bar", tint: Pad.orange,
                              text: "\(l.short) has been flat for 4 weeks at \(StatsUnits.weightText(l.current)).",
                              aside: "Worth a lighter week or a new rep range."))
        } else if let l = f.lift, let c = l.change, c > 0 {
            out.append(Notice(icon: "arrow.up.right", tint: Pad.voltText,
                              text: "\(l.short) up \(StatsUnits.weightText(c)) in 4 weeks.",
                              aside: "e1RM \(StatsUnits.weightText(l.current))."))
        } else if let l = f.lift, let c = l.change, c < 0 {
            out.append(Notice(icon: "arrow.down.right", tint: Pad.orange,
                              text: "\(l.short) down \(StatsUnits.weightText(abs(c))) in 4 weeks.",
                              aside: "Fatigue, sleep or food: the check-ins may say which."))
        }
        if f.missedStreak >= 2, f.shorterAsk {
            out.append(Notice(icon: "clock", tint: Pad.mute,
                              text: "The misses started after \(f.first) asked for shorter sessions.",
                              aside: "Shorter sessions might bring them back."))
        }
        let sessions = data.sessions(client: f.client).filter { $0.isDone }.sorted { $0.day < $1.day }
        if let last = sessions.last {
            if last.setsTotal > 0, last.setsLogged < last.setsTotal {
                out.append(Notice(icon: "list.bullet", tint: Pad.mute,
                                  text: "Logged \(last.setsLogged) of \(last.setsTotal) sets in \(last.title) on \(last.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).",
                                  aside: "Skipped sets often come before missed sessions."))
            }
            let mins = sessions.compactMap { s -> Double? in
                guard let a = s.start, let b = s.finish, b > a else { return nil }
                return b.timeIntervalSince(a) / 60
            }
            if mins.count >= 4, let a = last.start, let b = last.finish {
                let usual = mins.dropLast().sorted()[mins.count / 2 - 1]
                let this = b.timeIntervalSince(a) / 60
                if usual - this >= 15 {
                    out.append(Notice(icon: "timer", tint: Pad.mute,
                                      text: "Last session was \(Int(this)) minutes, about \(Int(usual - this)) shorter than usual.",
                                      aside: ""))
                }
            }
        }
        let prs = data.prsThisWeek(clientId: f.id)
        if let p = prs.first {
            out.append(Notice(icon: "trophy", tint: Pad.voltText,
                              text: "\(p.exercise) PR this week: \(StatsUnits.weightText(p.estimatedOneRepMax)) e1RM.",
                              aside: "A good thing to mention in your reply."))
        }
        if let v = velocityDrop(clientId: f.id) {
            out.append(Notice(icon: "speedometer", tint: Pad.orange, text: v.0, aside: v.1))
        }
        // Bodyweight over 4 weeks, from check-ins.
        let cis = (CoachData.shared.checkIns[f.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }
        let since = cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let bw = cis.filter { $0.date >= since }.compactMap { bodyweight($0) }
        if bw.count >= 2, let a = bw.first, let b = bw.last, abs(b - a) >= 1 {
            out.append(Notice(icon: "scalemass", tint: Pad.mute,
                              text: "Bodyweight \(b > a ? "up" : "down") \(StatsUnits.weightText(abs(b - a))) in 4 weeks.",
                              aside: "Now \(StatsUnits.weightText(b))."))
        }
        return Array(out.prefix(4))
    }

    /// Bar speed on a main lift's top sets fell more than usual in the latest session.
    static func velocityDrop(clientId: String) -> (String, String)? {
        let ms = PadData.shared.motion[clientId] ?? []
        for lift in ["Back Squat", "Bench Press", "Deadlift"] {
            let byWorkout = Dictionary(grouping: ms.filter { $0.exerciseName == lift && !$0.reps.isEmpty }, by: { $0.workoutId })
            let ordered = byWorkout.values.map { $0.sorted { $0.start < $1.start } }.sorted { ($0.first?.start ?? .distantPast) < ($1.first?.start ?? .distantPast) }
            guard let last = ordered.last, last.count >= 3, let a = last.first?.meanVelocity, let b = last.last?.meanVelocity, a > 0 else { continue }
            let drop = (a - b) / a
            guard drop >= 0.18 else { continue }
            var aside = ""
            if ordered.count >= 2, let p = ordered.dropLast().last, let pa = p.first?.meanVelocity, let pb = p.last?.meanVelocity, pa > 0 {
                aside = "The time before it fell \(Int(((pa - pb) / pa * 100).rounded()))%."
            }
            return ("\(lift.replacingOccurrences(of: "Back ", with: "")) bar speed fell from \(String(format: "%.2f", a)) to \(String(format: "%.2f", b)) m/s across the last session’s sets.", aside)
        }
        return nil
    }

    static func bodyweight(_ ci: APICheckIn) -> Double? {
        guard let f = ci.fields.first(where: { $0.cleanLabel.lowercased().contains("weight") }), let v = Double(f.value) else { return nil }
        return v
    }

    // MARK: Suggested next

    struct Suggestion: Identifiable {
        var id: String { title }
        let title: String
        let section: PadClientSection
    }

    static func suggestions(_ f: PadClientFacts) -> [Suggestion] {
        var out: [Suggestion] = []
        if f.client.unreadMessages > 0 { out.append(Suggestion(title: "Reply to \(f.first) in chat", section: .chat)) }
        if f.waiting != nil { out.append(Suggestion(title: "Answer this week’s check-in", section: .checkins)) }
        if f.missedStreak >= 2 && f.client.unreadMessages == 0 { out.append(Suggestion(title: "Message \(f.first): checking in", section: .chat)) }
        if f.endingSoon && f.nothingAfter { out.append(Suggestion(title: "Plan what comes after \(f.assignment?.programName ?? "the program")", section: .program)) }
        if f.shorterAsk && f.missedStreak >= 1 { out.append(Suggestion(title: "Offer shorter sessions", section: .workouts)) }
        if let r = f.renewDays, r >= 0, r <= 30 { out.append(Suggestion(title: "Talk about renewing before \(f.renewsOn!.formatted(.dateTime.month(.abbreviated).day()))", section: .chat)) }
        if out.isEmpty { out.append(Suggestion(title: "Look over the last workout", section: .workouts)) }
        return Array(out.prefix(3))
    }
}

// MARK: The business, across every client

enum PadBizPane: String, CaseIterable, Identifiable {
    case risk, sessions, checkins, ending, unread, prs, avgDays, newInactive, supplements
    var id: String { rawValue }
    var title: String {
        switch self {
        case .risk: return "Flight risk"
        case .sessions: return "Sessions, all clients"
        case .checkins: return "Check-ins"
        case .ending: return "Programs ending"
        case .unread: return "Unread messages, wait time"
        case .prs: return "PRs this month"
        case .avgDays: return "Average days since trained"
        case .newInactive: return "New and inactive clients"
        case .supplements: return "Supplement adherence"
        }
    }
    static let defaultOn: [PadBizPane] = [.risk, .sessions, .checkins, .ending, .unread, .prs]
}

/// Which insight panes show, and in what order. Kept on this iPad.
@MainActor
final class PadBizPrefs: ObservableObject {
    static let shared = PadBizPrefs()
    @Published var order: [PadBizPane] { didSet { save() } }
    @Published var on: Set<PadBizPane> { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        let o = (d.stringArray(forKey: "bst_pad_biz_order") ?? []).compactMap { PadBizPane(rawValue: $0) }
        let all = o + PadBizPane.allCases.filter { !o.contains($0) }
        order = all
        if let s = d.stringArray(forKey: "bst_pad_biz_on") { on = Set(s.compactMap { PadBizPane(rawValue: $0) }) }
        else { on = Set(PadBizPane.defaultOn) }
    }
    var shown: [PadBizPane] { order.filter { on.contains($0) } }
    private func save() {
        UserDefaults.standard.set(order.map { $0.rawValue }, forKey: "bst_pad_biz_order")
        UserDefaults.standard.set(on.map { $0.rawValue }, forKey: "bst_pad_biz_on")
    }
}

// MARK: The client's sections

enum PadClientSection: String, CaseIterable, Identifiable {
    case overview, awards, chat, checkins, macros, notes, photos, program, stats, supplements, workouts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .awards: return "Awards"
        case .chat: return "Chat"
        case .checkins: return "Check-ins"
        case .macros: return "Macros"
        case .notes: return "Notes"
        case .photos: return "Photos"
        case .program: return "Program"
        case .stats: return "Stats"
        case .supplements: return "Supplements"
        case .workouts: return "Workouts"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .awards: return "trophy"
        case .chat: return "bubble.left"
        case .checkins: return "checkmark.square"
        case .macros: return "chart.pie"
        case .notes: return "book.closed"
        case .photos: return "camera"
        case .program: return "list.bullet.rectangle"
        case .stats: return "chart.bar"
        case .supplements: return "pills"
        case .workouts: return "dumbbell"
        }
    }
    /// Overview first, then the rest alphabetically (the enum is already in that order).
    static var ordered: [PadClientSection] { allCases }
}
