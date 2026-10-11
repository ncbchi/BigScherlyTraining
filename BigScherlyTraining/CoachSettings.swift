import SwiftUI

// MARK: - Settings ▸ Coach (Oct 8, 2026)
// Saved replies and the check-in form builder. Both are stored per coach on the server
// (GET/PUT /admin/settings/{key}); clients read the form through GET /checkin-form.
// Synchronized folder: no target step needed.

// MARK: Saved replies — the one-tap phrases in chat, check-in review and compose sheets

struct SavedRepliesEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Line] = []
    @State private var newText = ""

    struct Line: Identifiable, Equatable { var id = UUID(); var text: String }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($items) { $line in
                        TextField("", text: $line.text, prompt: Text("Reply").foregroundColor(Brand.mute), axis: .vertical)
                            .font(BrandFont.body(15)).foregroundColor(Brand.text)
                            .listRowBackground(Brand.card)
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("YOUR REPLIES").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                } footer: {
                    Text("They show as tap-to-insert pills when you write to a client. Drag to reorder; swipe to delete.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                Section {
                    HStack(spacing: 10) {
                        TextField("", text: $newText, prompt: Text("Add a reply…").foregroundColor(Brand.mute))
                            .font(BrandFont.body(15)).foregroundColor(Brand.text)
                            .onSubmit(add)
                        Button(action: add) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundColor(Brand.voltText)
                        }
                        .buttonStyle(.borderless)
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Add reply")
                    }
                    .listRowBackground(Brand.card)
                }
                Section {
                    Button("Reset to the built-in replies") {
                        items = CoachDefaults.savedReplies.map { Line(text: $0) }
                    }
                    .foregroundColor(Brand.mute)
                    .listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Saved replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(Brand.mute) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setSavedReplies(items.map(\.text))
                        dismiss()
                    }
                    .foregroundColor(Brand.voltText)
                }
            }
            .onAppear { if items.isEmpty { items = store.savedReplies.map { Line(text: $0) } } }
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(Line(text: t))
        newText = ""
    }
}

// MARK: Check-in form builder — the questions every client answers each week
// Oct 8, 2026: also edits a named form from the forms library (form:) or makes one (newForm:).
// The default form keeps its "standard = no custom form" rule; named forms always store their list.

struct CheckInFormEditor: View {
    @Environment(\.dismiss) private var dismiss
    var form: APICheckInForm? = nil
    var newForm: Bool = false
    @State private var name = ""
    @State private var confirmDelete = false
    private var isNamed: Bool { form != nil || newForm }
    @State private var qs: [QDraft] = []
    @State private var saving = false
    @State private var failed = false
    @State private var isStandard = CheckInSchema.custom == nil

    struct QDraft: Identifiable, Equatable {
        var id: String
        var label: String
        var kind: CheckInKind
        var unit: String
        var higherIsBetter: Bool
        var tracksDelta: Bool

        init(_ q: CheckInQuestion) {
            id = q.id; label = q.label; kind = q.kind; unit = q.unit
            higherIsBetter = q.higherIsBetter; tracksDelta = q.tracksDelta
        }
        init(kind: CheckInKind) {
            id = "q" + UUID().uuidString.prefix(8).lowercased(); label = ""; self.kind = kind
            unit = ""; higherIsBetter = true; tracksDelta = false
        }
        var question: CheckInQuestion {
            CheckInQuestion(id, label.trimmingCharacters(in: .whitespaces), kind, unit: kind == .number ? unit : "",
                            tracksDelta: kind == .number && tracksDelta, higherIsBetter: kind == .scale ? higherIsBetter : true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if isNamed {
                    Section {
                        TextField("", text: $name, prompt: Text("Form name, e.g. Meet prep").foregroundColor(Brand.mute))
                            .font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                            .listRowBackground(Brand.card)
                    } header: {
                        Text("NAME").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    }
                }
                Section {
                    ForEach($qs) { $q in
                        questionRow($q).listRowBackground(Brand.card)
                    }
                    .onDelete { qs.remove(atOffsets: $0) }
                    .onMove { qs.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text(isNamed ? "QUESTIONS" : (isStandard ? "STANDARD QUESTIONS" : "YOUR QUESTIONS"))
                        .font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                } footer: {
                    Text(isNamed ? "Clients on this form answer these each week, in this order. Changes apply to their next check-in; past check-ins keep their answers."
                                 : "Every client answers these each week (unless you give them another form), in this order. Changes apply to their next check-in; past check-ins keep their answers.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                Section {
                    addButton("Add a 1–10 scale", kind: .scale, icon: "slider.horizontal.3")
                    addButton("Add a number", kind: .number, icon: "number")
                    addButton("Add a written answer", kind: .longText, icon: "text.alignleft")
                }
                Section {
                    if failed {
                        Text("Couldn't save. Check your connection and try again.")
                            .font(BrandFont.body(12)).foregroundColor(.orange).listRowBackground(Color.clear)
                    }
                    Button(isNamed ? "Start from the standard questions" : "Reset to the standard questions") {
                        qs = CheckInSchema.standard.map(QDraft.init)
                        isStandard = true
                    }
                    .foregroundColor(Brand.mute)
                    .listRowBackground(Color.clear)
                    if let form {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text(form.clientCount > 0 ? "Delete form (\(form.clientCount) client\(form.clientCount == 1 ? "" : "s") go back to the default)" : "Delete form")
                                .foregroundColor(Brand.danger)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(form?.name ?? (newForm ? "New form" : "Check-in form"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(Brand.mute) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView().tint(Brand.voltText) }
                    else { Button("Save", action: save).foregroundColor(Brand.voltText).disabled(!canSave) }
                }
            }
            .onAppear {
                guard qs.isEmpty else { return }
                if let form {
                    name = form.name
                    qs = (CheckInSchema.parse(form.json) ?? []).map(QDraft.init)
                } else if newForm {
                    qs = [QDraft(kind: .scale)]
                } else {
                    qs = CheckInSchema.questions.map(QDraft.init)
                }
            }
            .confirmationDialog("Delete this form?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteForm() }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: qs) { _, new in
                isStandard = new.map(\.question.label) == CheckInSchema.standard.map(\.label)
                    && new.map(\.kind) == CheckInSchema.standard.map(\.kind)
            }
        }
    }

    private func questionRow(_ q: Binding<QDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon(q.wrappedValue.kind)).foregroundColor(Brand.voltText).frame(width: 20)
                TextField("", text: q.label, prompt: Text("Question").foregroundColor(Brand.mute), axis: .vertical)
                    .font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
            }
            switch q.wrappedValue.kind {
            case .scale:
                Toggle(isOn: q.higherIsBetter) {
                    Text("Higher is better").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                .tint(Brand.volt)
            case .number:
                HStack(spacing: 10) {
                    TextField("", text: q.unit, prompt: Text("Unit (lb, steps…)").foregroundColor(Brand.mute))
                        .font(BrandFont.body(13)).foregroundColor(Brand.text)
                        .frame(maxWidth: 150)
                    Toggle(isOn: q.tracksDelta) {
                        Text("Show change vs last week").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    .tint(Brand.volt)
                }
            case .longText:
                Text("Written answer").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
        }
        .padding(.vertical, 4)
    }

    private func addButton(_ title: String, kind: CheckInKind, icon: String) -> some View {
        Button {
            withAnimation(.snappy) { qs.append(QDraft(kind: kind)) }
        } label: {
            Label(title, systemImage: icon).font(BrandFont.body(15)).foregroundColor(Brand.text)
        }
        .listRowBackground(Brand.card)
    }

    private func icon(_ k: CheckInKind) -> String {
        switch k {
        case .scale: return "slider.horizontal.3"
        case .number: return "number"
        case .longText: return "text.alignleft"
        }
    }

    private var canSave: Bool {
        !qs.isEmpty && qs.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            && (!isNamed || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func deleteForm() {
        guard let form else { return }
        Task {
            if (try? await APIClient.shared.deleteCheckInForm(id: form.id)) != nil { await MainActor.run { dismiss() } }
        }
    }

    private func save() {
        saving = true; failed = false
        let questions = qs.map(\.question)
        if isNamed {
            let n = name.trimmingCharacters(in: .whitespaces), json = CheckInSchema.encode(questions)
            Task {
                do {
                    if let form { try await APIClient.shared.updateCheckInForm(id: form.id, name: n, json: json) }
                    else { _ = try await APIClient.shared.createCheckInForm(name: n, json: json) }
                    await MainActor.run { saving = false; dismiss() }
                } catch {
                    await MainActor.run { saving = false; failed = true }
                }
            }
            return
        }
        // The standard list is stored as "no custom form", so a later change to the
        // built-in questions still reaches clients who never customised.
        let json = isStandard ? "" : CheckInSchema.encode(questions)
        Task {
            do {
                try await APIClient.shared.saveTrainerSetting("checkinForm", json: json)
                await MainActor.run {
                    CheckInSchema.custom = isStandard ? nil : questions
                    saving = false
                    dismiss()
                }
            } catch {
                await MainActor.run { saving = false; failed = true }
            }
        }
    }
}
