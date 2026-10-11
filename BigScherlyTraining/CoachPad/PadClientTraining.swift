import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's Workouts and Program (Oct 9, 2026)
//
// Workouts: a week-by-week grid (so a pattern of misses shows at a glance), the session set by set
// with what changed since last time, lift status, bar speed and the Watch heart rate under it.
// Tools: edit the next session, nudge it up 2.5%, move a session, ask for a form check.
// Program: the block as weeks across the top (and what comes after it), a day-by-day grid, the
// automatic progressions and the moved sessions. Tools: assign the next block, end it.
// Synchronized folder: no target step needed.

// MARK: - Workouts

struct PadClientWorkouts: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @State private var selectedId: String?
    @State private var weeksBack = 8
    @State private var health: [String: APIWorkoutHealthRow] = [:]
    @State private var editing: Workout?
    @State private var opened: Workout?
    @State private var quick: PadQuickMessage?
    @State private var confirmNudge = false
    @State private var nudging = false

    private var cal: Calendar { Calendar.training }

    var body: some View {
        let ss = data.sessions(client: facts.client)
        let next = ss.filter { $0.isPlanned }.min { $0.day < $1.day }
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(ss), notices: notices(ss)) {
                if let n = next {
                    Button { editing = model(n.id) } label: { Label("Edit next", systemImage: "pencil") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    Button { confirmNudge = true } label: {
                        HStack(spacing: 6) { if nudging { ProgressView() }; Text("Next +2.5%") }
                    }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    .disabled(nudging)
                }
                Button {
                    quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Form check",
                                            text: "Can you film your next top set of \(mainLift(ss) ?? "your main lift") from the side? I want to check your form.")
                } label: { Label("Form check", systemImage: "video") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadRule()
            HStack(spacing: 0) {
                weekColumn(ss).frame(width: 340)
                Rectangle().fill(Pad.line).frame(width: 1)
                if let s = ss.first(where: { $0.id == selectedId }) {
                    PadSessionDetail(facts: facts, session: s, health: health[s.id],
                                     onEdit: { editing = model(s.id) }, onOpen: { opened = model(s.id) })
                        .id(s.id)
                } else {
                    PadEmptyLine(text: ss.isEmpty ? "No workouts yet. Add one with New workout." : "Pick a session.")
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onChange(of: ss.count) { _, _ in if selectedId == nil { autoSelect(ss) } }
        .task {
            if let w = PadNav.shared.workoutId { selectedId = w; PadNav.shared.workoutId = nil }
            if selectedId == nil { autoSelect(ss) }
            await data.loadContext(facts.id)
            let rows = (try? await APIClient.shared.trainerClientHealth(clientId: facts.id)) ?? []
            health = Dictionary(rows.map { ($0.workoutId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        .sheet(item: $editing) { w in
            WorkoutBuilderView(clientId: facts.id, clientName: facts.name, editing: w,
                               programLabel: ss.first { $0.id == w.id }?.programLabel) {
                Task { await data.refresh(roster: store.roster) }
            }
        }
        .sheet(item: $opened) { w in
            NavigationStack {
                TrainerWorkoutDetailView(workout: w, clientId: facts.id, clientName: facts.name, programLabel: ss.first { $0.id == w.id }?.programLabel) {
                    Task { await data.refresh(roster: store.roster) }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { opened = nil }.foregroundColor(Brand.voltText) } }
            }
            .tint(Brand.volt)
        }
        .sheet(item: $quick) { m in PadQuickMessageSheet(message: m) }
        .alert("Raise " + (next?.title ?? "the next session") + " by 2.5%?", isPresented: $confirmNudge) {
            Button("Raise weights") { if let n = next { nudge(n) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every set with a fixed weight goes up 2.5%, rounded to the nearest \(StatsUnits.weightLabel == "kg" ? "1 kg" : "2.5 lb"). Only this session changes.")
        }
    }

    private func autoSelect(_ ss: [PadSession]) {
        let lastDone = ss.filter { $0.isDone }.max { ($0.finish ?? $0.day) < ($1.finish ?? $1.day) }
        selectedId = lastDone?.id ?? ss.filter { $0.isPlanned }.min { $0.day < $1.day }?.id
    }

    private func model(_ id: String) -> Workout? { data.apiWorkouts[facts.id]?.first { $0.id == id }?.toModel() }

    private func mainLift(_ ss: [PadSession]) -> String? {
        let names = (data.workouts[facts.id] ?? []).filter { $0.completed }.flatMap { $0.exercises.prefix(1).map { $0.name } }
        return Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    // MARK: Headline

    private func stats(_ ss: [PadSession]) -> [PadStat] {
        let today = cal.startOfDay(for: Date())
        let d28 = cal.date(byAdding: .day, value: -28, to: today) ?? today
        let d56 = cal.date(byAdding: .day, value: -56, to: today) ?? today
        let done28 = ss.filter { $0.isDone && $0.day >= d28 }
        let donePrev = ss.filter { $0.isDone && $0.day >= d56 && $0.day < d28 }
        let mins = done28.compactMap { s -> Double? in
            guard let a = s.start, let b = s.finish, b > a else { return nil }
            return b.timeIntervalSince(a) / 60
        }.sorted()
        let rpeNow = mean(done28.compactMap { $0.avgRPE })
        let rpeThen = mean(donePrev.compactMap { $0.avgRPE })
        let tonWeek = tonnage(from: cal.startOfWeek(for: Date()), days: 7)
        let tonAvg = (1...4).map { i in tonnage(from: cal.date(byAdding: .weekOfYear, value: -i, to: cal.startOfWeek(for: Date())) ?? today, days: 7) }
        let avg = tonAvg.reduce(0, +) / 4
        let missed28: Int = max(facts.planned28 - facts.done28, 0)
        let sessSub: String = facts.missedStreak >= 2 ? "\(facts.missedStreak) missed in a row" : (missed28 > 0 ? "\(missed28) missed" : "none missed")
        var out: [PadStat] = [
            PadStat(label: "Sessions, 4 wks", value: "\(facts.done28)", unit: "of \(max(facts.planned28, facts.done28))",
                    sub: sessSub, warn: facts.missedStreak >= 2),
            PadStat(label: "Session length", value: mins.isEmpty ? "—" : "\(Int(mins[mins.count / 2]))", unit: mins.isEmpty ? nil : "min", sub: "median, 4 wks")
        ]
        if let r = rpeNow {
            let d: Double = rpeThen.map { r - $0 } ?? 0
            var rpeSub: String = "4 wks"
            if rpeThen != nil {
                if abs(d) < 0.25 { rpeSub = "same as before" }
                else { rpeSub = (d > 0 ? "+" : "−") + abs(d).padShort + " vs the 4 wks before" }
            }
            out.append(PadStat(label: "Average RPE", value: r.rpeText, sub: rpeSub, warn: d >= 0.5))
        }
        let pct: Int = avg > 0 ? Int(((tonWeek - avg) / avg * 100).rounded()) : 0
        var volSub: String = "lifted in total"
        if avg > 0 { volSub = (pct >= 0 ? "+" : "−") + "\(abs(pct))% vs 4-wk average" }
        out.append(PadStat(label: "Volume this week", value: StatsUnits.weightText(tonWeek, unit: false), unit: StatsUnits.weightLabel,
                           sub: volSub, warn: avg > 0 && pct <= -40))
        return out
    }

    private func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

    private func tonnage(from start: Date, days: Int) -> Double {
        let end = cal.date(byAdding: .day, value: days, to: start) ?? start
        return (data.apiWorkouts[facts.id] ?? []).flatMap { $0.exercises.flatMap { $0.sets } }
            .filter { s in (s.loggedAt.map { $0 >= start && $0 < end } ?? false) }
            .reduce(0) { $0 + Double($1.loggedReps ?? 0) * ($1.loggedWeight ?? 0) }
    }

    // MARK: Noticing (workout-specific)

    private func notices(_ ss: [PadSession]) -> [PadInsights.Notice] {
        var out: [PadInsights.Notice] = []
        let today = cal.startOfDay(for: Date())
        let ws = data.apiWorkouts[facts.id] ?? []
        // The same weight feeling harder.
        let d28 = cal.date(byAdding: .day, value: -28, to: today) ?? today
        let d56 = cal.date(byAdding: .day, value: -56, to: today) ?? today
        var best: (String, Double, Double, Double)? = nil
        for name in Set(ws.flatMap { $0.exercises.map { $0.name } }) {
            let sets = ws.flatMap { w in w.exercises.filter { $0.name == name }.flatMap { $0.sets } }.filter { $0.loggedWeight != nil && $0.rpe != nil }
            let byLoad = Dictionary(grouping: sets, by: { $0.loggedWeight ?? 0 })
            for (load, ss2) in byLoad where load > 0 {
                let now = ss2.filter { ($0.loggedAt ?? .distantPast) >= d28 }.compactMap { $0.rpe }
                let then = ss2.filter { let t = $0.loggedAt ?? .distantPast; return t >= d56 && t < d28 }.compactMap { $0.rpe }
                guard now.count >= 2, then.count >= 2 else { continue }
                let a = now.reduce(0, +) / Double(now.count), b = then.reduce(0, +) / Double(then.count)
                if a - b >= 0.75, (best == nil || a - b > best!.3 - best!.2) { best = (name, load, b, a) }
            }
        }
        if let b = best {
            out.append(.init(icon: "gauge.with.dots.needle.67percent", tint: Pad.orange,
                             text: "\(b.0) at \(StatsUnits.weightText(b.1)) feels harder: RPE \(b.3.rpeText) now, \(b.2.rpeText) a month ago.",
                             aside: "Fatigue, sleep or stress, not strength."))
        }
        // An exercise they keep skipping.
        let recent = ws.filter { w in w.exercises.contains { $0.sets.contains { $0.loggedReps != nil } } }.sorted { $0.scheduledDate > $1.scheduledDate }.prefix(6)
        var skips: [String: (Int, Int)] = [:]
        for w in recent {
            for e in w.exercises {
                let skipped = !e.sets.contains { $0.loggedReps != nil }
                let c = skips[e.name] ?? (0, 0)
                skips[e.name] = (c.0 + (skipped ? 1 : 0), c.1 + 1)
            }
        }
        if let s = skips.filter({ $0.value.0 >= 2 && Double($0.value.0) / Double($0.value.1) >= 0.5 }).max(by: { $0.value.0 < $1.value.0 }) {
            out.append(.init(icon: "forward.end", tint: Pad.mute, text: "Skips \(s.key): \(s.value.0) of the last \(s.value.1) times.",
                             aside: "Swap it for something they'll do?"))
        }
        // Misses on one weekday.
        let d56b = cal.date(byAdding: .weekOfYear, value: -8, to: today) ?? today
        let missed = ss.filter { $0.isMissed && $0.day >= d56b }
        if missed.count >= 3 {
            let byDay = Dictionary(grouping: missed, by: { cal.component(.weekday, from: $0.day) })
            if let top = byDay.max(by: { $0.value.count < $1.value.count }), Double(top.value.count) / Double(missed.count) >= 0.6 {
                let name = cal.weekdaySymbols[top.key - 1]
                out.append(.init(icon: "calendar.badge.exclamationmark", tint: Pad.orange,
                                 text: "\(top.value.count) of \(missed.count) misses were \(name)s.", aside: "Another day may suit them better."))
            }
        }
        return out
    }

    // MARK: Week grid

    private func weekColumn(_ ss: [PadSession]) -> some View {
        let start = cal.startOfWeek(for: Date())
        let weeks: [Date] = (-1..<weeksBack).map { cal.date(byAdding: .weekOfYear, value: -$0, to: start) ?? start }
        let selected = ss.first { $0.id == selectedId }
        let selWeek = selected.map { cal.startOfWeek(for: $0.day) } ?? start
        let inWeek = ss.filter { cal.startOfWeek(for: $0.day) == selWeek }.sorted { $0.day < $1.day }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("").frame(width: 58)
                    ForEach(0..<7, id: \.self) { i in
                        Text(Calendar.trainingWeekdayLetters[i]).font(PadFont.cond(11)).foregroundColor(Pad.faint).frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 6)
                ForEach(weeks, id: \.self) { w in weekRow(w, ss: ss, on: w == selWeek) }
                Button("Show 8 more weeks") { weeksBack += 8 }
                    .font(PadFont.ui(13, .semibold)).foregroundColor(Pad.mute).padding(.top, 8)
                Rectangle().fill(Pad.line).frame(height: 1).padding(.vertical, 14)
                Text("Week of \(PadDay.short(selWeek))").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).padding(.bottom, 6)
                if inWeek.isEmpty { PadEmptyLine(text: "Nothing planned that week.") }
                ForEach(inWeek) { s in sessionRow(s) }
                HStack(spacing: 12) {
                    legend(Pad.volt, nil, "Done"); legend(nil, Pad.orange, "Missed"); legend(nil, Pad.line2, "Planned")
                }
                .padding(.top, 12)
            }
            .padding(14)
        }
    }

    private func weekRow(_ w: Date, ss: [PadSession], on: Bool) -> some View {
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: w) ?? w }
        let isThis = w == cal.startOfWeek(for: Date())
        return HStack(spacing: 4) {
            Text(isThis ? "This wk" : (w > Date() ? "Next" : PadDay.short(w)))
                .font(PadFont.cond(11)).foregroundColor(on ? Pad.text : Pad.faint).frame(width: 58, alignment: .leading)
            ForEach(days, id: \.self) { d in
                let mine = ss.filter { cal.isDate($0.day, inSameDayAs: d) }
                dayCell(mine)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Pad.surface : Color.clear))
    }

    @ViewBuilder
    private func dayCell(_ mine: [PadSession]) -> some View {
        if let s = mine.first {
            let sel = mine.contains { $0.id == selectedId }
            let state: String = s.isDone ? "done" : (s.isMissed ? "missed" : "planned")
            let a11y: String = s.title + ", " + PadDay.weekdayShort(s.day) + ", " + state
            Button { selectedId = mine.count > 1 && sel ? mine.first { $0.id != selectedId }?.id : s.id } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(s.isDone ? Pad.volt : (s.isLive ? Pad.volt.opacity(0.5) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(s.isMissed ? Pad.orange : (s.isPlanned ? Pad.line2 : Color.clear), lineWidth: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(sel ? Pad.text : Color.clear, lineWidth: 2).padding(-3))
                    .overlay(alignment: .topTrailing) {
                        if mine.count > 1 { Text("\(mine.count)").font(PadFont.cond(9, .bold)).foregroundColor(s.isDone ? Pad.onVolt : Pad.text).padding(2) }
                    }
                    .frame(height: 26).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a11y)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Pad.raised.opacity(0.45)).frame(height: 26).frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }

    private func sessionRow(_ s: PadSession) -> some View {
        let on = s.id == selectedId
        var sub = PadDay.weekdayShort(s.day)
        if s.isDone, let a = s.start, let b = s.finish, b > a { sub += " · \(Int(b.timeIntervalSince(a) / 60)) min" }
        if let r = s.avgRPE { sub += " · RPE \(r.rpeText)" }
        if let m = s.movedFrom { sub += " · moved from \(m.formatted(.dateTime.weekday(.abbreviated)))" }
        return Button { selectedId = s.id } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(PadFont.ui(14, .semibold)).foregroundColor(s.isMissed ? Pad.mute : Pad.text).lineLimit(1)
                    Text(sub).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 6)
                if s.isLive { PadTag(text: "Live", kind: .volt) }
                else if s.isMissed { PadTag(text: "Missed", kind: .warn) }
                else if s.isDone { PadTag(text: "\(s.setsLogged)/\(s.setsTotal)") }
                else { PadTag(text: "Planned", kind: .line) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Pad.line2 : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func legend(_ fill: Color?, _ stroke: Color?, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(fill ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke ?? Color.clear, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
    }

    // MARK: Nudge +2.5%

    private func nudge(_ s: PadSession) {
        guard let w = model(s.id) else { return }
        nudging = true
        let kg = StatsUnits.weightLabel == "kg"
        let exs: [[String: Any]] = w.exercises.enumerated().map { i, e in
            var d = DraftExercise(from: e)
            for j in d.sets.indices where d.sets[j].kind == .fixed || d.sets[j].kind == .amrap {
                guard j < e.sets.count else { continue }
                let lb = e.sets[j].targetWeight
                guard lb > 0 else { continue }
                let shown = kg ? lb * 1.025 * 0.45359237 : lb * 1.025
                let step = kg ? 1.0 : 2.5
                let r = (shown / step).rounded() * step
                d.sets[j].weight = r == r.rounded() ? String(Int(r)) : String(r)
            }
            return d.payload(order: i)
        }
        let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: w.date) ?? w.date
        let payload: [String: Any] = ["id": w.id, "title": w.title, "scheduledDate": ISO8601DateFormatter().string(from: day),
                                      "completed": false, "exercises": exs]
        Task {
            do {
                try await APIClient.shared.trainerUpdateWorkout(workoutId: w.id, scope: "this", payload: payload)
                await data.refresh(roster: store.roster)
                await MainActor.run { nudging = false; PadToasts.shared.show("\(w.title) is 2.5% heavier") }
            } catch {
                await MainActor.run { nudging = false; PadToasts.shared.show("Couldn’t change \(w.title). Try again.") }
            }
        }
    }
}

/// One session, set by set, with what changed since last time and the heart rate under it.
struct PadSessionDetail: View {
    let facts: PadClientFacts
    let session: PadSession
    let health: APIWorkoutHealthRow?
    let onEdit: () -> Void
    let onOpen: () -> Void
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @State private var moving = false
    @State private var moveTo = Date()

    private var cal: Calendar { Calendar.training }
    private var api: APIWorkout? { data.apiWorkouts[facts.id]?.first { $0.id == session.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let w = api {
                    let model = w.toModel()
                    ForEach(w.exercises.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { ex in
                        if let m = model.exercises.first(where: { $0.id == ex.id }) { exerciseCard(ex, m) }
                    }
                }
                if let h = health, h.heartRateSeries.count >= 4 { heartCard(h) }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(PadFont.display(30)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                Text(line).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(2)
            }
            Spacer(minLength: 8)
            if !session.isDone {
                Button { moveTo = session.day; moving = true } label: { Label("Move", systemImage: "calendar") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    .popover(isPresented: $moving) { movePicker }
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            Button(action: onOpen) { Label(session.isDone ? "Comment" : "Open", systemImage: session.isDone ? "text.bubble" : "arrow.up.right") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
        }
    }

    private var movePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(session.title) to").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            DatePicker("Day", selection: $moveTo, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().tint(Pad.voltText)
            HStack {
                Spacer()
                Button("Move") {
                    moving = false
                    let id = session.id, title = session.title, to = moveTo
                    Task {
                        do {
                            try await APIClient.shared.trainerMoveWorkout(id: id, to: to)
                            await data.refresh(roster: store.roster)
                            PadToasts.shared.show("\(title) moved to \(PadDay.weekdayShort(to))")
                        } catch { PadToasts.shared.show("Couldn’t move it. Try again.") }
                    }
                }
                .buttonStyle(PadButtonStyle(kind: .primary, small: true))
            }
        }
        .padding(18).frame(width: 340).background(Pad.surface)
    }

    private var line: String {
        var bits = [PadDay.weekdayShort(session.day)]
        if let a = session.start, let b = session.finish, b > a {
            bits.append("\(a.padClock) to \(b.padClock) · \(Int(b.timeIntervalSince(a) / 60)) min")
        }
        if session.setsTotal > 0 { bits.append(session.isDone || session.isMissed ? "\(session.setsLogged) of \(session.setsTotal) sets" : "\(session.setsTotal) sets planned") }
        if let r = session.avgRPE { bits.append("average RPE \(r.rpeText)") }
        if let h = health, let avg = h.avgHeartRate { bits.append("\(avg) bpm average") }
        if let p = session.programLabel { bits.append(p) }
        if let m = session.movedFrom { bits.append("moved from \(PadDay.weekdayShort(m))") }
        return bits.joined(separator: " · ")
    }

    // Lift status from its whole history: last 3 sessions against the 3 before.
    private func status(_ name: String) -> (String, PadTag.Kind)? {
        let h = ProgressEngine.history(for: name, workouts: data.workouts[facts.id] ?? []).sorted { $0.date < $1.date }
        guard h.count >= 2 else { return h.count == 1 ? ("New", PadTag.Kind.blue) : nil }
        let last = h.suffix(3).map { $0.estimatedOneRepMax }.max() ?? 0
        let before = h.dropLast(3).suffix(3).map { $0.estimatedOneRepMax }.max()
        guard let before, before > 0 else { return nil }
        let ch = (last - before) / before
        if ch >= 0.02 { return ("Progressing", .volt) }
        if ch <= -0.03 { return ("Going backwards", .warn) }
        return h.count >= 5 ? ("Stalled", .plain) : nil
    }

    /// The same exercise the time before this session.
    private func previous(_ name: String) -> [APISet]? {
        (data.apiWorkouts[facts.id] ?? [])
            .filter { $0.id != session.id && $0.scheduledDate < session.day }
            .sorted { $0.scheduledDate > $1.scheduledDate }
            .compactMap { w in w.exercises.first { e in e.name == name && e.sets.contains { $0.loggedReps != nil } } }
            .first?.sets.sorted { $0.setOrder < $1.setOrder }
    }

    private func exerciseCard(_ ex: APIExercise, _ model: Exercise) -> some View {
        let sets = ex.sets.sorted { $0.setOrder < $1.setOrder }
        let modelSets = sets.compactMap { a in model.sets.first { $0.id == a.id } }
        let logged = sets.filter { $0.loggedReps != nil }.count
        let past = session.isDone || session.isMissed
        let prev = previous(ex.name) ?? []
        let st = status(ex.name)
        let speeds = sets.compactMap { data.velocity(clientId: facts.id, setId: $0.id) }
        var countLabel: String = sets.count.plural("set")
        if past { countLabel = logged == sets.count ? "all \(sets.count) sets logged" : "\(logged) of \(sets.count) logged" }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ex.name).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                if let st { PadTag(text: st.0, kind: st.1) }
                Spacer()
                PadLab(countLabel, color: past && logged < sets.count ? Pad.orange : Pad.mute)
            }
            .padding(.vertical, 10)
            if !ex.clientNotes.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("“\(ex.clientNotes)”").font(PadFont.ui(13)).foregroundColor(Pad.mute).padding(.bottom, 8)
            }
            HStack(spacing: 8) {
                th("Set", 40); th("Prescribed", nil); th(past ? "Logged · vs last time" : "Last time", nil); th("RPE", 46, true); th(speeds.isEmpty ? "" : "Bar speed", 150)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line2).frame(height: 1) }
            ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                let v = data.velocity(clientId: facts.id, setId: s.id)
                let slow = v.flatMap { vv in speeds.first.map { vv < $0 * 0.85 } } ?? false
                HStack(spacing: 8) {
                    Text("\(i + 1)").foregroundColor(Pad.mute).frame(width: 40, alignment: .leading)
                    Text(i < modelSets.count ? SetTarget.text(modelSets[i], in: model) : "").foregroundColor(Pad.mute)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    loggedCell(s, prev: i < prev.count ? prev[i] : nil, past: past).frame(maxWidth: .infinity, alignment: .leading)
                    Text(s.rpe.map { $0.rpeText } ?? "—").foregroundColor(s.rpe == nil ? Pad.faint : Pad.text).frame(width: 46, alignment: .trailing)
                    HStack(spacing: 8) {
                        if let v {
                            RoundedRectangle(cornerRadius: 3).fill(slow ? Pad.orange : Pad.text).frame(width: max(8, min(100, CGFloat(v) * 170)), height: 6)
                            Text(String(format: "%.2f", v)).monospacedDigit()
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                }
                .font(PadFont.ui(14))
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func th(_ t: String, _ w: CGFloat?, _ trailing: Bool = false) -> some View {
        Group {
            if let w { Text(t).frame(width: w, alignment: trailing ? .trailing : .leading) }
            else { Text(t).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(PadFont.cond(12)).foregroundColor(Pad.faint).lineLimit(1)
    }

    private func setText(_ s: APISet) -> String {
        guard let r = s.loggedReps else { return "—" }
        let w = s.loggedWeight ?? 0
        return w > 0 ? "\(StatsUnits.weightText(w, unit: false)) × \(r)" : "\(r) reps"
    }

    /// "225 × 5  +5 lb" — the change since the same set last time, in the accent when it went up.
    @ViewBuilder
    private func loggedCell(_ s: APISet, prev: APISet?, past: Bool) -> some View {
        if !past {
            Text(prev.map { setText($0) } ?? "—").foregroundColor(Pad.mute)
        } else if let r = s.loggedReps {
            let short = r < s.targetReps && s.amrap != true
            HStack(spacing: 6) {
                Text(setText(s)).foregroundColor(short ? Pad.orange : Pad.text)
                if let d = delta(s, prev) { Text(d.0).font(PadFont.cond(12)).foregroundColor(d.1 ? Pad.voltText : Pad.orange) }
            }
        } else {
            Text("Skipped").foregroundColor(Pad.orange)
        }
    }

    private func delta(_ s: APISet, _ p: APISet?) -> (String, Bool)? {
        guard let p, let r = s.loggedReps, let pr = p.loggedReps else { return nil }
        let w = s.loggedWeight ?? 0, pw = p.loggedWeight ?? 0
        if abs(w - pw) >= 0.5 { return ("\(w > pw ? "+" : "−")\(StatsUnits.weightText(abs(w - pw)))", w > pw) }
        if r != pr { return ("\(r > pr ? "+" : "−")\(abs(r - pr).plural("rep"))", r > pr) }
        return nil
    }

    private func heartCard(_ h: APIWorkoutHealthRow) -> some View {
        let series = h.heartRateSeries.sorted { $0.t < $1.t }
        let marks = (api?.exercises.flatMap { $0.sets }.compactMap { $0.loggedAt } ?? []).sorted()
        let t0 = series.first!.t, t1 = series.last!.t
        let span = max(t1.timeIntervalSince(t0), 1)
        var bits: [String] = []
        if let a = h.avgHeartRate { bits.append("average \(a)") }
        if let pk = h.peakHeartRate { bits.append("peak \(pk) bpm") }
        if let k = h.activeCalories { bits.append("\(k) kcal") }
        let aside: String = bits.joined(separator: " · ")
        return PadPane(title: "Heart rate", aside: aside) {
            Canvas { ctx, size in
                let bs = series.map { Double($0.b) }
                let mn = (bs.min() ?? 60) - 5, mx = (bs.max() ?? 180) + 5
                func x(_ d: Date) -> CGFloat { size.width * CGFloat(d.timeIntervalSince(t0) / span) }
                func y(_ b: Double) -> CGFloat { size.height * (1 - CGFloat((b - mn) / max(mx - mn, 1))) }
                for m in marks where m >= t0 && m <= t1 {
                    var p = Path(); p.move(to: CGPoint(x: x(m), y: 0)); p.addLine(to: CGPoint(x: x(m), y: size.height))
                    ctx.stroke(p, with: .color(Pad.line2), lineWidth: 1)
                }
                var p = Path()
                for (i, s) in series.enumerated() {
                    let pt = CGPoint(x: x(s.t), y: y(Double(s.b)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(Pad.red.opacity(0.9)), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            .frame(height: 110)
            .accessibilityLabel("Heart rate over the session")
            HStack {
                PadLab(t0.padClock, color: Pad.faint, size: 11); Spacer()
                PadLab("grey lines are logged sets", color: Pad.faint, size: 11); Spacer()
                PadLab(t1.padClock, color: Pad.faint, size: 11)
            }
        }
    }
}

// MARK: - Program

struct PadClientProgram: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padGo) private var goSection
    @State private var detail: APIProgramDetail?
    @State private var changes: [APIProgressionChange] = []
    @State private var programs: [APIProgramSummary] = []
    @State private var assignFor: APIProgramSummary?
    @State private var confirmEnd = false

    private var cal: Calendar { Calendar.training }
    private var mine: [APIAssignment] { data.assignments.filter { $0.clientId == facts.id }.sorted { $0.startDate < $1.startDate } }
    private var current: APIAssignment? { facts.assignment }
    private var nextBlock: APIAssignment? {
        guard let c = current else { return nil }
        return mine.first { $0.id != c.id && $0.startDate >= c.endDate.addingTimeInterval(-86_400) }
    }

    var body: some View {
        let ss = data.sessions(client: facts.client)
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(ss), notices: notices(ss)) {
                Menu {
                    if programs.isEmpty { Text("No programs yet") }
                    ForEach(programs) { p in Button("\(p.name) · \(p.weeks) wks") { assignFor = p } }
                } label: {
                    Label(current == nil ? "Assign a program" : "Assign next block", systemImage: "plus")
                        .font(PadFont.ui(14, .semibold)).foregroundColor(current == nil ? Pad.onVolt : Pad.text)
                        .padding(.horizontal, 13).frame(minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(current == nil ? Pad.volt : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(current == nil ? Color.clear : Pad.line2, lineWidth: 1))
                }
                if let a = current {
                    Button { openStats(a) } label: { Label("Block stats", systemImage: "chart.xyaxis.line") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    Button("End program", role: .destructive) { confirmEnd = true }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                Button { goSection(.programs) } label: { Label("Programs", systemImage: "arrow.up.right") }
                    .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
            }
            PadRule()
            if let a = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        timeline(a, ss: ss)
                        HStack(alignment: .top, spacing: 14) {
                            dayGrid(a, ss: ss).frame(maxWidth: .infinity)
                            VStack(spacing: 14) { progressionsPane; movesPane(a, ss: ss) }.frame(width: 320)
                        }
                    }
                    .padding(20)
                }
            } else {
                noProgram
            }
        }
        .task { await load() }
        .sheet(item: $assignFor) { p in
            AssignProgramSheet(programId: p.id, programName: p.name, preselected: facts.id) {
                Task { await data.refresh(roster: store.roster); await load() }
            }
        }
        .confirmationDialog("End \(current?.programName ?? "the program") for \(facts.first)?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End program", role: .destructive) {
                guard let a = current else { return }
                Task {
                    do {
                        try await APIClient.shared.endAssignment(a.id)
                        await data.refresh(roster: store.roster)
                        PadToasts.shared.show("\(a.programName) ended")
                    } catch { PadToasts.shared.show("Couldn’t end it. Try again.") }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sessions already logged stay. Planned ones from the program are removed.") }
    }

    private func load() async {
        programs = (try? await APIClient.shared.programs()) ?? programs
        changes = (try? await APIClient.shared.progressionChanges(clientId: facts.id, days: 42)) ?? changes
        if let a = current { detail = try? await APIClient.shared.program(a.programId) }
    }

    private func inBlock(_ a: APIAssignment, _ ss: [PadSession]) -> [PadSession] {
        let s = cal.startOfDay(for: a.startDate), e = a.endDate.addingTimeInterval(86_400)
        return ss.filter { $0.day >= s && $0.day < e }
    }

    // MARK: Headline + noticing

    private func stats(_ ss: [PadSession]) -> [PadStat] {
        guard let a = current else {
            return [PadStat(label: "Program", value: "None", sub: "workouts are one-offs"),
                    PadStat(label: "Planned ahead", value: "\(ss.filter { $0.isPlanned }.count)", unit: "sessions", sub: "not from a program")]
        }
        let block = inBlock(a, ss)
        let past = block.filter { $0.day < cal.startOfDay(for: Date()) || $0.isDone }
        let done = past.filter { $0.isDone }.count
        let pct = past.isEmpty ? 100 : Int((Double(done) / Double(past.count) * 100).rounded())
        let moved = block.filter { $0.movedFrom != nil }.count
        let left = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: a.endDate).day ?? 0
        var endsSub: String = left <= 14 ? "nothing after it" : "\(left) days left"
        if let n = nextBlock { endsSub = "then " + n.programName }
        return [
            PadStat(label: a.programName, value: "Wk \(a.currentWeek)", unit: "of \(a.totalWeeks)", sub: "\(a.sessionsDone) of \(a.sessionsTotal) sessions"),
            PadStat(label: "Done so far", value: "\(pct)", unit: "%", sub: "\(done) of \(past.count) due", warn: pct < 70),
            PadStat(label: "Moved", value: "\(moved)", unit: moved == 1 ? "session" : "sessions", sub: "this block"),
            PadStat(label: "Ends", value: PadDay.short(a.endDate), sub: endsSub, warn: nextBlock == nil && left <= 14)
        ]
    }

    private func notices(_ ss: [PadSession]) -> [PadInsights.Notice] {
        guard let a = current else { return [] }
        var out: [PadInsights.Notice] = []
        if nextBlock == nil, facts.endingSoon {
            out.append(.init(icon: "calendar.badge.exclamationmark", tint: Pad.orange,
                             text: "\(a.programName) ends \(PadDay.short(a.endDate)) with nothing after it.", aside: "Plan the next block now so they don't stall."))
        }
        let moved = inBlock(a, ss).compactMap { $0.movedFrom }
        if moved.count >= 2 {
            let byDay = Dictionary(grouping: moved, by: { cal.component(.weekday, from: $0) })
            if let top = byDay.max(by: { $0.value.count < $1.value.count }), Double(top.value.count) / Double(moved.count) >= 0.5 {
                out.append(.init(icon: "arrow.left.arrow.right", tint: Pad.mute,
                                 text: "\(cal.weekdaySymbols[top.key - 1])s get moved most (\(top.value.count) of \(moved.count) moves).", aside: "Another day may suit their week better."))
            }
        }
        let recent = changes.filter { $0.undoneAt == nil && $0.createdAt >= (cal.date(byAdding: .day, value: -14, to: Date()) ?? Date()) }
        if !recent.isEmpty {
            out.append(.init(icon: "arrow.up.forward", tint: Pad.voltText, text: "\(recent.count.plural("automatic increase")) in the last 2 weeks.",
                             aside: recent.first.map { "Latest: \($0.exerciseName), \($0.summary)." } ?? ""))
        }
        return out
    }

    // MARK: Timeline of weeks

    private func weekStart(_ a: APIAssignment, _ i: Int) -> Date {
        cal.date(byAdding: .weekOfYear, value: i, to: cal.startOfWeek(for: a.startDate)) ?? a.startDate
    }

    private func blockLabels() -> [Int: (String, Bool)] {
        guard let doc = detail?.doc else { return [:] }
        var out: [Int: (String, Bool)] = [:]
        var w = 0
        for b in doc.blocks {
            for k in 0..<b.weeks {
                out[w] = (k == 0 ? b.name : "", (b.deloadLast ?? false) && k == b.weeks - 1)
                w += 1
            }
        }
        return out
    }

    private func timeline(_ a: APIAssignment, ss: [PadSession]) -> some View {
        let labels = blockLabels()
        return PadPane(title: "The block", aside: "\(PadDay.short(a.startDate)) to \(PadDay.short(a.endDate))") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(0..<max(a.totalWeeks, 1), id: \.self) { i in
                        weekColumn(a, i, ss: ss, label: labels[i])
                    }
                    nextColumn(a)
                }
            }
        }
    }

    private func weekColumn(_ a: APIAssignment, _ i: Int, ss: [PadSession], label: (String, Bool)?) -> some View {
        let s = weekStart(a, i)
        let e = cal.date(byAdding: .day, value: 7, to: s) ?? s
        let week = ss.filter { $0.day >= s && $0.day < e }
        let done = week.filter { $0.isDone }.count
        let missed = week.filter { $0.isMissed }.count
        let isNow = i + 1 == a.currentWeek
        var summary: String = "—"
        if !week.isEmpty {
            summary = "\(done)/\(week.count)"
            if missed > 0 { summary += " · \(missed) missed" }
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(label?.0 ?? " ").font(PadFont.cond(11)).foregroundColor(Pad.voltText).lineLimit(1)
            Text("Wk \(i + 1)").font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
            Text(PadDay.short(s)).font(PadFont.cond(11)).foregroundColor(Pad.faint)
            HStack(spacing: 2) {
                ForEach(week.sorted { $0.day < $1.day }) { x in
                    RoundedRectangle(cornerRadius: 2).fill(x.isDone ? Pad.volt : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(x.isMissed ? Pad.orange : (x.isDone ? Color.clear : Pad.line2), lineWidth: 1))
                        .frame(height: 8)
                }
            }
            .frame(height: 8)
            Text(summary).font(PadFont.cond(11))
                .foregroundColor(missed > 0 ? Pad.orange : Pad.mute).lineLimit(1)
            if label?.1 == true { PadTag(text: "Deload", kind: .line) }
        }
        .padding(10)
        .frame(width: 104, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isNow ? Pad.raised : Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isNow ? Pad.volt : Color.clear, lineWidth: 1.5))
    }

    @ViewBuilder
    private func nextColumn(_ a: APIAssignment) -> some View {
        if let n = nextBlock {
            VStack(alignment: .leading, spacing: 5) {
                Text("Next").font(PadFont.cond(11)).foregroundColor(Pad.faint)
                Text(n.programName).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text).lineLimit(2)
                Text("from \(PadDay.short(n.startDate))").font(PadFont.cond(11)).foregroundColor(Pad.mute)
            }
            .padding(10).frame(width: 140, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        } else {
            Menu {
                ForEach(programs) { p in Button("\(p.name) · \(p.weeks) wks") { assignFor = p } }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("After \(PadDay.short(a.endDate))").font(PadFont.cond(11)).foregroundColor(Pad.orange)
                    Text("Nothing planned").font(PadFont.ui(14, .bold)).foregroundColor(Pad.orange)
                    Text("Tap to assign the next block").font(PadFont.cond(11)).foregroundColor(Pad.mute)
                }
                .padding(10).frame(width: 150, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Pad.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
            }
        }
    }

    // MARK: Day grid

    private func dayGrid(_ a: APIAssignment, ss: [PadSession]) -> some View {
        PadPane(title: "Week by week", aside: "tap a session to open it in Workouts") {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("").frame(width: 50)
                    ForEach(0..<7, id: \.self) { i in
                        Text(Calendar.trainingWeekdayLetters[i]).font(PadFont.cond(11)).foregroundColor(Pad.faint).frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<max(a.totalWeeks, 1), id: \.self) { i in
                    let s = weekStart(a, i)
                    HStack(spacing: 4) {
                        Text("Wk \(i + 1)").font(PadFont.cond(12)).foregroundColor(i + 1 == a.currentWeek ? Pad.text : Pad.faint).frame(width: 50, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: d, to: s) ?? s
                            gridCell(ss.filter { cal.isDate($0.day, inSameDayAs: day) })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(_ mine: [PadSession]) -> some View {
        if let x = mine.first {
            let state: String = x.isDone ? "done" : (x.isMissed ? "missed" : "planned")
            let a11y: String = x.title + ", " + PadDay.weekdayShort(x.day) + ", " + state + (x.movedFrom != nil ? ", moved" : "")
            Button { PadNav.shared.workoutId = x.id; PadNav.shared.clientSection = .workouts; PadNav.shared.clientId = facts.id } label: {
                Text(x.title).font(PadFont.cond(11)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundColor(x.isDone ? Pad.onVolt : (x.isMissed ? Pad.orange : Pad.text))
                    .padding(3)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 6).fill(x.isDone ? Pad.volt : Pad.well))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(x.isMissed ? Pad.orange : (x.movedFrom != nil ? Pad.blue : Color.clear), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a11y)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Pad.raised.opacity(0.35)).frame(maxWidth: .infinity, minHeight: 40).accessibilityHidden(true)
        }
    }

    // MARK: Side panes

    private var progressionsPane: some View {
        PadPane(title: "Automatic progressions", aside: "6 weeks") {
            if changes.isEmpty { PadEmptyLine(text: "None yet.") }
            ForEach(changes.prefix(8)) { c in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.exerciseName).font(PadFont.ui(13, .semibold)).foregroundColor(c.undoneAt == nil ? Pad.text : Pad.faint)
                        Text("\(c.summary) · \(PadDay.short(c.createdAt))").font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if c.undoneAt == nil {
                        Button("Undo") {
                            Task {
                                _ = try? await APIClient.shared.undoProgressionChange(c.id)
                                await load(); await data.refresh(roster: store.roster)
                            }
                        }
                        .font(PadFont.ui(12, .semibold)).foregroundColor(Pad.mute)
                    } else { PadLab("undone", color: Pad.faint, size: 11) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func movesPane(_ a: APIAssignment, ss: [PadSession]) -> some View {
        let moved = inBlock(a, ss).filter { $0.movedFrom != nil }.sorted { $0.day > $1.day }
        return PadPane(title: "Moved sessions", aside: "this block") {
            if moved.isEmpty { PadEmptyLine(text: "Nothing moved.") }
            ForEach(moved.prefix(8)) { s in
                HStack {
                    Text(s.title).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Spacer()
                    Text("\(s.movedFrom!.formatted(.dateTime.weekday(.abbreviated).day())) → \(s.day.formatted(.dateTime.weekday(.abbreviated).day()))")
                        .font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// The client's Stats, limited to one block.
    private func openStats(_ a: APIAssignment) { PadStrength.open(facts.id, block: a, go: goSection) }

    private var noProgram: some View {
        let past = mine.filter { $0.endDate < Date() || $0.status.lowercased() == "ended" }.sorted { $0.endDate > $1.endDate }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PadPane(title: "No program") {
                    Text("\(facts.first)'s workouts are one-offs. A program plans the weeks ahead, progresses weights on its own, and shows here as a timeline.")
                        .font(PadFont.ui(14)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                }
                if !past.isEmpty {
                    PadPane(title: "Past programs") {
                        ForEach(past) { p in
                            Button { openStats(p) } label: {
                                HStack {
                                    Text(p.programName).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                                    Spacer()
                                    PadLab("\(PadDay.short(p.startDate)) to \(PadDay.short(p.endDate)) · \(p.sessionsDone) of \(p.sessionsTotal)")
                                    Image(systemName: "chart.xyaxis.line").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.faint)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .accessibilityHint("Opens the stats for this block")
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
