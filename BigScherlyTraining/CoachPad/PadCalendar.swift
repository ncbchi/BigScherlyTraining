import SwiftUI
import UniformTypeIdentifiers

// MARK: - Coach HQ on iPad: Calendar (round 3, Oct 9, 2026)
//
// One row per client, seven days across, so a week reads at a glance: done in the accent, missed
// outlined orange, moved outlined blue, planned in a thin outline. Drag a session along its row to
// move it (the client is told; Undo in the toast). Tap one for Open, Move or Comment. Under the week,
// next week's gaps only, each with a way to fill it. "Copy week forward" repeats this week's
// one-off workouts into next week (program sessions come from the program).
// Synchronized folder: no target step needed.

struct PadCalendarView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padSideBySide) private var sideBySide
    @Environment(\.padNewWorkout) private var newWorkout
    @Environment(\.padGo) private var go
    @State private var weekStart: Date = Calendar.training.startOfWeek(for: Date())
    @State private var target: String? = nil          // "clientId|day" under a drag
    @State private var moving: Set<String> = []
    @State private var commentFor: PadSession?
    @State private var builderFor: RosterItem?
    @State private var confirmCopy = false
    @State private var copying = false
    @State private var copyOnly: RosterItem?

    private var cal: Calendar { Calendar.training }
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) } }
    private var weekEnd: Date { cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }
    private var nextStart: Date { weekEnd }
    private var nextEnd: Date { cal.date(byAdding: .day, value: 7, to: weekEnd) ?? weekEnd }
    private var prevStart: Date { cal.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart }

    private var all: [PadSession] { data.sessions(for: store.roster) }
    private func inRange(_ a: Date, _ b: Date) -> [PadSession] { all.filter { $0.day >= a && $0.day < b } }
    private var rows: [RosterItem] {
        let week = inRange(weekStart, weekEnd)
        return store.roster.sorted { a, b in
            let na = week.contains { $0.clientId == a.id }
            let nb = week.contains { $0.clientId == b.id }
            return na != nb ? na : a.name < b.name
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Week of \(weekStart.formatted(.dateTime.month(.wide).day()))", subtitle: "One row per client. Drag a session along its row to move it.") {
                    weekSeg
                    Button { copyOnly = nil; confirmCopy = true } label: { Label("Copy week forward", systemImage: "doc.on.doc") }
                        .buttonStyle(PadButtonStyle(kind: .outline))
                        .disabled(copying)
                    Button { newWorkout() } label: { Label("New workout", systemImage: "plus") }.buttonStyle(PadButtonStyle(kind: .primary))
                }
                PadPageStrip(stats: strip, notes: notes)
                PadRule()
                VStack(alignment: .leading, spacing: 14) {
                    PadPane(title: "This week", aside: legendLine) {
                        if sideBySide { grid } else { ScrollView(.horizontal, showsIndicators: true) { grid.frame(width: 1080) } }
                    }
                    gapsPane
                    legend
                }
                .padding(20)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { store.loadRoster(); await data.refresh(roster: store.roster) }
        .sheet(item: $commentFor) { s in
            if let id = s.currentSetId {
                SetCommentSheet(setId: id, label: "\(s.title) · \(s.currentExercise ?? "") · \(s.currentSetText ?? "")", clientName: s.clientName)
            }
        }
        .sheet(item: $builderFor) { c in
            WorkoutBuilderView(clientId: c.id, clientName: c.name) { Task { await data.refresh(roster: store.roster) } }
        }
        .confirmationDialog(copyTitle, isPresented: $confirmCopy, titleVisibility: .visible) {
            Button(copyButton) { copyForward(only: copyOnly) }
        } message: {
            Text("Program sessions aren't copied; they come from the program. Days that already have the same workout are skipped.")
        }
    }

    // MARK: Week picker

    private var isThisWeek: Bool { cal.isDate(weekStart, inSameDayAs: cal.startOfWeek(for: Date())) }
    private func shift(_ n: Int) {
        withAnimation(.easeOut(duration: 0.15)) { weekStart = cal.date(byAdding: .day, value: 7 * n, to: weekStart) ?? weekStart }
    }

    private var weekSeg: some View {
        HStack(spacing: 2) {
            segButton("chevron.left", "Previous week") { shift(-1) }
            Button("This week") { withAnimation(.easeOut(duration: 0.15)) { weekStart = cal.startOfWeek(for: Date()) } }
                .font(PadFont.ui(14, .semibold)).foregroundColor(isThisWeek ? Pad.text : Pad.mute)
                .padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(isThisWeek ? Pad.raised : Color.clear))
                .hoverEffect(.highlight)
                .keyboardShortcut("t", modifiers: [])
            segButton("chevron.right", "Next week") { shift(1) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
    }

    private func segButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundColor(Pad.mute).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain).hoverEffect(.highlight).accessibilityLabel(label)
    }

    // MARK: Strip and noticing

    private var strip: [PadStat] {
        let week = inRange(weekStart, weekEnd)
        let last = inRange(prevStart, weekStart)
        let done = week.filter { $0.isDone }.count
        let lastDone = last.filter { $0.isDone }.count
        let moved = week.filter { $0.movedFrom != nil }
        let movedSub: String = moved.first.map { m in "\(m.clientName.firstName), \(dayShort(m.movedFrom ?? m.day)) → \(dayShort(m.day))" } ?? "none"
        let missed = week.filter { $0.isMissed }
        let gaps = gapRows.count
        let gapNames: String = gapRows.prefix(2).map { $0.client.name.firstName }.joined(separator: " and ")
        return [
            PadStat(label: "Sessions", value: "\(done)", unit: "of \(week.count)", sub: "last week \(lastDone) of \(last.count)", warn: !missed.isEmpty && done < lastDone),
            PadStat(label: "Moved", value: "\(moved.count)", sub: movedSub),
            PadStat(label: "Missed", value: "\(missed.count)", sub: missedNames(missed), warn: !missed.isEmpty),
            PadStat(label: "Gaps next week", value: "\(gaps)", sub: gaps == 0 ? "everyone has a plan" : gapNames, warn: gaps > 0),
        ]
    }

    private func missedNames(_ ss: [PadSession]) -> String {
        if ss.isEmpty { return "none" }
        var counts: [String: Int] = [:]
        for s in ss { counts[s.clientName.firstName, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
    }

    private func dayShort(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated)) }

    private var notes: [PadNote] {
        var out: [PadNote] = []
        // Several people missed the same weekday.
        let missed = inRange(weekStart, weekEnd).filter { $0.isMissed }
        var byDay: [Int: [String]] = [:]
        for s in missed { byDay[cal.component(.weekday, from: s.day), default: []].append(s.clientName.firstName) }
        if let top = byDay.max(by: { $0.value.count < $1.value.count }), top.value.count >= 2 {
            let day = cal.weekdaySymbols[top.key - 1]
            out.append(PadNote(icon: "calendar", tint: Pad.orange, text: "\(top.value.count) people missed \(day).",
                               aside: "\(top.value.joined(separator: ", ")). \(day)s may need a lighter start."))
        }
        // Four or more training days in a row, this week or next.
        for c in store.roster {
            let ss = inRange(weekStart, nextEnd).filter { $0.clientId == c.id && !$0.isMissed }
            let daySet = Set(ss.map { cal.startOfDay(for: $0.day) }).sorted()
            var run = 1, best = 1, bestEnd = daySet.first
            for i in daySet.indices.dropFirst() {
                let gap = cal.dateComponents([.day], from: daySet[i - 1], to: daySet[i]).day ?? 0
                run = gap == 1 ? run + 1 : 1
                if run > best { best = run; bestEnd = daySet[i] }
            }
            if best >= 4, let end = bestEnd {
                let start = cal.date(byAdding: .day, value: -(best - 1), to: end) ?? end
                let id = c.id
                out.append(PadNote(icon: "flame", tint: Pad.orange, text: "\(c.name.firstName) has \(best) training days in a row",
                                   aside: "\(dayShort(start))–\(dayShort(end)). Swap one for rest?", go: "Fix",
                                   run: { PadOpen.client(id, .workouts, go: go) }))
                break
            }
        }
        return out
    }

    // MARK: The grid: clients × days

    private let nameWidth: CGFloat = 160

    private var grid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Color.clear.frame(width: nameWidth, height: 1)
                ForEach(days, id: \.self) { d in dayHeader(d) }
            }
            ForEach(rows) { c in clientRow(c) }
            if rows.isEmpty { PadEmptyLine(text: "No clients yet.") }
        }
    }

    private func dayHeader(_ d: Date) -> some View {
        let today = cal.isDateInToday(d)
        let label: String = "\(d.formatted(.dateTime.weekday(.abbreviated))) \(cal.component(.day, from: d))"
        let n = inRange(d, cal.date(byAdding: .day, value: 1, to: d) ?? d).count
        return HStack(spacing: 4) {
            Text(label).font(PadFont.cond(13, .bold)).foregroundColor(today ? Pad.voltText : Pad.faint)
            if n > 0 { Text("· \(n)").font(PadFont.cond(12)).foregroundColor(Pad.faint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2).padding(.bottom, 2)
    }

    private func clientRow(_ c: RosterItem) -> some View {
        let program = data.assignments.first { $0.clientId == c.id && $0.status.lowercased() != "ended" && $0.endDate >= weekStart && $0.startDate < weekEnd }
        let sub: String = program.map { "\($0.programName) wk \(min($0.currentWeek, $0.totalWeeks))" } ?? "one-offs"
        return HStack(alignment: .top, spacing: 6) {
            Button { PadOpen.client(c.id, .workouts, go: go) } label: {
                HStack(spacing: 8) {
                    PadAvatar(name: c.name, size: 28)
                        .overlay(Circle().stroke(c.isDrifting ? Pad.orange : Color.clear, lineWidth: 2).padding(-3))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        Text(sub).font(PadFont.cond(11)).foregroundColor(Pad.mute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: nameWidth, alignment: .leading)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(days, id: \.self) { d in cell(c, d) }
        }
    }

    private func key(_ c: RosterItem, _ d: Date) -> String { "\(c.id)|\(Int(d.timeIntervalSince1970))" }

    private func cell(_ c: RosterItem, _ d: Date) -> some View {
        let next = cal.date(byAdding: .day, value: 1, to: d) ?? d
        let ss = inRange(d, next).filter { $0.clientId == c.id }.sorted { $0.placeMinute < $1.placeMinute }
        let k = key(c, d)
        let targeted = target == k
        let today = cal.isDateInToday(d)
        return VStack(spacing: 4) {
            ForEach(ss) { s in chip(s) }
            if ss.isEmpty {
                Color.clear.frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(today ? Pad.text.opacity(0.03) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundColor(targeted ? Pad.line2 : Color.clear))
        .dropDestination(for: String.self) { ids, _ in
            target = nil
            guard let id = ids.first else { return false }
            return move(id, to: d, clientId: c.id)
        } isTargeted: { on in
            if on { target = k } else if target == k { target = nil }
        }
    }

    private struct ChipStyle {
        let fill: Color
        let stroke: Color
        let text: Color
        let sub: String
    }

    private func style(_ s: PadSession) -> ChipStyle {
        let pr = s.isDone && data.prsThisWeek(clientId: s.clientId).contains { cal.isDate($0.date, inSameDayAs: s.day) }
        if s.isLive { return ChipStyle(fill: Pad.liveFill, stroke: Pad.isLight ? Pad.text : Pad.volt, text: Pad.text, sub: "lifting now") }
        if s.isDone {
            let when: String = pr ? "PR" : (s.finish.map { $0.padClock } ?? "done")
            return ChipStyle(fill: Pad.volt, stroke: .clear, text: Pad.onVolt, sub: when)
        }
        if s.isMissed { return ChipStyle(fill: .clear, stroke: Pad.orange, text: Pad.orange, sub: "missed") }
        if let m = s.movedFrom { return ChipStyle(fill: .clear, stroke: Pad.blue, text: Pad.text, sub: "moved from \(dayShort(m))") }
        let sub: String = s.usualStartMinute.map { u in
            let t = cal.date(bySettingHour: u / 60, minute: u % 60, second: 0, of: s.day) ?? s.day
            return "usually \(t.padClock)"
        } ?? "planned"
        return ChipStyle(fill: .clear, stroke: Pad.line2, text: Pad.text, sub: sub)
    }

    @ViewBuilder
    private func chip(_ s: PadSession) -> some View {
        let st = style(s)
        let base = VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(PadFont.cond(12, .bold)).foregroundColor(st.text).lineLimit(1)
            Text(st.sub).font(PadFont.cond(11, .medium)).foregroundColor(st.text.opacity(0.8)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(st.fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(st.stroke, lineWidth: 1.5))
        .opacity(moving.contains(s.id) ? 0.5 : 1)

        Menu {
            Button { PadNav.shared.workoutId = s.id; PadOpen.client(s.clientId, .workouts, go: go) } label: {
                Label("Open \(s.clientName.firstName)'s workouts", systemImage: "person")
            }
            if !s.isDone {
                Menu {
                    ForEach(days, id: \.self) { d in
                        Button(d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) { _ = move(s.id, to: d, clientId: s.clientId) }
                            .disabled(cal.isDate(d, inSameDayAs: s.day))
                    }
                } label: { Label("Move to", systemImage: "arrow.left.arrow.right") }
            }
            if s.currentSetId != nil {
                Button { commentFor = s } label: { Label("Comment on the last set", systemImage: "text.bubble") }
            }
        } label: {
            base
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(s.id) { base.frame(width: 130) }
        .disabled(moving.contains(s.id))
        .accessibilityLabel("\(s.clientName), \(s.title), \(st.sub)")
    }

    private var legendLine: String { "tap for Open, Move or Comment" }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(Pad.volt, .clear, "Done")
            legendItem(.clear, Pad.line2, "Planned")
            legendItem(.clear, Pad.orange, "Missed")
            legendItem(.clear, Pad.blue, "Moved")
            legendItem(Pad.liveFill, Pad.isLight ? Pad.text : Pad.volt, "Lifting now")
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ fill: Color, _ stroke: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 14, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(stroke, lineWidth: 1.5))
            PadLab(text, color: Pad.faint, size: 12)
        }
    }

    // MARK: Next week, gaps only

    struct GapRow: Identifiable {
        let client: RosterItem
        let from: Date          // first empty day
        let note: String
        var id: String { client.id }
    }

    private var gapRows: [GapRow] {
        let next = inRange(nextStart, nextEnd)
        var out: [GapRow] = []
        for c in store.roster {
            let mine = next.filter { $0.clientId == c.id }
            let a = data.assignments.first { $0.clientId == c.id && $0.status.lowercased() != "ended" && $0.endDate >= nextStart && $0.endDate < nextEnd }
            let trainsNow = inRange(prevStart, weekEnd).contains { $0.clientId == c.id }
            if mine.isEmpty {
                guard trainsNow || a != nil else { continue }      // long-paused clients aren't a gap
                let note: String = a.map { "block ends \(PadDay.short($0.endDate))" } ?? "nothing planned next week"
                out.append(GapRow(client: c, from: nextStart, note: note))
            } else if let a, !mine.contains(where: { $0.day > a.endDate }) {
                let from = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: a.endDate)) ?? nextEnd
                if from < nextEnd { out.append(GapRow(client: c, from: from, note: "block ends \(PadDay.short(a.endDate))")) }
            }
        }
        return out
    }

    private var gapsPane: some View {
        let gaps = gapRows
        let nextDays: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: nextStart) }
        return PadPane(title: "Next week, gaps only", aside: "tap a gap to fill it") {
            if gaps.isEmpty {
                PadEmptyLine(text: "Everyone has next week planned.")
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: nameWidth, height: 1)
                        ForEach(nextDays, id: \.self) { d in
                            Text("\(d.formatted(.dateTime.weekday(.abbreviated))) \(cal.component(.day, from: d))")
                                .font(PadFont.cond(13, .bold)).foregroundColor(Pad.faint).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(gaps) { g in gapRow(g, nextDays: nextDays) }
                }
            }
        }
    }

    private func gapRow(_ g: GapRow, nextDays: [Date]) -> some View {
        let lead = nextDays.filter { $0 < g.from }.count
        let span = 7 - lead
        let text: String = lead == 0 ? "Nothing planned next week · tap to fill" : "Nothing after \(dayShort(cal.date(byAdding: .day, value: -1, to: g.from) ?? g.from)) · tap to fill"
        return HStack(spacing: 6) {
            HStack(spacing: 8) {
                PadAvatar(name: g.client.name, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.client.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(g.note).font(PadFont.cond(11)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: nameWidth, alignment: .leading)
            GeometryReader { geo in
                let cellW = (geo.size.width - 6 * 6) / 7
                HStack(spacing: 6) {
                    if lead > 0 { Color.clear.frame(width: cellW * CGFloat(lead) + 6 * CGFloat(lead - 1)) }
                    Menu {
                        Button { builderFor = g.client } label: { Label("New workout for \(g.client.name.firstName)", systemImage: "plus") }
                        Button { copyOnly = g.client; confirmCopy = true } label: { Label("Repeat this week's one-offs", systemImage: "doc.on.doc") }
                        Button { PadOpen.client(g.client.id, .program, go: go) } label: { Label("Plan their next block", systemImage: "list.bullet.rectangle") }
                    } label: {
                        Text(text).font(PadFont.cond(12, .bold)).foregroundColor(Pad.orange)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Pad.orange.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pad.orange.opacity(0.45), lineWidth: 1))
                    }
                    .frame(width: cellW * CGFloat(span) + 6 * CGFloat(max(span - 1, 0)))
                }
            }
            .frame(height: 44)
        }
    }

    // MARK: Moving

    @discardableResult
    private func move(_ id: String, to day: Date, clientId: String) -> Bool {
        guard let s = all.first(where: { $0.id == id }) else { return false }
        guard s.clientId == clientId else {
            PadToasts.shared.show("Drag along \(s.clientName.firstName)'s own row to move it.")
            return false
        }
        guard !s.isDone, !cal.isDate(s.day, inSameDayAs: day) else { return false }
        moving.insert(id)
        let from = s.day
        Task {
            do {
                try await APIClient.shared.trainerMoveWorkout(id: id, to: day)
                await data.refresh(roster: store.roster)
                moving.remove(id)
                PadToasts.shared.show("Moved \(s.clientName.firstName)'s \(s.title) to \(day.formatted(.dateTime.weekday(.wide)))", action: "Undo") {
                    Task {
                        try? await APIClient.shared.trainerMoveWorkout(id: id, to: from)
                        await data.refresh(roster: store.roster)
                    }
                }
            } catch {
                moving.remove(id)
                PadToasts.shared.show("Couldn't move it. Check your connection and try again.")
            }
        }
        return true
    }

    // MARK: Copy week forward

    private func copyable(_ only: RosterItem?) -> [PadSession] {
        let week = inRange(weekStart, weekEnd).filter { $0.programLabel == nil && (only == nil || $0.clientId == only?.id) }
        let next = inRange(nextStart, nextEnd)
        return week.filter { s in
            let to = cal.date(byAdding: .day, value: 7, to: s.day) ?? s.day
            return !next.contains { $0.clientId == s.clientId && $0.title == s.title && cal.isDate($0.day, inSameDayAs: to) }
        }
    }

    private var copyTitle: String {
        let n = copyable(copyOnly).count
        let who: String = copyOnly.map { "\($0.name.firstName)'s " } ?? ""
        return n == 0 ? "Nothing to copy: \(who)one-off workouts this week are already in next week." : "Copy \(who)\(n.plural("workout")) into the week of \(nextStart.formatted(.dateTime.month(.wide).day()))?"
    }
    private var copyButton: String { copyable(copyOnly).isEmpty ? "OK" : "Copy" }

    private func copyForward(only: RosterItem?) {
        let list = copyable(only)
        guard !list.isEmpty else { return }
        copying = true
        Task {
            var made = 0
            for s in list {
                guard let w = data.apiWorkouts[s.clientId]?.first(where: { $0.id == s.id })?.toModel() else { continue }
                let exs: [[String: Any]] = w.exercises.enumerated().map { i, e in
                    var d = DraftExercise(from: e)
                    d.serverId = ""
                    for j in d.sets.indices { d.sets[j].serverId = "" }
                    return d.payload(order: i)
                }
                let to = cal.date(byAdding: .day, value: 7, to: s.day) ?? s.day
                let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: to) ?? to
                let payload: [String: Any] = ["id": "", "title": w.title, "scheduledDate": ISO8601DateFormatter().string(from: noon),
                                              "completed": false, "exercises": exs]
                if (try? await APIClient.shared.trainerCreateWorkout(clientId: s.clientId, payload: payload)) != nil { made += 1 }
            }
            await data.refresh(roster: store.roster)
            copying = false
            let missed = list.count - made
            PadToasts.shared.show(missed == 0 ? "Copied \(made.plural("workout")) into next week" : "Copied \(made); \(missed) didn't go. Try again.")
        }
    }
}
