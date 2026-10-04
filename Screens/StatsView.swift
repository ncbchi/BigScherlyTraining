import SwiftUI
import Charts

// MARK: - Stats tab (was History)
// Four sections, top to bottom:
//   THIS WEEK  — one headline sentence + three numbers
//   CALENDAR   — month/week widget; tap a day to see that day's training
//   TRENDS     — window picker, then Strength (SBD) and swipeable Insight cards
//   EXPLORE    — every exercise, workout type, and SBD, each with its own chart

struct StatsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_stats_window") private var windowRaw = StatsWindow.w12.rawValue
    @State private var path: [StatsSubject] = []
    @State private var explore: ExploreMode = .exercises
    @State private var selectedDay: Date = Calendar.training.startOfDay(for: Date())
    @State private var pickedInitialDay = false
    @State private var showNotes = false

    enum ExploreMode: String, CaseIterable, Identifiable {
        case exercises = "Exercises", workouts = "Workouts", sbd = "SBD"
        var id: String { rawValue }
    }

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .w12 }
    private var engine: StatsEngine { StatsEngine(store: store) }

    var body: some View {
        NavigationStack(path: $path) {
            let sessions = engine.allSessions(window: window)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Your Numbers")
                        Text("Stats").font(BrandFont.display(48)).foregroundColor(Brand.text)
                    }

                    thisWeek.staggeredAppear(0)

                    VStack(alignment: .leading, spacing: 10) {
                        StatsCalendarCard(selectedDay: $selectedDay)
                        DaySummaryCard(day: selectedDay) { id in path.append(.session(id)) }
                    }
                    .staggeredAppear(1)

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("TRENDS", sub: "for the \(window.label)")
                        StatsWindowPicker(selection: Binding(get: { window }, set: { windowRaw = $0.rawValue }))
                        if sessions.isEmpty {
                            Text("No logged sessions in the \(window.label). Try a longer window.")
                                .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                                .frame(maxWidth: .infinity).padding(.vertical, 20).card()
                        } else {
                            strengthCard(sessions)
                            insights(sessions)
                        }
                    }
                    .staggeredAppear(2)

                    exploreSection.staggeredAppear(3)
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
            }
            .background(Brand.bg.ignoresSafeArea())
            // Fade content out under the floating menu button.
            .overlay(alignment: .top) {
                LinearGradient(colors: [Brand.bg, Brand.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70).ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: StatsSubject.self) { subject in
                if case .session(let id) = subject {
                    StatsSessionView(workoutId: id)
                } else {
                    StatsDetailView(subject: subject)
                }
            }
            .sheet(isPresented: $showNotes) { notesSheet(sessions) }
            .task(id: window) {
                for s in sessions { _ = await store.loadWorkoutVitals(workoutId: s.id) }
            }
            .onAppear {
                // Open on the most recent training day so the summary isn't empty.
                guard !pickedInitialDay else { return }
                pickedInitialDay = true
                let cal = Calendar.training
                let today = cal.startOfDay(for: Date())
                let trainedToday = store.workouts.contains { $0.completed && cal.isDate($0.date, inSameDayAs: today) }
                if !trainedToday, let last = store.workouts.filter({ $0.completed && $0.date <= Date() }).map({ $0.date }).max() {
                    selectedDay = cal.startOfDay(for: last)
                }
            }
        }
        .tint(Brand.volt)
    }

    // MARK: This week

    private var thisWeek: some View {
        let cal = Calendar.training
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let lastStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        let thisW = store.workouts.filter { $0.completed && $0.date >= weekStart }
        let lastW = store.workouts.filter { $0.completed && $0.date >= lastStart && $0.date < weekStart }
        func sets(_ ws: [Workout]) -> Int { ws.flatMap { $0.exercises.flatMap { $0.sets } }.filter { $0.loggedReps != nil }.count }
        func vol(_ ws: [Workout]) -> Double {
            ws.flatMap { $0.exercises.flatMap { $0.sets } }.compactMap { s -> Double? in
                guard let r = s.loggedReps, let w = s.loggedWeight else { return nil }
                return Double(r) * w
            }.reduce(0, +)
        }
        let v = vol(thisW), lv = vol(lastW)
        let planned = store.workouts.filter { $0.date >= weekStart && $0.date < (cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart) }.count
        let headline: String = {
            if thisW.isEmpty {
                return planned > 0 ? "\(planned) session\(planned == 1 ? "" : "s") planned this week. Let's get the first one in."
                                   : "Nothing logged yet this week."
            }
            var t = "\(thisW.count) of \(max(planned, thisW.count)) sessions done · \(sets(thisW)) sets"
            if lv > 0 {
                let pct = (v - lv) / lv * 100
                t += String(format: " · volume %@%.0f%% vs last week", pct >= 0 ? "+" : "", pct)
            }
            return t
        }()
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("THIS WEEK", sub: nil)
            Text(headline).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                tile("\(thisW.count)/\(max(planned, thisW.count))", "SESSIONS")
                tile("\(sets(thisW))", "SETS")
                tile("\(weekStreak())", "WEEK STREAK")
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.display(28)).foregroundColor(Brand.voltText).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
    }

    private func weekStreak() -> Int {
        let cal = Calendar.training
        let weeks = Set(store.workouts.filter { $0.completed }.compactMap { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start })
        guard var week = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        if !weeks.contains(week) { week = cal.date(byAdding: .weekOfYear, value: -1, to: week) ?? week }
        var n = 0
        while weeks.contains(week) {
            n += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: week) else { break }
            week = prev
        }
        return n
    }

    // MARK: Strength (SBD)

    @ViewBuilder
    private func strengthCard(_ sessions: [StatsSession]) -> some View {
        let lifts: [(lift: SBDLift, points: [(Date, Double)])] = SBDLift.allCases.compactMap { lift in
            let pts = sessions.compactMap { s -> (Date, Double)? in
                guard let v = s.exercises.filter({ $0.sbd == lift }).map({ $0.bestE1RM }).max() else { return nil }
                return (s.date, v)
            }
            return pts.isEmpty ? nil : (lift, pts)
        }
        if !lifts.isEmpty {
            Button { path.append(.sbd) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("STRENGTH").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        Spacer()
                        if lifts.count == 3 {
                            Text("SBD TOTAL \(StatsUnits.weightText(lifts.compactMap { $0.points.last?.1 }.reduce(0, +)))")
                                .font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(lifts, id: \.lift) { item in
                            let first = item.points.first?.1 ?? 0, last = item.points.last?.1 ?? 0
                            let change = last - first
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.lift.rawValue.uppercased()).font(BrandFont.body(9, .bold)).tracking(1)
                                    .foregroundColor(item.lift.color)
                                Text(StatsUnits.weightText(last, unit: false)).font(BrandFont.display(24)).foregroundColor(Brand.text)
                                Text(change == 0 ? "est. 1RM" : "\(change > 0 ? "+" : "−")\(StatsUnits.weightText(abs(change)))")
                                    .font(BrandFont.body(10, .bold))
                                    .foregroundColor(change > 0 ? Brand.voltText : change < 0 ? .orange : Brand.mute)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if lifts.contains(where: { $0.points.count > 1 }) {
                        MiniChart(lines: lifts.map { item in
                                      MiniChart.Line(name: item.lift.rawValue, color: item.lift.color,
                                                     points: item.points.map { ($0.0, StatsUnits.weight($0.1)) })
                                  },
                                  unit: "est. 1RM (\(StatsUnits.weightLabel))", height: 170)
                    }
                    Text("Tap for SBD total, DOTS and every chart")
                        .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                }
                .card(padding: 16)
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: Insights (swipeable, one idea per card)

    private func insights(_ sessions: [StatsSession]) -> some View {
        let cards = insightCards(sessions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("INSIGHTS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                Text("swipe →").font(BrandFont.body(10)).foregroundColor(Brand.mute)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(cards) { c in
                        Button {
                            if c.id == "notes" { showNotes = true }
                            else if let t = c.target { path.append(t) }
                        } label: { InsightCardView(card: c) }
                        .buttonStyle(PressableStyle())
                        .containerRelativeFrame(.horizontal) { w, _ in w * 0.82 }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func insightCards(_ sessions: [StatsSession]) -> [InsightCard] {
        var cards: [InsightCard] = []
        func avg(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }

        // Biggest gain
        let byName = Dictionary(grouping: sessions.flatMap { s in s.exercises.map { (s.date, $0) } }, by: { $0.1.name })
        let gains = byName.compactMap { name, e -> (String, Double, Double, [(Date, Double)])? in
            let sorted = e.sorted { $0.0 < $1.0 }
            guard sorted.count >= 2, let f = sorted.first?.1.bestE1RM, let l = sorted.last?.1.bestE1RM, f > 0, l > f else { return nil }
            return (name, (l - f) / f * 100, l - f, sorted.map { ($0.0, StatsUnits.weight($0.1.bestE1RM)) })
        }.sorted { $0.1 > $1.1 }
        if let g = gains.first {
            cards.append(InsightCard(id: "gain", icon: "arrow.up.right", title: "BIGGEST GAIN",
                                     value: String(format: "+%.1f%%", g.1),
                                     sentence: "\(g.0) est. 1RM is up \(StatsUnits.weightText(g.2)) in the \(window.label).",
                                     points: g.3, color: Brand.volt, target: .exercise(g.0),
                                     chartLabel: "\(g.0) est. 1RM", unit: StatsUnits.weightLabel))
        }

        // Newest PR
        let start = window.start ?? .distantPast
        let windowPRs = store.personalRecords.filter { $0.date >= start }.sorted { $0.date > $1.date }
        if let pr = windowPRs.first {
            let liftPoints: [(Date, Double)] = sessions.compactMap { s in
                guard let v = s.exercises.filter({ $0.name == pr.exercise }).map({ $0.bestE1RM }).max() else { return nil }
                return (s.date, StatsUnits.weight(v))
            }
            let beat = pr.isFirstEver
                ? "First recorded \(pr.exercise.lowercased()) PR."
                : "Beat the old best of \(StatsUnits.weightText(pr.previousBest)) by \(StatsUnits.weightText(pr.gain))."
            let earlier = windowPRs.dropFirst().prefix(1).map { p in
                InsightListItem(icon: "trophy", title: "\(p.exercise) · \(p.reps)×\(StatsUnits.weightText(p.weight, unit: false))",
                                detail: p.date.formatted(.dateTime.month(.abbreviated).day()))
            }
            cards.append(InsightCard(id: "pr", icon: "trophy.fill", title: "NEWEST PR",
                                     value: "\(pr.reps)×\(StatsUnits.weightText(pr.weight, unit: false))",
                                     sentence: "\(pr.exercise) · \(pr.date.formatted(.dateTime.month(.abbreviated).day())) · \(StatsUnits.weightText(pr.estimatedOneRepMax)) est. 1RM. \(beat)",
                                     points: liftPoints.count > 1 ? liftPoints : [], color: Brand.volt, target: .exercise(pr.exercise),
                                     chartLabel: "\(pr.exercise) est. 1RM", unit: StatsUnits.weightLabel,
                                     highlight: pr.date,
                                     list: Array(earlier), listTitle: earlier.isEmpty ? nil : "PREVIOUS PR"))
        }

        // Bar speed
        let tracked = sessions.filter { $0.hasMotion }
        if tracked.count >= 2 {
            let pts = tracked.map { s in (s.date, avg(s.reps.map { $0.meanVelocity })) }
            let firstHalf = avg(pts.prefix(pts.count / 2).map { $0.1 }), secondHalf = avg(pts.suffix(pts.count / 2).map { $0.1 })
            let diff = secondHalf - firstHalf
            let loss = avg(tracked.flatMap { $0.motions.compactMap { $0.velocityLossPct } })
            let sentence = abs(diff) < 0.01
                ? String(format: "Steady bar speed, losing about %.0f%% across a typical set.", loss)
                : String(format: "Average bar speed is %@ %.2f m/s, losing about %.0f%% across a typical set.",
                         diff > 0 ? "up" : "down", abs(diff), loss)
            cards.append(InsightCard(id: "speed", icon: "speedometer", title: "BAR SPEED",
                                     value: String(format: "%.2f m/s", avg(tracked.flatMap { $0.reps.map { $0.meanVelocity } })),
                                     sentence: sentence, points: pts, color: Brand.volt,
                                     target: tracked.last?.exercises.first(where: { $0.hasMotion }).map { .exercise($0.name) },
                                     chartLabel: "Avg bar speed per session", unit: "m/s"))
        }

        // Readiness
        if let r = engine.readiness(in: sessions) {
            cards.append(InsightCard(id: "ready", icon: "bolt.fill", title: "READINESS", value: nil,
                                     sentence: r.text, points: [], color: Brand.volt, target: .exercise(r.exerciseName)))
        }

        // Effort
        let withHR = sessions.filter { $0.hr != nil }
        if withHR.count >= 2 {
            let pts = withHR.map { ($0.date, Double($0.hr!.avg)) }
            let rpe = avg(sessions.compactMap { $0.avgRPE })
            cards.append(InsightCard(id: "effort", icon: "heart.fill", title: "EFFORT",
                                     value: "\(Int(avg(pts.map { $0.1 }))) bpm",
                                     sentence: String(format: "Average session heart rate, with a typical RPE of %.1f.", rpe),
                                     points: pts, color: Color(hex: 0x3D9BE0), target: nil,
                                     chartLabel: "Avg heart rate per session", unit: "bpm"))
        }

        // Balance
        let groups = Dictionary(grouping: sessions.flatMap { $0.exercises }, by: { $0.muscleGroup.isEmpty ? "Other" : $0.muscleGroup })
            .map { (name: $0.key, sets: $0.value.map { $0.sets.count }.reduce(0, +)) }
            .sorted { $0.sets > $1.sets }
        if groups.count >= 2, let top = groups.first, let low = groups.last {
            cards.append(InsightCard(id: "balance", icon: "chart.bar.fill", title: "TRAINING BALANCE",
                                     value: top.name,
                                     sentence: "Most sets went to \(top.name.lowercased()) (\(top.sets)); fewest to \(low.name.lowercased()) (\(low.sets)).",
                                     points: [], color: Brand.volt, target: nil,
                                     bars: groups.prefix(5).map { (name: $0.name, value: Double($0.sets)) }))
        }

        // Notes
        let notes = sessions.flatMap { $0.notes }.sorted { $0.date > $1.date }
        if !notes.isEmpty {
            let effort = notes.filter { $0.kind == .effort }.count
            let depth = notes.filter { $0.kind == .depth }.count
            var parts: [String] = []
            if effort > 0 { parts.append("\(effort) effort") }
            if depth > 0 { parts.append("\(depth) depth") }
            let preview = notes.prefix(2).map { n in
                InsightListItem(icon: n.icon,
                                title: "\(n.exerciseName) · \(n.date.formatted(.dateTime.month(.abbreviated).day()))",
                                detail: n.text)
            }
            cards.append(InsightCard(id: "notes", icon: "text.bubble.fill", title: "NOTES FROM YOUR DATA",
                                     value: "\(notes.count)",
                                     sentence: parts.joined(separator: " · ") + " — from your Watch data. Tap to read them all.",
                                     points: [], color: Brand.volt, target: nil,
                                     list: Array(preview), listTitle: "LATEST"))
        }
        return cards
    }

    private func notesSheet(_ sessions: [StatsSession]) -> some View {
        let grouped = sessions.filter { !$0.notes.isEmpty }.reversed()
        return NavigationStack {
            List {
                ForEach(Array(grouped)) { s in
                    Section("\(s.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(s.title)") {
                        ForEach(s.notes) { n in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: n.icon).foregroundColor(Brand.voltText).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(n.exerciseName).font(.caption.bold()).foregroundColor(Brand.mute)
                                    Text(n.text).font(.subheadline).foregroundColor(Brand.text)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showNotes = false }.foregroundColor(Brand.voltText)
                }
            }
        }
    }

    // MARK: Explore

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("EXPLORE", sub: "every lift and workout, charted")
            HStack(spacing: 8) {
                ForEach(ExploreMode.allCases) { m in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { explore = m } } label: {
                        Text(m.rawValue)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundColor(explore == m ? Brand.onVolt : Brand.text)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(explore == m ? Brand.volt : Brand.black).clipShape(Capsule())
                            .overlay(Capsule().stroke(explore == m ? Brand.voltLine : Brand.line, lineWidth: 1))
                    }
                }
            }
            VStack(spacing: 8) {
                switch explore {
                case .exercises:
                    ForEach(exerciseRows, id: \.name) { r in
                        exploreRow(r.name, "\(r.sessions) session\(r.sessions == 1 ? "" : "s") · last \(r.last.formatted(date: .abbreviated, time: .omitted))",
                                   trailing: StatsUnits.weightText(r.best), sensor: r.sensor) { path.append(.exercise(r.name)) }
                    }
                case .workouts:
                    ForEach(workoutRows, id: \.title) { r in
                        exploreRow(r.title, "\(r.count) session\(r.count == 1 ? "" : "s") · last \(r.last.formatted(date: .abbreviated, time: .omitted))",
                                   trailing: nil, sensor: false) { path.append(.workout(r.title)) }
                    }
                case .sbd:
                    exploreRow("Squat · Bench · Deadlift", "Total, DOTS and all three lifts together",
                               trailing: nil, sensor: false) { path.append(.sbd) }
                    ForEach(sbdExerciseNames, id: \.self) { name in
                        exploreRow(name, SBDLift.classify(name)?.rawValue ?? "", trailing: nil, sensor: false) {
                            path.append(.exercise(name))
                        }
                    }
                }
            }
        }
    }

    private struct ExerciseRow { var name: String; var sessions: Int; var last: Date; var best: Double; var sensor: Bool }

    private var exerciseRows: [ExerciseRow] {
        let all = engine.allSessions(window: .all)
        let byName = Dictionary(grouping: all.flatMap { s in s.exercises.map { (s.date, $0) } }, by: { $0.1.name })
        return byName.map { name, e in
            ExerciseRow(name: name, sessions: e.count, last: e.map { $0.0 }.max() ?? .distantPast,
                        best: e.map { $0.1.bestE1RM }.max() ?? 0, sensor: e.contains { $0.1.hasMotion })
        }
        .sorted { $0.last > $1.last }
    }

    private var workoutRows: [(title: String, count: Int, last: Date)] {
        Dictionary(grouping: store.workouts.filter { $0.completed }, by: { $0.title })
            .map { (title: $0.key, count: $0.value.count, last: $0.value.map { $0.date }.max() ?? .distantPast) }
            .sorted { $0.last > $1.last }
    }

    private var sbdExerciseNames: [String] {
        let names = Set(store.workouts.filter { $0.completed }.flatMap { $0.exercises.map { $0.name } })
        return names.filter { SBDLift.classify($0) != nil }.sorted {
            (SBDLift.allCases.firstIndex(of: SBDLift.classify($0)!) ?? 0) < (SBDLift.allCases.firstIndex(of: SBDLift.classify($1)!) ?? 0)
        }
    }

    private func exploreRow(_ title: String, _ sub: String, trailing: String?, sensor: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text).lineLimit(1)
                        if sensor {
                            Image(systemName: "applewatch").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.voltText)
                        }
                    }
                    Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                }
                Spacer()
                if let trailing {
                    Text(trailing).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.mute)
            }
            .padding(14)
            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func sectionHeader(_ t: String, sub: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(t).font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
            if let sub { Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute) }
            Spacer()
        }
    }
}
