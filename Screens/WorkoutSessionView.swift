import SwiftUI
import Combine

// MARK: - Workout session (in progress)
// The screen clients spend the most time on. Top to bottom:
//   progress + Watch status → rest ring (while resting) → every exercise as a card
//   (the current one open) with typed reps / weight / RPE fields → still to come →
//   finish. The Watch pre-fills the reps it detected; everything stays editable.

struct WorkoutSessionView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var watch = WatchBridge.shared
    // Rest + logging live in the session controller, shared with the Lock Screen Live Activity.
    @ObservedObject private var live = LiveSessionController.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bst_units") private var units = "lb"

    let workoutId: String

    @State private var openExercises: Set<String> = []
    @State private var editingSetId: String? = nil
    @State private var confirmFinish = false
    @State private var showWatchStarting = false

    private var workout: Workout? { store.workouts.first { $0.id == workoutId } }
    private var restEnd: Date? { live.restEnd }
    private var restTotal: Int { live.restTotal }

    var body: some View {
        NavigationStack {
            if let w = workout {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(w)
                        if restEnd != nil { restCard(w) }
                        ForEach(Array(w.exercises.enumerated()), id: \.element.id) { i, ex in
                            ExerciseSessionCard(
                                workoutId: w.id, exercise: ex, index: i, total: w.exercises.count,
                                isOpen: openExercises.contains(ex.id),
                                isCurrent: currentExercise(w)?.id == ex.id,
                                editingSetId: $editingSetId,
                                toggle: { toggle(ex.id) },
                                onLog: { st, reps, weight, rpe in log(w, ex, st, reps, weight, rpe) })
                        }
                        WorkoutNotesCard(workout: w)
                        finishButton(w)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                }
                .background(Brand.bg.ignoresSafeArea())
                .scrollDismissesKeyboard(.interactively)
                .keyboardDoneButton()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).foregroundColor(Brand.text)
                        }
                        .accessibilityLabel("Minimise workout")
                    }
                    ToolbarItem(placement: .principal) {
                        Text("WORKOUT IN PROGRESS").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.mute)
                    }
                }
                .toolbarBackground(Brand.bg, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    store.activeWorkoutId = w.id
                    if openExercises.isEmpty, let c = currentExercise(w) { openExercises = [c.id] }
                    live.begin(workoutId: w.id)            // starts the Lock Screen Live Activity
                    // Settings ▸ Keep screen awake (on unless turned off)
                    UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.object(forKey: "bst_keep_awake") as? Bool ?? true
                }
                // A set logged from the Lock Screen moves on to the next exercise here too.
                .onChange(of: currentExercise(w)?.id) { old, new in
                    guard let new, !openExercises.contains(new) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if let old { openExercises.remove(old) }
                        openExercises.insert(new)
                    }
                }
                .onDisappear {
                    if store.activeWorkoutId == w.id { store.activeWorkoutId = nil }
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                .confirmationDialog("Finish this workout?", isPresented: $confirmFinish, titleVisibility: .visible) {
                    Button("Finish anyway") { finish(w) }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    let left = w.exercises.flatMap { $0.sets }.filter { $0.loggedReps == nil }.count
                    Text("\(left) set\(left == 1 ? " is" : "s are") still unlogged.")
                }
                .sheet(item: $store.prToCelebrate) { pr in PRCelebrationView(pr: pr) }
            } else {
                Text("This workout isn't available.").foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.bg)
            }
        }
        .tint(Brand.volt)
    }

    // MARK: Header

    private func header(_ w: Workout) -> some View {
        let sets = w.exercises.flatMap { $0.sets }
        let done = sets.filter { $0.loggedReps != nil }.count
        let first = sets.compactMap { $0.loggedAt }.min()
        return VStack(alignment: .leading, spacing: 10) {
            Text(w.title).font(BrandFont.display(36)).foregroundColor(Brand.text).lineLimit(2).minimumScaleFactor(0.7)
            HStack {
                Text("\(done) of \(sets.count) sets").font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
                Spacer()
                if let first {
                    Text(first, style: .timer).font(BrandFont.body(12, .semibold)).monospacedDigit().foregroundColor(Brand.mute)
                    Text("elapsed").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                } else {
                    Text("Log your first set to start the clock").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
            }
            DSProgressBar(fraction: sets.isEmpty ? 0 : Double(done) / Double(sets.count))
            watchRow
        }
    }

    @ViewBuilder
    private var watchRow: some View {
        if watch.watchSessionLive {
            HStack(spacing: 8) {
                DSChip(text: "Watch session live", icon: "applewatch")
                if let bpm = watch.liveHeartRate { DSChip(text: "\(bpm) bpm", icon: "heart.fill", color: Brand.danger) }
            }
        } else if watch.isWatchReady {
            Button {
                showWatchStarting = true
                watch.startWatchWorkout { _ in showWatchStarting = false }
            } label: {
                DSChip(text: showWatchStarting ? "Opening on your Watch…" : "Start on Watch — tracks reps & bar speed", icon: "applewatch")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Rest

    private func restCard(_ w: Workout) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let remaining = max(0, Int(ceil((restEnd ?? ctx.date).timeIntervalSince(ctx.date))))
            let frac = restTotal > 0 ? Double(remaining) / Double(restTotal) : 0
            let next = nextSet(w)
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Brand.text.opacity(0.08), lineWidth: 10)
                    Circle().trim(from: 0, to: frac)
                        .stroke(remaining == 0 ? Brand.text : Brand.voltLine, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: frac)
                    VStack(spacing: 0) {
                        Text(remaining == 0 ? "GO" : String(format: "%d:%02d", remaining / 60, remaining % 60))
                            .font(BrandFont.display(30)).foregroundColor(Brand.text).monospacedDigit()
                        Text("OF \(restTotal / 60):\(String(format: "%02d", restTotal % 60))")
                            .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 4) {
                    Text(remaining == 0 ? "REST'S OVER" : "RESTING").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    if let nx = next {
                        Text("Next up").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        Text("\(nx.0.name) · Set \(nx.2)").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text).lineLimit(2)
                        Text("\(nx.1.targetReps) × \(nx.1.targetWeight > 0 ? StatsUnits.weightText(nx.1.targetWeight) : "BW")")
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.voltText)
                    }
                    HStack(spacing: 8) {
                        Button("+30s") { addRest(30) }.buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
                        Button(remaining == 0 ? "Close" : "Skip") { endRest() }.buttonStyle(DSButtonStyle(kind: .primary, fullWidth: false))
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .onChange(of: remaining) { _, r in
                if r == 0 { RestTimerEngine.shared.fireForegroundBell() }
            }
        }
        .card(padding: 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func addRest(_ s: Int) { live.addRest(s) }

    private func endRest() { withAnimation(.spring(response: 0.4)) { live.endRest() } }

    // MARK: Logging

    private func currentExercise(_ w: Workout) -> Exercise? {
        w.exercises.first { $0.sets.contains { $0.loggedReps == nil } }
    }

    private func nextSet(_ w: Workout) -> (Exercise, ExerciseSet, Int)? {
        for ex in w.exercises {
            if let i = ex.sets.firstIndex(where: { $0.loggedReps == nil }) { return (ex, ex.sets[i], i + 1) }
        }
        return nil
    }

    private func toggle(_ id: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if openExercises.contains(id) { openExercises.remove(id) } else { openExercises.insert(id) }
        }
    }

    private func log(_ w: Workout, _ ex: Exercise, _ target: ExerciseSet, _ reps: Int, _ weight: Double, _ rpe: Double?) {
        editingSetId = nil
        withAnimation(.spring(response: 0.4)) {
            _ = live.log(workoutId: w.id, exerciseId: ex.id, setId: target.id, reps: reps, weight: weight, rpe: rpe)
        }
    }

    // MARK: Finish

    private func finishButton(_ w: Workout) -> some View {
        let left = w.exercises.flatMap { $0.sets }.filter { $0.loggedReps == nil }.count
        return Button {
            if left == 0 { finish(w) } else { confirmFinish = true }
        } label: {
            Label(left == 0 ? "Finish workout" : "Finish workout · \(left) left", systemImage: "checkmark")
        }
        .buttonStyle(DSButtonStyle(kind: left == 0 ? .primary : .secondary))
        .padding(.top, 6)
    }

    private func finish(_ w: Workout) {
        live.end()                                   // closes the Lock Screen Live Activity
        if let wi = store.workouts.firstIndex(where: { $0.id == w.id }),
           !store.workouts[wi].exercises.flatMap({ $0.sets }).contains(where: { $0.loggedReps == nil }) {
            store.workouts[wi].completed = true
            store.refreshAwards()
        }
        store.activeWorkoutId = nil
        dismiss()
    }
}

// MARK: - One exercise in the session

struct ExerciseSessionCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var motion = SetMotionStore.shared

    let workoutId: String
    let exercise: Exercise
    let index: Int
    let total: Int
    let isOpen: Bool
    let isCurrent: Bool
    @Binding var editingSetId: String?
    let toggle: () -> Void
    let onLog: (ExerciseSet, Int, Double, Double?) -> Void

    @State private var showForm = false

    private var done: Int { exercise.sets.filter { $0.loggedReps != nil }.count }
    private var activeSetId: String? { exercise.sets.first { $0.loggedReps == nil }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1) OF \(total)\(exercise.muscleGroup.isEmpty ? "" : " · \(exercise.muscleGroup.uppercased())")")
                            .font(BrandFont.body(9, .bold)).tracking(1.2).foregroundColor(isCurrent ? Brand.voltText : Brand.mute)
                        Text(exercise.name).font(BrandFont.display(isOpen ? 28 : 22)).foregroundColor(Brand.text)
                            .multilineTextAlignment(.leading)
                        if !isOpen {
                            Text("\(exercise.sets.count) × \(exercise.sets.first?.targetReps ?? 0) · \(exercise.sets.first.map { $0.targetWeight > 0 ? StatsUnits.weightText($0.targetWeight) : "BW" } ?? "")")
                                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(exercise.sets) { s in
                            Circle().fill(s.loggedReps != nil ? Brand.volt : Color.clear)
                                .overlay(Circle().stroke(s.loggedReps != nil ? Brand.voltLine : Brand.line, lineWidth: 1.5))
                                .frame(width: 8, height: 8)
                        }
                    }
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.mute)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                chipsRow
                VStack(spacing: 8) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { i, s in
                        if s.id == activeSetId || s.id == editingSetId {
                            SetEntryRow(workoutId: workoutId, exercise: exercise, target: s, number: i + 1,
                                        isEditing: s.loggedReps != nil,
                                        onLog: { r, w, rpe in onLog(s, r, w, rpe) },
                                        onCancel: { editingSetId = nil })
                        } else if s.loggedReps != nil {
                            doneRow(s, i + 1)
                        } else {
                            todoRow(s, i + 1)
                        }
                    }
                }
                formAndNotes
                NavigationLink {
                    StatsDetailView(subject: .exercise(exercise.name))
                } label: {
                    DSListRow(title: "History & bar speed", subtitle: "Every \(exercise.name) session, charted", icon: "chart.line.uptrend.xyaxis")
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(16)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isCurrent ? Brand.voltLine.opacity(0.55) : Brand.line, lineWidth: 1))
    }

    // MARK: Context chips

    @ViewBuilder
    private var chipsRow: some View {
        let history = store.history(for: exercise.name).filter { $0.id != workoutId }
        let last = history.last
        let best = history.map { $0.estimatedOneRepMax }.max()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let last, let top = last.sets.max(by: { $0.weight < $1.weight }) {
                    DSChip(text: "Last time \(top.reps) × \(StatsUnits.weightText(top.weight, unit: false)) · \(last.date.formatted(.dateTime.month(.abbreviated).day()))",
                           icon: "clock.arrow.circlepath", color: Brand.mute)
                }
                if let best, best > 0 {
                    DSChip(text: "Est. 1RM \(StatsUnits.weightText(best))", icon: "trophy.fill")
                }
                DSChip(text: "Rest \(exercise.restSeconds / 60):\(String(format: "%02d", exercise.restSeconds % 60))", icon: "timer", color: Brand.mute)
            }
        }
    }

    // MARK: Rows

    private func doneRow(_ s: ExerciseSet, _ n: Int) -> some View {
        let m = motion.motion(workoutId: workoutId, setId: s.id)
        return Button { editingSetId = s.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt)
                    .frame(width: 28, height: 28).background(Circle().fill(Brand.volt))
                Text("Set \(n)").font(BrandFont.body(13, .bold)).foregroundColor(Brand.mute).frame(width: 46, alignment: .leading)
                Text("\(s.loggedReps ?? 0) × \(StatsUnits.weightText(s.loggedWeight ?? s.targetWeight))")
                    .font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                Spacer()
                if let r = s.rpe { Text("RPE \(r.rpeText)").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText) }
                if let m {
                    Text(String(format: "%.2f m/s", m.meanVelocity)).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                }
                Image(systemName: "pencil").font(.system(size: 11)).foregroundColor(Brand.mute)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit this set")
    }

    private func todoRow(_ s: ExerciseSet, _ n: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                .frame(width: 28, height: 28).overlay(Circle().stroke(Brand.line, lineWidth: 1.5))
            Text("Set \(n)").font(BrandFont.body(13, .bold)).foregroundColor(Brand.mute).frame(width: 46, alignment: .leading)
            Text("\(s.targetReps) × \(s.targetWeight > 0 ? StatsUnits.weightText(s.targetWeight) : "BW") target")
                .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: Form + coach notes + your notes

    @ViewBuilder
    private var formAndNotes: some View {
        let cues = exercise.formInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let coach = exercise.coachNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cues.isEmpty || !coach.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !cues.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showForm.toggle() } } label: {
                        HStack {
                            Text("PROPER FORM").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            Spacer()
                            Text(showForm ? "Hide" : "Show").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                            Image(systemName: showForm ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.mute)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showForm {
                        Text(cues).font(BrandFont.body(13)).foregroundColor(Brand.text.opacity(0.9))
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !coach.isEmpty {
                    if !cues.isEmpty { Rectangle().fill(Brand.line).frame(height: 1) }
                    Text("COACH NOTES").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    Text(coach).font(BrandFont.body(13)).foregroundColor(Brand.text.opacity(0.9))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.04)))
        }
    }
}

// MARK: - The set being logged (or edited)
// Typed number fields for reps, weight and RPE. Starts from the plan (or the last
// set's weight); the Watch fills in the reps it detected, with a note saying so.

struct SetEntryRow: View {
    @ObservedObject private var watch = WatchBridge.shared
    @AppStorage("bst_units") private var units = "lb"

    let workoutId: String
    let exercise: Exercise
    let target: ExerciseSet
    let number: Int
    let isEditing: Bool
    let onLog: (Int, Double, Double?) -> Void
    let onCancel: () -> Void

    @State private var reps = ""
    @State private var weight = ""
    @State private var rpe = ""
    @State private var loaded = false
    @State private var fromWatch: WatchBridge.LiveDetection? = nil
    @FocusState private var focus: Field?

    enum Field { case reps, weight, rpe }

    private var isKg: Bool { units == "kg" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.voltText)
                    .frame(width: 28, height: 28).overlay(Circle().stroke(Brand.voltLine, lineWidth: 2))
                Text(isEditing ? "Edit set \(number)" : "Set \(number)").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                Spacer()
                if let d = fromWatch {
                    DSChip(text: String(format: "Watch: %d reps · %.2f m/s", d.reps, d.meanVelocity), icon: "applewatch", filled: true)
                } else if watch.watchSessionLive && !isEditing {
                    DSChip(text: "Watch will fill reps", icon: "applewatch")
                }
            }

            HStack(spacing: 10) {
                field("REPS", text: $reps, placeholder: "\(target.targetReps)", keyboard: .numberPad, f: .reps)
                field(isKg ? "KG" : "LB", text: $weight,
                      placeholder: StatsUnits.weightText(target.targetWeight, unit: false), keyboard: .decimalPad, f: .weight)
                field("RPE", text: $rpe, placeholder: "1–10", keyboard: .decimalPad, f: .rpe)
            }

            HStack(spacing: 8) {
                if isEditing {
                    Button("Cancel", action: onCancel).buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
                }
                Button { submit() } label: {
                    Label(isEditing ? "Save changes" : "Log set", systemImage: "checkmark")
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.voltLine, lineWidth: 1.5))
        .onAppear(perform: prefill)
        .onReceive(watch.$lastDetection) { d in applyWatch(d) }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType, f: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Brand.mute.opacity(0.6)))
                .keyboardType(keyboard)
                .focused($focus, equals: f)
                .font(BrandFont.display(26)).foregroundColor(Brand.text)
                .multilineTextAlignment(.center)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == f ? Brand.voltLine : Brand.line, lineWidth: focus == f ? 2 : 1))
                .accessibilityLabel(label == "RPE" ? "RPE, 1 to 10" : label)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Prefill

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        if isEditing {
            reps = target.loggedReps.map(String.init) ?? ""
            weight = target.loggedWeight.map { display($0) } ?? ""
            rpe = target.rpe.map { $0.rpeText } ?? ""
            return
        }
        reps = "\(target.targetReps)"
        // Carry the weight used on the previous set of this exercise, else the plan.
        let prev = exercise.sets.last { $0.loggedWeight != nil && $0.id != target.id }?.loggedWeight
        weight = display(prev ?? target.targetWeight)
        applyWatch(watch.lastDetection)
    }

    private func applyWatch(_ d: WatchBridge.LiveDetection?) {
        guard let d, !isEditing, d.workoutId == workoutId,
              d.exerciseId == nil || d.exerciseId == exercise.id,
              d.setId == nil || d.setId == target.id else { return }
        // Only very recent detections (the set you just did).
        guard Date().timeIntervalSince(d.receivedAt) < 600 else { return }
        withAnimation(.spring(response: 0.3)) {
            reps = "\(d.reps)"
            fromWatch = d
        }
    }

    private func display(_ lb: Double) -> String {
        let v = StatsUnits.weight(lb)
        return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    private func submit() {
        let r = Int(reps) ?? target.targetReps
        let typed = Double(weight.replacingOccurrences(of: ",", with: "."))
        let w = typed.map { isKg ? $0 / 0.45359237 : $0 } ?? target.targetWeight
        // Half steps: 8.3 → 8.5, 8.7 → 8.5. Comma or point.
        let p = Double(rpe.replacingOccurrences(of: ",", with: ".")).map { min(10, max(1, ($0 * 2).rounded() / 2)) }
        focus = nil
        onLog(r, w, p)
    }
}

// MARK: - Notes for this workout
// Oval pickers across the top choose what the note is about: "General" (the whole
// workout) or one exercise. Notes are kept on this device right away; exercise notes
// also go into the exercise itself so the workout summary shows them.

struct WorkoutNotesCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var notes = WorkoutNoteStore.shared
    let workout: Workout

    @State private var target: String = WorkoutNoteStore.general
    @FocusState private var editing: Bool

    /// The exercise being worked on (first with an unlogged set), or General when all are done.
    private var currentTarget: String {
        workout.exercises.first { $0.sets.contains { $0.loggedReps == nil } }?.id ?? WorkoutNoteStore.general
    }

    private var targets: [(id: String, name: String)] {
        var list: [(id: String, name: String)] = [(id: WorkoutNoteStore.general, name: "General")]
        for ex in workout.exercises { list.append((id: ex.id, name: ex.name)) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR NOTES").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
                Spacer()
                let count = targets.filter { !text(for: $0.id).isEmpty }.count
                if count > 0 {
                    Text("\(count) written").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            }

            // Follows the exercise you're on; swipe to General or another exercise any time.
            DSCarousel(options: targets.map { DSCarousel<String>.Option(id: $0.id, label: $0.name, marked: !text(for: $0.id).isEmpty) },
                       selection: $target, itemWidth: 150, accessibilityName: "Note for")

            ZStack(alignment: .topLeading) {
                if text(for: target).isEmpty {
                    Text(target == WorkoutNoteStore.general
                         ? "How did the whole session feel? Energy, sleep, anything your coach should know…"
                         : "Anything about this lift — how it moved, pain, form, what to change next time…")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute.opacity(0.7))
                        .padding(.horizontal, 15).padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
                TextEditor(text: binding(for: target))
                    .focused($editing)
                    .font(BrandFont.body(14)).foregroundColor(Brand.text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 120)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(editing ? Brand.voltLine : Brand.line, lineWidth: editing ? 2 : 1))
        }
        // Open on the exercise you're on, and move along with you to the next one —
        // but never switch while you're typing a note.
        .onAppear { target = currentTarget }
        .onChange(of: currentTarget) { _, new in
            guard !editing else { return }
            withAnimation(.snappy(duration: 0.3)) { target = new }
        }
        .padding(16)
        .background(Brand.card.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
    }

    private func text(for id: String) -> String {
        if let saved = notes.note(workoutId: workout.id, target: id) { return saved }
        // Exercise notes may already exist from the server.
        return workout.exercises.first { $0.id == id }?.clientNotes ?? ""
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { text(for: id) },
            set: { newValue in
                notes.set(newValue, workoutId: workout.id, target: id)
                // Mirror exercise notes into the exercise so the workout summary shows them.
                guard id != WorkoutNoteStore.general,
                      let wi = store.workouts.firstIndex(where: { $0.id == workout.id }),
                      let ei = store.workouts[wi].exercises.firstIndex(where: { $0.id == id }) else { return }
                store.workouts[wi].exercises[ei].clientNotes = newValue
            })
    }
}

/// Workout + exercise notes, kept on this device until the server stores them.
/// Keyed "workoutId|general" or "workoutId|exerciseId". Cleared on logout.
@MainActor
final class WorkoutNoteStore: ObservableObject {
    static let shared = WorkoutNoteStore()
    static let general = "general"

    @Published private(set) var notes: [String: String]
    private let key = "bst_workout_notes"

    private init() {
        notes = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func note(workoutId: String, target: String) -> String? { notes["\(workoutId)|\(target)"] }

    /// `sync: false` is for restoring from the server — it mustn't be sent straight back.
    func set(_ text: String, workoutId: String, target: String, sync: Bool = true) {
        let k = "\(workoutId)|\(target)"
        if text.isEmpty { notes.removeValue(forKey: k) } else { notes[k] = text }
        UserDefaults.standard.set(notes, forKey: key)
        guard sync else { return }
        ServerSync.shared.mark(target == Self.general
                               ? .workoutNote(workoutId: workoutId)
                               : .exerciseNote(workoutId: workoutId, exerciseId: target))
    }

    func reset() {
        notes = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}
