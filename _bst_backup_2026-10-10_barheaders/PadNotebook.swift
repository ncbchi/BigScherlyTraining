import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Notebook (round 3, Oct 9, 2026)
//
// Three columns: binders (yours, then each client's), pages, and the page itself, saving as you
// type. Search covers every page. Quick note drops a fresh page into the binder you're in. A page
// can be moved into a client's binder, which is how it shows up in that client's Notes.
// Synchronized folder: no target step needed.

struct PadNotebookView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.padSideBySide) private var sideBySide
    @State private var binders: [APINotebookBinder] = []
    @State private var binderId: String?
    @State private var pages: [APINotebookPage] = []
    @State private var pageId: String?
    @State private var loading = true
    @State private var loadingPages = false
    @State private var q = ""
    @State private var hits: [APINotebookHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var newBinder = false

    private var coachBinders: [APINotebookBinder] { binders.filter { $0.clientId == nil && !$0.archived }.sorted { $0.sortOrder < $1.sortOrder } }
    private var clientBinders: [APINotebookBinder] { binders.filter { $0.clientId != nil && !$0.archived && $0.pageCount > 0 }.sorted { $0.name < $1.name } }
    private var binder: APINotebookBinder? { binders.first { $0.id == binderId } }
    private var page: APINotebookPage? { pages.first { $0.id == pageId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadPageTop(title: "Notebook", subtitle: "Your binders. Each client's pages also live in their Notes.") {
                Button { newBinder = true } label: { Label("New binder", systemImage: "folder.badge.plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline))
                Button { Task { await quickNote() } } label: { Label("Quick note", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .primary))
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            PadPageStrip(stats: strip)
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                binderColumn.frame(width: sideBySide ? 230 : 190)
                Rectangle().fill(Pad.line).frame(width: 1)
                pageColumn.frame(width: sideBySide ? 290 : 240)
                Rectangle().fill(Pad.line).frame(width: 1)
                editorColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .task { await loadBinders() }
        .onChange(of: binderId) { _, _ in Task { await loadPages() } }
        .onChange(of: q) { _, t in search(t) }
        .sheet(isPresented: $newBinder) {
            PadNewBinderSheet { b in
                binders.append(b)
                binderId = b.id
            }
        }
    }

    // MARK: Strip

    private var strip: [PadStat] {
        let total = binders.map { $0.pageCount }.reduce(0, +)
        let shelves = binders.filter { !$0.archived && ($0.clientId == nil || $0.pageCount > 0) }.count
        let clientPages = binders.filter { $0.clientId != nil }.map { $0.pageCount }.reduce(0, +)
        let clients = binders.filter { $0.clientId != nil && $0.pageCount > 0 }.count
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let recent = binders.filter { $0.updatedAt >= weekAgo }.sorted { $0.updatedAt > $1.updatedAt }
        let latest: String = recent.first.map { "latest: \($0.name), \($0.updatedAt.padWhen)" } ?? "none this week"
        return [
            PadStat(label: "Pages", value: "\(total)", sub: "in \(shelves.plural("binder"))"),
            PadStat(label: "Client pages", value: "\(clientPages)", sub: "across \(clients.plural("client"))"),
            PadStat(label: "Binders edited this week", value: "\(recent.count)", sub: latest),
        ]
    }

    // MARK: Binders

    private var binderColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PadLab("Binders", color: Pad.faint, size: 12).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                if loading { ForEach(0..<4, id: \.self) { _ in PadSkeleton(height: 40).padding(.horizontal, 8) } }
                ForEach(coachBinders) { b in binderRow(b) }
                if !clientBinders.isEmpty {
                    PadLab("Clients", color: Pad.faint, size: 12).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                    ForEach(clientBinders) { b in binderRow(b) }
                }
            }
            .padding(8)
        }
    }

    private func binderRow(_ b: APINotebookBinder) -> some View {
        let on = b.id == binderId
        return Button { binderId = b.id; q = "" } label: {
            HStack(spacing: 10) {
                if b.clientId != nil {
                    PadAvatar(name: b.name, size: 28)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(BinderColor.color(b.color)).frame(width: 6, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(b.pageCount.plural("page")).font(PadFont.ui(12)).foregroundColor(Pad.mute)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.raised : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Pages

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Pad.faint)
                TextField("Search all pages", text: $q).font(PadFont.ui(15)).foregroundColor(Pad.text).autocorrectionDisabled()
                if !q.isEmpty {
                    Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Pad.faint) }.buttonStyle(.plain)
                }
            }
            .padInput()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                        if hits.isEmpty && q.count >= 2 { PadEmptyLine(text: "Nothing matches.") }
                        ForEach(hits) { h in hitRow(h) }
                    } else if loadingPages {
                        ForEach(0..<4, id: \.self) { _ in PadSkeleton(height: 46) }
                    } else if pages.isEmpty {
                        PadEmptyLine(text: binder == nil ? "Pick a binder." : "No pages yet. Quick note starts one.")
                    } else {
                        ForEach(pages) { p in pageRow(p) }
                    }
                }
            }
        }
        .padding(12)
    }

    private func pageRow(_ p: APINotebookPage) -> some View {
        let on = p.id == pageId
        let firstLine: String = p.body.split(separator: "\n").first.map { String($0) } ?? ""
        let title: String = p.title.isEmpty ? (firstLine.isEmpty ? "Untitled" : firstLine) : p.title
        return Button { pageId = p.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if p.pinned || p.linked { Image(systemName: p.linked ? "link" : "pin.fill").font(.system(size: 10, weight: .bold)).foregroundColor(Pad.faint) }
                    Text(title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                }
                Text("\(p.updatedAt.padWhen) · \(firstLine)").font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Pad.line2 : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func hitRow(_ h: APINotebookHit) -> some View {
        Button {
            let target = h.pageId
            q = ""
            binderId = h.binderId
            Task {
                await loadPages()
                pageId = target
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title.isEmpty ? "Untitled" : h.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                Text("\(h.binderName) · \(h.snippet)").font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: Editor

    @ViewBuilder
    private var editorColumn: some View {
        if let p = page, let b = binder {
            PadNotebookEditor(page: p, binder: b, binders: binders.filter { !$0.archived },
                              onSaved: { saved in replace(saved) },
                              onMoved: { Task { await loadBinders(); await loadPages() } },
                              onDeleted: {
                                  pages.removeAll { $0.id == p.id }
                                  pageId = pages.first?.id
                                  Task { await loadBinders() }
                              })
                .id(p.id)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(loading ? "" : "Pick a page, or start a quick note.").font(PadFont.ui(15)).foregroundColor(Pad.mute)
            }
            .padding(24)
        }
    }

    private func replace(_ p: APINotebookPage) {
        if let i = pages.firstIndex(where: { $0.id == p.id }) { pages[i] = p }
    }

    // MARK: Loading

    private func loadBinders() async {
        if let b = try? await APIClient.shared.notebook() { binders = b }
        loading = false
        if binderId == nil || !binders.contains(where: { $0.id == binderId }) {
            binderId = coachBinders.first?.id ?? clientBinders.first?.id
        }
    }

    private func loadPages() async {
        guard let id = binderId else { pages = []; return }
        loadingPages = pages.isEmpty
        let p = (try? await APIClient.shared.notebookPages(binderId: id)) ?? []
        guard id == binderId else { return }
        pages = p.sorted { a, b in
            if a.linked != b.linked { return a.linked }
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
        loadingPages = false
        if pageId == nil || !pages.contains(where: { $0.id == pageId }) { pageId = pages.first?.id }
    }

    private func search(_ t: String) {
        searchTask?.cancel()
        let s = t.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2 else { hits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let r = (try? await APIClient.shared.notebookSearch(s)) ?? []
            if !Task.isCancelled { hits = r }
        }
    }

    private func quickNote() async {
        let target = binderId ?? coachBinders.first?.id
        guard let target, let p = try? await APIClient.shared.createPage(binderId: target, title: "", body: "") else {
            PadToasts.shared.show("Couldn't start a note. Check your connection.")
            return
        }
        q = ""
        if binderId != target { binderId = target }
        pages.insert(p, at: pages.filter { $0.linked || $0.pinned }.count)
        pageId = p.id
    }
}

// MARK: - One page, saving as you type

struct PadNotebookEditor: View {
    let page: APINotebookPage
    let binder: APINotebookBinder
    let binders: [APINotebookBinder]
    var onSaved: (APINotebookPage) -> Void
    var onMoved: () -> Void
    var onDeleted: () -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var pinned = false
    @State private var loaded = false
    @State private var dirty = false
    @State private var status = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmDelete = false
    @Environment(\.padGo) private var go

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if page.linked {
                    Text(page.title.isEmpty ? "Notes" : page.title).font(PadFont.display(32)).foregroundColor(Pad.text).lineLimit(1)
                } else {
                    TextField("Title", text: $title).font(PadFont.display(32)).foregroundColor(Pad.text)
                }
                Spacer(minLength: 8)
                PadLab(status, color: Pad.faint, size: 12)
                Menu {
                    Button { Task { await togglePin() } } label: { Label(pinned ? "Unpin" : "Pin to top", systemImage: pinned ? "pin.slash" : "pin") }
                    if !page.linked {
                        Menu("Move to") {
                            ForEach(binders.filter { $0.id != binder.id }) { b in
                                Button(b.clientId == nil ? b.name : "\(b.name) (client)") { Task { await move(to: b.id) } }
                            }
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete page", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .semibold)).foregroundColor(Pad.text)
                        .frame(width: 44, height: 44)
                }
            }
            HStack(spacing: 6) {
                if let cid = binder.clientId {
                    Button { PadOpen.client(cid, .notes, go: go) } label: { PadTag(text: "Client: \(binder.name)", kind: .line) }
                        .buttonStyle(.plain)
                } else {
                    PadTag(text: binder.name, kind: .line)
                }
                if page.linked { PadTag(text: "Same as their Notes ▸ What to remember", kind: .line) }
                if pinned { PadTag(text: "Pinned", kind: .line) }
            }
            TextEditor(text: $text)
                .font(PadFont.ui(16)).foregroundColor(Pad.text).lineSpacing(4)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .onAppear {
            guard !loaded else { return }
            title = page.title; text = page.body; pinned = page.pinned; loaded = true
            status = "Saved \(page.updatedAt.padWhen)"
        }
        .onChange(of: title) { _, _ in touched() }
        .onChange(of: text) { _, _ in touched() }
        .onDisappear {
            saveTask?.cancel()
            guard dirty else { return }
            let id = page.id, fields = fieldsToSave()
            let done = onSaved
            Task {
                if let p = try? await APIClient.shared.updatePage(id: id, fields: fields) { done(p) }
            }
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: { Text("This can't be undone.") }
    }

    private func fieldsToSave() -> [String: Any] {
        var f: [String: Any] = ["body": text]
        if !page.linked { f["title"] = title }
        return f
    }

    private func touched() {
        guard loaded else { return }
        dirty = true
        status = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await saveNow()
        }
    }

    private func saveNow() async {
        let fields = fieldsToSave()
        let sentBody = text, sentTitle = title
        do {
            let p = try await APIClient.shared.updatePage(id: page.id, fields: fields)
            if sentBody == text && sentTitle == title { dirty = false }
            status = "Saved"
            onSaved(p)
        } catch {
            status = "Not saved. Check your connection."
        }
    }

    private func togglePin() async {
        if dirty { await saveNow() }
        if let p = try? await APIClient.shared.updatePage(id: page.id, fields: ["pinned": !pinned]) {
            pinned = p.pinned
            onSaved(p)
        }
    }

    private func move(to binderId: String) async {
        if dirty { await saveNow() }
        if (try? await APIClient.shared.updatePage(id: page.id, fields: ["binderId": binderId])) != nil {
            PadToasts.shared.show("Moved")
            onMoved()
        }
    }

    private func delete() async {
        saveTask?.cancel()
        dirty = false
        do {
            try await APIClient.shared.deletePage(id: page.id)
            onDeleted()
        } catch {
            PadToasts.shared.show("Couldn't delete. Try again.")
        }
    }
}

// MARK: - New binder

struct PadNewBinderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onMade: (APINotebookBinder) -> Void
    @State private var name = ""
    @State private var color = "volt"
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New binder").font(PadFont.display(28)).foregroundColor(Pad.text)
                Spacer()
                Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute).keyboardShortcut(.cancelAction)
            }
            TextField("Name", text: $name).padInput()
            HStack(spacing: 10) {
                ForEach(BinderColor.all, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(BinderColor.color(c)).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(color == c ? Pad.text : Color.clear, lineWidth: 2).padding(-4))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c)
                }
            }
            HStack {
                Spacer()
                Button("Make binder") { make() }
                    .buttonStyle(PadButtonStyle(kind: .primary))
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func make() {
        saving = true
        let n = name.trimmingCharacters(in: .whitespaces)
        Task {
            if let b = try? await APIClient.shared.createBinder(name: n, color: color) {
                onMade(b)
                dismiss()
            } else {
                saving = false
                PadToasts.shared.show("Couldn't make the binder. Try again.")
            }
        }
    }
}
