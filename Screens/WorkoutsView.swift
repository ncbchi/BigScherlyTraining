import SwiftUI
import Charts

// MARK: - Workouts list (upcoming first, scroll up for UPCOMING header, then past)
struct WorkoutsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Workout?
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
                    // COMPLETED workouts on top — user scrolls UP to reach these.
                    // Oldest first so the most recent completed sits just above UPCOMING.
                    Text("COMPLETED")
                        .font(BrandFont.display(22)).foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Brand.volt).clipShape(Capsule())

                    ForEach(store.pastWorkouts.reversed()) { w in
                        workoutRow(w, upcoming: false)
                    }
                    if store.pastWorkouts.isEmpty {
                        Text("No completed workouts yet.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }

                    // UPCOMING header — this is where the view lands on open.
                    Text("UPCOMING")
                        .font(BrandFont.display(22)).foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Brand.volt).clipShape(Capsule())
                        .padding(.top, 8)
                        .id("upcoming")

                    ForEach(store.upcomingWorkouts) { w in
                        workoutRow(w, upcoming: true)
                    }
                    if store.upcomingWorkouts.isEmpty {
                        Text("Nothing scheduled yet — check back soon.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
            }
            .onAppear {
                // Land on the upcoming section; completed is above, reachable by scrolling up.
                DispatchQueue.main.async {
                    withAnimation(.none) { proxy.scrollTo("upcoming", anchor: .top) }
                }
                // Prompt ONLY when there's actually something to take before a workout
                // today (see SupplementEngine.duePreWorkout), and only once per day —
                // so browsing the Workouts tab doesn't keep re-opening the drawer.
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
        .sheet(item: $selected) { w in
            WorkoutDetailView(workout: w)
        }
        .sheet(isPresented: $showPreWorkoutPrompt) {
            PreWorkoutSupplementPrompt(supplements: preWorkoutDue)
        }
        // Fires only when a logged set earns a throttled PR (see ProgressEngine).
        .sheet(item: $store.prToCelebrate) { pr in
            PRCelebrationView(pr: pr)
        }
    }

    func workoutRow(_ w: Workout, upcoming: Bool) -> some View {
        Button { selected = w } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(w.title).font(BrandFont.display(24)).foregroundColor(.white)
                    Spacer()
                    if !upcoming { Image(systemName: "checkmark.seal.fill").foregroundColor(Brand.volt) }
                }
                Text("\(w.dayOfWeek.uppercased()) · \(w.dateLabel)")
                    .font(BrandFont.body(11, .bold)).tracking(1).foregroundColor(Brand.volt)
                Text(w.exerciseSummary)
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    .multilineTextAlignment(.leading).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .opacity(upcoming ? 1 : 0.72)
        }
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
                        .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    Text(workout.title).font(BrandFont.display(34)).foregroundColor(.white)

                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(workout.exercises) { ex in
                            Button { selectedExercise = ex } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "dumbbell.fill").foregroundColor(Brand.volt).font(.system(size: 20))
                                    Spacer()
                                    Text(ex.name).font(BrandFont.display(20)).foregroundColor(.white).multilineTextAlignment(.leading)
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
                    Button("Done") { dismiss() }.foregroundColor(Brand.volt)
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
                Image(systemName: "heart.fill").foregroundColor(Brand.volt).font(.system(size: 14))
                Text("SESSION VITALS").font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
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
            Image(systemName: icon).foregroundColor(Brand.volt).font(.system(size: 15))
            Text(value).font(BrandFont.display(22)).foregroundColor(.white).minimumScaleFactor(0.6).lineLimit(1)
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
                .stroke(Brand.volt, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

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
                    .foregroundStyle(Brand.volt).symbol(Circle()).symbolSize(40)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(setHRPoints) { p in
                LineMark(x: .value("Set", p.setNumber), y: .value("Avg", p.avg),
                         series: .value("Metric", "Avg"))
                    .foregroundStyle(Color(hex: 0x3D9BE0)).symbol(Circle()).symbolSize(40)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale(["Peak": Brand.volt, "Avg": Color(hex: 0x3D9BE0)])
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
                    Text(exercise.name).font(BrandFont.display(34)).foregroundColor(.white)
                    Text(exercise.muscleGroup.uppercased()).font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)

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
                                    Image(systemName: "figure.strengthtraining.traditional").foregroundColor(Brand.volt)
                                    Text("Proper Form").font(BrandFont.body(15, .bold)).foregroundColor(.white)
                                    Spacer()
                                    Image(systemName: showForm ? "chevron.up" : "chevron.down").foregroundColor(Brand.volt)
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

                    // Sets
                    Text("YOUR PLAN").font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    ForEach($exercise.sets) { $set in
                        SetRow(set: $set,
                               number: (exercise.sets.firstIndex(where: {$0.id == set.id}) ?? 0) + 1,
                               restSeconds: exercise.restSeconds)
                    }

                    // Heart rate by set (shown once the exercise has been performed).
                    if !setHRPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("HEART RATE BY SET").font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
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
                                Image(systemName: "chart.line.uptrend.xyaxis").foregroundColor(Brand.volt)
                                Text("History & Progress").font(BrandFont.body(15, .bold)).foregroundColor(.white)
                                Spacer()
                                Image(systemName: showHistory ? "chevron.up" : "chevron.down").foregroundColor(Brand.volt)
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
                        Text("YOUR NOTES").font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        Text("Your coach can see these.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        TextEditor(text: $exercise.clientNotes)
                            .frame(height: 100).scrollContentBackground(.hidden)
                            .padding(10).background(Brand.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                            .foregroundColor(.white)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .tapToDismissKeyboard()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.foregroundColor(Brand.volt).fontWeight(.bold)
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
            Text(title.uppercased()).font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
            if highlight {
                Text(body).font(BrandFont.body(15)).foregroundColor(.white)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SET \(number)").font(BrandFont.display(20)).foregroundColor(.white)
                Spacer()
                Text("Target: \(set.targetReps) × \(Int(set.targetWeight))lb")
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
                Text("DIFFICULTY (RPE 1-10)").font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
                HStack(spacing: 5) {
                    ForEach(1...10, id: \.self) { n in
                        Button { set.rpe = n } label: {
                            Text("\(n)").font(BrandFont.body(13, .bold))
                                .foregroundColor(set.rpe == n ? Brand.black : Brand.white)
                                .frame(width: 30, height: 30)
                                .background(set.rpe == n ? Brand.volt : Brand.bg)
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
                .keyboardType(.numberPad).foregroundColor(.white)
                .padding(10).background(Brand.bg)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }
}
