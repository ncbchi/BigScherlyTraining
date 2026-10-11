import SwiftUI

// MARK: - Trainer: a client's workouts
// Every workout assigned to the client — upcoming, missed and completed — with
// prescribed vs. logged sets. Edit (Oct 8, 2026): the detail screen's Edit opens the
// builder prefilled; program sessions show their program label.

struct TrainerWorkoutsView: View {
    let clientId: String
    var clientName: String = ""
    @State private var workouts: [Workout] = []
    @State private var labels: [String: String] = [:]
    @State private var loading = true
    @State private var failed = false
    @State private var filter: Filter = .upcoming
    @State private var pickedDefault = false
    @State private var building = false

    enum Filter: String, CaseIterable, Identifiable {
        case upcoming  = "Upcoming"
        case missed    = "Missed"
        case completed = "Completed"
        var id: String { rawValue }
    }

    private func bucket(_ f: Filter) -> [Workout] {
        let today = Calendar.training.startOfDay(for: Date())
        switch f {
        case .upcoming:
            return workouts.filter { !$0.completed && $0.date >= today }.sorted { $0.date < $1.date }
        case .missed:
            return workouts.filter { !$0.completed && $0.date < today }.sorted { $0.date > $1.date }
        case .completed:
            return workouts.filter { $0.completed }.sorted { $0.date > $1.date }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Programs: what they're on, the automatic changes, assign / switch / end.
                ClientProgramCard(clientId: clientId, clientName: clientName) { Task { await load() } }
                Button { building = true } label: { Label("New workout", systemImage: "plus") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        let n = bucket(f).count
                        Button { withAnimation(.easeInOut(duration: 0.15)) { filter = f } } label: {
                            Text(loading ? f.rawValue : "\(f.rawValue) · \(n)")
                                .font(BrandFont.body(12, .bold))
                                .foregroundColor(filter == f ? Brand.onVolt : Brand.text)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(Capsule().fill(filter == f ? Brand.volt : Brand.black))
                                .overlay(Capsule().stroke(filter == f ? Brand.voltLine : Brand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)

                let list = bucket(filter)
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if failed && workouts.isEmpty {
                    Text("Couldn't load workouts. Pull down to retry.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else if list.isEmpty {
                    Text(emptyText)
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    ForEach(list) { w in
                        NavigationLink {
                            TrainerWorkoutDetailView(workout: w, clientId: clientId, clientName: clientName,
                                                     programLabel: labels[w.id]) { Task { await load() } }
                        } label: {
                            row(w)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $building) {
            WorkoutBuilderView(clientId: clientId, clientName: clientName) {
                Task { await load(); filter = .upcoming }
            }
        }
    }

    private var emptyText: String {
        switch filter {
        case .upcoming:  return "Nothing scheduled."
        case .missed:    return "No missed workouts."
        case .completed: return "Nothing completed yet."
        }
    }

    private func row(_ w: Workout) -> some View {
        let sets = w.exercises.flatMap { $0.sets }
        let logged = sets.filter { $0.loggedReps != nil }.count
        let showProgress = w.completed || logged > 0
        return HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(w.date.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(BrandFont.body(9, .heavy))
                Text("\(Calendar.training.component(.day, from: w.date))").font(BrandFont.display(22))
            }
            .foregroundColor(w.completed ? Brand.onVolt : Brand.text)
            .frame(width: 46, height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(w.completed ? Brand.volt : Brand.text.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(w.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                if let label = labels[w.id] {
                    Text(label).font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText).lineLimit(1)
                }
                Text("\(w.dayOfWeek) · \(w.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                if !w.exercises.isEmpty {
                    Text(w.exerciseSummary)
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(showProgress ? "\(logged)/\(sets.count)" : "\(sets.count)")
                    .font(BrandFont.body(14, .bold))
                    .foregroundColor(showProgress && logged == sets.count && !sets.isEmpty ? Brand.voltText : Brand.text)
                Text("SETS").font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.mute)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .padding(14)
        .background(Brand.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            let api = try await APIClient.shared.trainerWorkouts(clientId: clientId)
            workouts = api.map { $0.toModel() }
            labels = Dictionary(api.compactMap { a in a.programLabel.map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
            failed = false
        } catch {
            failed = true
        }
        loading = false
        // First load only: land on a tab that has something in it.
        if !pickedDefault {
            pickedDefault = true
            if bucket(.upcoming).isEmpty {
                if !bucket(.completed).isEmpty { filter = .completed }
                else if !bucket(.missed).isEmpty { filter = .missed }
            }
        }
    }
}

// MARK: - One workout

struct TrainerWorkoutDetailView: View {
    @State var workout: Workout
    var clientId: String = ""
    var clientName: String = ""
    var programLabel: String? = nil
    var onChanged: () -> Void = {}
    @State private var editing = false
    @State private var commenting: SetToComment?
    @State private var savingToLibrary = false
    @State private var libraryName = ""
    @State private var savedNote: String?

    struct SetToComment: Identifiable { let id: String; let label: String }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(workout.title).font(BrandFont.display(30)).foregroundColor(Brand.text)
                    if let programLabel {
                        Text(programLabel).font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                    }
                    if let savedNote {
                        Text(savedNote).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                    }
                    HStack(spacing: 10) {
                        Text("\(workout.dayOfWeek) · \(workout.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        statusBadge
                    }
                }

                if workout.exercises.isEmpty {
                    Text("No exercises on this workout.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }

                ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { i, ex in
                    exerciseCard(i + 1, ex)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !clientId.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { libraryName = workout.title; savingToLibrary = true } label: { Image(systemName: "books.vertical") }
                        .foregroundColor(Brand.voltText).accessibilityLabel("Save to library")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = true }.foregroundColor(Brand.voltText)
                }
            }
        }
        .alert("Save to library", isPresented: $savingToLibrary) {
            TextField("Name", text: $libraryName)
            Button("Save") {
                let n = libraryName.trimmingCharacters(in: .whitespaces)
                Task {
                    do { try await APIClient.shared.saveWorkoutToLibrary(workoutId: workout.id, name: n); savedNote = "Saved to your library" }
                    catch { savedNote = "Couldn't save to the library" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves the exercises and set targets (not what they logged) so you can give it to anyone.") }
        .sheet(item: $commenting) { c in
            SetCommentSheet(setId: c.id, label: c.label, clientName: clientName)
        }
        .sheet(isPresented: $editing) {
            WorkoutBuilderView(clientId: clientId, clientName: clientName, editing: workout, programLabel: programLabel) {
                Task { await reload() }
            }
        }
    }

    private func reload() async {
        if let fresh = try? await APIClient.shared.trainerWorkouts(clientId: clientId).first(where: { $0.id == workout.id }) {
            workout = fresh.toModel()
        }
        onChanged()
    }

    // MARK: Status

    private var statusBadge: some View {
        let sets = workout.exercises.flatMap { $0.sets }
        let logged = sets.filter { $0.loggedReps != nil }.count
        let past = workout.date < Calendar.training.startOfDay(for: Date())
        let (label, color): (String, Color) = {
            if workout.completed { return ("COMPLETED", Brand.volt) }
            if logged > 0 { return ("PARTIAL \(logged)/\(sets.count)", .orange) }
            if past { return ("MISSED", Brand.danger) }
            return ("SCHEDULED", Brand.mute)
        }()
        return Text(label)
            .font(BrandFont.body(9, .bold)).tracking(1)
            .foregroundColor(Brand.readable(color))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().stroke(Brand.readableLine(color), lineWidth: 1))
    }

    // MARK: Exercise

    private func exerciseCard(_ n: Int, _ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(BrandFont.display(22)).foregroundColor(Brand.voltText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ex.name).font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                    let meta = [ex.muscleGroup, "Rest \(restLabel(ex.restSeconds))"].filter { !$0.isEmpty }
                    Text(meta.joined(separator: " · "))
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            }

            if !ex.sets.isEmpty {
                VStack(spacing: 0) {
                    setHeader
                    ForEach(Array(ex.sets.enumerated()), id: \.element.id) { i, s in
                        Divider().overlay(Brand.line)
                        setRow(i + 1, s, in: ex)
                    }
                }
            }

            note("COACH NOTES", ex.coachNotes)
            note("FORM CUES", ex.formInstructions)
            note("CLIENT NOTES", ex.clientNotes)
        }
        .card(padding: 16)
    }

    private var setHeader: some View {
        HStack {
            Text("SET").frame(width: 34, alignment: .leading)
            Text("TARGET").frame(maxWidth: .infinity, alignment: .leading)
            Text("LOGGED").frame(maxWidth: .infinity, alignment: .leading)
            Text("RPE").frame(width: 36, alignment: .trailing)
            if !clientId.isEmpty { Color.clear.frame(width: 28, height: 1) }
        }
        .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
        .padding(.bottom, 6)
    }

    private func setRow(_ n: Int, _ s: ExerciseSet, in ex: Exercise) -> some View {
        let loggedText: String
        let loggedColor: Color
        if let r = s.loggedReps {
            loggedText = "\(r) × \(weight(s.loggedWeight ?? 0))"
            let hit = ProgressEngine.setHit(s, in: ex)
            loggedColor = hit ? Brand.volt : .orange
        } else {
            loggedText = "—"
            loggedColor = Brand.mute
        }
        return HStack {
            Text("\(n)").frame(width: 34, alignment: .leading).foregroundColor(Brand.mute)
            Text(SetTarget.text(s, in: ex))
                .frame(maxWidth: .infinity, alignment: .leading).foregroundColor(Brand.text)
            Text(loggedText)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundColor(Brand.readable(loggedColor))
            Text(s.rpe.map { $0.rpeText } ?? "—")
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(s.rpe == nil ? Brand.mute : Brand.text)
            if !clientId.isEmpty {
                // Comment on this set → their chat, set quoted (Oct 8, 2026)
                Button {
                    let what = s.loggedReps != nil ? loggedText : SetTarget.text(s, in: ex) + " (planned)"
                    commenting = SetToComment(id: s.id, label: "\(ex.name) · Set \(n) — \(what)")
                } label: {
                    Image(systemName: "text.bubble").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.voltText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Comment on set \(n)")
            }
        }
        .font(BrandFont.body(13, .semibold))
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func note(_ title: String, _ text: String) -> some View {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.body(9, .bold)).tracking(1).headerPill()
                Text(t).font(BrandFont.body(13)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Formatting

    private func weight(_ w: Double) -> String {
        if w <= 0 { return "BW" }
        return StatsUnits.weightText(w)
    }

    private func restLabel(_ sec: Int) -> String {
        sec < 60 ? "\(sec)s" : String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
