import SwiftUI
import Combine
import PhotosUI
import AVKit

// MARK: - Coach HQ on iPad: Inbox (Oct 8, 2026)
//
// Three panes: every thread across the roster | the conversation | the client's context.
// The context sits beside the conversation when there's room, otherwise it's a sheet.
// Synchronized folder: no target step needed.

struct PadInboxView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var nav = PadNav.shared
    @Environment(\.padSideBySide) private var sideBySide
    @State private var unreadOnly = false
    @State private var category = "Any category"
    @State private var selected: String?        // thread id
    @State private var showContext = true
    @State private var contextSheet = false
    @State private var loaded = false

    struct Item: Identifiable {
        let client: RosterItem
        let thread: APIChatThread
        var id: String { thread.id }
    }

    private var items: [Item] {
        store.roster.flatMap { c in (coach.threads[c.id] ?? []).map { Item(client: c, thread: $0) } }
            .sorted { ($0.thread.unread > 0 ? 0 : 1, $1.thread.lastActivity) < ($1.thread.unread > 0 ? 0 : 1, $0.thread.lastActivity) }
    }
    private var shown: [Item] {
        items.filter { i in (!unreadOnly || i.thread.unread > 0) && (category == "Any category" || i.thread.category == category) }
    }
    private var current: Item? { items.first { $0.id == selected } }
    private var unread: Int { items.filter { $0.thread.unread > 0 }.count }

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Inbox", subtitle: unread == 0 ? "All caught up. Every client’s messages, voice notes and set comments, one thread per topic."
                                                             : "\(unread.plural("unread thread")). Every client’s messages, voice notes and set comments, one thread per topic.") {
                PadSeg(options: [(id: false, label: "All"), (id: true, label: "Unread")], selection: $unreadOnly)
                Menu {
                    Button("Any category") { category = "Any category" }
                    ForEach(ChatCategory.allCases, id: \.rawValue) { c in Button(c.rawValue) { category = c.rawValue } }
                } label: {
                    HStack(spacing: 6) { Text(category); Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                        .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                        .padding(.horizontal, 14).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
                }
                .hoverEffect(.highlight)
            }
            PadRule()
            HStack(spacing: 0) {
                threadList.frame(width: 320)
                Rectangle().fill(Pad.line).frame(width: 1)
                if let cur = current {
                    PadConversation(item: cur, showContext: showContext && sideBySide, onToggleContext: {
                        if sideBySide { withAnimation(.easeOut(duration: 0.15)) { showContext.toggle() } } else { contextSheet = true }
                    }, onSent: { Task { await coach.loadThreads(cur.client.id, force: true); store.loadRoster() } })
                    .id(cur.id)
                    if sideBySide && showContext {
                        Rectangle().fill(Pad.line).frame(width: 1)
                        PadClientContext(client: cur.client).frame(width: 300)
                    }
                } else {
                    emptyConversation
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .background(keys)
        .sheet(isPresented: $contextSheet) {
            if let cur = current {
                PadClientContext(client: cur.client, asSheet: true).presentationDetents([.medium, .large])
            }
        }
        .task {
            await coach.loadAllThreads(store.roster, force: true)
            loaded = true
            consumeNav()
            if selected == nil { selected = shown.first?.id }
        }
        .onChange(of: store.roster.map { $0.id }) { _, _ in Task { await coach.loadAllThreads(store.roster, force: true) } }
        .onChange(of: nav.inboxThreadId) { _, _ in consumeNav() }
        .onChange(of: nav.inboxClientId) { _, _ in consumeNav() }
    }

    private func consumeNav() {
        if let t = nav.inboxThreadId, items.contains(where: { $0.id == t }) {
            selected = t; nav.inboxThreadId = nil; nav.inboxClientId = nil
        } else if let c = nav.inboxClientId, let t = items.first(where: { $0.client.id == c }) {
            selected = t.id; nav.inboxClientId = nil; nav.inboxThreadId = nil
        }
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !loaded && items.isEmpty {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 12) { PadSkeleton(height: 34, width: 34); VStack(alignment: .leading, spacing: 6) { PadSkeleton(height: 12, width: 140); PadSkeleton(height: 12) } }
                            .padding(16)
                    }
                } else if shown.isEmpty {
                    Text(items.isEmpty ? "No conversations yet." : "Nothing here.").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(18)
                }
                ForEach(shown) { i in
                    threadRow(i)
                    PadRule()
                }
            }
        }
        .background(Pad.page)
    }

    private func threadRow(_ i: Item) -> some View {
        let on = i.id == selected
        let unread = i.thread.unread > 0
        return Button { selected = i.id } label: {
            HStack(alignment: .top, spacing: 12) {
                PadAvatar(name: i.client.name, size: 34, dot: i.client.needsAttention ? Pad.volt : (i.client.isDrifting ? Pad.orange : Pad.faint))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(i.client.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(i.thread.lastActivity.padWhen).font(PadFont.cond(12)).foregroundColor(Pad.faint)
                    }
                    Text("\(i.thread.topic.isEmpty ? "Conversation" : i.thread.topic) · \(i.thread.category)").font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
                    Text(i.thread.preview).font(PadFont.ui(14, unread ? .semibold : .regular)).foregroundColor(unread ? Pad.text : Pad.mute).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(on ? Pad.surface : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.isLight ? Pad.text : Pad.volt).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(i.client.name), \(i.thread.topic)\(unread ? ", \(i.thread.unread) unread" : "")")
    }

    private var emptyConversation: some View {
        VStack(spacing: 8) {
            Text("Pick a conversation").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            Text("Or start one from a client’s profile.").font(PadFont.ui(14)).foregroundColor(Pad.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// J / K move through the list.
    private var keys: some View {
        Group {
            Button("Next conversation") { step(1) }.keyboardShortcut("j", modifiers: .control)
            Button("Previous conversation") { step(-1) }.keyboardShortcut("k", modifiers: .control)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
    private func step(_ d: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let i = list.firstIndex(where: { $0.id == selected }) else { selected = list.first?.id; return }
        let j = min(max(i + d, 0), list.count - 1)
        selected = list[j].id
    }
}

// MARK: - The conversation

struct PadConversation: View {
    @EnvironmentObject var store: AppStore
    let item: PadInboxView.Item
    let showContext: Bool
    var onToggleContext: () -> Void
    var onSent: () -> Void

    @State private var messages: [APIChatMessage] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var pending: [Pending] = []
    @State private var recording = false
    @State private var pickedVideo: PhotosPickerItem?
    @State private var videoStatus: String?
    @State private var playing: IdentifiableURL?
    @State private var loadingVideo: String?
    @State private var previewing = false
    @FocusState private var composing: Bool
    @ObservedObject private var data = PadData.shared

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var failed = false
    }

    private var client: RosterItem { item.client }
    private var thread: APIChatThread { item.thread }

    var body: some View {
        VStack(spacing: 0) {
            header
            PadRule()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if !loaded {
                            ForEach(0..<4, id: \.self) { i in
                                HStack { if i % 2 == 1 { Spacer() }; PadSkeleton(height: 44, width: 260); if i % 2 == 0 { Spacer() } }
                            }
                        } else if messages.isEmpty && pending.isEmpty {
                            Text("No messages yet. Say hello.").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(.top, 30)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !Calendar.current.isDate(m.createdAt, inSameDayAs: messages[i - 1].createdAt) {
                                Text(dayLabel(m.createdAt)).font(PadFont.cond(12)).foregroundColor(Pad.faint)
                            }
                            bubble(m).id(m.id)
                        }
                        ForEach(pending) { p in
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(p.text).font(PadFont.ui(15)).foregroundColor(Pad.onVolt)
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(PadBubble(fromMe: true).fill(Pad.volt))
                                    .opacity(p.failed ? 0.6 : 0.85)
                                if p.failed {
                                    HStack(spacing: 8) {
                                        Text("Didn’t send").font(PadFont.cond(12)).foregroundColor(Pad.orange)
                                        Button("Retry") { retry(p) }.font(PadFont.cond(12, .bold)).foregroundColor(Pad.text)
                                    }
                                } else {
                                    Text("Sending…").font(PadFont.cond(12)).foregroundColor(Pad.mute)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id(p.id)
                        }
                    }
                    .padding(22)
                }
                .onChange(of: messages.count) { _, _ in if let l = messages.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
                .onChange(of: pending.count) { _, _ in if let l = pending.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            }
            PadRule()
            composer
        }
        .task { await load() }
        .sheet(isPresented: $recording) {
            VoiceNoteSheet(title: "Voice note to \(client.name.firstName)") { url, secs, transcript in
                try await APIClient.shared.sendVoiceNote(threadId: thread.id, fileURL: url, seconds: secs, transcript: transcript, asCoach: true)
                await load(); onSent()
            }
        }
        .sheet(item: $playing) { p in VideoPlayer(player: AVPlayer(url: p.url)).ignoresSafeArea() }
        .sheet(isPresented: $previewing) { ClientPreviewSheet(clientId: client.id, clientName: client.name) }
        .onChange(of: pickedVideo) { _, item in guard let item else { return }; Task { await sendVideo(item) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PadAvatar(name: client.name, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text).lineLimit(1)
                Text(contextLine).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("View as \(client.name.firstName)") { previewing = true }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            Button("Open profile") { store.selectedClient = client }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            PadIconButton(systemName: "sidebar.right", label: showContext ? "Hide details" : "Show details", on: showContext) { onToggleContext() }
        }
        .padding(.horizontal, 16).frame(height: 72)
    }

    private var contextLine: String {
        var bits = ["\(thread.topic.isEmpty ? "Conversation" : thread.topic) · \(thread.category)"]
        let today = data.sessions(client: client).first { Calendar.training.isDateInToday($0.day) }
        if let t = today { bits.append("\(t.title) today") }
        let per = data.sessions(client: client).filter { $0.day >= (Calendar.training.date(byAdding: .day, value: -28, to: Date()) ?? Date()) && $0.day < Calendar.training.startOfDay(for: Date()) }.count
        if per > 0 { bits.append("trains \(max(1, Int((Double(per) / 4).rounded()))) days a week") }
        return bits.joined(separator: " · ")
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    @ViewBuilder
    private func bubble(_ m: APIChatMessage) -> some View {
        let me = m.fromTrainer
        VStack(alignment: me ? .trailing : .leading, spacing: 4) {
            if m.isVoice {
                PadVoiceBubble(message: m, threadId: thread.id)
            } else {
                if let key = m.videoKey ?? (m.kind == "video" ? m.imageKey : nil) {
                    Button {
                        Task {
                            loadingVideo = m.id
                            if let url = try? await APIClient.shared.chatVideoFile(threadId: thread.id, key: key, asCoach: true) { playing = IdentifiableURL(url: url) }
                            loadingVideo = nil
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(Pad.well)
                            if loadingVideo == m.id { ProgressView().tint(Pad.text) }
                            else { Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundColor(Pad.text.opacity(0.9)) }
                        }
                        .frame(width: 220, height: 140)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Pad.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play video")
                }
                if let ref = m.setRef {
                    HStack(spacing: 12) {
                        PadTag(text: "Set comment", kind: .volt)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(ref.exerciseName), set \(ref.setNumber)").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                            Text("\(ref.summary) · \(ref.workoutTitle) · \(ref.workoutDate.formatted(.dateTime.month(.abbreviated).day()))").font(PadFont.cond(13)).foregroundColor(Pad.mute)
                        }
                    }
                    .padding(10).padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line2, lineWidth: 1))
                }
                let txt = m.kind == "setComment" ? setCommentBody(m.text) : m.text
                if !txt.isEmpty {
                    Text(txt).font(PadFont.ui(15)).foregroundColor(me ? Pad.onVolt : Pad.text).lineSpacing(3)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(PadBubble(fromMe: me).fill(me ? Pad.volt : Pad.surface))
                        .overlay(me ? nil : PadBubble(fromMe: false).stroke(Pad.line, lineWidth: 1))
                        .textSelection(.enabled)
                }
            }
            Text(me ? "\(m.createdAt.padClock)\(m.isRead ? " · Seen" : "")" : m.createdAt.padClock).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
        .frame(maxWidth: 560, alignment: me ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.savedReplies, id: \.self) { r in PadChip(text: r) { draft = draft.isEmpty ? r : draft + " " + r; composing = true } }
                }
            }
            if let videoStatus {
                HStack(spacing: 8) {
                    if videoStatus.hasSuffix("…") { ProgressView().tint(Pad.text) }
                    Text(videoStatus).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(client.name.firstName)", text: $draft, axis: .vertical)
                    .lineLimit(1...6).focused($composing)
                    .padInput(multiline: true)
                    .onSubmit { send() }
                PadIconButton(systemName: "mic.fill", label: "Record a voice note") { recording = true }
                PhotosPicker(selection: $pickedVideo, matching: .videos, photoLibrary: .shared()) {
                    Image(systemName: "video.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(Pad.text)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
                }
                .accessibilityLabel("Send a video")
                Button("Send") { send() }.buttonStyle(PadButtonStyle(kind: .primary))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Button("Reply") { composing = true }.keyboardShortcut("r", modifiers: .control)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
    }

    private func load() async {
        messages = (try? await APIClient.shared.trainerMessages(threadId: thread.id)) ?? messages
        loaded = true
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        let p = Pending(text: t)
        pending.append(p)
        Task { await deliver(p) }
    }

    private func retry(_ p: Pending) {
        if let i = pending.firstIndex(of: p) { pending[i].failed = false }
        Task { await deliver(p) }
    }

    private func deliver(_ p: Pending) async {
        do {
            try await APIClient.shared.trainerSendMessage(threadId: thread.id, text: p.text)
            await load()
            pending.removeAll { $0.id == p.id }
            onSent()
        } catch {
            if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i].failed = true }
        }
    }

    private func sendVideo(_ item: PhotosPickerItem) async {
        videoStatus = "Compressing video…"
        defer { pickedVideo = nil }
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else { videoStatus = nil; return }
            let out = try await VideoCompressor.compress(movie.url)
            let size = (try? FileManager.default.attributesOfItem(atPath: out.url.path)[.size] as? Int) ?? 0
            if size > 28_000_000 { videoStatus = "That video is too long to send (\(size / 1_000_000) MB). Trim it to about a minute."; return }
            videoStatus = "Sending video…"
            try await APIClient.shared.coachSendVideo(threadId: thread.id, fileURL: out.url, caption: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""; videoStatus = nil
            await load(); onSent()
        } catch {
            videoStatus = (error as? APIClient.APIError)?.message ?? "Couldn’t send the video. Try again."
        }
    }
}

/// Rounded on three corners, tight on the tail corner.
struct PadBubble: Shape {
    let fromMe: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16, t: CGFloat = 5
        var p = Path()
        let bl: CGFloat = fromMe ? r : t, br: CGFloat = fromMe ? t : r
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A voice note: play button, waveform, duration; the transcript under it, and the 14-day note.
struct PadVoiceBubble: View {
    let message: APIChatMessage
    let threadId: String
    @ObservedObject private var playback = VoicePlayback.shared
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let bars: [CGFloat] = [6, 10, 16, 22, 14, 8, 18, 26, 20, 12, 8, 14, 24, 18, 10, 6, 12, 20, 26, 16, 10, 8, 14, 18, 12, 8, 6, 10, 14, 8]

    private var secs: Double { message.voiceSeconds ?? 0 }
    private var clock: String { let t = Int(secs.rounded()); return "\(t / 60):" + String(format: "%02d", t % 60) }
    private var available: Bool { message.voiceAvailable ?? false }
    private var playingThis: Bool { playback.playingId == message.id }

    var body: some View {
        VStack(alignment: message.fromTrainer ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 12) {
                if available {
                    Button {
                        Task { await playback.toggle(id: message.id) { try await APIClient.shared.voiceNoteAudio(threadId: threadId, messageId: message.id, asCoach: true) } }
                    } label: {
                        ZStack {
                            Circle().fill(Pad.text).frame(width: 36, height: 36)
                            if playback.loadingId == message.id { ProgressView().tint(Pad.isLight ? .white : Pad.ink) }
                            else { Image(systemName: playingThis ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold)).foregroundColor(Pad.isLight ? .white : Pad.ink) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playingThis ? "Pause voice note" : "Play voice note")
                } else {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundColor(Pad.mute)
                        .frame(width: 36, height: 36).background(Circle().fill(Pad.raised))
                }
                HStack(spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, h in
                        let played = playingThis && Double(i) / Double(bars.count) < playback.progress
                        Capsule().fill(played ? Pad.voltText : Pad.mute).frame(width: 3, height: h)
                    }
                }
                .frame(height: 28)
                .accessibilityHidden(true)
                Text(clock).font(PadFont.cond(13)).foregroundColor(Pad.mute)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(PadBubble(fromMe: message.fromTrainer).fill(Pad.surface))
            .overlay(PadBubble(fromMe: message.fromTrainer).stroke(message.fromTrainer ? Pad.line2 : Pad.line, lineWidth: 1))
            Text(transcriptLine).font(PadFont.ui(14)).foregroundColor(Pad.mute).lineSpacing(2)
                .multilineTextAlignment(message.fromTrainer ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .onReceive(timer) { _ in if playingThis { playback.tick() } }
        .onDisappear { if playingThis { playback.stop() } }
    }

    private var transcriptLine: String {
        let t = (message.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = t.isEmpty ? "No transcript" : "“\(t)”"
        if available, let e = message.voiceExpiresAt {
            let d = max(0, Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0)
            return base + " · audio kept \(d.plural("more day")), then just the transcript"
        }
        return available ? base : base + " · audio removed after 14 days"
    }
}

// MARK: - The client's context (beside the conversation, or a sheet)

struct PadClientContext: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    let client: RosterItem
    var asSheet = false
    @State private var note = ""
    @State private var noteLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var noteStatus = ""
    @State private var previewing = false

    private var cal: Calendar { Calendar.training }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("About \(client.name.firstName)").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                Spacer()
                if asSheet { PadIconButton(systemName: "xmark", label: "Close", small: true) { dismiss() } }
                else { PadLab("⌃J / ⌃K to move", color: Pad.faint) }
            }
            .padding(.horizontal, 18).frame(height: 56)
            PadRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    lifts
                    week
                    VStack(spacing: 0) {
                        row("Next session", nextSession)
                        PadRule()
                        row("Last check-in", lastCheckIn)
                        PadRule()
                        row("Supplements, last 30 days", supplements)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { PadLab("Your private note"); Spacer(); PadLab(noteStatus, color: Pad.faint) }
                        TextEditor(text: $note).scrollContentBackground(.hidden)
                            .font(PadFont.ui(14)).foregroundColor(Pad.mute).frame(minHeight: 90)
                            .padWell(10)
                            .onChange(of: note) { _, _ in if noteLoaded { touched() } }
                    }
                    if asSheet {
                        HStack(spacing: 8) {
                            Button("View as \(client.name.firstName)") { previewing = true }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                            Button("Open profile") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.selectedClient = client } }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        }
                    }
                }
                .padding(18)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .task {
            await data.loadContext(client.id)
            await coach.loadCheckIns(client.id)
            note = data.notes[client.id] ?? ""
            noteLoaded = true
        }
        .sheet(isPresented: $previewing) { ClientPreviewSheet(clientId: client.id, clientName: client.name) }
    }

    private var lifts: some View {
        let best = data.bestLifts(clientId: client.id)
        return VStack(alignment: .leading, spacing: 8) {
            PadLab("Best lifts, last 8 weeks")
            if best.isEmpty {
                Text(data.hasLoaded ? "No squat, bench or deadlift logged yet." : "").font(PadFont.ui(13)).foregroundColor(Pad.mute)
            } else {
                HStack(spacing: 6) {
                    ForEach(best, id: \.name) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            PadLab(b.name.replacingOccurrences(of: "Back ", with: "").replacingOccurrences(of: " Press", with: ""))
                            PadNumber(value: StatsUnits.weightText(b.e1rm, unit: false), size: 30)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padWell(10)
                    }
                }
            }
        }
    }

    private var week: some View {
        let start = cal.startOfWeek(for: Date())
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? Date()
        let ss = data.sessions(client: client).filter { $0.day >= start && $0.day < end }
        let done = ss.filter { $0.isDone }.count
        return VStack(alignment: .leading, spacing: 8) {
            PadLab("This week")
            PadNumber(value: "\(done)", unit: "of \(ss.count.plural("session"))", size: 30)
            PadBar(fraction: ss.isEmpty ? 0 : Double(done) / Double(ss.count))
        }
    }

    private var nextSession: String {
        let today = cal.startOfDay(for: Date())
        guard let n = data.sessions(client: client).filter({ !$0.isDone && $0.day >= today }).min(by: { $0.day < $1.day }) else { return "Nothing planned" }
        let day = cal.isDateInToday(n.day) ? "Today" : (cal.isDateInTomorrow(n.day) ? "Tomorrow" : n.day.formatted(.dateTime.weekday(.wide)))
        return "\(day) · \(n.title)"
    }

    private var lastCheckIn: String {
        guard let ci = (coach.checkIns[client.id] ?? []).filter({ $0.status != "draft" }).max(by: { $0.date < $1.date }) else { return "None yet" }
        var bits = [ci.date.formatted(.dateTime.weekday(.wide))]
        if let w = ci.fields.first(where: { $0.cleanLabel.lowercased().contains("weight") }), let v = Double(w.value) { bits.append(StatsUnits.weightText(v)) }
        if let s = ci.fields.first(where: { $0.cleanLabel.lowercased().contains("sleep") }), Double(s.value) != nil { bits.append("sleep \(s.value)/10") }
        return bits.joined(separator: " · ")
    }

    private var supplements: String {
        guard let a = data.adherence[client.id] else { return "—" }
        if a.totalExpected == 0 { return "Nothing on their protocol" }
        return "\(Int((a.overallRate * 100).rounded()))% taken · \(a.totalTaken) of \(a.totalExpected)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PadLab(label)
            Text(value).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }

    private func touched() {
        noteStatus = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            do {
                try await APIClient.shared.saveClientNote(clientId: client.id, body: note)
                data.setNote(client.id, note)
                noteStatus = "Saved"
            } catch { noteStatus = "Not saved" }
        }
    }
}
