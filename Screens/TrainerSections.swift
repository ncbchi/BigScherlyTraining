import SwiftUI

// MARK: - Today (landing / triage summary)
// Opens the app on "who needs me right now" rather than a raw client list.

struct TrainerTodayView: View {
    @EnvironmentObject var store: AppStore

    private var needsAttention: [RosterItem] { store.roster.filter { $0.needsAttention } }
    private var drifting: [RosterItem] { store.roster.filter { $0.isDrifting } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: greeting)
                Text("Today").font(BrandFont.display(44)).foregroundColor(.white)

                // Summary counters
                HStack(spacing: 10) {
                    summaryTile("\(store.totalUnread)", "UNREAD", .chat)
                    summaryTile("\(store.pendingCheckInCount)", "CHECK-INS", .checkins)
                    summaryTile("\(drifting.count)", "DRIFTING", .clients)
                }

                if needsAttention.isEmpty && drifting.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40)).foregroundColor(Brand.volt)
                        Text("All caught up.")
                            .font(BrandFont.body(16, .bold)).foregroundColor(.white)
                        Text("Nobody's waiting on you right now.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                if !needsAttention.isEmpty {
                    Text("NEEDS YOU").font(BrandFont.body(11, .bold)).tracking(1.5)
                        .foregroundColor(Brand.volt).padding(.top, 6)
                    ForEach(needsAttention) { c in
                        Button { store.selectedClient = c } label: { RosterRow(item: c) }
                    }
                }

                if !drifting.isEmpty {
                    Text("GOING QUIET").font(BrandFont.body(11, .bold)).tracking(1.5)
                        .foregroundColor(.orange).padding(.top, 10)
                    ForEach(drifting) { c in
                        Button { store.selectedClient = c } label: { RosterRow(item: c) }
                    }
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
        .sheet(item: $store.selectedClient) { c in TrainerClientView(client: c) }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 0..<12: return "Good Morning"; case 12..<17: return "Good Afternoon"; default: return "Good Evening" }
    }

    private func summaryTile(_ value: String, _ label: String, _ dest: TrainerTab) -> some View {
        Button { store.trainerTab = dest } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(BrandFont.display(30)).foregroundColor(Brand.volt)
                Text(label).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Brand.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }
}

// MARK: - Chat section (client list -> thread)

struct TrainerChatSection: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var expanded: String? = nil          // clientId whose drawer is open
    @State private var threadsByClient: [String: [APIChatThread]] = [:]
    @State private var loadingClient: String? = nil
    @State private var newThreadClient: RosterItem? = nil

    private var clients: [RosterItem] {
        let base = store.roster.sorted { $0.unreadMessages > $1.unreadMessages }
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Messages")
                Text("Chat").font(BrandFont.display(44)).foregroundColor(.white)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.mute).font(.system(size: 14))
                    TextField("Search clients…", text: $query)
                        .font(BrandFont.body(14)).foregroundColor(.white)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                ForEach(clients) { c in
                    VStack(spacing: 0) {
                        // Client header — tapping expands the drawer beneath it.
                        Button { toggle(c) } label: {
                            HStack(spacing: 12) {
                                Rectangle().fill(c.unreadMessages > 0 ? Brand.volt : Brand.line).frame(width: 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name).font(BrandFont.body(16, .bold)).foregroundColor(.white)
                                    Text(c.unreadMessages > 0 ? "\(c.unreadMessages) unread" : "Tap to view threads")
                                        .font(BrandFont.body(12))
                                        .foregroundColor(c.unreadMessages > 0 ? Brand.volt : Brand.mute)
                                }
                                Spacer()
                                if c.unreadMessages > 0 {
                                    Text("\(c.unreadMessages)").font(BrandFont.body(11, .bold))
                                        .foregroundColor(Brand.black)
                                        .frame(minWidth: 20, minHeight: 20)
                                        .background(Circle().fill(Brand.volt))
                                }
                                Image(systemName: expanded == c.id ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 12)).foregroundColor(Brand.mute)
                            }
                            .padding(.vertical, 14).padding(.trailing, 14)
                        }

                        // The drawer: this client's threads, by topic + category.
                        if expanded == c.id {
                            VStack(spacing: 8) {
                                Rectangle().fill(Brand.line).frame(height: 1)
                                    .padding(.bottom, 2)

                                if loadingClient == c.id {
                                    ProgressView().tint(Brand.volt).padding(.vertical, 12)
                                } else {
                                    let threads = threadsByClient[c.id] ?? []
                                    if threads.isEmpty {
                                        Text("No threads yet.")
                                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 10).padding(.leading, 15)
                                    } else {
                                        ForEach(threads, id: \.id) { t in
                                            NavigationLink {
                                                TrainerChatThreadScreen(
                                                    clientId: c.id, clientName: c.name,
                                                    threadId: t.id, categoryLabel: t.category)
                                            } label: {
                                                ThreadRow(thread: t)
                                            }
                                        }
                                    }

                                    // Start a fresh thread with this client.
                                    Button {
                                        newThreadClient = c
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 16))
                                            Text("New thread").font(BrandFont.body(13, .bold))
                                        }
                                        .foregroundColor(Brand.volt)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 10).padding(.leading, 15)
                                    }
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(
                        expanded == c.id ? Brand.volt.opacity(0.5) : Brand.line, lineWidth: 1))
                }

                if clients.isEmpty {
                    Text(store.roster.isEmpty ? "No clients yet." : "No clients match.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
        .sheet(item: $newThreadClient) { client in
            NewTrainerThreadSheet(client: client) { created in
                // Refresh this client's drawer so the new thread shows immediately.
                Task {
                    let t = (try? await APIClient.shared.trainerChats(clientId: client.id)) ?? []
                    await MainActor.run {
                        threadsByClient[client.id] = t
                        expanded = client.id
                    }
                }
            }
        }
    }

    private func toggle(_ c: RosterItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if expanded == c.id { expanded = nil; return }
            expanded = c.id
        }
        // Load this client's threads once, on first open.
        if threadsByClient[c.id] == nil {
            loadingClient = c.id
            Task {
                let t = (try? await APIClient.shared.trainerChats(clientId: c.id)) ?? []
                await MainActor.run {
                    threadsByClient[c.id] = t
                    if loadingClient == c.id { loadingClient = nil }
                }
            }
        }
    }
}

// One thread row inside the drawer: topic + category chip + unread dot.
// Trainer starts a new titled thread with a client. Creates the thread server-side,
// then reports the created thread back so the drawer can refresh.
struct NewTrainerThreadSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: RosterItem
    var onCreated: (APIChatThread) -> Void

    @State private var topic = ""
    @State private var category: ChatCategory = .general
    @State private var creating = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start a new thread with \(client.name). Give it a topic so it stays organized.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOPIC").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    TextField("", text: $topic, prompt: Text("e.g. Deload week plan").foregroundColor(Brand.mute))
                        .foregroundColor(.white).padding(14).background(Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
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

                if failed {
                    Text("Couldn't create the thread. Try again.")
                        .font(BrandFont.body(12)).foregroundColor(.orange)
                }

                Button {
                    create()
                } label: {
                    HStack {
                        if creating { ProgressView().tint(Brand.black) }
                        Text("Start thread").font(BrandFont.body(15, .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
                }
                .disabled(creating)

                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New Thread")
            .navigationBarTitleDisplayMode(.inline)
            .tapToDismissKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.volt) }
            }
            .keyboardDoneButton()
        }
    }

    private func create() {
        creating = true; failed = false
        let t = topic.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let thread = try await APIClient.shared.trainerCreateChat(
                    clientId: client.id,
                    topic: t.isEmpty ? "New conversation" : t,
                    category: category.rawValue)
                await MainActor.run {
                    creating = false
                    onCreated(thread)
                    dismiss()
                }
            } catch {
                await MainActor.run { creating = false; failed = true }
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: APIChatThread
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.topic.isEmpty ? "Conversation" : thread.topic)
                    .font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                    .lineLimit(1)
                Text(thread.category.uppercased())
                    .font(BrandFont.body(9, .bold)).tracking(1)
                    .foregroundColor(Brand.volt)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Brand.volt, lineWidth: 1))
            }
            Spacer()
            if thread.unread > 0 {
                Text("\(thread.unread)").font(BrandFont.body(10, .bold))
                    .foregroundColor(Brand.black)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Brand.volt))
            }
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(Brand.mute)
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(Brand.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }
}

// A pushed screen wrapping the chat thread with its own nav bar + title.
struct TrainerChatThreadScreen: View {
    let clientId: String
    let clientName: String
    var threadId: String? = nil
    var categoryLabel: String? = nil
    var body: some View {
        TrainerChatView(clientId: clientId, clientName: clientName,
                        threadId: threadId, categoryLabel: categoryLabel)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(clientName)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Check-in queue (all pending, across the roster)

struct CheckInQueueView: View {
    @EnvironmentObject var store: AppStore
    @State private var openFor: QueuedCheckIn?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Review Queue")
                Text("Check-Ins").font(BrandFont.display(44)).foregroundColor(.white)

                if store.checkInQueue.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 38)).foregroundColor(Brand.line)
                        Text("Queue's empty").font(BrandFont.body(16, .bold)).foregroundColor(.white)
                        Text("No check-ins waiting for a response.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    Text("\(store.checkInQueue.count) waiting")
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.volt)

                    ForEach(store.checkInQueue) { q in
                        Button { openFor = q } label: {
                            HStack(spacing: 12) {
                                Rectangle().fill(Brand.volt).frame(width: 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(q.clientName).font(BrandFont.body(16, .bold)).foregroundColor(.white)
                                    Text(q.checkIn.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(Brand.mute)
                            }
                            .padding(.vertical, 14).padding(.trailing, 14)
                            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
        .sheet(item: $openFor) { q in
            QueuedCheckInSheet(queued: q)
        }
    }
}

// Respond to a single queued check-in without leaving the queue.
struct QueuedCheckInSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let queued: QueuedCheckIn
    @State private var response = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(queued.clientName).font(BrandFont.display(30)).foregroundColor(.white)
                    Text(queued.checkIn.date.formatted(date: .abbreviated, time: .omitted))
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)

                    ForEach(queued.checkIn.fields, id: \.id) { f in
                        HStack {
                            Text(f.cleanLabel).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            Spacer()
                            Text(f.value).font(BrandFont.body(13, .bold)).foregroundColor(.white)
                        }
                        .padding(.vertical, 4)
                    }

                    Text("YOUR RESPONSE").font(BrandFont.body(10, .bold)).tracking(1.4)
                        .foregroundColor(Brand.volt).padding(.top, 6)
                    TextEditor(text: $response)
                        .font(BrandFont.body(15)).foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(height: 120)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                    Button {
                        send()
                    } label: {
                        HStack {
                            if sending { ProgressView().tint(Brand.black) }
                            Text("Send response").font(BrandFont.body(15, .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
                    }
                    .disabled(response.isEmpty || sending)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .tapToDismissKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(Brand.volt)
                }
            }
            .keyboardDoneButton()
        }
    }

    private func send() {
        sending = true
        Task {
            try? await APIClient.shared.trainerRespondCheckIn(checkInId: queued.checkIn.id, response: response)
            store.loadRoster()
            await MainActor.run { sending = false; dismiss() }
        }
    }
}

// MARK: - Insights (roll-up stats)

struct TrainerInsightsView: View {
    @EnvironmentObject var store: AppStore
    private var i: RosterInsights { store.insights }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "State of the Business")
                Text("Insights").font(BrandFont.display(44)).foregroundColor(.white)

                let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: cols, spacing: 10) {
                    stat("\(i.totalClients)", "ACTIVE CLIENTS")
                    stat("\(i.workoutsThisWeek)", "WORKOUTS THIS WEEK")
                    stat("\(i.needingAttention)", "NEED ATTENTION", i.needingAttention > 0 ? Brand.volt : nil)
                    stat("\(i.drifting)", "DRIFTING", i.drifting > 0 ? .orange : nil)
                    stat("\(i.awardsThisWeek)", "AWARDS THIS WEEK")
                    stat(i.avgDaysSinceTrained > 90 ? "—" : "\(i.avgDaysSinceTrained)d", "AVG SINCE TRAINED")
                }

                Text("Insights update from your roster each time it loads. Pull to refresh on Clients or Today.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute).padding(.top, 6)
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
    }

    private func stat(_ value: String, _ label: String, _ color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(BrandFont.display(34)).foregroundColor(color ?? Brand.volt)
            Text(label).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: - Announcements (one post to all clients)

struct AnnouncementsComposerView: View {
    @EnvironmentObject var store: AppStore
    @State private var title = ""
    @State private var messageBody = ""
    @State private var posting = false
    @State private var posted = false
    @State private var existing: [APIAnnouncement] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "From Coach")
                Text("Announcements").font(BrandFont.display(44)).foregroundColor(.white)
                Text("Post an update every client sees in their Announcements tab — gym news, program drops, schedule changes.")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)

                // Composer
                Text("TITLE").font(BrandFont.body(10, .bold)).tracking(1.4)
                    .foregroundColor(Brand.volt).padding(.top, 8)
                TextField("", text: $title, prompt: Text("New PR Challenge Starts Monday").foregroundColor(Brand.mute))
                    .font(BrandFont.body(16, .semibold)).foregroundColor(.white)
                    .padding(12)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                Text("MESSAGE").font(BrandFont.body(10, .bold)).tracking(1.4)
                    .foregroundColor(Brand.volt).padding(.top, 4)
                TextEditor(text: $messageBody)
                    .font(BrandFont.body(15)).foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(10).frame(height: 120)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                if posted {
                    Text("Posted to all clients. 👑")
                        .font(BrandFont.body(13, .bold)).foregroundColor(Brand.volt)
                }

                Button { post() } label: {
                    HStack {
                        if posting { ProgressView().tint(Brand.black) }
                        Text("Post announcement").font(BrandFont.body(15, .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
                }
                .disabled(title.isEmpty || messageBody.isEmpty || posting)
                .opacity(title.isEmpty || messageBody.isEmpty ? 0.5 : 1)

                // Existing announcements, newest first, with delete.
                if !existing.isEmpty || loading {
                    Text("POSTED").font(BrandFont.body(10, .bold)).tracking(1.4)
                        .foregroundColor(Brand.mute).padding(.top, 16)
                }
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 8)
                } else {
                    ForEach(existing, id: \.id) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(a.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(BrandFont.body(11, .bold)).foregroundColor(Brand.volt)
                                Spacer()
                                Button { remove(a) } label: {
                                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(Brand.mute)
                                }
                            }
                            Text(a.title).font(BrandFont.body(16, .bold)).foregroundColor(.white)
                            Text(a.body).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    }
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .task { await loadExisting() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }

    private func loadExisting() async {
        loading = true
        existing = ((try? await APIClient.shared.adminAnnouncements()) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
        loading = false
    }

    private func post() {
        posting = true; posted = false
        let t = title, b = messageBody
        Task {
            try? await APIClient.shared.createAnnouncement(title: t, body: b)
            await loadExisting()
            await MainActor.run {
                posting = false; posted = true
                title = ""; messageBody = ""
            }
        }
    }

    private func remove(_ a: APIAnnouncement) {
        Task {
            try? await APIClient.shared.deleteAnnouncement(id: a.id)
            await loadExisting()
        }
    }
}
