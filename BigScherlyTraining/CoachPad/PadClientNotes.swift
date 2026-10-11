import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's Notes and Chat (Oct 9, 2026)
//
// Notes: "What to remember" pinned on top (the same private note the Inbox shows beside a
// conversation), your pages on the left with the editor at full width, and an automatic timeline
// of what happened (program changes, PRs, flagged answers, missed runs, photos) so the notes have
// context. Tools: new page, quick note (⌘⇧N).
// Chat: the Inbox conversation screen for this client only. Tools: new conversation, check-in nudge.
// Synchronized folder: no target step needed.

// MARK: - Notes

struct PadClientNotes: View {
    let facts: PadClientFacts
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @State private var binder: APINotebookBinder?
    @State private var pages: [APINotebookPage] = []
    @State private var selectedId: String?
    @State private var title = ""
    @State private var text = ""
    @State private var remember = ""
    @State private var rememberLoaded = false
    @State private var status = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var rememberTask: Task<Void, Never>?
    @State private var loaded = false

    private var cal: Calendar { Calendar.training }
    private var own: [APINotebookPage] { pages.filter { !$0.linked }.sorted { ($0.pinned ? 0 : 1, $1.updatedAt) < ($1.pinned ? 0 : 1, $0.updatedAt) } }

    var body: some View {
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(), notices: []) {
                Button { Task { await newPage(quick: true) } } label: { Label("Quick note", systemImage: "square.and.pencil") }
                    .buttonStyle(PadButtonStyle(kind: .primary, small: true))
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button { Task { await newPage(quick: false) } } label: { Label("New page", systemImage: "doc.badge.plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            rememberCard.padding(.horizontal, 20).padding(.bottom, 14)
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                pageList.frame(width: 260)
                Rectangle().fill(Pad.line).frame(width: 1)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Pad.line).frame(width: 1)
                timeline.frame(width: 300).background(Pad.page)
            }
        }
        .task { await load() }
        .onDisappear {
            // Leaving mid-type: save now rather than lose the last second of typing.
            flush()
            if rememberTask != nil {
                rememberTask?.cancel()
                let id = facts.id, t = remember
                Task { try? await APIClient.shared.saveClientNote(clientId: id, body: t); data.setNote(id, t) }
            }
        }
    }

    private func load() async {
        if let n = try? await APIClient.shared.clientNote(clientId: facts.id) {
            remember = n.body
            data.setNote(facts.id, n.body)
        } else {
            remember = data.notes[facts.id] ?? ""
        }
        await data.loadContext(facts.id)
        rememberLoaded = true
        if let nb = try? await APIClient.shared.clientNotebook(clientId: facts.id) {
            binder = nb.binder
            pages = nb.pages
            if selectedId == nil, let first = own.first { select(first) }
        }
        loaded = true
        await coach.loadCheckIns(facts.id)
    }

    private func stats() -> [PadStat] {
        let last = own.map { $0.updatedAt }.max()
        return [
            PadStat(label: "Pages", value: "\(own.count)", sub: binder.map { "in \($0.name)" } ?? ""),
            PadStat(label: "Last written", value: last.map { "\(PadDay.daysAgo($0))" } ?? "—", unit: last == nil ? nil : "days ago",
                    sub: last.map { PadDay.short($0) } ?? "nothing yet")
        ]
    }

    // MARK: What to remember

    private var rememberCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pin.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.voltText)
                Text("What to remember").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("injuries, schedule, preferences, goals · also shows beside their chats", color: Pad.faint, size: 11)
            }
            TextEditor(text: $remember)
                .scrollContentBackground(.hidden)
                .font(PadFont.ui(14)).foregroundColor(Pad.text)
                .frame(minHeight: 64, maxHeight: 96)
                .onChange(of: remember) { _, t in
                    guard rememberLoaded, t != data.notes[facts.id] else { return }
                    rememberTask?.cancel()
                    let id = facts.id
                    rememberTask = Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        if Task.isCancelled { return }
                        try? await APIClient.shared.saveClientNote(clientId: id, body: t)
                        data.setNote(id, t)
                        rememberTask = nil
                    }
                }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    // MARK: Pages

    private var pageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if own.isEmpty && loaded { PadEmptyLine(text: "No pages yet.").padding(.horizontal, 6) }
                ForEach(own) { p in
                    let on = p.id == selectedId
                    Button { flush(); select(p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if p.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(Pad.voltText) }
                                Text(p.title.isEmpty ? "Untitled" : p.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                            }
                            Text(preview(p))
                                .font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.surface : Color.clear))
                        .overlay(alignment: .leading) { if on { RoundedRectangle(cornerRadius: 1.5).fill(Pad.volt).frame(width: 3).padding(.vertical, 8) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(8)
        }
    }

    private func preview(_ p: APINotebookPage) -> String {
        let flat: String = p.body.replacingOccurrences(of: "\n", with: " ")
        return PadDay.short(p.updatedAt) + " · " + String(flat.prefix(60))
    }

    private func select(_ p: APINotebookPage) {
        selectedId = p.id; title = p.title; text = p.body; status = ""
    }

    private var editor: some View {
        Group {
            if let id = selectedId, pages.contains(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Title", text: $title).font(PadFont.display(28)).foregroundColor(Pad.text)
                            .onChange(of: title) { _, _ in touched() }
                        PadLab(status, color: Pad.faint, size: 12)
                    }
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .font(PadFont.ui(16)).foregroundColor(Pad.text).lineSpacing(4)
                        .onChange(of: text) { _, _ in touched() }
                }
                .padding(20)
            } else {
                PadEmptyLine(text: loaded ? "Pick a page, or start one with Quick note (⌘⇧N)." : "").padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func touched() {
        guard let id = selectedId, let p = pages.first(where: { $0.id == id }), title != p.title || text != p.body else { return }
        status = "Saving…"
        saveTask?.cancel()
        let t = title, b = text
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await save(id: id, title: t, body: b)
        }
    }

    private func flush() {
        guard let id = selectedId, let p = pages.first(where: { $0.id == id }), title != p.title || text != p.body else { return }
        saveTask?.cancel()
        let t = title, b = text
        Task { await save(id: id, title: t, body: b) }
    }

    private func save(id: String, title t: String, body b: String) async {
        do {
            let p = try await APIClient.shared.updatePage(id: id, fields: ["title": t, "body": b])
            if let i = pages.firstIndex(where: { $0.id == id }) { pages[i] = p }
            if selectedId == id { status = "Saved" }
        } catch {
            if selectedId == id { status = "Not saved, check your connection" }
        }
    }

    private func newPage(quick: Bool) async {
        guard let b = binder else { return }
        flush()
        let name = quick ? "Note, \(Date().formatted(.dateTime.month(.abbreviated).day()))" : "Untitled"
        if let p = try? await APIClient.shared.createPage(binderId: b.id, title: name, body: "") {
            pages.append(p)
            select(p)
        } else {
            PadToasts.shared.show("Couldn’t add a page. Try again.")
        }
    }

    // MARK: Timeline

    struct Event: Identifiable {
        let id: String
        let date: Date
        let icon: String
        let tint: Color
        let text: String
    }

    private var events: [Event] {
        let since = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        var out: [Event] = []
        for a in data.assignments where a.clientId == facts.id {
            if a.startDate >= since { out.append(Event(id: "as-\(a.id)", date: a.startDate, icon: "list.bullet.rectangle", tint: Pad.blue, text: "Started \(a.programName)")) }
            if a.endDate >= since && a.endDate <= Date() { out.append(Event(id: "ae-\(a.id)", date: a.endDate, icon: "flag.checkered", tint: Pad.mute, text: "Finished \(a.programName)")) }
        }
        for p in ProgressEngine.allPRs(workouts: data.workouts[facts.id] ?? []) where !p.isFirstEver && p.date >= since {
            out.append(Event(id: "pr-\(p.id)", date: p.date, icon: "bolt.fill", tint: Pad.voltText, text: "\(p.exercise) PR, \(StatsUnits.weightText(p.estimatedOneRepMax)) e1RM"))
        }
        for c in (coach.checkIns[facts.id] ?? []) where c.status != "draft" && c.date >= since {
            if let f = PadCheckInReview.flaggedLine(c) {
                let short: String = f.count > 70 ? String(f.prefix(68)) + "…" : f
                out.append(Event(id: "ci-\(c.id)", date: c.date, icon: "exclamationmark.triangle", tint: Pad.orange, text: "Flagged: “" + short + "”"))
            }
        }
        // Runs of 2+ missed sessions.
        let ss = data.sessions(client: facts.client).filter { $0.day >= since && $0.day < cal.startOfDay(for: Date()) }.sorted { $0.day < $1.day }
        var run: [PadSession] = []
        func closeRun() {
            if run.count >= 2, let f = run.first { out.append(Event(id: "mr-\(f.id)", date: f.day, icon: "calendar.badge.exclamationmark", tint: Pad.orange, text: "Missed \(run.count) sessions in a row")) }
            run = []
        }
        for s in ss { if s.isMissed { run.append(s) } else if s.isDone { closeRun() } }
        closeRun()
        return out.sorted { $0.date > $1.date }
    }

    private var timeline: some View {
        let es = events
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What happened").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).padding(.bottom, 4)
                PadLab("Last 90 days, filled in for you", color: Pad.faint, size: 12).padding(.bottom, 10)
                if es.isEmpty { PadEmptyLine(text: "Nothing yet.") }
                ForEach(es) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.icon).font(.system(size: 12, weight: .semibold)).foregroundColor(e.tint)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Pad.raised))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).font(PadFont.ui(13)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
                            PadLab(PadDay.weekdayShort(e.date), color: Pad.faint, size: 11)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Chat

struct PadClientChat: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var coach = CoachData.shared
    @State private var selectedId: String?
    @State private var newThread = false
    @State private var topic = ""
    @State private var category = ChatCategory.general
    @State private var quick: PadQuickMessage?

    private var threads: [APIChatThread] { (coach.threads[facts.id] ?? []).sorted { $0.lastActivity > $1.lastActivity } }

    var body: some View {
        let ts = threads
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(ts), notices: []) {
                Button { newThread = true } label: { Label("New conversation", systemImage: "plus.bubble") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                Button {
                    quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Check-in nudge",
                                            text: "Hey \(facts.first), your weekly check-in is due. Takes about two minutes and helps me plan your next week.")
                } label: { Label("Check-in nudge", systemImage: "bell") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadRule()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        if ts.isEmpty { PadEmptyLine(text: "No conversations yet.").padding(.horizontal, 8) }
                        ForEach(ts, id: \.id) { t in threadRow(t) }
                    }
                    .padding(8)
                }
                .frame(width: 300)
                Rectangle().fill(Pad.line).frame(width: 1)
                if let t = ts.first(where: { $0.id == selectedId }) ?? ts.first {
                    PadConversation(item: PadInboxView.Item(client: facts.client, thread: t), showContext: false, embedded: true,
                                    onToggleContext: {}, onSent: { Task { await coach.loadThreads(facts.id, force: true) } })
                        .id(t.id)
                } else {
                    PadEmptyLine(text: "Start a conversation with New conversation.").padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .task { await coach.loadThreads(facts.id, force: true) }
        .sheet(item: $quick) { m in PadQuickMessageSheet(message: m) }
        .sheet(isPresented: $newThread) { newThreadSheet }
    }

    private func stats(_ ts: [APIChatThread]) -> [PadStat] {
        let unread = ts.reduce(0) { $0 + $1.unread }
        let last = ts.first?.lastActivity
        return [
            PadStat(label: "Conversations", value: "\(ts.count)", sub: Set(ts.map { $0.category }).sorted().joined(separator: ", ")),
            PadStat(label: "Unread", value: "\(unread)", sub: unread > 0 ? "waiting on you" : "all read", warn: unread > 0),
            PadStat(label: "Last message", value: last.map { "\(PadDay.daysAgo($0))" } ?? "—", unit: last == nil ? nil : "days ago", sub: last.map { $0.padWhen } ?? "")
        ]
    }

    private func threadRow(_ t: APIChatThread) -> some View {
        let on = t.id == (selectedId ?? threads.first?.id)
        return Button { selectedId = t.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.topic.isEmpty ? "Conversation" : t.topic).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if t.unread > 0 { PadTag(text: "\(t.unread)", kind: .volt) }
                    Text(t.lastActivity.padAgo).font(PadFont.cond(11)).foregroundColor(Pad.faint)
                }
                Text(t.category).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                Text(t.preview).font(PadFont.ui(13)).foregroundColor(t.unread > 0 ? Pad.text : Pad.mute).lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.surface : Color.clear))
            .overlay(alignment: .leading) { if on { RoundedRectangle(cornerRadius: 1.5).fill(Pad.volt).frame(width: 3).padding(.vertical, 8) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private var newThreadSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New conversation").font(PadFont.display(28)).foregroundColor(Pad.text)
                Spacer()
                Button("Cancel") { newThread = false }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute)
            }
            TextField("Topic, e.g. Hip warm-up", text: $topic).padInput()
            PadSeg(options: ChatCategory.allCases.map { (id: $0, label: $0.rawValue) }, selection: $category)
            HStack {
                Spacer()
                Button("Start") {
                    let t = topic.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    Task {
                        if let th = try? await APIClient.shared.trainerCreateChat(clientId: facts.id, topic: t, category: category.rawValue) {
                            await coach.loadThreads(facts.id, force: true)
                            selectedId = th.id
                        }
                        newThread = false; topic = ""
                    }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}
