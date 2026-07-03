import SwiftUI

// MARK: - Workouts list (upcoming first, scroll up for UPCOMING header, then past)
struct WorkoutsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Workout?

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
                        .background(Brand.volt)

                    ForEach(store.pastWorkouts.reversed()) { w in
                        workoutRow(w, upcoming: false)
                    }

                    // UPCOMING header — this is where the view lands on open.
                    Text("UPCOMING")
                        .font(BrandFont.display(22)).foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Brand.volt)
                        .padding(.top, 8)
                        .id("upcoming")

                    ForEach(store.upcomingWorkouts) { w in
                        workoutRow(w, upcoming: true)
                    }
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
            }
            .onAppear {
                // Land on the upcoming section; completed is above, reachable by scrolling up.
                DispatchQueue.main.async {
                    withAnimation(.none) { proxy.scrollTo("upcoming", anchor: .top) }
                }
            }
        }
        .sheet(item: $selected) { w in
            WorkoutDetailView(workout: w)
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
    let workout: Workout
    @State private var selectedExercise: Exercise?
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
                ExerciseDetailView(exercise: ex)
            }
        }
    }
}

// MARK: - Exercise detail with per-set RPE + logging + client notes
struct ExerciseDetailView: View {
    @Environment(\.dismiss) var dismiss
    @State var exercise: Exercise
    @State private var showHistory = false
    @State private var restActive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(exercise.name).font(BrandFont.display(34)).foregroundColor(.white)
                    Text(exercise.muscleGroup.uppercased()).font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)

                    section("Description", exercise.description)
                    section("Coach Notes", exercise.coachNotes, highlight: true)

                    // Sets
                    Text("YOUR PLAN").font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    ForEach($exercise.sets) { $set in
                        SetRow(set: $set,
                               number: (exercise.sets.firstIndex(where: {$0.id == set.id}) ?? 0) + 1,
                               restSeconds: exercise.restSeconds,
                               onDone: { withAnimation { restActive = true } })
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
                            .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
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
                            .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
                            .foregroundColor(.white)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { dismiss() }.foregroundColor(Brand.volt).fontWeight(.bold)
                }
            }
            .overlay {
                if restActive {
                    RestTimerView(totalSeconds: exercise.restSeconds) {
                        withAnimation { restActive = false }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    func section(_ title: String, _ body: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt)
            Text(body).font(BrandFont.body(15)).foregroundColor(highlight ? .white : Brand.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(highlight ? 16 : 0)
                .background(highlight ? Brand.black : Color.clear)
                .overlay(highlight ? Rectangle().stroke(Brand.line, lineWidth: 1) : nil)
        }
    }
}

// MARK: - Single set row with RPE selector
struct SetRow: View {
    @Binding var set: ExerciseSet
    let number: Int
    var restSeconds: Int = 90
    var onDone: () -> Void = {}

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
                                .frame(width: 28, height: 32)
                                .background(set.rpe == n ? Brand.volt : Brand.bg)
                                .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
                        }
                    }
                }
            }
            // Done -> start the rest timer
            Button(action: onDone) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("DONE — REST \(restLabel)")
                }
                .font(BrandFont.body(13, .bold)).tracking(0.5)
                .foregroundColor(Brand.black)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Brand.volt)
            }
        }
        .card()
    }

    private var restLabel: String {
        let m = restSeconds / 60, s = restSeconds % 60
        return m > 0 ? (s > 0 ? "\(m):\(String(format: "%02d", s))" : "\(m)MIN") : "\(s)S"
    }

    func logField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
            TextField("", text: value)
                .keyboardType(.numberPad).foregroundColor(.white)
                .padding(10).background(Brand.bg)
                .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
        }
    }
}
