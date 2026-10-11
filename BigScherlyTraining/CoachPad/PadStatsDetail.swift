import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Stats levels 1–3 (Oct 9, 2026)
//
// Level 1: one lift (or a workout, or SBD): every chart at once, the sessions beside the main one.
// Level 2: one session: heart rate through it, each exercise set by set.
// Level 3: one set, rep by rep: speed, depth, tempo, and every rep.
// Synchronized folder: no target step needed.

private func padDayLabel(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

@MainActor
private func openSession(_ s: StatsSession) {
    let nav = PadStatsNav.shared
    withAnimation(.easeInOut(duration: 0.22)) {
        nav.setId = nil
        nav.sessionLabel = padDayLabel(s.date)
        nav.sessionId = s.id
    }
}

// MARK: - Level 1

struct PadStatsSubjectView: View {
    let ctx: PadStatsContext
    let subject: StatsSubject
    @State private var categories: Set<StatCategory> = [.weight, .sensor, .heartRate]
    @State private var allSensors = false
    @State private var goalOpen = false
    @ObservedObject private var goals = PadLiftGoals.shared

    private var sessions: [StatsSession] { ctx.sessions(for: subject) }
    private var sensorSet: Set<SensorMetric> { allSensors ? Set(SensorMetric.allCases) : [.speed, .speedLoss, .depth, .tempo] }

    private var exerciseName: String? {
        if case .exercise(let n) = subject { return n }
        return nil
    }

    var body: some View {
        let ss = sessions
        let panels = ctx.engine.panels(for: subject, sessions: ss, categories: categories, sensors: sensorSet, bodyweightLb: nil, womensDOTS: nil)
            .filter { $0.hasData }
        let main = panels.first { $0.category == .weight }
        let rest = panels.filter { $0.id != main?.id }
        let notes = PadStatsFindings.subject(ctx, subject: subject, sessions: ss) + goalNotes(ss)
        let tracked = ss.filter { $0.hasMotion }.count
        let withHR = ss.filter { $0.hr != nil }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(subject.title == "SBD" ? "Squat · Bench · Deadlift" : subject.title)
                            .font(PadFont.display(36)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
                        PadLab(subtitle(ss.count, tracked: tracked), size: 13)
                    }
                    Spacer(minLength: 8)
                    if let name = exerciseName { goalButton(name, sessions: ss) }
                    chip("Weight", .weight, enabled: true)
                    chip("Sensor", .sensor, enabled: tracked > 0)
                    chip("Heart rate", .heartRate, enabled: withHR > 0)
                    PadStatsWindowSeg()
                }
                if !notes.isEmpty { PadFindings(notes: notes, columns: 3, limit: 3) }
                strip(ss)
                if ss.isEmpty {
                    PadPane(title: "Nothing in this period") { PadEmptyLine(text: "No sessions in the \(ctx.windowLabel). Try a longer period.") }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        if let main { mainChart(main, sessions: ss).frame(maxWidth: .infinity) }
                        sessionTable(ss).frame(width: 390)
                    }
                    if !rest.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4), alignment: .leading, spacing: 10) {
                            ForEach(rest) { p in
                                PadStatCard(panel: p) { d in pick(d, in: ss) }
                            }
                        }
                    }
                    if categories.contains(.sensor) && tracked > 0 {
                        Button(allSensors ? "Fewer sensor charts" : "Every sensor chart: pause, time under tension, sticking point, grinds, consistency, drift, reps") {
                            withAnimation(.easeOut(duration: 0.2)) { allSensors.toggle() }
                        }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: Lift goal (kept on the server with the coach's settings, key "clientLiftGoals")

    private func best(_ name: String, _ ss: [StatsSession]) -> Double {
        ss.compactMap { s in s.exercises.filter { $0.name == name }.map { $0.bestE1RM }.max() }.last ?? 0
    }

    private func goalButton(_ name: String, sessions ss: [StatsSession]) -> some View {
        let g = goals.goal(ctx.facts.id, lift: name)
        let label: String = g.map { goalLabel($0) } ?? "Set a goal"
        return Button(label) { goalOpen = true }
            .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            .popover(isPresented: $goalOpen) {
                PadGoalEditor(clientId: ctx.facts.id, lift: name, current: best(name, ss))
            }
    }

    private func goalLabel(_ g: PadLiftGoal) -> String {
        let target: String = StatsUnits.weightText(g.target, unit: false)
        guard let d = PadLiftGoals.stamp.date(from: g.by) else { return "Goal \(target)" }
        let when: String = d.formatted(.dateTime.month(.abbreviated).day())
        return "Goal \(target) by \(when)"
    }

    private var goalReference: StatReference? {
        guard let name = exerciseName, let g = goals.goal(ctx.facts.id, lift: name) else { return nil }
        return StatReference(label: "Goal \(StatsUnits.weightText(g.target, unit: false))", value: StatsUnits.weight(g.target), color: Pad.blue)
    }

    /// On pace or behind for the lift goal, from the rate over the period.
    private func goalNotes(_ ss: [StatsSession]) -> [PadNote] {
        guard let name = exerciseName, let g = goals.goal(ctx.facts.id, lift: name), let by = PadLiftGoals.stamp.date(from: g.by) else { return [] }
        let pts: [(Date, Double)] = ss.compactMap { s in s.exercises.filter { $0.name == name }.map { $0.bestE1RM }.max().map { (s.date, $0) } }
        guard let f = pts.first, let l = pts.last else { return [] }
        let dateText = by.formatted(.dateTime.month(.abbreviated).day())
        let target = StatsUnits.weightText(g.target)
        if l.1 >= g.target {
            return [PadNote(icon: "flag.checkered", tint: Pad.voltText, text: "Goal reached: \(target).", aside: "Estimated 1RM \(StatsUnits.weightText(l.1)).")]
        }
        let weeksLeft = max(0.5, by.timeIntervalSince(Date()) / (7 * 86_400))
        let span = max(1, l.0.timeIntervalSince(f.0) / (7 * 86_400))
        let needed = (g.target - l.1) / weeksLeft
        let rate = (l.1 - f.1) / span
        let aside = "Needs about \(StatsUnits.weightText(needed)) a week; lately \(StatsUnits.weightText(max(rate, 0))) a week."
        if rate >= needed {
            return [PadNote(icon: "flag", tint: Pad.voltText, text: "On pace for \(target) by \(dateText).", aside: aside)]
        }
        return [PadNote(icon: "flag", tint: Pad.orange, text: "Behind pace for \(target) by \(dateText).", aside: aside)]
    }

    private func subtitle(_ n: Int, tracked: Int) -> String {
        var s = "\(n.plural("session")) in the \(ctx.windowLabel)"
        if tracked > 0 { s += " · \(tracked) tracked by the Watch" }
        return s
    }

    private func chip(_ t: String, _ c: StatCategory, enabled: Bool) -> some View {
        PadChip(text: t, on: categories.contains(c) && enabled) {
            guard enabled else { return }
            if categories.contains(c) { categories.remove(c) } else { categories.insert(c) }
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private func pick(_ d: Date, in ss: [StatsSession]) {
        if let s = ss.first(where: { $0.date == d }) { openSession(ctx.session(s.id) ?? s) }
    }

    // MARK: Strip

    @ViewBuilder
    private func strip(_ ss: [StatsSession]) -> some View {
        switch subject {
        case .exercise(let name): exerciseStrip(name, ss)
        case .sbd: sbdStrip(ss)
        default: workoutStrip(ss)
        }
    }

    private func exerciseStrip(_ name: String, _ ss: [StatsSession]) -> some View {
        let pts: [Double] = ss.compactMap { s in s.exercises.filter { $0.name == name }.map { $0.bestE1RM }.max() }
        let now = pts.last ?? 0, first = pts.first ?? 0
        let ever = ctx.allTime.flatMap { $0.exercises.filter { $0.name == name } }.map { $0.bestE1RM }.max() ?? 0
        let pr = ctx.prs.filter { $0.exercise == name }.max { $0.estimatedOneRepMax < $1.estimatedOneRepMax }
        let speed1RM = ss.last.flatMap { ctx.engine.velocityE1RM(exerciseName: name, asOf: $0.date, sessions: ss) }
        let lastSets = ss.last?.exercises.filter { $0.name == name }.flatMap { $0.sets } ?? []
        let top = lastSets.max(by: padLighterSet)
        let losses: [Double] = ss.compactMap { s in
            let l = s.exercises.filter { $0.name == name }.flatMap { $0.motions.compactMap { $0.velocityLossPct } }
            return l.isEmpty ? nil : l.reduce(0, +) / Double(l.count)
        }
        let change = now - first
        let inWhat: String = ctx.program == nil ? "in the period" : "in the block"
        let changeText: String = pts.count < 2 ? "est. 1RM" : (change >= 0 ? "+\(StatsUnits.weightText(change)) \(inWhat)" : "−\(StatsUnits.weightText(-change)) \(inWhat)")
        let everAll = ctx.history.flatMap { $0.exercises.filter { $0.name == name } }.map { $0.bestE1RM }.max() ?? 0
        let prSub: String = pr.map { "PR · \($0.date.formatted(.dateTime.month(.abbreviated).day()))" } ?? "all time"
        let bestLabel: String = ctx.program == nil ? "Best ever" : "Best in block"
        let bestSub: String = ctx.program == nil ? prSub : "best ever " + StatsUnits.weightText(everAll)
        let lossFirst = losses.first ?? 0, lossNow = losses.last ?? 0
        let lossSub: String = losses.count < 2 ? "per set" : "was \(Int(lossFirst.rounded()))% at the start"
        return HStack(spacing: 8) {
            PadStatsTile(label: "Est. 1RM", value: StatsUnits.weightText(now, unit: false), unit: StatsUnits.weightLabel, sub: changeText, subColor: change > 0 ? Pad.voltText : Pad.mute)
            PadStatsTile(label: bestLabel, value: StatsUnits.weightText(ever, unit: false), unit: StatsUnits.weightLabel, sub: bestSub)
            PadStatsTile(label: "Speed-based 1RM", value: speed1RM.map { StatsUnits.weightText($0, unit: false) } ?? "—", unit: speed1RM == nil ? nil : StatsUnits.weightLabel,
                         sub: speed1RM == nil ? "needs more tracked sets" : "from the load–speed line")
            PadStatsTile(label: "Top set, last session", value: top.map { StatsUnits.weightText($0.weight, unit: false) } ?? "—", unit: top.map { "× \($0.reps)" },
                         sub: ss.last.map { padDayLabel($0.date) } ?? "")
            PadStatsTile(label: "Speed loss per set", value: losses.isEmpty ? "—" : "\(Int(lossNow.rounded()))", unit: losses.isEmpty ? nil : "%", sub: lossSub,
                         subColor: lossNow - lossFirst >= 6 ? Pad.orange : Pad.mute)
        }
    }

    private func sbdStrip(_ ss: [StatsSession]) -> some View {
        let panels = ctx.engine.panels(for: .sbd, sessions: ss, categories: [.weight], sensors: [], bodyweightLb: nil, womensDOTS: nil)
        let total = panels.first { $0.id == "sbd-total" }?.primary?.points
        let totalNow: String = total?.last.map { "\(Int($0.value.rounded()))" } ?? "—"
        let totalChange: Double = (total?.last?.value ?? 0) - (total?.first?.value ?? 0)
        let e = panels.first { $0.id == "e1rm" }
        let totalFmt: String = ctx.program == nil ? "%+.0f in the period" : "%+.0f in the block"
        let totalSub: String = (total?.count ?? 0) < 2 ? "needs all three lifts" : String(format: totalFmt, totalChange)
        return HStack(spacing: 8) {
            PadStatsTile(label: "SBD total", value: totalNow, unit: StatsUnits.weightLabel,
                         sub: totalSub,
                         subColor: totalChange > 0 ? Pad.voltText : Pad.mute)
            ForEach(SBDLift.allCases) { l in
                let pts = e?.series.first { $0.name == l.rawValue }?.points ?? []
                let now: String = pts.last.map { "\(Int($0.value.rounded()))" } ?? "—"
                let ch: Double = (pts.last?.value ?? 0) - (pts.first?.value ?? 0)
                PadStatsTile(label: l.rawValue, value: now, unit: pts.isEmpty ? nil : StatsUnits.weightLabel,
                             sub: pts.count < 2 ? "est. 1RM" : String(format: "%+.0f", ch), subColor: ch > 0 ? Pad.voltText : Pad.mute)
            }
        }
    }

    private func workoutStrip(_ ss: [StatsSession]) -> some View {
        let durations = ss.compactMap { $0.durationMin }
        let avgDur: String = durations.isEmpty ? "—" : "\(durations.reduce(0, +) / durations.count)"
        let vol = ss.last?.volume ?? 0, vol0 = ss.first?.volume ?? 0
        let rpe = ss.compactMap { $0.avgRPE }
        let avgRPE: String = rpe.isEmpty ? "—" : (rpe.reduce(0, +) / Double(rpe.count)).rpeText
        return HStack(spacing: 8) {
            PadStatsTile(label: "Sessions", value: "\(ss.count)", sub: ctx.windowLabel)
            PadStatsTile(label: "Duration", value: avgDur, unit: durations.isEmpty ? nil : "min", sub: "average")
            PadStatsTile(label: "Volume, last session", value: StatsUnits.weightText(vol, unit: false), unit: StatsUnits.weightLabel,
                         sub: vol0 > 0 && ss.count >= 2 ? String(format: "%+.0f%% on the first", (vol - vol0) / vol0 * 100) : "")
            PadStatsTile(label: "Sets, last session", value: "\(ss.last?.setCount ?? 0)", sub: "logged")
            PadStatsTile(label: "Effort", value: avgRPE, unit: rpe.isEmpty ? nil : "RPE", sub: "average")
        }
    }

    // MARK: Main chart and sessions

    private func mainChart(_ p: StatPanel, sessions ss: [StatsSession]) -> some View {
        let refs: [StatReference] = p.references + (p.id == "strength" ? [goalReference].compactMap { $0 } : [])
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.title).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("tap a point for that session", color: Pad.faint, size: 12)
            }
            PadStatLegend(series: p.series, references: refs)
            PadStatChart(series: p.series, references: refs, format: { v in p.axisUnit.isEmpty ? String(format: "%.0f", v) : "\(Int(v.rounded()))" }, height: 230) { d in pick(d, in: ss) }
            if let c = p.caption { PadLab(c, color: Pad.faint, size: 12) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private struct SessionLine: Identifiable {
        let id: String
        let session: StatsSession
        let date: String
        let top: String
        let e1rm: String
        let volume: String
        let rpe: String
        let speed: String
        let pr: Bool
    }

    private func lines(_ ss: [StatsSession]) -> [SessionLine] {
        let prDays = Set(ctx.prs.filter { p in !p.isFirstEver && (exerciseName == nil || p.exercise == exerciseName) }.map { Calendar.training.startOfDay(for: $0.date) })
        return ss.reversed().map { s in
            let sets = s.exercises.flatMap { $0.sets }
            let top = sets.max(by: padLighterSet)
            let topText: String = top.map { "\(StatsUnits.weightText($0.weight, unit: false)) × \($0.reps)" } ?? "—"
            let e: String = s.exercises.map { $0.bestE1RM }.max().map { StatsUnits.weightText($0, unit: false) } ?? "—"
            let reps = s.reps
            let sp: String = reps.isEmpty ? "—" : String(format: "%.2f", reps.map { $0.meanVelocity }.reduce(0, +) / Double(reps.count))
            return SessionLine(id: s.id, session: s, date: s.date.formatted(.dateTime.month(.abbreviated).day()), top: topText, e1rm: e,
                               volume: StatsUnits.weightText(s.volume, unit: false), rpe: s.avgRPE.map { $0.rpeText } ?? "—", speed: sp,
                               pr: prDays.contains(Calendar.training.startOfDay(for: s.date)))
        }
    }

    private func sessionTable(_ ss: [StatsSession]) -> some View {
        let rows = lines(ss)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("\(rows.count) · newest first", color: Pad.faint, size: 12)
            }
            HStack(spacing: 6) {
                head("Date").frame(width: 74, alignment: .leading)
                head("Top set").frame(maxWidth: .infinity, alignment: .leading)
                head("e1RM").frame(width: 44, alignment: .trailing)
                head("Volume").frame(width: 56, alignment: .trailing)
                head("RPE").frame(width: 32, alignment: .trailing)
                head("m/s").frame(width: 36, alignment: .trailing)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in tableRow(r) }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func head(_ t: String) -> some View { Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint) }

    private func tableRow(_ r: SessionLine) -> some View {
        Button { openSession(ctx.session(r.id) ?? r.session) } label: {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(r.date).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                    if r.pr { PadTag(text: "PR", kind: .volt) }
                }
                .frame(width: 74, alignment: .leading)
                Text(r.top).font(PadFont.ui(13)).foregroundColor(Pad.text).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Text(r.e1rm).font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 44, alignment: .trailing)
                Text(r.volume).font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 56, alignment: .trailing)
                Text(r.rpe).font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 32, alignment: .trailing)
                Text(r.speed).font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 36, alignment: .trailing)
            }
            .frame(minHeight: 36)
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Left column, level 2: this lift's sessions (or every session)

struct PadStatsSessionList: View {
    let ctx: PadStatsContext
    @ObservedObject private var nav = PadStatsNav.shared

    var body: some View {
        let list: [StatsSession] = nav.subject.map { ctx.sessions(for: $0) } ?? ctx.allTime
        let rows = Array(list.reversed().prefix(80))
        let prDays = Set(ctx.prs.filter { !$0.isFirstEver }.map { Calendar.training.startOfDay(for: $0.date) })
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(nav.subject?.title ?? "Every session").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(1)
                Spacer()
                PadLab("\(list.count)", color: Pad.faint, size: 12)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { s in row(s, pr: prDays.contains(Calendar.training.startOfDay(for: s.date))) }
                }
            }
        }
    }

    private func row(_ s: StatsSession, pr: Bool) -> some View {
        let on = nav.sessionId == s.id
        let top = s.exercises.flatMap { $0.sets }.max(by: padLighterSet)
        let topText: String? = top.map { "\(StatsUnits.weightText($0.weight, unit: false)) × \($0.reps)" }
        let rpeText: String? = s.avgRPE.map { "RPE \($0.rpeText)" }
        let parts: [String?] = [topText, rpeText]
        let sub: String = parts.compactMap { $0 }.joined(separator: " · ")
        let value: String = s.exercises.map { $0.bestE1RM }.max().map { StatsUnits.weightText($0, unit: false) } ?? ""
        return Button { openSession(ctx.session(s.id) ?? s) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(padDayLabel(s.date)).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                        if pr { PadTag(text: "PR", kind: .volt) }
                    }
                    Text(nav.subject == nil ? s.title : sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if nav.subject != nil, !value.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(value).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                        Text("e1RM").font(PadFont.cond(11)).foregroundColor(Pad.faint)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.raised : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Level 2: one session

struct PadStatsSessionView: View {
    let ctx: PadStatsContext
    let sessionId: String
    @ObservedObject private var nav = PadStatsNav.shared

    private var focus: String? {
        if case .exercise(let n)? = nav.subject { return n }
        return nil
    }

    var body: some View {
        if let s = ctx.session(sessionId) {
            content(s)
        } else {
            PadEmptyLine(text: "This session isn’t in the data any more.").padding(20)
        }
    }

    private func content(_ s: StatsSession) -> some View {
        let v = ctx.vitals[s.id]
        let notes = PadStatsFindings.session(ctx, s)
        let ordered = s.exercises.sorted { a, b in (a.name == focus ? 0 : 1) < (b.name == focus ? 0 : 1) }
        let times: String = timeLine(s, v)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(padDayLabel(s.date)) · \(s.title)").font(PadFont.display(36)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
                        PadLab(times, size: 13)
                    }
                    Spacer()
                }
                tiles(s, v)
                if !notes.isEmpty { PadFindings(notes: notes, columns: 2, limit: 4) }
                if let v, v.heartRateSeries.count >= 4 {
                    PadPane(title: "Heart rate through the session", aside: focus.map { "dots = \($0.lowercased()) sets" } ?? "dots = sets") {
                        PadSessionHeartChart(session: s, vitals: v, focus: focus ?? ordered.first?.name)
                            .frame(height: 170)
                    }
                }
                ForEach(ordered) { e in exerciseBlock(e, session: s, vitals: v) }
            }
            .padding(20)
        }
    }

    private func timeLine(_ s: StatsSession, _ v: WorkoutVitals?) -> String {
        var bits: [String] = []
        if let v { bits.append("\(v.start.padClock) to \(v.end.padClock)") }
        else {
            let times = s.exercises.flatMap { $0.sets.compactMap { $0.loggedAt } }.sorted()
            if let a = times.first, let b = times.last { bits.append("\(a.padClock) to \(b.padClock)") }
        }
        bits.append(s.exercises.count.plural("exercise"))
        bits.append(s.setCount.plural("set"))
        if s.hasMotion { bits.append("tracked by the Watch") }
        return bits.joined(separator: " · ")
    }

    private func tiles(_ s: StatsSession, _ v: WorkoutVitals?) -> some View {
        let others = ctx.history.filter { $0.title == s.title && $0.id != s.id }.compactMap { $0.durationMin }
        let usual: String = others.isEmpty ? "" : "usually \(others.reduce(0, +) / others.count)"
        let prev = ctx.history.last { $0.title == s.title && $0.date < s.date }
        let volSub: String = prev.map { p in p.volume > 0 ? String(format: "%+.0f%% on %@", (s.volume - p.volume) / p.volume * 100, p.date.formatted(.dateTime.month(.abbreviated).day())) : "" } ?? ""
        let volUp = (prev.map { s.volume > $0.volume }) ?? false
        return HStack(spacing: 8) {
            PadStatsTile(label: "Duration", value: s.durationMin.map { "\($0)" } ?? "—", unit: s.durationMin == nil ? nil : "min", sub: usual)
            PadStatsTile(label: "Heart rate", value: s.hr.map { "\($0.avg)" } ?? "—", unit: s.hr == nil ? nil : "avg", sub: s.hr.map { "peak \($0.peak)" } ?? "no Watch data")
            PadStatsTile(label: "Active calories", value: s.calories.map { "\($0)" } ?? "—", sub: s.calories == nil ? "" : "from Apple Health")
            PadStatsTile(label: "Volume", value: StatsUnits.weightText(s.volume, unit: false), unit: StatsUnits.weightLabel, sub: volSub, subColor: volUp ? Pad.voltText : Pad.mute)
            PadStatsTile(label: "Effort", value: s.avgRPE.map { $0.rpeText } ?? "—", unit: s.avgRPE == nil ? nil : "RPE", sub: "average of \(s.setCount.plural("set"))")
        }
    }

    // MARK: One exercise, set by set

    private struct SetLine: Identifiable {
        let id: String
        let set: SetStat
        let load: String
        let rpe: String
        let e1rm: String
        let speed: Double?
        let loss: String
        let depth: String
        let peakHR: String
        let note: String
        let pr: Bool
        let warn: Bool
    }

    private func setLines(_ e: ExerciseStat, session s: StatsSession, vitals v: WorkoutVitals?) -> [SetLine] {
        let pr = ctx.prs.first { $0.exercise == e.name && Calendar.training.isDate($0.date, inSameDayAs: s.date) && !$0.isFirstEver }
        return e.sets.map { st in
            let m = st.motion
            let sp: Double? = m.map { $0.meanVelocity }
            let lossV: Double? = m?.velocityLossPct
            var warn = false
            var note = ""
            if let rpe = st.rpe, let loss = lossV, let mm = m, mm.repCount >= 3 {
                let expected = StatsEngine.expectedRPE(velocityLoss: loss, grinds: mm.grindRepCount)
                if rpe - expected >= 1.5 { warn = true; note = "speed says ~\(expected.rpeText)" }
                else if expected - rpe >= 1.5 { warn = true; note = "harder than rated" }
            }
            var peak = "—"
            if let v, v.heartRateSeries.count > 1 {
                let from: Date? = m?.start ?? st.loggedAt?.addingTimeInterval(-60)
                let to: Date? = m?.end ?? st.loggedAt
                if let a = from, let b = to, let hr = HealthKitManager.heartRate(in: v.heartRateSeries, from: a, to: b.addingTimeInterval(15)) { peak = "\(hr.peak)" }
            }
            let isPR = pr.map { $0.weight == st.weight && $0.reps == st.reps } ?? false
            return SetLine(id: st.id, set: st, load: "\(StatsUnits.weightText(st.weight, unit: false)) × \(st.reps)", rpe: st.rpe.map { $0.rpeText } ?? "—",
                           e1rm: StatsUnits.weightText(st.e1RM, unit: false), speed: sp, loss: lossV.map { "\(Int($0.rounded()))%" } ?? "—",
                           depth: m.map { StatsUnits.depthText($0.averageTravelM) } ?? "—", peakHR: peak, note: note, pr: isPR, warn: warn)
        }
    }

    private func exerciseBlock(_ e: ExerciseStat, session s: StatsSession, vitals v: WorkoutVitals?) -> some View {
        let rows = setLines(e, session: s, vitals: v)
        let top = e.sets.max(by: padLighterSet)
        let topPart: String = top.map { " · top \(StatsUnits.weightText($0.weight, unit: false)) × \($0.reps)" } ?? ""
        let tapPart: String = e.hasMotion ? " · tap a set for every rep" : ""
        let aside: String = "\(e.sets.count.plural("set"))\(topPart)\(tapPart)"
        return PadPane(title: e.name, aside: aside) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    h("Set").frame(width: 34, alignment: .leading)
                    h("Load").frame(width: 90, alignment: .leading)
                    h("RPE").frame(width: 36, alignment: .trailing)
                    h("e1RM").frame(width: 50, alignment: .trailing)
                    h("Avg speed").frame(width: 140, alignment: .leading)
                    h("Speed loss").frame(width: 72, alignment: .trailing)
                    h("Depth").frame(width: 64, alignment: .trailing)
                    h("Peak HR").frame(width: 60, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
                ForEach(rows) { r in setRow(r) }
            }
        }
    }

    private func h(_ t: String) -> some View { Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint) }

    private func setRow(_ r: SetLine) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                nav.setLabel = "Set \(r.set.number)"
                nav.setId = r.id
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(r.set.number)").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).frame(width: 34, alignment: .leading)
                Text(r.load).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 90, alignment: .leading)
                Text(r.rpe).font(PadFont.ui(14)).foregroundColor(r.warn ? Pad.orange : Pad.text).frame(width: 36, alignment: .trailing)
                Text(r.e1rm).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 50, alignment: .trailing)
                Group {
                    if let sp = r.speed { PadSpeedBar(value: sp) } else { Text("—").font(PadFont.ui(14)).foregroundColor(Pad.faint) }
                }
                .frame(width: 140, alignment: .leading)
                Text(r.loss).font(PadFont.ui(14)).foregroundColor(r.warn ? Pad.orange : Pad.text).frame(width: 72, alignment: .trailing)
                Text(r.depth).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 64, alignment: .trailing)
                Text(r.peakHR).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 60, alignment: .trailing)
                HStack(spacing: 6) {
                    if r.pr { PadTag(text: "PR", kind: .volt) }
                    if !r.note.isEmpty { Text(r.note).font(PadFont.cond(12)).foregroundColor(Pad.orange).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Pad.faint)
            }
            .frame(minHeight: 40)
            .background(nav.setId == r.id ? Pad.raised : Color.clear)
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Heart rate across a session, each exercise as a band, the focus lift's sets as dots.
struct PadSessionHeartChart: View {
    let session: StatsSession
    let vitals: WorkoutVitals
    let focus: String?

    private struct Band { let name: String; let from: Date; let to: Date }

    private var bands: [Band] {
        session.exercises.compactMap { e in
            let times: [Date] = e.sets.flatMap { st -> [Date] in
                if let m = st.motion { return [m.start, m.end] }
                return st.loggedAt.map { [$0.addingTimeInterval(-45), $0] } ?? []
            }
            guard let a = times.min(), let b = times.max() else { return nil }
            return Band(name: e.name, from: a, to: b)
        }
    }

    private var marks: [(label: String, at: Date)] {
        guard let f = focus, let e = session.exercises.first(where: { $0.name == f }) else { return [] }
        return e.sets.compactMap { st -> (label: String, at: Date)? in
            guard let at = st.motion?.end ?? st.loggedAt else { return nil }
            return (label: "set \(st.number)", at: at)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let series = vitals.heartRateSeries
            guard let t0 = series.first?.time, let t1 = series.last?.time, t1 > t0 else { return }
            let lo = Double((series.map { $0.bpm }.min() ?? 80) - 10), hi = Double((series.map { $0.bpm }.max() ?? 170) + 8)
            let L: CGFloat = 36, R: CGFloat = 8, T: CGFloat = 22, B: CGFloat = 18
            let w = size.width, h = size.height
            func x(_ d: Date) -> CGFloat { L + (w - L - R) * CGFloat(d.timeIntervalSince(t0) / t1.timeIntervalSince(t0)) }
            func y(_ v: Double) -> CGFloat { T + (h - T - B) * CGFloat(1 - (v - lo) / (hi - lo)) }
            for (i, b) in bands.enumerated() {
                let r = CGRect(x: x(b.from), y: T - 18, width: max(4, x(b.to) - x(b.from)), height: h - B - T + 18)
                if b.name == focus || (focus == nil && i == 0) {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(Pad.raised.opacity(0.7)))
                }
                ctx.draw(Text(b.name).font(PadFont.cond(11)).foregroundColor(Pad.mute), at: CGPoint(x: r.minX + 6, y: T - 10), anchor: .leading)
            }
            for k in 0...2 {
                let v = lo + (hi - lo) * Double(k) / 2
                var g = Path(); g.move(to: CGPoint(x: L, y: y(v))); g.addLine(to: CGPoint(x: w - R, y: y(v)))
                ctx.stroke(g, with: .color(Pad.line), lineWidth: 1)
                ctx.draw(Text("\(Int(v.rounded()))").font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L - 6, y: y(v)), anchor: .trailing)
            }
            var p = Path()
            for (i, s) in series.enumerated() {
                let pt = CGPoint(x: x(s.time), y: y(Double(s.bpm)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Pad.text), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for m in marks {
                let near = series.min { abs($0.time.timeIntervalSince(m.at)) < abs($1.time.timeIntervalSince(m.at)) }
                guard let n = near else { continue }
                let pt = CGPoint(x: x(m.at), y: y(Double(n.bpm)))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(Pad.volt))
                ctx.draw(Text(m.label).font(PadFont.cond(10, .bold)).foregroundColor(Pad.text), at: CGPoint(x: pt.x, y: pt.y - 8), anchor: .bottom)
            }
            ctx.draw(Text(t0.padClock).font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L, y: h), anchor: .bottomLeading)
            ctx.draw(Text(t1.padClock).font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: w - R, y: h), anchor: .bottomTrailing)
        }
        .accessibilityLabel("Heart rate from \(vitals.start.padClock) to \(vitals.end.padClock), average \(vitals.avgHeartRate ?? 0)")
    }
}

// MARK: - Left column, level 3: every set of the session

struct PadStatsSetList: View {
    let ctx: PadStatsContext
    @ObservedObject private var nav = PadStatsNav.shared

    var body: some View {
        let s = nav.sessionId.flatMap { ctx.session($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(s.map { padDayLabel($0.date) } ?? "Session").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab(s.map { $0.setCount.plural("set") } ?? "", color: Pad.faint, size: 12)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(s?.exercises ?? []) { e in
                        PadLab(e.name, color: Pad.faint, size: 12).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        ForEach(e.sets) { st in row(st) }
                    }
                }
            }
        }
    }

    private func row(_ st: SetStat) -> some View {
        let on = nav.setId == st.id
        let sub: String = "\(StatsUnits.weightText(st.weight, unit: false)) × \(st.reps)" + (st.rpe.map { " · RPE \($0.rpeText)" } ?? "")
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { nav.setLabel = "Set \(st.number)"; nav.setId = st.id }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set \(st.number)").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    Text(sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let m = st.motion {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.2f", m.meanVelocity)).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                        Text("m/s").font(PadFont.cond(11)).foregroundColor(Pad.faint)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.raised : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Level 3: one set, rep by rep

struct PadStatsSetView: View {
    let ctx: PadStatsContext
    let sessionId: String
    let setId: String

    var body: some View {
        if let s = ctx.session(sessionId), let e = s.exercises.first(where: { $0.sets.contains { $0.id == setId } }),
           let st = e.sets.first(where: { $0.id == setId }) {
            content(s, e, st)
        } else {
            PadEmptyLine(text: "This set isn’t in the data any more.").padding(20)
        }
    }

    private func content(_ s: StatsSession, _ e: ExerciseStat, _ st: SetStat) -> some View {
        let notes = PadStatsFindings.set(ctx, session: s, exercise: e, set: st)
        let rpePart: String = st.rpe.map { " · rated RPE \($0.rpeText)" } ?? ""
        let timePart: String = st.loggedAt.map { ", \($0.padClock)" } ?? ""
        let sub: String = "\(StatsUnits.weightText(st.weight)) × \(st.reps)\(rpePart) · \(padDayLabel(s.date))\(timePart)"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(e.name) · set \(st.number)").font(PadFont.display(36)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
                    PadLab(sub, size: 13)
                }
                if let m = st.motion { tiles(s, e, st, m) }
                if !notes.isEmpty { PadFindings(notes: notes, columns: 2, limit: 4) }
                if let m = st.motion {
                    HStack(alignment: .top, spacing: 12) {
                        PadPane(title: "Speed, rep by rep", aside: e.sets.first.map { $0.id == st.id ? "m/s" : "dashed = set \($0.number)" }) {
                            PadRepSpeedChart(reps: m.reps, compare: e.sets.first.flatMap { $0.id == st.id ? nil : $0.motion?.reps }, mvt: e.sbd?.mvt)
                                .frame(height: 160)
                        }
                        PadPane(title: "Depth", aside: StatsUnits.depthLabel + " of bar travel") {
                            PadRepDepthChart(reps: m.reps, usual: usualDepth(e.name)).frame(height: 160)
                        }
                        PadPane(title: "Tempo", aside: "lowering · pause · lifting") {
                            PadRepTempoChart(reps: m.reps).frame(height: 160)
                        }
                    }
                    repTable(m)
                }
            }
            .padding(20)
        }
    }

    private func usualDepth(_ name: String) -> Double? {
        let t = ctx.history.flatMap { $0.exercises.filter { $0.name == name }.flatMap { $0.reps.map { $0.travelM } } }.sorted()
        return t.count >= 10 ? t[t.count / 2] : nil
    }

    private func tiles(_ s: StatsSession, _ e: ExerciseStat, _ st: SetStat, _ m: SetMotion) -> some View {
        let firstSet = e.sets.first
        let firstSpeed: String = firstSet.flatMap { $0.id == st.id ? nil : $0.motion }.map { String(format: "set %d: %.2f", firstSet?.number ?? 1, $0.meanVelocity) } ?? "average"
        let usual = usualDepth(e.name)
        let v = ctx.vitals[s.id]
        var peak = "—"
        if let v, let hr = HealthKitManager.heartRate(in: v.heartRateSeries, from: m.start, to: m.end.addingTimeInterval(15)) { peak = "\(hr.peak)" }
        return HStack(spacing: 8) {
            PadStatsTile(label: "Avg speed", value: String(format: "%.2f", m.meanVelocity), unit: "m/s", sub: firstSpeed)
            PadStatsTile(label: "Speed loss", value: m.velocityLossPct.map { "\(Int($0.rounded()))" } ?? "—", unit: m.velocityLossPct == nil ? nil : "%", sub: "first reps → last")
            PadStatsTile(label: "Under tension", value: String(format: "%.1f", m.timeUnderTensionSec), unit: "s", sub: m.repCount.plural("rep"))
            PadStatsTile(label: "Depth", value: StatsUnits.depthText(m.averageTravelM), sub: usual.map { "usual " + StatsUnits.depthText($0) } ?? "average")
            PadStatsTile(label: "Consistency", value: m.travelConsistencyPct.map { "\(Int($0.rounded()))" } ?? "—", unit: m.travelConsistencyPct == nil ? nil : "%", sub: "rep to rep depth")
            PadStatsTile(label: "Peak HR", value: peak, unit: peak == "—" ? nil : "bpm", sub: "during the set")
        }
    }

    private func repTable(_ m: SetMotion) -> some View {
        let mx = max(m.reps.map { $0.meanVelocity }.max() ?? 0.8, 0.3)
        return PadPane(title: "Every rep", aside: "from the Watch") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    h("Rep").frame(width: 50, alignment: .leading)
                    h("Avg speed").frame(width: 140, alignment: .leading)
                    h("Peak speed").frame(width: 80, alignment: .trailing)
                    h("Depth").frame(width: 76, alignment: .trailing)
                    h("Lowering").frame(width: 72, alignment: .trailing)
                    h("Pause").frame(width: 60, alignment: .trailing)
                    h("Lifting").frame(width: 64, alignment: .trailing)
                    h("Sticking point").frame(width: 100, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
                ForEach(m.reps) { r in
                    HStack(spacing: 8) {
                        Text("Rep \(r.index)").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).frame(width: 50, alignment: .leading)
                        PadSpeedBar(value: r.meanVelocity, maxValue: mx * 1.1, warn: r.isGrind)
                        Text(String(format: "%.2f", r.peakVelocity)).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 80, alignment: .trailing)
                        Text(StatsUnits.depthText(r.travelM)).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 76, alignment: .trailing)
                        Text(r.eccentricSec.map { String(format: "%.1fs", $0) } ?? "—").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 72, alignment: .trailing)
                        Text(r.bottomPauseSec.map { String(format: "%.1fs", $0) } ?? "—").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1fs", r.concentricSec)).font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 64, alignment: .trailing)
                        Text(r.stickingPoint.map { "\(Int(($0 * 100).rounded()))% up" } ?? "—").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 100, alignment: .trailing)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 38)
                    .overlay(alignment: .top) { PadRule() }
                }
            }
        }
    }

    private func h(_ t: String) -> some View { Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint) }
}

// MARK: - Rep charts

/// Bars per rep; the comparison set's reps as dashes; the lift's 1RM speed as a line.
struct PadRepSpeedChart: View {
    let reps: [RepMotion]
    var compare: [RepMotion]? = nil
    var mvt: Double? = nil
    var body: some View {
        Canvas { ctx, size in
            guard !reps.isEmpty else { return }
            let all: [Double] = reps.map { $0.meanVelocity } + (compare?.map { $0.meanVelocity } ?? []) + [mvt ?? 0]
            let hi = max((all.max() ?? 1) * 1.12, 0.1), lo = 0.0
            let L: CGFloat = 30, B: CGFloat = 16, T: CGFloat = 6
            let w = size.width, h = size.height
            func y(_ v: Double) -> CGFloat { T + (h - T - B) * CGFloat(1 - (v - lo) / (hi - lo)) }
            for k in 1...2 {
                let v = hi * Double(k) / 2.2
                var g = Path(); g.move(to: CGPoint(x: L, y: y(v))); g.addLine(to: CGPoint(x: w, y: y(v)))
                ctx.stroke(g, with: .color(Pad.line), lineWidth: 1)
                ctx.draw(Text(String(format: "%.2f", v)).font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L - 4, y: y(v)), anchor: .trailing)
            }
            let n = reps.count
            let slot = (w - L) / CGFloat(n)
            let bw = min(36, slot * 0.5)
            for (i, r) in reps.enumerated() {
                let cx = L + slot * (CGFloat(i) + 0.5)
                let top = y(r.meanVelocity)
                ctx.fill(Path(roundedRect: CGRect(x: cx - bw / 2, y: top, width: bw, height: (h - B) - top), cornerRadius: 4),
                         with: .color(r.isGrind ? Pad.orange : Pad.text))
                if let c = compare, i < c.count {
                    var d = Path(); d.move(to: CGPoint(x: cx - bw / 2 - 5, y: y(c[i].meanVelocity))); d.addLine(to: CGPoint(x: cx + bw / 2 + 5, y: y(c[i].meanVelocity)))
                    ctx.stroke(d, with: .color(Pad.mute), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                }
                ctx.draw(Text("\(r.index)").font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: cx, y: h), anchor: .bottom)
            }
            if let mvt {
                var m = Path(); m.move(to: CGPoint(x: L, y: y(mvt))); m.addLine(to: CGPoint(x: w, y: y(mvt)))
                ctx.stroke(m, with: .color(Pad.orange), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                ctx.draw(Text(String(format: "1RM speed %.2f", mvt)).font(PadFont.cond(10, .bold)).foregroundColor(Pad.orange), at: CGPoint(x: w, y: y(mvt) - 3), anchor: .bottomTrailing)
            }
        }
        .accessibilityLabel("Speed per rep: " + reps.map { String(format: "%.2f", $0.meanVelocity) }.joined(separator: ", "))
    }
}

/// Depth per rep against the lift's usual band.
struct PadRepDepthChart: View {
    let reps: [RepMotion]
    var usual: Double? = nil
    var body: some View {
        Canvas { ctx, size in
            guard !reps.isEmpty else { return }
            let vals = reps.map { StatsUnits.depth($0.travelM) }
            let u: Double? = usual.map { StatsUnits.depth($0) }
            let all = vals + (u.map { [$0 * 0.95, $0 * 1.05] } ?? [])
            let lo = (all.min() ?? 0) * 0.97, hi = (all.max() ?? 1) * 1.03
            let L: CGFloat = 30, B: CGFloat = 16, T: CGFloat = 6
            let w = size.width, h = size.height
            func y(_ v: Double) -> CGFloat { T + (h - T - B) * CGFloat(1 - (v - lo) / max(hi - lo, 0.001)) }
            if let u {
                let r = CGRect(x: L, y: y(u * 1.03), width: w - L, height: y(u * 0.97) - y(u * 1.03))
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Pad.raised))
                ctx.draw(Text("usual").font(PadFont.cond(10)).foregroundColor(Pad.mute), at: CGPoint(x: L + 6, y: r.minY + 2), anchor: .topLeading)
            }
            ctx.draw(Text(String(format: "%.0f", hi)).font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L - 4, y: y(hi)), anchor: .trailing)
            ctx.draw(Text(String(format: "%.0f", lo)).font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L - 4, y: y(lo)), anchor: .trailing)
            let slot = (w - L) / CGFloat(vals.count)
            var p = Path()
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: L + slot * (CGFloat(i) + 0.5), y: y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Pad.text), lineWidth: 1.6)
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: L + slot * (CGFloat(i) + 0.5), y: y(v))
                let shallow = u.map { v < $0 * 0.95 } ?? false
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)), with: .color(shallow ? Pad.orange : Pad.text))
                ctx.draw(Text("\(reps[i].index)").font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: pt.x, y: h), anchor: .bottom)
            }
        }
        .accessibilityLabel("Depth per rep: " + reps.map { StatsUnits.depthText($0.travelM) }.joined(separator: ", "))
    }
}

/// Lowering, pause and lifting time, one bar per rep.
struct PadRepTempoChart: View {
    let reps: [RepMotion]
    var body: some View {
        Canvas { ctx, size in
            guard !reps.isEmpty else { return }
            let totals = reps.map { ($0.eccentricSec ?? 0) + ($0.bottomPauseSec ?? 0) + $0.concentricSec }
            let mx = max(totals.max() ?? 1, 0.5)
            let L: CGFloat = 36, R: CGFloat = 36
            let rowH = min(26, size.height / CGFloat(reps.count))
            for (i, r) in reps.enumerated() {
                let yy = CGFloat(i) * rowH + 4
                var x = L
                let parts: [(Double, Color)] = [(r.eccentricSec ?? 0, Pad.blue), (r.bottomPauseSec ?? 0, Pad.mute), (r.concentricSec, Pad.text)]
                for (v, c) in parts where v > 0 {
                    let ww = (size.width - L - R) * CGFloat(v / mx)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: yy, width: max(2, ww - 2), height: rowH - 10), cornerRadius: 3), with: .color(c))
                    x += ww
                }
                ctx.draw(Text("rep \(r.index)").font(PadFont.cond(10)).foregroundColor(Pad.faint), at: CGPoint(x: L - 6, y: yy + (rowH - 10) / 2), anchor: .trailing)
                ctx.draw(Text(String(format: "%.1fs", totals[i])).font(PadFont.cond(10)).foregroundColor(Pad.mute), at: CGPoint(x: x + 4, y: yy + (rowH - 10) / 2), anchor: .leading)
            }
        }
        .accessibilityLabel("Tempo per rep")
    }
}
