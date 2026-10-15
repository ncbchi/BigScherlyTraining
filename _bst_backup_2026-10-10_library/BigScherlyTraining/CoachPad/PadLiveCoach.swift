import SwiftUI

// MARK: - Coach HQ on iPad: Live · the coach's column (Oct 10, 2026)
//
// Beside the client's card, in the same card style:
//   Next set — reps and weight steppers, back-off −10%, AMRAP, add a set, skip it. Saved to the
//     server (the same PUT the workout builder uses, this session only), then the client's phone
//     fetches the workout again and its set card says "Coach changed it · was 225".
//   Notes for next time — per exercise. Saved into that exercise's coach notes on the client's next
//     workout with it ("From Nick · Oct 10 — …"); the phone shows them as notes from the coach.
//     No next workout with that exercise yet: saved to the coach's private note on the client.
//   Watch for — only the coach sees it: a PR on the bar, their usual bar speed, lift targets.
// No messages mid-session: the coach is standing next to them. Synchronized folder: no target step.

// MARK: Saving

@MainActor
enum PadLivePlan {
    enum Failure: Error { case notFound }

    /// The workout as the builder sends it (ids kept, so logged sets keep what was logged).
    static func payload(_ w: Workout) -> [String: Any] {
        let exercises: [[String: Any]] = w.exercises.enumerated().map { i, e in
            let sets: [[String: Any]] = e.sets.enumerated().map { j, s in setPayload(s, j) }
            let p: [String: Any] = ["id": e.id, "name": e.name, "muscleGroup": e.muscleGroup, "description": e.description,
                                    "coachNotes": e.coachNotes, "clientNotes": e.clientNotes, "sortOrder": i,
                                    "restSeconds": e.restSeconds, "sets": sets]
            return p
        }
        return ["id": w.id, "title": w.title, "scheduledDate": ISO8601DateFormatter().string(from: w.date),
                "completed": w.completed, "exercises": exercises]
    }

    private static func setPayload(_ s: ExerciseSet, _ order: Int) -> [String: Any] {
        var p: [String: Any] = ["id": s.id, "targetReps": s.targetReps, "targetWeight": s.targetWeight, "setOrder": order]
        if let r = s.targetRpe { p["targetRpe"] = r }
        if let pc = s.percent { p["percent"] = pc }
        if s.amrap == true { p["amrap"] = true }
        return p
    }

    /// Change the session they're doing: the server's copy, then their phone fetches it again.
    static func edit(_ phone: PadLivePhone, _ change: (inout Workout) -> Void) async throws {
        guard let wid = phone.workout?.id, let cid = phone.clientId else { throw Failure.notFound }
        if phone.demo { PadLiveDemo.shared.edit(phone.id, change); return }
        let all = try await APIClient.shared.trainerWorkouts(clientId: cid)
        guard let api = all.first(where: { $0.id == wid }) else { throw Failure.notFound }
        var w = api.toModel()
        change(&w)
        try await APIClient.shared.trainerUpdateWorkout(workoutId: wid, scope: "this", payload: payload(w))
        PadLiveLink.shared.command(LiveCommand(t: "reload"), to: phone.id)
    }

    static func changeSet(_ id: String, _ w: inout Workout, _ f: (inout ExerciseSet) -> Void) {
        for ei in w.exercises.indices {
            for si in w.exercises[ei].sets.indices where w.exercises[ei].sets[si].id == id { f(&w.exercises[ei].sets[si]) }
        }
    }

    static func addSet(after id: String, _ w: inout Workout) {
        for ei in w.exercises.indices {
            if let si = w.exercises[ei].sets.firstIndex(where: { $0.id == id }) {
                var copy = w.exercises[ei].sets[si]
                copy.id = ""                                  // new on the server
                copy.loggedReps = nil; copy.loggedWeight = nil; copy.rpe = nil; copy.loggedAt = nil
                w.exercises[ei].sets.insert(copy, at: si + 1)
                return
            }
        }
    }

    static func removeSet(_ id: String, _ w: inout Workout) {
        for ei in w.exercises.indices {
            w.exercises[ei].sets.removeAll { $0.id == id && $0.loggedReps == nil }
        }
    }

    /// A note for next time, on their next workout with this exercise. Returns where it went.
    static func saveNote(_ phone: PadLivePhone, exercise: String, text: String) async throws -> String {
        guard let cid = phone.clientId else { throw Failure.notFound }
        let first: String = phone.name.firstName
        if phone.demo { return "\(first)'s next \(exercise) · demo, nothing saved" }
        let all = try await APIClient.shared.trainerWorkouts(clientId: cid)
        let today: Date = Calendar.current.startOfDay(for: Date())
        let current: String? = phone.workout?.id
        let key: String = exercise.lowercased()
        let upcoming: [APIWorkout] = all.filter { !$0.completed && $0.id != current && $0.scheduledDate >= today }
            .sorted { $0.scheduledDate < $1.scheduledDate }
        let line: String = CoachNoteLines.line(who: PadLiveLink.shared.coachName.firstName, when: Date(), text: text)
        if let api = upcoming.first(where: { $0.exercises.contains { $0.name.lowercased() == key } }) {
            var w = api.toModel()
            if let i = w.exercises.firstIndex(where: { $0.name.lowercased() == key }) {
                let cur: String = w.exercises[i].coachNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                w.exercises[i].coachNotes = cur.isEmpty ? line : cur + "\n" + line
            }
            try await APIClient.shared.trainerUpdateWorkout(workoutId: w.id, scope: "this", payload: payload(w))
            Task { await PadData.shared.refresh(roster: AppStore.shared.roster, force: false) }
            return api.scheduledDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + " · " + api.title
        }
        // Nothing scheduled with it yet: the coach's own note on the client, so it isn't lost.
        let had: String = (try? await APIClient.shared.clientNote(clientId: cid))?.body ?? (PadData.shared.notes[cid] ?? "")
        let add: String = "For \(first)'s next \(exercise): \(text)"
        let body: String = had.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? add : had + "\n" + add
        try await APIClient.shared.saveClientNote(clientId: cid, body: body)
        PadData.shared.setNote(cid, body)
        return "No \(exercise) scheduled yet — saved to your private notes on \(first)"
    }
}

// MARK: - Card header (a volt tag, then a grey title)

struct PadLiveCoachHeader: View {
    let icon: String
    let tag: String
    let title: String
    var right: String = ""
    var rightColor: Color = Brand.mute
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .heavy))
                Text(tag).font(BrandFont.body(9, .heavy)).tracking(1)
            }
            .foregroundColor(Brand.onVolt)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(Brand.volt))
            Text(title).font(BrandFont.body(10, .heavy)).tracking(1.3).foregroundColor(Brand.mute).lineLimit(1)
            Spacer(minLength: 4)
            if !right.isEmpty { Text(right).font(BrandFont.body(11, .semibold)).foregroundColor(rightColor).lineLimit(1) }
        }
    }
}

struct PadLivePill: View {
    let text: String
    var icon: String? = nil
    var filled = false
    var dim = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .heavy)) }
                Text(text).font(BrandFont.body(12, .heavy))
            }
            .foregroundColor(filled ? Brand.onVolt : (dim ? Brand.mute : Brand.text))
            .padding(.horizontal, 13).frame(height: 32)
            .background(Capsule().fill(filled ? Brand.volt : Color.clear))
            .overlay(Capsule().stroke(filled ? Color.clear : Brand.line, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Next set

struct PadLiveNextSetCard: View {
    let ctx: PadLiveCtx
    var compact = false

    @State private var draftReps: Int?
    @State private var draftLb: Double?
    @State private var status: Status = .idle
    @State private var saveTask: Task<Void, Never>?        // the debounce after − / +
    @State private var chain: Task<Void, Never>?           // saves run one after another (each reads, changes, writes)
    @State private var serial = 0
    @State private var originals: [String: ExerciseSet] = [:]       // before your first change, for Undo

    enum Status: Equatable { case idle, saving, saved, failed }

    private var step: Double { StatsUnits.isKg ? 2.5 / 0.45359237 : 5 }

    var body: some View {
        let target: (Exercise, ExerciseSet, Int)? = ctx.nextSet
        VStack(alignment: .leading, spacing: 10) {
            PadLiveCoachHeader(icon: "pencil", tag: "NEXT SET", title: heading(target), right: statusText, rightColor: statusColor)
            if let t = target {
                editor(t)
            } else {
                Text("Last set of the session — nothing after it.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                if let cur = ctx.cardSet {
                    PadLivePill(text: "+ Add a set") { save(cur.1, track: false) { w in PadLivePlan.addSet(after: cur.1.id, &w) } }
                }
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padLiveCard(highlight: status == .saved ? Brand.voltLine.opacity(0.6) : nil)
        .onChange(of: target?.1.id) { _, _ in saveTask?.cancel(); draftReps = nil; draftLb = nil }
        // The phone sent the plan back with your change in it: the draft has done its job.
        .onChange(of: target.map { "\($0.1.targetReps)|\($0.1.targetWeight)" }) { _, _ in
            if let t = target {
                if draftReps == t.1.targetReps { draftReps = nil }
                if let d = draftLb, abs(d - t.1.targetWeight) < 0.01 { draftLb = nil }
            }
        }
    }

    private func heading(_ t: (Exercise, ExerciseSet, Int)?) -> String {
        guard let t else { return "" }
        let ex: String = t.0.name == ctx.card.exercise ? "" : t.0.name.uppercased() + " · "
        return ex + "SET \(t.2) OF \(t.0.sets.count)" + (ctx.card.stage == .lifting ? " · UP NEXT" : "")
    }

    private var statusText: String {
        switch status {
        case .idle: return compact ? "" : "straight to \(ctx.firstName)'s card"
        case .saving: return "Saving…"
        case .saved: return "✓ on \(ctx.firstName)'s card"
        case .failed: return "Couldn't save — tap again"
        }
    }
    private var statusColor: Color {
        switch status {
        case .saved: return Brand.voltText
        case .failed: return Color(hex: 0xF2A03D)
        default: return Brand.mute
        }
    }

    @ViewBuilder private func editor(_ t: (Exercise, ExerciseSet, Int)) -> some View {
        let s: ExerciseSet = t.1
        let reps: Int = draftReps ?? s.targetReps
        let baseLb: Double = SetTarget.plannedWeight(s, in: t.0) ?? (ctx.cardSet?.1.id == s.id ? ctx.goalLb : 0)
        let lb: Double = draftLb ?? baseLb
        let repsChanged: Bool = originals[s.id].map { $0.targetReps != reps } ?? (draftReps != nil)
        let lbChanged: Bool = originals[s.id].map { abs($0.targetWeight - lb) > 0.01 } ?? (draftLb != nil)
        let kind: String = kindText(s)
        HStack(alignment: .bottom, spacing: 10) {
            stepper("REPS", value: "\(reps)\(s.amrap == true ? "+" : "")", unit: nil, changed: repsChanged,
                    minus: { bump(s, reps: max(1, reps - 1), lb: nil) }, plus: { bump(s, reps: reps + 1, lb: nil) })
            stepper("WEIGHT", value: lb > 0 ? SetTarget.weightText(lb, unit: false) : "BW", unit: lb > 0 ? StatsUnits.weightLabel : nil, changed: lbChanged,
                    minus: { bump(s, reps: nil, lb: max(0, lb - step)) }, plus: { bump(s, reps: nil, lb: lb + step) })
            if !kind.isEmpty, !compact {
                Text(kind.uppercased()).font(BrandFont.body(9, .heavy)).tracking(1).foregroundColor(Brand.voltText)
                    .padding(.bottom, 14)
            }
        }
        if !compact {
            HStack(spacing: 6) {
                PadLivePill(text: "Back-off −10%", filled: s.percent != nil) {
                    save(s, track: true) { w in PadLivePlan.changeSet(s.id, &w) { x in x.percent = -10; x.targetWeight = 0; x.targetRpe = nil; x.amrap = nil } }
                }
                PadLivePill(text: "AMRAP", filled: s.amrap == true) {
                    let on: Bool = s.amrap != true
                    save(s, track: true) { w in PadLivePlan.changeSet(s.id, &w) { x in x.amrap = on ? true : nil } }
                }
                PadLivePill(text: "+ Add a set") { save(s, track: false) { w in PadLivePlan.addSet(after: s.id, &w) } }
                PadLivePill(text: "Skip it", dim: true) { save(s, track: false) { w in PadLivePlan.removeSet(s.id, &w) } }
            }
            if let o = originals[s.id] {
                HStack(spacing: 6) {
                    Text("Was " + PadLiveMath.planText(o) + ".").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    Button("Undo") { undo(o) }.font(BrandFont.body(11, .heavy)).foregroundColor(Brand.text).buttonStyle(.plain)
                }
            }
        }
    }

    private func kindText(_ s: ExerciseSet) -> String {
        if s.amrap == true { return "AMRAP" }
        if let p = s.percent { return "Back-off \(Int(p))%" }
        if let r = s.targetRpe { return "RPE " + r.rpeText }
        return ""
    }

    private func stepper(_ label: String, value: String, unit: String?, changed: Bool,
                         minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(BrandFont.body(9, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
            HStack(spacing: 0) {
                Button(action: minus) { Image(systemName: "minus").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 46).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
                    if let unit { Text(unit).font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute) }
                }
                .foregroundColor(changed ? Brand.voltText : Brand.text)
                .frame(minWidth: 70)
                Button(action: plus) { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 46).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
            .foregroundColor(Brand.text)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(changed ? Brand.voltLine : Brand.line, lineWidth: 1.5))
        }
    }

    /// A tap on − or +: shown at once, saved a moment after the last tap (several taps, one save).
    private func bump(_ s: ExerciseSet, reps: Int?, lb: Double?) {
        if let reps { draftReps = reps }
        if let lb { draftLb = lb }
        status = .idle
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            let r: Int? = draftReps
            let w: Double? = draftLb
            guard r != nil || w != nil else { return }
            save(s, track: true) { wk in
                PadLivePlan.changeSet(s.id, &wk) { x in
                    if let r { x.targetReps = r }
                    if let w { x.targetWeight = w; x.percent = nil; x.targetRpe = nil }
                }
            }
        }
    }

    /// Saved one after another. `track`: a change to this set's targets ("Changed by you", Undo);
    /// adding or skipping a set isn't one.
    private func save(_ s: ExerciseSet, track: Bool, _ change: @escaping (inout Workout) -> Void) {
        let prev: Task<Void, Never>? = chain
        let phone: PadLivePhone = ctx.phone
        serial += 1
        let mine: Int = serial
        status = .saving
        chain = Task { @MainActor in
            await prev?.value
            do {
                try await PadLivePlan.edit(phone, change)
                if track {
                    if originals[s.id] == nil { originals[s.id] = s }
                    let was: String = "WAS " + PadLiveMath.planText(originals[s.id] ?? s).uppercased()
                    PadLiveLink.shared.update(phone.id) { p in if p.changed[s.id] == nil { p.changed[s.id] = was } }
                }
                if serial == mine { status = .saved }
                PadToasts.shared.show("On \(phone.name.firstName)'s phone and Watch")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if serial == mine, status == .saved { status = .idle }
            } catch {
                if serial == mine { status = .failed }
            }
        }
    }

    private func undo(_ o: ExerciseSet) {
        saveTask?.cancel()
        draftReps = nil; draftLb = nil
        let prev: Task<Void, Never>? = chain
        let phone: PadLivePhone = ctx.phone
        serial += 1
        status = .saving
        chain = Task { @MainActor in
            await prev?.value
            do {
                try await PadLivePlan.edit(phone) { w in
                    PadLivePlan.changeSet(o.id, &w) { x in
                        x.targetReps = o.targetReps; x.targetWeight = o.targetWeight
                        x.percent = o.percent; x.targetRpe = o.targetRpe; x.amrap = o.amrap
                    }
                }
                PadLiveLink.shared.update(phone.id) { p in p.changed[o.id] = nil }
                originals[o.id] = nil
                status = .idle
            } catch {
                status = .failed
            }
        }
    }
}

// MARK: - Notes for next time

struct PadLiveNotesCard: View {
    let ctx: PadLiveCtx
    var compact = false

    @State private var text = ""
    @State private var exercise = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    private let starters: [String] = ["Go up 5 lb", "Same weight, cleaner", "Pause reps", "Slow the lowering", "Brace before the unrack"]

    var body: some View {
        let names: [String] = (ctx.workout?.exercises ?? []).map { $0.name }
        let ex: String = exercise.isEmpty ? ctx.card.exercise : exercise
        let count: Int = ctx.phone.notes.count
        VStack(alignment: .leading, spacing: 10) {
            PadLiveCoachHeader(icon: "note.text", tag: compact ? "NEXT TIME" : "NOTES FOR NEXT TIME",
                               title: count > 0 ? "\(count) FOR \(ctx.firstName.uppercased())" : "\(ctx.firstName.uppercased()) SEES THEM NEXT WORKOUT")
            if !compact {
                ForEach(ctx.phone.notes) { n in
                    HStack(alignment: .top, spacing: 10) {
                        Text(n.exercise.uppercased()).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.mute).frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.text).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text).fixedSize(horizontal: false, vertical: true)
                            Text(n.whereTo).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                    }
                    Rectangle().fill(Brand.line).frame(height: 1)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    ForEach(names, id: \.self) { n in Button(n) { exercise = n } }
                } label: {
                    HStack(spacing: 3) {
                        Text(ex.uppercased()).font(BrandFont.body(11, .heavy)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
                    }
                    .foregroundColor(Brand.mute)
                    .frame(maxWidth: 120, alignment: .leading)
                }
                TextField("Note for \(ctx.firstName)'s next \(ex)…", text: $text, axis: .vertical)
                    .font(BrandFont.body(14)).foregroundColor(Brand.text)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save(ex) }
                Button { save(ex) } label: {
                    Image(systemName: saving ? "ellipsis" : "arrow.up").font(.system(size: 14, weight: .heavy))
                        .foregroundColor(Brand.onVolt).frame(width: 34, height: 34).background(Circle().fill(Brand.volt))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || saving)
                .opacity(trimmed.isEmpty ? 0.4 : 1)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.text.opacity(0.06)))
            if !compact {
                PadLiveFlow(spacing: 6) {
                    ForEach(starters, id: \.self) { st in
                        PadLivePill(text: st) { text = trimmed.isEmpty ? st : trimmed + ". " + st; focused = true }
                    }
                }
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padLiveCard()
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ ex: String) {
        let t: String = trimmed
        guard !t.isEmpty, !saving else { return }
        guard !ex.isEmpty else { PadToasts.shared.show("Pick the exercise the note's for"); return }
        let phone: PadLivePhone = ctx.phone
        saving = true
        Task { @MainActor in
            do {
                let whereTo: String = try await PadLivePlan.saveNote(phone, exercise: ex, text: t)
                PadLiveLink.shared.update(phone.id) { p in p.notes.append(PadLiveNote(exercise: ex, text: t, whereTo: whereTo)) }
                text = ""
                PadToasts.shared.show("Saved for next time")
            } catch {
                PadToasts.shared.show("Couldn't save the note — check the connection")
            }
            saving = false
        }
    }
}

// MARK: - Watch for (only the coach sees it)

struct PadLiveWatchFor: View {
    let ctx: PadLiveCtx
    @ObservedObject private var targets = PadTargets.shared

    var body: some View {
        let c = ctx.card
        let lb: Double = ctx.goalLb
        let reps: Int = max(c.goalReps, 1)
        let e1: Double = PadLiveMath.e1RM(lb, reps)
        let best: Double? = PadLiveMath.bestE1RM(clientId: ctx.clientId, exercise: c.exercise, excluding: ctx.workout?.id)
        let lifts: [PadTarget] = targets.open(ctx.clientId).filter { $0.kind == .lift && $0.lift.lowercased() == c.exercise.lowercased() }
        let isPR: Bool = lb > 0 && c.stage != .done && (best.map { e1 > $0 } ?? false)
        let usual: Double? = ctx.usual
        let now: Double? = ctx.shownSpeeds.last
        if isPR || !lifts.isEmpty || usual != nil {
            VStack(alignment: .leading, spacing: 10) {
                PadLiveCoachHeader(icon: "bolt.fill", tag: "WATCH FOR", title: "ONLY YOU SEE THIS")
                if isPR, let b = best {
                    note("trophy.fill", Brand.voltLine, "PR on the bar",
                         "\(reps) × \(SetTarget.weightText(lb)) is an e1RM of \(SetTarget.weightText(e1)) — best so far \(SetTarget.weightText(b)).")
                }
                if let u = usual {
                    let detail: String = now.map { String(format: "%.2f m/s now; ", $0) } ?? ""
                    note("info.circle", Color(hex: 0x3D9BE0), "Their usual at \(SetTarget.weightText(lb))",
                         detail + String(format: "usually %.2f m/s on rep 1.", u))
                }
                ForEach(lifts) { t in
                    let hit: Bool = t.reps > 0 ? (lb >= t.weight && reps >= t.reps) : (lb > 0 && e1 >= t.weight)
                    let what: String = t.reps > 0 ? "\(t.reps) × \(SetTarget.weightText(t.weight))" : "e1RM \(SetTarget.weightText(t.weight))"
                    note(hit ? "target" : "scope", hit ? Brand.voltLine : Color(hex: 0xF2A03D), "Target “\(t.title)”",
                         what + (hit ? " — this set gets it." : ""))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padLiveCard()
        }
    }

    private func note(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                Text(detail).font(BrandFont.body(11.5)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
