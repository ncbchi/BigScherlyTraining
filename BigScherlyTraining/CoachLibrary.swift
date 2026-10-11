import SwiftUI
import Combine

// MARK: - Coach: supplements per client + libraries (Oct 8, 2026)
//
// • Client screen ▸ Supplements: their protocol grouped by stack, 30-day adherence per
//   supplement, add / edit / remove, apply a supplement template, save theirs as one.
// • Saved workouts (the coach's library): the workout builder can start from one, and a
//   client's workout can be saved to the library. Building and assigning saved workouts in
//   bulk lives in Coach HQ on the web (Library).
// Same protocol model the client app already uses (Supplement / SupplementTiming).
// Synchronized folder: no target step needed.

// MARK: API models

struct APISupplementAdherence: Decodable {
    struct Row: Decodable { let supplementId: String; let name: String; let taken: Int; let expected: Int; let missed: Int; let rate: Double }
    let streakDays: Int
    let overallRate: Double
    let totalTaken: Int
    let totalExpected: Int
    let perSupplement: [Row]
}

struct APISupplementTemplate: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let itemCount: Int
}

struct APILibraryWorkout: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let exerciseCount: Int
    let setCount: Int
    let summary: String
}

struct APILibraryWorkoutDetail: Decodable {
    let id: String
    let title: String
    let exercises: [APIExercise]
}

extension APIClient {
    private func body(_ d: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: d) }

    func coachSupplements(clientId: String) async throws -> [Supplement] { try await get("/admin/clients/\(clientId)/supplements") }
    func coachSupplementStacks(clientId: String) async throws -> [SupplementStack] { try await get("/admin/clients/\(clientId)/supplement-stacks") }
    func coachSupplementAdherence(clientId: String) async throws -> APISupplementAdherence { try await get("/admin/clients/\(clientId)/supplement-adherence") }
    func supplementTemplates() async throws -> [APISupplementTemplate] { try await get("/admin/supplement-templates") }
    func coachSaveSupplement(clientId: String, id: String?, payload: [String: Any]) async throws {
        if let id { _ = try await request("/admin/supplements/\(id)", method: "PATCH", body: try body(payload)) }
        else { _ = try await request("/admin/clients/\(clientId)/supplements", method: "POST", body: try body(payload)) }
    }
    func coachDeleteSupplement(id: String) async throws { _ = try await request("/admin/supplements/\(id)", method: "DELETE") }
    // Custom supplements (Oct 8, 2026): the signed-in client — or the coach on his own profile.
    func saveOwnSupplement(id: String?, payload: [String: Any]) async throws {
        if let id { _ = try await request("/supplements/\(id)", method: "PATCH", body: try body(payload)) }
        else { _ = try await request("/supplements", method: "POST", body: try body(payload)) }
    }
    func deleteOwnSupplement(id: String) async throws { _ = try await request("/supplements/\(id)", method: "DELETE") }
    func createOwnStack(name: String) async throws -> SupplementStack {
        try decoder.decode(SupplementStack.self, from: try await request("/supplements/stacks", method: "POST", body: try body(["name": name])))
    }

    func coachCreateStack(clientId: String, name: String) async throws -> SupplementStack {
        try decoder.decode(SupplementStack.self, from: try await request("/admin/clients/\(clientId)/supplement-stacks", method: "POST", body: try body(["name": name])))
    }
    func applySupplementTemplate(clientId: String, templateId: String) async throws {
        _ = try await request("/admin/clients/\(clientId)/apply-supplement-template/\(templateId)", method: "POST")
    }
    func saveSupplementsAsTemplate(clientId: String, name: String) async throws {
        _ = try await request("/admin/clients/\(clientId)/supplements/save-as-template", method: "POST", body: try body(["name": name]))
    }

    func workoutLibrary() async throws -> [APILibraryWorkout] { try await get("/admin/workout-library") }
    func libraryWorkout(id: String) async throws -> APILibraryWorkoutDetail { try await get("/admin/workout-library/\(id)") }
    func saveWorkoutToLibrary(workoutId: String, name: String) async throws {
        _ = try await request("/admin/workouts/\(workoutId)/save-to-library", method: "POST", body: try body(["name": name]))
    }
}

// MARK: - Client screen ▸ Supplements

struct CoachClientSupplements: View {
    let clientId: String
    var clientName: String = ""
    @State private var supps: [Supplement] = []
    @State private var stacks: [SupplementStack] = []
    @State private var adherence: APISupplementAdherence?
    @State private var templates: [APISupplementTemplate] = []
    @State private var loading = true
    @State private var editing: SupplementDraft?
    @State private var confirmTemplate: APISupplementTemplate?
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let a = adherence, !supps.isEmpty {
                    HStack(spacing: 10) {
                        DSStatTile(value: "\(Int((a.overallRate * 100).rounded()))%", label: "TAKEN · 30 DAYS")
                        DSStatTile(value: "\(a.streakDays)", label: "DAY STREAK", color: Brand.text)
                        DSStatTile(value: "\(supps.count)", label: "ON PROTOCOL", color: Brand.text)
                    }
                }
                HStack(spacing: 8) {
                    Button { editing = SupplementDraft() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    if !templates.isEmpty {
                        Menu {
                            ForEach(templates) { t in Button("\(t.name) (\(t.itemCount))") { confirmTemplate = t } }
                        } label: {
                            Label("Template", systemImage: "square.stack.fill")
                                .font(BrandFont.body(14, .bold)).foregroundColor(Brand.voltText)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Capsule().stroke(Brand.voltLine, lineWidth: 1))
                        }
                    }
                }
                if let toast { Text(toast).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText) }

                if loading && supps.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if supps.isEmpty {
                    Text("No supplements yet. Add one, or apply a template.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute).padding(.top, 10)
                }
                ForEach(groups, id: \.id) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        if !g.name.isEmpty { DSSectionHeader(title: g.name.uppercased(), subtitle: "\(g.items.count)") }
                        ForEach(g.items) { s in
                            Button { editing = SupplementDraft(s) } label: { row(s) }.buttonStyle(PressableStyle())
                        }
                    }
                }
                if !supps.isEmpty {
                    Button { templateName = "\(clientName.split(separator: " ").first.map(String.init) ?? "Their")'s protocol"; savingTemplate = true } label: {
                        Label("Save as template", systemImage: "square.and.arrow.down").font(BrandFont.body(13, .bold)).foregroundColor(Brand.mute)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { d in
            SupplementEditorSheet(clientId: clientId, draft: d, stacks: stacks) { Task { await load() } }
        }
        .confirmationDialog("Apply \(confirmTemplate?.name ?? "")?", isPresented: Binding(get: { confirmTemplate != nil }, set: { if !$0 { confirmTemplate = nil } }),
                            titleVisibility: .visible) {
            Button("Add its \(confirmTemplate?.itemCount ?? 0) supplements") {
                guard let t = confirmTemplate else { return }
                Task {
                    try? await APIClient.shared.applySupplementTemplate(clientId: clientId, templateId: t.id)
                    toast = "Applied \(t.name)"
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save as template", isPresented: $savingTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save") {
                let n = templateName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                Task {
                    try? await APIClient.shared.saveSupplementsAsTemplate(clientId: clientId, name: n)
                    toast = "Saved “\(n)”"
                    templates = (try? await APIClient.shared.supplementTemplates()) ?? templates
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves their whole protocol, stacks included, so you can apply it to anyone.") }
    }

    private struct Group { let id: String; let name: String; let items: [Supplement] }

    private var groups: [Group] {
        var out: [Group] = stacks.map { st in Group(id: st.id, name: st.name, items: supps.filter { $0.stackId == st.id }) }
        let loose = supps.filter { s in s.stackId == nil || !stacks.contains { $0.id == s.stackId } }
        out.append(Group(id: "_none", name: stacks.isEmpty ? "" : "Not in a stack", items: loose))
        return out.filter { !$0.items.isEmpty }
    }

    private func row(_ s: Supplement) -> some View {
        let r = adherence?.perSupplement.first { $0.supplementId == s.id }
        let pct: Int? = r.flatMap { $0.expected > 0 ? Int(($0.rate * 100).rounded()) : nil }
        let barColor: Color = (pct ?? 0) >= 80 ? Brand.volt : ((pct ?? 0) >= 50 ? Color.orange : Brand.danger)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.name).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                Text(s.dose.display).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                if s.isPrescription { DSChip(text: "RX", color: Brand.volt) }
                if s.addedBy == "client" { DSChip(text: "THEIR OWN", color: Brand.mute) }
                if s.lowStock, let q = s.quantityOnHand { DSChip(text: "\(q) LEFT", color: .orange) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
            }
            Text(detailLine(s))
                .font(BrandFont.body(12)).foregroundColor(Brand.mute)
            if let pct, let r {
                HStack(spacing: 8) {
                    Capsule().fill(Brand.text.opacity(0.08)).frame(width: 140, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(barColor).frame(width: 140 * CGFloat(pct) / 100, height: 5) }
                    Text("\(pct)% · \(r.taken)/\(r.expected) in 30 days").font(BrandFont.body(10)).foregroundColor(Brand.mute)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .opacity(s.isActive ? 1 : 0.55)
    }

    private func detailLine(_ s: Supplement) -> String {
        var parts: [String] = [s.timing.summary]
        if let i = s.instructions, !i.isEmpty { parts.append(i) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        supps = (try? await APIClient.shared.coachSupplements(clientId: clientId)) ?? supps
        stacks = (try? await APIClient.shared.coachSupplementStacks(clientId: clientId)) ?? stacks
        adherence = try? await APIClient.shared.coachSupplementAdherence(clientId: clientId)
        templates = (try? await APIClient.shared.supplementTemplates()) ?? templates
        loading = false
    }
}

// MARK: Editor

struct SupplementDraft: Identifiable {
    var id = UUID()
    var serverId: String?
    var name = ""
    var amount = ""
    var unit: DoseUnit = .g
    var kind: TimingKind = .daily
    var days: Set<Int> = []
    var times: [Date] = [SupplementDraft.time(480)]
    var offset = 30
    var meals = 1
    var stackId: String?
    var instructions = ""
    var rx = false
    var cycleEnd: Date?
    var quantity = ""

    static func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    init() {}
    init(_ s: Supplement) {
        serverId = s.id; name = s.name
        amount = s.dose.amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(s.dose.amount)) : String(s.dose.amount)
        unit = s.dose.unit; kind = s.timing.kind
        days = Set((s.timing.days ?? []).map(\.rawValue))
        let ts = (s.timing.times ?? []).map { SupplementDraft.time($0.minutes) }
        times = ts.isEmpty ? [SupplementDraft.time(480)] : ts
        offset = s.timing.offsetMinutes ?? (s.timing.kind == .afterWorkout ? 45 : 30)
        meals = s.timing.mealCount ?? 1
        stackId = s.stackId; instructions = s.instructions ?? ""; rx = s.isPrescription
        cycleEnd = s.cycleEnd
        quantity = s.quantityOnHand.map(String.init) ?? ""
    }

    var payload: [String: Any] {
        var p: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "doseAmount": Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0,
            "doseUnit": unit.rawValue, "timingKind": kind.rawValue,
            "isPrescription": rx,
            "stackId": stackId ?? NSNull(),
            "instructions": instructions.trimmingCharacters(in: .whitespaces).isEmpty ? NSNull() : instructions.trimmingCharacters(in: .whitespaces)
        ]
        p["timingDays"] = kind == .fixedDays ? days.sorted() : NSNull()
        p["timingTimes"] = (kind == .daily || kind == .fixedDays) ? times.map(SupplementDraft.minutes).sorted() : NSNull()
        p["timingOffsetMinutes"] = (kind == .beforeWorkout || kind == .afterWorkout) ? offset : NSNull()
        p["timingMealCount"] = kind == .withMeals ? meals : NSNull()
        if let e = cycleEnd { p["cycleEnd"] = ISO8601DateFormatter().string(from: e) } else { p["cycleEnd"] = NSNull() }
        p["quantityOnHand"] = Int(quantity) ?? NSNull()
        return p
    }

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if (Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0 { return "Enter an amount." }
        if kind == .fixedDays && days.isEmpty { return "Pick at least one day." }
        return nil
    }
}

/// One-tap starting points for a new supplement; everything stays editable.
struct SupplementPreset: Identifiable {
    let id: String
    let name: String
    let amount: String
    let unit: DoseUnit
    let kind: TimingKind
    var minutes: [Int] = []
    var offset = 30
    var meals = 1
    var note = ""

    static let all: [SupplementPreset] = [
        SupplementPreset(id: "creatine", name: "Creatine", amount: "5", unit: .g, kind: .daily, minutes: [480]),
        SupplementPreset(id: "d3", name: "Vitamin D3", amount: "2000", unit: .iu, kind: .daily, minutes: [480], note: "with breakfast"),
        SupplementPreset(id: "fish", name: "Fish oil", amount: "2", unit: .capsule, kind: .withMeals, meals: 2),
        SupplementPreset(id: "mag", name: "Magnesium", amount: "400", unit: .mg, kind: .daily, minutes: [1290], note: "before bed"),
        SupplementPreset(id: "caf", name: "Caffeine", amount: "200", unit: .mg, kind: .beforeWorkout, offset: 30),
        SupplementPreset(id: "whey", name: "Protein shake", amount: "1", unit: .scoop, kind: .afterWorkout, offset: 45),
        SupplementPreset(id: "multi", name: "Multivitamin", amount: "1", unit: .tablet, kind: .daily, minutes: [480]),
        SupplementPreset(id: "elec", name: "Electrolytes", amount: "1", unit: .scoop, kind: .beforeWorkout, offset: 20, note: "in 500 mL water")
    ]

    func apply(to d: inout SupplementDraft) {
        d.name = name; d.amount = amount; d.unit = unit; d.kind = kind
        if !minutes.isEmpty { d.times = minutes.map { SupplementDraft.time($0) } }
        d.offset = offset; d.meals = meals
        if !note.isEmpty { d.instructions = note }
    }
}

struct SupplementEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    @State var draft: SupplementDraft
    @State var stacks: [SupplementStack]
    /// true = the signed-in person's own supplement (client app / coach's own training).
    var own: Bool = false
    var onSaved: () -> Void = {}
    @State private var saving = false
    @State private var error: String?
    @State private var newStack = false
    @State private var newStackName = ""
    @State private var confirmDelete = false

    private let kinds: [(TimingKind, String)] = [(.daily, "Every day"), (.fixedDays, "Set days"), (.beforeWorkout, "Before training"),
                                                  (.afterWorkout, "After training"), (.withMeals, "With meals")]
    private let weekOrder: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    var body: some View {
        NavigationStack {
            Form {
                if draft.serverId == nil {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SupplementPreset.all) { p in
                                    Button { p.apply(to: &draft) } label: {
                                        Text(p.name).font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Capsule().fill(Brand.text.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } header: { Text("Quick pick") }
                }
                Section {
                    TextField("Name, e.g. Creatine monohydrate", text: $draft.name)
                    HStack {
                        TextField("Amount", text: $draft.amount).keyboardType(.decimalPad)
                        Picker("Unit", selection: $draft.unit) {
                            ForEach(DoseUnit.allCases) { u in Text(u.rawValue).tag(u) }
                        }
                        .labelsHidden()
                    }
                } header: { Text("Dose") }

                Section {
                    Picker("When", selection: $draft.kind) {
                        ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    if draft.kind == .fixedDays {
                        HStack(spacing: 6) {
                            ForEach(weekOrder) { d in
                                let on = draft.days.contains(d.rawValue)
                                Button {
                                    if on { draft.days.remove(d.rawValue) } else { draft.days.insert(d.rawValue) }
                                } label: {
                                    Text(String(d.short.prefix(2))).font(BrandFont.body(12, .bold))
                                        .frame(width: 34, height: 34)
                                        .foregroundColor(on ? Brand.onVolt : Brand.text)
                                        .background(Circle().fill(on ? Brand.volt : Brand.text.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if draft.kind == .daily || draft.kind == .fixedDays {
                        ForEach(draft.times.indices, id: \.self) { i in
                            HStack {
                                DatePicker("Time \(i + 1)", selection: $draft.times[i], displayedComponents: .hourAndMinute)
                                if draft.times.count > 1 {
                                    Button { draft.times.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundColor(Brand.mute) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        Button("Add a time") { draft.times.append(SupplementDraft.time(1200)) }
                    }
                    if draft.kind == .beforeWorkout || draft.kind == .afterWorkout {
                        Stepper("\(draft.offset) min \(draft.kind == .beforeWorkout ? "before" : "after")", value: $draft.offset, in: 0...240, step: 5)
                    }
                    if draft.kind == .withMeals {
                        Stepper("\(draft.meals) meal\(draft.meals == 1 ? "" : "s") a day", value: $draft.meals, in: 1...6)
                    }
                } header: { Text("Timing") }

                Section {
                    Picker("Stack", selection: $draft.stackId) {
                        Text("None").tag(String?.none)
                        ForEach(stacks) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                    Button("New stack…") { newStackName = ""; newStack = true }
                    TextField("Instructions (optional)", text: $draft.instructions)
                    Toggle("Prescription", isOn: $draft.rx).tint(Brand.volt)
                } header: { Text("Details") }

                Section {
                    Toggle("Ends on a date", isOn: Binding(get: { draft.cycleEnd != nil },
                                                          set: { draft.cycleEnd = $0 ? Calendar.current.date(byAdding: .day, value: 56, to: Date()) : nil }))
                        .tint(Brand.volt)
                    if draft.cycleEnd != nil {
                        DatePicker("Last day", selection: Binding(get: { draft.cycleEnd ?? Date() }, set: { draft.cycleEnd = $0 }), displayedComponents: .date)
                    }
                    TextField("Doses on hand (optional)", text: $draft.quantity).keyboardType(.numberPad)
                } header: { Text("Cycle & stock") }

                if let error {
                    Section { Text(error).foregroundColor(.orange) }
                }
                if own {
                    Section {
                        Text("Your coach sees everything you add here. Check with your doctor before starting anything new.")
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                }
                if draft.serverId != nil {
                    Section {
                        Button(own ? "Remove it" : "Remove from their protocol", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(draft.serverId == nil ? (own ? "Add your own" : "Add supplement") : "Edit supplement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(Brand.mute) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView().tint(Brand.voltText) }
                    else { Button(draft.serverId == nil ? "Add" : "Save") { Task { await save() } }.foregroundColor(Brand.voltText) }
                }
            }
            .alert("New stack", isPresented: $newStack) {
                TextField("e.g. Morning", text: $newStackName)
                Button("Create") {
                    let n = newStackName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    Task {
                        var made: SupplementStack?
                        if own { made = try? await APIClient.shared.createOwnStack(name: n) }
                        else { made = try? await APIClient.shared.coachCreateStack(clientId: clientId, name: n) }
                        if let st = made {
                            stacks.append(st); draft.stackId = st.id
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    guard let id = draft.serverId else { return }
                    Task {
                        if own { try? await APIClient.shared.deleteOwnSupplement(id: id) }
                        else { try? await APIClient.shared.coachDeleteSupplement(id: id) }
                        onSaved(); dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() async {
        if let p = draft.problem { error = p; return }
        saving = true; error = nil
        do {
            if own { try await APIClient.shared.saveOwnSupplement(id: draft.serverId, payload: draft.payload) }
            else { try await APIClient.shared.coachSaveSupplement(clientId: clientId, id: draft.serverId, payload: draft.payload) }
            saving = false; onSaved(); dismiss()
        } catch {
            saving = false; self.error = "Couldn't save. Check your connection and try again."
        }
    }
}

// MARK: - Saved workouts: pick one to start the builder

struct LibraryPickerMenu: View {
    let onPick: (APILibraryWorkoutDetail) -> Void
    @State private var items: [APILibraryWorkout] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                Menu {
                    ForEach(items) { w in
                        Button("\(w.title) · \(w.exerciseCount) exercises") {
                            Task { if let d = try? await APIClient.shared.libraryWorkout(id: w.id) { onPick(d) } }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical.fill").foregroundColor(Brand.voltText)
                        Text("Start from a saved workout").font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
                    }
                    .padding(12).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                }
            }
        }
        .task { items = (try? await APIClient.shared.workoutLibrary()) ?? [] }
    }
}
