import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Library ▸ Workouts and Programs (3.1.8, Oct 10, 2026)
//
// Workouts: each saved workout's fingerprint (sets per muscle), how long it takes, how often you
// give it and to whom; give one to a client for one or more days.
// Programs: the program's shape (weeks across, days down, coloured by focus, deloads faded, sets per
// week under it), everyone who's run it (sessions done, strength, PRs), how it ranks against your
// other programs, the week people drift, and what they said in check-ins while on it.
// The Programs tab keeps who's on what this week; the Library keeps what works.
// Synchronized folder: no target step needed.

// MARK: - Program results (worked out from what PadData already has)

struct PadLibraryProgramRun: Identifiable {
    let assignment: APIAssignment
    let done: Int
    let due: Int
    let strength: Double?          // squat/bench/deadlift average change, percent
    let prs: Int
    let missedByWeek: [Int]        // index = program week - 1
    var id: String { assignment.id }
    var stalled: Bool {
        let a = assignment
        return a.status.lowercased() != "ended" && a.endDate >= Date() && due >= 4 && Double(done) / Double(max(due, 1)) < 0.6
    }
}

struct PadLibraryProgramResult {
    var runs: [PadLibraryProgramRun] = []
    var strength = 0.0
    var strengthMonths = 0.0
    var prs = 0
    var done = 0
    var due = 0
    var strengthPerMonth: Double? { strengthMonths >= 0.5 ? strength / strengthMonths : nil }
    var donePct: Int? { due > 0 ? Int((Double(done) / Double(due) * 100).rounded()) : nil }
    /// The average strength change per run, percent.
    var avgStrength: Double? {
        let s = runs.compactMap { $0.strength }
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }
    /// Finishers (90%+ of sessions) against the rest, when both exist.
    var finishersVsRest: (fin: Double, rest: Double)? {
        let fin = runs.filter { $0.due > 0 && Double($0.done) / Double($0.due) >= 0.9 }.compactMap { $0.strength }
        let rest = runs.filter { $0.due > 0 && Double($0.done) / Double($0.due) < 0.7 }.compactMap { $0.strength }
        guard !fin.isEmpty, !rest.isEmpty else { return nil }
        return (fin.reduce(0, +) / Double(fin.count), rest.reduce(0, +) / Double(rest.count))
    }
    var missedByWeek: [Int] {
        let n = runs.map { $0.missedByWeek.count }.max() ?? 0
        return (0..<n).map { i in runs.map { i < $0.missedByWeek.count ? $0.missedByWeek[i] : 0 }.reduce(0, +) }
    }
}

extension PadLibraryStore {
    /// Same sums as the Programs tab's "which programs work", kept per run so the Library can show each person.
    func computeResults(store: AppStore) {
        let data = PadData.shared
        let cal = Calendar.training
        let today = cal.startOfDay(for: Date())
        var out: [String: PadLibraryProgramResult] = [:]
        var prCache: [String: [PersonalRecord]] = [:]
        var sessionCache: [String: [StatsSession]] = [:]
        for a in data.assignments where a.startDate <= today {
            var r = out[a.programId] ?? PadLibraryProgramResult()
            let c = store.roster.first { $0.id == a.clientId } ?? RosterItem.stub(a.clientId, a.clientName)
            let start = cal.startOfDay(for: a.startDate)
            let endDay = min(cal.startOfDay(for: a.endDate), today)
            let ss = data.sessions(client: c).filter { $0.day >= start && $0.day <= endDay && $0.programLabel != nil }
            let due = ss.filter { $0.day < today || $0.isDone }.count
            let done = ss.filter { $0.isDone }.count
            var missed: [Int] = Array(repeating: 0, count: max(a.totalWeeks, 1))
            for s in ss where s.day < today && !s.isDone {
                let w = (cal.dateComponents([.day], from: start, to: s.day).day ?? 0) / 7
                if w >= 0 && w < missed.count { missed[w] += 1 }
            }
            let end = min(a.endDate, Date())
            let days = max(0, cal.dateComponents([.day], from: a.startDate, to: end).day ?? 0)
            if prCache[a.clientId] == nil { prCache[a.clientId] = ProgressEngine.allPRs(workouts: data.workouts[a.clientId] ?? []) }
            let prs = (prCache[a.clientId] ?? []).filter { $0.date >= a.startDate && $0.date <= end }.count
            if sessionCache[a.clientId] == nil {
                let src = StatsSource(workouts: data.workouts[a.clientId] ?? [], isDemo: !store.isLive, motion: { _, _ in nil }, vitals: [:])
                sessionCache[a.clientId] = StatsEngine(source: src).allSessions(window: .all)
            }
            let ids = PadStatsContext.programWorkouts(a, clientId: a.clientId)
            let block = PadBlockSummary.make(a, sessions: (sessionCache[a.clientId] ?? []).filter { ids.contains($0.id) })
            let strength: Double? = days >= 14 ? block.strength : nil
            if let pct = strength {
                r.strength += pct
                r.strengthMonths += Double(days) / 30.4
            }
            r.prs += prs
            r.done += done
            r.due += due
            r.runs.append(PadLibraryProgramRun(assignment: a, done: done, due: due, strength: strength, prs: prs, missedByWeek: missed))
            out[a.programId] = r
        }
        programResults = out
        resultsStamp = data.loadedAt
    }

    /// The program that does the most for people, when there's something to compare.
    var bestProgram: (program: APIProgramSummary, text: String)? {
        let ranked: [(APIProgramSummary, Double)] = programs.compactMap { p in programResults[p.id]?.avgStrength.map { (p, $0) } }.sorted { $0.1 > $1.1 }
        if let top = ranked.first, top.1 > 0 { return (top.0, String(format: "%+.1f%%", top.1)) }
        return nil
    }
}

// MARK: - Workouts

struct PadLibraryWorkouts: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go
    @State private var sort = "given"
    @State private var confirmDelete: LibWorkout?
    @State private var busy = false

    private var list: [LibWorkout] {
        let q = lib.exQuery
        let base = lib.workouts.filter { q.isEmpty || PadLibraryKit.matches($0.title + " " + $0.summary + " " + $0.tags.joined(separator: " "), q) }
        switch sort {
        case "name": return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "new": return base.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        default: return base.sorted { $0.given != $1.given ? $0.given > $1.given : $0.title < $1.title }
        }
    }
    private var selected: LibWorkout? {
        if let id = lib.workoutId, let w = lib.workout(id) { return w }
        return list.first
    }

    var body: some View {
        HStack(spacing: 0) {
            PadLibraryColumn(width: 470) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.mute)
                        TextField("Find a workout", text: $lib.exQuery).font(PadFont.ui(14)).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
                    PadSeg(options: [(id: "given", label: "Most given"), (id: "new", label: "Newest"), (id: "name", label: "A–Z")], selection: $sort)
                }
                .padding(12)
            } content: {
                if !lib.loaded {
                    ForEach(0..<5, id: \.self) { _ in PadSkeleton(height: 60).padding(12) }
                } else if list.isEmpty {
                    PadEmptyLine(text: lib.workouts.isEmpty ? "No saved workouts yet. Save one from any client's workout (… ▸ Save to library)." : "Nothing matches.").padding(14)
                } else {
                    ForEach(list) { w in row(w) }
                }
            }
            Rectangle().fill(Pad.line).frame(width: 1)
            Group {
                if let w = selected { inspector(w) } else {
                    PadLibraryPick(icon: "list.bullet", title: "Pick a workout", text: "See what's in it, who you give it to, and give it to someone.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")” from your library?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let w = confirmDelete { delete(w) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sessions already on clients' calendars stay as they are.") }
    }

    private func row(_ w: LibWorkout) -> some View {
        let on: Bool = selected?.id == w.id
        return Button { lib.workoutId = w.id } label: {
            HStack(alignment: .center, spacing: 12) {
                PadLibraryFingerprint(setsPerMuscle: w.setsPerMuscle).frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(w.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        ForEach(w.tags.prefix(2), id: \.self) { t in PadTag(text: "#" + t) }
                    }
                    Text("\(w.focus) · \(w.exerciseCount) exercises · \(w.setCount) sets · ~\(w.estMinutes) min").font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(w.given == 0 ? "never given" : "\(w.given)×").font(PadFont.ui(14, .bold)).foregroundColor(w.given == 0 ? Pad.faint : Pad.text)
                    Text(w.clientCount == 0 ? "" : w.clientCount.plural("client")).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
            }
            .padLibraryRow(on)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.workout(w.id).payload) { PadLibraryDragPreview(icon: "list.bullet", title: w.title, sub: "\(w.exerciseCount) exercises") }
    }

    private func inspector(_ w: LibWorkout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Text(w.title).font(PadFont.display(32)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    PadTag(text: w.focus)
                    Spacer(minLength: 6)
                    PadIconButton(systemName: "plus.square.on.square", label: "Duplicate", small: true) { duplicate(w) }
                    PadIconButton(systemName: "trash", label: "Delete", small: true, tint: Pad.red) { confirmDelete = w }
                    PadLibraryGiveMenu(item: .workout(w.id))
                }
                HStack(spacing: 10) {
                    PadLibraryStat(value: "\(w.exerciseCount)", label: "exercises")
                    PadLibraryStat(value: "\(w.setCount)", label: "sets")
                    PadLibraryStat(value: "~\(w.estMinutes)", label: "minutes")
                    PadLibraryStat(value: "\(w.given)", label: "times given")
                }
                PadPane(title: "Focus", aside: "share of sets") {
                    PadLibrarySplitBar(parts: [("Legs", w.legs, Pad.volt), ("Push", w.push, Pad.text), ("Pull", w.pull, Color(hex: 0x8E8E93)), ("Other", w.other, Pad.raised)])
                    let muscles: [(String, Int)] = w.setsPerMuscle.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    HStack(spacing: 6) {
                        ForEach(muscles, id: \.0) { m in PadTag(text: "\(m.0) \(m.1)") }
                    }
                }
                PadPane(title: "What's in it", aside: w.steps.count.plural("exercise")) {
                    VStack(spacing: 0) {
                        ForEach(Array(w.steps.enumerated()), id: \.offset) { i, s in
                            if i > 0 { PadRule() }
                            HStack(spacing: 10) {
                                Text("\(i + 1)").font(PadFont.cond(13)).foregroundColor(Pad.faint).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                    Text(s.muscleGroup ?? "").font(PadFont.cond(12)).foregroundColor(Pad.mute)
                                }
                                Spacer(minLength: 6)
                                Text(s.rx ?? "\(s.sets) sets").font(PadFont.ui(14)).foregroundColor(Pad.text)
                                if let r = s.restSeconds, r > 0 { PadLab("rest \(PadLibraryKit.rest(r))", color: Pad.faint, size: 12) }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { if let x = lib.exercise(named: s.name) { lib.exerciseKey = x.key; lib.open(.exercises) } }
                        }
                    }
                }
                PadPane(title: "Who you give it to", aside: w.lastGiven.map { "last \(PadDay.short($0))" }) {
                    if w.givenTo.isEmpty {
                        PadEmptyLine(text: "Not given to anyone yet. Drag it onto a face below, or Give to….")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(w.givenTo.enumerated()), id: \.element.id) { i, g in
                                if i > 0 { PadRule() }
                                HStack(spacing: 10) {
                                    PadAvatar(name: g.name, size: 28)
                                    Text(g.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                                    Spacer(minLength: 6)
                                    PadLab("\(g.times)×", color: Pad.text, size: 13)
                                    PadLab(g.last.map { "last \(PadDay.short($0))" } ?? "", size: 12).frame(width: 90, alignment: .trailing)
                                    PadLab(g.next.map { "next \(PadDay.short($0))" } ?? "nothing planned", color: g.next == nil ? Pad.faint : Pad.voltText, size: 12).frame(width: 110, alignment: .trailing)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .onTapGesture { PadOpen.client(g.clientId, .workouts, go: go) }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func duplicate(_ w: LibWorkout) {
        guard !busy else { return }
        busy = true
        Task {
            do { try await APIClient.shared.duplicateLibraryWorkout(id: w.id); await lib.reloadWorkouts(); PadToasts.shared.show("Duplicated “\(w.title)”") }
            catch { PadToasts.shared.show("Couldn't duplicate it. Try again.") }
            busy = false
        }
    }

    private func delete(_ w: LibWorkout) {
        Task {
            do {
                try await APIClient.shared.deleteLibraryWorkout(id: w.id)
                if lib.workoutId == w.id { lib.workoutId = nil }
                await lib.reloadWorkouts()
                PadToasts.shared.show("Deleted “\(w.title)”")
            } catch { PadToasts.shared.show("Couldn't delete it. Try again.") }
        }
    }
}

/// Sets per muscle as a tiny column chart: a saved workout's fingerprint.
struct PadLibraryFingerprint: View {
    let setsPerMuscle: [String: Int]
    private static let order = ["Quads", "Hamstrings", "Glutes", "Calves", "Chest", "Shoulders", "Triceps", "Back", "Biceps", "Forearms", "Core", "Full Body", "Cardio"]
    var body: some View {
        let keys: [String] = Self.order.filter { setsPerMuscle[$0] != nil } + setsPerMuscle.keys.filter { !Self.order.contains($0) }.sorted()
        let m: Int = max(setsPerMuscle.values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(keys, id: \.self) { k in
                RoundedRectangle(cornerRadius: 2)
                    .fill(PadLibraryKit.isLower(k) ? Pad.volt : Pad.text.opacity(0.75))
                    .frame(height: max(3, 36 * CGFloat(setsPerMuscle[k] ?? 0) / CGFloat(m)))
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
        .accessibilityHidden(true)
    }
}

/// A horizontal share bar with a legend.
struct PadLibrarySplitBar: View {
    let parts: [(String, Double, Color)]
    var body: some View {
        let total: Double = max(parts.map { $0.1 }.reduce(0, +), 0.0001)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                        RoundedRectangle(cornerRadius: 3).fill(p.2).frame(width: max(4, (g.size.width - 6) * CGFloat(p.1 / total)))
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 9, height: 9)
                        Text("\(p.0) \(Int((p.1 / total * 100).rounded()))%").font(PadFont.cond(12)).foregroundColor(Pad.mute)
                    }
                }
            }
        }
    }
}

/// A number with a label under it, in a well.
struct PadLibraryStat: View {
    let value: String
    let label: String
    var warn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(PadFont.display(26)).foregroundColor(warn ? Pad.orange : Pad.text).lineLimit(1).minimumScaleFactor(0.6)
            PadLab(label, size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }
}

/// What a dragged item looks like under your finger.
struct PadLibraryDragPreview: View {
    let icon: String
    let title: String
    let sub: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(Pad.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                Text(sub).font(PadFont.cond(12)).foregroundColor(Pad.mute)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line2, lineWidth: 1))
    }
}

// MARK: - Give a saved workout: who and which days

struct PadLibraryGiveWorkoutSheet: View {
    let workout: LibWorkout
    let client: RosterItem
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var days: Set<DateComponents> = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    PadLab("GIVE A SAVED WORKOUT", color: Pad.faint, size: 12)
                    Text("\(workout.title) → \(client.id == store.selfClientId ? "You" : client.name)").font(PadFont.display(28)).foregroundColor(Pad.text)
                }
                Spacer()
                PadIconButton(systemName: "xmark", label: "Close", small: true) { dismiss() }
            }
            PadLab("Pick the days. Each one becomes a session on their calendar, and they can start it from their phone.", size: 14)
            MultiDatePicker("Days", selection: $days, in: Calendar.training.startOfDay(for: Date())...)
                .tint(Pad.isLight ? Pad.text : Pad.volt)
                .frame(maxHeight: 360)
            if let error { PadLab(error, color: Pad.orange, size: 13) }
            HStack {
                PadLab(days.isEmpty ? "No days picked" : days.count.plural("session"), size: 14)
                Spacer()
                Button { save() } label: {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(Pad.onVolt) }
                        Text(days.count <= 1 ? "Give it" : "Give \(days.count) sessions")
                    }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(days.isEmpty || saving)
                .opacity(days.isEmpty ? 0.5 : 1)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func save() {
        let cal = Calendar.training
        let picked: [Date] = days.compactMap { cal.date(from: $0) }.sorted()
        guard !picked.isEmpty else { return }
        saving = true
        error = nil
        Task {
            do {
                let n = try await APIClient.shared.giveLibraryWorkout(id: workout.id, clientId: client.id, days: picked)
                await PadData.shared.refresh(roster: store.roster)
                await PadLibraryStore.shared.reloadWorkouts()
                PadToasts.shared.show("\(n.plural("session")) on \(client.id == store.selfClientId ? "your" : client.name.firstName + "'s") calendar")
                dismiss()
            } catch {
                self.error = "Couldn't give it. Check your connection and try again."
            }
            saving = false
        }
    }
}

// MARK: - Programs

struct PadLibraryPrograms: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var data = PadData.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go
    @State private var busy = false

    private var list: [APIProgramSummary] {
        lib.programs.sorted { a, b in
            let ra = lib.programResults[a.id]?.runs.count ?? 0, rb = lib.programResults[b.id]?.runs.count ?? 0
            return ra != rb ? ra > rb : a.name < b.name
        }
    }
    private var selected: APIProgramSummary? {
        if let id = lib.programId, let p = lib.program(id) { return p }
        return list.first
    }

    var body: some View {
        HStack(spacing: 0) {
            PadLibraryColumn(width: 260) {
                HStack {
                    PadLab("\(lib.programs.count.plural("program")) · results from everyone who's run them", size: 12)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 44)
            } content: {
                if !lib.loaded {
                    ForEach(0..<4, id: \.self) { _ in PadSkeleton(height: 64).padding(12) }
                } else if list.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        PadEmptyLine(text: "No programs yet. Build your first; it shows here with its results.")
                        Button { actions.sheet(.programEditor(nil)) } label: { Label("New program", systemImage: "plus") }
                            .buttonStyle(PadButtonStyle(kind: .primary, small: true))
                    }
                    .padding(14)
                } else {
                    ForEach(list) { p in row(p) }
                }
            }
            Rectangle().fill(Pad.line).frame(width: 1)
            Group {
                if let p = selected { PadLibraryProgramPage(program: p) } else {
                    PadLibraryPick(icon: "calendar", title: "Pick a program", text: "See its shape and what it did for everyone who ran it.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: data.loadedAt) { _, _ in lib.computeResults(store: store) }
    }

    private func row(_ p: APIProgramSummary) -> some View {
        let on: Bool = selected?.id == p.id
        let r = lib.programResults[p.id]
        let gain: String = r?.avgStrength.map { String(format: "%+.1f%%", $0) } ?? "—"
        let ran: Int = r?.runs.count ?? 0
        return Button { lib.programId = p.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(2)
                Text("\(p.weeks) weeks · \(p.daysPerWeek) days\(p.blocks > 1 ? " · \(p.blocks) blocks" : "")").font(PadFont.cond(13)).foregroundColor(Pad.mute)
                HStack(spacing: 6) {
                    Text(gain + " lifts").font(PadFont.cond(13)).foregroundColor((r?.avgStrength ?? 0) > 0 ? Pad.voltText : Pad.mute)
                    Text("·").foregroundColor(Pad.faint)
                    Text(ran == 0 ? "not run yet" : "ran by \(ran)").font(PadFont.cond(13)).foregroundColor(Pad.mute)
                }
            }
            .padLibraryRow(on)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.program(p.id).payload) { PadLibraryDragPreview(icon: "calendar", title: p.name, sub: "\(p.weeks) weeks · \(p.daysPerWeek) days") }
    }
}

struct PadLibraryProgramPage: View {
    let program: APIProgramSummary
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var coach = CoachData.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go
    @State private var busy = false

    private var doc: APIProgramDoc? { lib.programDocs[program.id]?.doc }
    private var result: PadLibraryProgramResult { lib.programResults[program.id] ?? PadLibraryProgramResult() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !program.description.isEmpty {
                    Text(program.description).font(PadFont.ui(14)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                }
                shapePane
                HStack(alignment: .top, spacing: 12) {
                    runsPane.frame(maxWidth: .infinity)
                    rankPane.frame(width: 300)
                }
                HStack(alignment: .top, spacing: 12) {
                    losesPane.frame(maxWidth: .infinity)
                    saidPane.frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(program.name).font(PadFont.display(32)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
            PadLab("\(program.weeks) weeks · \(program.daysPerWeek) days a week" + (deloadText.isEmpty ? "" : " · " + deloadText), size: 13).lineLimit(1)
            Spacer(minLength: 6)
            PadIconButton(systemName: "plus.square.on.square", label: "Duplicate", small: true) { duplicate() }
            Button { actions.sheet(.programEditor(program.id)) } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            Button { actions.sheet(.programDetail(program)) } label: { Label("Open", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            PadLibraryGiveMenu(item: .program(program.id))
        }
    }

    private var deloadText: String {
        guard let doc else { return "" }
        var weeks: [Int] = []
        var w = 0
        for b in doc.blocks { w += b.weeks; if b.deloadLast == true { weeks.append(w) } }
        if weeks.isEmpty { return "" }
        return "deload in week" + (weeks.count == 1 ? " " : "s ") + weeks.map(String.init).joined(separator: " and ")
    }

    // MARK: The shape

    struct Cell { let title: String; let scheme: String; let focus: Int; let deload: Bool }   // focus 0 lower · 1 upper · 2 full

    private var shape: (weekdays: [Int], weeks: [[Int: Cell]], sets: [Int])? {
        guard let doc, !doc.blocks.isEmpty else { return nil }
        var weeks: [[Int: Cell]] = []
        var sets: [Int] = []
        var weekdays: Set<Int> = []
        for b in doc.blocks {
            for wi in 0..<max(b.weeks, 1) {
                var row: [Int: Cell] = [:]
                var n = 0
                let deload: Bool = b.deloadLast == true && wi == b.weeks - 1
                for d in b.days {
                    weekdays.insert(d.weekday)
                    let first = d.exercises.first
                    let scheme: String = first.map { e in e.sets.isEmpty ? "" : "\(e.sets.count)×\(e.sets[0].reps)" } ?? ""
                    row[d.weekday] = Cell(title: d.title, scheme: scheme, focus: PadLibraryKit.focus(d.exercises.map { (muscle: $0.muscleGroup ?? "", sets: $0.sets.count) }), deload: deload)
                    n += d.exercises.map { $0.sets.count }.reduce(0, +)
                }
                weeks.append(row)
                sets.append(deload ? n / 2 : n)
            }
        }
        return (weekdays.sorted(), weeks, sets)
    }

    private var shapePane: some View {
        PadPane(title: "The shape", aside: "weeks across · days down · faded = deload") {
            if let s = shape {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Color.clear.frame(width: 40, height: 1)
                            ForEach(0..<s.weeks.count, id: \.self) { i in
                                Text("W\(i + 1)").font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: cellWidth(s.weeks.count))
                            }
                        }
                        ForEach(s.weekdays, id: \.self) { wd in
                            HStack(spacing: 4) {
                                Text(PadLibraryKit.weekday(wd)).font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: 40, alignment: .leading)
                                ForEach(0..<s.weeks.count, id: \.self) { i in cell(s.weeks[i][wd], width: cellWidth(s.weeks.count)) }
                            }
                        }
                        HStack(alignment: .bottom, spacing: 4) {
                            Text("sets").font(PadFont.cond(11)).foregroundColor(Pad.mute).frame(width: 40, alignment: .leading)
                            let m: Int = max(s.sets.max() ?? 1, 1)
                            ForEach(0..<s.sets.count, id: \.self) { i in
                                VStack(spacing: 2) {
                                    Text("\(s.sets[i])").font(PadFont.cond(10)).foregroundColor(Pad.faint)
                                    RoundedRectangle(cornerRadius: 3).fill(Pad.raised).frame(width: cellWidth(s.weeks.count), height: max(3, 30 * CGFloat(s.sets[i]) / CGFloat(m)))
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    legend(Pad.volt, "Lower")
                    legend(Pad.isLight ? Color(hex: 0x2A2A2E) : Pad.chalk, "Upper")
                    legend(Color(hex: 0xB9BAB5), "Full")
                }
            } else {
                PadSkeleton(height: 120)
            }
        }
    }

    private func cellWidth(_ n: Int) -> CGFloat { n <= 8 ? 92 : (n <= 12 ? 72 : 60) }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9); PadLab(t, size: 12) }
    }

    @ViewBuilder
    private func cell(_ c: Cell?, width: CGFloat) -> some View {
        if let c {
            let bg: Color = c.focus == 0 ? Pad.volt : (c.focus == 1 ? (Pad.isLight ? Color(hex: 0x2A2A2E) : Pad.chalk) : Color(hex: 0xB9BAB5))
            let fg: Color = c.focus == 0 ? Pad.onVolt : (c.focus == 1 ? (Pad.isLight ? .white : Pad.ink) : Pad.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.title).font(PadFont.cond(11.5)).lineLimit(1)
                Text(c.scheme).font(PadFont.cond(10.5, .medium)).opacity(0.75)
            }
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .frame(width: width, height: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(bg))
            .opacity(c.deload ? 0.4 : 1)
        } else {
            RoundedRectangle(cornerRadius: 7).stroke(Pad.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: width, height: 40)
        }
    }

    // MARK: Results

    private var runsPane: some View {
        let r = result
        let aside: String = r.runs.isEmpty ? "nobody yet" : "\(r.runs.count.plural("client")) · \(r.prs.plural("PR"))"
        return PadPane(title: "Everyone who's run it", aside: aside) {
            if r.runs.isEmpty {
                PadEmptyLine(text: "Nobody's run it yet. Drag it onto a face below, or Give to….")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        head("Client").frame(maxWidth: .infinity, alignment: .leading)
                        head("Started").frame(width: 62, alignment: .leading)
                        head("Sessions done").frame(width: 150, alignment: .leading)
                        head("Lifts").frame(width: 56, alignment: .trailing)
                        head("PRs").frame(width: 34, alignment: .trailing)
                        head("").frame(width: 104, alignment: .trailing)
                    }
                    ForEach(r.runs.sorted { $0.assignment.startDate > $1.assignment.startDate }) { run in runRow(run) }
                }
            }
        }
    }

    private func head(_ t: String) -> some View { Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint).padding(.bottom, 4) }

    private func runRow(_ run: PadLibraryProgramRun) -> some View {
        let a = run.assignment
        let frac: Double = run.due > 0 ? Double(run.done) / Double(run.due) : 0
        let ended: Bool = a.status.lowercased() == "ended" || a.endDate < Date()
        let status: String = run.stalled ? "stalled · wk \(min(a.currentWeek, a.totalWeeks))" : (ended ? "finished" : "running · wk \(min(a.currentWeek, a.totalWeeks))")
        let lifts: String = run.strength.map { String(format: "%+.1f%%", $0) } ?? "—"
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                PadAvatar(name: a.clientName, size: 26)
                Text(a.clientName).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(PadDay.short(a.startDate)).font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 62, alignment: .leading)
            HStack(spacing: 6) {
                PadBar(fraction: frac, hero: false, height: 7)
                Text("\(run.done)/\(max(run.due, run.done))").font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: 44, alignment: .leading)
            }
            .frame(width: 150)
            Text(lifts).font(PadFont.ui(13, .semibold)).foregroundColor((run.strength ?? 0) > 0 ? Pad.voltText : Pad.text).frame(width: 56, alignment: .trailing)
            Text("\(run.prs)").font(PadFont.ui(13)).foregroundColor(Pad.text).frame(width: 34, alignment: .trailing)
            Text(status).font(PadFont.cond(12)).foregroundColor(run.stalled ? Pad.orange : Pad.mute).frame(width: 104, alignment: .trailing).lineLimit(1)
        }
        .frame(minHeight: 40)
        .overlay(alignment: .top) { PadRule() }
        .contentShape(Rectangle())
        .onTapGesture { PadOpen.client(a.clientId, .program, go: go) }
    }

    private var rankPane: some View {
        let ranked: [(APIProgramSummary, Double)] = lib.programs.compactMap { p in lib.programResults[p.id]?.avgStrength.map { (p, $0) } }.sorted { $0.1 > $1.1 }
        let top: Double = max(ranked.map { abs($0.1) }.max() ?? 1, 0.1)
        return PadPane(title: "Against your others", aside: "average lift change") {
            if ranked.count < 2 {
                PadEmptyLine(text: ranked.isEmpty ? "Shows once people have run a program for a couple of weeks." : "Shows when a second program has results to compare.")
            } else {
                VStack(spacing: 6) {
                    ForEach(ranked, id: \.0.id) { p, v in
                        let on: Bool = p.id == program.id
                        HStack(spacing: 8) {
                            Text(p.name).font(PadFont.ui(13, on ? .bold : .medium)).foregroundColor(Pad.text).lineLimit(1).frame(width: 120, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Pad.well)
                                    RoundedRectangle(cornerRadius: 4).fill(on ? Pad.volt : Color(hex: 0xB9BAB5)).frame(width: max(4, g.size.width * CGFloat(abs(v) / top)))
                                }
                            }
                            .frame(height: 14)
                            Text(String(format: "%+.1f%%", v)).font(PadFont.ui(13, .bold)).foregroundColor(Pad.text).frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            if let f = result.finishersVsRest {
                Text("People who did 90%+ of sessions: \(String(format: "%+.1f%%", f.fin)). Under 70%: \(String(format: "%+.1f%%", f.rest)).")
                    .font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var losesPane: some View {
        let missed: [Int] = result.missedByWeek
        let worst: Int? = missed.indices.max { missed[$0] < missed[$1] }
        let m: Int = max(missed.max() ?? 1, 1)
        return PadPane(title: "Where it loses people", aside: "sessions missed, by week") {
            if missed.allSatisfy({ $0 == 0 }) {
                PadEmptyLine(text: result.runs.isEmpty ? "Shows once people have run it." : "Nobody's missed a session on it. 👊")
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<missed.count, id: \.self) { i in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3).fill(i == worst ? Pad.orange : Color(hex: 0xB9BAB5))
                                .frame(height: max(3, 48 * CGFloat(missed[i]) / CGFloat(m)))
                            Text("W\(i + 1)").font(PadFont.cond(11)).foregroundColor(Pad.mute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 66)
                if let w = worst {
                    Text("Week \(w + 1) is where people drift: \(missed[w].plural("missed session")).").font(PadFont.ui(13)).foregroundColor(Pad.mute)
                }
            }
        }
    }

    private var quotes: [(text: String, who: String)] {
        var out: [(Date, String, String)] = []
        for run in result.runs {
            let a = run.assignment
            for ci in coach.checkIns[a.clientId] ?? [] where ci.date >= a.startDate && ci.date <= a.endDate.addingTimeInterval(86_400) {
                let week: Int = (Calendar.training.dateComponents([.day], from: a.startDate, to: ci.date).day ?? 0) / 7 + 1
                for f in ci.fields where f.label.hasSuffix("|longText") {
                    let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if v.count >= 12 { out.append((ci.date, v, "\(a.clientName.firstName) · week \(week)")) }
                }
            }
        }
        return out.sorted { $0.0 > $1.0 }.prefix(3).map { (text: $0.1, who: $0.2) }
    }

    private var saidPane: some View {
        let qs = quotes
        return PadPane(title: "What they said", aside: "check-ins while on it") {
            if qs.isEmpty {
                PadEmptyLine(text: "Written check-in answers from people on it show here.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                        (Text("“\(q.text)” ").foregroundColor(Pad.text) + Text(q.who).font(PadFont.cond(12)).foregroundColor(Pad.mute))
                            .font(PadFont.ui(14)).lineLimit(3)
                    }
                }
            }
        }
    }

    private func duplicate() {
        guard !busy else { return }
        busy = true
        Task {
            do { try await APIClient.shared.duplicateProgram(id: program.id); await lib.reloadPrograms(); PadToasts.shared.show("Duplicated “\(program.name)”") }
            catch { PadToasts.shared.show("Couldn't duplicate it. Try again.") }
            busy = false
        }
    }
}
