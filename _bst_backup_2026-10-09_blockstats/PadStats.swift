import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's Stats (Oct 9, 2026)
//
// The client's phone Stats for the coach, nested like Clients: Stats › a lift › a session › a set.
// The list you came from stays on the left; the crumb bar and esc go back; ⌘[ ⌘] switch client at
// the same depth (a session or set belongs to one client, so those reset). Findings on every level.
// Replaces the lighter Stats section (PadClientStats, kept for its lift-goal editor).
// Synchronized folder: no target step needed.

struct PadStatsView: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var nav = PadStatsNav.shared
    @AppStorage("bst_pad_stats_window") private var windowRaw = StatsWindow.w12.rawValue
    @State private var vitals: [String: WorkoutVitals] = [:]
    @State private var ctx: PadStatsContext?
    @State private var loading = true

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .w12 }
    private var motionCount: Int { data.motion[facts.id]?.count ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(width: nav.depth == 0 ? 286 : 236)
            Rectangle().fill(Pad.line).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Pad.page)
        .task(id: facts.id) { await load() }
        .onChange(of: windowRaw) { _, _ in rebuild() }
        .onChange(of: data.loadedAt) { _, _ in rebuild() }
        .onChange(of: motionCount) { _, _ in rebuild() }
    }

    // MARK: Columns

    @ViewBuilder
    private var left: some View {
        if let ctx {
            switch nav.depth {
            case 0: PadStatsExploreList(ctx: ctx, narrow: false)
            case 1: PadStatsExploreList(ctx: ctx, narrow: true)
            case 2: PadStatsSessionList(ctx: ctx)
            default: PadStatsSetList(ctx: ctx)
            }
        } else {
            VStack(spacing: 10) { ForEach(0..<8, id: \.self) { _ in PadSkeleton(height: 44) } }.padding(14)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let ctx {
            if let setId = nav.setId, let sid = nav.sessionId {
                PadStatsSetView(ctx: ctx, sessionId: sid, setId: setId).id(setId)
            } else if let sid = nav.sessionId {
                PadStatsSessionView(ctx: ctx, sessionId: sid).id(sid)
            } else if let subject = nav.subject {
                PadStatsSubjectView(ctx: ctx, subject: subject).id(subject.id)
            } else {
                PadStatsHome(ctx: ctx)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                PadSkeleton(height: 120)
                HStack(spacing: 8) { ForEach(0..<5, id: \.self) { _ in PadSkeleton(height: 70) } }
                PadSkeleton(height: 260)
            }
            .padding(20)
        }
    }

    // MARK: Data

    private func load() async {
        // A session or set belongs to one client; the lift (or the home level) carries over.
        if nav.clientId != facts.id {
            nav.sessionId = nil; nav.setId = nil
            nav.clientId = facts.id
        }
        rebuild()
        await PadLiftGoals.shared.load(store: store)
        await data.loadContext(facts.id)
        if store.isLive, let rows = try? await APIClient.shared.trainerClientHealth(clientId: facts.id) {
            var v: [String: WorkoutVitals] = [:]
            for r in rows { v[r.workoutId] = r.toVitals() }
            vitals = v
        }
        loading = false
        rebuild()
        // A lift this client never did: back to their Stats.
        if case .exercise(let name)? = nav.subject, let c = ctx, !c.allTime.contains(where: { s in s.exercises.contains { $0.name == name } }) {
            nav.subject = nil
        }
    }

    private func rebuild() {
        ctx = PadStatsContext.make(facts: facts, window: window, vitals: vitals, store: store)
    }
}

// MARK: - The period picker (the phone's windows)

struct PadStatsWindowSeg: View {
    @AppStorage("bst_pad_stats_window") private var windowRaw = StatsWindow.w12.rawValue
    var body: some View {
        PadSeg(options: StatsWindow.allCases.map { (id: $0.rawValue, label: $0.rawValue) }, selection: $windowRaw)
    }
}

// MARK: - Left column, levels 0 and 1: every lift, workout, or SBD

struct PadStatsExploreList: View {
    let ctx: PadStatsContext
    let narrow: Bool
    @ObservedObject private var nav = PadStatsNav.shared
    @State private var q = ""

    struct Row: Identifiable {
        let id: String
        let title: String
        let sub: String
        let value: String
        let valueLabel: String
        let spark: [Double]
        let watch: Bool
        let subject: StatsSubject
        let group: Int          // 0 = SBD lifts, 1 = everything else
    }

    private var rows: [Row] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        let all: [Row]
        switch nav.explore {
        case .exercises: all = exerciseRows
        case .workouts: all = workoutRows
        case .sbd: all = sbdRows
        }
        return t.isEmpty ? all : all.filter { $0.title.lowercased().contains(t) }
    }

    private var exerciseRows: [Row] {
        var by: [String: [(Date, ExerciseStat)]] = [:]
        for s in ctx.allTime { for e in s.exercises { by[e.name, default: []].append((s.date, e)) } }
        let rows: [Row] = by.map { entry in
            let name = entry.key
            let sorted = entry.value.sorted { $0.0 < $1.0 }
            let best = sorted.map { $0.1.bestE1RM }.max() ?? 0
            let last = sorted.last?.0 ?? Date.distantPast
            let sbd = SBDLift.classify(name) != nil
            let sub = "\(sorted.count.plural("session")) · last \(last.formatted(.dateTime.month(.abbreviated).day()))"
            return Row(id: "ex|" + name, title: name, sub: sub, value: StatsUnits.weightText(best, unit: false), valueLabel: "e1RM",
                       spark: sorted.suffix(10).map { $0.1.bestE1RM }, watch: sorted.contains { $0.1.hasMotion },
                       subject: .exercise(name), group: sbd ? 0 : 1)
        }
        return rows.sorted { a, b in a.group != b.group ? a.group < b.group : a.title < b.title }
    }

    private var workoutRows: [Row] {
        var by: [String: [StatsSession]] = [:]
        for s in ctx.allTime { by[s.title, default: []].append(s) }
        return by.map { entry in
            let title = entry.key, list = entry.value
            let last = list.map { $0.date }.max() ?? Date.distantPast
            let sub = "\(list.count.plural("session")) · last \(last.formatted(.dateTime.month(.abbreviated).day()))"
            return Row(id: "wo|" + title, title: title, sub: sub, value: StatsUnits.weightText(list.last?.volume ?? 0, unit: false),
                       valueLabel: "volume", spark: list.suffix(10).map { $0.volume }, watch: list.contains { $0.hasMotion },
                       subject: .workout(title), group: 1)
        }
        .sorted { $0.title < $1.title }
    }

    private var sbdRows: [Row] {
        let lifts = exerciseRows.filter { $0.group == 0 }
        let total = Row(id: "sbd", title: "Squat · Bench · Deadlift", sub: "Total and all three lifts together", value: "", valueLabel: "",
                        spark: [], watch: false, subject: .sbd, group: 0)
        return [total] + lifts
    }

    var body: some View {
        let rs = rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Explore").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("\(rs.count)", color: Pad.faint, size: 12)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if !narrow {
                PadSeg(options: PadStatsExplore.allCases.map { (id: $0, label: $0.rawValue) }, selection: $nav.explore)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.faint)
                    TextField("Find a lift", text: $q).font(PadFont.ui(14)).foregroundColor(Pad.text).autocorrectionDisabled()
                }
                .padInput()
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rs.enumerated()), id: \.element.id) { i, r in
                        if i == 0 || rs[i - 1].group != r.group { groupLabel(r.group) }
                        row(r)
                    }
                    if rs.isEmpty {
                        PadEmptyLine(text: q.isEmpty ? "Nothing logged yet." : "Nothing matches.").padding(.horizontal, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupLabel(_ g: Int) -> some View {
        if nav.explore == .exercises {
            PadLab(g == 0 ? "Squat · bench · deadlift" : "Everything else", color: Pad.faint, size: 12)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
        }
    }

    private func row(_ r: Row) -> some View {
        let on = nav.subject == r.subject
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) { nav.setId = nil; nav.sessionId = nil; nav.subject = r.subject }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(r.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        if r.watch { Image(systemName: "applewatch").font(.system(size: 10, weight: .semibold)).foregroundColor(Pad.mute) }
                    }
                    if !narrow { Text(r.sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if r.spark.count >= 2 { PadSpark(values: r.spark, color: narrow ? Pad.mute : Pad.text).frame(width: narrow ? 40 : 56, height: narrow ? 14 : 18) }
                if !narrow && !r.value.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(r.value).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                        Text(r.valueLabel).font(PadFont.cond(11)).foregroundColor(Pad.faint)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, narrow ? 11 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.raised : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Level 0: the client's Stats

struct PadStatsHome: View {
    let ctx: PadStatsContext
    @ObservedObject private var nav = PadStatsNav.shared
    @State private var month: Date = Calendar.training.date(from: Calendar.training.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selectedDay: Date?

    private var cal: Calendar { Calendar.training }

    var body: some View {
        let notes = PadStatsFindings.home(ctx)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PadLab("Everything \(ctx.first) has logged, \(ctx.windowLabel)", size: 13)
                    Spacer()
                    PadStatsWindowSeg()
                }
                PadPane(title: "What the numbers say", aside: notes.isEmpty ? nil : ctx.windowLabel) {
                    if notes.isEmpty {
                        PadEmptyLine(text: ctx.sessions.isEmpty ? "No logged sessions in the \(ctx.windowLabel)." : "Nothing stands out in the \(ctx.windowLabel).")
                    } else {
                        PadFindings(notes: notes, columns: 2, limit: 4)
                    }
                }
                strip
                HStack(alignment: .top, spacing: 12) {
                    strengthPane.frame(maxWidth: .infinity)
                    PadStatsMonth(ctx: ctx, month: $month, selected: $selectedDay).frame(width: 300)
                }
                trends
            }
            .padding(20)
        }
    }

    // MARK: Strip

    private var strip: some View {
        let weekStart = cal.startOfWeek(for: Date())
        let lastStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let thisW = ctx.allTime.filter { $0.date >= weekStart }
        let lastW = ctx.allTime.filter { $0.date >= lastStart && $0.date < weekStart }
        let planned = ctx.workouts.filter { $0.date >= weekStart && $0.date < weekEnd }.count
        let sets = thisW.map { $0.setCount }.reduce(0, +), lastSets = lastW.map { $0.setCount }.reduce(0, +)
        let vol = thisW.map { $0.volume }.reduce(0, +), lastVol = lastW.map { $0.volume }.reduce(0, +)
        let volText: String = lastVol > 0 ? String(format: "%+.0f", (vol - lastVol) / lastVol * 100) : "—"
        let setDelta = sets - lastSets
        let setSub: String = lastSets == 0 ? "none last week" : (setDelta >= 0 ? "+\(setDelta) on last week" : "\(setDelta) on last week")
        let streak = weekStreak()
        let sbd = sbdTotal()
        let sessionsSub: String = planned > thisW.count ? "\(planned - thisW.count) still planned" : "all done"
        let sbdValue: String = sbd.map { StatsUnits.weightText($0.now, unit: false) } ?? "—"
        let sbdUnit: String? = sbd == nil ? nil : StatsUnits.weightLabel
        let sbdChange: Double = sbd?.change ?? 0
        let sbdSub: String = sbd == nil ? "needs all three lifts" : (sbdChange >= 0 ? "+\(StatsUnits.weightText(sbdChange)) in the period" : "−\(StatsUnits.weightText(-sbdChange)) in the period")
        let sbdColor: Color = sbdChange > 0 ? Pad.voltText : Pad.mute
        let setColor: Color = setDelta > 0 ? Pad.voltText : Pad.mute
        let streakColor: Color = streak >= 4 ? Pad.voltText : Pad.mute
        let volUnit: String? = lastVol > 0 ? "%" : nil
        return HStack(spacing: 8) {
            PadStatsTile(label: "Sessions this week", value: "\(thisW.count)", unit: "of \(max(planned, thisW.count))", sub: sessionsSub)
            PadStatsTile(label: "Sets this week", value: "\(sets)", sub: setSub, subColor: setColor)
            PadStatsTile(label: "Week streak", value: "\(streak)", unit: "wks", sub: "at least one session", subColor: streakColor)
            PadStatsTile(label: "SBD total", value: sbdValue, unit: sbdUnit, sub: sbdSub, subColor: sbdColor)
            PadStatsTile(label: "Volume", value: volText, unit: volUnit, sub: "this week vs last")
        }
    }

    private func weekStreak() -> Int {
        let weeks = Set(ctx.allTime.map { cal.startOfWeek(for: $0.date) })
        var week = cal.startOfWeek(for: Date())
        if !weeks.contains(week) { week = cal.date(byAdding: .weekOfYear, value: -1, to: week) ?? week }
        var n = 0
        while weeks.contains(week) {
            n += 1
            week = cal.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        return n
    }

    /// The SBD total panel from the phone's engine: latest and change over the window.
    private func sbdTotal() -> (now: Double, change: Double)? {
        let s = ctx.sessions(for: .sbd)
        let panels = ctx.engine.panels(for: .sbd, sessions: s, categories: [.weight], sensors: [], bodyweightLb: nil, womensDOTS: nil)
        guard let total = panels.first(where: { $0.id == "sbd-total" })?.primary?.points, let l = total.last, let f = total.first else { return nil }
        // Panel values are in display units already; convert back to lb for weightText.
        let toLb: Double = StatsUnits.isKg ? 1 / 0.45359237 : 1
        return (l.value * toLb, (l.value - f.value) * toLb)
    }

    // MARK: Strength

    private struct LiftLine: Identifiable {
        let id: String
        let name: String
        let label: String
        let color: Color
        let points: [StatPoint]
    }

    private var lifts: [LiftLine] {
        var out: [LiftLine] = []
        for lift in SBDLift.allCases {
            let pts: [StatPoint] = ctx.sessions.compactMap { s in
                s.exercises.filter { $0.sbd == lift }.map { $0.bestE1RM }.max().map { StatPoint(date: s.date, value: StatsUnits.weight($0)) }
            }
            guard !pts.isEmpty else { continue }
            let name = mostTrained(lift)
            out.append(LiftLine(id: lift.rawValue, name: name, label: lift.rawValue, color: lift.color, points: pts))
        }
        return out
    }

    private func mostTrained(_ lift: SBDLift) -> String {
        var count: [String: Int] = [:]
        for s in ctx.sessions { for e in s.exercises where e.sbd == lift { count[e.name, default: 0] += 1 } }
        return count.max { $0.value < $1.value }?.key ?? lift.rawValue
    }

    private var strengthPane: some View {
        let ls = lifts
        let series: [StatSeries] = ls.map { StatSeries(name: $0.label, color: $0.color, style: .line, points: $0.points) }
        return PadPane(title: "Strength", aside: "estimated 1RM · tap a lift for every chart") {
            if ls.isEmpty {
                PadEmptyLine(text: "No squat, bench or deadlift in the \(ctx.windowLabel).")
            } else {
                HStack(spacing: 10) {
                    ForEach(ls) { l in liftTile(l) }
                }
                PadStatChart(series: series, format: { "\(Int($0.rounded()))" }, height: 170) { d in openSession(on: d) }
                Button { withAnimation(.easeInOut(duration: 0.22)) { nav.subject = .sbd } } label: {
                    Label("Total and every chart", systemImage: "chevron.right")
                }
                .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
            }
        }
    }

    private func liftTile(_ l: LiftLine) -> some View {
        let last = l.points.last?.value ?? 0, first = l.points.first?.value ?? 0
        let change = last - first
        let sub: String = l.points.count < 2 ? "est. 1RM" : (abs(change) < 0.5 ? "flat" : (change > 0 ? "+\(Int(change.rounded()))" : "−\(Int((-change).rounded()))"))
        let subColor: Color = change > 0.5 ? Pad.voltText : (change < -0.5 ? Pad.orange : Pad.mute)
        return Button { withAnimation(.easeInOut(duration: 0.22)) { nav.subject = .exercise(l.name) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Capsule().fill(l.color).frame(width: 10, height: 3)
                    Text(l.label).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
                PadNumber(value: "\(Int(last.rounded()))", unit: StatsUnits.weightLabel, size: 28)
                Text(sub).font(PadFont.cond(12)).foregroundColor(subColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func openSession(on d: Date) {
        guard let s = ctx.allTime.first(where: { $0.date == d }) ?? ctx.allTime.first(where: { cal.isDate($0.date, inSameDayAs: d) }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            nav.sessionLabel = s.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            nav.sessionId = s.id
        }
    }

    // MARK: Trends

    private var trends: some View {
        let speedPts: [StatPoint] = ctx.sessions.filter { $0.hasMotion }.map { s in
            StatPoint(date: s.date, value: s.reps.map { $0.meanVelocity }.reduce(0, +) / Double(max(s.reps.count, 1)))
        }
        let rpePts: [StatPoint] = ctx.sessions.compactMap { s in s.avgRPE.map { StatPoint(date: s.date, value: $0) } }
        let hrPts: [StatPoint] = ctx.sessions.compactMap { s in s.hr.map { StatPoint(date: s.date, value: Double($0.avg)) } }
        let speed = StatPanel(id: "t-speed", category: .sensor, title: "Bar speed, every tracked set", series: [StatSeries(name: "Avg", color: Pad.text, style: .line, points: speedPts)],
                              format: { String(format: "%.2f m/s", $0) }, axisUnit: "m/s", higherIsBetter: nil)
        let effort = StatPanel(id: "t-rpe", category: .weight, title: "Effort per session", series: [StatSeries(name: "RPE", color: Pad.text, style: .line, points: rpePts)],
                               format: { String(format: "%.1f", $0) }, axisUnit: "RPE", higherIsBetter: nil)
        let heart = StatPanel(id: "t-hr", category: .heartRate, title: "Heart rate per session", series: [StatSeries(name: "Avg", color: Pad.text, style: .line, points: hrPts)],
                              format: { "\(Int($0.rounded())) bpm" }, axisUnit: "avg", higherIsBetter: nil)
        return HStack(alignment: .top, spacing: 10) {
            PadStatCard(panel: speed) { d in openSession(on: d) }
            PadStatCard(panel: effort) { d in openSession(on: d) }
            PadStatCard(panel: heart) { d in openSession(on: d) }
            balanceCard
        }
    }

    private var balanceCard: some View {
        var by: [String: Int] = [:]
        for s in ctx.sessions { for e in s.exercises { by[e.muscleGroup.isEmpty ? "Other" : e.muscleGroup, default: 0] += e.sets.count } }
        let rows = by.sorted { $0.value > $1.value }.prefix(6).map { (name: $0.key, sets: $0.value) }
        let mx = Double(max(rows.first?.sets ?? 1, 1))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Balance").font(PadFont.cond(12)).foregroundColor(Pad.mute)
                Spacer()
                Text("sets per muscle").font(PadFont.cond(11)).foregroundColor(Pad.faint)
            }
            if rows.isEmpty { PadEmptyLine(text: "Nothing logged.") }
            ForEach(rows, id: \.name) { r in
                HStack(spacing: 8) {
                    Text(r.name).font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: 76, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Pad.raised)
                            Capsule().fill(Pad.text).frame(width: max(4, g.size.width * CGFloat(Double(r.sets) / mx)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(r.sets)").font(PadFont.cond(12)).foregroundColor(Pad.text).frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }
}

// MARK: - The month (done, PR, planned, today); tap a day, then a session

struct PadStatsMonth: View {
    let ctx: PadStatsContext
    @Binding var month: Date
    @Binding var selected: Date?
    @ObservedObject private var nav = PadStatsNav.shared

    private var cal: Calendar { Calendar.training }

    private var cells: [Date?] {
        let first = month
        let wd = (cal.component(.weekday, from: first) + 5) % 7      // Monday = 0
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead: [Date?] = Array(repeating: nil, count: wd)
        let days: [Date?] = (0..<count).map { cal.date(byAdding: .day, value: $0, to: first) }
        return lead + days
    }

    private var doneDays: Set<Date> { Set(ctx.allTime.map { cal.startOfDay(for: $0.date) }) }
    private var prDays: Set<Date> { Set(ctx.prs.filter { !$0.isFirstEver }.map { cal.startOfDay(for: $0.date) }) }
    private var plannedDays: Set<Date> {
        let today = cal.startOfDay(for: Date())
        return Set(ctx.workouts.filter { !$0.completed && $0.date >= today }.map { cal.startOfDay(for: $0.date) })
    }
    private var day: Date? { selected ?? ctx.allTime.last.map { cal.startOfDay(for: $0.date) } }

    var body: some View {
        let done = doneDays, prs = prDays, planned = plannedDays
        let daySessions = ctx.allTime.filter { s in day.map { cal.isDate(s.date, inSameDayAs: $0) } ?? false }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadIconButton(systemName: "chevron.left", label: "Previous month", small: true) { shift(-1) }
                PadIconButton(systemName: "chevron.right", label: "Next month", small: true) { shift(1) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"], id: \.self) { d in
                    Text(d).font(PadFont.cond(11)).foregroundColor(Pad.faint)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d { cell(d, done: done.contains(d), pr: prs.contains(d), planned: planned.contains(d)) }
                    else { Color.clear.frame(height: 34) }
                }
            }
            PadRule()
            if daySessions.isEmpty {
                PadEmptyLine(text: day.map { "Nothing logged on \($0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))." } ?? "Pick a day.")
            }
            ForEach(daySessions) { s in sessionRow(s, pr: prs.contains(cal.startOfDay(for: s.date))) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func shift(_ n: Int) { month = cal.date(byAdding: .month, value: n, to: month) ?? month }

    private func cell(_ d: Date, done: Bool, pr: Bool, planned: Bool) -> some View {
        let isSel = day.map { cal.isDate($0, inSameDayAs: d) } ?? false
        let today = cal.isDateInToday(d)
        let fill: Color = isSel ? Pad.text : (done ? Pad.raised : Color.clear)
        let fg: Color = isSel ? Pad.page : (done || planned || today ? Pad.text : Pad.mute)
        let dot: Color = pr ? Pad.volt : (isSel ? Pad.page : Pad.text)
        let ring: Color = today ? (Pad.isLight ? Pad.text : Pad.volt) : (planned ? Pad.line2 : Color.clear)
        let a11y: String = d.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (done ? ", trained" : "") + (pr ? ", PR" : "") + (planned ? ", planned" : "")
        return Button { selected = d } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: d))").font(PadFont.ui(13, .semibold)).foregroundColor(fg)
                Circle().fill(done ? dot : Color.clear).frame(width: pr ? 6 : 5, height: pr ? 6 : 5)
                    .overlay(Circle().stroke(planned && !done ? Pad.mute : Color.clear, lineWidth: 1.2))
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ring, lineWidth: today ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(a11y)
    }

    private func sessionRow(_ s: StatsSession, pr: Bool) -> some View {
        let dur: String? = s.durationMin.map { "\($0) min" }
        let hr: String? = s.hr.map { "avg HR \($0.avg)" }
        let rpe: String? = s.avgRPE.map { "RPE \($0.rpeText)" }
        let parts: [String?] = [dur, "\(s.setCount) sets", hr, rpe]
        let bits: [String] = parts.compactMap { $0 }
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                nav.sessionLabel = s.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                nav.sessionId = s.id
            }
        } label: {
            HStack(spacing: 10) {
                if pr { PadTag(text: "PR", kind: .volt) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(bits.joined(separator: " · ")).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.faint)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}
