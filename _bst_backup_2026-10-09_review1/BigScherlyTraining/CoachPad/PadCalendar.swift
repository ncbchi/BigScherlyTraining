import SwiftUI
import UniformTypeIdentifiers

// MARK: - Coach HQ on iPad: Calendar (Oct 8, 2026)
//
// One week, every client. Drag a session to another day to move it (the client is told);
// tap one for Move, Open or Comment. Built from the sessions Today already loads.
// Synchronized folder: no target step needed.

struct PadCalendarView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padSideBySide) private var sideBySide
    @Environment(\.padNewWorkout) private var newWorkout
    @State private var weekStart: Date = Calendar.training.startOfWeek(for: Date())
    @State private var clientFilter: String? = nil
    @State private var targetDay: Date? = nil
    @State private var moving: Set<String> = []
    @State private var commentFor: PadSession?

    private var cal: Calendar { Calendar.training }
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) } }
    private var weekEnd: Date { cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }
    private var sessions: [PadSession] {
        data.sessions(for: store.roster.filter { clientFilter == nil || $0.id == clientFilter })
            .filter { $0.day >= weekStart && $0.day < weekEnd }
    }
    private func sessions(on day: Date) -> [PadSession] {
        sessions.filter { cal.isDate($0.day, inSameDayAs: day) }.sorted { ($0.isDone ? 0 : 1, $0.placeMinute) < ($1.isDone ? 0 : 1, $1.placeMinute) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Calendar", subtitle: subtitle) {
                    Menu {
                        Button("Everyone") { clientFilter = nil }
                        ForEach(store.roster) { c in Button(c.name) { clientFilter = c.id } }
                    } label: {
                        HStack(spacing: 6) {
                            Text(clientFilter.flatMap { id in store.roster.first { $0.id == id }?.name } ?? "Everyone")
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                        .padding(.horizontal, 14).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
                    }
                    .hoverEffect(.highlight)
                    HStack(spacing: 2) {
                        segButton("chevron.left", "Previous week") { shift(-1) }
                        Button("This week") { withAnimation(.easeOut(duration: 0.15)) { weekStart = cal.startOfWeek(for: Date()) } }
                            .font(PadFont.ui(14, .semibold)).foregroundColor(isThisWeek ? Pad.text : Pad.mute)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isThisWeek ? Pad.raised : Color.clear))
                            .hoverEffect(.highlight)
                        segButton("chevron.right", "Next week") { shift(1) }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Pad.well))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
                    Button { newWorkout() } label: { Label("New workout", systemImage: "plus") }.buttonStyle(PadButtonStyle(kind: .primary))
                }
                PadPanel(padding: 14) {
                    if sideBySide {
                        grid.frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) { grid.frame(width: 7 * 180) }
                    }
                    legend
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { store.loadRoster(); await data.refresh(roster: store.roster) }
        .sheet(item: $commentFor) { s in
            if let id = s.currentSetId {
                SetCommentSheet(setId: id, label: "\(s.title) · \(s.currentExercise ?? "") · \(s.currentSetText ?? "")", clientName: s.clientName)
            }
        }
    }

    private var isThisWeek: Bool { cal.isDate(weekStart, inSameDayAs: cal.startOfWeek(for: Date())) }
    private func shift(_ n: Int) {
        withAnimation(.easeOut(duration: 0.15)) { weekStart = cal.date(byAdding: .day, value: 7 * n, to: weekStart) ?? weekStart }
    }
    private func segButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundColor(Pad.mute).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain).hoverEffect(.highlight).accessibilityLabel(label)
    }

    private var subtitle: String {
        let a = weekStart.formatted(.dateTime.month(.wide).day())
        let b = (cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart).formatted(.dateTime.month(.wide).day())
        let done = sessions.filter { $0.isDone }.count
        let moved = sessions.filter { $0.movedFrom != nil }.count
        var s = "\(a) to \(b) · \(sessions.count.plural("session")), \(done) done"
        if moved > 0 { s += " · \(moved) moved" }
        return s + "."
    }

    // MARK: The grid

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { d in dayHeader(d) }
            }
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.self) { d in dayColumn(d) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.well))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func dayHeader(_ d: Date) -> some View {
        let today = cal.isDateInToday(d)
        let ss = sessions(on: d)
        return VStack(alignment: .leading, spacing: 2) {
            Text(today ? "\(d.formatted(.dateTime.weekday(.abbreviated))) · today" : d.formatted(.dateTime.weekday(.abbreviated)))
                .font(PadFont.cond(13)).foregroundColor(Pad.mute)
            Text("\(cal.component(.day, from: d))").font(PadFont.display(30))
                .foregroundColor(today ? Pad.onVolt : Pad.text)
                .padding(.horizontal, today ? 6 : 0).padding(.vertical, today ? 2 : 0)
                .background(RoundedRectangle(cornerRadius: 7).fill(today ? Pad.volt : Color.clear))
            Text(countLine(ss, day: d)).font(PadFont.cond(12)).foregroundColor(Pad.faint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 10)
        .background(Pad.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Pad.line).frame(width: 1) }
    }

    private func countLine(_ ss: [PadSession], day: Date) -> String {
        if ss.isEmpty { return day < cal.startOfDay(for: Date()) ? "Nothing" : "Rest day" }
        let done = ss.filter { $0.isDone }.count
        let live = ss.filter { $0.isLive }.count
        if cal.isDateInToday(day) {
            var bits = ["\(done) done"]
            if live > 0 { bits.append("\(live) lifting") }
            let left = ss.count - done - live
            if left > 0 { bits.append("\(left) to go") }
            return bits.joined(separator: " · ")
        }
        if day < cal.startOfDay(for: Date()) { return done == ss.count ? "\(ss.count.plural("session")) · all done" : "\(done) of \(ss.count) done" }
        return "\(ss.count) planned"
    }

    private func dayColumn(_ d: Date) -> some View {
        let ss = sessions(on: d)
        let targeted = targetDay.map { cal.isDate($0, inSameDayAs: d) } ?? false
        let past = d < cal.startOfDay(for: Date())
        return VStack(spacing: 6) {
            if targeted {
                Text("Drop here · \(d.formatted(.dateTime.weekday(.abbreviated).day()))").font(PadFont.cond(12)).foregroundColor(Pad.faint)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundColor(Pad.line2))
            }
            ForEach(ss) { s in card(s) }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .top)
        .background(cal.isDateInToday(d) ? Pad.text.opacity(0.025) : Color.clear)
        .opacity(past ? 0.85 : 1)
        .overlay(alignment: .trailing) { Rectangle().fill(Pad.line).frame(width: 1) }
        .dropDestination(for: String.self) { ids, _ in
            targetDay = nil
            guard let id = ids.first else { return false }
            move(id, to: d)
            return true
        } isTargeted: { on in
            targetDay = on ? d : (targetDay.map { cal.isDate($0, inSameDayAs: d) } == true ? nil : targetDay)
        }
    }

    @ViewBuilder
    private func card(_ s: PadSession) -> some View {
        let base = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PadAvatar(name: s.clientName, size: 20, volt: s.isLive)
                Text(s.clientName).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
            }
            Text(s.programLabel ?? s.title).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
            HStack(spacing: 6) {
                if s.isDone {
                    PadLab("\(s.setsLogged) of \(s.setsTotal)", size: 12)
                    if data.prsThisWeek(clientId: s.clientId).contains(where: { cal.isDate($0.date, inSameDayAs: s.day) }) { PadTag(text: "PR", kind: .volt) }
                } else if s.isLive {
                    PadLab("Lifting · set \(s.setsLogged + 1) of \(s.setsTotal)", size: 12)
                } else if s.isMissed {
                    PadTag(text: "Missed", kind: .bad)
                } else if let m = s.movedFrom {
                    PadTag(text: "From \(m.formatted(.dateTime.weekday(.abbreviated)))", kind: .warn)
                } else {
                    PadTag(text: s.programLabel == nil ? "Planned" : "Program", kind: .line)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(s.isDone ? Pad.done : (s.isMissed ? Color.clear : (s.isLive ? Pad.liveFill : Pad.raised))))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(s.isLive ? (Pad.isLight ? Pad.text : Pad.volt) : (s.isMissed ? Pad.line2 : Color.clear), lineWidth: s.isLive ? 1.5 : 1))
        .opacity(moving.contains(s.id) ? 0.5 : 1)

        Menu {
            Button { store.selectedClient = store.roster.first { $0.id == s.clientId } } label: { Label("Open \(s.clientName.firstName)’s workouts", systemImage: "person") }
            if !s.isDone {
                Menu {
                    ForEach(days, id: \.self) { d in
                        Button(d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) { move(s.id, to: d) }
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
        .draggable(s.id) { base.frame(width: 160) }
        .disabled(moving.contains(s.id))
        .accessibilityLabel("\(s.clientName), \(s.title), \(s.isDone ? "done" : (s.isLive ? "lifting now" : (s.isMissed ? "missed" : "planned")))")
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(Pad.done, nil, "Done, with sets logged")
            legendItem(Pad.raised, nil, "Planned")
            legendItem(Pad.liveFill, Pad.isLight ? Pad.text : Pad.volt, "Lifting now")
            legendItem(.clear, Pad.line2, "Missed")
            Spacer(minLength: 0)
            PadLab("Drag a session to another day to move it; the client is told. Tap one for Move, Open or Comment.", color: Pad.faint).lineLimit(2)
        }
    }
    private func legendItem(_ fill: Color, _ stroke: Color?, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(stroke ?? .clear, lineWidth: 1.5))
            PadLab(text)
        }
    }

    // MARK: Moving

    private func move(_ id: String, to day: Date) {
        guard let s = sessions.first(where: { $0.id == id }) ?? data.sessions(for: store.roster).first(where: { $0.id == id }),
              !s.isDone, !cal.isDate(s.day, inSameDayAs: day) else { return }
        moving.insert(id)
        let from = s.day
        Task {
            do {
                try await APIClient.shared.trainerMoveWorkout(id: id, to: day)
                await data.refresh(roster: store.roster)
                await MainActor.run {
                    moving.remove(id)
                    PadToasts.shared.show("Moved \(s.clientName.firstName)’s \(s.title) to \(day.formatted(.dateTime.weekday(.wide)))", action: "Undo") {
                        Task {
                            try? await APIClient.shared.trainerMoveWorkout(id: id, to: from)
                            await data.refresh(roster: store.roster)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    moving.remove(id)
                    PadToasts.shared.show("Couldn’t move it. Check your connection and try again.")
                }
            }
        }
    }
}
