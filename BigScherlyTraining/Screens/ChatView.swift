import SwiftUI

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
                            .padding(12).background(Brand.volt)
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
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .sheet(item: $selected) { t in ChatThreadView(thread: t) }
        .sheet(isPresented: $showNew) { NewChatSheet() }
    }

    func chip(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased()).font(BrandFont.body(11, .bold)).tracking(0.5)
                .foregroundColor(on ? Brand.black : Brand.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Brand.volt : Brand.black)
                .overlay(Rectangle().stroke(on ? Brand.volt : Brand.line, lineWidth: 1))
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
    @Environment(\.dismiss) var dismiss
    @State var thread: ChatThread
    @State private var draft = ""

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
                // Composer
                HStack(spacing: 12) {
                    Button {} label: { Image(systemName: "photo").foregroundColor(Brand.volt).font(.system(size: 22)) }
                    TextField("", text: $draft, prompt: Text("Message coach…").foregroundColor(Brand.mute))
                        .foregroundColor(.white).padding(12).background(Brand.black)
                        .overlay(Capsule().stroke(Brand.line, lineWidth: 1)).clipShape(Capsule())
                    Button {
                        guard !draft.isEmpty else { return }
                        thread.messages.append(ChatMessage(id: UUID().uuidString, text: draft, fromTrainer: false, timestamp: Date()))
                        draft = ""
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }

    func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if !m.fromTrainer { Spacer(minLength: 40) }
            VStack(alignment: m.fromTrainer ? .leading : .trailing, spacing: 4) {
                Text(m.text)
                    .font(BrandFont.body(15))
                    .foregroundColor(m.fromTrainer ? .white : Brand.black)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(m.fromTrainer ? Brand.black : Brand.volt)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(m.fromTrainer ? RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1) : nil)
                Text(time(m.timestamp)).font(BrandFont.body(10)).foregroundColor(Brand.mute)
            }
            if m.fromTrainer { Spacer(minLength: 40) }
        }
    }
    func time(_ d: Date) -> String { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f.string(from: d) }
}

struct NewChatSheet: View {
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
                        .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
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
                                        .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                VoltButton(title: "Start Chat") { dismiss() }
                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New Chat")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }
}
