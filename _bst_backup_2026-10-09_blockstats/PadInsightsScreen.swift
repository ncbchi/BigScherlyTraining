import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Insights (round 3, Oct 9, 2026)
//
// The business over the last 4, 8 or 12 weeks: sessions per week across everyone against the
// average, check-ins sent on time, PRs, every client in one table (tap to open them), renewals
// coming up, and wins. All worked out from what the app already loads. Reply time and retention
// history need the server to keep them, so they aren't shown yet.
// Synchronized folder: no target step needed.

struct PadInsightsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var renewals = PadRenewals.shared
    @Environment(\.padGo) private var go
    @Environment(\.padSideBySide) private var sideBySide
    @AppStorage("bst_pad_insights_weeks") private var weeks = 8
    @State private var prs: [String: [PersonalRecord]] = [:]

    private var cal: Calendar { Calendar.training }
    private var weekStart: Date { cal.startOfWeek(for: Date()) }

    private func weekStartFor(_ i: Int, of n: Int) -> Date {
        cal.date(byAdding: .weekOfYear, value: i - (n - 1), to: weekStart) ?? weekStart
    }

    var body: some View {
        let facts = PadRosterFacts.all(store)
        let series = sessionSeries(weeks)
        let prev = sessionSeries(weeks * 2).prefix(weeks)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Insights", subtitle: "The business over the last \(weeks) weeks.") {
                    PadSeg(options: [(id: 4, label: "4 wks"), (id: 8, label: "8 wks"), (id: 12, label: "12 wks")], selection: $weeks)
                }
                PadPageStrip(stats: strip(facts, series: series, prev: Array(prev)), notes: notes(facts, series: series))
                PadRule()
                if sideBySide {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 12) { sessionsPane(series); chartsRow(facts); clientTable(facts) }.frame(maxWidth: .infinity)
                        VStack(spacing: 12) { renewalsPane(facts); winsPane; rosterPane(facts) }.frame(width: 330)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 12) { sessionsPane(series); chartsRow(facts); clientTable(facts); renewalsPane(facts); winsPane; rosterPane(facts) }
                        .padding(20)
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { store.loadRoster(); await data.refresh(roster: store.roster) }
        .task {
            await renewals.load(store: store)
            if !data.hasLoaded { await data.refresh(roster: store.roster) }
            loadPRs()
        }
        .onChange(of: data.loadedAt) { _, _ in loadPRs() }
    }

    // MARK: Numbers

    /// Sessions done per week across everyone, oldest first, this week last.
    private func sessionSeries(_ n: Int) -> [Int] {
        let all = data.sessions(for: store.roster).filter { $0.isDone }
        return (0..<n).map { i in
            let s = weekStartFor(i, of: n)
            let e = cal.date(byAdding: .day, value: 7, to: s) ?? s
            return all.filter { $0.day >= s && $0.day < e }.count
        }
    }

    /// Share of check-ins sent, per week (only weeks that count), oldest first.
    private func checkInSeries(_ facts: [PadClientFacts]) -> [Double] {
        let n = min(weeks, 12)
        return (0..<n).compactMap { i in
            let idx = 12 - n + i
            let marks = facts.compactMap { f in idx < f.checkInWeeks.count ? f.checkInWeeks[idx] : nil }.filter { $0.counts }
            guard !marks.isEmpty else { return nil }
            return Double(marks.filter { $0.isSent }.count) / Double(marks.count) * 100
        }
    }

    private func prSeries(_ n: Int) -> [Double] {
        let all = prs.values.flatMap { $0 }
        return (0..<n).map { i in
            let s = weekStartFor(i, of: n)
            let e = cal.date(byAdding: .day, value: 7, to: s) ?? s
            return Double(all.filter { $0.date >= s && $0.date < e }.count)
        }
    }

    private func prsIn(_ clientId: String?, from: Date, to: Date) -> Int {
        let list: [PersonalRecord] = clientId.map { prs[$0] ?? [] } ?? prs.values.flatMap { $0 }
        return list.filter { $0.date >= from && $0.date < to }.count
    }

    private var periodStart: Date { weekStartFor(0, of: weeks) }
    private var prevStart: Date { weekStartFor(0, of: weeks * 2) }

    private func loadPRs() {
        var out: [String: [PersonalRecord]] = [:]
        for c in store.roster { out[c.id] = ProgressEngine.allPRs(workouts: data.workouts[c.id] ?? []) }
        prs = out
    }

    // MARK: Strip and noticing

    private func strip(_ facts: [PadClientFacts], series: [Int], prev: [Int]) -> [PadStat] {
        let active = facts.filter { !$0.paused }
        let paused = facts.count - active.count
        let new = facts.filter { $0.isNew }.count
        let clients = max(active.count, 1)
        // Average sessions per client a week, over complete weeks (this week is still going).
        let full = Array(series.dropLast())
        let per: Double = full.isEmpty ? 0 : Double(full.reduce(0, +)) / Double(full.count) / Double(clients)
        let prevPer: Double = prev.isEmpty ? 0 : Double(prev.reduce(0, +)) / Double(prev.count) / Double(clients)
        let perWarn = prevPer > 0 && per < prevPer * 0.9
        let perSub: String = prevPer > 0 ? "was \(String(format: "%.1f", prevPer))" : "per week"
        let ci = checkInSeries(facts)
        let ciPct: String = ci.isEmpty ? "—" : "\(Int((ci.reduce(0, +) / Double(ci.count)).rounded()))"
        let prNow = prsIn(nil, from: periodStart, to: Date())
        let prBefore = prsIn(nil, from: prevStart, to: periodStart)
        let prDelta = prNow - prBefore
        let prSub: String = prBefore == 0 && prNow == 0 ? "none yet" : (prDelta >= 0 ? "+\(prDelta) on the \(weeks) before" : "\(prDelta) on the \(weeks) before")
        let window = PadPrefs.renewWindow
        let renewing = facts.filter { ($0.renewDays ?? -1) >= 0 && ($0.renewDays ?? 999) <= window }
        let atRisk = renewing.filter { $0.risk == .high }.count
        return [
            PadStat(label: "Active clients", value: "\(active.count)", sub: "\(paused) paused · \(new) new"),
            PadStat(label: "Sessions per client", value: String(format: "%.1f", per), unit: "/wk", sub: perSub, warn: perWarn),
            PadStat(label: "Check-ins sent", value: ciPct, unit: ci.isEmpty ? nil : "%", sub: "on time, \(min(weeks, 12)) wks"),
            PadStat(label: "PRs", value: "\(prNow)", sub: prSub, good: prDelta > 0),
            PadStat(label: "Renewals, \(window) days", value: "\(renewing.count)", sub: atRisk > 0 ? "\(atRisk) at risk" : (renewing.isEmpty ? "none set" : "none at risk"), warn: atRisk > 0),
        ]
    }

    private func notes(_ facts: [PadClientFacts], series: [Int]) -> [PadNote] {
        var out: [PadNote] = []
        let full = Array(series.dropLast())
        if full.count >= 3, let last = full.last {
            let avg = Double(full.dropLast().reduce(0, +)) / Double(max(full.count - 1, 1))
            if avg > 0 {
                let change = (Double(last) - avg) / avg * 100
                if abs(change) >= 12 {
                    let down = facts.filter { f in f.weekly.count >= 2 && f.usualPerWeek > 0 && Double(f.weekly[f.weekly.count - 2]) < f.usualPerWeek * 0.6 }
                    let names = down.prefix(3).map { $0.first }.joined(separator: " and ")
                    let dir: String = change < 0 ? "down" : "up"
                    let aside: String = change < 0 && !names.isEmpty ? "mostly \(names)." : "last week against the average before it."
                    let tint: Color = change < 0 ? Pad.orange : Pad.voltText
                    let text: String = "Sessions \(dir) \(Int(abs(change).rounded()))%,"
                    if let f = down.first {
                        let id = f.id
                        out.append(PadNote(icon: "chart.bar.fill", tint: tint, text: text, aside: aside,
                                           go: "See them", run: { PadOpen.client(id, .workouts, go: go) }))
                    } else {
                        out.append(PadNote(icon: "chart.bar.fill", tint: tint, text: text, aside: aside))
                    }
                }
            }
        }
        let window = PadPrefs.renewWindow
        let renewing = facts.filter { ($0.renewDays ?? -1) >= 0 && ($0.renewDays ?? 999) <= window }
            .sorted { a, b in a.risk != b.risk ? a.risk > b.risk : (a.renewDays ?? 0) < (b.renewDays ?? 0) }
        if let r = renewing.first {
            let aside: String = r.risk == .high ? "\(r.first)'s is the one to talk about first." : "First up: \(r.first), \(PadDay.short(r.renewsOn ?? Date()))."
            out.append(PadNote(icon: "flag.fill", tint: r.risk == .high ? Pad.orange : Pad.mute,
                               text: "\(renewing.count == 1 ? "One renewal" : "\(renewing.count) renewals") in the next \(window) days.", aside: aside,
                               go: "Open", run: { PadOpen.client(r.id, go: go) }))
        }
        let prNow = prsIn(nil, from: periodStart, to: Date())
        let prBefore = prsIn(nil, from: prevStart, to: periodStart)
        if prNow > 0, prNow >= prBefore + 3 {
            out.append(PadNote(icon: "bolt.fill", tint: Pad.voltText, text: "PRs are up:", aside: "\(prNow) in \(weeks) weeks, \(prBefore) in the \(weeks) before."))
        }
        return out
    }

    // MARK: Panes

    private func sessionsPane(_ series: [Int]) -> some View {
        let full = Array(series.dropLast())
        let avg: Double = full.isEmpty ? 0 : Double(full.reduce(0, +)) / Double(full.count)
        let labels: [String] = (0..<series.count).map { i in
            let d = weekStartFor(i, of: series.count)
            return i == 0 || cal.component(.day, from: d) <= 7 ? PadDay.short(d) : "\(cal.component(.day, from: d))"
        }
        return PadPane(title: "Sessions per week, all clients", aside: "dashed line = average · this week so far in the accent") {
            PadAverageBars(values: series.map { Double($0) }, average: avg, labels: labels, height: 130)
        }
    }

    private func chartsRow(_ facts: [PadClientFacts]) -> some View {
        let ci = checkInSeries(facts)
        let pr = prSeries(weeks)
        let ciLast: String = ci.last.map { "\(Int($0.rounded()))%" } ?? "—"
        let prTotal: Int = Int(pr.reduce(0, +))
        return HStack(alignment: .top, spacing: 12) {
            PadPane(title: "Check-ins sent on time", aside: "weekly · last \(ciLast)") {
                if ci.count >= 2 { PadLineChart(points: ci).frame(height: 80) } else { PadEmptyLine(text: "Needs two weeks of check-ins.") }
            }
            PadPane(title: "PRs", aside: "weekly · \(prTotal) in \(weeks) weeks") {
                if pr.count >= 2 { PadBars(values: pr, height: 80) } else { PadEmptyLine(text: "None yet.") }
            }
        }
    }

    private func clientTable(_ facts: [PadClientFacts]) -> some View {
        let rows = facts.sorted { $0.needs > $1.needs }
        return PadPane(title: "Every client", aside: "tap a row to open them in Clients") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    tableHead("Client").frame(maxWidth: .infinity, alignment: .leading)
                    tableHead("Sessions / wk").frame(width: 100, alignment: .leading)
                    tableHead("Done").frame(width: 50, alignment: .trailing)
                    tableHead("Check-ins").frame(width: 70, alignment: .trailing)
                    tableHead("PRs").frame(width: 40, alignment: .trailing)
                    tableHead("Renews").frame(width: 64, alignment: .trailing)
                }
                ForEach(rows) { f in clientRow(f) }
            }
        }
    }

    private func tableHead(_ t: String) -> some View {
        Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint).padding(.bottom, 6)
    }

    private func clientRow(_ f: PadClientFacts) -> some View {
        let done: String = f.planned28 > 0 ? "\(Int((Double(f.done28) / Double(f.planned28) * 100).rounded()))%" : "—"
        let doneWarn: Bool = f.planned28 > 0 && Double(f.done28) / Double(f.planned28) < 0.7
        let n = min(weeks, 12)
        let marks = f.checkInWeeks.suffix(n).filter { $0.counts }
        let sent = marks.filter { $0.isSent }.count
        let ci: String = marks.isEmpty ? "—" : "\(sent) of \(marks.count)"
        let ciWarn: Bool = !marks.isEmpty && Double(sent) / Double(marks.count) < 0.75
        let prCount = prsIn(f.id, from: periodStart, to: Date())
        let renew: String = f.renewsOn.map { PadDay.short($0) } ?? "—"
        let renewWarn: Bool = f.risk == .high && f.renewsOn != nil
        return Button { PadOpen.client(f.id, go: go) } label: {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    PadAvatar(name: f.name, size: 26)
                        .overlay(Circle().stroke(f.risk == .high ? Pad.orange : Color.clear, lineWidth: 2).padding(-3))
                    Text(f.name).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PadWeekBars(weeks: f.weekly, height: 18).frame(width: 100, alignment: .leading)
                Text(done).font(PadFont.ui(13)).foregroundColor(doneWarn ? Pad.orange : Pad.text).frame(width: 50, alignment: .trailing)
                Text(ci).font(PadFont.ui(13)).foregroundColor(ciWarn ? Pad.orange : Pad.text).frame(width: 70, alignment: .trailing)
                Text("\(prCount)").font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 40, alignment: .trailing)
                Text(renew).font(PadFont.ui(13)).foregroundColor(renewWarn ? Pad.orange : Pad.text).frame(width: 64, alignment: .trailing)
            }
            .frame(minHeight: 42)
            .overlay(alignment: .top) { PadRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func renewalsPane(_ facts: [PadClientFacts]) -> some View {
        let horizon = max(60, PadPrefs.renewWindow)
        let rows = facts.filter { ($0.renewDays ?? -1) >= 0 && ($0.renewDays ?? 999) <= horizon }.sorted { ($0.renewDays ?? 0) < ($1.renewDays ?? 0) }
        return PadPane(title: "Renewals", aside: "next \(horizon) days") {
            if rows.isEmpty {
                PadEmptyLine(text: "None coming up. Set renewal dates on each client's Overview.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { PadRule() }
                        renewalRow(f)
                    }
                }
            }
        }
    }

    private func renewalRow(_ f: PadClientFacts) -> some View {
        let state: String = f.risk == .high ? "at risk" : (f.risk == .watch ? "slipping" : "on track")
        let detail: String = "\(f.renewsOn.map { PadDay.short($0) } ?? "") · \(state)"
        let days: String = (f.renewDays ?? 0).plural("day")
        return Button { PadOpen.client(f.id, go: go) } label: {
            PadPaneRow(name: f.name, ring: f.risk == .high, title: f.name, detail: detail) {
                Text(days).font(PadFont.cond(12)).foregroundColor(f.risk == .high ? Pad.orange : Pad.mute)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var winsPane: some View {
        let prNow = prsIn(nil, from: periodStart, to: Date())
        let prBefore = prsIn(nil, from: prevStart, to: periodStart)
        let awards = store.recentAwards.filter { $0.earnedAt >= periodStart }
        let who = Set(awards.map { $0.clientId }).count
        let delta = prNow - prBefore
        let prSub: String = delta >= 0 ? "+\(delta) on before" : "\(delta) on before"
        return PadPane(title: "Wins, all clients", aside: "\(weeks) weeks") {
            HStack(spacing: 8) {
                PadStatTile(stat: PadStat(label: "PRs", value: "\(prNow)", sub: prSub, good: delta > 0))
                PadStatTile(stat: PadStat(label: "Awards", value: "\(awards.count)", sub: who.plural("client")))
            }
            Button("See all wins") { go(.wins) }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
        }
    }

    private func rosterPane(_ facts: [PadClientFacts]) -> some View {
        let new = facts.filter { $0.isNew }
        let paused = facts.filter { $0.paused }
        let onProgram = facts.filter { $0.assignment != nil }.count
        return PadPane(title: "Roster") {
            HStack(spacing: 8) {
                PadStatTile(stat: PadStat(label: "On a program", value: "\(onProgram)", unit: "of \(facts.count)"))
                PadStatTile(stat: PadStat(label: "New, 4 wks", value: "\(new.count)", sub: new.prefix(2).map { $0.first }.joined(separator: ", ")))
            }
            if !paused.isEmpty {
                PadLab("Paused: " + paused.map { $0.first }.joined(separator: ", ") + ". No session in 45 days and nothing planned.", size: 12)
            }
            PadLab("Retention over a year needs the server to keep start and end dates. On the 2.1 list.", color: Pad.faint, size: 12)
        }
    }
}

/// Bars with a dashed average line; the last bar (this week, still going) in the accent.
struct PadAverageBars: View {
    let values: [Double]
    let average: Double
    var labels: [String] = []
    var height: CGFloat = 120
    var body: some View {
        let mx = max(values.max() ?? 1, average, 1)
        let avgY: CGFloat = height * (1 - CGFloat(average / mx))
        return VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(i == values.count - 1 ? Pad.volt : Pad.raised)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, height * CGFloat(v / mx)))
                    }
                }
                .frame(height: height, alignment: .bottom)
                if average > 0 {
                    Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 2000, y: 0)) }
                        .stroke(Pad.voltText.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .offset(y: avgY)
                        .clipped()
                }
            }
            .frame(height: height)
            .clipped()
            if !labels.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                        Text(l).font(PadFont.cond(10)).foregroundColor(Pad.faint).frame(maxWidth: .infinity).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityLabel("Sessions per week: " + values.map { String(Int($0)) }.joined(separator: ", "))
    }
}
