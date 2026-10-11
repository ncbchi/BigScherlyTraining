import SwiftUI

// MARK: - Coach ▸ Programs (Oct 8, 2026)
//
// Phone side of programs: the library, a program's full plan, assigning it to a client
// (or yourself) from a start date, who's running what, and the automatic changes the
// progression engine made — each with Undo. Building and editing programs lives in
// Coach HQ on the web (desktop has the room for blocks × days × sets).
// Synchronized folder: no target step needed.

// MARK: API models

struct APIProgramSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let weeks: Int
    let daysPerWeek: Int
    let blocks: Int
    let activeAssignments: Int
    let updatedAt: Date
}

struct APIProgramDoc: Decodable {
    let blocks: [Block]
    struct Block: Decodable { let name: String; let weeks: Int; let deloadLast: Bool?; let days: [Day] }
    struct Day: Decodable { let title: String; let weekday: Int; let exercises: [Ex] }
    struct Ex: Decodable {
        let name: String; let muscleGroup: String?; let restSeconds: Int?
        let sets: [SetD]; let progression: Prog?
    }
    struct SetD: Decodable { let reps: Int; let weight: Double?; let rpe: Double?; let percent: Double?; let amrap: Bool? }
    struct Prog: Decodable {
        let method: String; let increment: Double?; let pct: Double?; let pctStep: Double?
        let repMin: Int?; let repMax: Int?; let targetRpe: Double?; let velMin: Double?; let velMax: Double?; let maxSets: Int?
    }
}

struct APIProgramDetail: Decodable {
    let id: String
    let name: String
    let description: String
    let doc: APIProgramDoc
    let weeks: Int
}

struct APIAssignment: Decodable, Identifiable {
    let id: String
    let clientId: String
    let clientName: String
    let programId: String
    let programName: String
    let startDate: Date
    let endDate: Date
    let totalWeeks: Int
    let currentWeek: Int
    let sessionsDone: Int
    let sessionsTotal: Int
    let status: String
}

struct APIProgressionChange: Decodable, Identifiable {
    let id: String
    let clientId: String
    let clientName: String
    let exerciseName: String
    let method: String
    let summary: String
    let reason: String
    let setsChanged: Int
    let createdAt: Date
    let undoneAt: Date?
}

struct APIAssignResult: Decodable { let id: String; let workouts: Int }
struct APIUndoResult: Decodable { let restored: Int }

extension APIClient {
    func programs() async throws -> [APIProgramSummary] { try await get("/admin/programs") }
    func program(_ id: String) async throws -> APIProgramDetail { try await get("/admin/programs/\(id)") }
    func assignProgram(_ id: String, clientId: String, start: Date) async throws -> APIAssignResult {
        let c = Calendar.training.dateComponents([.year, .month, .day], from: start)
        let stamp = String(format: "%04ld-%02ld-%02ldT00:00:00", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
        let data = try await request("/admin/programs/\(id)/assign", method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: ["clientId": clientId, "startDate": stamp]))
        return try decoder.decode(APIAssignResult.self, from: data)
    }
    func assignments(clientId: String? = nil) async throws -> [APIAssignment] {
        try await get("/admin/assignments" + (clientId.map { "?clientId=\($0)" } ?? ""))
    }
    func endAssignment(_ id: String) async throws { _ = try await request("/admin/assignments/\(id)/end", method: "POST") }
    func progressionChanges(clientId: String? = nil, days: Int = 14) async throws -> [APIProgressionChange] {
        try await get("/admin/progression-changes?days=\(days)" + (clientId.map { "&clientId=\($0)" } ?? ""))
    }
    @discardableResult
    func undoProgressionChange(_ id: String) async throws -> APIUndoResult {
        let data = try await request("/admin/progression-changes/\(id)/undo", method: "POST")
        return try decoder.decode(APIUndoResult.self, from: data)
    }
}

// MARK: Methods (same wording as Coach HQ)

enum ProgressionMethod {
    static let all: [(id: String, name: String, about: String)] = [
        ("manual", "By hand", "Sets stay exactly as written."),
        ("linear", "Linear", "Adds the increment every week."),
        ("pct1rm", "% of 1RM", "Weights from their est. 1RM: a start % plus a step each week."),
        ("waves", "Waves", "Three weeks up, the 4th drops 10%. Each wave starts higher."),
        ("volume", "Volume ramp", "Adds a set each week, up to the max."),
        ("topset", "Top set → back-offs", "A top set by RPE drives the back-off weights."),
        ("double", "Double progression", "Adds reps to the top of the range, then adds weight."),
        ("rpe", "RPE autoregulation", "Easy RPE → more weight next week; too hard → less."),
        ("velocity", "Velocity zone", "Watch bar speed above the zone → more weight; below → less."),
        ("safety", "Linear + safety net", "A miss repeats the weight; two misses in a row drop 10%."),
        ("auto", "Auto-adjust", "Working weight follows a % of their newest est. 1RM."),
        ("readiness", "Readiness on the day", "Trimmed 10% when the latest check-in shows a rough night or high stress."),
    ]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    static func about(_ id: String) -> String { all.first { $0.id == id }?.about ?? "" }
}

private let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

private func setText(_ s: APIProgramDoc.SetD) -> (main: String, tag: String?) {
    let w = s.weight ?? 0
    if let p = s.percent { return ("\(s.reps) × back-off", "\(Int(p))%") }
    if let r = s.rpe { return ("\(s.reps) @ RPE \(r.rpeText)", "TOP") }
    if s.amrap == true { return ("\(s.reps > 0 ? "\(s.reps)+" : "max") × \(w > 0 ? StatsUnits.weightText(w) : "BW")", "AMRAP") }
    if w <= 0 { return ("\(s.reps) × BW", nil) }
    return ("\(s.reps) × \(StatsUnits.weightText(w))", nil)
}

// MARK: Programs screen

struct CoachProgramsView: View {
    @EnvironmentObject var store: AppStore
    @State private var programs: [APIProgramSummary] = []
    @State private var running: [APIAssignment] = []
    @State private var changes: [APIProgressionChange] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSScreenHeader(eyebrow: "Plan the work", title: "Programs",
                               subtitle: "Assign one and it fills the calendar; progression runs itself. Build and edit programs in Coach HQ on the web.")

                if loading && programs.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 20)
                } else if failed && programs.isEmpty {
                    Text("Couldn't load programs. Pull down to retry.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }

                if !programs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "LIBRARY", subtitle: "\(programs.count)")
                        ForEach(programs) { p in
                            NavigationLink { CoachProgramDetailView(summary: p) { Task { await load() } } } label: { programCard(p) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                } else if !loading {
                    Text("No programs yet — build your first in Coach HQ on the web.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }

                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "RUNNING", subtitle: running.isEmpty ? nil : "\(running.count) active")
                    if running.isEmpty && !loading {
                        Text("Nobody's on a program right now.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    ForEach(running) { a in AssignmentRow(assignment: a) { open(a) } }
                }

                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "AUTOMATIC CHANGES", subtitle: "last 14 days")
                    if changes.isEmpty && !loading {
                        Text("None yet. They appear after clients log program sessions.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    ForEach(changes) { c in ProgressionChangeRow(change: c) { Task { await load() } } }
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func open(_ a: APIAssignment) {
        if let c = store.roster.first(where: { $0.id == a.clientId }) { store.selectedClient = c }
        else if a.clientId == store.selfClientId { store.select(.workouts) }
    }

    private func programCard(_ p: APIProgramSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(p.weeks) WEEKS · \(p.daysPerWeek) DAYS/WK").font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.voltText)
                Spacer()
                if p.activeAssignments > 0 { DSChip(text: "\(p.activeAssignments) running", color: Brand.volt) }
            }
            Text(p.name).font(BrandFont.display(26)).foregroundColor(Brand.text).multilineTextAlignment(.leading)
            if !p.description.isEmpty {
                Text(p.description).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func load() async {
        do {
            async let p = APIClient.shared.programs()
            async let a = APIClient.shared.assignments()
            async let c = APIClient.shared.progressionChanges(days: 14)
            let (pp, aa, cc) = try await (p, a, c)
            programs = pp; running = aa; changes = cc; failed = false
        } catch { failed = true }
        loading = false
    }
}

// MARK: One program

struct CoachProgramDetailView: View {
    @EnvironmentObject var store: AppStore
    let summary: APIProgramSummary
    var onChange: () -> Void = {}
    @State private var detail: APIProgramDetail?
    @State private var assigning = false
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "\(summary.weeks) weeks · \(summary.daysPerWeek) days a week", title: summary.name,
                               subtitle: summary.description.isEmpty ? nil : summary.description)
                Button { assigning = true } label: { Label("Assign this program", systemImage: "calendar.badge.plus") }
                    .buttonStyle(DSButtonStyle(kind: .primary))

                if let d = detail {
                    ForEach(Array(d.doc.blocks.enumerated()), id: \.offset) { _, b in blockCard(b) }
                } else if failed {
                    Text("Couldn't load the plan.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                } else {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity)
                }
                Text("Edit this program in Coach HQ on the web. Edits apply to new assignments; anyone running it keeps their copy.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await APIClient.shared.program(summary.id) } catch { failed = true }
        }
        .sheet(isPresented: $assigning) {
            AssignProgramSheet(programId: summary.id, programName: summary.name) { onChange() }
                .environmentObject(store)
        }
    }

    private func blockCard(_ b: APIProgramDoc.Block) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(b.name.uppercased()).font(BrandFont.body(11, .heavy)).tracking(1.5).headerPill()
                Spacer()
                Text("\(b.weeks) wk\(b.deloadLast == true ? " · deload last" : "")").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
            }
            ForEach(Array(b.days.enumerated()), id: \.offset) { _, day in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(day.title).font(BrandFont.display(22)).foregroundColor(Brand.text)
                        Spacer()
                        Text(weekdayNames[min(max(day.weekday, 0), 6)]).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.voltText)
                    }
                    ForEach(Array(day.exercises.enumerated()), id: \.offset) { _, ex in exRow(ex) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.text.opacity(0.05)))
            }
        }
        .card(padding: 16)
    }

    private func exRow(_ ex: APIProgramDoc.Ex) -> some View {
        let m = ex.progression?.method ?? "manual"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(ex.name).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                Spacer(minLength: 6)
                DSChip(text: ProgressionMethod.name(m), color: Brand.volt)
            }
            Text(ex.sets.map { setText($0).main }.joined(separator: " · "))
                .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            Text(ProgressionMethod.about(m)).font(BrandFont.body(11)).foregroundColor(Brand.mute.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Assign

struct AssignProgramSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let programId: String
    let programName: String
    var preselected: String? = nil
    var onDone: () -> Void = {}

    @State private var who: String?
    @State private var start: Date = {
        let cal = Calendar.training
        let today = cal.startOfDay(for: Date())
        let wd = (cal.component(.weekday, from: today) + 5) % 7          // Monday = 0
        return cal.date(byAdding: .day, value: wd == 0 ? 7 : 7 - wd, to: today) ?? today
    }()
    @State private var saving = false
    @State private var error: String?

    private var people: [(id: String, name: String)] {
        (store.selfClientId.map { [($0, "You — your own training")] } ?? []) + store.roster.map { ($0.id, $0.name) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DSScreenHeader(eyebrow: "Assign", title: programName,
                                   subtitle: "Week 1 starts on the date you pick; each day lands on its weekday.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHO").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        VStack(spacing: 0) {
                            ForEach(people, id: \.id) { p in
                                Button { who = p.id } label: {
                                    HStack {
                                        Text(p.name).font(BrandFont.body(15, who == p.id ? .bold : .regular)).foregroundColor(Brand.text)
                                        Spacer()
                                        if who == p.id { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.voltText) }
                                    }
                                    .padding(.horizontal, 14).frame(minHeight: 46)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if p.id != people.last?.id { Divider().background(Brand.line) }
                            }
                        }
                        .card(padding: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("START").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        DatePicker("Start", selection: $start, displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden().tint(Brand.voltText)
                    }
                    Text("Starting a program ends the one they're on. Their untouched future sessions from it are removed; anything logged stays.")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    if let error { Text(error).font(BrandFont.body(12)).foregroundColor(.orange) }
                    Button { assign() } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(Brand.onVolt) }
                            Label("Assign", systemImage: "calendar.badge.plus")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(who == nil || saving)
                    .opacity(who == nil ? 0.5 : 1)
                }
                .padding(20)
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            .onAppear { if who == nil { who = preselected } }
        }
    }

    private func assign() {
        guard let who else { return }
        saving = true; error = nil
        Task {
            do {
                _ = try await APIClient.shared.assignProgram(programId, clientId: who, start: start)
                await MainActor.run {
                    saving = false
                    if who == store.selfClientId { store.loadAllFromAPI() }   // his own calendar
                    store.loadRoster()
                    onDone()
                    dismiss()
                }
            } catch {
                await MainActor.run { saving = false; self.error = "Couldn't assign it. Check your connection and try again." }
            }
        }
    }
}

// MARK: Rows

struct AssignmentRow: View {
    let assignment: APIAssignment
    var onTap: () -> Void = {}
    var body: some View {
        let a = assignment
        let pct = a.sessionsTotal > 0 ? Double(a.sessionsDone) / Double(a.sessionsTotal) : 0
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(a.clientName) · \(a.programName)").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
                }
                Text(a.currentWeek > 0 ? "Week \(a.currentWeek) of \(a.totalWeeks) · \(a.sessionsDone)/\(a.sessionsTotal) sessions"
                                       : "Starts \(a.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Brand.text.opacity(0.08))
                        Capsule().fill(Brand.volt).frame(width: g.size.width * pct)
                    }
                }
                .frame(height: 4)
            }
            .card(padding: 14)
        }
        .buttonStyle(PressableStyle())
    }
}

struct ProgressionChangeRow: View {
    let change: APIProgressionChange
    var showClient = true
    var onChanged: () -> Void = {}
    @State private var working = false
    @State private var undone = false

    var body: some View {
        let c = change
        let isUndone = undone || c.undoneAt != nil
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.fill").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.voltText)
                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Brand.text.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text((showClient ? "\(c.clientName) · " : "") + c.summary).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(c.reason).font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                Text("\(ProgressionMethod.name(c.method)) · \(c.createdAt.formatted(.relative(presentation: .named)))")
                    .font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
            }
            Spacer(minLength: 6)
            if isUndone {
                Text("UNDONE").font(BrandFont.body(9, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
                    .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Brand.line, lineWidth: 1))
            } else {
                CoachActionPill(title: working ? "…" : "Undo", icon: "arrow.uturn.backward", primary: false) { undo() }
                    .disabled(working)
            }
        }
        .card(padding: 14)
        .opacity(isUndone ? 0.6 : 1)
    }

    private func undo() {
        working = true
        Task {
            let ok = (try? await APIClient.shared.undoProgressionChange(change.id)) != nil
            await MainActor.run { working = false; if ok { undone = true; onChanged() } }
        }
    }
}

// MARK: On a client's Workouts tab

struct ClientProgramCard: View {
    @EnvironmentObject var store: AppStore
    let clientId: String
    let clientName: String
    var onChange: () -> Void = {}
    @State private var current: APIAssignment?
    @State private var changes: [APIProgressionChange] = []
    @State private var programs: [APIProgramSummary] = []
    @State private var picking = false
    @State private var assignFor: APIProgramSummary?
    @State private var confirmEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PROGRAM").font(BrandFont.body(11, .heavy)).tracking(1.5).headerPill()
                Spacer()
                Menu {
                    ForEach(programs) { p in Button(p.name) { assignFor = p } }
                    if programs.isEmpty { Text("Build programs in Coach HQ on the web") }
                } label: {
                    Text(current == nil ? "Assign a program" : "Switch").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                }
            }
            if let a = current {
                Text(a.programName).font(BrandFont.display(24)).foregroundColor(Brand.text)
                Text(a.currentWeek > 0 ? "Week \(a.currentWeek) of \(a.totalWeeks) · \(a.sessionsDone)/\(a.sessionsTotal) sessions"
                                       : "Starts \(a.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                Button(role: .destructive) { confirmEnd = true } label: {
                    Text("End program").font(BrandFont.body(12, .bold)).foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            } else {
                Text("Not on a program — workouts here are one-offs.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            ForEach(changes.prefix(3)) { c in ProgressionChangeRow(change: c, showClient: false) { Task { await load(); onChange() } } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .task { await load() }
        .sheet(item: $assignFor) { p in
            AssignProgramSheet(programId: p.id, programName: p.name, preselected: clientId) { Task { await load(); onChange() } }
                .environmentObject(store)
        }
        .confirmationDialog("End \(current?.programName ?? "this program")?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End program", role: .destructive) {
                guard let a = current else { return }
                Task { try? await APIClient.shared.endAssignment(a.id); await load(); onChange() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Untouched future sessions are removed. Anything \(clientName.split(separator: " ").first.map(String.init) ?? "they") logged stays.") }
    }

    private func load() async {
        async let a = APIClient.shared.assignments(clientId: clientId)
        async let c = APIClient.shared.progressionChanges(clientId: clientId, days: 30)
        async let p = APIClient.shared.programs()
        current = (try? await a)?.first
        changes = (try? await c) ?? []
        programs = (try? await p) ?? []
    }
}
