import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Programs (round 3, Oct 9, 2026)
//
// A board of programs with who's on each and how far along they are, a "which programs work"
// table across everyone who has run them (sessions done, PRs a month, effort drift), and the
// automatic increases the progression engine made this week, each with Undo. Building and editing
// a program stays on the web, where blocks × days × sets fit; here you assign, check and fix.
// Synchronized folder: no target step needed.

struct PadProgramsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padGo) private var go
    @Environment(\.padSideBySide) private var sideBySide
    @State private var programs: [APIProgramSummary] = []
    @State private var changes: [APIProgressionChange] = []
    @State private var loaded = false
    @State private var stats: [String: ProgramStats] = [:]      // by program id
    @State private var open: APIProgramSummary?
    @State private var assign: AssignTarget?

    struct AssignTarget: Identifiable {
        let program: APIProgramSummary
        let clientId: String?
        var id: String { program.id + (clientId ?? "") }
    }

    /// Everyone who has run a program, added up.
    struct ProgramStats {
        var clients = 0
        var due = 0
        var done = 0
        var prs = 0
        var months: Double = 0
        var rpeDrift: Double?
        var donePct: Int? { due > 0 ? Int((Double(done) / Double(due) * 100).rounded()) : nil }
        var prsPerMonth: Double? { months >= 0.5 ? Double(prs) / months : nil }
    }

    private var cal: Calendar { Calendar.training }
    private var today: Date { cal.startOfDay(for: Date()) }
    private var active: [APIAssignment] {
        data.assignments.filter { $0.status.lowercased() != "ended" && $0.endDate >= today && $0.startDate <= today.addingTimeInterval(86_400 * 7) }
    }
    private var weekChanges: [APIProgressionChange] {
        let since = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return changes.filter { $0.createdAt >= since }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Programs", subtitle: subtitle) {
                    Button { go(.library) } label: { Label("Library", systemImage: "books.vertical") }
                        .buttonStyle(PadButtonStyle(kind: .outline))
                }
                PadPageStrip(stats: strip, notes: notes)
                PadRule()
                if sideBySide {
                    HStack(alignment: .top, spacing: 16) {
                        board.frame(maxWidth: .infinity)
                        VStack(spacing: 12) { worksPane; increasesPane }.frame(width: 420)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) { board; worksPane; increasesPane }.padding(20)
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: data.loadedAt) { _, _ in computeStats() }
        .sheet(item: $open) { p in
            NavigationStack { CoachProgramDetailView(summary: p) { Task { await load() } } }
        }
        .sheet(item: $assign) { t in
            AssignProgramSheet(programId: t.program.id, programName: t.program.name, preselected: t.clientId) {
                Task { await data.refresh(roster: store.roster); await load() }
            }
        }
    }

    // MARK: Strip and noticing

    private var subtitle: String {
        if !loaded { return "Loading your programs…" }
        let on = Set(active.map { $0.clientId }).count
        let ending = endingNothingAfter.count
        var s = "\(programs.count.plural("program")), \(on) of \(store.roster.count) clients on one."
        if ending > 0 { s += " \(ending == 1 ? "One block ends" : "\(ending) blocks end") with nothing after." }
        return s
    }

    private var endingNothingAfter: [APIAssignment] {
        let soon = cal.date(byAdding: .day, value: 14, to: today) ?? today
        return active.filter { a in
            a.endDate <= soon && !data.assignments.contains { $0.clientId == a.clientId && $0.id != a.id && $0.startDate >= a.endDate.addingTimeInterval(-86_400) }
        }
    }

    private var strip: [PadStat] {
        let onIds = Set(active.map { $0.clientId })
        let off = store.roster.filter { !onIds.contains($0.id) }
        let offText: String = off.isEmpty ? "everyone" : (off.count == 1 ? "\(off[0].name.firstName) isn't on one" : "\(off.count) aren't on one")
        let soon = cal.date(byAdding: .day, value: 14, to: today) ?? today
        let ending = active.filter { $0.endDate <= soon }
        let nothing = endingNothingAfter.count
        let endSub: String = ending.isEmpty ? "none" : (nothing == 0 ? "all have a next block" : "nothing after for \(nothing)")
        let due = active.map { dueSessions($0) }.reduce(0, +)
        let done = active.map { doneSessions($0) }.reduce(0, +)
        let pct: String = due > 0 ? "\(Int((Double(done) / Double(due) * 100).rounded()))" : "—"
        let undone = weekChanges.filter { $0.undoneAt != nil }.count
        return [
            PadStat(label: "On a program", value: "\(onIds.count)", unit: "of \(store.roster.count)", sub: offText),
            PadStat(label: "Ending in 14 days", value: "\(ending.count)", sub: endSub, warn: nothing > 0),
            PadStat(label: "Sessions done", value: pct, unit: due > 0 ? "%" : nil, sub: "of what was due, current blocks"),
            PadStat(label: "Auto increases", value: "\(weekChanges.count)", sub: "this week · \(undone) undone", good: weekChanges.count > 0),
        ]
    }

    private var notes: [PadNote] {
        var out: [PadNote] = []
        // The program that makes PRs.
        let ranked = programs.compactMap { p in stats[p.id]?.prsPerMonth.map { (p, $0) } }.sorted { $0.1 > $1.1 }
        if ranked.count >= 2, ranked[0].1 > 0 {
            let best = ranked[0], worst = ranked[ranked.count - 1]
            let n = stats[best.0.id]?.prs ?? 0
            out.append(PadNote(icon: "bolt.fill", tint: Pad.voltText, text: "\(best.0.name) makes PRs:",
                               aside: "\(n.plural("PR")), \(String(format: "%.1f", best.1)) per client a month. \(worst.0.name): \(String(format: "%.1f", worst.1))."))
        }
        let ending = endingNothingAfter
        if !ending.isEmpty {
            let names = ending.map { $0.clientName.firstName }.joined(separator: " and ")
            let dates = ending.map { PadDay.short($0.endDate) }.joined(separator: " and ")
            let first = ending[0]
            out.append(PadNote(icon: "flag.fill", tint: Pad.orange, text: "\(names) \(ending.count == 1 ? "ends" : "end") with nothing after.",
                               aside: "\(dates).", go: "Assign", run: { PadOpen.client(first.clientId, .program, go: go) }))
        }
        // When sessions get moved most.
        let moves = data.moves
        if moves.count >= 3 {
            var byDay: [Int: Int] = [:]
            for m in moves { byDay[cal.component(.weekday, from: m.from), default: 0] += 1 }
            if let top = byDay.max(by: { $0.value < $1.value }), top.value * 2 >= moves.count {
                let day = cal.weekdaySymbols[top.key - 1]
                out.append(PadNote(icon: "calendar", tint: Pad.mute, text: "\(day) sessions get moved most:",
                                   aside: "\(top.value) of \(moves.count) moves this week."))
            }
        }
        return out
    }

    // MARK: The board

    private var board: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return Group {
            if !loaded {
                LazyVGrid(columns: cols, spacing: 12) { ForEach(0..<4, id: \.self) { _ in PadSkeleton(height: 170) } }
            } else if programs.isEmpty {
                PadPane(title: "No programs yet") {
                    PadEmptyLine(text: "Build programs in Coach HQ on the web; they show here to assign and follow.")
                }
            } else {
                LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                    ForEach(sortedPrograms) { p in card(p) }
                }
            }
        }
    }

    private var sortedPrograms: [APIProgramSummary] {
        programs.sorted { a, b in
            let na = active.filter { $0.programId == a.id }.count
            let nb = active.filter { $0.programId == b.id }.count
            return na != nb ? na > nb : a.name < b.name
        }
    }

    private func card(_ p: APIProgramSummary) -> some View {
        let people = active.filter { $0.programId == p.id }.sorted { $0.endDate < $1.endDate }
        let blocksPart: String = p.blocks > 1 ? " · \(p.blocks) blocks" : ""
        let nobody: String = people.isEmpty ? " · nobody on it" : ""
        let meta: String = "\(p.weeks) wks · \(p.daysPerWeek) days\(blocksPart)\(nobody)"
        let st = stats[p.id]
        let ending = people.filter { a in endingNothingAfter.contains { $0.id == a.id } }
        return VStack(alignment: .leading, spacing: 10) {
            Button { open = p } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(p.name).font(PadFont.display(22)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    PadLab(meta, size: 12).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(people) { a in personRow(a) }
            if !ending.isEmpty {
                PadLab("Nothing planned after · \(footer(st))", color: Pad.orange, size: 12)
            } else {
                PadLab(footer(st), size: 12)
            }
            HStack(spacing: 6) {
                if let first = ending.first {
                    Menu {
                        ForEach(programs) { q in
                            Button(q.name) { assign = AssignTarget(program: q, clientId: first.clientId) }
                        }
                    } label: { PadMenuLabel(text: ending.count == 1 ? "Assign \(first.clientName.firstName)'s next block" : "Assign next block", kind: .primary) }
                } else {
                    Button("Assign") { assign = AssignTarget(program: p, clientId: nil) }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                Button("Open") { open = p }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func footer(_ st: ProgramStats?) -> String {
        guard let st, st.clients > 0 else { return "Not run yet" }
        var bits: [String] = []
        bits.append(st.prs.plural("PR"))
        if let d = st.donePct { bits.append("\(d)% of sessions done") }
        if let r = st.rpeDrift { bits.append(abs(r) < 0.3 ? "effort steady" : (r > 0 ? "effort up \(String(format: "%.1f", r))" : "effort down \(String(format: "%.1f", -r))")) }
        return bits.joined(separator: " · ")
    }

    private func personRow(_ a: APIAssignment) -> some View {
        let warn = endingNothingAfter.contains { $0.id == a.id }
        let frac: Double = a.totalWeeks > 0 ? min(1, Double(a.currentWeek) / Double(a.totalWeeks)) : 0
        let label: String = "wk \(min(a.currentWeek, a.totalWeeks)) of \(a.totalWeeks)" + (warn ? " · ends \(PadDay.short(a.endDate))" : "")
        let barColor: Color = warn ? Pad.orange : Pad.volt
        return Button { PadOpen.client(a.clientId, .program, go: go) } label: {
            HStack(spacing: 8) {
                PadAvatar(name: a.clientName, size: 26)
                Text(a.clientName).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Pad.raised)
                        Capsule().fill(barColor).frame(width: max(4, g.size.width * CGFloat(frac)))
                    }
                }
                .frame(width: 90, height: 6)
                Text(label).font(PadFont.cond(12)).foregroundColor(warn ? Pad.orange : Pad.mute)
                    .frame(width: 130, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: Which programs work

    private var worksPane: some View {
        let rows = programs.filter { (stats[$0.id]?.clients ?? 0) > 0 }
            .sorted { (stats[$0.id]?.prsPerMonth ?? 0) > (stats[$1.id]?.prsPerMonth ?? 0) }
        let best: String? = rows.first?.id
        return PadPane(title: "Which programs work", aside: "everyone who's run them") {
            if rows.isEmpty {
                PadEmptyLine(text: loaded ? "Shows once someone has run a program for a couple of weeks." : "")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        head("Program").frame(maxWidth: .infinity, alignment: .leading)
                        head("Clients").frame(width: 50, alignment: .trailing)
                        head("Done").frame(width: 50, alignment: .trailing)
                        head("PRs / mo").frame(width: 60, alignment: .trailing)
                        head("Effort").frame(width: 50, alignment: .trailing)
                    }
                    ForEach(rows) { p in
                        worksRow(p, best: p.id == best && rows.count > 1)
                    }
                }
                PadLab("Done = sessions logged of those due. Effort = average RPE in the last two weeks of a block against the first two.", color: Pad.faint, size: 12)
            }
        }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint).padding(.bottom, 6)
    }

    private func worksRow(_ p: APIProgramSummary, best: Bool) -> some View {
        let st = stats[p.id] ?? ProgramStats()
        let done: String = st.donePct.map { "\($0)%" } ?? "—"
        let prs: String = st.prsPerMonth.map { String(format: "%.1f", $0) } ?? "—"
        let drift: String = st.rpeDrift.map { String(format: "%+.1f", $0) } ?? "—"
        let driftWarn: Bool = (st.rpeDrift ?? 0) >= 0.6
        let doneWarn: Bool = (st.donePct ?? 100) < 70
        return HStack(spacing: 8) {
            Text(p.name).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(st.clients)").font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 50, alignment: .trailing)
            Text(done).font(PadFont.ui(13)).foregroundColor(doneWarn ? Pad.orange : Pad.text).frame(width: 50, alignment: .trailing)
            Text(prs).font(PadFont.ui(13, best ? .bold : .medium)).foregroundColor(best ? Pad.voltText : Pad.text).frame(width: 60, alignment: .trailing)
            Text(drift).font(PadFont.ui(13)).foregroundColor(driftWarn ? Pad.orange : Pad.text).frame(width: 50, alignment: .trailing)
        }
        .frame(minHeight: 38)
        .overlay(alignment: .top) { PadRule() }
    }

    // MARK: Automatic increases

    private var increasesPane: some View {
        PadPane(title: "Automatic increases", aside: "this week") {
            if weekChanges.isEmpty {
                PadEmptyLine(text: loaded ? "None this week." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(weekChanges.prefix(8).enumerated()), id: \.element.id) { i, c in
                        if i > 0 { PadRule() }
                        PadPaneRow(name: c.clientName, title: "\(c.exerciseName) · \(c.summary)", detail: "\(c.clientName.firstName) · \(c.reason)") {
                            if c.undoneAt != nil {
                                PadLab("Undone", color: Pad.faint, size: 12)
                            } else {
                                Button("Undo") { undo(c) }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                            }
                        }
                    }
                }
            }
        }
    }

    private func undo(_ c: APIProgressionChange) {
        Task {
            do {
                let r = try await APIClient.shared.undoProgressionChange(c.id)
                changes = (try? await APIClient.shared.progressionChanges(days: 14)) ?? changes
                PadToasts.shared.show("Undone · \(r.restored.plural("set")) back to before")
            } catch {
                PadToasts.shared.show("Couldn't undo. Try again.")
            }
        }
    }

    // MARK: Loading and working it out

    private func load() async {
        guard store.isLive else { loaded = true; return }
        async let p = try? await APIClient.shared.programs()
        async let c = try? await APIClient.shared.progressionChanges(days: 14)
        let pv = await p, cv = await c
        if let pv { programs = pv }
        if let cv { changes = cv }
        if !data.hasLoaded { await data.refresh(roster: store.roster) }
        loaded = true
        computeStats()
    }

    private func sessionsIn(_ a: APIAssignment) -> [PadSession] {
        let start = cal.startOfDay(for: a.startDate)
        let end = min(cal.startOfDay(for: a.endDate), today)
        let c = store.roster.first { $0.id == a.clientId } ?? RosterItem.stub(a.clientId, a.clientName)
        return data.sessions(client: c).filter { $0.day >= start && $0.day <= end && $0.programLabel != nil }
    }

    private func dueSessions(_ a: APIAssignment) -> Int {
        let n = sessionsIn(a).filter { $0.day < today || $0.isDone }.count
        return n > 0 ? n : 0
    }
    private func doneSessions(_ a: APIAssignment) -> Int { sessionsIn(a).filter { $0.isDone }.count }

    private func computeStats() {
        var out: [String: ProgramStats] = [:]
        var prCache: [String: [PersonalRecord]] = [:]
        for a in data.assignments where a.startDate <= today {
            var s = out[a.programId] ?? ProgramStats()
            s.clients += 1
            s.due += dueSessions(a)
            s.done += doneSessions(a)
            let end = min(a.endDate, Date())
            let days = max(0, cal.dateComponents([.day], from: a.startDate, to: end).day ?? 0)
            s.months += Double(days) / 30.4
            if prCache[a.clientId] == nil { prCache[a.clientId] = ProgressEngine.allPRs(workouts: data.workouts[a.clientId] ?? []) }
            s.prs += (prCache[a.clientId] ?? []).filter { $0.date >= a.startDate && $0.date <= end }.count
            // Effort drift: average RPE, last two weeks of the block against the first two.
            let ss = sessionsIn(a).filter { $0.isDone && $0.avgRPE != nil }
            let twoWeeks: TimeInterval = 14 * 86_400
            let early = ss.filter { $0.day < a.startDate.addingTimeInterval(twoWeeks) }.compactMap { $0.avgRPE }
            let late = ss.filter { $0.day > end.addingTimeInterval(-twoWeeks) }.compactMap { $0.avgRPE }
            if early.count >= 2, late.count >= 2, days >= 28 {
                let d = late.reduce(0, +) / Double(late.count) - early.reduce(0, +) / Double(early.count)
                s.rpeDrift = s.rpeDrift.map { ($0 + d) / 2 } ?? d
            }
            out[a.programId] = s
        }
        stats = out
    }
}
