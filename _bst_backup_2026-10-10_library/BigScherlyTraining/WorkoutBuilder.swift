import SwiftUI

// MARK: - Workout builder (Oct 8, 2026)
//
// The coach writes a workout — for any client, or for himself (his hidden self profile).
// Exercises stack as cards; each set is a row ("5 × 225 lb", "1 @ RPE 8.5", "5 × −17%",
// "8+ × 160 lb", "12 × BW"). Tap a set to open it: the set-type carousel and its fields.
// Saves through POST /admin/clients/{id}/workouts, so the client's card reads exactly as
// typed — fixed / target RPE / back-off % / AMRAP / bodyweight are the same set types the
// workout screen already understands. Synchronized folder: no target step needed.
//
// Edit (Oct 8, 2026): pass `editing:` to open an existing workout. Exercise and set ids are
// kept, so logged sets keep what was logged (they show "Logged …" and can't be removed).
// If later sessions of the same program day (or, outside a program, the same title) exist,
// saving asks: this session only, or this and the later ones. "Later" carries the CHANGES,
// so +10 lb here is +10 lb on each later week's own weight. PUT /admin/workouts/{id}?scope=

struct WorkoutBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    let clientName: String
    var editing: Workout? = nil
    var programLabel: String? = nil
    var onSaved: () -> Void = {}

    @State private var title = ""
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var exercises: [DraftExercise] = [DraftExercise()]
    @State private var selectedSet: UUID?
    @State private var saving = false
    @State private var failed = false
    @State private var prefilled = false
    @State private var futureCount = 0
    @State private var askScope = false
    @State private var pendingPayload: [String: Any] = [:]

    private var isEdit: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DSScreenHeader(eyebrow: clientName.isEmpty ? "Your training" : "For \(clientName)",
                                   title: isEdit ? "Edit workout" : "New workout",
                                   subtitle: isEdit ? (programLabel ?? "Changes show on their Workouts the moment you save.")
                                                    : "Shows on their Workouts the moment you save.")

                    if !isEdit {
                        // Saved workouts (coach library, Oct 8, 2026): fill the builder, then change anything.
                        LibraryPickerMenu { d in
                            title = d.title
                            let exs: [DraftExercise] = d.exercises.map { api in
                                var x = DraftExercise(from: api.toModel())
                                x.serverId = ""
                                x.sets = x.sets.map { s in
                                    var c = s
                                    c.serverId = ""; c.logged = ""; c.origWeightLb = 0; c.origWeightText = ""
                                    return c
                                }
                                return x
                            }
                            if !exs.isEmpty { exercises = exs }
                        }
                    }

                    field("TITLE") {
                        TextField("", text: $title, prompt: Text("e.g. Upper A").foregroundColor(Brand.mute))
                            .foregroundColor(Brand.text)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("DAY").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        DatePicker("Day", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden().tint(Brand.voltText)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.black))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    }

                    ForEach($exercises) { $ex in
                        exerciseCard($ex, index: exercises.firstIndex(where: { $0.id == ex.id }) ?? 0)
                    }

                    Button {
                        withAnimation(.snappy) { exercises.append(DraftExercise()) }
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))

                    if failed {
                        Text("Couldn't save. Check your connection and try again.")
                            .font(BrandFont.body(12)).foregroundColor(.orange)
                    }

                    Button { save() } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(Brand.onVolt) }
                            Label(isEdit ? "Save changes" : "Save workout", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(saving || !canSave)
                    .opacity(canSave ? 1 : 0.5)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(isEdit ? "Edit workout" : "New workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) }
            }
            .tapToDismissKeyboard()
            .keyboardDoneButton()
            .onAppear { prefill() }
            .task { await ExerciseCatalog.shared.load() }   // library + standard exercises for the dropdown
            .confirmationDialog("Apply to later sessions?", isPresented: $askScope, titleVisibility: .visible) {
                Button("This and \(futureCount) later") { put(pendingPayload, scope: "future") }
                Button("This session only") { put(pendingPayload, scope: "this") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("There \(futureCount == 1 ? "is 1 later session" : "are \(futureCount) later sessions") of this workout. "
                     + "Each keeps its own weights — +10 lb here means +10 lb there.")
            }
        }
    }

    private func prefill() {
        guard let w = editing, !prefilled else { return }
        prefilled = true
        title = w.title
        date = Calendar.current.startOfDay(for: w.date)
        let exs = w.exercises.map { DraftExercise(from: $0) }
        exercises = exs.isEmpty ? [DraftExercise()] : exs
    }

    // MARK: Exercise card

    private func exerciseCard(_ ex: Binding<DraftExercise>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(index + 1) OF \(exercises.count)").font(BrandFont.body(10, .heavy)).tracking(1.2).headerPill()
                Spacer()
                if exercises.count > 1 && !ex.wrappedValue.sets.contains(where: { !$0.logged.isEmpty }) {
                    Button {
                        withAnimation(.snappy) { exercises.removeAll { $0.id == ex.wrappedValue.id } }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.mute)
                    }
                    .accessibilityLabel("Remove exercise")
                }
            }
            ExerciseNameField(name: ex.name) { item in apply(item, to: ex) }
            HStack(spacing: 8) {
                TextField("", text: ex.muscle, prompt: Text("Muscle group").foregroundColor(Brand.mute))
                    .font(BrandFont.body(14)).foregroundColor(Brand.text)
                    .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
                Stepper(value: ex.rest, in: 15...600, step: 15) {
                    Text("Rest \(restText(ex.wrappedValue.rest))").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                }
                .tint(Brand.voltText)
            }

            VStack(spacing: 8) {
                ForEach(ex.sets) { $s in
                    let n = (ex.wrappedValue.sets.firstIndex(where: { $0.id == s.id }) ?? 0) + 1
                    if selectedSet == s.id {
                        setEditor($s, number: n, ex: ex)
                    } else {
                        setRow(s, number: n)
                    }
                }
            }

            HStack(spacing: 8) {
                CoachActionPill(title: "Add set", icon: "plus") {
                    withAnimation(.snappy) {
                        let s = ex.wrappedValue.sets.last.map { $0.copy() } ?? DraftSet()
                        ex.wrappedValue.sets.append(s)
                        selectedSet = s.id
                    }
                }
                if ex.wrappedValue.sets.count > 1 {
                    CoachActionPill(title: "Duplicate last", icon: "plus.square.on.square", primary: false) {
                        withAnimation(.snappy) {
                            if let last = ex.wrappedValue.sets.last { ex.wrappedValue.sets.append(last.copy()) }
                        }
                    }
                }
            }
        }
        .card(padding: 16)
    }

    private func setRow(_ s: DraftSet, number: Int) -> some View {
        Button {
            withAnimation(.snappy) { selectedSet = s.id }
        } label: {
            HStack(spacing: 8) {
                Text("Set \(number)").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.mute).frame(width: 52, alignment: .leading)
                Text(s.summary).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                Spacer()
                if !s.logged.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(Brand.voltText)
                        .accessibilityLabel("Logged")
                }
                if s.kind != .fixed {
                    Text(s.kind.tag).font(BrandFont.body(8, .heavy)).tracking(0.6).foregroundColor(Brand.voltText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
                }
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set \(number), \(s.summary). Tap to edit.")
    }

    private func setEditor(_ s: Binding<DraftSet>, number: Int, ex: Binding<DraftExercise>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SET \(number)").font(BrandFont.body(10, .heavy)).tracking(1.2).headerPill()
                Spacer()
                if ex.wrappedValue.sets.count > 1 && s.wrappedValue.logged.isEmpty {
                    Button {
                        withAnimation(.snappy) {
                            ex.wrappedValue.sets.removeAll { $0.id == s.wrappedValue.id }
                            selectedSet = nil
                        }
                    } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundColor(Brand.mute) }
                    .accessibilityLabel("Remove set")
                }
                Button { withAnimation(.snappy) { selectedSet = nil } } label: {
                    Text("Done").font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                }
            }
            DSCarousel(options: SetKind.allCases.map { DSCarousel<SetKind>.Option(id: $0, label: $0.rawValue) },
                       selection: s.kind, itemWidth: 118, accessibilityName: "Set type")
            HStack(spacing: 8) {
                numberField(s.wrappedValue.kind == .amrap ? "MIN REPS" : "REPS", text: s.reps, placeholder: s.wrappedValue.kind == .amrap ? "0" : "5")
                switch s.wrappedValue.kind {
                case .fixed:   numberField("WEIGHT (\(StatsUnits.weightLabel))", text: s.weight, placeholder: "135")
                case .rpe:     numberField("TARGET RPE", text: s.rpe, placeholder: "8.5")
                case .backoff: numberField("% LIGHTER", text: s.percent, placeholder: "17")
                case .amrap:   numberField("WEIGHT (\(StatsUnits.weightLabel))", text: s.weight, placeholder: "0 = BW")
                case .bw:      EmptyView()
                }
            }
            Text(s.wrappedValue.kind.explainer).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                .fixedSize(horizontal: false, vertical: true)
            if !s.wrappedValue.logged.isEmpty {
                Text("Logged \(s.wrappedValue.logged) — that stays.").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.text)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.voltLine.opacity(0.45), lineWidth: 1.5))
    }

    // MARK: Exercise dropdown

    /// Fills the name, muscle group and rest; sets × reps too while the sets are still the blank default.
    private func apply(_ d: APICatalogExercise, to ex: Binding<DraftExercise>) {
        ex.wrappedValue.name = d.name
        if !d.muscleGroup.isEmpty { ex.wrappedValue.muscle = d.muscleGroup }
        if d.restSeconds > 0 { ex.wrappedValue.rest = min(max(d.restSeconds, 15), 600) }
        let sets = ex.wrappedValue.sets
        let blank = sets.count == 1 && sets[0].serverId.isEmpty && sets[0].weight.isEmpty && sets[0].kind == .fixed
        if blank {
            ex.wrappedValue.sets = (0..<max(1, d.defaultSets)).map { _ in
                DraftSet(kind: d.defaultReps > 0 ? .fixed : .bw, reps: d.defaultReps > 0 ? "\(d.defaultReps)" : "")
            }
        }
    }

    // MARK: Fields

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            content()
                .padding(14).background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }

    private func numberField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(BrandFont.body(8, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Brand.mute.opacity(0.6)))
                .keyboardType(.decimalPad)
                .font(BrandFont.display(22)).foregroundColor(Brand.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
    }

    private func restText(_ s: Int) -> String { s < 60 ? "\(s)s" : (s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s") }

    // MARK: Save

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && exercises.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.sets.isEmpty }
    }

    private func save() {
        saving = true; failed = false
        // Noon on the chosen day, so the date is the same day in any time zone near the gym.
        let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let exs = exercises.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.sets.isEmpty }
        let payload: [String: Any] = [
            "id": editing?.id ?? "", "title": title.trimmingCharacters(in: .whitespaces),
            "scheduledDate": ISO8601DateFormatter().string(from: day), "completed": false,
            "exercises": exs.enumerated().map { i, e in e.payload(order: i) }
        ]
        if let w = editing {
            Task {
                let n = (try? await APIClient.shared.workoutFutureCount(workoutId: w.id)) ?? 0
                await MainActor.run {
                    if n > 0 { saving = false; futureCount = n; pendingPayload = payload; askScope = true }
                    else { put(payload, scope: "this") }
                }
            }
            return
        }
        Task {
            do {
                try await APIClient.shared.trainerCreateWorkout(clientId: clientId, payload: payload)
                await MainActor.run {
                    saving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run { saving = false; failed = true }
            }
        }
    }

    private func put(_ payload: [String: Any], scope: String) {
        guard let w = editing else { return }
        saving = true; failed = false
        Task {
            do {
                try await APIClient.shared.trainerUpdateWorkout(workoutId: w.id, scope: scope, payload: payload)
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; failed = true }
            }
        }
    }
}

extension APIClient {
    /// How many later, untouched sessions "this and later" would change.
    func workoutFutureCount(workoutId: String) async throws -> Int {
        struct R: Decodable { let count: Int }
        let r: R = try await get("/admin/workouts/\(workoutId)/future")
        return r.count
    }
    func trainerUpdateWorkout(workoutId: String, scope: String, payload: [String: Any]) async throws {
        _ = try await request("/admin/workouts/\(workoutId)?scope=\(scope)", method: "PUT",
                              body: try JSONSerialization.data(withJSONObject: payload))
    }
}

// MARK: - Drafts

enum SetKind: String, CaseIterable, Hashable {
    case fixed = "Fixed", rpe = "Target RPE", backoff = "Back-off %", amrap = "AMRAP", bw = "Bodyweight"

    var tag: String {
        switch self {
        case .fixed: return ""
        case .rpe: return "RPE"
        case .backoff: return "BACK-OFF"
        case .amrap: return "AMRAP"
        case .bw: return "BW"
        }
    }
    var explainer: String {
        switch self {
        case .fixed: return "Reps × weight, prefilled on their card."
        case .rpe: return "They work up to the effort. The weight box fills from their last session; the target shows faded in RPE."
        case .backoff: return "Weight = their heaviest set of this exercise today, this much lighter, rounded to the plate step."
        case .amrap: return "As many reps as possible. Min reps is the floor (0 = none)."
        case .bw: return "No weight — just reps."
        }
    }
}

struct DraftSet: Identifiable, Equatable {
    var id = UUID()
    var kind: SetKind = .fixed
    var reps = ""
    var weight = ""
    var rpe = ""
    var percent = ""
    // Edit mode: the server set id, what was logged ("5 × 225 lb", empty if nothing), and the
    // stored weight + how it was shown, so an untouched kg weight goes back as the exact lb.
    var serverId = ""
    var logged = ""
    var origWeightLb: Double = 0
    var origWeightText = ""

    func copy() -> DraftSet { DraftSet(kind: kind, reps: reps, weight: weight, rpe: rpe, percent: percent) }

    init(kind: SetKind = .fixed, reps: String = "", weight: String = "", rpe: String = "", percent: String = "") {
        self.kind = kind; self.reps = reps; self.weight = weight; self.rpe = rpe; self.percent = percent
    }

    init(from s: ExerciseSet) {
        if s.amrap == true { kind = .amrap }
        else if s.percent != nil { kind = .backoff }
        else if s.targetRpe != nil { kind = .rpe }
        else if s.targetWeight > 0 { kind = .fixed }
        else { kind = .bw }
        reps = kind == .amrap && s.targetReps == 0 ? "" : "\(s.targetReps)"
        if s.targetWeight > 0 {
            let shown = StatsUnits.weightLabel == "kg" ? s.targetWeight * 0.45359237 : s.targetWeight
            weight = Self.clean(shown)
        }
        rpe = s.targetRpe.map { Self.clean($0) } ?? ""
        percent = s.percent.map { Self.clean(abs($0)) } ?? ""
        serverId = s.id
        origWeightLb = s.targetWeight
        origWeightText = weight
        if let r = s.loggedReps {
            let lw = s.loggedWeight ?? 0
            logged = "\(r) × " + (lw > 0 ? StatsUnits.weightText(lw) : "BW")
        }
    }

    private static func clean(_ d: Double) -> String {
        let r = (d * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    private static func num(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }
    private var repsN: Int { Int(Self.num(reps) ?? 0) }
    /// Stored in lb (the server's unit); typed in the user's unit.
    private var weightLb: Double {
        if !serverId.isEmpty && weight == origWeightText && origWeightLb > 0 { return origWeightLb }
        guard let w = Self.num(weight), w > 0 else { return 0 }
        return StatsUnits.weightLabel == "kg" ? w / 0.45359237 : w
    }

    var summary: String {
        let r = reps.isEmpty ? "—" : reps
        switch kind {
        case .fixed: return "\(r) × \(weight.isEmpty ? "—" : weight) \(StatsUnits.weightLabel)"
        case .rpe: return "\(r) @ RPE \(rpe.isEmpty ? "—" : rpe)"
        case .backoff: return "\(r) × −\(percent.isEmpty ? "—" : percent)%"
        case .amrap: return "\(repsN > 0 ? "\(repsN)+" : "max") × \(weightLb > 0 ? "\(weight) \(StatsUnits.weightLabel)" : "BW")"
        case .bw: return "\(r) × BW"
        }
    }

    func payload(order: Int) -> [String: Any] {
        var p: [String: Any] = ["id": serverId, "targetReps": repsN, "targetWeight": 0.0, "setOrder": order]
        switch kind {
        case .fixed: p["targetWeight"] = weightLb
        case .rpe: if let r = Self.num(rpe) { p["targetRpe"] = min(max(r, 1), 10) }
        case .backoff: p["percent"] = -abs(Self.num(percent) ?? 0)
        case .amrap: p["amrap"] = true; p["targetWeight"] = weightLb
        case .bw: break
        }
        return p
    }
}

struct DraftExercise: Identifiable {
    var id = UUID()
    var name = ""
    var muscle = ""
    var rest = 90
    var sets: [DraftSet] = [DraftSet()]
    // Edit mode: kept as-is so editing never wipes the coach's notes or the description.
    var serverId = ""
    var desc = ""
    var notes = ""

    init() {}

    init(from e: Exercise) {
        name = e.name; muscle = e.muscleGroup; rest = e.restSeconds > 0 ? min(max(e.restSeconds, 15), 600) : 90
        sets = e.sets.isEmpty ? [DraftSet()] : e.sets.map { DraftSet(from: $0) }
        serverId = e.id; desc = e.description; notes = e.coachNotes
    }

    func payload(order: Int) -> [String: Any] {
        ["id": serverId, "name": name.trimmingCharacters(in: .whitespaces), "muscleGroup": muscle.trimmingCharacters(in: .whitespaces),
         "description": desc, "coachNotes": notes, "clientNotes": "", "sortOrder": order, "restSeconds": rest,
         "sets": sets.enumerated().map { i, s in s.payload(order: i) }]
    }
}
