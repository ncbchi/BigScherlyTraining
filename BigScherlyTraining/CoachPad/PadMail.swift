import SwiftUI
import QuickLook

// MARK: - Coach HQ on iPad: Inbox (email to coach@) (Oct 15, 2026)
//
// Canvas "Inbox · 5 — iPad, three panes": threads | the email | who it's from, the same as Coach HQ on
// the web. The bar says how many are unread, who has waited longest and how many new people wrote;
// tapping one jumps there. Under 1100 points wide it shows one pane at a time and the details open
// in a sheet. The parts (rows, emails, reply bar, New email, the contact panel) are shared with the
// phone in CoachMailViews.swift and drawn here in the Platform look.
// Keyboard: ⌘⇧N new email, ⌘↵ send. Synchronized folder: no target step needed.

struct PadMailView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var box = MailBox.shared
    @StateObject private var model = MailThreadModel()
    @Environment(\.padGo) private var go
    @Environment(\.padSideBySide) private var sideBySide
    @AppStorage("bst_pad_mail_details") private var showDetails = true
    @State private var composing = false
    @State private var details = false
    @State private var confirmDelete: String?
    @State private var preview: URL?
    @State private var downloading = false

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Inbox", facts: facts) {
                if box.live { tools }
            }
            if !box.checked {
                VStack(alignment: .leading, spacing: 12) { PadSkeleton(height: 40); PadSkeleton(height: 120) }.padding(20)
                Spacer(minLength: 0)
            } else if !box.live {
                coming
            } else {
                panes
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .environment(\.mailLook, .iPad)
        .environment(\.mailActions, actions)
        .task { await box.show() }
        .sheet(isPresented: $composing) {
            MailComposeSheet { line in PadToasts.shared.show(line) }
                .environmentObject(store)
                .environment(\.mailLook, .iPad)
        }
        .sheet(isPresented: $details) {
            NavigationStack {
                ScrollView { MailContactPanel(model: model).padding(20) }
                    .background(Pad.surface.ignoresSafeArea())
                    .navigationTitle("Who is this?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { details = false }.foregroundColor(Pad.voltText) } }
            }
            .environmentObject(store)
            .environment(\.mailLook, .iPad)
            .environment(\.mailActions, actions)
            .presentationDetents([.medium, .large])
        }
        .quickLookPreview($preview)
        .confirmationDialog("Delete it forever?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let id = confirmDelete { deleteForever(id) } }
        } message: { Text("It can't be brought back.") }
        .background(keyCommands)
    }

    // MARK: Bar

    private var facts: [PadFact] {
        guard box.live, let s = box.status else { return [PadFact(bold: "coach@")] }
        var out: [PadFact] = [PadFact(bold: "\(s.unread ?? 0)", tail: " unread")]
        if let o = s.oldestWaiting {
            let days = PadDay.daysAgo(o.since)
            let tail: String = days <= 0 ? " waiting today" : " waiting \(days) day\(days == 1 ? "" : "s")"
            out.append(PadFact(bold: (o.name ?? "Someone").firstName, tail: tail, warn: days >= 1, run: {
                box.setFolder("inbox")
                select(o.threadId)
            }))
        }
        if let n = s.newPeople, n > 0 {
            out.append(PadFact(bold: "\(n)", tail: n == 1 ? " new person" : " new people", run: {
                box.setFolder("inbox"); box.filter = "others"
            }))
        }
        if let w = s.waiting, w > 1 { out.append(PadFact(bold: "\(w)", tail: " waiting on you")) }
        return out
    }

    private var folderOptions: [(id: String, label: String)] {
        MailText.folders.filter { $0.id != "trash" }.map { f -> (id: String, label: String) in
            let n: Int = box.status?.count(f.id) ?? 0
            return (id: f.id, label: n > 0 ? "\(f.name) \(n)" : f.name)
        }
    }

    @ViewBuilder private var tools: some View {
        PadSeg(options: folderOptions, selection: Binding(get: { box.folder == "trash" ? "inbox" : box.folder }, set: { f in
            Task { await model.close() }
            box.setFolder(f)
        }))
        Menu {
            Button { Task { await model.close() }; box.setFolder("trash") } label: { Label(box.folder == "trash" ? "Trash (open)" : "Trash", systemImage: "trash") }
            Button { Task { await box.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundColor(Pad.text)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
        }
        .accessibilityLabel("More")
        Button { composing = true } label: { Label("New email", systemImage: "square.and.pencil") }
            .buttonStyle(PadButtonStyle(kind: .primary))
    }

    private var keyCommands: some View {
        Button("New email") { composing = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    // MARK: Panes

    @ViewBuilder private var panes: some View {
        if sideBySide {
            HStack(spacing: 0) {
                listPane.frame(width: 340)
                Rectangle().fill(Pad.line).frame(width: 1)
                readerPane.frame(maxWidth: .infinity)
                if showDetails && model.thread != nil && box.folder != "sent" && box.folder != "drafts" {
                    Rectangle().fill(Pad.line).frame(width: 1)
                    ScrollView { MailContactPanel(model: model).padding(16) }
                        .frame(width: 290)
                        .background(Pad.page)
                }
            }
        } else if model.threadId == nil {
            listPane
        } else {
            readerPane
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.mute)
                    TextField("Search mail", text: Binding(get: { box.query }, set: { box.query = $0; box.searchChanged() }))
                        .font(PadFont.ui(15)).foregroundColor(Pad.text)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !box.query.isEmpty {
                        Button { box.query = ""; box.searchChanged() } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(Pad.faint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
                if box.folder == "inbox" {
                    PadSeg(options: [(id: "all", label: "All"), (id: "clients", label: "Clients"), (id: "others", label: "Others")],
                           selection: $box.filter)
                }
                if box.folder == "trash" {
                    HStack {
                        PadLab("Trash", size: 13)
                        Spacer()
                        Button("Back to Inbox") { box.setFolder("inbox") }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(Pad.line).frame(height: 1)
            ScrollView {
                if box.items == nil {
                    VStack(spacing: 12) { ForEach(0..<5, id: \.self) { _ in PadSkeleton(height: 64) } }.padding(12)
                } else if box.shown.isEmpty {
                    VStack(spacing: 4) {
                        Text(MailText.emptyLine(box.folder, searching: !box.query.isEmpty)).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                        if !box.listError.isEmpty { PadLab(box.listError, size: 13) }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(box.shown) { i in
                            Button { select(i.threadId) } label: { MailRow(item: i, folder: box.folder, selected: model.threadId == i.threadId) }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                                .contextMenu { rowMenu(i) }
                        }
                    }
                }
            }
            .refreshable { await box.refresh() }
        }
        .background(Pad.page)
    }

    @ViewBuilder private func rowMenu(_ i: MailItem) -> some View {
        if box.folder == "drafts" {
            Button(role: .destructive) { run({ try await box.deleteDraft(i.emailId) }, ok: "Draft deleted") } label: { Label("Delete draft", systemImage: "trash") }
        } else {
            ForEach(MailThreadActions.list(threadId: i.threadId, folder: box.folder, look: .iPad, actions: actions, confirmDelete: { confirmDelete = i.threadId })) { a in
                if a.destructive {
                    Button(role: .destructive) { a.run() } label: { Label(a.label, systemImage: a.icon) }
                } else if a.id == "unread" {
                    Button { run({ try await box.markRead(i.threadId, i.unread) }, ok: nil) } label: {
                        Label(i.unread ? "Mark as read" : "Mark as unread", systemImage: i.unread ? "envelope.open" : "envelope.badge")
                    }
                } else {
                    Button { a.run() } label: { Label(a.label, systemImage: a.icon) }
                }
            }
            if let s = i.scheduledAt, s > Date() {
                Button { run({ try await box.cancelScheduled(i.emailId) }, ok: "Stopped. It's back in Drafts.") } label: { Label("Don't send", systemImage: "xmark.circle") }
            }
        }
    }

    @ViewBuilder private var readerPane: some View {
        if model.threadId == nil {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 30)).foregroundColor(Pad.faint)
                Text("Pick an email").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                PadLab("Or write one with New email.", size: 13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                readerTop
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.loading && model.thread == nil {
                                PadSkeleton(height: 120); PadSkeleton(height: 220)
                            } else if !model.error.isEmpty {
                                VStack(spacing: 6) {
                                    Text("Couldn't open it.").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                                    PadLab(model.error, size: 13)
                                    Button("Try again") { if let id = model.threadId { Task { await model.open(id) } } }
                                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                                }
                                .frame(maxWidth: .infinity).padding(.top, 30)
                            } else {
                                if !sideBySide && box.folder != "sent" && box.folder != "drafts" {
                                    MailContactPanel(model: model, compact: true)
                                }
                                MailThreadEmails(model: model) { a in open(a) }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.thread?.emails.last?.id) { _, id in
                        if let id { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
                    }
                }
                if model.thread != nil && box.folder != "junk" && box.folder != "trash" {
                    MailReplyBar(model: model)
                }
            }
        }
    }

    private var readerTop: some View {
        let t = model.thread
        let people: String = {
            guard let t else { return "" }
            var seen: [String] = []
            for e in t.emails {
                let n = e.fromMe ? "you" : (e.from?.shown ?? "").firstName
                if !seen.contains(n) { seen.append(n) }
            }
            return "\(t.emails.count) email\(t.emails.count == 1 ? "" : "s") · " + seen.joined(separator: " and ")
        }()
        let list: [MailThreadAction] = model.threadId.map { id in
            MailThreadActions.list(threadId: id, folder: box.folder, look: .iPad, actions: actions, confirmDelete: { confirmDelete = id })
        } ?? []
        let clientId: String? = t?.contact?.clientId
        return HStack(spacing: 8) {
            if !sideBySide {
                PadIconButton(systemName: "chevron.left", label: "Back to the list", small: true) { Task { await model.close() } }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text((t?.subject ?? "").isEmpty ? "(no subject)" : (t?.subject ?? "")).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text).lineLimit(1)
                PadLab(people, size: 13).lineLimit(1)
            }
            Spacer(minLength: 6)
            ForEach(list) { a in
                PadIconButton(systemName: a.icon, label: a.label, small: true) { a.run() }
            }
            if let clientId {
                PadIconButton(systemName: "bubble.left", label: "Answer in Messages", small: true) { PadOpen.inbox(clientId, go: go) }
            }
            if !sideBySide {
                PadIconButton(systemName: "person.crop.circle", label: "Who is this?", small: true) { details = true }
            } else if box.folder != "sent" && box.folder != "drafts" {
                PadIconButton(systemName: "sidebar.right", label: showDetails ? "Hide details" : "Show details", small: true, on: showDetails) { showDetails.toggle() }
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
    }

    // MARK: Coming soon / can't reach

    private var coming: some View {
        let title: String = box.reason == "unreachable" ? "Can't reach the mail server" : (box.reason == "demo" ? "Not in Demo Mode" : "Email lands here soon")
        let msg: String
        switch box.reason {
        case "demo": msg = "Email to coach@ shows here when you're signed in to your coach account."
        case "notOwner": msg = "The coach@ inbox belongs to another Coach HQ login, so it isn't shown here."
        case "unreachable": msg = "Coach HQ can't reach the mail server right now" + (box.detail.isEmpty ? "." : ": \(box.detail)")
        default: msg = "Email to coach@bigscherlytraining.com shows up here once the mail server is switched on" + (box.detail.isEmpty ? "." : " (\(box.detail))")
        }
        return ScrollView {
            PadPane(title: title) {
                Text(msg).font(PadFont.ui(15)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { go(.inbox) } label: { Label("Open Messages", systemImage: "bubble.left") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    if box.reason == "unreachable" {
                        Button("Try again") { Task { await box.show() } }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Doing it

    private var actions: MailActions {
        MailActions(
            openClient: { id in PadOpen.client(id, go: go) },
            answerInMessages: { id in PadOpen.inbox(id, go: go) },
            openWorkouts: { id in PadOpen.client(id, .workouts, go: go) },
            toast: { t, u in PadToasts.shared.show(t, action: u == nil ? nil : "Undo", perform: u) },
            closed: { id in if model.threadId == id { Task { await model.close() } } }
        )
    }

    private func select(_ id: String) {
        Task { await model.open(id) }
    }

    private func deleteForever(_ id: String) {
        Task {
            do {
                try await box.deleteForever(id)
                if model.threadId == id { await model.close() }
                PadToasts.shared.show("Deleted")
            } catch {
                PadToasts.shared.show((error as? APIClient.APIError)?.message ?? "Couldn't delete it.")
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void, ok: String?) {
        Task {
            do { try await work(); if let ok { PadToasts.shared.show(ok) } }
            catch { PadToasts.shared.show((error as? APIClient.APIError)?.message ?? "Couldn't do that.") }
        }
    }

    private func open(_ a: MailAttachment) {
        guard !downloading else { return }
        downloading = true
        Task {
            do { preview = try await APIClient.shared.mailDownload(a) }
            catch { PadToasts.shared.show((error as? APIClient.APIError)?.message ?? "Couldn't download it.") }
            downloading = false
        }
    }
}
