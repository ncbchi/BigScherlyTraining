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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Talk To Coach")
                        Text("Chat").font(BrandFont.display(48)).foregroundColor(.white)
                    }
                    Spacer()
                    Button { showNew = true } label: {
                        Image(systemName: "square.and.pencil").foregroundColor(Brand.black)
                            .padding(12).background(Brand.volt).clipShape(Capsule())
                    }
                }

                // Category filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", filter == nil) { filter = nil }
                        ForEach(ChatCategory.allCases, id: \.self) { cat in
                            chip(cat.rawValue, filter == cat) { filter = cat }
                        }
                    }
                }

                ForEach(filtered) { t in
                    Button { selected = t } label: { threadRow(t) }
                }

                if filtered.isEmpty {
                    EmptyState(icon: "bubble.left.and.bubble.right",
                               title: "No conversations yet",
                               message: "Tap the compose button to start a chat with your coach.")
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .sheet(item: $selected) { t in ChatThreadView(thread: t).environmentObject(store) }
        .sheet(isPresented: $showNew) { NewChatSheet().environmentObject(store) }
    }

    func chip(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased()).font(BrandFont.body(11, .bold)).tracking(0.5)
                .foregroundColor(on ? Brand.black : Brand.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Brand.volt : Brand.black).clipShape(Capsule())
                .overlay(Capsule().stroke(on ? Brand.volt : Brand.line, lineWidth: 1))
        }
    }
    func threadRow(_ t: ChatThread) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(t.topic).font(BrandFont.display(20)).foregroundColor(.white)
                    Text(t.category.rawValue.uppercased()).font(BrandFont.body(9, .bold)).tracking(0.5)
                        .foregroundColor(Brand.volt).padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(Brand.volt.opacity(0.5), lineWidth: 1))
                }
                Text(t.preview).font(BrandFont.body(13)).foregroundColor(Brand.mute).lineLimit(1)
            }
            Spacer()
            if t.unread > 0 {
                Text("\(t.unread)").font(BrandFont.body(11, .bold)).foregroundColor(Brand.black)
                    .frame(width: 22, height: 22).background(Circle().fill(Brand.volt))
            }
        }
        .card()
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
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(thread.messages) { m in
                            bubble(m)
                        }
                    }
                    .padding(20)
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
                        Image(systemName: "video.badge.plus").foregroundColor(Brand.volt).font(.system(size: 22))
                    }
                    TextField("", text: $draft, prompt: Text("Message coach…").foregroundColor(Brand.mute))
                        .foregroundColor(.white).padding(12).background(Brand.black)
                        .overlay(Capsule().stroke(Brand.line, lineWidth: 1)).clipShape(Capsule())
                    Button {
                        guard !draft.isEmpty else { return }
                        let text = draft
                        thread.messages.append(ChatMessage(id: UUID().uuidString, text: text, fromTrainer: false, timestamp: Date()))
                        draft = ""
                        if store.isLive {
                            Task { try? await APIClient.shared.sendMessage(threadId: thread.id, text: text) }
                        }
                    } label: {
                        Image(systemName: "arrow.up").foregroundColor(Brand.black).font(.system(size: 18, weight: .bold))
                            .frame(width: 40, height: 40).background(Circle().fill(Brand.volt))
                    }
                }
                .padding(14).background(Brand.bg)
                .overlay(Rectangle().fill(Brand.line).frame(height: 1), alignment: .top)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(thread.topic)
            .navigationBarTitleDisplayMode(.inline)
            .tapToDismissKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.volt) }
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

    func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if !m.fromTrainer { Spacer(minLength: 40) }
            VStack(alignment: m.fromTrainer ? .leading : .trailing, spacing: 4) {
                if hasVideo(m) { videoThumb(m) }
                if !m.text.isEmpty {
                    Text(m.text)
                        .font(BrandFont.body(15))
                        .foregroundColor(m.fromTrainer ? .white : Brand.black)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(m.fromTrainer ? Brand.black : Brand.volt)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(m.fromTrainer ? RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1) : nil)
                }
                Text(time(m.timestamp)).font(BrandFont.body(10)).foregroundColor(Brand.mute)
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
                    .font(.system(size: 46)).foregroundColor(.white.opacity(0.92)).shadow(radius: 6)
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
                    Text("TOPIC").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    TextField("", text: $topic, prompt: Text("e.g. Deadlift form").foregroundColor(Brand.mute))
                        .foregroundColor(.white).padding(14).background(Brand.black)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("CATEGORY").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ChatCategory.allCases, id: \.self) { c in
                                Button { category = c } label: {
                                    Text(c.rawValue.uppercased()).font(BrandFont.body(11, .bold))
                                        .foregroundColor(category == c ? Brand.black : Brand.white)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(category == c ? Brand.volt : Brand.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                                }
                            }
                        }
                    }
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
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.volt) }
            }
        }
    }
}
