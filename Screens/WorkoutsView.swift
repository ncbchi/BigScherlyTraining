import SwiftUI
import Charts

// MARK: - Workouts list
// Completed sits above (scroll up to reach it); the screen lands on the plan. Both are grouped by
// week (Oct 23, 2026 — see WorkoutWeeks.swift); swipe a planned workout for Move · Skip · Mark done.
// Today's workout is highlighted. Open a planned workout → the live session
// screen; open a completed one → its summary with Apple Health vitals.
struct WorkoutsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"
    @State private var selected: Workout?          // completed → summary
    @State private var building = false            // coach: plan his own workout
    @State private var showPreWorkoutPrompt = false
    @State private var preWorkoutDue: [Supplement] = []
    // Remembers the day we last showed the pre-workout drawer, so it appears at most
    // once a day rather than every time this tab is opened. Survives app restarts.
    @AppStorage("lastPreWorkoutPromptDay") private var lastPreWorkoutPromptDay = ""

    // By week (Oct 23, 2026): which weeks and days are open, the swiped row, the sheets.
    @State private var openWeeks: Set<Date> = []
    @State private var openDays: Set<Date> = []
    @State private var openDoneWeeks: Set<Date> = []
    @State private var openDoneDays: Set<Date> = []
    @State private var swipeOpen: String?
    @State private var markingDone: Workout?
    @State private var moving: Workout?
    @State private var resetting: Workout?          // a finished workout ▸ Reset (asks first)
    @State private var copying: Workout?            // ▸ Copy to another day
    @State private var notFinishedOnly = false
    @State private var didSetDefaults = false
    @ObservedObject private var actions = WorkoutActions.shared

    private let cal = Calendar.training

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // MARK: Lists

    private var order: [String: Int] {
        Dictionary(store.workouts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    /// Finished or skipped: the Completed section.
    private var doneList: [Workout] { store.workouts.filter { $0.completed || $0.skipped == true } }
    /// Still to do (past ones not finished included): the plan.
    private var planList: [Workout] { store.upcomingWorkouts }
    private var overdue: [Workout] { planList.filter { $0.date < cal.startOfDay(for: Date()) } }
    private var doneWeeks: [TrainingWeekGroup] { WorkoutWeeks.group(doneList, order: order) }
    private var planWeeks: [TrainingWeekGroup] {
        WorkoutWeeks.group(notFinishedOnly ? overdue : planList, order: order)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: "COMPLETED", subtitle: "\(store.pastWorkouts.count) sessions")
                    if doneList.isEmpty {
                        Text("No completed workouts yet.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }
                    weekList(doneWeeks, done: true)

                    // This is where the screen lands.
                    DSScreenHeader(eyebrow: "Training", title: "Workouts")
                        .padding(.top, 28)
                        .id("upcoming")
                    Text(planSummary).font(BrandFont.body(13.5)).foregroundColor(Brand.mute)
                        .padding(.top, -6)
                    // A coach programs himself, same builder he uses for clients.
                    if store.isTrainer, store.selfClientId != nil {
                        Button { building = true } label: { Label("Plan a workout", systemImage: "plus") }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                    if !overdue.isEmpty { filterChips }
                    weekList(planWeeks, done: false)
                    if planList.isEmpty {
                        Text("Nothing scheduled yet — check back soon.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 52).padding(.horizontal, 16).padding(.bottom, 90)
            }
            .background(Brand.bg.ignoresSafeArea())
            .dsTopFade()
            .sheet(isPresented: $building) {
                if let me = store.selfClientId {
                    WorkoutBuilderView(clientId: me, clientName: "") { store.loadAllFromAPI() }
                }
            }
            .onAppear {
                setDefaults()
                DispatchQueue.main.async {
                    withAnimation(.none) { proxy.scrollTo("upcoming", anchor: .top) }
                }
                // Prompt ONLY when there's actually something to take before a workout
                // today (see SupplementEngine.duePreWorkout), and only once per day.
                let today = Self.dayKey(Date())
                guard lastPreWorkoutPromptDay != today else { return }
                preWorkoutDue = SupplementEngine.shared.duePreWorkout(
                    supplements: store.supplements,
                    logs: store.supplementLogs,
                    workouts: store.workouts)
                if !preWorkoutDue.isEmpty {
                    showPreWorkoutPrompt = true
                    lastPreWorkoutPromptDay = today
                }
            }
        }
        .overlay(alignment: .bottom) { WorkoutActionToast() }
        .sheet(item: $selected) { w in WorkoutDetailView(workout: w) }
        .sheet(item: $markingDone) { w in
            MarkDoneSheet(workout: w) { asPlanned in
                if asPlanned { actions.markDoneAsPlanned(w.id) } else { actions.markDone(w.id) }
            }
            .sheetFitsContent()
        }
        .sheet(item: $moving) { w in
            MoveWorkoutSheet(workout: w) { day in actions.move(w.id, to: day) }
                .sheetFitsContent()
        }
        .sheet(item: $resetting) { w in
            ResetWorkoutSheet(workout: w) { actions.resetWorkout(w.id) }
                .sheetFitsContent()
        }
        .sheet(item: $copying) { w in
            CopyWorkoutSheet(workout: w) { day in actions.copyWorkout(w.id, to: day) }
                .sheetFitsContent()
        }
        .sheet(isPresented: $showPreWorkoutPrompt) {
            PreWorkoutSupplementPrompt(supplements: preWorkoutDue)
        }
        // Fires only when a logged set earns a throttled PR (see ProgressEngine).
        .sheet(item: Binding(get: { (store.sessionWorkoutId == nil || store.sessionMinimized) ? store.prToCelebrate : nil },
                             set: { store.prToCelebrate = $0 })) { pr in PRCelebrationView(pr: pr).sheetFitsContent() }
    }

    private var planSummary: String {
        let n = planList.count
        return "\(n) planned" + (overdue.isEmpty ? "" : " · \(overdue.count) not finished from earlier")
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            chip("All", on: !notFinishedOnly) { notFinishedOnly = false }
            chip("Not finished · \(overdue.count)", on: notFinishedOnly) { notFinishedOnly = true }
        }
    }

    private func chip(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button {
            withAnimation(WorkoutActions.spring) { tap() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(t).font(BrandFont.body(13, .bold))
                .foregroundColor(on ? Brand.onVolt : Brand.text)
                .padding(.horizontal, 13).frame(height: 32)
                .background(Capsule().fill(on ? Brand.volt : Brand.card))
                .overlay(Capsule().stroke(on ? Color.clear : Brand.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Weeks and days

    @ViewBuilder
    private func weekList(_ weeks: [TrainingWeekGroup], done: Bool) -> some View {
        ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
            if i == 0 || WorkoutWeeks.monthLabel(weeks[i - 1].start) != WorkoutWeeks.monthLabel(wk.start) {
                monthDivider(WorkoutWeeks.monthLabel(wk.start))
            }
            weekCard(wk, done: done)
        }
    }

    private func monthDivider(_ t: String) -> some View {
        HStack(spacing: 10) {
            Text(t).font(BrandFont.body(11, .heavy)).tracking(1.6).foregroundColor(Brand.mute)
            Rectangle().fill(Brand.line).frame(height: 1)
        }
        .padding(.top, 6).padding(.horizontal, 2)
    }

    private func weekCard(_ wk: TrainingWeekGroup, done: Bool) -> some View {
        let all = store.workouts.filter { cal.isSameTrainingWeek($0.date, wk.start) }
        let isOpen = done ? openDoneWeeks.contains(wk.start) : openWeeks.contains(wk.start)
        let thisWeek = WorkoutWeeks.isThisWeek(wk.start)
        let today = cal.startOfDay(for: Date())
        let leftOver = wk.workouts.filter { $0.date < today }.count
        let badge: String? = (!done && !thisWeek && leftOver > 0) ? "\(leftOver) not finished" : nil
        return WorkoutWeekCard(week: wk, allInWeek: done ? wk.workouts : all, open: isOpen, badge: badge,
                               subtitle: done ? doneSubtitle(wk) : planSubtitle(wk, all: all),
                               toggle: { toggleWeek(wk.start, done: done) }) {
            ForEach(Array(wk.days.enumerated()), id: \.element.id) { j, d in
                if j > 0 { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 76) }
                dayRow(d, done: done)
            }
        }
    }

    private func planSubtitle(_ wk: TrainingWeekGroup, all: [Workout]) -> String {
        let doneN = all.filter { $0.completed }.count
        let days = Set(all.map { cal.startOfDay(for: $0.date) }).count
        if WorkoutWeeks.isThisWeek(wk.start) {
            return "\(doneN) of \(all.count) done · today is \(Date().formatted(.dateTime.weekday(.wide)))"
        }
        if doneN == 0 && wk.start > Date() {
            return "\(all.count) workout\(all.count == 1 ? "" : "s") · \(days) day\(days == 1 ? "" : "s")"
        }
        return "\(doneN) of \(all.count) done"
    }

    private func doneSubtitle(_ wk: TrainingWeekGroup) -> String {
        let finished = wk.workouts.filter { $0.completed }
        let skipped = wk.workouts.count - finished.count
        let volume = finished.flatMap { $0.exercises.flatMap { $0.sets } }.compactMap { s -> Double? in
            guard let r = s.loggedReps, let w = s.loggedWeight else { return nil }
            return Double(r) * w
        }.reduce(0, +)
        var parts = ["\(finished.count) done"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if volume > 0 { parts.append(StatsUnits.weightText(volume)) }
        return parts.joined(separator: " · ")
    }

    private func dayRow(_ d: TrainingDayGroup, done: Bool) -> some View {
        let allThatDay = done ? d.workouts : store.workouts.filter { cal.isDate($0.date, inSameDayAs: d.day) }
        let isOpen = done ? openDoneDays.contains(d.day) : openDays.contains(d.day)
        return WorkoutDayRow(day: d, allThatDay: allThatDay, open: isOpen, toggle: { toggleDay(d.day, done: done) }) {
            ForEach(Array(d.workouts.enumerated()), id: \.element.id) { k, w in
                if k > 0 { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 52) }
                if done {
                    doneSwipeRow(w)
                } else {
                    swipeRow(w)
                }
            }
        }
    }

    private func swipeRow(_ w: Workout) -> some View {
        SwipeRevealRow(id: w.id, openId: $swipeOpen, actions: [
            SwipeAction(id: "move", title: "Move", icon: "calendar", fill: Brand.card, ink: Brand.voltText, stroke: Brand.voltLine) { moving = w },
            SwipeAction(id: "skip", title: "Skip", icon: "forward.fill", fill: Brand.card, ink: Brand.voltText, stroke: Brand.voltLine) { actions.skip(w.id) },
            SwipeAction(id: "done", title: "Mark done", icon: "checkmark", fill: Brand.volt, ink: Brand.onVolt) { requestDone(w) }
        ], onTap: { store.openSession(w.id) }) {
            PlannedWorkoutRow(workout: w)
        }
    }

    /// A finished (or skipped) workout, swiped left (Oct 27, 2026): Reopen · Reset · Copy to another day.
    private func doneSwipeRow(_ w: Workout) -> some View {
        var acts = [SwipeAction(id: "reopen", title: "Reopen", icon: "arrow.uturn.backward", fill: Brand.volt, ink: Brand.onVolt) {
            actions.reopenFinished(w.id)
        }]
        if w.completed {
            acts.append(SwipeAction(id: "reset", title: "Reset", icon: "arrow.counterclockwise",
                                    fill: Brand.card, ink: Brand.danger, stroke: Brand.danger) { resetting = w })
        }
        acts.append(SwipeAction(id: "copy", title: "Copy to another day", icon: "doc.on.doc",
                                fill: Brand.card, ink: Brand.voltText, stroke: Brand.voltLine) { copying = w })
        return SwipeRevealRow(id: "done-" + w.id, openId: $swipeOpen, actions: acts,
                              onTap: { if w.completed { selected = w } }) {
            DoneWorkoutRow(workout: w, prs: prCount(w))
        }
    }

    /// Unlogged sets: ask how to finish it. Everything logged: straight to done.
    private func requestDone(_ w: Workout) {
        let unlogged = w.exercises.flatMap { $0.sets }.contains { $0.loggedReps == nil }
        if unlogged { markingDone = w } else { actions.markDone(w.id) }
    }

    private func prCount(_ w: Workout) -> Int {
        store.personalRecords.filter { cal.isDate($0.date, inSameDayAs: w.date) }.count
    }

    private func toggleWeek(_ start: Date, done: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(WorkoutActions.spring) {
            if done {
                if openDoneWeeks.contains(start) { openDoneWeeks.remove(start) } else { openDoneWeeks.insert(start) }
            } else {
                if openWeeks.contains(start) { openWeeks.remove(start) } else { openWeeks.insert(start) }
            }
            swipeOpen = nil
        }
    }

    private func toggleDay(_ day: Date, done: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(WorkoutActions.spring) {
            if done {
                if openDoneDays.contains(day) { openDoneDays.remove(day) } else { openDoneDays.insert(day) }
            } else {
                if openDays.contains(day) { openDays.remove(day) } else { openDays.insert(day) }
            }
            swipeOpen = nil
        }
    }

    /// First visit: this week open (or the next week with something planned), on today's day
    /// (or the next day with a workout, else the last one before today).
    private func setDefaults() {
        guard !didSetDefaults else { return }
        didSetDefaults = true
        let weeks = WorkoutWeeks.group(planList, order: order)
        let thisWeek = cal.trainingWeekStart(Date())
        guard let wk = weeks.first(where: { $0.start == thisWeek }) ?? weeks.first(where: { $0.start > thisWeek }) else { return }
        openWeeks.insert(wk.start)
        let today = cal.startOfDay(for: Date())
        if let d = wk.days.first(where: { $0.day >= today }) ?? wk.days.last { openDays.insert(d.day) }
    }
}

// MARK: - Workout detail — exercises as a grid
struct WorkoutDetailView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var health = HealthKitManager.shared
    let workout: Workout
    @State private var selectedExercise: Exercise?
    @State private var vitals: WorkoutVitals?
    @State private var loadingVitals = false
    @State private var healthDenied = false
    @Environment(\.dismiss) var dismiss

    let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(workout.dayOfWeek.uppercased()) · \(workout.dateLabel)")
                        .font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    Text(workout.title).font(BrandFont.display(34)).foregroundColor(Brand.text)

                    if workout.completed {
                        let sets = workout.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }
                        let volume = sets.reduce(0.0) { $0 + $1.volume }
                        let prs = store.personalRecords.filter { Calendar.training.isDate($0.date, inSameDayAs: workout.date) }.count
                        HStack(spacing: 10) {
                            DSStatTile(value: StatsUnits.weightText(volume, unit: false), label: "\(StatsUnits.weightLabel.uppercased()) MOVED")
                            DSStatTile(value: "\(sets.count)", label: "SETS", color: Brand.text)
                            DSStatTile(value: "\(prs)", label: prs == 1 ? "PR" : "PRS", color: prs > 0 ? Brand.volt : Brand.mute)
                        }
                        NavigationLink { StatsSessionView(workoutId: workout.id) } label: {
                            DSListRow(title: "Full breakdown in Stats", subtitle: "Every set, rep-level bar speed and heart rate",
                                      icon: "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(PressableStyle())
                    }

                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(workout.exercises) { ex in
                            Button { selectedExercise = ex } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "dumbbell.fill").foregroundColor(Brand.voltText).font(.system(size: 20))
                                    Spacer()
                                    Text(ex.name).font(BrandFont.display(20)).foregroundColor(Brand.text).multilineTextAlignment(.leading)
                                    Text("\(ex.sets.count) sets · \(ex.muscleGroup)").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                                }
                                .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                                .card()
                            }
                        }
                    }

                    // Apple Health session vitals — what the body actually did.
                    if workout.completed {
                        vitalsSection
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Brand.voltText)
                }
            }
            .sheet(item: $selectedExercise) { ex in
                ExerciseDetailView(exercise: ex, sessionVitals: vitals)
            }
            .task { await loadVitals() }
            .onAppear { store.activeWorkoutId = workout.id }
            .onDisappear { if store.activeWorkoutId == workout.id { store.activeWorkoutId = nil } }
        }
    }

    // MARK: Vitals

    @ViewBuilder
    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundColor(Brand.voltText).font(.system(size: 14))
                Text("SESSION VITALS").font(BrandFont.body(12, .bold)).tracking(1.5).headerPill()
            }
            .padding(.top, 8)

            if loadingVitals {
                HStack { ProgressView().tint(Brand.volt); Text("Reading Apple Health…").font(BrandFont.body(13)).foregroundColor(Brand.mute) }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else if let v = vitals {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        vitalStat("\(v.durationMinutes)", "MIN", "clock.fill")
                        vitalStat(v.avgHeartRate.map { "\($0)" } ?? "—", "AVG BPM", "heart.fill")
                        vitalStat(v.peakHeartRate.map { "\($0)" } ?? "—", "PEAK BPM", "bolt.heart.fill")
                        vitalStat(v.activeCalories.map { "\($0)" } ?? "—", "KCAL", "flame.fill")
                    }
                    if v.heartRateSeries.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HEART RATE (BPM)").font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.mute)
                            HeartRateSparkline(samples: v.heartRateSeries)
                                .frame(height: 104)
                        }
                    }
                }
                .card()
            } else if healthDenied {
                connectPrompt(text: "Turn on Apple Health in Settings to see your heart rate and calories for this session.")
            } else {
                connectPrompt(text: "No matching Apple Health workout found for this day.")
            }
        }
    }

    private func vitalStat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundColor(Brand.voltText).font(.system(size: 15))
            Text(value).font(BrandFont.display(22)).foregroundColor(Brand.text).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(BrandFont.body(8, .bold)).tracking(0.5).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity)
    }

    private func connectPrompt(text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.text.square").foregroundColor(Brand.mute).font(.system(size: 22))
            Text(text).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private func loadVitals() async {
        guard workout.completed, vitals == nil, !loadingVitals else { return }
        loadingVitals = true

        // Demo mode: show representative vitals without touching HealthKit (which
        // returns nothing in the simulator / App Store review anyway).
        if store.isDemoMode || APIConfig.useMock {
            try? await Task.sleep(nanoseconds: 500_000_000)   // brief "reading…" beat
            vitals = MockData.vitals(for: workout)
            loadingVitals = false
            return
        }

        // Auto-ask on first completed workout.
        if !health.authorizationRequested {
            let granted = await health.requestAuthorization()
            if !granted { healthDenied = true; loadingVitals = false; return }
        }
        let v = await health.vitals(near: workout.date)
        vitals = v
        loadingVitals = false
        // Sync to server so the coach sees it (Phase 1 — client + coach).
        if let v { store.uploadWorkoutVitals(workoutId: workout.id, vitals: v) }
    }
}

// A minimal heart-rate line for the session.
// A small heart-rate chart for the session: Y-axis has several labelled BPM
// gridlines you can read a value off, X-axis is elapsed time (start → end).
struct HeartRateSparkline: View {
    let samples: [HeartRateSample]

    private var bpms: [Double] { samples.map { Double($0.bpm) } }
    private var totalMinutes: Int {
        guard let first = samples.first?.time, let last = samples.last?.time else { return 0 }
        return max(1, Int(last.timeIntervalSince(first) / 60))
    }

    // Padded min/max for the plot, and evenly-spaced "nice" tick values between them.
    private var lo: Double { (bpms.min() ?? 60) - 4 }
    private var hi: Double { (bpms.max() ?? 160) + 4 }
    private var ticks: [Int] {
        let count = 4                                   // → 5 gridlines
        let step = (hi - lo) / Double(count)
        return (0...count).map { Int((lo + step * Double($0)).rounded()) }.reversed()
    }

    var body: some View {
        GeometryReader { geo in
            let range = max(hi - lo, 1)
            let axisW: CGFloat = 30

            ZStack(alignment: .topLeading) {
                // Labelled gridlines — one per tick, positioned by its BPM value.
                ForEach(ticks, id: \.self) { bpm in
                    let y = (geo.size.height - 16) * (1 - (Double(bpm) - lo) / range)
                    HStack(spacing: 6) {
                        Text("\(bpm)")
                            .font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute)
                            .frame(width: axisW - 6, alignment: .trailing)
                        Rectangle().fill(Brand.line).frame(height: 1)
                    }
                    .offset(y: y)
                }

                // The heart-rate curve, drawn in the plot area (right of the axis).
                Path { p in
                    let plotW = geo.size.width - axisW
                    let plotH = geo.size.height - 16
                    for (i, bpm) in bpms.enumerated() {
                        let x = axisW + plotW * (bpms.count <= 1 ? 0 : Double(i) / Double(bpms.count - 1))
                        let y = plotH * (1 - (bpm - lo) / range)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // X-axis time labels along the bottom.
                HStack {
                    Text("0:00")
                    Spacer()
                    Text("\(totalMinutes / 2) min")
                    Spacer()
                    Text("\(totalMinutes) min")
                }
                .font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute)
                .padding(.leading, axisW)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

// MARK: - Exercise detail with per-set RPE + logging + client notes
struct ExerciseDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var exercise: Exercise
    var sessionVitals: WorkoutVitals? = nil
    @State private var showHistory = false
    @State private var showForm = false

    // Per-set heart rate for the by-set chart. Only sets that were actually performed
    // (have logged reps) are plotted. On device this slices the session's HR stream to
    // each set's time window (using the set's loggedAt); demo mode uses mock numbers.
    struct SetHR: Identifiable { let id: String; let setNumber: Int; let avg: Int; let peak: Int }
    private var setHRPoints: [SetHR] {
        let performed = exercise.sets.enumerated().filter { $0.element.loggedReps != nil }
        guard !performed.isEmpty else { return [] }

        // Real path: slice the session HR series between consecutive set timestamps.
        if let series = sessionVitals?.heartRateSeries, series.count > 1 {
            let stamped = performed.compactMap { pair -> (Int, ExerciseSet, Date)? in
                guard let at = pair.element.loggedAt else { return nil }
                return (pair.offset, pair.element, at)
            }.sorted { $0.2 < $1.2 }
            if !stamped.isEmpty {
                var out: [SetHR] = []
                for (i, item) in stamped.enumerated() {
                    // Window: from the previous set's stamp (or session start) to this stamp.
                    let from = i == 0 ? (sessionVitals?.start ?? item.2.addingTimeInterval(-90)) : stamped[i - 1].2
                    let to = item.2
                    if let hr = HealthKitManager.heartRate(in: series, from: from, to: to) {
                        out.append(SetHR(id: item.1.id, setNumber: i + 1, avg: hr.avg, peak: hr.peak))
                    }
                }
                if !out.isEmpty { return out }
            }
        }

        // Demo / fallback.
        guard store.isDemoMode || APIConfig.useMock else { return [] }
        let total = performed.count
        return performed.enumerated().map { i, pair in
            let (_, set) = pair
            let hr = MockData.setHR(exerciseName: exercise.name, setId: set.id, setIndex: i, totalSets: total)
            return SetHR(id: set.id, setNumber: i + 1, avg: hr.avg, peak: hr.peak)
        }
    }

    private var setHRChart: some View {
        Chart {
            ForEach(setHRPoints) { p in
                LineMark(x: .value("Set", p.setNumber), y: .value("Peak", p.peak),
                         series: .value("Metric", "Peak"))
                    .foregroundStyle(Brand.voltLine).symbol(Circle()).symbolSize(40)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(setHRPoints) { p in
                LineMark(x: .value("Set", p.setNumber), y: .value("Avg", p.avg),
                         series: .value("Metric", "Avg"))
                    .foregroundStyle(Color(hex: 0x3D9BE0)).symbol(Circle()).symbolSize(40)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale(["Peak": Brand.voltLine, "Avg": Color(hex: 0x3D9BE0)])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: setHRPoints.map { $0.setNumber }) { value in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel {
                    if let n = value.as(Int.self) { Text("Set \(n)").foregroundStyle(Brand.mute) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel().foregroundStyle(Brand.mute)
            }
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text(label).font(BrandFont.body(12, .medium)).foregroundColor(Brand.mute)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(exercise.name).font(BrandFont.display(34)).foregroundColor(Brand.text)
                    Text(exercise.muscleGroup.uppercased()).font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()

                    section("Description", exercise.description)
                    section("Coach Notes", exercise.coachNotes, highlight: true)

                    // Proper form — only appears when the trainer has written cueing for
                    // this lift, so it never shows an empty card.
                    if !exercise.formInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) { showForm.toggle() }
                            } label: {
                                HStack {
                                    Image(systemName: "figure.strengthtraining.traditional").foregroundColor(Brand.voltText)
                                    Text("Proper Form").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                    Spacer()
                                    Image(systemName: showForm ? "chevron.up" : "chevron.down").foregroundColor(Brand.voltText)
                                }
                                .padding(.vertical, 16).padding(.horizontal, 18)
                                .background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                            }
                            if showForm {
                                Text(exercise.formInstructions)
                                    .font(BrandFont.body(14))
                                    .foregroundColor(Brand.mute)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(18)
                                    .background(Brand.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                                    .padding(.top, 8)
                            }
                        }
                    }
                    if let link = exercise.videoUrl, let url = URL(string: link) {
                        // Demo video from your coach's exercise library (Oct 8, 2026)
                        Link(destination: url) {
                            Label("Watch the demo", systemImage: "play.rectangle.fill")
                                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.voltText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14).padding(.horizontal, 18)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.black))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                        }
                    }

                    // Sets
                    Text("YOUR PLAN").font(BrandFont.body(12, .bold)).tracking(1.5).headerPill()
                    ForEach($exercise.sets) { $set in
                        SetRow(set: $set,
                               number: (exercise.sets.firstIndex(where: {$0.id == set.id}) ?? 0) + 1,
                               restSeconds: exercise.restSeconds,
                               targetText: SetTarget.text(set, in: exercise))
                    }

                    // Heart rate by set (shown once the exercise has been performed).
                    if !setHRPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("HEART RATE BY SET").font(BrandFont.body(12, .bold)).tracking(1.5).headerPill()
                            setHRChart.frame(height: 170)
                            HStack(spacing: 20) {
                                legendDot(Brand.volt, "Peak BPM")
                                legendDot(Color(hex: 0x3D9BE0), "Avg BPM")
                                Spacer()
                            }
                        }
                    }

                    // History (collapsible) — tap to reveal past sessions + trend graph
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showHistory.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: "chart.line.uptrend.xyaxis").foregroundColor(Brand.voltText)
                                Text("History & Progress").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                Spacer()
                                Image(systemName: showHistory ? "chevron.up" : "chevron.down").foregroundColor(Brand.voltText)
                            }
                            .padding(.vertical, 16).padding(.horizontal, 18)
                            .background(Brand.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                        }
                        if showHistory {
                            ExerciseHistoryView(exerciseName: exercise.name)
                                .padding(.top, 16)
                        }
                    }

                    // Client notes
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR NOTES").font(BrandFont.body(12, .bold)).tracking(1.5).headerPill()
                        Text("Your coach can see these.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        TextEditor(text: $exercise.clientNotes)
                            .frame(height: 100).scrollContentBackground(.hidden)
                            .padding(10).background(Brand.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                            .foregroundColor(Brand.text)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .tapToDismissKeyboard()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.foregroundColor(Brand.voltText).fontWeight(.bold)
                }
            }
            .keyboardDoneButton()
        }
    }

    /// Writes the logged reps/weight/RPE back into the store (this view edits a COPY),
    /// pushes each set to the server, then checks whether the session earned a PR.
    private func save() {
        guard let wi = store.workouts.firstIndex(where: { w in
            w.exercises.contains(where: { $0.id == exercise.id })
        }), let ei = store.workouts[wi].exercises.firstIndex(where: { $0.id == exercise.id })
        else { dismiss(); return }

        // Timestamp any set that now has logged data but wasn't stamped yet.
        // These timestamps let us later slice the workout's heart-rate stream
        // per-exercise from HealthKit.
        let now = Date()
        for i in exercise.sets.indices {
            let s = exercise.sets[i]
            let hasData = s.loggedReps != nil || s.loggedWeight != nil || s.rpe != nil
            if hasData && s.loggedAt == nil { exercise.sets[i].loggedAt = now }
        }

        store.workouts[wi].exercises[ei] = exercise
        store.saveLoggedSets(workoutId: store.workouts[wi].id, exercise: exercise)
        store.checkForPRs(in: store.workouts[wi])
        dismiss()
    }

    func section(_ title: String, _ body: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(BrandFont.body(12, .bold)).tracking(1.5).headerPill()
            if highlight {
                Text(body).font(BrandFont.body(15)).foregroundColor(Brand.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
            } else {
                // Plain body copy — no card, no rounding, no clip (clipping was
                // cutting the descenders and reading as an unwanted rounded box).
                Text(body).font(BrandFont.body(15)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Single set row with RPE selector
struct SetRow: View {
    @Binding var set: ExerciseSet
    let number: Int
    var restSeconds: Int = 90
    var targetText: String? = nil      // "1 @ RPE 8.5", "3 × 170 lb" (SetTarget)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SET \(number)").font(BrandFont.display(20)).foregroundColor(Brand.text)
                Spacer()
                Text("Target: \(targetText ?? "\(set.targetReps) × \(Int(set.targetWeight))lb")")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            }
            HStack(spacing: 12) {
                logField("Reps", value: Binding(
                    get: { set.loggedReps.map(String.init) ?? "" },
                    set: { set.loggedReps = Int($0) }))
                logField("Weight", value: Binding(
                    get: { set.loggedWeight.map { String(Int($0)) } ?? "" },
                    set: { set.loggedWeight = Double($0) }))
            }
            // RPE 1-10
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DIFFICULTY (RPE 1-10)").font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
                    Spacer()
                    // Half steps: tap a number, then ½ to add half.
                    if let r = set.rpe, r < 10 {
                        Button { set.rpe = r == r.rounded() ? r + 0.5 : r.rounded(.down) } label: {
                            Text(r == r.rounded() ? "+½" : "\(r.rpeText) ✓").font(BrandFont.body(11, .bold))
                                .foregroundColor(r == r.rounded() ? Brand.voltText : Brand.onVolt)
                                .padding(.horizontal, 10).frame(minHeight: 28)
                                .background(Capsule().fill(r == r.rounded() ? Color.clear : Brand.volt))
                                .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
                        }
                        .accessibilityLabel(r == r.rounded() ? "Add half a point" : "Remove the half point")
                    }
                }
                HStack(spacing: 5) {
                    ForEach(1...10, id: \.self) { n in
                        let on = set.rpe.map { Int($0) == n } ?? false
                        Button { set.rpe = Double(n) } label: {
                            Text("\(n)").font(BrandFont.body(13, .bold))
                                .foregroundColor(on ? Brand.onVolt : Brand.white)
                                .frame(width: 30, height: 30)
                                .background(on ? Brand.volt : Brand.bg)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Brand.line, lineWidth: 1))
                        }
                    }
                }
            }
            // Done -> inline rest countdown fills across this button
            InlineRestButton(restSeconds: restSeconds)
        }
        .card()
    }

    func logField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
            TextField("", text: value)
                .keyboardType(.numberPad).foregroundColor(Brand.text)
                .padding(10).background(Brand.bg)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }
}
