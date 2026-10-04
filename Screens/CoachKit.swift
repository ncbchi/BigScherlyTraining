import SwiftUI
import Combine   // @Published / ObservableObject (the project requires direct imports)

// MARK: - Coach data
// The coach app is for triage and replies; reviewing client data happens in the web
// console. This only caches what the phone screens need: each client's conversations
// (Chat) and check-ins (comparing a check-in with the one before it). Cleared on logout.

@MainActor
final class CoachData: ObservableObject {
    static let shared = CoachData()

    @Published private(set) var threads: [String: [APIChatThread]] = [:]
    @Published private(set) var checkIns: [String: [APICheckIn]] = [:]

    func loadThreads(_ clientId: String, force: Bool = false) async {
        if !force, threads[clientId] != nil { return }
        if let t = try? await APIClient.shared.trainerChats(clientId: clientId) { threads[clientId] = t }
    }

    func loadAllThreads(_ roster: [RosterItem], force: Bool = false) async {
        for c in roster { await loadThreads(c.id, force: force) }
    }

    func loadCheckIns(_ clientId: String, force: Bool = false) async {
        if !force, checkIns[clientId] != nil { return }
        if let c = try? await APIClient.shared.trainerCheckIns(clientId: clientId) {
            checkIns[clientId] = c.sorted { $0.date > $1.date }
        }
    }

    func reset() { threads = [:]; checkIns = [:] }
}

// MARK: - Wins (awards clients earned, from the server)

struct CoachWin: Identifiable {
    var id: String
    var clientId: String
    var clientName: String
    var title: String
    var detail: String
    var icon: String
    var date: Date
}

enum CoachWins {
    static func build(awards: [RosterAward], days: Int = 30) -> [CoachWin] {
        let since = Calendar.training.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return awards.filter { $0.earnedAt >= since }.map { a in
            CoachWin(id: "aw|\(a.clientId)|\(a.kind)", clientId: a.clientId, clientName: a.clientName,
                     title: a.title, detail: a.blurb, icon: a.icon, date: a.earnedAt)
        }
        .sorted { $0.date > $1.date }
    }
}

/// Which wins the coach has already congratulated (this phone).
@MainActor
final class CongratsLog: ObservableObject {
    static let shared = CongratsLog()
    @Published private(set) var done: Set<String>
    private let key = "bst_coach_congratulated"
    private init() { done = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    func mark(_ id: String) { done.insert(id); UserDefaults.standard.set(Array(done), forKey: key) }
    func reset() { done = []; UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - Messaging

enum CoachMessenger {
    /// Send to the client's most recent conversation, or start one if they have none.
    static func send(_ text: String, to clientId: String, newTopic: String = "From your coach") async throws {
        let threads = try await APIClient.shared.trainerChats(clientId: clientId)
        let thread: APIChatThread
        if let t = threads.max(by: { $0.lastActivity < $1.lastActivity }) { thread = t }
        else { thread = try await APIClient.shared.trainerCreateChat(clientId: clientId, topic: newTopic, category: ChatCategory.general.rawValue) }
        try await APIClient.shared.trainerSendMessage(threadId: thread.id, text: text)
    }
}

extension String {
    var firstName: String { split(separator: " ").first.map(String.init) ?? self }
    var initials: String {
        let parts = split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

// MARK: - Shared coach components

struct CoachAvatar: View {
    let name: String
    var size: CGFloat = 44
    var highlighted = false
    var body: some View {
        Text(name.initials)
            .font(BrandFont.display(size * 0.42))
            .foregroundColor(highlighted ? Brand.onVolt : Brand.text)
            .frame(width: size, height: size)
            .background(Circle().fill(highlighted ? Brand.volt : Brand.text.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

struct CoachSearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Brand.mute).font(.system(size: 14))
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Brand.mute))
                .font(BrandFont.body(14)).foregroundColor(Brand.text).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Brand.mute) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }
}

/// A row of filter chips. `selected` matches by label.
struct CoachFilterChips: View {
    let options: [(label: String, color: Color)]
    @Binding var selected: String
    var body: some View {
        DSCarousel(options: options.map { DSCarousel<String>.Option(id: $0.label, label: $0.label, tint: $0.color) },
                   selection: $selected, likely: options.first?.label, itemWidth: 132,
                   accessibilityName: "Filter")
    }
}

/// One-tap starter phrases that fill (not send) the message box.
struct QuickReplies: View {
    let options: [String]
    let pick: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { o in
                    Button { pick(o) } label: {
                        Text(o).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Small action pill used on coach rows (Reply / Review / Nudge…).
struct CoachActionPill: View {
    let title: String
    var icon: String? = nil
    var primary = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(BrandFont.body(12, .heavy))
            }
            .foregroundColor(primary ? Brand.onVolt : Brand.voltText)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(Capsule().fill(primary ? Brand.volt : Color.clear))
            .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Compose-and-send sheet used for congrats, nudges and comments.
struct CoachComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let clientId: String
    let starters: [String]
    var initial: String = ""
    var onSent: () -> Void = {}

    @State private var text = ""
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(subtitle.uppercased()).font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                    QuickReplies(options: starters) { text = $0 }
                    TextEditor(text: $text)
                        .font(BrandFont.body(15)).foregroundColor(Brand.text)
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 130)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.voltLine, lineWidth: 1.5))
                    Text("Sends as a chat message.").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    if failed {
                        Text("Couldn't send. Check your connection and try again.").font(BrandFont.body(12)).foregroundColor(.orange)
                    }
                    Button { send() } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(Brand.black) }
                            Label("Send", systemImage: "arrow.up")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            .onAppear { if text.isEmpty { text = initial } }
            .keyboardDoneButton()
        }
    }

    private func send() {
        sending = true; failed = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await CoachMessenger.send(t, to: clientId)
                await MainActor.run {
                    sending = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSent(); dismiss()
                }
            } catch {
                await MainActor.run { sending = false; failed = true }
            }
        }
    }
}

/// Identifiable wrapper for compose sheets.
struct CoachCompose: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let clientId: String
    let starters: [String]
    var initial: String = ""
    var winId: String? = nil
}
