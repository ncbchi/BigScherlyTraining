import SwiftUI

// MARK: - Coach HQ on iPad: build and edit a program (Oct 15, 2026)
//
// Canvas "Programs · 1 — Build and edit on iPad" and "· 2 — New, edit, duplicate, delete". The web's
// program editor (Coach HQ ProgramEditor) laid out for the iPad: the outline on the left (name, what it's
// for, blocks and their days), the picked day on the right with its block's weeks and deload above it.
// Every exercise has its sets in the five set types the workout builder uses (fixed, target RPE, back-off %,
// AMRAP, bodyweight) and "How it progresses" with the fields its method needs. Exercise names search the
// coach's library first, then the standard exercises (ExerciseCatalog), as in the workout builder.
// Saves the whole program with PUT /admin/programs/{id} (POST for a new one); the server tidies it the same
// way it does for the web (ProgramEngine.Sanitize). Anyone already running it keeps their copy.
// Synchronized folder: no target step needed.

// MARK: Editable model

struct PEProgram: Equatable {
    var name = ""
    var about = ""
    var blocks: [PEBlock] = []
    var totalWeeks: Int { blocks.reduce(0) { $0 + max(1, $1.weeks) } }
}

struct PEBlock: Identifiable, Equatable {
    let id = UUID()
    var name = "Block 1"
    var weeks = 4
    var deloadLast = false
    var days: [PEDay] = []
}

struct PEDay: Identifiable, Equatable {
    let id = UUID()
    var title = "Day"
    var weekday = 0            // 0 = Monday
    var exercises: [PEExercise] = []
}

struct PESet: Identifiable, Equatable {
    let id = UUID()
    var kind: SetKind = .fixed
    var reps = "5"
    var weight = ""             // in the coach's unit
    var rpe = ""
    var percent = ""            // typed as a positive number ("15" = 15% lighter)
    func copy() -> PESet { PESet(kind: kind, reps: reps, weight: weight, rpe: rpe, percent: percent) }
}

struct PEExercise: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var muscle = ""
    var rest = "120"
    var notes = ""              // coach notes: kept as they were (Coach HQ edits them)
    var sets: [PESet] = [PESet()]
    var method = "linear"
    var increment = "5"
    var pct = ""
    var pctStep = ""
    var repMin = ""
    var repMax = ""
    var targetRpe = ""
    var velMin = ""
    var velMax = ""
    var maxSets = ""
    func copy() -> PEExercise {
        var x = PEExercise()
        x.name = name; x.muscle = muscle; x.rest = rest; x.notes = notes; x.sets = sets.map { $0.copy() }
        x.method = method; x.increment = increment; x.pct = pct; x.pctStep = pctStep; x.repMin = repMin; x.repMax = repMax
        x.targetRpe = targetRpe; x.velMin = velMin; x.velMax = velMax; x.maxSets = maxSets
        return x
    }
}

// MARK: Reading and writing the server's ProgramDoc

private struct PEIn: Decodable {
    let id: String
    let name: String
    let description: String?
    let doc: Doc
    struct Doc: Decodable { let blocks: [Block]? }
    struct Block: Decodable { let name: String?; let weeks: Int?; let deloadLast: Bool?; let days: [Day]? }
    struct Day: Decodable { let title: String?; let weekday: Int?; let exercises: [Ex]? }
    struct Ex: Decodable {
        let name: String?; let muscleGroup: String?; let restSeconds: Int?; let coachNotes: String?
        let sets: [SetD]?; let progression: Prog?
    }
    struct SetD: Decodable { let reps: Int?; let weight: Double?; let rpe: Double?; let percent: Double?; let amrap: Bool? }
    struct Prog: Decodable {
        let method: String?; let increment: Double?; let pct: Double?; let pctStep: Double?
        let repMin: Int?; let repMax: Int?; let targetRpe: Double?; let velMin: Double?; let velMax: Double?; let maxSets: Int?
    }
}

enum PEConvert {
    static func clean(_ d: Double?) -> String {
        guard let d else { return "" }
        let r = (d * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
    static func num(_ s: String) -> Double? {
        // Finite and in a sane range only: Int(_:) traps on nan, infinity or a huge value ("1e999").
        guard let d = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), d.isFinite, abs(d) < 1_000_000 else { return nil }
        return d
    }
    static func toShown(_ lb: Double) -> Double { StatsUnits.isKg ? lb * 0.45359237 : lb }
    static func toLb(_ shown: Double) -> Double { StatsUnits.isKg ? shown / 0.45359237 : shown }

    fileprivate static func program(_ p: PEIn) -> PEProgram {
        var out = PEProgram(name: p.name, about: p.description ?? "", blocks: [])
        for b in p.doc.blocks ?? [] {
            var blk = PEBlock(name: b.name ?? "Block", weeks: b.weeks ?? 4, deloadLast: b.deloadLast ?? false, days: [])
            for d in b.days ?? [] {
                var day = PEDay(title: d.title ?? "Day", weekday: min(max(d.weekday ?? 0, 0), 6), exercises: [])
                for e in d.exercises ?? [] {
                    var x = PEExercise()
                    x.name = e.name ?? ""; x.muscle = e.muscleGroup ?? ""; x.rest = "\(e.restSeconds ?? 90)"; x.notes = e.coachNotes ?? ""
                    x.sets = (e.sets ?? []).map { s in
                        var o = PESet()
                        o.reps = "\(s.reps ?? 0)"
                        let w = s.weight ?? 0
                        if s.percent != nil { o.kind = .backoff; o.percent = clean(abs(s.percent ?? 0)) }
                        else if s.rpe != nil { o.kind = .rpe; o.rpe = clean(s.rpe) }
                        else if s.amrap == true { o.kind = .amrap; o.weight = w > 0 ? clean(toShown(w)) : ""; if (s.reps ?? 0) == 0 { o.reps = "" } }
                        else if w > 0 { o.kind = .fixed; o.weight = clean(toShown(w)) }
                        else { o.kind = .bw }
                        return o
                    }
                    if x.sets.isEmpty { x.sets = [PESet()] }
                    if let pr = e.progression {
                        x.method = pr.method ?? "manual"
                        x.increment = clean(pr.increment ?? 5)
                        x.pct = clean(pr.pct); x.pctStep = clean(pr.pctStep)
                        x.repMin = pr.repMin.map(String.init) ?? ""; x.repMax = pr.repMax.map(String.init) ?? ""
                        x.targetRpe = clean(pr.targetRpe); x.velMin = clean(pr.velMin); x.velMax = clean(pr.velMax)
                        x.maxSets = pr.maxSets.map(String.init) ?? ""
                    } else {
                        x.method = "manual"
                    }
                    day.exercises.append(x)
                }
                blk.days.append(day)
            }
            out.blocks.append(blk)
        }
        return out
    }

    /// The body for POST / PUT /admin/programs: {name, description, doc}.
    static func body(_ p: PEProgram) -> [String: Any] {
        let blocks: [[String: Any]] = p.blocks.map { b in
            let days: [[String: Any]] = b.days.map { d in
                let exs: [[String: Any]] = d.exercises
                    .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { e in exercise(e) }
                return ["title": d.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Day" : d.title, "weekday": d.weekday, "exercises": exs]
            }
            return ["name": b.name, "weeks": max(1, min(16, b.weeks)), "deloadLast": b.deloadLast, "days": days]
        }
        return ["name": p.name.trimmingCharacters(in: .whitespaces), "description": p.about.trimmingCharacters(in: .whitespaces), "doc": ["blocks": blocks]]
    }

    private static func exercise(_ e: PEExercise) -> [String: Any] {
        let sets: [[String: Any]] = e.sets.map { s in
            let reps = Int(num(s.reps) ?? 0)
            var o: [String: Any] = ["reps": reps, "weight": 0.0]
            switch s.kind {
            case .fixed: o["weight"] = toLb(num(s.weight) ?? 0)
            case .rpe: if let r = num(s.rpe) { o["rpe"] = min(max(r, 1), 10) } else { o["rpe"] = 8.0 }
            case .backoff: o["percent"] = -abs(num(s.percent) ?? 15)
            case .amrap: o["amrap"] = true; o["weight"] = toLb(num(s.weight) ?? 0)
            case .bw: break
            }
            return o
        }
        var prog: [String: Any] = ["method": e.method, "increment": num(e.increment) ?? 5]
        func put(_ key: String, _ v: String, int: Bool = false) {
            guard let d = num(v) else { return }
            prog[key] = int ? Int(d) : d
        }
        put("pct", e.pct); put("pctStep", e.pctStep); put("repMin", e.repMin, int: true); put("repMax", e.repMax, int: true)
        put("targetRpe", e.targetRpe); put("velMin", e.velMin); put("velMax", e.velMax); put("maxSets", e.maxSets, int: true)
        return ["name": e.name.trimmingCharacters(in: .whitespaces), "muscleGroup": e.muscle.trimmingCharacters(in: .whitespaces),
                "restSeconds": Int(num(e.rest) ?? 90), "coachNotes": e.notes, "sets": sets, "progression": prog]
    }
}

extension APIClient {
    fileprivate func programForEditing(_ id: String) async throws -> PEIn {
        try decoder.decode(PEIn.self, from: try await request("/admin/programs/\(id)", method: "GET"))
    }
    /// Saves a program; returns its id (new or the same).
    func saveProgram(id: String?, body: [String: Any]) async throws -> String {
        struct R: Decodable { let id: String }
        let data = try await mailCall(id.map { "/admin/programs/\($0)" } ?? "/admin/programs", method: id == nil ? "POST" : "PUT", body: body)
        return try decoder.decode(R.self, from: data).id
    }
    func deleteProgram(id: String) async throws {
        _ = try await mailCall("/admin/programs/\(id)", method: "DELETE")
    }
}

// MARK: - The editor

struct PadProgramEditor: View {
    /// nil = a new program.
    var programId: String?
    var onSaved: (String?) -> Void = { _ in }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = ExerciseCatalog.shared

    @State private var pid: String?
    @State private var p = PEProgram()
    @State private var saved = PEProgram()
    @State private var loading = false
    @State private var loadError: String?
    @State private var saving = false
    @State private var error: String?
    @State private var dayId: UUID?
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @State private var assigning = false
    @State private var started = false

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let short = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var dirty: Bool { p != saved }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Pad.line).frame(height: 1)
            if loading {
                VStack(alignment: .leading, spacing: 12) { PadSkeleton(height: 44); PadSkeleton(height: 200); PadSkeleton(height: 200) }.padding(20)
                Spacer(minLength: 0)
            } else if let loadError {
                VStack(spacing: 8) {
                    Text("Couldn't open it.").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                    PadLab(loadError, size: 13)
                    Button("Try again") { Task { await load() } }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { g in
                    if g.size.width >= 760 {
                        HStack(spacing: 0) {
                            ScrollView { outline.padding(14) }.frame(width: 280).background(Pad.page)
                            Rectangle().fill(Pad.line).frame(width: 1)
                            ScrollView { detail.padding(20) }.frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) { outline; Rectangle().fill(Pad.line).frame(height: 1); detail }.padding(16)
                        }
                    }
                }
            }
        }
        .background(Pad.surface.ignoresSafeArea())
        .presentationSizing(.page)
        .interactiveDismissDisabled(dirty)
        .task {
            guard !started else { return }
            started = true
            await catalog.load()
            if programId != nil { await load() } else { startNew() }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Save") { Task { if await save() { dismiss() } } }
        }
        .confirmationDialog("Delete this program?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete “\(p.name)”", role: .destructive) { remove() }
        } message: { Text("Anyone already on it keeps their sessions.") }
        .sheet(isPresented: $assigning) {
            if let pid {
                AssignProgramSheet(programId: pid, programName: p.name) {
                    Task { await PadData.shared.refresh(roster: store.roster) }
                }
                .environmentObject(store)
            }
        }
        .background(
            Button("Save") { Task { _ = await save() } }
                .keyboardShortcut("s", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        )
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Cancel") { if dirty { confirmDiscard = true } else { dismiss() } }
                .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
            Spacer(minLength: 6)
            VStack(spacing: 1) {
                PadLab(pid == nil ? "NEW PROGRAM" : (dirty ? "PROGRAM · NOT SAVED" : "PROGRAM"), color: dirty ? Pad.orange : Pad.mute, size: 12)
                Text(p.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled program" : p.name)
                    .font(PadFont.ui(17, .bold)).foregroundColor(Pad.text).lineLimit(1)
            }
            Spacer(minLength: 6)
            if pid != nil {
                Button { Task { if dirty { guard await save() else { return } }; assigning = true } } label: { Label("Assign", systemImage: "calendar.badge.plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            Button { Task { _ = await save() } } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().tint(Pad.onVolt).controlSize(.small) } else { Image(systemName: "checkmark") }
                    Text("Save")
                }
            }
            .buttonStyle(PadButtonStyle(kind: .primary, small: true))
            .disabled(saving)
        }
        .padding(.horizontal, 16).frame(minHeight: 60)
    }

    // MARK: Outline

    private var outline: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name", $p.name, prompt: "e.g. Strength Base · 3-Day")
            field("What it's for", $p.about, prompt: "One line for you and your clients")
            PadLab(summary, size: 12).padding(.top, 2)
            if let error { Text(error).font(PadFont.ui(13)).foregroundColor(Pad.orange).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(p.blocks.enumerated()), id: \.element.id) { bi, b in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(b.name.isEmpty ? "Block \(bi + 1)" : b.name).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text).lineLimit(1)
                        Spacer(minLength: 4)
                        PadLab("\(b.weeks) wk" + (b.deloadLast ? " · deload" : ""), size: 12)
                    }
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                    ForEach(b.days) { d in
                        let on = d.id == dayId
                        Button { dayId = d.id } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(Self.short[min(max(d.weekday, 0), 6)]) · \(d.title.isEmpty ? "Day" : d.title)")
                                        .font(PadFont.ui(14, on ? .bold : .semibold)).foregroundColor(Pad.text).lineLimit(1)
                                    PadLab(d.exercises.isEmpty ? "no exercises" : "\(d.exercises.count) exercise\(d.exercises.count == 1 ? "" : "s")", size: 12)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 22).padding(.trailing, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Pad.raised : Color.clear))
                            .overlay(alignment: .leading) { if on { RoundedRectangle(cornerRadius: 2).fill(Pad.volt).frame(width: 3).padding(.vertical, 6) } }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                    }
                    Button { addDay(to: bi) } label: { Label("Add day", systemImage: "plus") }
                        .font(PadFont.cond(13)).foregroundColor(Pad.voltText)
                        .padding(.leading, 22).padding(.vertical, 6)
                        .disabled(b.days.count >= 7)
                }
            }
            Button { addBlock() } label: { Label("Add block", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                .disabled(p.blocks.count >= 12)
                .padding(.top, 6)
            if pid != nil {
                Button("Delete program", role: .destructive) { confirmDelete = true }
                    .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.red)
                    .padding(.top, 8)
            }
        }
    }

    private var summary: String {
        let n = p.blocks.count
        var deloads: [Int] = []
        var w = 0
        for b in p.blocks { w += b.weeks; if b.deloadLast { deloads.append(w) } }
        let dl: String = deloads.isEmpty ? "" : " · deload in week" + (deloads.count == 1 ? " " : "s ") + deloads.map(String.init).joined(separator: " and ")
        return "\(n) block\(n == 1 ? "" : "s") · \(p.totalWeeks) weeks" + dl
    }

    // MARK: The picked day (and its block)

    private var where_: (block: Int, day: Int)? {
        for (bi, b) in p.blocks.enumerated() {
            if let di = b.days.firstIndex(where: { $0.id == dayId }) { return (bi, di) }
        }
        return nil
    }

    @ViewBuilder private var detail: some View {
        if let w = where_ {
            VStack(alignment: .leading, spacing: 14) {
                blockStrip(w.block)
                dayHead(w.block, w.day)
                ForEach(p.blocks[w.block].days[w.day].exercises) { x in
                    exerciseCard(w.block, w.day, x)
                }
                HStack(spacing: 10) {
                    Button { addExercise(w.block, w.day) } label: { Label("Add exercise", systemImage: "plus") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        .disabled(p.blocks[w.block].days[w.day].exercises.count >= 20)
                    PadLab("Names come from your library first, then the standard exercises.", color: Pad.faint, size: 12)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundColor(Pad.faint)
                Text("Pick a day").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                PadLab("Or add one under a block.", size: 13)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    /// Bindings found by id, so removing a block or day while its field is focused can't write to a stale position.
    private func blockBinding(_ id: UUID) -> Binding<PEBlock> {
        Binding(get: { p.blocks.first(where: { $0.id == id }) ?? PEBlock() },
                set: { new in if let i = p.blocks.firstIndex(where: { $0.id == id }) { p.blocks[i] = new } })
    }

    private func dayBinding(_ id: UUID) -> Binding<PEDay> {
        Binding(get: {
            for b in p.blocks { if let d = b.days.first(where: { $0.id == id }) { return d } }
            return PEDay()
        }, set: { new in
            for bi in p.blocks.indices {
                if let di = p.blocks[bi].days.firstIndex(where: { $0.id == id }) { p.blocks[bi].days[di] = new; return }
            }
        })
    }

    private func blockStrip(_ bi: Int) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            field("Block \(bi + 1)", blockBinding(p.blocks[bi].id).name, prompt: "e.g. Base")
            VStack(alignment: .leading, spacing: 4) {
                PadLab("Weeks", size: 12)
                Stepper(value: blockBinding(p.blocks[bi].id).weeks, in: 1...16) {
                    Text("\(p.blocks[bi].weeks)").font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).monospacedDigit()
                }
                .frame(width: 140)
            }
            Toggle(isOn: blockBinding(p.blocks[bi].id).deloadLast) { Text("Deload last week").font(PadFont.ui(14)).foregroundColor(Pad.text) }
                .tint(Pad.volt).fixedSize()
                .padding(.bottom, 6)
            if p.blocks.count > 1 {
                PadIconButton(systemName: "trash", label: "Remove this block", small: true, tint: Pad.mute) { removeBlock(bi) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.page))
    }

    private func dayHead(_ bi: Int, _ di: Int) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            field("Day", dayBinding(p.blocks[bi].days[di].id).title, prompt: "e.g. Squat Day")
            VStack(alignment: .leading, spacing: 4) {
                PadLab("On", size: 12)
                Menu {
                    ForEach(0..<7, id: \.self) { i in Button(Self.weekdays[i]) { dayBinding(p.blocks[bi].days[di].id).wrappedValue.weekday = i } }
                } label: {
                    HStack {
                        Text(Self.weekdays[min(max(p.blocks[bi].days[di].weekday, 0), 6)]).font(PadFont.ui(15)).foregroundColor(Pad.text)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Pad.mute)
                    }
                    .padding(.horizontal, 12).frame(width: 160, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
                }
            }
            PadIconButton(systemName: "trash", label: "Remove this day", small: true, tint: Pad.mute) { removeDay(bi, di) }
        }
    }

    // MARK: One exercise

    /// A binding found by id each time, so removing or moving exercises never reads past the end.
    private func exBinding(_ x: PEExercise) -> Binding<PEExercise> {
        Binding(get: {
            for b in p.blocks { for d in b.days { if let e = d.exercises.first(where: { $0.id == x.id }) { return e } } }
            return x
        }, set: { new in
            for bi in p.blocks.indices {
                for di in p.blocks[bi].days.indices {
                    if let ei = p.blocks[bi].days[di].exercises.firstIndex(where: { $0.id == x.id }) {
                        p.blocks[bi].days[di].exercises[ei] = new
                        return
                    }
                }
            }
        })
    }

    private func exerciseCard(_ bi: Int, _ di: Int, _ x: PEExercise) -> some View {
        let ex: Binding<PEExercise> = exBinding(x)
        let list = p.blocks.indices.contains(bi) && p.blocks[bi].days.indices.contains(di) ? p.blocks[bi].days[di].exercises : []
        let ei: Int = list.firstIndex(where: { $0.id == x.id }) ?? 0
        let count = list.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { moveExercise(bi, di, ei, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }.disabled(ei == 0)
                    Button { moveExercise(bi, di, ei, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }.disabled(ei >= count - 1)
                    Button { duplicateExercise(bi, di, ei) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { removeExercise(bi, di, ei) } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 15, weight: .semibold)).foregroundColor(Pad.mute)
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Exercise \(ei + 1) actions")
                VStack(alignment: .leading, spacing: 4) {
                    PadLab("Exercise \(ei + 1)", size: 12)
                    PadExerciseNameField(name: ex.name) { x in
                        ex.wrappedValue.name = x.name
                        if ex.wrappedValue.muscle.isEmpty { ex.wrappedValue.muscle = x.muscleGroup }
                        if x.restSeconds > 0 { ex.wrappedValue.rest = "\(x.restSeconds)" }
                        let s = ex.wrappedValue.sets
                        if s.count == 1 && s[0].weight.isEmpty && x.defaultSets > 0 {
                            ex.wrappedValue.sets = (0..<x.defaultSets).map { _ in PESet(kind: x.defaultReps > 0 ? .fixed : .bw, reps: x.defaultReps > 0 ? "\(x.defaultReps)" : "") }
                        }
                    }
                }
                field("Muscle", ex.muscle, prompt: "e.g. Legs").frame(width: 150)
                field("Rest s", ex.rest, prompt: "90", keyboard: .numberPad).frame(width: 84)
            }
            VStack(spacing: 6) {
                ForEach(Array(ex.wrappedValue.sets.enumerated()), id: \.element.id) { si, set in setRow(ex, si, set.id) }
            }
            HStack(spacing: 8) {
                Button {
                    let last = ex.wrappedValue.sets.last?.copy() ?? PESet()
                    if ex.wrappedValue.sets.count < 15 { ex.wrappedValue.sets.append(last) }
                } label: { Label("Set", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    .disabled(ex.wrappedValue.sets.count >= 15)
            }
            Rectangle().fill(Pad.line).frame(height: 1)
            progression(ex)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.page))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func setRow(_ ex: Binding<PEExercise>, _ si: Int, _ setId: UUID) -> some View {
        let s: Binding<PESet> = Binding(get: { ex.wrappedValue.sets.first(where: { $0.id == setId }) ?? PESet() },
                                        set: { new in
                                            var e = ex.wrappedValue
                                            if let i = e.sets.firstIndex(where: { $0.id == setId }) { e.sets[i] = new; ex.wrappedValue = e }
                                        })
        let kind = s.wrappedValue.kind
        return HStack(spacing: 8) {
            Text("Set \(si + 1)").font(PadFont.cond(13)).foregroundColor(Pad.mute).frame(width: 46, alignment: .leading)
            Menu {
                ForEach(SetKind.allCases, id: \.self) { k in
                    Button { setKind(s, k) } label: { if k == kind { Label(k.rawValue, systemImage: "checkmark") } else { Text(k.rawValue) } }
                }
            } label: {
                HStack {
                    Text(kind.rawValue).font(PadFont.ui(14)).foregroundColor(Pad.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundColor(Pad.mute)
                }
                .padding(.horizontal, 10).frame(width: 150, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
            }
            .accessibilityLabel("Set \(si + 1) type, \(kind.rawValue)")
            small(s.reps, prompt: kind == .amrap ? "min" : "reps", width: 70, keyboard: .numberPad)
            Text(kind == .amrap ? "min reps" : "reps").font(PadFont.cond(12)).foregroundColor(Pad.faint).frame(width: 52, alignment: .leading)
            switch kind {
            case .fixed:
                small(s.weight, prompt: "135", width: 96, keyboard: .decimalPad)
                unit(StatsUnits.weightLabel)
            case .amrap:
                small(s.weight, prompt: "0 = BW", width: 96, keyboard: .decimalPad)
                unit(StatsUnits.weightLabel)
            case .rpe:
                small(s.rpe, prompt: "8", width: 96, keyboard: .decimalPad)
                unit("RPE")
            case .backoff:
                small(s.percent, prompt: "15", width: 96, keyboard: .decimalPad)
                unit("% lighter")
            case .bw:
                Color.clear.frame(width: 96 + 8 + 70, height: 1)
            }
            if !kind.tag.isEmpty {
                Text(kind == .rpe ? "TOP" : kind.tag).font(PadFont.cond(11, .bold)).foregroundColor(Pad.voltText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Pad.voltText.opacity(0.45), lineWidth: 1))
            }
            Spacer(minLength: 0)
            Button { if ex.wrappedValue.sets.count > 1 { ex.wrappedValue.sets.removeAll { $0.id == setId } } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Pad.faint).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(ex.wrappedValue.sets.count <= 1)
            .accessibilityLabel("Remove set \(si + 1)")
        }
    }

    private func setKind(_ s: Binding<PESet>, _ k: SetKind) {
        var n = s.wrappedValue
        n.kind = k
        if k == .fixed && n.weight.isEmpty { n.weight = StatsUnits.isKg ? "60" : "135" }
        if k == .rpe && n.rpe.isEmpty { n.rpe = "8" }
        if k == .backoff && n.percent.isEmpty { n.percent = "15" }
        s.wrappedValue = n
    }

    private func progression(_ ex: Binding<PEExercise>) -> some View {
        let m = ex.wrappedValue.method
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    PadLab("How it progresses", size: 12)
                    Menu {
                        ForEach(ProgressionMethod.all, id: \.id) { x in
                            Button { ex.wrappedValue.method = x.id } label: {
                                if x.id == m { Label(x.name, systemImage: "checkmark") } else { Text(x.name) }
                            }
                        }
                    } label: {
                        HStack {
                            Text(ProgressionMethod.name(m)).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Pad.mute)
                        }
                        .padding(.horizontal, 12).frame(width: 260, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
                    }
                }
                Text(ProgressionMethod.about(m)).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            let params = paramFields(m)
            if !params.isEmpty {
                HStack(spacing: 10) {
                    ForEach(params, id: \.label) { pf in
                        field(pf.label, paramBinding(ex, pf.key), prompt: pf.hint, keyboard: .decimalPad).frame(width: 140)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private struct ParamField { let key: String; let label: String; let hint: String }

    /// The same fields Coach HQ asks for, per method.
    private func paramFields(_ m: String) -> [ParamField] {
        var out: [ParamField] = []
        if !["manual", "topset", "pct1rm", "auto"].contains(m) { out.append(ParamField(key: "increment", label: "+ per step (lb)", hint: "5")) }
        if m == "pct1rm" {
            out.append(ParamField(key: "pct", label: "Start % of 1RM", hint: "70"))
            out.append(ParamField(key: "pctStep", label: "+ % per week", hint: "2.5"))
            out.append(ParamField(key: "increment", label: "Fallback + lb/wk", hint: "5"))
        }
        if m == "auto" { out.append(ParamField(key: "pct", label: "% of e1RM", hint: "80")) }
        if m == "double" {
            out.append(ParamField(key: "repMin", label: "Rep range min", hint: "8"))
            out.append(ParamField(key: "repMax", label: "Rep range max", hint: "12"))
        }
        if m == "rpe" { out.append(ParamField(key: "targetRpe", label: "Target RPE", hint: "8")) }
        if m == "velocity" {
            out.append(ParamField(key: "velMin", label: "Zone min m/s", hint: "0.5"))
            out.append(ParamField(key: "velMax", label: "Zone max m/s", hint: "0.75"))
        }
        if m == "volume" { out.append(ParamField(key: "maxSets", label: "Max sets", hint: "6")) }
        return out
    }

    private func paramBinding(_ ex: Binding<PEExercise>, _ key: String) -> Binding<String> {
        switch key {
        case "pct": return ex.pct
        case "pctStep": return ex.pctStep
        case "repMin": return ex.repMin
        case "repMax": return ex.repMax
        case "targetRpe": return ex.targetRpe
        case "velMin": return ex.velMin
        case "velMax": return ex.velMax
        case "maxSets": return ex.maxSets
        default: return ex.increment
        }
    }

    // MARK: Fields

    private func field(_ label: String, _ text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PadLab(label, size: 12)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(Pad.faint))
                .keyboardType(keyboard)
                .padInput()
        }
    }

    private func small(_ text: Binding<String>, prompt: String, width: CGFloat, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(Pad.faint))
            .keyboardType(keyboard)
            .multilineTextAlignment(.trailing)
            .font(PadFont.ui(15)).foregroundColor(Pad.text)
            .padding(.horizontal, 10).frame(width: width, height: 40)
            .background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
    }

    private func unit(_ t: String) -> some View {
        Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint).frame(width: 70, alignment: .leading)
    }

    // MARK: Changing the shape

    private func newDay(_ weekday: Int) -> PEDay { PEDay(title: "Day", weekday: weekday, exercises: [PEExercise()]) }

    private func startNew() {
        let d = newDay(0)
        p = PEProgram(name: "", about: "", blocks: [PEBlock(name: "Block 1", weeks: 4, deloadLast: false, days: [d])])
        saved = PEProgram(name: "", about: "", blocks: [])
        dayId = d.id
    }

    private func addBlock() {
        let d = newDay(0)
        p.blocks.append(PEBlock(name: "Block \(p.blocks.count + 1)", weeks: 4, deloadLast: false, days: [d]))
        dayId = d.id
    }

    private func removeBlock(_ bi: Int) {
        guard p.blocks.count > 1, p.blocks.indices.contains(bi) else { return }
        p.blocks.remove(at: bi)
        dayId = p.blocks[min(bi, p.blocks.count - 1)].days.first?.id ?? p.blocks.first?.days.first?.id
    }

    private func addDay(to bi: Int) {
        let last = p.blocks[bi].days.last?.weekday ?? -2
        let d = newDay(min(6, last + 2))
        p.blocks[bi].days.append(d)
        dayId = d.id
    }

    private func removeDay(_ bi: Int, _ di: Int) {
        guard p.blocks.indices.contains(bi), p.blocks[bi].days.indices.contains(di) else { return }
        p.blocks[bi].days.remove(at: di)
        let ds = p.blocks[bi].days
        dayId = ds.isEmpty ? p.blocks.flatMap { $0.days }.first?.id : ds[min(di, ds.count - 1)].id
    }

    private func addExercise(_ bi: Int, _ di: Int) { p.blocks[bi].days[di].exercises.append(PEExercise()) }

    private func removeExercise(_ bi: Int, _ di: Int, _ ei: Int) {
        guard p.blocks[bi].days[di].exercises.indices.contains(ei) else { return }
        p.blocks[bi].days[di].exercises.remove(at: ei)
    }

    private func duplicateExercise(_ bi: Int, _ di: Int, _ ei: Int) {
        let x = p.blocks[bi].days[di].exercises[ei].copy()
        p.blocks[bi].days[di].exercises.insert(x, at: ei + 1)
    }

    private func moveExercise(_ bi: Int, _ di: Int, _ ei: Int, by delta: Int) {
        let to = ei + delta
        guard p.blocks[bi].days[di].exercises.indices.contains(to) else { return }
        p.blocks[bi].days[di].exercises.swapAt(ei, to)
    }

    // MARK: Server

    private func load() async {
        guard let id = programId else { return }
        loading = true; loadError = nil
        do {
            let x = try await APIClient.shared.programForEditing(id)
            p = PEConvert.program(x)
            if p.blocks.isEmpty { p.blocks = [PEBlock(name: "Block 1", weeks: 4, deloadLast: false, days: [newDay(0)])] }
            saved = p
            pid = x.id
            dayId = p.blocks.first?.days.first?.id
        } catch {
            loadError = (error as? APIClient.APIError)?.message ?? "Check your connection and try again."
        }
        loading = false
    }

    /// Saves; true when it worked.
    private func save() async -> Bool {
        guard !saving else { return false }
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { error = "Give the program a name."; return false }
        if p.blocks.allSatisfy({ $0.days.allSatisfy { $0.exercises.allSatisfy { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } } }) {
            error = "Add at least one exercise with a name."; return false
        }
        saving = true; error = nil
        do {
            let id = try await APIClient.shared.saveProgram(id: pid, body: PEConvert.body(p))
            pid = id
            // Read it back the way the server tidied it, keeping the open day where possible.
            let pos = where_
            if let x = try? await APIClient.shared.programForEditing(id) {
                p = PEConvert.program(x)
                if let pos, p.blocks.indices.contains(pos.block), p.blocks[pos.block].days.indices.contains(pos.day) {
                    dayId = p.blocks[pos.block].days[pos.day].id
                } else {
                    dayId = p.blocks.first?.days.first?.id
                }
            }
            saved = p
            saving = false
            PadToasts.shared.show("Program saved")
            onSaved(id)
            return true
        } catch {
            saving = false
            self.error = (error as? APIClient.APIError)?.message ?? "Couldn't save. Check your connection and try again."
            return false
        }
    }

    private func remove() {
        guard let pid else { return }
        Task {
            do {
                try await APIClient.shared.deleteProgram(id: pid)
                PadToasts.shared.show("Deleted “\(p.name)”")
                onSaved(nil)
                dismiss()
            } catch {
                self.error = (error as? APIClient.APIError)?.message ?? "Couldn't delete it."
            }
        }
    }
}

// MARK: - Exercise name with suggestions (library first), in the iPad look

struct PadExerciseNameField: View {
    @Binding var name: String
    let onPick: (APICatalogExercise) -> Void
    @ObservedObject private var catalog = ExerciseCatalog.shared
    @FocusState private var focused: Bool
    @State private var browsing = false
    @State private var justPicked = false

    private var query: String { name.trimmingCharacters(in: .whitespaces) }
    private var suggestions: [APICatalogExercise] {
        if query.isEmpty { return Array(catalog.items.filter { $0.isMine }.prefix(6)) }
        return catalog.search(query, limit: 7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("", text: $name, prompt: Text("Type or pick").foregroundColor(Pad.faint))
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, _ in if focused { justPicked = false } }
                    .onSubmit { if let top = suggestions.first, top.name.lowercased() == query.lowercased() { pick(top) } }
                Button { focused = false; browsing = true } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .heavy)).foregroundColor(Pad.onVolt)
                        .frame(width: 26, height: 26).background(Circle().fill(Pad.volt))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse all exercises")
            }
            .padInput()
            if focused && !justPicked {
                let list = suggestions
                VStack(alignment: .leading, spacing: 0) {
                    if !catalog.loaded {
                        PadLab("Loading exercises…", size: 12).padding(10)
                    } else if list.isEmpty {
                        PadLab(query.isEmpty ? "Type to search, or tap ⌄ to browse." : "No match: “\(query)” stays as typed.", size: 12).padding(10)
                    } else {
                        ForEach(list, id: \.stableId) { x in
                            Button { pick(x) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(x.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                                        if !x.detail.isEmpty { PadLab(x.detail, size: 12).lineLimit(1) }
                                    }
                                    Spacer(minLength: 4)
                                    if x.isMine { PadTag(text: "Yours", kind: .volt) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Pad.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
            }
        }
        .sheet(isPresented: $browsing) {
            ExercisePickerSheet(current: name) { x in
                browsing = false
                pick(x)
            }
        }
    }

    private func pick(_ x: APICatalogExercise) {
        justPicked = true
        name = x.name
        focused = false
        onPick(x)
    }
}
