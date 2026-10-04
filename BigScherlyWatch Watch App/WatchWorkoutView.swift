import SwiftUI
import Combine

private let volt = Color(red: 0xED/255, green: 0xFF/255, blue: 0x3D/255)
private let voltDim = Color(red: 0xED/255, green: 0xFF/255, blue: 0x3D/255).opacity(0.28)

// MARK: - Workout (exercise list)

struct WatchWorkoutView: View {
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var session: WorkoutSessionManager
    @EnvironmentObject var motion: MotionRecorder
    @State private var confirmEnd = false

    private var totalSets: Int {
        state.activeWorkout?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
    }
    private var doneSets: Int {
        state.activeWorkout?.exercises.reduce(0) {
            $0 + $1.sets.filter { $0.loggedReps != nil }.count
        } ?? 0
    }

    var body: some View {
        if let workout = state.activeWorkout {
            List {
                // Session header with a live completion bar.
                VStack(alignment: .leading, spacing: 6) {
                    Text(workout.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        progressBar(total: totalSets, done: doneSets)
                        Text("\(doneSets)/\(totalSets)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(volt)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)

                sessionRow.listRowBackground(Color.clear)

                ForEach(workout.exercises) { ex in
                    NavigationLink {
                        WatchExerciseView(exerciseId: ex.id)
                    } label: {
                        exerciseRow(ex)
                    }
                }

                if session.isRunning {
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End Session", systemImage: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .confirmationDialog("End this session?", isPresented: $confirmEnd) {
                Button("End & Save", role: .destructive) { Task { await session.end() } }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("It's saved to Apple Health as a strength workout.")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "dumbbell").font(.system(size: 26)).foregroundColor(.gray)
                Text("No active workout").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Text("Open a workout on your phone to log it here.")
                    .font(.system(size: 12)).foregroundColor(.gray).multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    // Start button before the session; live heart rate, timer and rep count during it.
    @ViewBuilder
    private var sessionRow: some View {
        if session.isRunning {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(.red)
                    Text(session.heartRate.map { "\($0)" } ?? "--")
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundColor(.white)
                }
                if let start = session.startDate {
                    Text(start, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(.gray)
                }
                Spacer()
                if let reps = motion.liveRepCount {
                    Text("\(reps) rep\(reps == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(volt))
                } else {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(volt)
                }
            }
            .padding(.vertical, 4)
        } else {
            Button {
                Task { await session.start() }
            } label: {
                VStack(spacing: 2) {
                    Label("Start Session", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                    Text("Tracks reps, bar speed & heart rate")
                        .font(.system(size: 10)).foregroundColor(.black.opacity(0.7))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Capsule().fill(volt))
            }
            .buttonStyle(.plain)
            if let err = session.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(.orange)
            }
        }
    }

    private func exerciseRow(_ ex: WatchExercise) -> some View {
        let done = ex.sets.filter { $0.loggedReps != nil }.count
        let complete = done == ex.sets.count && done > 0
        return HStack(spacing: 9) {
            // Per-exercise completion pip.
            ZStack {
                Circle().stroke(complete ? volt : Color.white.opacity(0.22), lineWidth: 2)
                    .frame(width: 22, height: 22)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black)).foregroundColor(volt)
                } else {
                    Text("\(done)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(complete ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
                Text("\(done)/\(ex.sets.count) sets")
                    .font(.system(size: 11)).foregroundColor(.gray)
            }
        }
        .padding(.vertical, 2)
    }

    private func progressBar(total: Int, done: Int) -> some View {
        GeometryReader { g in
            let frac = total > 0 ? CGFloat(done) / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [voltDim, volt], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(frac > 0 ? 4 : 0, g.size.width * frac))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Exercise (set list)

struct WatchExerciseView: View {
    @EnvironmentObject var state: WatchState
    let exerciseId: String
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var exercise: WatchExercise? {
        state.activeWorkout?.exercises.first(where: { $0.id == exerciseId })
    }

    var body: some View {
        if let ex = exercise {
            List {
                if state.restEndDate != nil {
                    restBanner.listRowBackground(Color.clear)
                }

                ForEach(Array(ex.sets.enumerated()), id: \.element.id) { idx, set in
                    NavigationLink {
                        WatchSetLogView(exerciseId: ex.id, setId: set.id, setNumber: idx + 1)
                    } label: {
                        setRow(idx + 1, set)
                    }
                }

                Button {
                    state.startRest(seconds: ex.restSeconds)
                } label: {
                    Label("Start rest (\(ex.restSeconds)s)", systemImage: "timer")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(volt)
                }
            }
            .navigationTitle(ex.name)
            .onAppear { state.focusedExerciseId = exerciseId }
            .onDisappear { if state.focusedExerciseId == exerciseId { state.focusedExerciseId = nil } }
            .onReceive(tick) { _ in
                if state.restEndDate != nil, state.restRemaining <= 0 { state.restEndDate = nil }
            }
        } else {
            Text("—")
        }
    }

    // Rest countdown with an accurate draining ring.
    private var restBanner: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: state.restProgress)
                    .stroke(Color.black, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: state.restProgress)
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.black)
            }
            .frame(width: 26, height: 26)

            Text(timeString(state.restRemaining))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(.black).monospacedDigit()
            Spacer()
            Button {
                state.cancelRest()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.black.opacity(0.65)).font(.system(size: 17))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(
            LinearGradient(colors: [volt, volt.opacity(0.82)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func setRow(_ n: Int, _ set: WatchSet) -> some View {
        let logged = set.loggedReps != nil
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(logged ? volt : Color.clear)
                    .overlay(Circle().stroke(logged ? volt : Color.white.opacity(0.25), lineWidth: 2))
                    .frame(width: 18, height: 18)
                if logged {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black)).foregroundColor(.black)
                }
            }
            Text("Set \(n)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(logged ? .white.opacity(0.6) : .white)
            Spacer()
            if let reps = set.loggedReps {
                Text("\(reps)×\(Int(set.loggedWeight ?? set.targetWeight))")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(volt)
                if let rpe = set.rpe {
                    Text("@\(rpe == rpe.rounded() ? String(Int(rpe)) : String(format: "%.1f", rpe))").font(.system(size: 11)).foregroundColor(.gray)
                }
            } else {
                Text("\(set.targetReps)×\(Int(set.targetWeight))")
                    .font(.system(size: 13, design: .rounded)).foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Set logging

struct WatchSetLogView: View {
    @EnvironmentObject var state: WatchState
    @Environment(\.dismiss) var dismiss
    let exerciseId: String
    let setId: String
    let setNumber: Int
    /// When confirming an auto-detected set: its rep count and motion.
    var detection: DetectedSet? = nil
    /// Extra step after logging (the detected-set sheet uses it to close itself).
    var onLogged: (() -> Void)? = nil

    @State private var reps: Double = 0
    @State private var weight: Double = 0
    @State private var rpe: Double = 0
    @State private var targetWeight: Double = 0
    @State private var loaded = false

    private var set: WatchSet? {
        state.activeWorkout?.exercises.first(where: { $0.id == exerciseId })?
            .sets.first(where: { $0.id == setId })
    }
    private var exercise: WatchExercise? {
        state.activeWorkout?.exercises.first(where: { $0.id == exerciseId })
    }
    private var isLastSet: Bool {
        guard let ex = exercise else { return false }
        return ex.sets.last?.id == setId
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 1) {
                    if let name = exercise?.name {
                        Text(name).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    Text("SET \(setNumber)")
                        .font(.system(size: 10, weight: .black)).tracking(1.5)
                        .foregroundColor(volt)
                    if let d = detection {
                        Text(String(format: "Detected · %.2f m/s · %.0f in", d.meanVelocity, d.averageTravelM * 39.37))
                            .font(.system(size: 10)).foregroundColor(.gray)
                    }
                }

                sliderRow("REPS", value: $reps, range: 1...20, step: 1, display: "\(Int(reps))")
                sliderRow("WEIGHT", value: $weight, range: weightRange, step: 5,
                          display: "\(Int(weight))")
                sliderRow("RPE", value: $rpe, range: 1...10, step: 0.5,
                          display: rpe == rpe.rounded() ? "\(Int(rpe))" : String(format: "%.1f", rpe))

                Button {
                    state.logSet(exerciseId: exerciseId, setId: setId,
                                 reps: Int(reps), weight: weight, rpe: rpe,
                                 motion: detection)
                    if !isLastSet, let rest = exercise?.restSeconds, rest > 0 {
                        state.startRest(seconds: rest)
                    }
                    dismiss()
                    onLogged?()
                } label: {
                    Text(isLastSet ? "Log Set" : "Log & Rest")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [volt, volt.opacity(0.85)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .onAppear {
            guard !loaded, let s = set else { return }
            reps = min(20, max(1, Double(detection?.reps.count ?? s.loggedReps ?? s.targetReps)))
            targetWeight = s.targetWeight
            let w = s.loggedWeight ?? s.targetWeight
            weight = min(targetWeight + 50, max(max(0, targetWeight - 50), w))
            rpe = s.rpe ?? 7
            loaded = true
        }
    }

    private var weightRange: ClosedRange<Double> {
        let lower = max(0, targetWeight - 50)
        return lower...(targetWeight + 50)
    }

    // MARK: Slider
    //
    // The drag gesture lives on the TRACK, not the knob. That matters: when it was on
    // the knob, `g.location.x` was measured inside the knob's own frame *and* the code
    // added the knob's current offset — so a moving knob was counted twice and the
    // value ran away from the finger. Reading the location in track space means the
    // knob centre sits exactly where the finger is, 1:1, with no feedback.
    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 9, weight: .black)).tracking(1.2)
                    .foregroundColor(.gray)
                Spacer()
                Text(display)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                let w = geo.size.width
                let knobD: CGFloat = 26
                let usable = max(1, w - knobD)
                let span = range.upperBound - range.lowerBound
                let rawFrac = span > 0 ? CGFloat((value.wrappedValue - range.lowerBound) / span) : 0
                let frac = min(max(0, rawFrac), 1)
                let knobX = usable * frac

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 9)
                    Capsule()
                        .fill(LinearGradient(colors: [voltDim, volt],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: knobX + knobD / 2, height: 9)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(volt, lineWidth: 3))
                        .frame(width: knobD, height: knobD)
                        .offset(x: knobX)
                }
                .frame(height: knobD)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            // location.x is in TRACK space. Subtract half the knob so
                            // the knob's centre — not its left edge — tracks the finger.
                            let centre = g.location.x - knobD / 2
                            let f = Double(min(max(0, centre / usable), 1))
                            let raw = range.lowerBound + f * span
                            let snapped = (raw / step).rounded() * step
                            value.wrappedValue = min(range.upperBound,
                                                     max(range.lowerBound, snapped))
                        }
                )
            }
            .frame(height: 26)
        }
        .padding(.vertical, 1)
    }
}
