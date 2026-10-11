import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's Stats and Wins (Oct 9, 2026)
//
// Stats: the coach layer on top (findings + what changed since the last check-in), lift cards
// (e1RM trend, bar speed at a fixed weight, goal with an on-pace line), bodyweight, weekly volume,
// sets per muscle and the consistency calendar. 4, 8 or 12 weeks. This is the coach's view until
// the iPhone Stats screens are brought over in the borrowing pass.
// Wins (was Awards): PRs, awards and milestones in one feed, what they're close to, and how long
// since their last win. Tools: shout-outs.
// Synchronized folder: no target step needed.

// MARK: - Stats

struct PadClientStats: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var goals = PadLiftGoals.shared
    @AppStorage("bst_pad_stats_weeks") private var weeks = 8
    @State private var goalLift: String?

    private var cal: Calendar { Calendar.training }
    private var since: Date { cal.date(byAdding: .weekOfYear, value: -weeks, to: cal.startOfDay(for: Date())) ?? Date() }
    private var workouts: [Workout] { data.workouts[facts.id] ?? [] }

    /// The notices across the top: since the last check-in first, then the rest.
    private var topNotices: [PadInsights.Notice] {
        var top: [PadInsights.Notice] = []
        if let s = sinceCheckIn() { top.append(s) }
        top.append(contentsOf: PadInsights.notices(facts))
        return top
    }

    var body: some View {
        let lifts = topLifts()
        let top = topNotices
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(), notices: top) {
                PadSeg(options: [(id: 4, label: "4 wks"), (id: 8, label: "8 wks"), (id: 12, label: "12 wks")], selection: $weeks)
            }
            PadRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if lifts.isEmpty {
                        PadPane(title: "Lifts") { PadEmptyLine(text: "No lifts logged in the last \(weeks) weeks.") }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(lifts, id: \.self) { l in liftCard(l) }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) { bodyCard; volumeCard }
                    HStack(alignment: .top, spacing: 12) { muscleCard; calendarCard }
                }
                .padding(20)
            }
        }
        .task { await goals.load(store: store); await data.loadContext(facts.id); await coach.loadCheckIns(facts.id) }
    }

    // MARK: Headline

    private func stats() -> [PadStat] {
        let done = workouts.filter { $0.completed && $0.date >= since }
        let prs = ProgressEngine.allPRs(workouts: workouts).filter { $0.date >= since && !$0.isFirstEver }
        let vol = done.flatMap { $0.exercises.flatMap { $0.sets } }.reduce(0.0) { $0 + $1.volume }
        let bw = bodyweights()
        var out = [
            PadStat(label: "Sessions", value: "\(done.count)", sub: "last \(weeks) weeks"),
            PadStat(label: "PRs", value: "\(prs.count)", sub: prs.first.map { "latest \($0.exercise)" } ?? "none yet", good: !prs.isEmpty),
            PadStat(label: "Volume", value: StatsUnits.weightText(vol, unit: false), unit: StatsUnits.weightLabel, sub: "lifted in total")
        ]
        if let a = bw.first?.1, let b = bw.last?.1, bw.count >= 2 {
            let d = StatsUnits.weight(b - a)
            out.append(PadStat(label: "Bodyweight", value: StatsUnits.weight(b).padShort, unit: StatsUnits.weightLabel,
                               sub: "\(d >= 0 ? "+" : "−")\(abs(d).padShort) in \(weeks) wks"))
        }
        return out
    }

    private func bodyweights() -> [(Date, Double)] {
        (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" && $0.date >= since }
            .compactMap { c in PadInsights.bodyweight(c).map { (c.date, $0) } }
            .sorted { $0.0 < $1.0 }
    }

    /// One line on what changed since the last check-in.
    private func sinceCheckIn() -> PadInsights.Notice? {
        let cis = (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }
        guard let last = cis.last else { return nil }
        let sessions = workouts.filter { $0.completed && $0.date > last.date }.count
        let prs = ProgressEngine.allPRs(workouts: workouts).filter { $0.date > last.date && !$0.isFirstEver }.count
        var bits = ["\(sessions.plural("session"))"]
        if prs > 0 { bits.append(prs.plural("PR")) }
        if cis.count >= 2, let a = PadInsights.bodyweight(cis[cis.count - 2]), let b = PadInsights.bodyweight(last) {
            let d = StatsUnits.weight(b - a)
            if abs(d) >= 0.1 { bits.append("bodyweight " + (d >= 0 ? "+" : "−") + abs(d).padShort + " " + StatsUnits.weightLabel + " on the check-in before") }
        }
        return PadInsights.Notice(icon: "clock.arrow.circlepath", tint: Pad.mute, text: "Since the last check-in (\(PadDay.short(last.date))):",
                     aside: bits.joined(separator: ", ") + ".")
    }

    // MARK: Lifts

    private func topLifts() -> [String] {
        let names = workouts.filter { $0.completed && $0.date >= since }.flatMap { $0.exercises.filter { e in e.sets.contains { $0.loggedReps != nil } }.map { $0.name } }
        return Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(6).map { $0.key }
    }

    private func liftCard(_ name: String) -> some View {
        let h = ProgressEngine.history(for: name, workouts: workouts).filter { $0.date >= since }.sorted { $0.date < $1.date }
        let series = h.map { StatsUnits.weight($0.estimatedOneRepMax) }
        let best = h.map { $0.estimatedOneRepMax }.max() ?? 0
        let change = (h.last?.estimatedOneRepMax ?? 0) - (h.first?.estimatedOneRepMax ?? 0)
        let goal = goals.goal(facts.id, lift: name)
        let speed = speedAtLoad(name)
        let deltaText: String = (change >= 0 ? "+" : "−") + StatsUnits.weightText(abs(change))
        var speedText: String = ""
        var speedColor: Color = Pad.mute
        if let sp = speed {
            speedText = "At " + StatsUnits.weightText(sp.load) + ": " + String(format: "%.2f", sp.from) + " → " + String(format: "%.2f", sp.to) + " m/s"
            if sp.to >= sp.from * 1.03 { speedColor = Pad.voltText } else if sp.to <= sp.from * 0.95 { speedColor = Pad.orange }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(1)
                Spacer(minLength: 4)
                Button(goal == nil ? "Set goal" : "Goal") { goalLift = name }
                    .font(PadFont.ui(12, .semibold)).foregroundColor(Pad.mute)
                    .popover(isPresented: Binding(get: { goalLift == name }, set: { if !$0 { goalLift = nil } })) {
                        PadGoalEditor(clientId: facts.id, lift: name, current: best)
                    }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PadNumber(value: StatsUnits.weightText(best, unit: false), unit: "e1RM", size: 30)
                Spacer()
                if h.count >= 2 { PadDelta(text: deltaText, better: abs(change) < 2.5 ? nil : change > 0) }
            }
            PadLineChart(points: series, goal: goal.map { StatsUnits.weight($0.target) }).frame(height: 54)
            if let g = goal { goalLine(g, h: h) }
            if speed != nil {
                Text(speedText).font(PadFont.cond(12)).foregroundColor(speedColor)
            }
            PadLab("\(h.count.plural("session")) · best \(StatsUnits.weightText(best))", color: Pad.faint, size: 11)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    /// On pace for the goal? Compares the rate needed with the rate over the period.
    private func goalLine(_ g: PadLiftGoal, h: [ExerciseHistorySession]) -> some View {
        let by = PadLiftGoals.stamp.date(from: g.by) ?? Date()
        let now = h.last?.estimatedOneRepMax ?? 0
        let daysLeft = max(Double(cal.dateComponents([.day], from: Date(), to: by).day ?? 0), 1)
        let span = max(Double(cal.dateComponents([.day], from: h.first?.date ?? Date(), to: h.last?.date ?? Date()).day ?? 0), 7)
        let rate = ((h.last?.estimatedOneRepMax ?? 0) - (h.first?.estimatedOneRepMax ?? 0)) / span * 7
        let need = (g.target - now) / daysLeft * 7
        let text: String
        let color: Color
        if now >= g.target { text = "Goal \(StatsUnits.weightText(g.target)) reached"; color = Pad.voltText }
        else if rate >= need { text = "On pace for \(StatsUnits.weightText(g.target)) by \(PadDay.short(by))"; color = Pad.voltText }
        else { text = "Behind: needs +\(StatsUnits.weightText(need))/wk, doing \(rate >= 0 ? "+" : "−")\(StatsUnits.weightText(abs(rate)))/wk"; color = Pad.orange }
        return Text(text).font(PadFont.cond(12)).foregroundColor(color).lineLimit(2)
    }

    /// Bar speed at the load they've used most, first session vs latest.
    private func speedAtLoad(_ name: String) -> (load: Double, from: Double, to: Double)? {
        let ms = (data.motion[facts.id] ?? []).filter { $0.exerciseName == name && !$0.reps.isEmpty && $0.start >= since }
        guard ms.count >= 4 else { return nil }
        var loadOf: [String: Double] = [:]
        for w in data.apiWorkouts[facts.id] ?? [] { for e in w.exercises where e.name == name { for s in e.sets { if let lw = s.loggedWeight { loadOf[s.id] = lw } } } }
        let withLoad = ms.compactMap { m in loadOf[m.setId].map { (m, $0) } }
        let byLoad = Dictionary(grouping: withLoad, by: { $0.1 })
        guard let pick = byLoad.filter({ Set($0.value.map { $0.0.workoutId }).count >= 2 }).max(by: { $0.value.count < $1.value.count }) else { return nil }
        let byW = Dictionary(grouping: pick.value, by: { $0.0.workoutId }).values.map { v in
            (v.map { $0.0.start }.min() ?? Date(), v.map { $0.0.meanVelocity }.reduce(0, +) / Double(v.count))
        }.sorted { $0.0 < $1.0 }
        guard let a = byW.first?.1, let b = byW.last?.1 else { return nil }
        return (pick.key, a, b)
    }

    // MARK: Body, volume, muscles, calendar

    private var bodyCard: some View {
        let bw = bodyweights()
        return PadPane(title: "Bodyweight", aside: "from check-ins") {
            if bw.count >= 2 {
                PadLineChart(points: bw.map { StatsUnits.weight($0.1) }).frame(height: 90)
                HStack {
                    PadLab("\(StatsUnits.weight(bw.first!.1).padShort) on \(PadDay.short(bw.first!.0))", color: Pad.faint, size: 11)
                    Spacer()
                    PadLab("\(StatsUnits.weight(bw.last!.1).padShort) \(StatsUnits.weightLabel) now", size: 11)
                }
            } else {
                PadEmptyLine(text: "Needs two check-ins with bodyweight.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeCard: some View {
        let start = cal.startOfWeek(for: Date())
        let wks: [Date] = (0..<weeks).reversed().map { cal.date(byAdding: .weekOfYear, value: -$0, to: start) ?? start }
        let vals: [Double] = wks.map { w in
            let e = cal.date(byAdding: .day, value: 7, to: w) ?? w
            return workouts.filter { $0.completed && $0.date >= w && $0.date < e }.flatMap { $0.exercises.flatMap { $0.sets } }.reduce(0.0) { $0 + $1.volume }
        }
        return PadPane(title: "Weekly volume", aside: StatsUnits.weightLabel + " lifted") {
            PadBars(values: vals.map { StatsUnits.weight($0) }, labels: wks.map { PadDay.short($0) }, height: 90)
        }
        .frame(maxWidth: .infinity)
    }

    private var muscleCard: some View {
        let api = (data.apiWorkouts[facts.id] ?? []).filter { $0.scheduledDate >= since }
        let start = cal.startOfWeek(for: Date())
        var thisWeek: [String: Int] = [:], total: [String: Int] = [:]
        for w in api {
            for e in w.exercises {
                let n = e.sets.filter { $0.loggedReps != nil }.count
                guard n > 0 else { continue }
                let m = e.muscleGroup.isEmpty ? "Other" : e.muscleGroup.capitalized
                total[m, default: 0] += n
                if w.scheduledDate >= start { thisWeek[m, default: 0] += n }
            }
        }
        let rows = total.sorted { $0.value > $1.value }.prefix(8)
        let wk = Double(max(weeks, 1))
        var mx: Double = 1
        for r in rows { mx = max(mx, Double(r.value) / wk, Double(thisWeek[r.key] ?? 0)) }
        return PadPane(title: "Sets per muscle", aside: "this week · bar = weekly average") {
            if rows.isEmpty { PadEmptyLine(text: "No logged sets yet.") }
            ForEach(Array(rows), id: \.key) { row in
                let m: String = row.key
                let avg = Double(row.value) / Double(max(weeks, 1))
                let now = Double(thisWeek[m] ?? 0)
                HStack(spacing: 10) {
                    Text(m).font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 90, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Pad.raised).frame(width: g.size.width * CGFloat(avg / mx), height: 8)
                            Capsule().fill(now >= avg ? Pad.volt : Pad.orange).frame(width: max(2, g.size.width * CGFloat(now / mx)), height: 4)
                        }
                        .frame(height: 8)
                    }
                    .frame(height: 8)
                    Text("\(Int(now)) / \(avg.padShort)").font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var calendarCard: some View {
        let start = cal.startOfWeek(for: Date())
        let wks: [Date] = (0..<12).reversed().map { cal.date(byAdding: .weekOfYear, value: -$0, to: start) ?? start }
        let ss = data.sessions(client: facts.client)
        return PadPane(title: "Consistency", aside: "12 weeks") {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in Text(Calendar.trainingWeekdayLetters[i]).font(PadFont.cond(10)).foregroundColor(Pad.faint).frame(height: 14) }
                }
                ForEach(wks, id: \.self) { w in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: d, to: w) ?? w
                            let mine = ss.filter { cal.isDate($0.day, inSameDayAs: day) }
                            let done = mine.contains { $0.isDone }
                            let missed = !done && mine.contains { $0.isMissed }
                            RoundedRectangle(cornerRadius: 3)
                                .fill(done ? Pad.volt : Pad.raised.opacity(day > Date() ? 0.25 : 0.6))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(missed ? Pad.orange : Color.clear, lineWidth: 1.2))
                                .frame(height: 14)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityLabel("Training calendar, last 12 weeks")
        }
        .frame(maxWidth: .infinity)
    }
}

/// Set or clear a lift goal (an e1RM by a date).
struct PadGoalEditor: View {
    let clientId: String
    let lift: String
    let current: Double
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var by = Calendar.training.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date()

    var body: some View {
        let existing = PadLiftGoals.shared.goal(clientId, lift: lift)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(lift) goal").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            PadLab("Now \(StatsUnits.weightText(current)) e1RM")
            HStack(spacing: 8) {
                TextField("Target e1RM", text: $target).keyboardType(.decimalPad).padInput()
                Text(StatsUnits.weightLabel).font(PadFont.ui(14)).foregroundColor(Pad.mute)
            }
            DatePicker("By", selection: $by, in: Date()..., displayedComponents: .date).tint(Pad.voltText)
            HStack {
                if existing != nil {
                    Button("Clear") { PadLiftGoals.shared.set(nil, lift: lift, clientId: clientId, store: store); dismiss() }
                        .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                }
                Spacer()
                Button("Save") {
                    guard let t = Double(target.replacingOccurrences(of: ",", with: ".")), t > 0 else { return }
                    let lb = StatsUnits.weightLabel == "kg" ? t / 0.45359237 : t
                    PadLiftGoals.shared.set(PadLiftGoal(lift: lift, target: lb, by: PadLiftGoals.stamp.string(from: by)), lift: lift, clientId: clientId, store: store)
                    dismiss()
                }
                .buttonStyle(PadButtonStyle(kind: .primary, small: true))
                .disabled(Double(target.replacingOccurrences(of: ",", with: ".")) == nil)
            }
        }
        .padding(18).frame(width: 340).background(Pad.surface)
        .onAppear {
            if let e = existing {
                target = StatsUnits.weight(e.target).padShort
                by = PadLiftGoals.stamp.date(from: e.by) ?? by
            } else {
                target = StatsUnits.weight((current * 1.05 / 5).rounded() * 5).padShort
            }
        }
    }
}

// MARK: - Wins (PRs, awards and milestones)

struct PadClientWins: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var targets = PadTargets.shared
    @State private var setTarget = false
    @State private var awards: [APIAward] = []
    @State private var quick: PadQuickMessage?

    private var cal: Calendar { Calendar.training }

    struct Win: Identifiable {
        let id: String
        let date: Date
        let icon: String
        let kind: String     // "PR" / "Award" / "Milestone"
        let title: String
        let detail: String
    }

    private static let sessionMarks = [10, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000]
    private static let streakMarks = [4, 8, 12, 26, 52]

    var body: some View {
        let feed = wins()
        let last = feed.first?.date
        let dry = last.map { PadDay.daysAgo($0) } ?? 999
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(feed, streak: streak()), notices: PadTargetProgress.notices(for: facts, store: store) + dryNotice(dry)) {
                Button { setTarget = true } label: { Label("Set a target", systemImage: "target") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                Button {
                    quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Shout-out",
                                            text: "Just looked over your training, \(facts.first). Really proud of the work you're putting in. Keep it up!")
                } label: { Label("Shout-out", systemImage: "hands.clap") }
                .buttonStyle(PadButtonStyle(kind: .primary, small: true))
            }
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if feed.isEmpty { PadEmptyLine(text: "No wins yet. PRs, awards and milestones show here as they happen.").padding(20) }
                        ForEach(feed) { w in winRow(w) }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(Pad.line).frame(width: 1)
                ScrollView {
                    VStack(spacing: 12) {
                        PadTargetsPane(facts: facts)
                        closeToPane
                        shelfPane
                    }
                    .padding(16)
                }
                .frame(width: 340)
                .background(Pad.page)
            }
        }
        .task {
            await PadTargets.shared.load(store: store)
            awards = (try? await APIClient.shared.trainerAwards(clientId: facts.id)) ?? awards
        }
        .sheet(item: $quick) { m in PadQuickMessageSheet(message: m) }
        .sheet(isPresented: $setTarget) { PadTargetSheet(facts: facts, existing: nil) }
    }

    private var doneDates: [Date] {
        data.sessions(client: facts.client).filter { $0.isDone }.map { $0.finish ?? $0.day }.sorted()
    }

    private func wins() -> [Win] {
        var out: [Win] = []
        for p in ProgressEngine.allPRs(workouts: data.workouts[facts.id] ?? []) where !p.isFirstEver {
            out.append(Win(id: "pr-" + p.id, date: p.date, icon: "bolt.fill", kind: "PR",
                           title: "\(p.exercise) PR", detail: "\(p.reps) × \(StatsUnits.weightText(p.weight)) · \(StatsUnits.weightText(p.estimatedOneRepMax)) e1RM, up \(StatsUnits.weightText(p.gain))"))
        }
        for a in awards {
            out.append(Win(id: "aw-" + a.kind, date: a.earnedAt, icon: "trophy.fill", kind: "Award", title: a.title, detail: a.blurb))
        }
        let dates = doneDates
        for m in Self.sessionMarks where dates.count >= m {
            out.append(Win(id: "ms-\(m)", date: dates[m - 1], icon: "flag.checkered", kind: "Milestone", title: "\(m) sessions", detail: "Since \(PadDay.short(dates.first!))"))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Weeks in a row with at least one session (this week counts once they've trained).
    private func streak() -> Int {
        let ss = doneDates
        var w = cal.startOfWeek(for: Date())
        var n = 0
        if !ss.contains(where: { cal.startOfWeek(for: $0) == w }) { w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w }
        while ss.contains(where: { cal.startOfWeek(for: $0) == w }) {
            n += 1
            w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w
        }
        return n
    }

    private func stats(_ feed: [Win], streak: Int) -> [PadStat] {
        let d90 = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let last = feed.first
        let prCount: Int = feed.filter { $0.kind == "PR" && $0.date >= d90 }.count
        var prSub: String = "none yet"
        if let p = feed.first(where: { $0.kind == "PR" }) { prSub = "latest " + PadDay.short(p.date) }
        var awardSub: String = "none yet"
        if let a = awards.max(by: { $0.earnedAt < $1.earnedAt }) { awardSub = "latest " + PadDay.short(a.earnedAt) }
        let lastDays: Int = last.map { PadDay.daysAgo($0.date) } ?? 0
        let lastValue: String = last == nil ? "—" : "\(lastDays)"
        var out: [PadStat] = []
        out.append(PadStat(label: "PRs, 90 days", value: "\(prCount)", sub: prSub))
        out.append(PadStat(label: "Awards", value: "\(awards.count)", sub: awardSub))
        out.append(PadStat(label: "Last win", value: lastValue, unit: last == nil ? nil : "days ago", sub: last?.title ?? "nothing yet", warn: lastDays > 21))
        out.append(PadStat(label: "Weekly streak", value: "\(streak)", unit: streak == 1 ? "week" : "weeks", sub: "with at least one session", good: streak >= 4))
        return out
    }

    private func dryNotice(_ dry: Int) -> [PadInsights.Notice] {
        guard dry > 21, dry < 999 else { return [] }
        return [.init(icon: "hourglass", tint: Pad.orange, text: "No wins in \(dry) days.",
                      aside: "Long dry spells come before people drift. Set a small target this week to break it.")]
    }

    private func winRow(_ w: Win) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: w.icon).font(.system(size: 14, weight: .semibold))
                .foregroundColor(w.kind == "PR" ? Pad.onVolt : Pad.text)
                .frame(width: 34, height: 34)
                .background(Circle().fill(w.kind == "PR" ? Pad.volt : Pad.raised))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(w.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                    PadTag(text: w.kind, kind: .line)
                }
                Text(w.detail).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(2)
                PadLab(PadDay.weekdayShort(w.date), color: Pad.faint, size: 11)
            }
            Spacer(minLength: 8)
            Button("Congratulate") {
                quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Congratulate \(facts.first)",
                                        text: "\(w.title)! That's a big one, \(facts.first). Well earned.")
            }
            .buttonStyle(PadButtonStyle(kind: .outline, small: true))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1).padding(.leading, 66) }
    }

    private var closeToPane: some View {
        var items: [(String, String, Double)] = []      // title, detail, progress 0–1
        let n = doneDates.count
        if let next = Self.sessionMarks.first(where: { $0 > n }) {
            let prev = Self.sessionMarks.last { $0 <= n } ?? 0
            items.append(("\(next) sessions", "\(next - n) to go", Double(n - prev) / Double(next - prev)))
        }
        let s = streak()
        if let next = Self.streakMarks.first(where: { $0 > s }), s > 0 {
            items.append(("\(next)-week streak", "\(s) of \(next) weeks", Double(s) / Double(next)))
        }
        for name in nearPRLifts() { items.append((name.0, name.1, name.2)) }
        return PadPane(title: "Close to") {
            if items.isEmpty { PadEmptyLine(text: "Nothing close right now.") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(it.0).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                        Spacer()
                        PadLab(it.1, size: 12)
                    }
                    PadBar(fraction: it.2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Main lifts whose latest session was within 3% of their best.
    private func nearPRLifts() -> [(String, String, Double)] {
        let ws = data.workouts[facts.id] ?? []
        var out: [(String, String, Double)] = []
        for name in ["Back Squat", "Bench Press", "Deadlift"] {
            let h = ProgressEngine.history(for: name, workouts: ws).sorted { $0.date < $1.date }
            guard h.count >= 3, let last = h.last?.estimatedOneRepMax else { continue }
            let best = h.dropLast().map { $0.estimatedOneRepMax }.max() ?? 0
            guard best > 0, last < best, last >= best * 0.97 else { continue }
            out.append(("\(name) PR", "\(StatsUnits.weightText(best - last)) under their best", last / best))
        }
        return out
    }

    private var shelfPane: some View {
        PadPane(title: "Trophy shelf", aside: awards.isEmpty ? nil : "\(awards.count)") {
            if awards.isEmpty { PadEmptyLine(text: "Awards come with streaks, PRs and milestones.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(awards.sorted { $0.earnedAt > $1.earnedAt }) { a in
                    VStack(spacing: 6) {
                        Image(systemName: UIImage(systemName: a.icon) == nil ? "trophy.fill" : a.icon)
                            .font(.system(size: 20, weight: .semibold)).foregroundColor(Pad.voltText)
                        Text(a.title).font(PadFont.cond(11)).foregroundColor(Pad.text).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
