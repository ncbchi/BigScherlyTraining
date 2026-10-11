import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Targets (Oct 10, 2026)
//
// Things a client works toward. The coach sets a target with a finish line and a prize; the iPad
// works out the progress from what's already loaded (sessions, lifts, check-ins) and shows it on the
// client's Wins, the Wins page and Today. Stored as the coach setting `clientTargets` (and the
// coach's templates as `targetTemplates`), so no DLL change. The phone's "Working toward" shelf and
// the award it mints come in the next step, with a client endpoint for the same data.
// Synchronized folder: no target step needed.

// MARK: Model

enum PadTargetKind: String, Codable, CaseIterable, Identifiable {
    case lift, sessions, streak, checkins, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lift: return "Lift"
        case .sessions: return "Sessions"
        case .streak: return "Streak"
        case .checkins: return "Check-ins"
        case .manual: return "Manual"
        }
    }
    var blurb: String {
        switch self {
        case .lift: return "A weight on the bar, or an estimated 1RM."
        case .sessions: return "A number of sessions, within a stretch of weeks or by a date."
        case .streak: return "Weeks in a row with at least one session."
        case .checkins: return "Check-ins sent, weeks in a row."
        case .manual: return "Something you'll tick yourself. First unassisted pull-up, say."
        }
    }
}

struct PadTarget: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var icon: String = "calendar"
    var kind: PadTargetKind
    var lift: String = ""          // lift kind
    var weight: Double = 0         // lift kind, lb. With reps 0 it's an e1RM target; with reps it's weight × reps
    var reps: Int = 0
    var count: Int = 0             // sessions / streak weeks / check-in weeks
    var weeks: Int = 0             // sessions kind: within this many weeks of start (0 = until the deadline, or ever)
    var start: String              // yyyy-MM-dd
    var deadline: String = ""      // yyyy-MM-dd, or ""
    var note: String = ""          // what they see when they earn it
    var earnedAt: String = ""      // yyyy-MM-dd once earned
    var done: Bool = false         // manual kind

    var startDate: Date { PadLiftGoals.stamp.date(from: start) ?? Date() }
    var deadlineDate: Date? { deadline.isEmpty ? nil : PadLiftGoals.stamp.date(from: deadline) }
    var earnedDate: Date? { earnedAt.isEmpty ? nil : PadLiftGoals.stamp.date(from: earnedAt) }
    var isEarned: Bool { !earnedAt.isEmpty }

    /// "12 sessions in 4 weeks", "Bench 225 × 1", "Train every week for 8 weeks"
    var rule: String {
        switch kind {
        case .lift:
            let w = StatsUnits.weightText(weight)
            return reps > 0 ? "\(lift) \(w) × \(reps)" : "\(lift) \(w) e1RM"
        case .sessions:
            if weeks > 0 { return "\(count) sessions in \(weeks) weeks" }
            return deadline.isEmpty ? "\(count) sessions" : "\(count) sessions by \(PadDay.short(deadlineDate ?? Date()))"
        case .streak: return "Train every week for \(count) weeks"
        case .checkins: return "\(count) check-ins in a row"
        case .manual: return note.isEmpty ? "You'll tick it when it happens" : "Ticked by you"
        }
    }
}

/// A target the coach sets often, kept with its defaults.
struct PadTargetTemplate: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var icon: String
    var kind: PadTargetKind
    var lift: String = ""
    var weight: Double = 0
    var reps: Int = 0
    var count: Int = 0
    var weeks: Int = 0
    var note: String = ""

    static let builtIn: [PadTargetTemplate] = [
        PadTargetTemplate(id: "t-showed-up", title: "Showed Up", icon: "calendar", kind: .sessions, count: 12, weeks: 4, note: "Four weeks of showing up is the whole game. Everything else follows."),
        PadTargetTemplate(id: "t-two-plates", title: "Two Plates", icon: "dumbbell", kind: .lift, lift: "Bench Press", weight: 225, reps: 1, note: "225 on the bench. Welcome to the club."),
        PadTargetTemplate(id: "t-eight-straight", title: "Eight Straight", icon: "flame", kind: .streak, count: 8, note: "Eight weeks without a miss. That's a habit now."),
        PadTargetTemplate(id: "t-comeback", title: "Comeback", icon: "arrow.uturn.backward", kind: .sessions, count: 4, weeks: 2, note: "Back in it. The hardest part is behind you."),
        PadTargetTemplate(id: "t-50", title: "50 Sessions", icon: "flag.checkered", kind: .sessions, count: 50, note: "Fifty sessions. Look how far that is from day one."),
    ]
}

// MARK: Store (coach settings `clientTargets` and `targetTemplates`)

@MainActor
final class PadTargets: ObservableObject {
    static let shared = PadTargets()
    static let key = "clientTargets"
    static let templatesKey = "targetTemplates"
    @Published private(set) var targets: [String: [PadTarget]] = [:]     // by client id
    @Published private(set) var templates: [PadTargetTemplate] = PadTargetTemplate.builtIn
    private var loaded = false

    init() {
        if let d = UserDefaults.standard.data(forKey: "bst_pad_targets"),
           let t = try? JSONDecoder().decode([String: [PadTarget]].self, from: d) { targets = t }
        if let d = UserDefaults.standard.data(forKey: "bst_pad_target_templates"),
           let t = try? JSONDecoder().decode([PadTargetTemplate].self, from: d), !t.isEmpty { templates = t }
    }

    func load(store: AppStore) async {
        guard store.isLive, !loaded else { return }
        loaded = true
        if let s = try? await APIClient.shared.trainerSetting(Self.key), let json = s.json,
           let t = try? JSONDecoder().decode([String: [PadTarget]].self, from: Data(json.utf8)) {
            targets = t
        }
        if let s = try? await APIClient.shared.trainerSetting(Self.templatesKey), let json = s.json,
           let t = try? JSONDecoder().decode([PadTargetTemplate].self, from: Data(json.utf8)), !t.isEmpty {
            templates = t
        }
        cache()
    }

    func list(_ clientId: String) -> [PadTarget] { targets[clientId] ?? [] }
    func open(_ clientId: String) -> [PadTarget] { list(clientId).filter { !$0.isEarned } }

    func save(_ t: PadTarget, clientId: String, store: AppStore) {
        var list = (targets[clientId] ?? []).filter { $0.id != t.id }
        list.append(t)
        targets[clientId] = list
        push(store: store)
    }

    func remove(_ id: String, clientId: String, store: AppStore) {
        let list = (targets[clientId] ?? []).filter { $0.id != id }
        targets[clientId] = list.isEmpty ? nil : list
        push(store: store)
    }

    /// Marks a target earned today (called when the progress reaches the line, or by the coach for a manual one).
    func markEarned(_ id: String, clientId: String, store: AppStore) {
        guard var t = list(clientId).first(where: { $0.id == id }), !t.isEarned else { return }
        t.earnedAt = PadLiftGoals.stamp.string(from: Date())
        if t.kind == .manual { t.done = true }
        save(t, clientId: clientId, store: store)
    }

    func saveTemplate(_ tp: PadTargetTemplate, store: AppStore) {
        templates = templates.filter { $0.id != tp.id } + [tp]
        pushTemplates(store: store)
    }

    func removeTemplate(_ id: String, store: AppStore) {
        templates = templates.filter { $0.id != id }
        pushTemplates(store: store)
    }

    private func push(store: AppStore) {
        cache()
        guard store.isLive, let data = try? JSONEncoder().encode(targets), let json = String(data: data, encoding: .utf8) else { return }
        Task { _ = try? await APIClient.shared.saveTrainerSetting(Self.key, json: json) }
    }

    private func pushTemplates(store: AppStore) {
        cache()
        guard store.isLive, let data = try? JSONEncoder().encode(templates), let json = String(data: data, encoding: .utf8) else { return }
        Task { _ = try? await APIClient.shared.saveTrainerSetting(Self.templatesKey, json: json) }
    }

    private func cache() {
        if let d = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(d, forKey: "bst_pad_targets") }
        if let d = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(d, forKey: "bst_pad_target_templates") }
    }
}

// MARK: Progress

struct PadTargetProgress {
    let target: PadTarget
    let current: Double
    let goal: Double
    let currentText: String      // "10", "205 lb"
    let goalText: String         // "12 sessions", "225 lb"
    let left: String             // "2 sessions", "20 lb"
    let pace: String             // "on pace", "behind", "1 ahead", ""
    let onPace: Bool?            // nil = no deadline or nothing to say
    let nudge: String            // "Two more and it's yours. Next one's Thursday."
    let detail: String           // the second line under the bar, "e1RM 218" / "wk 6 open"

    var fraction: Double { goal > 0 ? min(1, current / goal) : 0 }
    var percent: Int { Int((fraction * 100).rounded(.down)) }
    var reached: Bool { current >= goal && goal > 0 }
    var daysLeft: Int? { target.deadlineDate.map { Calendar.training.dateComponents([.day], from: Calendar.training.startOfDay(for: Date()), to: $0).day ?? 0 } }

    /// Works a target out from what the iPad already has for the client.
    @MainActor
    static func compute(_ t: PadTarget, facts: PadClientFacts) -> PadTargetProgress {
        let cal = Calendar.training
        let data = PadData.shared
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: t.startDate)
        let sessions = data.sessions(client: facts.client).filter { $0.isDone }.sorted { $0.day < $1.day }
        let planned = data.sessions(client: facts.client).filter { $0.isPlanned && $0.day >= today }.sorted { $0.day < $1.day }
        let nextPlanned: String = planned.first.map { cal.isDateInToday($0.day) ? "today" : $0.day.formatted(.dateTime.weekday(.wide)) } ?? ""
        var cur = 0.0, goal = Double(max(t.count, 1))
        var curText = "0", goalText = "", left = "", detail = "", nudge = ""
        switch t.kind {
        case .sessions:
            var end: Date? = t.deadlineDate
            if t.weeks > 0 { end = cal.date(byAdding: .weekOfYear, value: t.weeks, to: start) }
            let done = sessions.filter { s in s.day >= start && (end.map { s.day < $0 } ?? true) }.count
            cur = Double(done); curText = "\(done)"; goalText = "\(t.count) sessions"
            let togo = max(0, t.count - done)
            left = togo == 0 ? "done" : togo.plural("session")
            detail = planned.isEmpty ? "" : "next \(nextPlanned)"
            if togo > 0, togo <= 2, !nextPlanned.isEmpty { nudge = "\(togo == 1 ? "One more" : "Two more") and it's \(togo == 1 ? "done" : "theirs"). Next one's \(nextPlanned)." }
        case .streak:
            let s = weekStreak(sessions.map { $0.day })
            cur = Double(s); curText = "\(s)"; goalText = "\(t.count) weeks"
            left = max(0, t.count - s) == 0 ? "done" : "\(max(0, t.count - s)) more weeks"
            let thisWeek = sessions.contains { cal.startOfWeek(for: $0.day) == cal.startOfWeek(for: Date()) }
            detail = thisWeek ? "this week done" : "wk \(s + 1) open"
            if !thisWeek, s > 0 { nudge = "This week's session keeps the streak alive." }
        case .checkins:
            let marks = facts.checkInWeeks
            var n = 0
            for m in marks.reversed() { if m.isSent { n += 1 } else if m == .open { continue } else { break } }
            cur = Double(n); curText = "\(n)"; goalText = "\(t.count) in a row"
            left = max(0, t.count - n) == 0 ? "done" : "\(max(0, t.count - n)) more"
            detail = marks.last == .open ? "this week's not sent" : ""
        case .lift:
            let ws = (data.workouts[facts.id] ?? []).filter { $0.completed && $0.date >= start }
            let h = ProgressEngine.history(for: t.lift, workouts: ws)
            let bestE1 = h.map { $0.estimatedOneRepMax }.max() ?? 0
            if t.reps > 0 {
                // Heaviest weight lifted for at least that many reps since the start.
                var best = 0.0
                for w in ws { for e in w.exercises where e.name == t.lift { for s in e.sets where (s.loggedReps ?? 0) >= t.reps { best = max(best, s.loggedWeight ?? 0) } } }
                cur = best; goal = t.weight
                curText = StatsUnits.weightText(best); goalText = "\(StatsUnits.weightText(t.weight)) × \(t.reps)"
                detail = bestE1 > 0 ? "e1RM \(StatsUnits.weightText(bestE1, unit: false))" : ""
            } else {
                cur = bestE1; goal = t.weight
                curText = StatsUnits.weightText(bestE1); goalText = "\(StatsUnits.weightText(t.weight)) e1RM"
                if let last = h.last { detail = "last \(PadDay.short(last.date))" }
            }
            let gap = goal - cur
            left = gap <= 0 ? "done" : StatsUnits.weightText(gap)
            if gap > 0, gap <= goal * 0.03 { nudge = "\(StatsUnits.weightText(gap)) away. A good day does it." }
        case .manual:
            cur = t.done ? 1 : 0; goal = 1
            curText = t.done ? "Done" : "Not yet"; goalText = ""
            left = t.done ? "done" : "when it happens"
        }
        // Pace against the deadline: what's needed per week from here against what they've done per week since the start.
        var pace = "", onPace: Bool? = nil
        if !t.isEarned, cur < goal, let dl = t.deadlineDate, t.kind != .manual {
            let daysLeft = max(0, cal.dateComponents([.day], from: today, to: dl).day ?? 0)
            let daysIn = max(1, cal.dateComponents([.day], from: start, to: today).day ?? 1)
            if daysLeft == 0 { pace = "due today"; onPace = false }
            else if t.kind == .lift {
                // Needs the rest of the gap at the rate of the last 8 weeks.
                let ws = data.workouts[facts.id] ?? []
                let h = ProgressEngine.history(for: t.lift, workouts: ws)
                let d56 = cal.date(byAdding: .day, value: -56, to: Date()) ?? Date()
                let recent = h.filter { $0.date >= d56 }.map { $0.estimatedOneRepMax }
                if recent.count >= 2, let a = recent.first, let b = recent.last, b > a {
                    let perDay = (b - a) / 56
                    onPace = cur + perDay * Double(daysLeft) >= goal
                    pace = onPace! ? "on pace" : "behind"
                } else { pace = "no trend yet" }
            } else {
                let ratePerDay = cur / Double(daysIn)
                let needPerDay = (goal - cur) / Double(max(daysLeft, 1))
                onPace = ratePerDay >= needPerDay
                let ahead = Int((ratePerDay * Double(daysIn + daysLeft) - goal).rounded(.down))
                pace = onPace! ? (ahead >= 1 ? "on pace · \(ahead) ahead" : "on pace") : "behind"
            }
        } else if t.isEarned { pace = "earned \(PadDay.short(t.earnedDate ?? Date()))" }
        else if cur >= goal { pace = "reached" }
        return PadTargetProgress(target: t, current: cur, goal: goal, currentText: curText, goalText: goalText, left: left,
                                 pace: pace, onPace: onPace, nudge: nudge, detail: detail)
    }

    static func weekStreak(_ days: [Date]) -> Int {
        let cal = Calendar.training
        let weeks = Set(days.map { cal.startOfWeek(for: $0) })
        var w = cal.startOfWeek(for: Date())
        if !weeks.contains(w) { w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w }
        var n = 0
        while weeks.contains(w) { n += 1; w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w }
        return n
    }

    /// Every open target for a client, with progress. Marks the ones that have crossed the line as earned.
    @MainActor
    static func all(for facts: PadClientFacts, store: AppStore) -> [PadTargetProgress] {
        let out = PadTargets.shared.list(facts.id).map { compute($0, facts: facts) }
        // Crossing the line is recorded after this render, not during it.
        let crossed = out.filter { $0.reached && !$0.target.isEarned && $0.target.kind != .manual }.map { $0.target.id }
        if !crossed.isEmpty {
            let clientId = facts.id
            Task { @MainActor in for id in crossed { PadTargets.shared.markEarned(id, clientId: clientId, store: store) } }
        }
        return out.sorted { a, b in
            if a.target.isEarned != b.target.isEarned { return !a.target.isEarned }
            return a.fraction > b.fraction
        }
    }

    /// The things worth noticing about a client's targets (for the Wins section, Today and the Wins page).
    @MainActor
    static func notices(for facts: PadClientFacts, store: AppStore) -> [PadInsights.Notice] {
        var out: [PadInsights.Notice] = []
        for p in all(for: facts, store: store) where !p.target.isEarned {
            let t = p.target
            if !p.nudge.isEmpty {
                out.append(.init(icon: "bolt.fill", tint: Pad.voltText, text: "\(facts.first) is \(p.left) from \(t.title).", aside: p.nudge))
            } else if p.onPace == false, let d = p.daysLeft {
                let aside: String = t.kind == .lift ? "The last 8 weeks didn't move fast enough. Push the date or the \(t.lift.lowercased()) frequency." : "\(p.left) left in \(d.plural("day")). Push the date, or a nudge now."
                out.append(.init(icon: "hourglass", tint: Pad.orange, text: "\(t.title) is behind for \(PadDay.short(t.deadlineDate ?? Date())).", aside: aside))
            }
        }
        return out
    }
}

// MARK: Icons the coach can pick

enum PadTargetIcons {
    static let all = ["calendar", "flame", "dumbbell", "trophy", "bolt", "flag.checkered", "arrow.uturn.backward", "figure.strengthtraining.traditional", "checkmark.seal", "star", "mountain.2", "target"]
}

// MARK: The Targets pane (client › Wins)

struct PadTargetsPane: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var targets = PadTargets.shared
    @State private var editing: PadTarget?
    @State private var adding = false

    var body: some View {
        let list = PadTargetProgress.all(for: facts, store: store)
        let open = list.filter { !$0.target.isEarned }
        let earned = list.filter { $0.target.isEarned }
        let earnedPart: String = earned.isEmpty ? "" : " · \(earned.count) earned"
        let aside: String = list.isEmpty ? "things \(facts.first) works toward" : "\(open.count) open" + earnedPart
        return PadPane(title: "Targets", aside: aside) {
            if list.isEmpty {
                PadEmptyLine(text: "Set something for \(facts.first) to work toward. They'll see the progress on their phone.")
            }
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.target.id) { i, p in
                    if i > 0 { PadRule() }
                    row(p)
                }
            }
            HStack(spacing: 8) {
                Button { adding = true } label: { Label("Set a target", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                Spacer()
                PadLab(templatesLine, color: Pad.faint, size: 12).lineLimit(1)
            }
        }
        .sheet(isPresented: $adding) { PadTargetSheet(facts: facts, existing: nil) }
        .sheet(item: $editing) { t in PadTargetSheet(facts: facts, existing: t) }
    }

    private var templatesLine: String {
        let names = targets.templates.prefix(3).map { $0.title }
        return names.isEmpty ? "" : "Templates: " + names.joined(separator: " · ")
    }

    private func row(_ p: PadTargetProgress) -> some View {
        let t = p.target
        let tint: Color = t.isEarned ? Pad.green : (p.onPace == false ? Pad.orange : Pad.voltText)
        let tagText: String
        let tagKind: PadTag.Kind
        if t.isEarned { tagText = "earned"; tagKind = .plain }
        else if p.onPace == false { tagText = "behind"; tagKind = .warn }
        else if p.left == "done" { tagText = "reached"; tagKind = .volt }
        else if !p.nudge.isEmpty { tagText = "\(p.left) to go"; tagKind = .volt }
        else if t.deadline.isEmpty { tagText = "no deadline"; tagKind = .line }
        else { tagText = "by \(PadDay.short(t.deadlineDate ?? Date()))"; tagKind = .line }
        let sub: String = t.rule + (t.deadline.isEmpty || t.isEarned ? "" : " · by \(PadDay.short(t.deadlineDate ?? Date()))")
        return Button { editing = t } label: {
            HStack(spacing: 12) {
                Image(systemName: t.isEarned ? "checkmark" : t.icon).font(.system(size: 15, weight: .semibold)).foregroundColor(tint)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10).fill(Pad.raised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 5) {
                    PadBar(fraction: t.isEarned ? 1 : p.fraction, hero: !t.isEarned)
                    HStack {
                        Text(t.isEarned ? "Done" : "\(p.currentText) of \(p.goalText)").font(PadFont.cond(11, .bold)).foregroundColor(Pad.text).lineLimit(1)
                        Spacer()
                        Text(t.isEarned ? p.pace : (p.pace.isEmpty ? p.detail : p.pace)).font(PadFont.cond(11)).foregroundColor(Pad.mute).lineLimit(1)
                    }
                }
                .frame(width: 150)
                PadTag(text: tagText, kind: tagKind)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(t.isEarned ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu {
            if t.kind == .manual && !t.isEarned {
                Button { PadTargets.shared.markEarned(t.id, clientId: facts.id, store: store) } label: { Label("Mark it done", systemImage: "checkmark") }
            }
            Button { editing = t } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { PadTargets.shared.remove(t.id, clientId: facts.id, store: store) } label: { Label("Remove", systemImage: "trash") }
        }
    }
}

// MARK: Set a target

struct PadTargetSheet: View {
    let facts: PadClientFacts
    let existing: PadTarget?
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var targets = PadTargets.shared
    @ObservedObject private var data = PadData.shared
    @State private var t: PadTarget
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var weightText: String
    @State private var repsText: String
    @State private var countText: String
    @State private var weeksText: String
    @State private var template: String = ""
    @State private var savedTemplate = false

    init(facts: PadClientFacts, existing: PadTarget?) {
        self.facts = facts
        self.existing = existing
        let start = PadLiftGoals.stamp.string(from: Date())
        let base = existing ?? PadTarget(title: "", kind: .sessions, count: 12, weeks: 4, start: start)
        _t = State(initialValue: base)
        _hasDeadline = State(initialValue: !base.deadline.isEmpty)
        _deadline = State(initialValue: base.deadlineDate ?? (Calendar.training.date(byAdding: .weekOfYear, value: 4, to: Date()) ?? Date()))
        _weightText = State(initialValue: base.weight > 0 ? StatsUnits.weight(base.weight).padShort : "")
        _repsText = State(initialValue: base.reps > 0 ? "\(base.reps)" : "")
        _countText = State(initialValue: base.count > 0 ? "\(base.count)" : "")
        _weeksText = State(initialValue: base.weeks > 0 ? "\(base.weeks)" : "")
    }

    private var lifts: [String] {
        let ws = data.workouts[facts.id] ?? []
        var names: [String: Int] = [:]
        for w in ws where w.completed { for e in w.exercises { names[e.name, default: 0] += 1 } }
        let main = ["Back Squat", "Bench Press", "Deadlift", "Overhead Press", "Front Squat", "Romanian Deadlift", "Barbell Row", "Hip Thrust"]
        let rest = names.keys.filter { !main.contains($0) }.sorted()
        return main + rest
    }

    private var canSave: Bool {
        let title = t.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return false }
        switch t.kind {
        case .lift: return !t.lift.isEmpty && (Double(weightText.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
        case .sessions, .streak, .checkins: return (Int(countText) ?? 0) > 0
        case .manual: return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(existing == nil ? "Set a target" : "Edit target").font(PadFont.display(28)).foregroundColor(Pad.text)
                    Spacer()
                    Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute)
                }
                if existing == nil { templatesRow }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        PadLab("Kind", size: 12)
                        PadSeg(options: PadTargetKind.allCases.map { (id: $0, label: $0.title) }, selection: $t.kind)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        PadLab("Icon", size: 12)
                        iconRow
                    }
                }
                PadLab(t.kind.blurb, color: Pad.faint, size: 12)
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Title", size: 12)
                    TextField("Showed Up", text: $t.title).padInput()
                }
                fields
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            PadLab("Deadline", size: 12)
                            Spacer()
                            Toggle("", isOn: $hasDeadline).labelsHidden().tint(Pad.volt).scaleEffect(0.8)
                        }
                        if hasDeadline {
                            DatePicker("", selection: $deadline, in: Date()..., displayedComponents: .date).labelsHidden().tint(Pad.voltText)
                        } else {
                            PadLab("No deadline. It's done when it's done.", color: Pad.faint, size: 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        PadLab("Note they'll see when they earn it", size: 12)
                        TextField("“Four weeks of showing up is the whole game…”", text: $t.note, axis: .vertical).lineLimit(2...3).padInput()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                preview
                HStack(spacing: 8) {
                    if existing != nil {
                        Button("Remove", role: .destructive) { PadTargets.shared.remove(t.id, clientId: facts.id, store: store); dismiss() }
                            .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                    }
                    Spacer()
                    Button(savedTemplate ? "Saved as template" : "Save as template") { saveTemplate() }
                        .buttonStyle(PadButtonStyle(kind: .quiet, small: true)).disabled(!canSave || savedTemplate)
                    Button(existing == nil ? "Set it" : "Save") { save() }
                        .buttonStyle(PadButtonStyle(kind: .primary, small: true)).disabled(!canSave)
                }
            }
            .padding(24)
        }
        .background(Pad.surface)
        .frame(minWidth: 560, minHeight: 620)
    }

    private var templatesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(targets.templates) { tp in
                    PadChip(text: tp.title, on: template == tp.id) { apply(tp) }
                        .contextMenu {
                            Button(role: .destructive) { PadTargets.shared.removeTemplate(tp.id, store: store) } label: { Label("Delete template", systemImage: "trash") }
                        }
                }
                PadChip(text: "Your own…", on: template == "own") { template = "own"; t.title = "" }
            }
        }
    }

    private var iconRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PadTargetIcons.all, id: \.self) { ic in
                    let on = t.icon == ic
                    Button { t.icon = ic } label: {
                        Image(systemName: ic).font(.system(size: 15, weight: .semibold))
                            .foregroundColor(on ? Pad.onVolt : Pad.mute)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 11).fill(on ? Pad.volt : Pad.well))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? Color.clear : Pad.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ic)
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch t.kind {
        case .lift:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Lift", size: 12)
                    Menu {
                        ForEach(lifts, id: \.self) { l in Button(l) { t.lift = l } }
                    } label: {
                        PadMenuLabel(text: t.lift.isEmpty ? "Pick a lift" : t.lift, kind: .outline, icon: "chevron.up.chevron.down")
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Weight (\(StatsUnits.weightLabel))", size: 12)
                    TextField("225", text: $weightText).keyboardType(.decimalPad).padInput()
                }
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Reps (blank = e1RM)", size: 12)
                    TextField("1", text: $repsText).keyboardType(.numberPad).padInput()
                }
            }
        case .sessions:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Sessions", size: 12)
                    TextField("12", text: $countText).keyboardType(.numberPad).padInput()
                }
                VStack(alignment: .leading, spacing: 5) {
                    PadLab("Within (weeks, blank = by the deadline)", size: 12)
                    TextField("4", text: $weeksText).keyboardType(.numberPad).padInput()
                }
            }
        case .streak:
            VStack(alignment: .leading, spacing: 5) {
                PadLab("Weeks in a row", size: 12)
                TextField("8", text: $countText).keyboardType(.numberPad).padInput().frame(maxWidth: 200)
            }
        case .checkins:
            VStack(alignment: .leading, spacing: 5) {
                PadLab("Check-ins in a row", size: 12)
                TextField("6", text: $countText).keyboardType(.numberPad).padInput().frame(maxWidth: 200)
            }
        case .manual:
            PadLab("You'll mark it done from the Targets pane when it happens.", color: Pad.faint, size: 12)
        }
    }

    private var preview: some View {
        let draft = built()
        let p = PadTargetProgress.compute(draft, facts: facts)
        let already: String = p.current > 0 && p.target.kind != .manual ? " · already \(p.currentText) of \(p.goalText)" : ""
        return VStack(alignment: .leading, spacing: 8) {
            PadLab("\(facts.first) sees", size: 12)
            HStack(spacing: 10) {
                Image(systemName: draft.icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.voltText)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(Pad.raised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.title.isEmpty ? "Untitled target" : draft.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    Text(previewLine(draft, already: already)).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(2)
                }
                Spacer()
                PadTag(text: "\(p.percent)%", kind: .volt)
            }
        }
        .padWell()
    }

    private func previewLine(_ d: PadTarget, already: String) -> String {
        let by: String = hasDeadline ? " · by \(PadDay.short(deadline))" : ""
        return d.rule + by + already
    }

    private func apply(_ tp: PadTargetTemplate) {
        template = tp.id
        t.title = tp.title; t.icon = tp.icon; t.kind = tp.kind; t.lift = tp.lift; t.note = tp.note
        weightText = tp.weight > 0 ? StatsUnits.weight(tp.weight).padShort : ""
        repsText = tp.reps > 0 ? "\(tp.reps)" : ""
        countText = tp.count > 0 ? "\(tp.count)" : ""
        weeksText = tp.weeks > 0 ? "\(tp.weeks)" : ""
        if tp.weeks > 0 { hasDeadline = true; deadline = Calendar.training.date(byAdding: .weekOfYear, value: tp.weeks, to: Date()) ?? deadline }
    }

    private func built() -> PadTarget {
        var d = t
        d.title = t.title.trimmingCharacters(in: .whitespaces)
        let w = Double(weightText.replacingOccurrences(of: ",", with: ".")) ?? 0
        d.weight = StatsUnits.weightLabel == "kg" ? w / 0.45359237 : w
        d.reps = Int(repsText) ?? 0
        d.count = Int(countText) ?? 0
        d.weeks = Int(weeksText) ?? 0
        d.deadline = hasDeadline ? PadLiftGoals.stamp.string(from: deadline) : ""
        if d.kind != .lift { d.lift = ""; d.weight = 0; d.reps = 0 }
        if d.kind == .manual || d.kind == .lift { d.count = 0; d.weeks = 0 }
        if d.kind != .sessions { d.weeks = 0 }
        return d
    }

    private func save() {
        PadTargets.shared.save(built(), clientId: facts.id, store: store)
        dismiss()
    }

    private func saveTemplate() {
        let d = built()
        PadTargets.shared.saveTemplate(PadTargetTemplate(title: d.title, icon: d.icon, kind: d.kind, lift: d.lift, weight: d.weight, reps: d.reps, count: d.count, weeks: d.weeks, note: d.note), store: store)
        savedTemplate = true
    }
}
