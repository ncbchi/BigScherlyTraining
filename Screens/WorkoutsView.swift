import SwiftUI
import Charts

// MARK: - Workouts list
// Completed sits above (scroll up to reach it); the screen lands on Upcoming.
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

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DSSectionHeader(title: "COMPLETED", subtitle: "\(store.pastWorkouts.count) sessions")
                    ForEach(store.pastWorkouts.reversed()) { w in completedRow(w) }
                    if store.pastWorkouts.isEmpty {
                        Text("No completed workouts yet.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }

                    // This is where the screen lands.
                    DSScreenHeader(eyebrow: "Training", title: "Workouts")
                        .padding(.top, 28)
                        .id("upcoming")
                    // A coach programs himself, same builder he uses for clients.
                    if store.isTrainer, store.selfClientId != nil {
                        Button { building = true } label: { Label("Plan a workout", systemImage: "plus") }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                    DSSectionHeader(title: "UPCOMING", subtitle: store.upcomingWorkouts.isEmpty ? nil : "\(store.upcomingWorkouts.count) planned")
                    ForEach(store.upcomingWorkouts) { w in upcomingRow(w) }
                    if store.upcomingWorkouts.isEmpty {
                        Text("Nothing scheduled yet — check back soon.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
            }
            .background(Brand.bg.ignoresSafeArea())
            .dsTopFade()
            .sheet(isPresented: $building) {
                if let me = store.selfClientId {
                    WorkoutBuilderView(clientId: me, clientName: "") { store.loadAllFromAPI() }
                }
            }
            .onAppear {
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
        .sheet(item: $selected) { w in WorkoutDetailView(workout: w) }
        .sheet(isPresented: $showPreWorkoutPrompt) {
            PreWorkoutSupplementPrompt(supplements: preWorkoutDue)
        }
        // Fires only when a logged set earns a throttled PR (see ProgressEngine).
        .sheet(item: Binding(get: { (store.sessionWorkoutId == nil || store.sessionMinimized) ? store.prToCelebrate : nil },
                             set: { store.prToCelebrate = $0 })) { pr in PRCelebrationView(pr: pr).sheetFitsContent() }
    }

    // MARK: Rows

    private func upcomingRow(_ w: Workout) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(w.date)
        let sets = w.exercises.reduce(0) { $0 + $1.sets.count }
        let logged = w.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        return Button { store.openSession(w.id) } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    Text(w.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(BrandFont.body(10, .heavy)).tracking(1)
                    Text("\(cal.component(.day, from: w.date))").font(BrandFont.display(28))
                }
                .foregroundColor(isToday ? Brand.onVolt : Brand.text)
                .frame(width: 54, height: 62)
                .background(RoundedRectangle(cornerRadius: 14).fill(isToday ? Brand.volt : Brand.text.opacity(0.06)))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if isToday { DSChip(text: "Today", color: Brand.volt, filled: true) }
                        if logged > 0 { DSChip(text: "In progress · \(logged)/\(sets)", icon: "play.fill") }
                    }
                    Text(w.title).font(BrandFont.display(22)).foregroundColor(Brand.text).multilineTextAlignment(.leading)
                    Text(w.exerciseSummary).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text("\(w.exercises.count) exercises · \(sets) sets").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
                    .padding(.top, 4)
            }
            .padding(14)
            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(isToday ? Brand.voltLine.opacity(0.6) : Brand.line, lineWidth: isToday ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func completedRow(_ w: Workout) -> some View {
        let cal = Calendar.current
        let volume = w.exercises.flatMap { $0.sets }.compactMap { s -> Double? in
            guard let r = s.loggedReps, let wt = s.loggedWeight else { return nil }
            return Double(r) * wt
        }.reduce(0, +)
        let sets = w.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        let prs = store.personalRecords.filter { cal.isDate($0.date, inSameDayAs: w.date) }.count
        return Button { selected = w } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt)
                    .frame(width: 28, height: 28).background(Circle().fill(Brand.volt))
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.title).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text).lineLimit(1)
                    Text("\(w.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(sets) sets · \(StatsUnits.weightText(volume))")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                }
                Spacer()
                if prs > 0 { DSChip(text: prs == 1 ? "PR" : "\(prs) PRs", icon: "trophy.fill") }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.mute)
            }
            .padding(12)
            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
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
