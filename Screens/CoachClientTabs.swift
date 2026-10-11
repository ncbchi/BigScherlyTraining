import SwiftUI

// MARK: - This client's conversations

struct CoachClientThreads: View {
    @ObservedObject private var data = CoachData.shared
    let client: RosterItem
    @State private var newThread = false
    @State private var filter = "All"

    var body: some View {
        let threads = (data.threads[client.id] ?? [])
            .filter { filter == "All" || $0.category == filter }
            .sorted { $0.lastActivity > $1.lastActivity }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Same category carousel as the client's Chat screen.
                DSCarousel(options: [DSCarousel<String>.Option(id: "All", label: "All")]
                                    + ChatCategory.allCases.map { DSCarousel<String>.Option(id: $0.rawValue, label: $0.rawValue) },
                           selection: $filter, likely: "All", itemWidth: 116,
                           accessibilityName: "Show conversations")
                if data.threads[client.id] == nil {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if threads.isEmpty {
                    Text((data.threads[client.id] ?? []).isEmpty ? "No conversations yet." : "Nothing in \(filter) yet.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }
                ForEach(threads, id: \.id) { t in
                    NavigationLink {
                        TrainerChatThreadScreen(clientId: client.id, clientName: client.name, threadId: t.id, categoryLabel: t.category)
                    } label: {
                        DSListRow(title: t.topic.isEmpty ? "Conversation" : t.topic,
                                  subtitle: "\(t.category) · \(t.preview)",
                                  trailing: t.unread > 0 ? "\(t.unread)" : nil,
                                  icon: t.unread > 0 ? "bubble.left.fill" : "bubble.left")
                    }
                    .buttonStyle(PressableStyle())
                }
                Button { newThread = true } label: {
                    DSListRow(title: "New conversation", subtitle: "Give it a topic so it stays organized", icon: "plus.bubble.fill")
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .onAppear { Task { await data.loadThreads(client.id, force: true) } }
        .sheet(isPresented: $newThread) {
            NewTrainerThreadSheet(client: client) { _ in Task { await data.loadThreads(client.id, force: true) } }
        }
    }
}
