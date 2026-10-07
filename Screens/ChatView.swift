import SwiftUI
import PhotosUI
import AVKit
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Chat: categorized thread list
struct ChatListView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: ChatThread?
    @State private var filter: ChatCategory? = nil
    @State private var showNew = false

    var filtered: [ChatThread] {
        let base = store.chats.sorted { $0.lastActivity > $1.lastActivity }
        guard let f = filter else { return base }
        return base.filter { $0.category == f }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    DSScreenHeader(eyebrow: "Talk To Coach", title: "Chat",
                                   subtitle: store.unreadMessages > 0
                                       ? "\(store.unreadMessages) unread from your coach"
                                       : "Questions, form checks, anything.")
                    Spacer()
                    DSIconButton(systemName: "square.and.pencil", accessibilityLabel: "New conversation",
                                 size: 48, tint: Brand.onVolt, fill: Brand.volt) { showNew = true }
                }

                // Category filter: All in the middle, swipe either way
                DSCarousel(options: [DSCarousel<String>.Option(id: "All", label: "All")]
                                    + ChatCategory.allCases.map { DSCarousel<String>.Option(id: $0.rawValue, label: $0.rawValue) },
                           selection: Binding(get: { filter?.rawValue ?? "All" },
                                              set: { filter = ChatCategory(rawValue: $0) }),
                           likely: "All", itemWidth: 116, accessibilityName: "Show conversations")

                ForEach(filtered) { t in
                    Button { selected = t } label: { threadRow(t) }
                        .buttonStyle(PressableStyle())
                }

                if filtered.isEmpty {
                    EmptyState(icon: "bubble.left.and.bubble.right",
                               title: "No conversations yet",
                               message: "Tap the compose button to start a chat with your coach.")
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .sheet(item: $selected) { t in ChatThreadView(thread: t).environmentObject(store) }
        .sheet(isPresented: $showNew) { NewChatSheet().environmentObject(store) }
    }

    func chip(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased()).font(BrandFont.body(11, .bold)).tracking(0.5)
                .foregroundColor(on ? Brand.onVolt : Brand.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Brand.volt : Brand.black).clipShape(Capsule())
                .overlay(Capsule().stroke(on ? Brand.voltLine : Brand.line, lineWidth: 1))
        }
    }
    func threadRow(_ t: ChatThread) -> some View {
        let icon: String = {
            switch t.category {
            case .general: return "bubble.left.fill"
            case .form: return "figure.strengthtraining.traditional"
            case .nutrition: return "fork.knife"
            case .program: return "list.bullet.clipboard"
            case .admin: return "person.text.rectangle"
            }
        }()
        let last = t.messages.last
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundColor(t.unread > 0 ? Brand.onVolt : Brand.voltText)
                .frame(width: 44, height: 44)
                .background(Circle().fill(t.unread > 0 ? Brand.volt : Brand.text.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t.topic).font(BrandFont.body(15, t.unread > 0 ? .heavy : .bold)).foregroundColor(Brand.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(t.lastActivity.formatted(.relative(presentation: .named)))
                        .font(BrandFont.body(10)).foregroundColor(Brand.mute).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(t.category.rawValue.uppercased()).font(BrandFont.body(8, .bold)).tracking(0.6)
                        .foregroundColor(Brand.voltText).padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
                    Text((last?.fromTrainer == true ? "Coach: " : "You: ") + t.preview)
                        .font(BrandFont.body(13, t.unread > 0 ? .semibold : .regular))
                        .foregroundColor(t.unread > 0 ? Brand.text : Brand.mute).lineLimit(1)
                }
            }
            if t.unread > 0 {
                Text("\(t.unread)").font(BrandFont.body(11, .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 22, height: 22).background(Circle().fill(Brand.volt))
            }
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(t.unread > 0 ? Brand.voltLine.opacity(0.5) : Brand.line, lineWidth: 1))
    }
}

// MARK: - Single chat thread (iMessage-style bubbles)
struct ChatThreadView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var thread: ChatThread
    @State private var draft = ""

    // Video attachments
    @State private var pickedItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var localVideos: [String: URL] = [:]   // messageID -> compressed file (this session)
    @State private var thumbs: [String: UIImage] = [:]     // messageID -> poster frame
    @State private var playing: IdentifiableURL?           // drives the player sheet

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if thread.messages.isEmpty {
                    EmptyState(icon: "bubble.left.and.text.bubble",
                               title: "Say the first thing",
                               message: "Describe what's going on. A short video of the set helps your coach see it.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                let ms = thread.messages
                                ForEach(Array(ms.enumerated()), id: \.element.id) { i, m in
                                    let prev = i > 0 ? ms[i - 1] : nil
                                    let next = i + 1 < ms.count ? ms[i + 1] : nil
                                    if startsNewDay(prev, m) { daySeparator(m.timestamp) }
                                    bubble(m, joinsPrevious: grouped(prev, m), joinsNext: grouped(m, next))
                                        .padding(.top, grouped(prev, m) ? 3 : 12)
                                        .id(m.id)
                                }
                            }
                            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
                        }
                        // Newest at the bottom: opens there, and stays there as messages land.
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: thread.messages.count) { _, _ in
                            guard let last = thread.messages.last else { return }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView().tint(Brand.volt)
                        Text("Compressing video…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    .padding(.bottom, 6)
                }
                // Composer
                HStack(spacing: 12) {
                    PhotosPicker(selection: $pickedItem, matching: .videos, photoLibrary: .shared()) {
                        Image(systemName: "video.badge.plus").foregroundColor(Brand.voltText).font(.system(size: 22))
                    }
                    TextField("", text: $draft, prompt: Text("Message coach…").foregroundColor(Brand.mute))
                        .foregroundColor(Brand.text).padding(12).background(Brand.black)
                        .overlay(Capsule().stroke(Brand.line, lineWidth: 1)).clipShape(Capsule())
                    let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        guard canSend else { return }
                        let text = draft
                        thread.messages.append(ChatMessage(id: UUID().uuidString, text: text, fromTrainer: false, timestamp: Date()))
                        draft = ""
                        if store.isLive {
                            Task { try? await APIClient.shared.sendMessage(threadId: thread.id, text: text) }
                        }
                    } label: {
                        Image(systemName: "arrow.up").foregroundColor(canSend ? Brand.onVolt : Brand.mute)
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(canSend ? Brand.volt : Brand.text.opacity(0.10)))
                    }
                    .disabled(!canSend)
                    .animation(.easeInOut(duration: 0.15), value: canSend)
                    .accessibilityLabel("Send")
                }
                .padding(14).background(Brand.bg)
                .overlay(Rectangle().fill(Brand.line).frame(height: 1), alignment: .top)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(thread.topic)
            .navigationBarTitleDisplayMode(.inline)
            .tapToDismissKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.voltText) }
            }
            .task {
                // Load full message history from the API when the thread opens
                if store.isLive, thread.messages.isEmpty {
                    if let msgs = try? await APIClient.shared.messages(thread.id) {
                        thread.messages = msgs.map { $0.toModel() }
                    }
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await handlePickedVideo(item) }
            }
            .sheet(item: $playing) { p in
                VideoPlayer(player: AVPlayer(url: p.url)).ignoresSafeArea()
            }
        }
    }

    // Compress on device (540p, ≤120s), show it immediately, upload in the background.
    func handlePickedVideo(_ item: PhotosPickerItem) async {
        await MainActor.run { isProcessing = true }
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                await MainActor.run { isProcessing = false; pickedItem = nil }
                return
            }
            let out = try await VideoCompressor.compress(movie.url)
            let msgId = UUID().uuidString
            await MainActor.run {
                localVideos[msgId] = out.url
                if let t = out.thumbnail { thumbs[msgId] = t }
                thread.messages.append(ChatMessage(id: msgId, text: "", fromTrainer: false, timestamp: Date()))
                isProcessing = false
                pickedItem = nil
            }
            if store.isLive {
                if let key = try? await APIClient.shared.uploadChatVideo(threadId: thread.id, fileURL: out.url) {
                    await MainActor.run {
                        if let idx = thread.messages.firstIndex(where: { $0.id == msgId }) {
                            thread.messages[idx].videoKey = key
                        }
                    }
                }
            }
        } catch {
            await MainActor.run { isProcessing = false; pickedItem = nil }
        }
    }

    func hasVideo(_ m: ChatMessage) -> Bool {
        localVideos[m.id] != nil || m.videoKey != nil
    }

    func startsNewDay(_ prev: ChatMessage?, _ m: ChatMessage) -> Bool {
        guard let prev else { return true }
        return !Calendar.current.isDate(prev.timestamp, inSameDayAs: m.timestamp)
    }

    /// Same sender, same day, within five minutes: the bubbles read as one run.
    func grouped(_ a: ChatMessage?, _ b: ChatMessage?) -> Bool {
        guard let a, let b, a.fromTrainer == b.fromTrainer,
              Calendar.current.isDate(a.timestamp, inSameDayAs: b.timestamp) else { return false }
        return abs(b.timestamp.timeIntervalSince(a.timestamp)) < 5 * 60
    }

    func daySeparator(_ d: Date) -> some View {
        let cal = Calendar.current
        let label: String = cal.isDateInToday(d) ? "TODAY"
            : cal.isDateInYesterday(d) ? "YESTERDAY"
            : d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        return HStack(spacing: 10) {
            Rectangle().fill(Brand.line).frame(height: 1)
            Text(label).font(BrandFont.body(10, .heavy)).tracking(1.5).foregroundColor(Brand.mute).fixedSize()
            Rectangle().fill(Brand.line).frame(height: 1)
        }
        .padding(.top, 14).padding(.bottom, 2)
    }

    /// Corners tighten on the sender's side where a bubble joins the one before or after it.
    func bubbleShape(_ m: ChatMessage, joinsPrevious: Bool, joinsNext: Bool) -> UnevenRoundedRectangle {
        let r: CGFloat = 18, j: CGFloat = 6
        if m.fromTrainer {
            return UnevenRoundedRectangle(topLeadingRadius: joinsPrevious ? j : r, bottomLeadingRadius: joinsNext ? j : r,
                                          bottomTrailingRadius: r, topTrailingRadius: r)
        } else {
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                          bottomTrailingRadius: joinsNext ? j : r, topTrailingRadius: joinsPrevious ? j : r)
        }
    }

    func bubble(_ m: ChatMessage, joinsPrevious: Bool, joinsNext: Bool) -> some View {
        let shape = bubbleShape(m, joinsPrevious: joinsPrevious, joinsNext: joinsNext)
        return HStack {
            if !m.fromTrainer { Spacer(minLength: 40) }
            VStack(alignment: m.fromTrainer ? .leading : .trailing, spacing: 4) {
                if hasVideo(m) { videoThumb(m) }
                if !m.text.isEmpty {
                    Text(m.text)
                        .font(BrandFont.body(15))
                        .foregroundColor(m.fromTrainer ? Brand.text : Brand.onVolt)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(m.fromTrainer ? Brand.black : Brand.volt)
                        .clipShape(shape)
                        .overlay(m.fromTrainer ? shape.stroke(Brand.line, lineWidth: 1) : nil)
                }
                // One time per run of bubbles; the day separator carries the date.
                if !joinsNext {
                    Text(m.timestamp.formatted(.dateTime.hour().minute()))
                        .font(BrandFont.body(10)).foregroundColor(Brand.mute).padding(.horizontal, 4)
                }
            }
            if m.fromTrainer { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    func videoThumb(_ m: ChatMessage) -> some View {
        Button {
            if let url = localVideos[m.id] {
                playing = IdentifiableURL(url: url)                 // played this session — instant
            } else if let key = m.videoKey {
                Task {                                              // older clip — fetch a signed URL
                    if let url = try? await APIClient.shared.chatVideoURL(threadId: thread.id, key: key) {
                        await MainActor.run { playing = IdentifiableURL(url: url) }
                    }
                }
            }
        } label: {
            ZStack {
                if let img = thumbs[m.id] {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Brand.black)
                    Image(systemName: "video.fill").foregroundColor(Brand.mute).font(.system(size: 26))
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46)).foregroundColor(Brand.text.opacity(0.92)).shadow(radius: 6)
            }
            .frame(width: 210, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }

    func time(_ d: Date) -> String { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f.string(from: d) }
}

// Wrapper so a plain URL can drive a .sheet(item:)
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

// Lets PhotosPicker hand us a real file URL for the chosen video.
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked_\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

struct NewChatSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var topic = ""
    @State private var category: ChatCategory = .general
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start a new conversation. Give it a topic so it stays organized.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                VStack(alignment: .leading, spacing: 8) {
                    Text("TOPIC").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    TextField("", text: $topic, prompt: Text("e.g. Deadlift form").foregroundColor(Brand.mute))
                        .foregroundColor(Brand.text).padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.black))   // fill inside the corners
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("CATEGORY").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    DSCarousel(options: ChatCategory.allCases.map { DSCarousel<ChatCategory>.Option(id: $0, label: $0.rawValue) },
                               selection: $category, likely: .general, itemWidth: 116, accessibilityName: "Category")
                }
                VoltButton(title: "Start Chat") {
                    let trimmed = topic.trimmingCharacters(in: .whitespaces)
                    let thread = ChatThread(id: UUID().uuidString,
                                            topic: trimmed.isEmpty ? "New Conversation" : trimmed,
                                            category: category,
                                            messages: [],
                                            lastActivity: Date())
                    store.chats.insert(thread, at: 0)
                    dismiss()
                }
                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New Chat")
            .tapToDismissKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) }
            }
        }
    }
}
