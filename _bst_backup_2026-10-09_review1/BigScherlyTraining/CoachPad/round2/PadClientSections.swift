import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's sections, built for the iPad (review 1, Oct 9, 2026)
//
// Workouts: the list (next, missed, logged) and the session set by set against what was prescribed,
// with bar speed and what's worth noticing. Check-ins: 12 weeks at a glance, trends under every
// number, flagged answers first, and that week's workouts pinned beside it. Macros: targets by day,
// and new ones from here. Stats: the coach notes on top of the existing progress view until the
// iPhone Stats screens are brought over.
// Synchronized folder: no target step needed.

// MARK: - Workouts

struct PadClientWorkouts: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @State private var selectedId: String?
    @State private var showAll = false
    @State private var compare = false
    @State private var opened: Workout?

    private var cal: Calendar { Calendar.training }
    private var sessions: [PadSession] { data.sessions(client: facts.client) }

    var body: some View {
        let ss = sessions
        let today = cal.startOfDay(for: Date())
        let since = showAll ? Date.distantPast : (cal.date(byAdding: .weekOfYear, value: -8, to: today) ?? today)
        let next = ss.filter { $0.isPlanned || $0.isLive }.sorted { $0.day < $1.day }.prefix(2)
        let missed = ss.filter { $0.isMissed && $0.day >= since }.sorted { $0.day > $1.day }
        let logged = ss.filter { $0.isDone && $0.day >= since }.sorted { ($0.finish ?? $0.day) > ($1.finish ?? $1.day) }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Workouts").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                    Spacer()
                    PadSeg(options: [(id: false, label: "8 weeks"), (id: true, label: "All")], selection: $showAll)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !next.isEmpty { group("Next"); ForEach(Array(next)) { row($0) } }
                        if !missed.isEmpty { group(facts.missedStreak >= 2 ? "Missed · \(facts.missedStreak) in a row" : "Missed"); ForEach(missed) { row($0) } }
                        if !logged.isEmpty { group("Logged"); ForEach(logged) { row($0) } }
                        if ss.isEmpty { Text("No workouts yet.").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(14) }
                    }
                    .padding(.bottom, 20)
                }
            }
            .frame(width: 300)
            Rectangle().fill(Pad.line).frame(width: 1)
            if let s = ss.first(where: { $0.id == selectedId }) {
                PadWorkoutDetail(facts: facts, session: s, compare: $compare, onOpen: { opened = $0 }).id(s.id)
            } else {
                Text("Pick a workout.").font(PadFont.ui(15)).foregroundColor(Pad.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedId == nil { selectedId = logged.first?.id ?? next.first?.id ?? missed.first?.id }
        }
        .sheet(item: $opened) { w in
            let s = ss.first { $0.id == w.id }
            NavigationStack {
                TrainerWorkoutDetailView(workout: w, clientId: facts.id, clientName: facts.name, programLabel: s?.programLabel) {
                    Task { await data.refresh(roster: store.roster) }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { opened = nil }.foregroundColor(Brand.voltText) } }
            }
            .tint(Brand.volt)
        }
    }

    private func group(_ t: String) -> some View {
        PadLab(t, color: Pad.faint, size: 12).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
    }

    private func row(_ s: PadSession) -> some View {
        let on = s.id == selectedId
        var sub = s.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if cal.isDateInToday(s.day) { sub = "Today" } else if cal.isDateInTomorrow(s.day) { sub = "Tomorrow" }
        if s.isDone {
            if let a = s.start, let b = s.finish, b > a { sub += " · \(Int(b.timeIntervalSince(a) / 60)) min" }
            if let r = s.avgRPE { sub += " · RPE \(r.rpeText)" }
        } else if s.isPlanned { sub += " · planned · \(s.exerciseCount.plural("exercise"))" }
        let hasPR = s.isDone && data.prsThisWeek(clientId: facts.id).contains { cal.isDate($0.date, inSameDayAs: s.finish ?? s.day) }
        return Button { selectedId = s.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(s.title).font(PadFont.ui(14, .semibold)).foregroundColor(s.isMissed ? Pad.mute : Pad.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if s.isLive { PadTag(text: "Live", kind: .volt) }
                    else if s.isMissed { PadTag(text: "Missed", kind: .warn) }
                    else if hasPR { PadTag(text: "PR", kind: .volt) }
                    else if s.isDone { PadTag(text: "\(s.setsLogged)/\(s.setsTotal)") }
                    else { PadTag(text: s.day.formatted(.dateTime.weekday(.abbreviated)), kind: .line) }
                }
                Text(sub).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.surface : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One session, set by set.
struct PadWorkoutDetail: View {
    let facts: PadClientFacts
    let session: PadSession
    @Binding var compare: Bool
    let onOpen: (Workout) -> Void
    @ObservedObject private var data = PadData.shared

    private var cal: Calendar { Calendar.training }
    private var api: APIWorkout? { data.apiWorkouts[facts.id]?.first { $0.id == session.id } }
    /// The last time they did this same workout, for "Compare".
    private var previous: APIWorkout? {
        (data.apiWorkouts[facts.id] ?? []).filter { $0.title == session.title && $0.id != session.id && $0.scheduledDate < session.day && $0.exercises.contains { $0.sets.contains { $0.loggedReps != nil } } }
            .max { $0.scheduledDate < $1.scheduledDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                let ns = notices
                if !ns.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(ns.enumerated()), id: \.element.id) { i, n in
                            if i > 0 { PadRule() }
                            PadNoticeRow(notice: n).padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
                }
                if let w = api {
                    let model = w.toModel()
                    let exs = w.exercises.sorted { $0.sortOrder < $1.sortOrder }
                    ForEach(exs, id: \.id) { ex in
                        if let m = model.exercises.first(where: { $0.id == ex.id }) { exerciseCard(ex, m) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(PadFont.display(32)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                Text(line).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let p = previous {
                Button(compare ? "Hide \(p.scheduledDate.formatted(.dateTime.month(.abbreviated).day()))" : "Compare with \(p.scheduledDate.formatted(.dateTime.month(.abbreviated).day()))") { compare.toggle() }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            if let w = api {
                Button(session.isDone ? "Open · comment" : "Open · edit") { onOpen(w.toModel()) }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
        }
    }

    private var line: String {
        var bits = [session.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
        if let a = session.start, let b = session.finish, b > a {
            var t = "\(a.padClock) to \(b.padClock) · \(Int(b.timeIntervalSince(a) / 60)) min"
            if let u = usualMinutes { t += ", usually \(u)" }
            bits.append(t)
        }
        if session.setsTotal > 0 { bits.append("\(session.setsLogged) of \(session.setsTotal) sets") }
        if let r = session.avgRPE { bits.append("average RPE \(r.rpeText)") }
        if let p = session.programLabel { bits.append(p) }
        if session.isMissed { bits.append("not logged") }
        return bits.joined(separator: " · ")
    }

    private var usualMinutes: Int? {
        let mins = data.sessions(client: facts.client).filter { $0.isDone && $0.id != session.id }.compactMap { s -> Double? in
            guard let a = s.start, let b = s.finish, b > a else { return nil }
            return b.timeIntervalSince(a) / 60
        }.sorted()
        guard mins.count >= 3 else { return nil }
        return Int(mins[mins.count / 2])
    }

    private var notices: [PadInsights.Notice] {
        var out: [PadInsights.Notice] = []
        let ms = (data.motion[facts.id] ?? []).filter { $0.workoutId == session.id && !$0.reps.isEmpty }
        for lift in Set(ms.map { $0.exerciseName }).sorted() {
            let sets = ms.filter { $0.exerciseName == lift }.sorted { $0.start < $1.start }
            guard sets.count >= 3, let a = sets.first?.meanVelocity, let b = sets.last?.meanVelocity, a > 0 else { continue }
            let drop = (a - b) / a
            if drop >= 0.15 {
                out.append(.init(icon: "speedometer", tint: Pad.orange,
                                 text: "\(lift) bar speed fell from \(String(format: "%.2f", a)) to \(String(format: "%.2f", b)) m/s across the sets.",
                                 aside: sets.contains { $0.grindRepCount > 0 } ? "There was a grind." : ""))
            } else {
                out.append(.init(icon: "speedometer", tint: Pad.mute,
                                 text: "\(lift) bar speed held near \(String(format: "%.2f", (a + b) / 2)) m/s.", aside: "No real slowdown."))
            }
        }
        if session.setsLogged > 0, session.setsTotal > session.setsLogged, !session.isLive {
            let skipped = session.setsTotal - session.setsLogged
            var t = "\(skipped.plural("set")) not logged."
            if let a = session.start, let b = session.finish, let u = usualMinutes, u - Int(b.timeIntervalSince(a) / 60) >= 15 {
                t = "\(skipped.plural("set")) skipped and finished \(u - Int(b.timeIntervalSince(a) / 60)) minutes early."
            }
            let after = data.sessions(client: facts.client).filter { $0.day > session.day && $0.day < Date() }
            let aside = after.isEmpty || after.allSatisfy({ $0.isMissed }) ? "This was the last session before the gap." : ""
            out.append(.init(icon: "list.bullet", tint: Pad.mute, text: t, aside: facts.missedStreak >= 2 ? aside : ""))
        }
        let prs = ProgressEngine.allPRs(workouts: data.workouts[facts.id] ?? []).filter { cal.isDate($0.date, inSameDayAs: session.day) && !$0.isFirstEver }
        for p in prs.prefix(2) {
            out.append(.init(icon: "trophy", tint: Pad.voltText,
                             text: "\(p.exercise) PR: \(p.reps) × \(StatsUnits.weightText(p.weight)), \(StatsUnits.weightText(p.estimatedOneRepMax)) e1RM.",
                             aside: p.previousBest > 0 ? "Up \(StatsUnits.weightText(p.gain))." : ""))
        }
        return out
    }

    private func exerciseCard(_ ex: APIExercise, _ model: Exercise) -> some View {
        let sets = ex.sets.sorted { $0.setOrder < $1.setOrder }
        let modelSets = model.setsOrdered(like: sets)
        let logged = sets.filter { $0.loggedReps != nil }.count
        let past = session.day < cal.startOfDay(for: Date()) || session.isDone
        let prevEx = compare ? previous?.exercises.first { $0.name == ex.name } : nil
        let prevSets = prevEx?.sets.sorted { $0.setOrder < $1.setOrder } ?? []
        let hasSpeed = sets.contains { data.velocity(clientId: facts.id, setId: $0.id) != nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(ex.name).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("\(sets.count.plural("set")) · \(logged == sets.count ? "all logged" : "\(logged) of \(sets.count) logged")",
                       color: past && logged < sets.count ? Pad.orange : Pad.mute)
            }
            .padding(.vertical, 10)
            if !ex.clientNotes.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("“\(ex.clientNotes)”").font(PadFont.ui(13)).foregroundColor(Pad.mute).padding(.bottom, 8)
            }
            HStack(spacing: 8) {
                th("Set", 44); th("Prescribed", nil); th("Logged", nil)
                if compare { th("Last time", nil) }
                th("RPE", 50, trailing: true); th(hasSpeed ? "Bar speed" : "", 170)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line2).frame(height: 1) }
            ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                let v = data.velocity(clientId: facts.id, setId: s.id)
                let first = sets.compactMap { data.velocity(clientId: facts.id, setId: $0.id) }.first
                let slow = v.flatMap { vv in first.map { vv < $0 * 0.85 } } ?? false
                HStack(spacing: 8) {
                    Text("\(i + 1)").foregroundColor(Pad.mute).frame(width: 44, alignment: .leading)
                    Text(i < modelSets.count ? SetTarget.text(modelSets[i], in: model) : "").foregroundColor(Pad.mute).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    loggedText(s, past: past).frame(maxWidth: .infinity, alignment: .leading)
                    if compare {
                        Text(i < prevSets.count ? setText(prevSets[i]) : "—").foregroundColor(Pad.mute).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(s.rpe.map { $0.rpeText } ?? "—").foregroundColor(s.rpe == nil ? Pad.faint : Pad.text).frame(width: 50, alignment: .trailing)
                    HStack(spacing: 8) {
                        if let v {
                            RoundedRectangle(cornerRadius: 3).fill(slow ? Pad.orange : Pad.text)
                                .frame(width: max(8, min(120, CGFloat(v) * 200)), height: 6)
                            Text(String(format: "%.2f", v)).monospacedDigit()
                        }
                    }
                    .frame(width: 170, alignment: .leading)
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

    private func th(_ t: String, _ w: CGFloat?, trailing: Bool = false) -> some View {
        Group {
            if let w { Text(t).frame(width: w, alignment: trailing ? .trailing : .leading) }
            else { Text(t).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(PadFont.cond(12)).foregroundColor(Pad.faint)
    }

    private func setText(_ s: APISet) -> String {
        guard let r = s.loggedReps else { return "—" }
        let w = s.loggedWeight ?? 0
        return w > 0 ? "\(StatsUnits.weightText(w, unit: false)) × \(r)" : "\(r) reps"
    }

    @ViewBuilder
    private func loggedText(_ s: APISet, past: Bool) -> some View {
        if s.loggedReps != nil {
            let short = s.loggedReps! < s.targetReps && s.amrap != true
            Text(setText(s)).foregroundColor(short ? Pad.orange : Pad.text)
        } else if past {
            Text("Skipped").foregroundColor(Pad.orange)
        } else {
            Text("—").foregroundColor(Pad.faint)
        }
    }
}

private extension Exercise {
    /// The model's sets in the same order as the API's (they share ids).
    func setsOrdered(like api: [APISet]) -> [ExerciseSet] {
        api.compactMap { a in sets.first { $0.id == a.id } }
    }
}

// MARK: - Check-ins

struct PadClientCheckIns: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var data = PadData.shared
    @Environment(\.padGo) private var goSection
    @AppStorage("bst_pad_pin_workouts") private var pinned = true
    @State private var selectedId: String?
    @State private var photos: [APIPhoto] = []
    @State private var reply = ""
    @State private var sending = false
    @State private var failed = false

    private var cal: Calendar { Calendar.training }
    private var history: [APICheckIn] { (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date > $1.date } }

    var body: some View {
        let hs = history
        GeometryReader { g in
            HStack(spacing: 0) {
                list(hs).frame(width: 248)
                Rectangle().fill(Pad.line).frame(width: 1)
                if let ci = hs.first(where: { $0.id == selectedId }) ?? hs.first {
                    content(ci, all: hs).id(ci.id)
                    if pinned && g.size.width >= 1000 {
                        Rectangle().fill(Pad.line).frame(width: 1)
                        PadPinnedWorkouts(facts: facts, checkIn: ci, onClose: { withAnimation { pinned = false } })
                            .frame(width: 372)
                            .background(Pad.page)
                            .transition(.move(edge: .trailing))
                    }
                } else {
                    Text("No check-ins yet.").font(PadFont.ui(15)).foregroundColor(Pad.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await coach.loadCheckIns(facts.id)
            await data.loadContext(facts.id)
            photos = (try? await APIClient.shared.trainerPhotos(clientId: facts.id)) ?? []
        }
    }

    // MARK: List

    private func list(_ hs: [APICheckIn]) -> some View {
        let sent: Int = facts.checkInWeeks.filter { $0.isSent }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Check-ins").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("\(sent) of 12 weeks", size: 12)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 3) {
                ForEach(Array(facts.checkInWeeks.enumerated()), id: \.offset) { _, m in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(m.fill)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(m.stroke, lineWidth: 1.5))
                        .frame(height: 16)
                }
            }
            .padding(.horizontal, 14)
            .accessibilityLabel("Last 12 weeks: \(sent) check-ins sent")
            PadLab("12 weeks · volt sent · orange none", color: Pad.faint, size: 12).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(hs, id: \.id) { ci in row(ci, first: hs.first?.id) } }
            }
        }
    }

    private func weekLabel(_ ci: APICheckIn) -> String {
        if let a = data.assignments.first(where: { $0.clientId == facts.id && ci.date >= $0.startDate && ci.date <= $0.endDate.addingTimeInterval(86_400) }) {
            let w = (cal.dateComponents([.day], from: cal.startOfDay(for: a.startDate), to: ci.date).day ?? 0) / 7 + 1
            return "Week \(w)"
        }
        return ci.date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func row(_ ci: APICheckIn, first: String?) -> some View {
        let on = ci.id == (selectedId ?? first)
        let waiting = facts.waiting?.id == ci.id
        var sub = ci.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if let f = PadCheckInReview.flaggedLine(ci) {
            let w = PadCheckInReview.flagWords.first { f.lowercased().contains($0) } ?? "flag"
            sub += " · \(w) flagged"
        } else if let bw = PadInsights.bodyweight(ci) {
            sub += " · \(StatsUnits.weightText(bw))"
        }
        return Button { selectedId = ci.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(weekLabel(ci)).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    Spacer(minLength: 4)
                    if waiting { PadTag(text: "Waiting \(ci.date.padShortAgo)", kind: .volt) }
                    else if !(ci.trainerResponse ?? "").isEmpty { PadTag(text: "Replied", kind: .line) }
                }
                Text(sub).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Pad.surface : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: Content

    private func content(_ ci: APICheckIn, all: [APICheckIn]) -> some View {
        let older = all.filter { $0.date < ci.date }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title(ci)).font(PadFont.display(26)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                        PadLab("sent \(ci.date.formatted(.dateTime.weekday(.abbreviated))) \(ci.date.padClock)")
                        Spacer()
                        Button("Full review") { PadNav.shared.checkInId = ci.id; goSection(.checkins) }
                            .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                    }
                    metrics(ci, older: older)
                    answers(ci, older: older)
                    photoRow(ci)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            composer(ci)
        }
    }

    private func title(_ ci: APICheckIn) -> String {
        if let a = data.assignments.first(where: { $0.clientId == facts.id && ci.date >= $0.startDate && ci.date <= $0.endDate.addingTimeInterval(86_400) }) {
            return "\(weekLabel(ci)) of \(a.programName)"
        }
        return "Check-in, \(ci.date.formatted(.dateTime.month(.wide).day()))"
    }

    private struct Met: Identifiable { let id: String; let label: String; let now: Double; let prev: Double?; let series: [Double]; let unit: String; let better: Bool? }

    private func metrics(_ ci: APICheckIn, older: [APICheckIn]) -> some View {
        let chron = ([ci] + older).sorted { $0.date < $1.date }.suffix(8)
        let ms: [Met] = ci.fields.sorted { $0.fieldOrder < $1.fieldOrder }.compactMap { f in
            guard let v = Double(f.value) else { return nil }
            let isW = f.cleanLabel.lowercased().contains("weight")
            let q = CheckInSchema.questions.first { $0.label == f.cleanLabel }
            let conv: (Double) -> Double = { isW ? StatsUnits.weight($0) : $0 }
            let series = chron.compactMap { c in c.fields.first { $0.cleanLabel == f.cleanLabel }.flatMap { Double($0.value) }.map(conv) }
            let prev = older.first.flatMap { o in o.fields.first { $0.cleanLabel == f.cleanLabel } }.flatMap { Double($0.value) }.map(conv)
            return Met(id: f.id, label: f.cleanLabel.components(separatedBy: " / ").first ?? f.cleanLabel, now: conv(v), prev: prev, series: series,
                       unit: isW ? StatsUnits.weightLabel : "", better: isW ? nil : (q?.higherIsBetter ?? true))
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(ms) { m in
                let d: Double? = m.prev.map { m.now - $0 }
                let dText: String = deltaText(d)
                let better: Bool? = deltaBetter(d, m.better)
                VStack(alignment: .leading, spacing: 2) {
                    PadLab(m.label, size: 12).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        PadNumber(value: fmt(m.now), unit: m.unit.isEmpty ? nil : m.unit, size: 24)
                        if d != nil { PadDelta(text: dText, better: better) }
                    }
                    PadMiniLine(points: m.series, worse: better == false)
                        .frame(height: 22).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
            }
        }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }
    private func deltaText(_ d: Double?) -> String {
        guard let d else { return "" }
        if d == 0 { return "same" }
        return (d > 0 ? "+" : "−") + fmt(abs(d))
    }
    private func deltaBetter(_ d: Double?, _ higherIsBetter: Bool?) -> Bool? {
        guard let d, d != 0, let h = higherIsBetter else { return nil }
        return (d > 0) == h
    }

    private func answers(_ ci: APICheckIn, older: [APICheckIn]) -> some View {
        let words = ci.fields.sorted { $0.fieldOrder < $1.fieldOrder }.filter { Double($0.value) == nil && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let ordered = words.filter { PadCheckInReview.isFlagged($0) } + words.filter { !PadCheckInReview.isFlagged($0) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ordered, id: \.id) { f in
                let flagged = PadCheckInReview.isFlagged(f)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        if flagged { PadTag(text: "Flagged", kind: .warn) }
                        Text(f.cleanLabel).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                    }
                    .frame(width: 136, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(f.value).font(PadFont.ui(14)).foregroundColor(Pad.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        if flagged { flagLinks(f, older: older) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11).padding(.horizontal, flagged ? 12 : 0)
                .background(RoundedRectangle(cornerRadius: 10).fill(flagged ? Pad.orange.opacity(0.07) : Color.clear))
                .overlay(alignment: .top) { if !flagged { PadRule() } }
            }
        }
    }

    private func flagLinks(_ f: APICheckInField, older: [APICheckIn]) -> some View {
        let words = PadCheckInReview.flagWords.filter { f.value.lowercased().contains($0) }
        let earlier = older.first { o in o.fields.contains { g in Double(g.value) == nil && words.contains { g.value.lowercased().contains($0) } } }
        return HStack(spacing: 8) {
            Button { withAnimation { pinned.toggle() } } label: {
                Label(pinned ? "Pinned: that week’s workouts" : "Pin that week’s workouts", systemImage: "pin")
                    .font(PadFont.ui(13, .semibold)).foregroundColor(pinned ? Pad.onVolt : Pad.text)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pinned ? Pad.volt : Pad.raised))
            }
            .buttonStyle(.plain)
            if let e = earlier {
                Button { selectedId = e.id } label: {
                    Text("Similar, \(e.date.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Pad.raised))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func photoRow(_ ci: APICheckIn) -> some View {
        let mine = photos.filter { ci.photoIds.contains($0.id) || cal.isDate($0.date, inSameDayAs: ci.date) }
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Photos").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                HStack(spacing: 8) {
                    ForEach(mine, id: \.id) { p in
                        PhotoFill(photo: p.toModel(), url: APIClient.shared.trainerPhotoURL(photoId: p.id))
                            .frame(height: 140).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .bottomLeading) { Text(p.category).font(PadFont.cond(12, .bold)).foregroundColor(.white).padding(8) }
                            .accessibilityLabel("\(p.category) photo")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func composer(_ ci: APICheckIn) -> some View {
        let answered = !(ci.trainerResponse ?? "").isEmpty
        VStack(spacing: 0) {
            PadRule()
            if answered {
                HStack(alignment: .top, spacing: 10) {
                    PadLab("Your reply")
                    Text(ci.trainerResponse ?? "").font(PadFont.ui(14)).foregroundColor(Pad.text).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                HStack(spacing: 8) {
                    TextField("Reply to \(facts.first)…", text: $reply, axis: .vertical)
                        .lineLimit(1...5).padInput(multiline: true)
                    Button {
                        send(ci)
                    } label: {
                        HStack(spacing: 6) { if sending { ProgressView().tint(Pad.onVolt) }; Text("Reply") }
                    }
                    .buttonStyle(PadButtonStyle(kind: .primary))
                    .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                if failed { Text("Couldn’t send. Check your connection and try again.").font(PadFont.ui(13)).foregroundColor(Pad.orange).padding(.bottom, 8) }
            }
        }
        .background(Pad.page)
    }

    private func send(_ ci: APICheckIn) {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true; failed = false
        Task {
            do {
                try await APIClient.shared.trainerRespondCheckIn(checkInId: ci.id, response: t)
                await coach.loadCheckIns(facts.id, force: true)
                await MainActor.run {
                    sending = false; reply = ""
                    store.loadRoster()
                    PadToasts.shared.show("Replied to \(facts.first)")
                }
            } catch {
                await MainActor.run { sending = false; failed = true }
            }
        }
    }
}

/// A small trend line; orange when the latest move is the wrong way.
struct PadMiniLine: View {
    let points: [Double]
    var worse = false
    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2 else { return }
            let mn = points.min() ?? 0, mx = points.max() ?? 1
            let rng = max(mx - mn, 0.5)
            var p = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(points.count - 1),
                                 y: 2 + (size.height - 4) * (1 - CGFloat((v - mn) / rng)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(worse ? Pad.orange : Pad.text), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// That week's workouts, beside a check-in.
struct PadPinnedWorkouts: View {
    static func speedLine(now: Double, before: Double) -> String {
        let n = String(format: "%.2f", now), b = String(format: "%.2f", before)
        if now >= before * 0.95 { return "The last set held its speed (\(n) m/s vs \(b) before). Not a grind." }
        return "The last set slowed to \(n) m/s, from \(b) before."
    }

    let facts: PadClientFacts
    let checkIn: APICheckIn
    let onClose: () -> Void
    @ObservedObject private var data = PadData.shared

    private var cal: Calendar { Calendar.training }
    private var weekSessions: [PadSession] {
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: checkIn.date)) ?? checkIn.date
        let start = cal.date(byAdding: .day, value: -7, to: end) ?? end
        return data.sessions(client: facts.client).filter { $0.day >= start && $0.day < end }.sorted { $0.day > $1.day }
    }

    var body: some View {
        let ss = weekSessions
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.voltText)
                Text("Workouts · that week").font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadIconButton(systemName: "xmark", label: "Unpin", small: true, action: onClose)
            }
            .padding(.horizontal, 14).frame(height: 52)
            .overlay(alignment: .bottom) { PadRule() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ss.isEmpty {
                        Text("No workouts in the 7 days before this check-in.").font(PadFont.ui(13)).foregroundColor(Pad.mute)
                    }
                    ForEach(ss) { s in
                        dayCard(s)
                        if s.id == mainSession(ss)?.id { mainLift(s) }
                    }
                    PadLab("Pinned beside every check-in until you unpin it.", color: Pad.faint, size: 12)
                }
                .padding(14)
            }
        }
    }

    private func mainSession(_ ss: [PadSession]) -> PadSession? { ss.first { $0.isDone } }

    private func dayCard(_ s: PadSession) -> some View {
        let hasPR = ProgressEngine.allPRs(workouts: data.workouts[facts.id] ?? []).contains { cal.isDate($0.date, inSameDayAs: s.day) && !$0.isFirstEver }
        return HStack(spacing: 10) {
            if hasPR { PadTag(text: "PR", kind: .volt) }
            else if s.isMissed { PadTag(text: "Missed", kind: .warn) }
            else if s.isDone { PadTag(text: "\(s.setsLogged)/\(s.setsTotal)", kind: .line) }
            else { PadTag(text: "Planned", kind: .line) }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                Text(daySub(s)).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
    }

    private func daySub(_ s: PadSession) -> String {
        var t = s.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if let a = s.start, let b = s.finish, b > a { t += " · \(a.padClock) to \(b.padClock)" }
        if let r = s.avgRPE { t += " · RPE \(r.rpeText)" }
        return t
    }

    /// The first exercise of the main session, set by set with bar speed, and its last-set speed over 4 weeks.
    @ViewBuilder
    private func mainLift(_ s: PadSession) -> some View {
        if let w = data.apiWorkouts[facts.id]?.first(where: { $0.id == s.id }),
           let ex = w.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }).first {
            let sets = ex.sets.sorted { $0.setOrder < $1.setOrder }.filter { $0.loggedReps != nil }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ex.name).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                    Spacer()
                    PadLab("bar speed", size: 12)
                }
                .padding(.bottom, 4)
                ForEach(Array(sets.enumerated()), id: \.element.id) { i, st in
                    let v = data.velocity(clientId: facts.id, setId: st.id)
                    HStack(spacing: 8) {
                        Text("\(i + 1)").foregroundColor(Pad.mute).frame(width: 26, alignment: .leading)
                        Text("\(StatsUnits.weightText(st.loggedWeight ?? 0, unit: false)) × \(st.loggedReps ?? 0)").frame(maxWidth: .infinity, alignment: .leading)
                        Text(st.rpe.map { $0.rpeText } ?? "—").foregroundColor(Pad.mute).frame(width: 36, alignment: .trailing)
                        Text(v.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    .font(PadFont.ui(14)).foregroundColor(Pad.text)
                    .frame(height: 34)
                    .overlay(alignment: .bottom) { PadRule() }
                }
            }
            speedTrend(ex.name, upTo: s.day)
        }
    }

    @ViewBuilder
    private func speedTrend(_ lift: String, upTo day: Date) -> some View {
        let ms = (data.motion[facts.id] ?? []).filter { $0.exerciseName == lift && !$0.reps.isEmpty && $0.start <= day.addingTimeInterval(86_400) }
        let byW = Dictionary(grouping: ms, by: { $0.workoutId }).values
            .compactMap { sets -> (Date, Double)? in
                guard let last = sets.max(by: { $0.start < $1.start }) else { return nil }
                return (last.start, last.meanVelocity)
            }
            .sorted { $0.0 < $1.0 }
            .suffix(4)
        let pts = Array(byW)
        if pts.count >= 2 {
            let now = pts.last!.1
            let before = pts.dropLast().map { $0.1 }
            let avg = before.reduce(0, +) / Double(before.count)
            VStack(alignment: .leading, spacing: 6) {
                Text("Last set’s bar speed, \(pts.count) sessions").font(PadFont.ui(13, .bold)).foregroundColor(Pad.text)
                PadSparkline(points: pts.map { $0.1 }, from: pts.first!.0, to: pts.last!.0).frame(height: 70)
                Text(Self.speedLine(now: now, before: avg))
                    .font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
        }
    }
}

// MARK: - Macros

struct PadClientMacros: View {
    let client: RosterItem
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @State private var days: [APIMacroDay] = []
    @State private var loading = true
    @State private var failed = false
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var saving = false

    private var cal: Calendar { Calendar.training }

    var body: some View {
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let to = cal.date(byAdding: .day, value: 14, to: today) ?? today
        let shown = days.filter { $0.date >= from && $0.date <= to }.sorted { $0.date < $1.date }
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Targets by day").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text).padding(.bottom, 10)
                    HStack(spacing: 8) {
                        hcell("Day", nil); hcell("", 80); hcell("kcal", 70); hcell("Protein", 70); hcell("Carbs", 70); hcell("Fat", 60)
                    }
                    .padding(.bottom, 6).overlay(alignment: .bottom) { Rectangle().fill(Pad.line2).frame(height: 1) }
                    if loading { PadSkeleton(height: 14).padding(.vertical, 14) }
                    if failed { Text("Couldn’t load \(client.name.firstName)’s macros.").font(PadFont.ui(14)).foregroundColor(Pad.orange).padding(.vertical, 12) }
                    if !loading && !failed && shown.isEmpty { Text("No targets set for these weeks.").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(.vertical, 12) }
                    ForEach(shown, id: \.id) { d in
                        let isToday = cal.isDateInToday(d.date)
                        HStack(spacing: 8) {
                            Text(isToday ? "Today" : d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(PadFont.ui(14, isToday ? .bold : .medium)).frame(maxWidth: .infinity, alignment: .leading)
                            Group { if d.isTrainingDay { PadTag(text: "Training", kind: .line) } else { PadTag(text: "Rest") } }.frame(width: 80, alignment: .leading)
                            Text("\(d.calorieGoal)").frame(width: 70, alignment: .leading)
                            Text("\(d.proteinGoal) g").frame(width: 70, alignment: .leading)
                            Text("\(d.carbGoal) g").frame(width: 70, alignment: .leading)
                            Text("\(d.fatGoal) g").frame(width: 60, alignment: .leading)
                        }
                        .font(PadFont.ui(14)).foregroundColor(d.date < today ? Pad.mute : Pad.text)
                        .frame(height: 40)
                        .overlay(alignment: .bottom) { PadRule() }
                    }
                }
                .padding(20)
            }
            Rectangle().fill(Pad.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                Text("New targets").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                HStack(spacing: 8) { field("Protein", $protein); field("Carbs", $carbs); field("Fat", $fat) }
                if let p = Int(protein), let c = Int(carbs), let f = Int(fat) {
                    PadLab("\(p * 4 + c * 4 + f * 9) kcal a day. Starts tomorrow, for 14 days.")
                } else {
                    PadLab("Grams a day. Calories follow (4 · 4 · 9).")
                }
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) { if saving { ProgressView().tint(Pad.onVolt) }; Text("Set for 14 days") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(saving || Int(protein) == nil || Int(carbs) == nil || Int(fat) == nil)
                Spacer()
            }
            .padding(20)
            .frame(width: 320)
            .background(Pad.page)
        }
        .task { await load() }
    }

    private func hcell(_ t: String, _ w: CGFloat?) -> some View {
        Group {
            if let w { Text(t).frame(width: w, alignment: .leading) } else { Text(t).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(PadFont.cond(12)).foregroundColor(Pad.faint)
    }

    private func field(_ label: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PadLab(label)
            TextField("g", text: b).keyboardType(.numberPad).padInput()
        }
    }

    private func load() async {
        do {
            let v = try await APIClient.shared.viewAsToken(clientId: client.id)
            let ds: [APIMacroDay] = try await APIClient.shared.get("/macros", token: v.token)
            days = ds
            if let t = ds.first(where: { cal.isDateInToday($0.date) }) ?? ds.last {
                if protein.isEmpty { protein = "\(t.proteinGoal)"; carbs = "\(t.carbGoal)"; fat = "\(t.fatGoal)" }
            }
            loading = false
        } catch {
            loading = false; failed = true
        }
    }

    private func save() {
        guard let p = Int(protein), let c = Int(carbs), let f = Int(fat) else { return }
        saving = true
        let kcal = p * 4 + c * 4 + f * 9
        let sessions = data.sessions(client: client)
        Task {
            var bad = 0
            for i in 1...14 {
                let day = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: Date())) ?? Date()
                let training = sessions.contains { cal.isDate($0.day, inSameDayAs: day) }
                do { try await APIClient.shared.trainerSetMacros(clientId: client.id, day: day, training: training, kcal: kcal, protein: p, carbs: c, fat: f) }
                catch { bad += 1 }
            }
            await load()
            await MainActor.run {
                saving = false
                if bad == 0 { PadToasts.shared.show("New macros for \(client.name.firstName) from tomorrow") }
                else { PadToasts.shared.show("Couldn’t save \(bad.plural("day")). Check your connection and try again.") }
            }
        }
    }
}

// MARK: - Stats (for now: the coach notes, then the existing progress view)

struct PadClientStats: View {
    let facts: PadClientFacts
    var body: some View {
        VStack(spacing: 0) {
            let ns = PadInsights.notices(facts)
            if !ns.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("What stands out").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).padding(.bottom, 4)
                    ForEach(Array(ns.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { PadRule() }
                        PadNoticeRow(notice: n).padding(.vertical, 9)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
                .frame(maxWidth: 820)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            }
            TrainerProgressView(clientId: facts.id)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg.ignoresSafeArea())
    }
}
