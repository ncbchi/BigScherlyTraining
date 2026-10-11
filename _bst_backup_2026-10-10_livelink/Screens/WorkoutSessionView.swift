import SwiftUI
import Combine
import Charts
import UIKit

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
    @ObservedObject private var setup = SetupEngine.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_hand") private var hand = "right"      // the dock chevron sits on the thumb side

    let workoutId: String
    /// Set when the session is hosted as a floating card: the chevron docks it,
    /// finishing closes it. Unset (e.g. a preview sheet) falls back to dismiss().
    var onMinimize: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var openExercises: Set<String> = []
    @State private var editingSetId: String? = nil
    @State private var confirmFinish = false
    @State private var showWatchStarting = false
    @State private var cardHidden = false          // the live card scrolled away: pin its status bar

    private var workout: Workout? { store.workouts.first { $0.id == workoutId } }

    var body: some View {
        NavigationStack {
            if let w = workout {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleRow(w)
                        // Phase 3: the live card — status bar over a full metric window.
                        VStack(spacing: 10) {
                            LiveCard(workout: w) { editNext(w, proxy) }
                            LiveSetCard(workout: w) { editNext(w, proxy) }      // next set · rest · lifting · log
                        }
                        .id("liveCard")
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 70 } action: { hidden in
                            withAnimation(.easeOut(duration: 0.2)) { cardHidden = hidden }
                        }
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
                // Already at the top and still pulling down: dock the card.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                    if y < -80, onMinimize != nil { minimise() }
                }
                // Scrolled past the card: its status bar stays pinned. Tap it to scroll back up.
                .overlay(alignment: .top) {
                    if cardHidden {
                        VStack(spacing: 0) {
                            LiveStatusBar(workout: w)
                            Rectangle().fill(Brand.line).frame(height: 1)
                            LiveSetCard(workout: w, compact: true) { editNext(w, proxy) }
                        }
                            .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
                            .padding(.horizontal, 16).padding(.top, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.spring(response: 0.4)) { proxy.scrollTo("liveCard", anchor: .top) } }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                // Edit (the Lock Screen card's, or the live card's): straight to that set's row — the
                // row selects its reps and brings up the number pad.
                .onAppear { if let id = live.editRequest { showSet(id, w, proxy) } }
                .onChange(of: live.editRequest) { _, id in if let id { showSet(id, w, proxy) } }
                }
                .scrollDismissesKeyboard(.interactively)
                .keyboardDoneButton()
                .toolbar {
                    ToolbarItem(placement: hand == "left" ? .topBarLeading : .topBarTrailing) {
                        Button { minimise() } label: {
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
                    print(String(format: "[Open] card appeared · %.0f ms after tap", Date().timeIntervalSince(AppStore.openTapAt) * 1000))
                    store.activeWorkoutId = w.id
                    if openExercises.isEmpty, let c = currentExercise(w) { openExercises = [c.id] }
                    live.begin(workoutId: w.id)            // starts the Lock Screen Live Activity
                    SetVideoRecorder.shared.screenVisible = true   // set videos only film on this screen
                    // First-time Watch setup — a beat later, once the card has settled, so it
                    // isn't on the critical path of the card appearing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if store.sessionWorkoutId == w.id, !store.sessionMinimized {
                            SetupEngine.shared.considerOffering(workout: w)
                        }
                    }
                    // Settings ▸ Keep screen awake (on unless turned off)
                    UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.object(forKey: "bst_keep_awake") as? Bool ?? true
                    print(String(format: "[Open] onAppear finished · %.0f ms after tap", Date().timeIntervalSince(AppStore.openTapAt) * 1000))
                    DispatchQueue.main.async {
                        print(String(format: "[Open] main thread free again · %.0f ms after tap", Date().timeIntervalSince(AppStore.openTapAt) * 1000))
                    }
                }
                // A set logged from the Lock Screen moves on to the next exercise here too.
                .onChange(of: currentExercise(w)?.id) { old, new in
                    guard let new, !openExercises.contains(new) else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if let old { openExercises.remove(old) }
                        openExercises.insert(new)
                    }
                }
                // The Watch setup: offered between sets — the body setup first, then a lift's the
                // first time it's up next (squat, bench, deadlift). Your theme, the elements in your accent.
                .onChange(of: live.revision) { _, _ in SetupEngine.shared.considerOffering(workout: w) }
                .onReceive(WatchBridge.shared.$watchSessionActive) { _ in SetupEngine.shared.considerOffering(workout: w) }
                .sheet(item: Binding(get: { setup.origin == .workout ? setup.request : nil },
                                     set: { setup.request = $0 })) { _ in
                    SetupSheet()                                   // sizes itself to its content
                        .presentationBackground(Brand.bg)
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled()
                }
                .onDisappear {
                    // Docked, not closed: the Watch keeps pointing at this workout.
                    if store.activeWorkoutId == w.id, store.sessionWorkoutId != w.id { store.activeWorkoutId = nil }
                    UIApplication.shared.isIdleTimerDisabled = false
                    SetVideoRecorder.shared.screenVisible = false   // set videos only film on this screen
                    SetupEngine.shared.withdraw(from: .workout)    // offered again when you reopen it
                }
                .sheet(item: $store.prToCelebrate) { pr in PRCelebrationView(pr: pr).sheetFitsContent() }
            } else {
                Text("This workout isn't available.").foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.bg)
            }
        }
        .tint(Brand.volt)
        // Finish confirmation: the app's own centred card, not a system alert — an
        // alert takes the accent tint for its buttons, which on a translucent alert
        // surface isn't readable.
        .overlay {
            if confirmFinish, let w = workout {
                FinishConfirmCard(
                    left: w.exercises.flatMap { $0.sets }.filter { $0.loggedReps == nil }.count,
                    keepGoing: { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { confirmFinish = false } },
                    finishAnyway: { confirmFinish = false; finish(w) })
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: confirmFinish)
    }

    // MARK: Header

    private func titleRow(_ w: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(w.title).font(BrandFont.display(30)).foregroundColor(Brand.text).lineLimit(2).minimumScaleFactor(0.7)
            if !live.watchConnected { watchRow }
        }
    }

    /// The status bar's Edit: open the next set's exercise and scroll to it.
    private func editNext(_ w: Workout, _ proxy: ScrollViewProxy) {
        guard let nx = nextSet(w) else { return }
        live.requestEdit(setId: nx.1.id)          // the row selects its reps (number pad up)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            openExercises.insert(nx.0.id)
            editingSetId = nx.1.id
            proxy.scrollTo(nx.0.id, anchor: .top)
        }
    }

    /// Edit from the Lock Screen: open the set's exercise and bring its row to the middle — no
    /// animation, it should just be there. A set already logged opens in its edit row.
    private func showSet(_ setId: String, _ w: Workout, _ proxy: ScrollViewProxy) {
        guard let ex = w.exercises.first(where: { $0.sets.contains { $0.id == setId } }) else {
            live.editRequest = nil
            return
        }
        openExercises.insert(ex.id)
        if ex.sets.first(where: { $0.id == setId })?.loggedReps != nil { editingSetId = setId }
        DispatchQueue.main.async { proxy.scrollTo("set-\(setId)", anchor: .center) }
        // The row has picked it up by now (or never will — e.g. the set's gone): don't leave it pending.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if live.editRequest == setId { live.editRequest = nil }
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

    // MARK: Rest (the live card's status bar shows it now)

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
        if let onClose { onClose() } else { dismiss() }
    }

    private func minimise() {
        if let onMinimize { onMinimize() } else { dismiss() }
    }
}

// MARK: - Finish confirmation (centred card)

private struct FinishConfirmCard: View {
    let left: Int
    let keepGoing: () -> Void
    let finishAnyway: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { keepGoing() }
            VStack(alignment: .leading, spacing: 14) {
                Text("Finish this workout?").font(BrandFont.display(28)).foregroundColor(Brand.text)
                Text("\(left) set\(left == 1 ? " is" : "s are") still unlogged.")
                    .font(BrandFont.body(15)).foregroundColor(Brand.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Keep going") { keepGoing() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("Finish anyway") { finishAnyway() }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Brand.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 12)
            .padding(.horizontal, 24)
        }
        .accessibilityAddTraits(.isModal)
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
                            Text(SetTarget.summary(exercise))
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
                                .id("set-\(s.id)")
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
            Text("\(SetTarget.text(s, in: exercise)) target")
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
                        if let link = exercise.videoUrl, let url = URL(string: link) {
                            Link(destination: url) {
                                Label("Watch the demo", systemImage: "play.rectangle.fill")
                                    .font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                            }
                        }
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
    @EnvironmentObject var store: AppStore
    @ObservedObject private var watch = WatchBridge.shared
    @ObservedObject private var live = LiveSessionController.shared
    @AppStorage("bst_units") private var units = "lb"
    @ObservedObject private var gym = GymEquipment.shared      // the set-card barbell redraws when My Gym changes
    @State private var plateRequest: PlateCalcRequest? = nil   // the calculator, opened over the workout itself

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
    @State private var rpeEstimate: String? = nil       // the RPE as estimated (shown as "estimated" until changed)
    @State private var selectOnFocus = false            // Edit: the reps start selected, so typing replaces them
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
                // Barbell lifts and plate-loaded machines: this set's plates, the mirror of the set number.
                if let lift = plateLift {
                    Button { openPlates(lift) } label: {
                        PlateBarIcon(plates: gym.iconPlates(lift: lift, total: weightShown))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Plate calculator")
                }
            }

            HStack(spacing: 10) {
                field("REPS", text: $reps, placeholder: SetTarget.repsText(target), keyboard: .numberPad, f: .reps)
                // A back-off with nothing heavier logged yet: the box is empty and shows its % faded.
                field(isKg ? "KG" : "LB", text: $weight, placeholder: weightPlaceholder, keyboard: .decimalPad, f: .weight)
                // An RPE set: its target, faded, in the empty box.
                field("RPE", text: $rpe, placeholder: target.targetRpe?.rpeText ?? "1–10", keyboard: .decimalPad, f: .rpe,
                      note: rpeEstimate != nil && rpe == rpeEstimate ? "estimated" : nil)
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
        .sheet(item: $plateRequest) { r in
            PlateCalculatorView(request: r).presentationDragIndicator(.visible)
        }
        .onReceive(watch.$lastDetection) { d in applyWatch(d) }
        // Typing in the set that's waiting to be logged: the card (and an auto-log when the next set
        // starts) use your numbers.
        .onChange(of: reps) { _, _ in sendDraft() }
        .onChange(of: weight) { _, _ in sendDraft() }
        .onChange(of: rpe) { _, _ in sendDraft() }
        // The set just finished while this row was showing: fill it in like the card (unless you're typing).
        .onChange(of: live.setAwaitingLog) { _, waiting in
            if waiting, !isEditing, focus == nil { applyPrefill() }
        }
        // Edit (Lock Screen card / live card): fill in the set as the card showed it, select the reps.
        .onReceive(live.$editRequest) { id in
            guard let id, id == target.id else { return }
            if !isEditing { applyPrefill() }
            selectOnFocus = true
            for delay in [0.1, 0.4] {                   // again once the card has finished opening
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard focus == nil else { return }
                    focus = .reps
                    print(String(format: "[Edit] reps selected · %.0f ms after the tap reached the app",
                                 Date().timeIntervalSince(AppStore.openTapAt) * 1000))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { n in
            guard selectOnFocus, focus == .reps, let tf = n.object as? UITextField else { return }
            selectOnFocus = false
            DispatchQueue.main.async { tf.selectAll(nil) }
        }
    }

    // MARK: Plate calculator

    private var plateLift: PlateLift? { PlateLift.of(exercise.name) }

    /// The weight in the box (or its faded planned weight), in your units.
    private var weightShown: Double? {
        if let typed = Double(weight.replacingOccurrences(of: ",", with: ".")) { return typed }
        return SetTarget.shownWeight(target, in: exercise).map { StatsUnits.weight($0) }
    }

    private func openPlates(_ lift: PlateLift) {
        // Opened from here (not the app's root): the workout is already on screen as a sheet,
        // and iOS shows one sheet at a time — from the root it would wait until the workout closed.
        plateRequest = (PlateCalcRequest(
            exerciseName: exercise.name,
            setLabel: "Set \(number) of \(exercise.sets.count)",
            useFor: "Set \(number)",
            startTotal: weightShown,
            lift: lift,
            onUse: { shown in weight = display(StatsUnits.isKg ? shown / 0.45359237 : shown) }))
    }

    /// The faded text in an empty weight box: the planned weight, a back-off's % ("−17%"), or "—".
    private var weightPlaceholder: String {
        if let w = SetTarget.shownWeight(target, in: exercise) { return SetTarget.weightText(w, unit: false) }
        if let p = target.percent { return SetTarget.percentText(p) }
        return "—"
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType, f: Field, note: String? = nil) -> some View {
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
            Text(note ?? " ").font(BrandFont.body(9, .semibold)).foregroundColor(Brand.mute)
                .opacity(note == nil ? 0 : 1)
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
        // A set that's done and waiting to be logged: exactly as the Lock Screen card shows it.
        if live.prefill(forSet: target.id) != nil {
            applyPrefill()
            return
        }
        // AMRAP with no minimum: reps stay empty for you (or the Watch) to fill in.
        reps = SetTarget.isAmrap(target) && target.targetReps <= 0 ? "" : "\(target.targetReps)"
        if SetTarget.isFixed(target) || SetTarget.isBodyweight(target) {
            // Carry the weight used on the previous set of this exercise, else the plan.
            let prev = exercise.sets.last { $0.loggedWeight != nil && $0.id != target.id }?.loggedWeight
            weight = display(prev ?? target.targetWeight)
        } else {
            // Back-off: the heaviest set logged less its % (empty, showing the % faded, until one's logged).
            // RPE: the last weight you used on this lift today, else last session's top set.
            weight = SetTarget.startWeight(target, in: exercise, workoutId: workoutId, workouts: store.workouts)
                .map { display(SetTarget.roundToStep($0)) } ?? ""
        }
        applyWatch(watch.lastDetection)
    }

    /// The finished set as the card fills it in: Watch reps, carried weight, estimated RPE.
    private func applyPrefill() {
        guard let p = live.prefill(forSet: target.id) else { return }
        reps = "\(p.reps)"
        weight = display(p.weightLb)
        rpe = p.rpe.rpeText
        rpeEstimate = rpe
        if let d = watch.lastDetection, d.workoutId == workoutId, Date().timeIntervalSince(d.receivedAt) < 600,
           d.exerciseId == nil || d.exerciseId == exercise.id, d.setId == nil || d.setId == target.id {
            fromWatch = d
        }
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
        SetTarget.weightText(lb, unit: false)          // 76.25, not 76.2
    }

    private func parsed() -> (reps: Int, weightLb: Double, rpe: Double?) {
        let r = Int(reps) ?? target.targetReps
        let typed = Double(weight.replacingOccurrences(of: ",", with: "."))
        let w = typed.map { isKg ? $0 / 0.45359237 : $0 } ?? SetTarget.plannedWeight(target, in: exercise) ?? target.targetWeight
        // Half steps: 8.3 → 8.5, 8.7 → 8.5. Comma or point.
        let p = Double(rpe.replacingOccurrences(of: ",", with: ".")).map { min(10, max(1, ($0 * 2).rounded() / 2)) }
        return (r, w, p)
    }

    /// Only once you've typed (focus is in the row) — not when the row fills itself in.
    private func sendDraft() {
        guard focus != nil, !isEditing else { return }
        let v = parsed()
        live.setDraft(setId: target.id, reps: v.reps, weightLb: v.weightLb, rpe: v.rpe)
    }

    private func submit() {
        // An AMRAP with no minimum needs the reps you did (nothing to fall back on).
        if SetTarget.isAmrap(target), target.targetReps <= 0, Int(reps) == nil { focus = .reps; return }
        // A back-off or RPE set with no weight typed has nothing to fall back on either.
        if !SetTarget.isFixed(target), !SetTarget.isBodyweight(target),
           Double(weight.replacingOccurrences(of: ",", with: ".")) == nil,
           SetTarget.plannedWeight(target, in: exercise) == nil { focus = .weight; return }
        let v = parsed()
        focus = nil
        onLog(v.reps, v.weightLb, v.rpe)
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

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Phase 3 · The live card (kept in this file so no project step is needed)
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Pause targets (the Watch pause buzz and the Pause metric)

/// The bottom pause an exercise asks for. Your own setting (per exercise) wins; otherwise
/// it's read from the programme: "2-sec pause", "pause 2 s", "paused (2s)", or tempo "3-2-1-0".
enum PauseTarget {
    static let overridesKey = "bst_pause_targets"     // [exercise name: seconds]; 0 = off
    static let buzzKey = "bst_pause_buzz"

    /// Settings ▸ Apple Watch ▸ Pause buzz (on unless turned off).
    static var buzzOn: Bool { UserDefaults.standard.object(forKey: buzzKey) as? Bool ?? true }

    static func fromProgram(_ ex: Exercise) -> Double? {
        let text = [ex.name, ex.description, ex.coachNotes, ex.formInstructions].joined(separator: " ").lowercased()
        let patterns = [
            #"(\d+(?:\.\d+)?)\s*-?\s*(?:s|sec|secs|second|seconds|count)\b[^.\n]{0,12}?\bpause"#,
            #"\bpause[sd]?\b[^.\n\d]{0,15}?(\d+(?:\.\d+)?)\s*-?\s*(?:s|sec|secs|second|seconds|count)\b"#,
            #"\btempo[:\s]*\(?\s*(?:\d|x)\s*[-–/]\s*(\d+(?:\.\d+)?)\s*[-–/]\s*(?:\d|x)"#,
        ]
        for p in patterns {
            if let v = firstNumber(p, in: text), v > 0, v <= 10 { return v }
        }
        return nil
    }

    private static func firstNumber(_ pattern: String, in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    static func override(_ ex: Exercise) -> Double? {
        (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Double])?[ex.name]
    }

    /// nil = follow the programme; 0 = off; otherwise seconds.
    static func setOverride(_ seconds: Double?, for ex: Exercise) {
        var d = (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Double]) ?? [:]
        d[ex.name] = seconds
        UserDefaults.standard.set(d, forKey: overridesKey)
    }

    static func target(_ ex: Exercise) -> Double? {
        if let o = override(ex) { return o > 0 ? o : nil }
        return fromProgram(ex)
    }

    /// What the Watch is sent: nothing when the pause buzz is off.
    static func forWatch(_ ex: Exercise) -> Double? { buzzOn ? target(ex) : nil }

    static func text(_ s: Double) -> String { s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s) }
}

// MARK: - The nine metrics

enum LiveMetric: String, CaseIterable, Identifiable {
    case notes, heartRate, speed, tempo, pause, depth, trend, session, sets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: return "Coach notes"
        case .heartRate: return "Heart rate"
        case .speed: return "Bar speed"
        case .tempo: return "Tempo"
        case .pause: return "Pause"
        case .depth: return "Depth"
        case .trend: return "Trend"
        case .session: return "Session"
        case .sets: return "Sets"
        }
    }
    var icon: String {
        switch self {
        case .notes: return "sparkles"
        case .heartRate: return "heart.fill"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .tempo: return "metronome.fill"
        case .pause: return "pause.fill"
        case .depth: return "arrow.down.to.line"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .session: return "sum"
        case .sets: return "list.bullet"
        }
    }
}

// MARK: - Coach notes

struct CoachNote: Identifiable {
    enum Kind: Int { case pr = 0, fix = 1, info = 2, good = 3 }
    let id = UUID()
    let kind: Kind
    let icon: String
    let title: String
    let detail: String

    var color: Color {
        switch kind {
        case .pr, .good: return Brand.voltLine
        case .fix: return Color(hex: 0xF2A03D)
        case .info: return Color(hex: 0x3D9BE0)
        }
    }
}

/// Tips after each set, from what the Watch saw and what you logged. Most useful first.
enum CoachNotes {
    static func epley(_ w: Double, _ r: Int) -> Double { r <= 1 ? w : w * (1 + Double(r) / 30) }

    static func speedLoss(_ v: [Double]) -> Double? {
        guard v.count >= 2, let best = v.prefix(2).max(), best > 0, let last = v.last else { return nil }
        return max(0, (best - last) / best * 100)
    }

    static func make(exercise ex: Exercise, set: ExerciseSet, motion: SetMotion?,
                     pauseTarget: Double?, workouts: [Workout]) -> [CoachNote] {
        var out: [CoachNote] = []
        let reps = motion?.reps ?? []
        let fmt = { (v: Double) in String(format: "%.1f s", v) }

        // Short of the range set in the first-time setup — the same true depth (chest touch,
        // lockout) every rep, or it gets flagged.
        if let cal = LiftCalibration.forExercise(ex.name), cal.fullTravelM > 0, !reps.isEmpty {
            let short = reps.filter { $0.travelM < 0.92 * cal.fullTravelM }
            if !short.isEmpty {
                let list = short.map { "\($0.index)" }.joined(separator: ", ")
                let pct = Int(((short.map(\.travelM).min() ?? 0) / cal.fullTravelM * 100).rounded())
                out.append(CoachNote(kind: .fix, icon: "arrow.down.to.line",
                                     title: short.count == 1 ? "Rep \(list) was short" : "Reps \(list) were short",
                                     detail: "Down to \(pct)% of your full range — \(cal.lift.standard), every rep."))
            }
        }

        // A new estimated PR
        if let r = set.loggedReps, let w = set.loggedWeight, r > 0, w > 0 {
            let e = epley(w, r)
            let when = set.loggedAt ?? Date()
            let prev = workouts.flatMap { $0.exercises }.filter { $0.name == ex.name }.flatMap { $0.sets }
                .filter { $0.id != set.id && ($0.loggedAt ?? .distantPast) < when }
                .compactMap { s -> Double? in
                    guard let r = s.loggedReps, let w = s.loggedWeight, r > 0, w > 0 else { return nil }
                    return epley(w, r)
                }
                .max()
            if let prev, e > prev + 0.5 {
                out.append(CoachNote(kind: .pr, icon: "trophy.fill", title: "New estimated PR · \(StatsUnits.weightText(e))",
                                     detail: "Up \(StatsUnits.weightText(e - prev)) on your best."))
            }
        }

        if !reps.isEmpty {
            // Pause against the target
            let pauses = reps.compactMap { $0.bottomPauseSec }
            if let t = pauseTarget, !pauses.isEmpty {
                let avg = pauses.reduce(0, +) / Double(pauses.count)
                if avg < t - 0.25 {
                    let buzz = PauseTarget.buzzOn ? " Your Watch taps you at \(PauseTarget.text(t))." : ""
                    out.append(CoachNote(kind: .fix, icon: "pause.fill", title: "Pause \(fmt(avg)) — target \(PauseTarget.text(t))",
                                         detail: "Hold the bottom longer.\(buzz)"))
                } else if pauses.count >= 3, let f = pauses.first, let l = pauses.last, f - l >= 0.4 {
                    out.append(CoachNote(kind: .fix, icon: "pause.fill", title: "Your pause got shorter each rep",
                                         detail: "\(fmt(f)) on rep 1, \(fmt(l)) by the last."))
                } else {
                    out.append(CoachNote(kind: .good, icon: "checkmark", title: "Pauses on target",
                                         detail: "Averaged \(fmt(avg)) against \(PauseTarget.text(t))."))
                }
            }

            // Lowering too fast
            let ecc = reps.compactMap { $0.eccentricSec }
            if ecc.count >= 2 {
                let avg = ecc.reduce(0, +) / Double(ecc.count)
                if avg < 0.9 {
                    out.append(CoachNote(kind: .fix, icon: "arrow.down", title: "Lowering was fast (\(fmt(avg)))",
                                         detail: "Control the descent — aim for about 2 s down."))
                }
            }

            // A grinding rep
            if let g = reps.last(where: { $0.isGrind }) {
                out.append(CoachNote(kind: .fix, icon: "tortoise.fill", title: "Rep \(g.index) was a grind",
                                     detail: "That's close to your limit for this weight."))
            }

            // Depth consistency
            let travel = reps.map { $0.travelM }
            if travel.count >= 3 {
                let med = travel.sorted()[travel.count / 2]
                if let shallow = reps.first(where: { med - $0.travelM >= 0.03 && $0.travelM < med * 0.9 }) {
                    out.append(CoachNote(kind: .fix, icon: "arrow.down.to.line",
                                         title: "Rep \(shallow.index) was \(StatsUnits.depthText(med - shallow.travelM)) shallower",
                                         detail: "Hit the same depth every rep."))
                } else if (travel.max() ?? 0) - (travel.min() ?? 0) <= 0.02 {
                    out.append(CoachNote(kind: .good, icon: "checkmark", title: "Depth stayed even",
                                         detail: "Every rep within \(StatsUnits.depthText(0.02))."))
                }
            }

            // Speed loss, and an effort check against the RPE you logged
            if let loss = speedLoss(reps.map { $0.meanVelocity }) {
                let next = set.loggedWeight.map { StatsUnits.weightText($0) } ?? "the same weight"
                if loss >= 30 {
                    out.append(CoachNote(kind: .info, icon: "gauge.with.dots.needle.33percent", title: "Speed dropped \(Int(loss))%",
                                         detail: "Close to your limit — keep \(next) next set and take the full rest."))
                } else if loss >= 15 {
                    out.append(CoachNote(kind: .info, icon: "gauge.with.dots.needle.50percent", title: "Speed dropped \(Int(loss))%",
                                         detail: "A solid working set."))
                } else if reps.count >= 3 {
                    let small = UserDefaults.standard.string(forKey: "bst_weight_step") == "small"
                    let step = StatsUnits.isKg ? (small ? "1.25 kg" : "2.5 kg") : (small ? "2.5 lb" : "5 lb")
                    out.append(CoachNote(kind: .good, icon: "gauge.with.dots.needle.67percent", title: "Speed held (−\(Int(loss))%)",
                                         detail: "Room to add \(step) next set if it felt easy."))
                }
                if let rpe = set.rpe {
                    if rpe <= 7, loss >= 30 {
                        out.append(CoachNote(kind: .fix, icon: "exclamationmark.triangle.fill",
                                             title: "RPE \(rpe.rpeText), but speed dropped like a 9",
                                             detail: "That set may have been harder than it felt."))
                    } else if rpe >= 9, loss < 12 {
                        out.append(CoachNote(kind: .info, icon: "battery.75percent", title: "RPE \(rpe.rpeText), but speed barely dropped",
                                             detail: "You may have more in the tank."))
                    }
                }
            }
        }
        return Array(out.sorted { $0.kind.rawValue < $1.kind.rawValue }.prefix(3))
    }
}

// MARK: - Shared lookups

enum LiveCardData {
    static func nextSet(_ w: Workout) -> (Exercise, ExerciseSet, Int)? {
        for ex in w.exercises {
            if let i = ex.sets.firstIndex(where: { $0.loggedReps == nil }) { return (ex, ex.sets[i], i + 1) }
        }
        return nil
    }

    static func lastLogged(_ w: Workout) -> (Exercise, ExerciseSet, Int)? {
        var best: (Exercise, ExerciseSet, Int, Date)? = nil
        for ex in w.exercises {
            for (i, s) in ex.sets.enumerated() where s.loggedReps != nil {
                let at = s.loggedAt ?? .distantPast
                if best == nil || at > best!.3 { best = (ex, s, i + 1, at) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    static func weightFor(_ ex: Exercise, _ set: ExerciseSet) -> Double {
        if !SetTarget.isFixed(set) && !SetTarget.isBodyweight(set) {
            return SetTarget.plannedWeight(set, in: ex) ?? ex.sets.last(where: { $0.loggedWeight != nil })?.loggedWeight ?? 0
        }
        return ex.sets.last(where: { $0.loggedWeight != nil })?.loggedWeight ?? set.targetWeight
    }

    static func setText(reps: Int, weightLb: Double) -> String {
        "\(reps) × \(weightLb > 0 ? StatsUnits.weightText(weightLb) : "BW")"
    }
}

// MARK: - Status bar (thin: clock, sets, Watch, heart rate)

struct LiveStatusBar: View {
    let workout: Workout
    @ObservedObject private var live = LiveSessionController.shared

    var body: some View {
        let _ = live.revision
        let all = workout.exercises.flatMap { $0.sets }
        HStack(spacing: 6) {
            Circle().fill(live.watchConnected ? Brand.danger : Brand.mute.opacity(0.5)).frame(width: 7, height: 7)
            Text(live.sessionStart(workout), style: .timer)
                .font(BrandFont.body(12, .heavy)).monospacedDigit().foregroundColor(Brand.text)
            Text("· \(all.filter { $0.loggedReps != nil }.count)/\(all.count) sets").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
            Spacer(minLength: 4)
            if live.watchConnected {
                Image(systemName: "applewatch").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.voltText)
            }
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                if let bpm = live.currentHeartRate {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").font(.system(size: 10)).foregroundColor(Brand.danger)
                        Text("\(bpm)").font(BrandFont.body(12, .heavy)).monospacedDigit().foregroundColor(Brand.text)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The set card (its own card, under the live card) — the Lock Screen card's button scheme

struct LiveSetCard: View {
    let workout: Workout
    var compact = false                 // one slim row, for the bar pinned at the top when you scroll
    var onEdit: () -> Void = {}

    @ObservedObject private var live = LiveSessionController.shared
    @ObservedObject private var watch = WatchBridge.shared

    private var tileSize: CGSize { compact ? CGSize(width: 66, height: 44) : CGSize(width: 118, height: 86) }

    var body: some View {
        let _ = live.revision
        let next = LiveCardData.nextSet(workout)
        Group {
            switch live.stage {
            case .resting: TimelineView(.periodic(from: .now, by: 0.25)) { ctx in resting(next, now: ctx.date) }
            case .lifting: if live.setAwaitingLog { logging(next) } else { lifting(next) }
            case .ready: ready(next)
            case .done: finished
            }
        }
        .padding(.horizontal, 14).padding(.vertical, compact ? 9 : 14)
        .frame(maxWidth: .infinity)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 22).fill(Brand.card)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
                    .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
            }
        }
    }

    private func setOf(_ n: (Exercise, ExerciseSet, Int)?) -> String {
        guard let n else { return "" }
        return "SET \(n.2) OF \(n.0.sets.count)"
    }

    // MARK: Stages

    private func ready(_ next: (Exercise, ExerciseSet, Int)?) -> some View {
        row(tile: {
                Button { live.startSet() } label: {
                    filledTile(icon: "play.fill", label: compact ? nil : "Start set \(next?.2 ?? 1)")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start set \(next?.2 ?? 1)")
                .onAppear { if !compact { SetVideoRecorder.shared.warm() } }   // camera ready for the set
            },
            title: next?.0.name ?? "", kicker: setOf(next), kickerColor: Brand.mute,
            value: next.map { SetTarget.text($0.1, in: $0.0) } ?? "",
            valueColor: Brand.voltText) {
            if live.watchConnected {
                Text("or just lift — your Watch starts it").font(BrandFont.body(10, .semibold)).foregroundColor(Brand.mute)
            }
        }
    }

    private func resting(_ next: (Exercise, ExerciseSet, Int)?, now: Date) -> some View {
        let end = live.restEnd ?? now
        let left = max(0, end.timeIntervalSince(now))
        let remaining = Int(ceil(left))
        let frac = live.restTotal > 0 ? min(1, left / Double(live.restTotal)) : 0
        let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        return row(tile: { restTile(frac: frac, clock: clock) },
                   title: next?.0.name ?? "", kicker: "UP NEXT · " + setOf(next), kickerColor: Brand.mute,
                   value: next.map { SetTarget.text($0.1, in: $0.0) } ?? "",
                   valueColor: Brand.voltText) {
            pill("+30s", filled: false) { live.addRest(30) }
            pill("Skip", filled: true) { withAnimation(.spring(response: 0.4)) { live.endRest() } }
        }
        .onChange(of: remaining) { _, r in
            if r == 0 && !compact { RestTimerEngine.shared.fireForegroundBell() }   // once: the card, not the pinned bar
            if r == 10 && !compact { RestTimerEngine.shared.fireForegroundWarning() }
            if r == 12 && !compact { SetVideoRecorder.shared.warm() }          // camera ready for the next set
        }
    }

    private func lifting(_ next: (Exercise, ExerciseSet, Int)?) -> some View {
        let reps = watch.liveReps
        let loss = CoachNotes.speedLoss(reps)
        return row(tile: { liftTile(set: next?.2 ?? 1) },
                   title: next?.0.name ?? "", kicker: setOf(next) + " · LIFTING", kickerColor: Brand.danger,
                   value: reps.isEmpty ? "Waiting for rep 1" : SetTarget.repProgress(reps.count, next?.1),
                   valueColor: Brand.text) {
            if let loss, reps.count >= 2 {
                Text("Speed −\(Int(loss))%").font(BrandFont.body(11, .heavy))
                    .foregroundColor(loss >= 20 ? Color(hex: 0xF2A03D) : Brand.text)
                    .padding(.horizontal, 10).frame(height: 26)
                    .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
            }
        }
        .animation(.spring(response: 0.4), value: reps.count)
    }

    private func logging(_ next: (Exercise, ExerciseSet, Int)?) -> some View {
        // The set as the Lock Screen card shows it: Watch reps, carried weight, estimated RPE.
        let p = next.flatMap { live.prefill(forSet: $0.1.id) }
        let reps = p?.reps ?? watch.lastDetection?.reps ?? next?.1.targetReps ?? 0
        let weight = p?.weightLb ?? next.map { LiveCardData.weightFor($0.0, $0.1) } ?? 0
        let v = watch.lastDetection?.meanVelocity ?? 0
        let rpeText = p.map { " · RPE \($0.rpe.rpeText)~" } ?? ""
        return row(tile: {
                Button {
                    withAnimation(.spring(response: 0.4)) { live.logDone() }
                } label: { filledTile(icon: "checkmark", label: compact ? nil : "Log set") }
                .buttonStyle(.plain)
                .accessibilityLabel("Log set")
            },
            title: next?.0.name ?? "",
            kicker: "SET \(next?.2 ?? 0) DONE" + (p?.byWatch == false ? "" : " · FROM YOUR WATCH"), kickerColor: Brand.mute,
            value: LiveCardData.setText(reps: reps, weightLb: weight) + (compact ? "" : rpeText)
                + (v > 0 && compact ? String(format: " · %.2f m/s", v) : ""),
            valueColor: Brand.text) {
            pill("Edit", filled: false) { onEdit() }
        }
    }

    private var finished: some View {
        row(tile: {
                RoundedRectangle(cornerRadius: 16).fill(Brand.text.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark.seal.fill").font(.system(size: compact ? 18 : 28)).foregroundColor(Brand.voltText))
            },
            title: "All sets logged", kicker: "NICE WORK", kickerColor: Brand.mute,
            value: "Finish below", valueColor: Brand.text) { EmptyView() }
    }

    // MARK: Building blocks

    /// The Lock Screen card's tile on the left; the words right-aligned on the right.
    private func row<T: View, A: View>(@ViewBuilder tile: () -> T, title: String, kicker: String, kickerColor: Color,
                                       value: String, valueColor: Color, @ViewBuilder accessory: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            tile().frame(width: tileSize.width, height: tileSize.height)
            SetVideoToggle(compact: compact)            // set videos: film each set (front camera)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: compact ? 1 : 3) {
                Text(title).font(BrandFont.body(compact ? 13 : 16, .heavy)).foregroundColor(Brand.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(kicker).font(BrandFont.body(compact ? 8 : 9, .heavy)).tracking(1.1).foregroundColor(kickerColor)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(value).font(.system(size: compact ? 14 : 20, weight: .heavy, design: .rounded))
                    .foregroundColor(valueColor).lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if !compact {
                    HStack(spacing: 6) { accessory() }.padding(.top, 5)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }

    /// Filled accent tile: ▶ Start set, ✓ Log set.
    private func filledTile(icon: String, label: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: compact ? 16 : 24, weight: .heavy))
            if let label { Text(label).font(.system(size: 13, weight: .heavy)) }
        }
        .foregroundColor(Brand.onVolt)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Brand.volt))
        .contentShape(Rectangle())
    }

    /// Rest: a dark tile whose thick accent border drains clockwise from the top centre.
    private func restTile(frac: Double, clock: String) -> some View {
        let r: CGFloat = compact ? 12 : 16
        let w: CGFloat = compact ? 4 : 6
        return ZStack {
            RoundedRectangle(cornerRadius: r).fill(Brand.text.opacity(0.05))
            TopCentreRoundedRect(radius: r).stroke(Brand.text.opacity(0.10), lineWidth: w).padding(w / 2)
            TopCentreRoundedRect(radius: r).trim(from: 1 - frac, to: 1)
                .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .padding(w / 2)
                .animation(.linear(duration: 0.25), value: frac)
            VStack(spacing: 0) {
                if !compact { Text("REST").font(BrandFont.body(8, .heavy)).tracking(1.2).foregroundColor(Brand.mute) }
                Text(clock).font(.system(size: compact ? 15 : 28, weight: .heavy, design: .rounded))
                    .monospacedDigit().foregroundColor(Brand.text)
                    .contentTransition(.numericText())
            }
        }
    }

    /// Lifting: a dark tile with a thin accent border and the set timer.
    private func liftTile(set: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Brand.text.opacity(0.05))
            RoundedRectangle(cornerRadius: compact ? 12 : 16).stroke(Brand.voltLine, lineWidth: 1.5)
            VStack(spacing: 1) {
                if !compact {
                    Text("SET \(set) · LIFTING").font(BrandFont.body(7.5, .heavy)).tracking(0.8).foregroundColor(Brand.voltText)
                }
                if let since = live.liftingSince {
                    Text(since, style: .timer).font(.system(size: compact ? 15 : 28, weight: .heavy, design: .rounded))
                        .monospacedDigit().foregroundColor(Brand.text)
                }
            }
        }
    }

    private func pill(_ t: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(BrandFont.body(12, .heavy))
                .foregroundColor(filled ? Brand.onVolt : Brand.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(filled ? Brand.volt : Color.clear))
                .overlay(Capsule().stroke(filled ? Color.clear : Brand.line, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// A rounded rectangle whose outline starts and ends at the top centre, going clockwise —
/// so trimming it drains the border the way the Lock Screen card's rest button does.
private struct TopCentreRoundedRect: Shape {
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        let rad = min(radius, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.minY + rad), radius: rad, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - The card

struct LiveCard: View {
    let workout: Workout
    var onEdit: () -> Void = {}

    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveSessionController.shared
    @ObservedObject private var watch = WatchBridge.shared
    @AppStorage("bst_live_windows") private var windowCount = 1      // 1–4 (the side dots)
    @AppStorage("bst_live_metrics") private var metricsRaw = "heartRate,speed,tempo,pause"
    @State private var autoNotes = false     // a set just finished: the top window shows its notes
    // The windows mount one per frame once the card is on screen, so four charts laying
    // out for the first time don't hold up the card appearing or the first touch.
    @State private var readyWindows = 0

    /// One full window; two split it in half (same height); three and four add half windows below.
    static let windowHeight: CGFloat = 284
    static let maxWindows = 4
    private static let half: CGFloat = 131

    /// One metric per window, all different (a metric open in one window isn't offered in another).
    private var metrics: [LiveMetric] {
        var m: [LiveMetric] = []
        for raw in metricsRaw.split(separator: ",") {
            if let x = LiveMetric(rawValue: String(raw)), !m.contains(x) { m.append(x) }
        }
        for x in LiveMetric.allCases where m.count < Self.maxWindows && !m.contains(x) { m.append(x) }
        return Array(m.prefix(Self.maxWindows))
    }
    private var windows: Int { min(max(windowCount, 1), Self.maxWindows) }
    private var lifting: Bool { live.stage == .lifting && !live.setAwaitingLog }

    /// After a set, coach notes take over the top window — unless another window already shows them.
    private var notesTakeover: Bool { autoNotes && !metrics.prefix(windows).contains(.notes) }
    private func shown(_ i: Int) -> LiveMetric { i == 0 && notesTakeover ? .notes : metrics[i] }

    /// A window's choices: every metric not open in another window.
    private func options(_ i: Int) -> [LiveMetric] {
        let others = Set((0..<windows).filter { $0 != i }.map { shown($0) })
        return LiveMetric.allCases.filter { !others.contains($0) }
    }

    private func setMetric(_ i: Int, _ m: LiveMetric) {
        var all = metrics
        if let j = all.firstIndex(of: m), j != i { all.swapAt(i, j) } else { all[i] = m }
        metricsRaw = all.map(\.rawValue).joined(separator: ",")
        if i == 0 { autoNotes = false }
    }

    private func step(_ i: Int, _ delta: Int) {
        let opts = options(i)
        guard !opts.isEmpty else { return }
        let at = opts.firstIndex(of: shown(i)) ?? 0
        setMetric(i, opts[(at + delta + opts.count) % opts.count])
        UISelectionFeedbackGenerator().selectionChanged()
    }

    var body: some View {
        let _ = live.revision
        // Built once per redraw and shared by every window — it rescans the workout for
        // motion data and builds the coach notes, which is too much to do four times over.
        let ctx = context
        VStack(spacing: 0) {
            LiveStatusBar(workout: workout)
            LinkDiagnosticsStrip()                                   // DIAGNOSTIC (temporary)
            Rectangle().fill(Brand.line).frame(height: 1)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    if windows == 1 {
                        staged(0, ctx, compact: false).frame(height: Self.windowHeight)
                        dotsRow(0)
                    } else {
                        staged(0, ctx, compact: true).frame(height: Self.half - 1)
                        dotsRow(0)
                        divider
                        staged(1, ctx, compact: true).frame(height: Self.half)
                        dotsRow(1)
                        ForEach(2..<windows, id: \.self) { i in
                            divider
                            staged(i, ctx, compact: true).frame(height: Self.half)
                            dotsRow(i)
                        }
                    }
                }
                .padding(.bottom, 6)
                sideDots
                    .frame(height: Self.windowHeight + (windows == 1 ? 0 : 22))   // centred on the first window
            }
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .task {
            guard readyWindows == 0 else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)           // let the card finish sliding in
            for i in 1...Self.maxWindows {
                readyWindows = i
                try? await Task.sleep(nanoseconds: 32_000_000)        // a couple of frames each: touches get through
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
        .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
        // A set finished (the Watch saw it end, or you logged it): show its coach notes.
        .onChange(of: LiveCardData.lastLogged(workout)?.1.id) { _, new in if new != nil { autoNotes = true } }
        .onChange(of: live.setAwaitingLog) { _, waiting in if waiting { autoNotes = true } }
        // The next set started: back to the metric you picked.
        .onChange(of: lifting) { _, now in if now { autoNotes = false } }
    }

    private var divider: some View {
        Rectangle().fill(Brand.line).frame(height: 1).padding(.horizontal, 14)
    }

    // MARK: Dots

    /// This window's dots — only the metrics not open in another window.
    private func dotsRow(_ i: Int) -> some View {
        let cur = shown(i)
        return HStack(spacing: 0) {
            ForEach(options(i)) { m in
                Button { withAnimation(.easeOut(duration: 0.15)) { setMetric(i, m) } } label: {
                    Capsule().fill(m == cur ? Brand.voltLine : Brand.mute.opacity(0.45))
                        .frame(width: m == cur ? 16 : 6, height: 6)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.title)
                .accessibilityAddTraits(m == cur ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Four dots down the side: how many windows (tap the third for three, and so on).
    private var sideDots: some View {
        VStack(spacing: 0) {
            ForEach(0..<Self.maxWindows, id: \.self) { k in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { windowCount = k + 1 }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Group {
                        if k < windows { Capsule().fill(Brand.voltLine).frame(width: 6, height: 12) }
                        else { Circle().fill(Brand.mute.opacity(0.45)).frame(width: 6, height: 6) }
                    }
                    .frame(width: 26, height: 19)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k == 0 ? "One window" : "\(k + 1) windows")
                .accessibilityAddTraits(k + 1 == windows ? .isSelected : [])
            }
        }
    }

    // MARK: A window (swipe left or right to change its metric)

    @ViewBuilder private func staged(_ i: Int, _ ctx: LiveMetricContext, compact: Bool) -> some View {
        if i < readyWindows { pane(i, ctx, compact: compact) } else { Color.clear }
    }

    private func pane(_ i: Int, _ ctx: LiveMetricContext, compact: Bool) -> some View {
        metricView(shown(i), ctx, compact: compact)
            .padding(.leading, 14).padding(.trailing, 30).padding(.vertical, compact ? 6 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in     // the page still scrolls
                guard abs(v.translation.width) > 40, abs(v.translation.width) > abs(v.translation.height) else { return }
                withAnimation(.easeOut(duration: 0.15)) { step(i, v.translation.width < 0 ? 1 : -1) }
            })
    }

    @ViewBuilder private func metricView(_ m: LiveMetric, _ ctx: LiveMetricContext, compact: Bool) -> some View {
        switch m {
        case .notes: NotesMetric(ctx: ctx, compact: compact)
        case .heartRate:
            TimelineView(.periodic(from: .now, by: 5)) { _ in       // keeps moving between Watch readings
                HeartMetric(samples: live.heartSamples, now: live.currentHeartRate, maxHR: live.heartMax, compact: compact)
            }
        case .speed: SpeedMetric(ctx: ctx, compact: compact)
        case .tempo: TempoMetric(ctx: ctx, compact: compact)
        case .pause: PauseMetric(ctx: ctx, compact: compact)
        case .depth: DepthMetric(ctx: ctx, compact: compact)
        case .trend: TrendMetric(ctx: ctx, workouts: store.workouts, compact: compact)
        case .session: SessionMetric(workout: workout, samples: live.heartSamples, start: live.sessionStart(workout), compact: compact)
        case .sets: SetsMetric(ctx: ctx, workout: workout, compact: compact)
        }
    }

    /// Before your first set of an exercise here: your last session's last set of it.
    private func lastTime(_ ex: Exercise) -> (Workout, Exercise, ExerciseSet, Int)? {
        for pw in store.workouts.filter({ $0.id != workout.id && $0.date <= workout.date }).sorted(by: { $0.date > $1.date }) {
            if let pex = pw.exercises.first(where: { $0.name == ex.name }),
               let i = pex.sets.lastIndex(where: { $0.loggedReps != nil }) {
                return (pw, pex, pex.sets[i], i)
            }
        }
        return nil
    }

    /// What the metrics describe: the set in progress (live), the set you just did, or —
    /// before you've done one of this exercise today — your last session's set.
    private var context: LiveMetricContext {
        let last = live.lastSetMotion(workout)
        let logged = LiveCardData.lastLogged(workout)
        let next = LiveCardData.nextSet(workout)
        let exercise: Exercise? = (lifting || logged == nil) ? (next?.0 ?? logged?.0) : logged?.0
        var motion = (last != nil && last?.0.id == exercise?.id) ? last?.3 : nil
        var lastTimeDate: Date? = nil
        var notes: [CoachNote] = []
        var notesMotion: SetMotion? = nil
        var notesLabel = ""
        if let l = logged {
            notesMotion = (last?.1.id == l.1.id) ? last?.3 : nil
            notes = CoachNotes.make(exercise: l.0, set: l.1, motion: notesMotion, pauseTarget: PauseTarget.target(l.0), workouts: store.workouts)
            notesLabel = "\(l.0.name) · Set \(l.2)"
        }
        if motion == nil || logged == nil, let ex = exercise, let prev = lastTime(ex) {
            let pm = live.setMotion(prev.0, prev.1, prev.2, index: prev.3)
            if motion == nil, let pm { motion = pm; lastTimeDate = prev.0.date }
            if logged == nil {
                notesMotion = pm
                notes = CoachNotes.make(exercise: prev.1, set: prev.2, motion: pm, pauseTarget: PauseTarget.target(prev.1), workouts: store.workouts)
                notesLabel = "Last time · " + prev.0.date.formatted(.dateTime.month(.abbreviated).day())
            }
        }
        return LiveMetricContext(exercise: exercise, motion: motion,
                                 liveReps: lifting ? watch.liveRepMotions : nil,
                                 lastTime: lastTimeDate, notes: notes, notesMotion: notesMotion, notesLabel: notesLabel)
    }
}

struct LiveMetricContext {
    let exercise: Exercise?            // the exercise the metrics are about
    let motion: SetMotion?             // its most recent set with Watch data (or last session's)
    let liveReps: [RepMotion]?         // the set in progress, rep by rep (nil when not lifting)
    let lastTime: Date?                // set when `motion` is from a previous session
    let notes: [CoachNote]
    let notesMotion: SetMotion?
    let notesLabel: String

    var isLive: Bool { liveReps != nil }
    /// The reps the charts show: live ones while lifting, otherwise the latest set's.
    var reps: [RepMotion] { liveReps ?? motion?.reps ?? [] }
    /// "LIVE", "LAST TIME · SEP 29", or the exercise.
    var badge: String {
        if isLive { return "LIVE" }
        if let d = lastTime { return "LAST TIME · " + d.formatted(.dateTime.month(.abbreviated).day()).uppercased() }
        return exercise?.name ?? ""
    }
}

// MARK: - Metric building blocks

private struct MetricHeader: View {
    let metric: LiveMetric
    var right: String = ""
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: metric.icon).font(.system(size: 11, weight: .bold)).foregroundColor(Brand.voltText)
            Text(metric.title.uppercased()).font(BrandFont.body(10, .heavy)).tracking(1.3).foregroundColor(Brand.mute)
            Spacer(minLength: 4)
            if !right.isEmpty {
                Text(right).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute).lineLimit(1)
            }
        }
    }
}

private struct EmptyMetric: View {
    let metric: LiveMetric
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeader(metric: metric)
            Spacer(minLength: 0)
            Text(text).font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private let axisFont = Font.system(size: 9, weight: .semibold)
private let orange = Color(hex: 0xF2A03D)
private let blue = Color(hex: 0x3D9BE0)

private extension View {
    /// Axes on every chart: labelled values on both, light grid lines.
    func liveAxes(x: String, y: String) -> some View {
        self
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Brand.line)
                    AxisValueLabel().font(axisFont).foregroundStyle(Brand.mute)
                }
            }
            .chartXAxisLabel(position: .bottom, alignment: .trailing) {
                Text(x).font(.system(size: 8, weight: .bold)).foregroundColor(Brand.mute)
            }
            .chartYAxisLabel(position: .leading, alignment: .top) {
                Text(y).font(.system(size: 8, weight: .bold)).foregroundColor(Brand.mute)
            }
    }

    /// A rep-number x axis (1, 2, 3…).
    func repAxis() -> some View {
        self.chartXAxis {
            AxisMarks { _ in
                AxisTick().foregroundStyle(Brand.line)
                AxisValueLabel().font(axisFont).foregroundStyle(Brand.mute)
            }
        }
    }
}

// MARK: Heart rate

private struct HeartMetric: View {
    let samples: [(Date, Int)]
    let now: Int?
    let maxHR: Int
    let compact: Bool

    private struct Pt: Identifiable { let id: Double; let x: Double; let bpm: Int }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-600)
        // Stable identities (the sample's time), so a redraw isn't "all-new data" to the chart.
        let pts = samples.filter { $0.0 >= cutoff }.map { s -> Pt in
            Pt(id: s.0.timeIntervalSinceReferenceDate, x: s.0.timeIntervalSinceNow / 60, bpm: s.1)
        }
        let peak = samples.map { $0.1 }.max() ?? now ?? 0
        if now == nil && pts.isEmpty {
            EmptyMetric(metric: .heartRate, text: "Start the workout on your Watch to see your heart rate here.")
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                MetricHeader(metric: .heartRate, right: peak > 0 ? "PEAK \(peak)" : "")
                if !compact, let bpm = now {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(bpm)").font(BrandFont.display(44)).foregroundColor(Brand.text).monospacedDigit()
                        Text("bpm").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                        Spacer()
                        Text(zoneText(bpm)).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                    }
                }
                let floor = max(40, (pts.map { $0.bpm }.min() ?? 60) - 10)
                // A smooth curve through a single point divides by zero — the chart redraws invalid
                // sizes on every frame and blocks the main thread. Two points before drawing it.
                if pts.count < 2 {
                    Text("Building your heart-rate trend…").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 60, alignment: .center)
                } else {
                Chart(pts) { p in
                    AreaMark(x: .value("Minutes", p.x), yStart: .value("Floor", floor), yEnd: .value("bpm", p.bpm))
                        .foregroundStyle(LinearGradient(colors: [Brand.danger.opacity(0.28), Brand.danger.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Minutes", p.x), y: .value("bpm", p.bpm))
                        .foregroundStyle(Brand.danger).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartXScale(domain: -10.0...0.0)
                .chartYScale(domain: floor...max(100, peak + 8))
                .animation(.easeInOut(duration: 0.6), value: pts.last?.bpm)
                .chartXAxis {
                    AxisMarks(values: [-10.0, -8.0, -6.0, -4.0, -2.0, 0.0]) { v in
                        AxisTick().foregroundStyle(Brand.line)
                        AxisValueLabel {
                            if let m = v.as(Double.self) { Text(m == 0 ? "now" : "\(Int(m))m").font(axisFont).foregroundColor(Brand.mute) }
                        }
                    }
                }
                .liveAxes(x: "minutes", y: "bpm")
                }
            }
        }
    }

    private func zoneText(_ bpm: Int) -> String {
        let pct = Double(bpm) / Double(max(maxHR, 1)) * 100
        let zone = pct >= 90 ? 5 : pct >= 80 ? 4 : pct >= 70 ? 3 : pct >= 60 ? 2 : 1
        return "Zone \(zone) · \(Int(pct))% of max"
    }
}

// MARK: Bar speed (live while lifting)

private struct SpeedMetric: View {
    let ctx: LiveMetricContext
    let compact: Bool

    private struct Bar: Identifiable { let id: Int; let rep: String; let v: Double; let slow: Bool }

    var body: some View {
        let vals = ctx.reps.map { $0.meanVelocity }
        let target = max(vals.count, ctx.exercise.flatMap { ex in ex.sets.first { $0.loggedReps == nil }?.targetReps } ?? vals.count, 1)
        let best = vals.prefix(2).max() ?? 0
        let bars = vals.enumerated().map { Bar(id: $0.offset, rep: "\($0.offset + 1)", v: $0.element, slow: best > 0 && $0.element < best * 0.8) }
        if vals.isEmpty && !ctx.isLive {
            EmptyMetric(metric: .speed, text: "Lift with your Watch on and each rep's bar speed fills in here as you go.")
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                MetricHeader(metric: .speed, right: ctx.badge)
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(vals.last.map { String(format: "%.2f", $0) } ?? "—").font(BrandFont.display(40)).foregroundColor(Brand.text)
                            .monospacedDigit().contentTransition(.numericText())
                        Text(ctx.isLive ? (vals.isEmpty ? "m/s · waiting for rep 1" : "m/s · this rep") : "m/s · last rep")
                            .font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
                        Spacer()
                        if let loss = CoachNotes.speedLoss(vals) {
                            Text("Loss \(Int(loss))%").font(BrandFont.body(11, .heavy)).foregroundColor(loss >= 20 ? orange : Brand.mute)
                        }
                    }
                }
                if bars.isEmpty {
                    // Live but no rep yet: no chart. A chart with no marks (or a line through one
                    // point) lays out invalid sizes on every redraw and ties up the main thread.
                    Spacer(minLength: 0)
                    Text("Waiting for rep 1…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    Chart(bars) { b in
                        BarMark(x: .value("Rep", b.rep), y: .value("m/s", b.v), width: .ratio(0.6))
                            .foregroundStyle(b.slow ? orange : Brand.voltLine)
                            .cornerRadius(4)
                            .annotation(position: .top, spacing: 2) {
                                if !compact { Text(String(format: "%.2f", b.v)).font(.system(size: 8, weight: .bold)).foregroundColor(Brand.mute) }
                            }
                    }
                    .chartXScale(domain: (1...target).map { "\($0)" })
                    .chartYScale(domain: 0...max(0.6, (vals.max() ?? 0.5) * 1.2))
                    .repAxis()
                    .liveAxes(x: "rep", y: "m/s")
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: vals)
                }
            }
        }
    }
}

// MARK: Tempo (lower · pause · lift)

private struct TempoMetric: View {
    let ctx: LiveMetricContext
    let compact: Bool

    private struct Seg: Identifiable { let id: String; let rep: String; let phase: String; let sec: Double }

    var body: some View {
        let reps = ctx.reps
        let segs = reps.flatMap { r -> [Seg] in
            [Seg(id: "\(r.index)l", rep: "\(r.index)", phase: "Lower", sec: r.eccentricSec ?? 0),
             Seg(id: "\(r.index)p", rep: "\(r.index)", phase: "Pause", sec: r.bottomPauseSec ?? 0),
             Seg(id: "\(r.index)u", rep: "\(r.index)", phase: "Lift", sec: r.concentricSec)]
        }
        if reps.isEmpty && !ctx.isLive {
            EmptyMetric(metric: .tempo, text: "With your Watch on: how long each rep spends lowering, paused and lifting.")
        } else {
            let avg = { (f: (RepMotion) -> Double?) -> String in
                let v = reps.compactMap(f); return v.isEmpty ? "—" : String(format: "%.1f", v.reduce(0, +) / Double(v.count))
            }
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                MetricHeader(metric: .tempo, right: ctx.isLive || ctx.lastTime != nil ? ctx.badge
                             : "lower \(avg { $0.eccentricSec }) · pause \(avg { $0.bottomPauseSec }) · lift \(avg { $0.concentricSec }) s")
                if segs.isEmpty {
                    // Live but no rep yet: no chart. A chart with no marks (or a line through one
                    // point) lays out invalid sizes on every redraw and ties up the main thread.
                    Spacer(minLength: 0)
                    Text("Waiting for rep 1…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    Chart(segs) { s in
                        BarMark(x: .value("Rep", s.rep), y: .value("Seconds", s.sec), width: .ratio(0.6))
                            .foregroundStyle(by: .value("Phase", s.phase))
                    }
                    .chartForegroundStyleScale(["Lower": blue, "Pause": Brand.text.opacity(0.65), "Lift": Brand.voltLine])
                    .chartLegend(compact ? .hidden : .visible)
                    .chartXScale(domain: (1...max(reps.count, ctx.exercise.flatMap { ex in ex.sets.first { $0.loggedReps == nil }?.targetReps } ?? 1, 1)).map { "\($0)" })
                    .repAxis()
                    .liveAxes(x: "rep", y: "sec")
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: reps.count)
                }
            }
        }
    }
}

// MARK: Pause (against the target)

private struct PauseMetric: View {
    let ctx: LiveMetricContext
    let compact: Bool
    @EnvironmentObject var store: AppStore
    @State private var refresh = 0

    private struct Pt: Identifiable { let id: Int; let rep: String; let sec: Double }

    var body: some View {
        let _ = refresh
        let reps = ctx.reps
        let pts = reps.map { Pt(id: $0.index, rep: "\($0.index)", sec: $0.bottomPauseSec ?? 0) }
        let target = ctx.exercise.flatMap { PauseTarget.target($0) }
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack {
                MetricHeader(metric: .pause, right: ctx.isLive || ctx.lastTime != nil ? ctx.badge : "")
                if let ex = ctx.exercise { targetMenu(ex, target) }
            }
            if reps.isEmpty && !ctx.isLive {
                Spacer(minLength: 0)
                Text("After a set with your Watch on: each rep's pause at the bottom, against your target.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                if pts.isEmpty {
                    // Live but no rep yet: no chart. A chart with no marks (or a line through one
                    // point) lays out invalid sizes on every redraw and ties up the main thread.
                    Spacer(minLength: 0)
                    Text("Waiting for rep 1…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    Chart {
                        ForEach(pts) { p in
                            if pts.count >= 2 {                       // a line through one point is degenerate
                                LineMark(x: .value("Rep", p.rep), y: .value("Seconds", p.sec))
                                    .foregroundStyle(orange).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                            PointMark(x: .value("Rep", p.rep), y: .value("Seconds", p.sec))
                                .foregroundStyle(target.map { p.sec >= $0 - 0.25 } ?? true ? Brand.voltLine : orange)
                                .symbolSize(compact ? 40 : 70)
                        }
                        if let t = target {
                            RuleMark(y: .value("Target", t))
                                .foregroundStyle(Brand.mute)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Text("target \(PauseTarget.text(t))").font(.system(size: 8, weight: .bold)).foregroundColor(Brand.mute)
                                }
                        }
                    }
                    .chartYScale(domain: 0...max(target ?? 0, pts.map { $0.sec }.max() ?? 1, 1) * 1.3)
                    .chartXScale(domain: (1...max(reps.count, ctx.exercise.flatMap { ex in ex.sets.first { $0.loggedReps == nil }?.targetReps } ?? 1, 1)).map { "\($0)" })
                    .repAxis()
                    .liveAxes(x: "rep", y: "sec")
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: reps.count)
                }
            }
        }
    }

    /// Set the target for this exercise (sent to the Watch for the pause buzz).
    private func targetMenu(_ ex: Exercise, _ target: Double?) -> some View {
        Menu {
            let program = PauseTarget.fromProgram(ex)
            Button("From the programme" + (program.map { " (\(PauseTarget.text($0)))" } ?? " (none)")) { set(nil, ex) }
            Button("Off") { set(0, ex) }
            ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { s in Button(PauseTarget.text(s)) { set(s, ex) } }
        } label: {
            HStack(spacing: 3) {
                Text(target.map { "Target \(PauseTarget.text($0))" } ?? "No target").font(BrandFont.body(10, .heavy))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(Brand.voltText)
        }
    }

    private func set(_ s: Double?, _ ex: Exercise) {
        PauseTarget.setOverride(s, for: ex)
        refresh += 1
        store.sendActiveWorkoutToWatch()          // the Watch buzzes at the new target
    }
}

// MARK: Depth

private struct DepthMetric: View {
    let ctx: LiveMetricContext
    let compact: Bool

    private struct Bar: Identifiable { let id: Int; let rep: String; let d: Double; let shallow: Bool }

    var body: some View {
        let reps = ctx.reps
        let depths = reps.map { StatsUnits.depth($0.travelM) }
        let med = depths.sorted().dropFirst(depths.count / 2).first ?? 0
        let bars = reps.enumerated().map { i, r in
            Bar(id: r.index, rep: "\(r.index)", d: depths[i], shallow: StatsUnits.depth(0.03) <= med - depths[i])
        }
        if reps.isEmpty && !ctx.isLive {
            EmptyMetric(metric: .depth, text: "With your Watch on: how far the bar travels on each rep.")
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                MetricHeader(metric: .depth, right: ctx.isLive || ctx.lastTime != nil ? ctx.badge
                             : "typical \(String(format: "%.1f", med)) \(StatsUnits.depthLabel)")
                if bars.isEmpty {
                    // Live but no rep yet: no chart. A chart with no marks (or a line through one
                    // point) lays out invalid sizes on every redraw and ties up the main thread.
                    Spacer(minLength: 0)
                    Text("Waiting for rep 1…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    Chart {
                        ForEach(bars) { b in
                            BarMark(x: .value("Rep", b.rep), y: .value("Depth", b.d), width: .ratio(0.6))
                                .foregroundStyle(b.shallow ? orange : blue).cornerRadius(4)
                        }
                        RuleMark(y: .value("Typical", med))
                            .foregroundStyle(Brand.mute).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .chartYScale(domain: 0...max(1, (depths.max() ?? 1) * 1.2))
                    .chartXScale(domain: (1...max(reps.count, ctx.exercise.flatMap { ex in ex.sets.first { $0.loggedReps == nil }?.targetReps } ?? 1, 1)).map { "\($0)" })
                    .repAxis()
                    .liveAxes(x: "rep", y: StatsUnits.depthLabel)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: reps.count)
                }
            }
        }
    }
}

// MARK: Trend (this lift's estimated 1RM)

private struct TrendMetric: View {
    let ctx: LiveMetricContext
    let workouts: [Workout]
    let compact: Bool

    private struct Pt: Identifiable { let id: String; let date: Date; let e1rm: Double }

    var body: some View {
        let name = ctx.exercise?.name ?? ""
        let pts: [Pt] = workouts.compactMap { w -> Pt? in
            let best = w.exercises.filter { $0.name == name }.flatMap { $0.sets }.compactMap { s -> Double? in
                guard let r = s.loggedReps, let wt = s.loggedWeight, r > 0, wt > 0 else { return nil }
                return CoachNotes.epley(wt, r)
            }.max()
            return best.map { Pt(id: w.id, date: w.date, e1rm: StatsUnits.weight($0)) }
        }
        .sorted { $0.date < $1.date }
        .suffix(10)
        .map { $0 }
        if pts.count < 2 {
            EmptyMetric(metric: .trend, text: name.isEmpty ? "Your strength trend for each lift appears here."
                        : "Log \(name) in a couple of workouts to see its trend.")
        } else {
            let best = pts.map { $0.e1rm }.max() ?? 0
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                MetricHeader(metric: .trend, right: "\(name) · est. 1RM")
                if !compact, let last = pts.last {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(Int(last.e1rm.rounded()))").font(BrandFont.display(40)).foregroundColor(Brand.text)
                        Text(StatsUnits.weightLabel).font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                        Spacer()
                        Text("best \(Int(best.rounded()))").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                    }
                }
                Chart(pts) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Est. 1RM", p.e1rm))
                        .foregroundStyle(Brand.voltLine).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Date", p.date), y: .value("Est. 1RM", p.e1rm))
                        .foregroundStyle(Brand.voltLine).symbolSize(compact ? 18 : 30)
                }
                .chartYScale(domain: ((pts.map { $0.e1rm }.min() ?? 0) * 0.95)...(best * 1.03))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisTick().foregroundStyle(Brand.line)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(axisFont).foregroundStyle(Brand.mute)
                    }
                }
                .liveAxes(x: "date", y: StatsUnits.weightLabel)
            }
        }
    }
}

// MARK: Session totals

private struct SessionMetric: View {
    let workout: Workout
    let samples: [(Date, Int)]
    let start: Date
    let compact: Bool

    var body: some View {
        let sets = workout.exercises.flatMap { $0.sets }
        let done = sets.filter { $0.loggedReps != nil }
        let volume = done.reduce(0.0) { $0 + Double($1.loggedReps ?? 0) * ($1.loggedWeight ?? 0) }
        let bpms = samples.filter { $0.0 >= start }.map { $0.1 }
        let exDone = workout.exercises.filter { ex in !ex.sets.isEmpty && ex.sets.allSatisfy { $0.loggedReps != nil } }.count
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            MetricHeader(metric: .session)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3),
                      alignment: .leading, spacing: compact ? 6 : 14) {
                tile(StatsUnits.weightText(volume, unit: false), "VOLUME \(StatsUnits.weightLabel.uppercased())")
                tile("\(done.count)/\(sets.count)", "SETS")
                VStack(alignment: .leading, spacing: 1) {
                    Text(start, style: .timer).font(BrandFont.body(compact ? 15 : 22, .heavy)).monospacedDigit().foregroundColor(Brand.text)
                    Text("TIME").font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
                }
                tile(bpms.isEmpty ? "—" : "\(bpms.reduce(0, +) / bpms.count)", "AVG BPM")
                tile(bpms.max().map { "\($0)" } ?? "—", "PEAK BPM")
                tile("\(exDone)/\(workout.exercises.count)", "EXERCISES")
            }
        }
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(BrandFont.body(compact ? 15 : 22, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(l).font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
        }
    }
}

// MARK: Sets (this exercise)

private struct SetsMetric: View {
    let ctx: LiveMetricContext
    let workout: Workout
    let compact: Bool

    var body: some View {
        if let ex = ctx.exercise {
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                MetricHeader(metric: .sets, right: ex.name)
                HStack {
                    Text("SET").frame(width: 30, alignment: .leading)
                    Text("REPS × WEIGHT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("M/S").frame(width: 40, alignment: .trailing)
                    Text("RPE").frame(width: 34, alignment: .trailing)
                }
                .font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
                ForEach(Array(ex.sets.enumerated().prefix(compact ? 4 : 8)), id: \.element.id) { i, s in
                    let logged = s.loggedReps != nil
                    let m = logged ? LiveSessionController.shared.setMotion(workout, ex, s, index: i) : nil
                    let v = m.map { $0.reps.map { $0.meanVelocity }.reduce(0, +) / Double(max($0.reps.count, 1)) }
                    HStack {
                        Text("\(i + 1)").frame(width: 30, alignment: .leading).foregroundColor(Brand.mute)
                        Text(logged ? LiveCardData.setText(reps: s.loggedReps ?? 0, weightLb: s.loggedWeight ?? s.targetWeight)
                                    : SetTarget.text(s, in: ex))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(logged ? Brand.text : Brand.mute)
                        Text(v.map { String(format: "%.2f", $0) } ?? "—").frame(width: 40, alignment: .trailing).foregroundColor(Brand.mute)
                        Text(s.rpe?.rpeText ?? "—").frame(width: 34, alignment: .trailing).foregroundColor(Brand.mute)
                    }
                    .font(BrandFont.body(compact ? 11 : 13, logged ? .bold : .medium))
                    .monospacedDigit()
                }
            }
        } else {
            EmptyMetric(metric: .sets, text: "Your sets for the current exercise appear here.")
        }
    }
}

// MARK: Coach notes

private struct NotesMetric: View {
    let ctx: LiveMetricContext
    let compact: Bool

    var body: some View {
        if ctx.notes.isEmpty {
            EmptyMetric(metric: .notes, text: "Coach notes appear after each set. With your Watch on, they cover tempo, pause, bar speed and depth.")
        } else {
            VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                MetricHeader(metric: .notes, right: ctx.notesLabel)
                if !compact, let reps = ctx.notesMotion?.reps, !reps.isEmpty {
                    let v = reps.map { $0.meanVelocity }
                    HStack(spacing: 8) {
                        summary("\(reps.count)", "REPS")
                        summary(String(format: "%.2f", v.reduce(0, +) / Double(v.count)), "AVG M/S")
                        summary(CoachNotes.speedLoss(v).map { "−\(Int($0))%" } ?? "—", "SPEED LOSS")
                    }
                }
                ForEach(ctx.notes.prefix(compact ? 1 : 3)) { n in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: n.icon).font(.system(size: 12, weight: .bold)).foregroundColor(n.color)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(n.color.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.title).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.8)
                            if !compact || n.detail.count < 40 {
                                Text(n.detail).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(BrandFont.body(18, .heavy)).foregroundColor(Brand.text)
            Text(l).font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.text.opacity(0.05)))
    }
}

// MARK: - DIAGNOSTIC (temporary): the phone → Watch link at a glance. Delete with LinkStats.
struct LinkDiagnosticsStrip: View {
    @ObservedObject private var s = LinkStats.shared

    var body: some View {
        HStack(spacing: 10) {
            Text("LINK").font(BrandFont.body(9, .heavy)).tracking(1.4).foregroundColor(Brand.voltText)
            chip("bolt.fill", s.live, "live", Brand.voltText)
            chip("arrow.clockwise", s.retried, "retried", s.retried > 0 ? Brand.text : Brand.mute)
            chip("arrow.down.circle.fill", s.rescued, "by pull", s.rescued > 0 ? .orange : Brand.mute)
            chip("tray.full.fill", s.queued, "queued", s.queued > 0 ? .red : Brand.mute)
            Spacer(minLength: 4)
            if let ms = s.lastMs {
                Text("\(ms) ms").font(BrandFont.body(10, .heavy)).monospacedDigit()
                    .foregroundColor(ms > 600 ? .orange : Brand.mute)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Brand.voltLine.opacity(0.06))
        .animation(.spring(response: 0.3), value: s.sent)
    }

    private func chip(_ icon: String, _ n: Int, _ label: String, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text("\(n)").font(BrandFont.body(11, .heavy)).monospacedDigit()
            Text(label).font(BrandFont.body(9, .semibold)).opacity(0.8)
        }
        .foregroundColor(c)
    }
}

// MARK: - The session card and its dock
// The card is presented as a full-screen cover from the app shell — its own
// presentation, so its scrolling and start-up are isolated from the screens
// underneath and the slide is driven by UIKit. Pull down on its title bar, or pull
// down once you're already at the top, and it dismisses to a dock at the bottom of
// the screen. Rest timers, logged sets and the Live Activity live in
// LiveSessionController, so the card picks up where it was when re-opened.

struct WorkoutSessionCard: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_hand") private var hand = "right"
    let workoutId: String

    @State private var drag: CGFloat = 0

    var body: some View {
        WorkoutSessionView(workoutId: workoutId,
                           onMinimize: { store.minimizeSession() },
                           onClose: { store.closeSession() })
            .overlay(alignment: .top) { pullDownStrip }
            .offset(y: drag)
            .background(Brand.bg.ignoresSafeArea())
    }

    /// Pull down on the title bar to dock the card. Only this strip takes the drag
    /// — and not the chevron's corner — so the session's own scrolling is untouched.
    private var pullDownStrip: some View {
        Color.clear
            .frame(height: 54)
            .contentShape(Rectangle())
            .padding(hand == "left" ? .leading : .trailing, 66)
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in drag = max(0, v.translation.height) }
                    .onEnded { v in
                        if v.translation.height > 110 || v.predictedEndTranslation.height > 320 {
                            store.minimizeSession()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { drag = 0 }
                        }
                    }
            )
    }
}

/// The docked session: the same status bar and set card the session pins at its top
/// when you scroll, in a bar at the bottom of the screen. Start a set, log it and
/// end rest from here; tap or pull up to go back to the card.
struct WorkoutDock: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveSessionController.shared
    @AppStorage("bst_hand") private var hand = "right"
    let workoutId: String
    /// Rest just ran out while you were elsewhere: a strip along the bottom says so,
    /// and the edge goes volt. `flashOn` is the on-phase of the flash.
    var alert = false
    var flashOn = true

    private var workout: Workout? { store.workouts.first { $0.id == workoutId } }

    var body: some View {
        if let w = workout {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Capsule().fill(Brand.mute.opacity(0.35)).frame(width: 40, height: 5)
                        .padding(.top, 7)
                    LiveStatusBar(workout: w)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.expandSession() }
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { v in if v.translation.height < -24 { store.expandSession() } }
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Back to the workout")

                Rectangle().fill(Brand.line).frame(height: 1)
                setRow(w)
                if alert { restOverStrip(w) }
            }
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26)
                .stroke(alert ? Brand.volt.opacity(flashOn ? 1 : 0.45) : Brand.line, lineWidth: alert ? 1.5 : 1))
            .shadow(color: .black.opacity(0.65), radius: 18, x: 0, y: 10)
            .shadow(color: Brand.volt.opacity(alert && flashOn ? 0.35 : 0), radius: 10)
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    private func restOverStrip(_ w: Workout) -> some View {
        let next = LiveCardData.nextSet(w)
        let which = next.map { "SET \($0.2) OF \($0.0.sets.count) IS UP" } ?? "NEXT SET IS UP"
        return HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 13, weight: .heavy))
            Text("REST'S OVER · \(which)").font(BrandFont.body(11, .heavy)).tracking(1.4).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            if let next { Text(next.0.name).font(BrandFont.body(11, .bold)).opacity(0.75).lineLimit(1) }
        }
        .foregroundColor(Brand.onVolt)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Brand.volt.opacity(flashOn ? 1 : 0.35))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The compact set card drops its pills to stay slim, so rest keeps a Skip of
    /// its own here — on the thumb side.
    private func setRow(_ w: Workout) -> some View {
        let _ = live.revision
        let resting = live.stage == .resting
        return HStack(spacing: 10) {
            if resting && hand == "left" { skip.padding(.leading, 14) }
            LiveSetCard(workout: w, compact: true)
            if resting && hand != "left" { skip.padding(.trailing, 14) }
        }
    }

    private var skip: some View {
        Button { withAnimation(.spring(response: 0.4)) { live.endRest() } } label: {
            Text("Skip").font(BrandFont.body(12, .heavy))
                .foregroundColor(Brand.onVolt)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Brand.volt))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End rest")
    }
}


// MARK: - Dock host: tuck it away, and bring it back when rest runs out
// Swipe the dock toward the back-swipe edge and it slides off-screen, leaving a
// volt tab on that edge with the live number (rest countdown, or the set clock).
// Tap or pull the tab and it comes back. When a rest timer runs out while you're
// elsewhere, the dock returns on its own with the rest-over strip flashing, and
// the rest-end sound/haptic fires here — the full card isn't on screen to do it.

struct WorkoutDockHost: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveSessionController.shared
    @AppStorage("bst_hand") private var hand = "right"
    let workoutId: String

    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 400
    @State private var dockHeight: CGFloat = 112
    @State private var alert = false
    @State private var flashOn = true
    @State private var alertTask: Task<Void, Never>? = nil
    // Ten seconds left while tucked: the tab flashes accent ⇄ background and reads "10s".
    @State private var tabWarn = false
    @State private var tabFlashOn = true
    @State private var warnTask: Task<Void, Never>? = nil

    private var leftHanded: Bool { hand == "left" }
    private var tucked: Bool { store.dockTucked }
    /// Tucks toward the leading edge for a right-handed grip (the back-swipe edge), trailing for left-handed.
    private var tuckSign: CGFloat { leftHanded ? 1 : -1 }
    private var workout: Workout? { store.workouts.first { $0.id == workoutId } }

    var body: some View {
        ZStack(alignment: leftHanded ? .bottomTrailing : .bottomLeading) {
            WorkoutDock(workoutId: workoutId, alert: alert, flashOn: flashOn)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if h > 1 { dockHeight = h }
                }
                .offset(x: tucked ? tuckSign * (width + 40) : drag)
                .allowsHitTesting(!tucked)
                .simultaneousGesture(tuckGesture)

            if tucked, let w = workout {
                DockTab(workout: w, leading: !leftHanded, warning: tabWarn, flashOn: tabFlashOn)
                    .padding(.bottom, max(16, 16 + (dockHeight - 16 - 92) / 2))
                    .transition(.move(edge: leftHanded ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if w > 1 { width = w }
        }
        .onChange(of: live.stage) { old, new in
            // Rest ran its course (a skip clears restEnd first). The full card fires the
            // bell when it's open; while docked, that's this host's job.
            guard old == .resting, new != .resting, live.restEnd != nil, store.sessionMinimized else { return }
            restRanOut()
        }
        // Opening the menu tucks the dock out of the way. It stays tucked until you pull
        // it back (or a rest runs out, which brings it back on its own).
        .onChange(of: store.showTray) { _, open in
            if open, !store.dockTucked { store.tuckDock() }
        }
        // The ten-second warning also only fires from the full card; while docked it's ours.
        .onChange(of: live.restEnd, initial: true) { _, end in scheduleWarning(end) }
        .onDisappear { alertTask?.cancel(); warnTask?.cancel() }
    }

    private func scheduleWarning(_ end: Date?) {
        warnTask?.cancel(); warnTask = nil
        guard let end else { return }
        let delay = end.timeIntervalSinceNow - 10
        guard delay > 0 else { return }
        warnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, live.restEnd == end, store.sessionMinimized else { return }
            RestTimerEngine.shared.fireForegroundWarning()
            guard store.dockTucked else { return }
            withAnimation(.easeInOut(duration: 0.12)) { tabWarn = true; tabFlashOn = true }
            for i in 1...4 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.12)) { tabFlashOn = i % 2 == 0 }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { tabWarn = false; tabFlashOn = true }
        }
    }

    /// Only a clearly sideways pull, in the tuck direction, moves the dock. Buttons on
    /// the dock keep working: the gesture is simultaneous and needs 20pt of travel.
    private var tuckGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                let dx = v.translation.width
                guard abs(dx) > abs(v.translation.height) * 1.5 else { return }
                drag = tuckSign < 0 ? min(0, dx) : max(0, dx)
            }
            .onEnded { v in
                let far = abs(drag) > 90
                let flick = v.predictedEndTranslation.width * tuckSign > 240     // a flick in the tuck direction
                if far || flick {
                    drag = 0
                    store.tuckDock()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { drag = 0 }
                }
            }
    }

    private func restRanOut() {
        RestTimerEngine.shared.fireForegroundBell()      // your sound / haptic setting, Watch-aware
        store.untuckDock()
        alertTask?.cancel()
        alertTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) { alert = true; flashOn = true }
            // on · off · on · off · on, then hold, then go.
            for i in 1...4 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) { flashOn = i % 2 == 0 }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { alert = false }
        }
    }
}

/// The tab left on the edge when the dock is tucked: accent-coloured, the live
/// number running vertically. Tap it, or pull it inward, to bring the dock back.
struct DockTab: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveSessionController.shared
    let workout: Workout
    let leading: Bool      // sits on the leading edge (right-handed) or the trailing edge
    var warning = false    // ten seconds of rest left: flashes accent ⇄ background, reads "10s"
    var flashOn = true

    private var shape: UnevenRoundedRectangle {
        leading ? UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16)
                : UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
    }

    var body: some View {
        let _ = live.revision
        let dim = warning && !flashOn          // the "background" phase of the flash
        Button { store.untuckDock() } label: {
            VStack(spacing: 6) {
                Circle().fill(live.watchConnected ? Brand.danger : (dim ? Brand.mute : Brand.onVolt.opacity(0.5))).frame(width: 7, height: 7)
                Group {
                    if warning { Text("10s") } else { clock }
                }
                .font(BrandFont.body(12, .heavy)).monospacedDigit()
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: 48)
                Image(systemName: leading ? "chevron.right" : "chevron.left")
                    .font(.system(size: 12, weight: .heavy))
            }
            .foregroundColor(dim ? Brand.text : Brand.onVolt)
            .frame(width: 30, height: 92)
            .background(shape.fill(dim ? Brand.bg : Brand.volt))
            .overlay(shape.stroke(Brand.volt, lineWidth: dim ? 1.5 : 0))
            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the workout dock")
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { v in
                let inward = leading ? v.translation.width : -v.translation.width
                if inward > 24 { store.untuckDock() }
            }
        )
    }

    /// Rest countdown while resting, the set clock while lifting, the session clock otherwise.
    @ViewBuilder
    private var clock: some View {
        switch live.stage {
        case .resting:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(ceil((live.restEnd ?? ctx.date).timeIntervalSince(ctx.date))))
                Text(String(format: "%d:%02d", left / 60, left % 60))
            }
        case .lifting:
            if let since = live.liftingSince { Text(since, style: .timer) } else { Text("0:00") }
        default:
            Text(live.sessionStart(workout), style: .timer)
        }
    }
}
