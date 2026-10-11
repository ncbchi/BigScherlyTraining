import SwiftUI

// MARK: - Coach Notebook + check-in forms (Oct 8, 2026)
//
// Notebook: OneNote-style binders → pages. Every client has a binder (its pinned "Notes"
// page is the same note as before — the web console and older apps see the same text),
// plus the coach's own binders (General, Programming ideas…). Pages save as you type.
// Check-in forms: a library of forms; each client gets one (default = the coach's form).
// Synchronized folder: no target step needed.

// MARK: API models

struct APINotebookBinder: Decodable, Identifiable, Hashable {
    let id: String
    let clientId: String?
    let name: String
    let color: String
    let sortOrder: Int
    let pageCount: Int
    let updatedAt: Date
    let archived: Bool
}

struct APINotebookPage: Decodable, Identifiable, Hashable {
    let id: String
    let binderId: String
    var title: String
    var body: String
    var pinned: Bool
    let linked: Bool
    let sortOrder: Int
    let createdAt: Date
    var updatedAt: Date
}

struct APINotebookHit: Decodable, Identifiable {
    let pageId: String
    let binderId: String
    let binderName: String
    let clientId: String?
    let title: String
    let snippet: String
    let updatedAt: Date
    var id: String { pageId }
}

struct APIClientNotebook: Decodable {
    let binder: APINotebookBinder
    let pages: [APINotebookPage]
}

struct APICheckInForm: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let json: String
    let clientCount: Int
    let updatedAt: Date
}

struct APIClientCheckInForm: Decodable {
    let formId: String?
    let name: String
    let json: String?
}

extension APIClient {
    private func jsonBody(_ d: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: d) }

    func notebook() async throws -> [APINotebookBinder] { try await get("/admin/notebook") }
    func notebookPages(binderId: String) async throws -> [APINotebookPage] { try await get("/admin/notebook/binders/\(binderId)/pages") }
    func clientNotebook(clientId: String) async throws -> APIClientNotebook { try await get("/admin/clients/\(clientId)/notebook") }
    func notebookSearch(_ q: String) async throws -> [APINotebookHit] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#%"))) ?? ""
        return try await get("/admin/notebook/search?q=\(enc)")
    }
    func createBinder(name: String, color: String) async throws -> APINotebookBinder {
        try decoder.decode(APINotebookBinder.self, from: try await request("/admin/notebook/binders", method: "POST",
                                                                             body: try jsonBody(["name": name, "color": color])))
    }
    func updateBinder(id: String, name: String?, color: String?) async throws {
        var d: [String: Any] = [:]
        if let name { d["name"] = name }
        if let color { d["color"] = color }
        _ = try await request("/admin/notebook/binders/\(id)", method: "PUT", body: try jsonBody(d))
    }
    func deleteBinder(id: String) async throws { _ = try await request("/admin/notebook/binders/\(id)", method: "DELETE") }
    func createPage(binderId: String, title: String, body: String) async throws -> APINotebookPage {
        try decoder.decode(APINotebookPage.self, from: try await request("/admin/notebook/binders/\(binderId)/pages", method: "POST",
                                                                           body: try jsonBody(["title": title, "body": body])))
    }
    @discardableResult
    func updatePage(id: String, fields: [String: Any]) async throws -> APINotebookPage {
        try decoder.decode(APINotebookPage.self, from: try await request("/admin/notebook/pages/\(id)", method: "PUT", body: try jsonBody(fields)))
    }
    func deletePage(id: String) async throws { _ = try await request("/admin/notebook/pages/\(id)", method: "DELETE") }

    func checkInForms() async throws -> [APICheckInForm] { try await get("/admin/checkin-forms") }
    func createCheckInForm(name: String, json: String) async throws -> APICheckInForm {
        try decoder.decode(APICheckInForm.self, from: try await request("/admin/checkin-forms", method: "POST",
                                                                          body: try jsonBody(["name": name, "json": json])))
    }
    func updateCheckInForm(id: String, name: String, json: String) async throws {
        _ = try await request("/admin/checkin-forms/\(id)", method: "PUT", body: try jsonBody(["name": name, "json": json]))
    }
    func deleteCheckInForm(id: String) async throws { _ = try await request("/admin/checkin-forms/\(id)", method: "DELETE") }
    func clientCheckInForm(clientId: String) async throws -> APIClientCheckInForm { try await get("/admin/clients/\(clientId)/checkin-form") }
    func assignCheckInForm(clientId: String, formId: String?) async throws -> APIClientCheckInForm {
        try decoder.decode(APIClientCheckInForm.self, from: try await request("/admin/clients/\(clientId)/checkin-form", method: "PUT",
                                                                                body: try jsonBody(["formId": formId ?? NSNull()])))
    }
}

enum BinderColor {
    static let all = ["volt", "orange", "red", "blue", "purple", "teal", "grey"]
    static func color(_ key: String) -> Color {
        switch key {
        case "orange": return Color(red: 0.95, green: 0.63, blue: 0.24)
        case "red": return Color(red: 1.0, green: 0.35, blue: 0.35)
        case "blue": return Color(red: 0.24, green: 0.61, blue: 0.88)
        case "purple": return Color(red: 0.65, green: 0.49, blue: 0.95)
        case "teal": return Color(red: 0.24, green: 0.79, blue: 0.72)
        case "grey": return Color(red: 0.557, green: 0.557, blue: 0.576)   // #8E8E93
        default: return Brand.volt
        }
    }
}

private func notebookAgo(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
    return days < 7 ? "\(days) days ago" : d.formatted(.dateTime.month(.abbreviated).day())
}

// MARK: - Notebook (menu: COACH ▸ Notebook)

struct CoachNotebookView: View {
    @State private var binders: [APINotebookBinder] = []
    @State private var loading = true
    @State private var failed = false
    @State private var query = ""
    @State private var hits: [APINotebookHit]? = nil
    @State private var searchTask: Task<Void, Never>?
    @State private var newBinder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DSScreenHeader(eyebrow: "Yours", title: "Notebook",
                               subtitle: "A binder for every client, plus your own. Pages save as you type.")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.mute)
                    TextField("", text: $query, prompt: Text("Search every page").foregroundColor(Brand.mute))
                        .foregroundColor(Brand.text).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Brand.mute) }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))

                if let hits {
                    VStack(alignment: .leading, spacing: 8) {
                        DSSectionHeader(title: "RESULTS", subtitle: "\(hits.count)")
                        if hits.isEmpty {
                            Text("Nothing matches.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        }
                        ForEach(hits) { h in
                            NavigationLink {
                                NotebookPageLoader(binderId: h.binderId, pageId: h.pageId, binderName: h.binderName) { Task { await load() } }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                                    Text("\(h.binderName) · \(notebookAgo(h.updatedAt))").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
                                    Text(h.snippet).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                } else {
                    if loading && binders.isEmpty {
                        ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 20)
                    } else if failed && binders.isEmpty {
                        Text("Couldn't load the notebook. Pull down to retry.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    }
                    let own = binders.filter { $0.clientId == nil }
                    let clients = binders.filter { $0.clientId != nil && !$0.archived }
                    let archived = binders.filter { $0.archived }
                    if !own.isEmpty || !loading {
                        section("BINDERS", own, trailing: AnyView(
                            Button { newBinder = true } label: {
                                Label("Binder", systemImage: "plus").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                            }))
                    }
                    if !clients.isEmpty { section("CLIENTS", clients) }
                    if !archived.isEmpty { section("ARCHIVED", archived) }
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: query) { _, q in search(q) }
        .sheet(isPresented: $newBinder) { BinderSheet(binder: nil) { _ in Task { await load() } } }
        .tapToDismissKeyboard()
    }

    private func section(_ title: String, _ list: [APINotebookBinder], trailing: AnyView? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DSSectionHeader(title: title, subtitle: nil)
                Spacer()
                if let trailing { trailing }
            }
            ForEach(list) { b in
                NavigationLink { NotebookBinderView(binder: b) { Task { await load() } } } label: { binderRow(b) }
                    .buttonStyle(PressableStyle())
            }
        }
    }

    private func binderRow(_ b: APINotebookBinder) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(BinderColor.color(b.color)).frame(width: 12, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.name).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                Text("\(b.pageCount) page\(b.pageCount == 1 ? "" : "s") · \(notebookAgo(b.updatedAt))")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .padding(14).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func load() async {
        do { binders = try await APIClient.shared.notebook(); failed = false } catch { failed = true }
        loading = false
    }

    private func search(_ q: String) {
        searchTask?.cancel()
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { hits = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let r = (try? await APIClient.shared.notebookSearch(t)) ?? []
            if !Task.isCancelled { hits = r }
        }
    }
}

// MARK: One binder: its pages

struct NotebookBinderView: View {
    let binder: APINotebookBinder
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [APINotebookPage] = []
    @State private var loading = true
    @State private var editingBinder = false
    @State private var openPage: APINotebookPage?
    @State private var allBinders: [APINotebookBinder] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(BinderColor.color(binder.color)).frame(width: 10, height: 30)
                    Text(binder.name).font(BrandFont.display(34)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
                }
                Button { Task { await newPage() } } label: { Label("New page", systemImage: "plus") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                if loading && pages.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 20)
                } else if pages.isEmpty {
                    Text("No pages yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }
                ForEach(pages) { p in
                    Button { openPage = p } label: { NotebookPageRow(page: p) }.buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingBinder = true } label: { Image(systemName: "paintpalette") }
                    .foregroundColor(Brand.voltText).accessibilityLabel("Binder settings")
            }
        }
        .navigationDestination(item: $openPage) { p in
            NotebookPageEditor(page: p, binders: allBinders) { updated in
                if let updated, let i = pages.firstIndex(where: { $0.id == updated.id }) { pages[i] = updated }
                Task { await load() }
                onChanged()
            }
        }
        .sheet(isPresented: $editingBinder) {
            BinderSheet(binder: binder) { deleted in
                onChanged()
                if deleted { dismiss() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        pages = (try? await APIClient.shared.notebookPages(binderId: binder.id)) ?? pages
        allBinders = (try? await APIClient.shared.notebook()) ?? allBinders
        loading = false
    }

    private func newPage() async {
        if let p = try? await APIClient.shared.createPage(binderId: binder.id, title: "", body: "") {
            var blank = p; blank.title = ""
            pages.insert(blank, at: pages.filter { $0.linked || $0.pinned }.count)
            openPage = blank
            onChanged()
        }
    }
}

struct NotebookPageRow: View {
    let page: APINotebookPage
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if page.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(Brand.voltText) }
                Text(page.title.isEmpty ? "Untitled" : page.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                Spacer()
                Text(notebookAgo(page.updatedAt)).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
            }
            Text(page.body.isEmpty ? "Empty page" : page.body).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(page.pinned ? Brand.voltLine.opacity(0.5) : Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// Opens a page straight from a search hit (fetches the binder's pages, then edits that one).
struct NotebookPageLoader: View {
    let binderId: String
    let pageId: String
    let binderName: String
    var onChanged: () -> Void = {}
    @State private var page: APINotebookPage?
    @State private var binders: [APINotebookBinder] = []
    @State private var failed = false

    var body: some View {
        Group {
            if let page {
                NotebookPageEditor(page: page, binders: binders) { _ in onChanged() }
            } else if failed {
                Text("Couldn't open that page.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.bg.ignoresSafeArea())
            } else {
                ProgressView().tint(Brand.volt).frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.bg.ignoresSafeArea())
            }
        }
        .task {
            binders = (try? await APIClient.shared.notebook()) ?? []
            if let ps = try? await APIClient.shared.notebookPages(binderId: binderId), let p = ps.first(where: { $0.id == pageId }) { page = p }
            else { failed = true }
        }
    }
}

// MARK: Page editor — autosaves 0.7 s after you stop typing, and when you leave

struct NotebookPageEditor: View {
    @Environment(\.dismiss) private var dismiss
    let page: APINotebookPage
    var binders: [APINotebookBinder] = []
    var onDone: (APINotebookPage?) -> Void = { _ in }

    @State private var title = ""
    @State private var text = ""
    @State private var pinned = false
    @State private var loaded = false
    @State private var dirty = false
    @State private var status = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var latest: APINotebookPage?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $title, prompt: Text("Untitled").foregroundColor(Brand.mute), axis: .vertical)
                .font(BrandFont.display(30)).foregroundColor(Brand.text)
                .disabled(page.linked)
            HStack(spacing: 6) {
                if page.linked {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundColor(Brand.mute)
                    Text("Private · same note as the web console").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
                Spacer()
                Text(status).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
            }
            TextEditor(text: $text)
                .font(BrandFont.body(16)).foregroundColor(Brand.text)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20).padding(.top, 8)
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { addChecklistLine() } label: { Image(systemName: "checklist") }
                    .foregroundColor(Brand.voltText).accessibilityLabel("Add a checklist line")
                if !page.linked {
                    Menu {
                        Button(pinned ? "Unpin" : "Pin to top") { Task { await togglePin() } }
                        let others = binders.filter { $0.id != page.binderId }
                        if !others.isEmpty {
                            Menu("Move to") {
                                ForEach(others) { b in Button(b.name) { Task { await move(to: b.id) } } }
                            }
                        }
                        Button("Delete page", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .foregroundColor(Brand.voltText)
                }
            }
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .onAppear {
            guard !loaded else { return }
            title = page.title; text = page.body; pinned = page.pinned; loaded = true
            status = "Saved \(notebookAgo(page.updatedAt).lowercased())"
        }
        .onChange(of: title) { _, _ in touched() }
        .onChange(of: text) { _, _ in touched() }
        .onDisappear {
            saveTask?.cancel()
            if dirty {
                let id = page.id, fields = fieldsToSave()
                Task {
                    let p = try? await APIClient.shared.updatePage(id: id, fields: fields)
                    await MainActor.run { onDone(p) }
                }
            } else {
                onDone(latest)
            }
        }
        .keyboardDoneButton()
    }

    private func fieldsToSave() -> [String: Any] {
        var f: [String: Any] = ["body": text]
        if !page.linked { f["title"] = title }
        return f
    }

    private func touched() {
        guard loaded else { return }
        if title == (latest?.title ?? page.title) && text == (latest?.body ?? page.body) && !dirty { return }
        dirty = true; status = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await saveNow()
        }
    }

    private func saveNow() async {
        let fields = fieldsToSave()
        do {
            let p = try await APIClient.shared.updatePage(id: page.id, fields: fields)
            latest = p
            if (fields["body"] as? String) == text && (page.linked || (fields["title"] as? String) == title) { dirty = false }
            status = "Saved"
        } catch {
            status = "Not saved — check your connection"
        }
    }

    private func addChecklistLine() {
        if text.isEmpty || text.hasSuffix("\n") { text += "- [ ] " } else { text += "\n- [ ] " }
    }

    private func togglePin() async {
        if dirty { await saveNow() }
        if let p = try? await APIClient.shared.updatePage(id: page.id, fields: ["pinned": !pinned]) { pinned = p.pinned; latest = p }
    }

    private func move(to binderId: String) async {
        if dirty { await saveNow() }
        if (try? await APIClient.shared.updatePage(id: page.id, fields: ["binderId": binderId])) != nil {
            dirty = false
            dismiss()
        }
    }

    private func delete() async {
        saveTask?.cancel(); dirty = false
        if (try? await APIClient.shared.deletePage(id: page.id)) != nil { dismiss() }
    }
}

// MARK: New / edit binder

struct BinderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let binder: APINotebookBinder?
    var onSaved: (_ deleted: Bool) -> Void = { _ in }
    @State private var name = ""
    @State private var color = "blue"
    @State private var saving = false
    @State private var failed = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if binder?.clientId == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NAME").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            TextField("", text: $name, prompt: Text("e.g. Programming ideas").foregroundColor(Brand.mute))
                                .foregroundColor(Brand.text).padding(14)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.black))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                        }
                    } else {
                        Text("\(binder?.name ?? "")'s binder follows their name and stays with them.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COLOR").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        HStack(spacing: 10) {
                            ForEach(BinderColor.all, id: \.self) { c in
                                Button { color = c } label: {
                                    RoundedRectangle(cornerRadius: 8).fill(BinderColor.color(c)).frame(width: 34, height: 34)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.text, lineWidth: color == c ? 2.5 : 0))
                                }
                                .accessibilityLabel(c)
                            }
                        }
                    }
                    if failed { Text("Couldn't save. Try again.").font(BrandFont.body(12)).foregroundColor(.orange) }
                    Button { Task { await save() } } label: { Label(binder == nil ? "Create binder" : "Save", systemImage: "checkmark") }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .disabled(saving || (binder?.clientId == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    if let b = binder, b.clientId == nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Delete binder and its \(b.pageCount) page\(b.pageCount == 1 ? "" : "s")")
                                .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.danger).frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(20)
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(binder == nil ? "New binder" : "Binder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(Brand.mute) } }
            .confirmationDialog("Delete this binder and every page in it?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { if let b = binder { name = b.name; color = b.color } }
        }
    }

    private func save() async {
        saving = true; failed = false
        do {
            if let b = binder {
                try await APIClient.shared.updateBinder(id: b.id, name: b.clientId == nil ? name : nil, color: color)
            } else {
                _ = try await APIClient.shared.createBinder(name: name, color: color)
            }
            saving = false; onSaved(false); dismiss()
        } catch { saving = false; failed = true }
    }

    private func delete() async {
        guard let b = binder else { return }
        if (try? await APIClient.shared.deleteBinder(id: b.id)) != nil { onSaved(true); dismiss() }
    }
}

// MARK: - A client's binder (client screen ▸ Notes)

struct ClientNotebookView: View {
    let clientId: String
    @State private var binder: APINotebookBinder?
    @State private var pages: [APINotebookPage] = []
    @State private var loading = true
    @State private var openPage: APINotebookPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(Brand.mute)
                    Text("Private to you — the client never sees these.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                Button { Task { await newPage() } } label: { Label("New page", systemImage: "plus") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(binder == nil)
                if loading && pages.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(pages) { p in
                    Button { openPage = p } label: { NotebookPageRow(page: p) }.buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .navigationDestination(item: $openPage) { p in
            NotebookPageEditor(page: p) { _ in Task { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let r = try? await APIClient.shared.clientNotebook(clientId: clientId) { binder = r.binder; pages = r.pages }
        loading = false
    }

    private func newPage() async {
        guard let b = binder, let p = try? await APIClient.shared.createPage(binderId: b.id, title: "", body: "") else { return }
        var blank = p; blank.title = ""
        pages.insert(blank, at: pages.filter { $0.linked || $0.pinned }.count)
        openPage = blank
    }
}

// MARK: - Check-in forms

/// Client screen ▸ Check-Ins: which form this client answers.
struct ClientCheckInFormPicker: View {
    let clientId: String
    @State private var forms: [APICheckInForm] = []
    @State private var current: String? = nil
    @State private var name = "Default form"
    @State private var loaded = false

    var body: some View {
        Menu {
            Button { assign(nil) } label: {
                if current == nil { Label("Default form", systemImage: "checkmark") } else { Text("Default form") }
            }
            ForEach(forms) { f in
                Button { assign(f.id) } label: {
                    if current == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundColor(Brand.voltText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CHECK-IN FORM").font(BrandFont.body(9, .heavy)).tracking(1).foregroundColor(Brand.mute)
                    Text(loaded ? name : "…").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
            }
            .padding(12).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
        }
        .task {
            let loadedForms = try? await APIClient.shared.checkInForms()
            let assigned = try? await APIClient.shared.clientCheckInForm(clientId: clientId)
            forms = loadedForms ?? []
            if let assigned { current = assigned.formId; name = assigned.name }
            loaded = true
        }
        .accessibilityLabel("Check-in form: \(name). Applies from their next check-in.")
    }

    private func assign(_ id: String?) {
        let before = (current, name)
        current = id; name = id.flatMap { i in forms.first { $0.id == i }?.name } ?? "Default form"
        Task {
            do {
                let r = try await APIClient.shared.assignCheckInForm(clientId: clientId, formId: id)
                current = r.formId; name = r.name
            } catch { current = before.0; name = before.1 }
        }
    }
}

/// Settings ▸ Coach ▸ Check-in forms: the default form plus named forms.
struct CheckInFormsLibrary: View {
    @Environment(\.dismiss) private var dismiss
    @State private var forms: [APICheckInForm] = []
    @State private var editingDefault = false
    @State private var editing: APICheckInForm?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { editingDefault = true } label: {
                        row("Default form", CheckInSchema.custom == nil ? "Standard questions · everyone unless you pick another"
                                                                      : "\(CheckInSchema.questions.count) questions · everyone unless you pick another")
                    }
                    ForEach(forms) { f in
                        Button { editing = f } label: {
                            row(f.name, "\(CheckInSchema.parse(f.json)?.count ?? 0) questions · " +
                                (f.clientCount == 0 ? "not given to anyone" : "\(f.clientCount) client\(f.clientCount == 1 ? "" : "s")"))
                        }
                    }
                    Button { creating = true } label: {
                        Label("New form", systemImage: "plus").font(BrandFont.body(15, .semibold)).foregroundColor(Brand.voltText)
                    }
                } footer: {
                    Text("Give a client a form from their Check-Ins screen. Changes apply from their next check-in.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Check-in forms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundColor(Brand.voltText) } }
            .task { await load() }
            .sheet(isPresented: $editingDefault) { CheckInFormEditor() }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { f in
                CheckInFormEditor(form: f)
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
                CheckInFormEditor(newForm: true)
            }
        }
    }

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
            Text(sub).font(BrandFont.body(12)).foregroundColor(Brand.mute)
        }
        .padding(.vertical, 2)
    }

    private func load() async { forms = (try? await APIClient.shared.checkInForms()) ?? forms }
}
