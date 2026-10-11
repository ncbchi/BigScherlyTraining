import SwiftUI

// MARK: - Chat (every conversation, across the roster)

struct TrainerChatSection: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = CoachData.shared
    @State private var query = ""
    @State private var filter = "All"
    @State private var pickClient = false
    @State private var newThreadClient: RosterItem? = nil
    @State private var loaded = false

    private struct Item: Identifiable {
        let client: RosterItem
        let thread: APIChatThread
        var id: String { thread.id }
    }

    private var items: [Item] {
        store.roster.flatMap { c in (data.threads[c.id] ?? []).map { Item(client: c, thread: $0) } }
            .sorted { ($0.thread.unread > 0 ? 0 : 1, $1.thread.lastActivity) < ($1.thread.unread > 0 ? 0 : 1, $0.thread.lastActivity) }
    }

    var body: some View {
        let all = items
        let unread = all.filter { $0.thread.unread > 0 }
        let shown = all.filter { i in
            let f = filter == "All" || i.thread.category == filter
            let q = query.isEmpty || i.client.name.localizedCaseInsensitiveContains(query)
                || i.thread.topic.localizedCaseInsensitiveContains(query) || i.thread.preview.localizedCaseInsensitiveContains(query)
            return f && q
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DSScreenHeader(eyebrow: "Messages", title: "Chat",
                               subtitle: unread.isEmpty ? "All caught up · newest first" : "\(unread.count) unread · newest first")
                CoachSearchField(prompt: "Search clients or messages", text: $query)
                // Same category carousel as the client's Chat: All in the middle,
                // the client app's categories around it. Unread threads sort first.
                DSCarousel(options: [DSCarousel<String>.Option(id: "All", label: "All")]
                                    + ChatCategory.allCases.map { DSCarousel<String>.Option(id: $0.rawValue, label: $0.rawValue) },
                           selection: $filter, likely: "All", itemWidth: 116,
                           accessibilityName: "Show conversations")

                if !loaded && all.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if shown.isEmpty {
                    Text(all.isEmpty ? "No conversations yet." : "Nothing here.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(shown) { i in
                    NavigationLink {
                        TrainerChatThreadScreen(clientId: i.client.id, clientName: i.client.name,
                                                threadId: i.thread.id, categoryLabel: i.thread.category)
                    } label: { row(i) }
                    .buttonStyle(PressableStyle())
                }

                Button { pickClient = true } label: {
                    DSListRow(title: "Start a conversation", subtitle: "Pick a client, topic and category", icon: "plus.bubble.fill")
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable {
            store.loadRoster()
            await data.loadAllThreads(store.roster, force: true)
        }
        // Reload on every appearance so unread counts are fresh after reading a thread.
        .onAppear { Task { await data.loadAllThreads(store.roster, force: true); loaded = true } }
        .onChange(of: store.roster.count) { _, _ in Task { await data.loadAllThreads(store.roster); loaded = true } }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
        .sheet(isPresented: $pickClient) {
            ClientPickerSheet { c in
                pickClient = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { newThreadClient = c }
            }
        }
        .sheet(item: $newThreadClient) { client in
            NewTrainerThreadSheet(client: client) { _ in
                Task { await data.loadThreads(client.id, force: true) }
            }
        }
    }

    private func row(_ i: Item) -> some View {
        let unread = i.thread.unread > 0
        return HStack(spacing: 12) {
            CoachAvatar(name: i.client.name, size: 44, highlighted: unread)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(i.client.name).font(BrandFont.body(15, unread ? .heavy : .bold)).foregroundColor(Brand.text).lineLimit(1)
                    Text(i.thread.category.uppercased()).font(BrandFont.body(8, .bold)).tracking(0.6)
                        .foregroundColor(Brand.voltText).padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
                }
                Text(i.thread.topic.isEmpty ? "Conversation" : i.thread.topic)
                    .font(BrandFont.body(12, .bold)).foregroundColor(unread ? Brand.text : Brand.mute).lineLimit(1)
                Text(i.thread.preview).font(BrandFont.body(12, unread ? .semibold : .regular))
                    .foregroundColor(unread ? Brand.text : Brand.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(i.thread.lastActivity.formatted(.relative(presentation: .named)))
                    .font(BrandFont.body(10)).foregroundColor(Brand.mute).lineLimit(1)
                if unread {
                    Text("\(i.thread.unread)").font(BrandFont.body(11, .bold)).foregroundColor(Brand.onVolt)
                        .frame(minWidth: 20, minHeight: 20).background(Circle().fill(Brand.volt))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(unread ? Brand.voltLine.opacity(0.5) : Brand.line, lineWidth: 1))
    }
}

/// Pick which client a new conversation is with.
struct ClientPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let pick: (RosterItem) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    CoachSearchField(prompt: "Search clients", text: $query)
                    ForEach(store.roster.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { c in
                        Button { pick(c) } label: {
                            HStack(spacing: 12) {
                                CoachAvatar(name: c.name, size: 38)
                                Text(c.name).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(Brand.mute)
                            }
                            .padding(12)
                            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(20)
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
        }
    }
}

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
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start a new thread with \(client.name). Give it a topic so it stays organized.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOPIC").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    TextField("", text: $topic, prompt: Text("e.g. Deload week plan").foregroundColor(Brand.mute))
                        .foregroundColor(Brand.text).padding(14).background(Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CATEGORY").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    DSCarousel(options: ChatCategory.allCases.map { DSCarousel<ChatCategory>.Option(id: $0, label: $0.rawValue) },
                               selection: $category, likely: .general, itemWidth: 116, accessibilityName: "Category")
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
                    .background(Brand.volt).foregroundColor(Brand.onVolt).clipShape(Capsule())
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
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) }
            }
            .keyboardDoneButton()
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
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
                DSScreenHeader(eyebrow: "Review queue", title: "Check-Ins",
                               subtitle: store.checkInQueue.isEmpty ? nil : "\(store.checkInQueue.count) waiting · oldest first")
                if store.checkInQueue.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(Brand.voltText)
                        Text("Queue's empty").font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
                        Text("No check-ins waiting for a response.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(store.checkInQueue.sorted { $0.checkIn.date < $1.checkIn.date }) { q in
                    Button { openFor = q } label: {
                        HStack(spacing: 12) {
                            CoachAvatar(name: q.clientName, size: 42, highlighted: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.clientName).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                                Text("Sent \(q.checkIn.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
                                     + (q.checkIn.photoIds.isEmpty ? "" : " · \(q.checkIn.photoIds.count) photo\(q.checkIn.photoIds.count == 1 ? "" : "s")"))
                                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                            Text("Review").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.onVolt)
                                .padding(.horizontal, 12).frame(minHeight: 34).background(Capsule().fill(Brand.volt))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable { store.loadRoster() }
        .sheet(item: $openFor) { q in
            CoachCheckInReview(clientId: q.clientId, clientName: q.clientName, checkIn: q.checkIn)
        }
    }
}

// MARK: - Check-in review (week over week, their words, photos, respond)

struct CoachCheckInReview: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = CoachData.shared
    let clientId: String
    let clientName: String
    let checkIn: APICheckIn

    @State private var response = ""
    @State private var sending = false
    @State private var failed = false
    @State private var photos: [APIPhoto] = []
    @State private var photoCategory: String? = nil
    @State private var photoComment: APIPhoto? = nil
    @State private var commentText = ""

    private var previous: APICheckIn? {
        (data.checkIns[clientId] ?? []).filter { $0.date < checkIn.date && $0.id != checkIn.id && $0.status != "draft" }
            .max { $0.date < $1.date }
    }

    private struct Delta: Identifiable {
        let id: String; let label: String; let now: Double; let prev: Double?; let unit: String; let better: Bool?
        let history: [Double]           // this metric across every submitted check-in, oldest first, ending here
    }

    private func deltas() -> [Delta] {
        // The full story per metric, not just now-vs-last-week: every submitted
        // check-in up to this one, in the order the form asks the questions.
        var past = (data.checkIns[clientId] ?? []).filter { $0.status != "draft" && $0.date <= checkIn.date }
        if !past.contains(where: { $0.id == checkIn.id }) { past.append(checkIn) }
        let ordered = past.sorted { $0.date < $1.date }
        return checkIn.fields.sorted { $0.fieldOrder < $1.fieldOrder }.compactMap { f in
            guard let v = Double(f.value) else { return nil }
            let q = CheckInSchema.questions.first { $0.label == f.cleanLabel }
            let prev = previous?.fields.first { $0.cleanLabel == f.cleanLabel }.flatMap { Double($0.value) }
            let isWeight = q?.id == "weight" || f.cleanLabel.lowercased().contains("weight")
            let conv: (Double) -> Double = { isWeight ? StatsUnits.weight($0) : $0 }
            let hist = ordered.compactMap { ci in
                ci.fields.first { $0.cleanLabel == f.cleanLabel }.flatMap { Double($0.value) }.map(conv)
            }
            return Delta(id: f.id, label: shortLabel(f.cleanLabel), now: conv(v),
                         prev: prev.map(conv),
                         unit: isWeight ? " \(StatsUnits.weightLabel)" : "",
                         better: isWeight ? nil : (q?.higherIsBetter ?? true),
                         history: hist)
        }
    }

    private func shortLabel(_ l: String) -> String {
        let map = ["Nutrition adherence": "NUTRITION", "Workout consistency": "CONSISTENCY", "Sleep quality": "SLEEP",
                   "Energy / fatigue": "ENERGY", "Stress load": "STRESS", "Soreness / recovery": "RECOVERY"]
        return (map[l] ?? l).uppercased()
    }

    var body: some View {
        let ds = deltas()
        let words = checkIn.fields.filter { Double($0.value) == nil && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let ups = ds.filter { d in guard let p = d.prev, let b = d.better else { return false }; return b ? d.now > p : d.now < p }.count
        let scored = ds.filter { $0.prev != nil && $0.better != nil }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        CoachAvatar(name: clientName, size: 52, highlighted: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clientName).font(BrandFont.display(32)).foregroundColor(Brand.text)
                            Text("Sent \(checkIn.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
                                 + (previous.map { " · vs \($0.date.formatted(.dateTime.month(.abbreviated).day()))" } ?? " · first check-in"))
                                .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        }
                    }

                    if !ds.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("WEEK OVER WEEK").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                                Spacer()
                                if scored > 0 { Text("\(ups) of \(scored) scores up").font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText) }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(ds) { d in tile(d) }
                            }
                            if ds.contains(where: { $0.history.count >= 2 }) {
                                Text("Each line runs from their first check-in to this one.")
                                    .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                            }
                        }
                        .card(padding: 16)
                    }

                    if !words.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("IN THEIR WORDS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            ForEach(words, id: \.id) { f in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.cleanLabel).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.mute)
                                    Text("“\(f.value)”").font(BrandFont.body(14, .medium)).foregroundColor(Brand.text)
                                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 16)
                    }

                    photoCompare

                    if let r = checkIn.trainerResponse, !r.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR RESPONSE").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            Text(r).font(BrandFont.body(14)).foregroundColor(Brand.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 16)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("YOUR RESPONSE").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            QuickReplies { s in   // his saved replies
                                response = response.isEmpty ? s : response + " " + s
                            }
                            TextEditor(text: $response)
                                .font(BrandFont.body(15)).foregroundColor(Brand.text)
                                .scrollContentBackground(.hidden)
                                .padding(10).frame(minHeight: 120)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: 1.5))
                            if failed {
                                Text("Couldn't send. Check your connection and try again.").font(BrandFont.body(12)).foregroundColor(.orange)
                            }
                            Button { send() } label: {
                                HStack(spacing: 8) {
                                    if sending { ProgressView().tint(Brand.black) }
                                    Label("Send response & mark reviewed", systemImage: "checkmark")
                                }
                            }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                            .disabled(sending || response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .card(padding: 16)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.voltText) } }
            .tapToDismissKeyboard()
            .keyboardDoneButton()
            .task {
                await data.loadCheckIns(clientId)
                photos = (try? await APIClient.shared.trainerPhotos(clientId: clientId)) ?? []
            }
            .alert("Comment on this photo", isPresented: Binding(get: { photoComment != nil }, set: { if !$0 { photoComment = nil } })) {
                TextField("Your comment", text: $commentText)
                Button("Save") {
                    if let p = photoComment {
                        let t = commentText
                        Task {
                            try? await APIClient.shared.trainerCommentPhoto(photoId: p.id, comment: t)
                            photos = (try? await APIClient.shared.trainerPhotos(clientId: clientId)) ?? photos
                        }
                    }
                    photoComment = nil
                }
                Button("Cancel", role: .cancel) { photoComment = nil }
            } message: { Text("Shows under the photo in their app.") }
        }
    }

    private func tile(_ d: Delta) -> some View {
        let diff = d.prev.map { d.now - $0 }
        let color: Color = {
            guard let diff, diff != 0, let good = d.better else { return Brand.mute }
            return (diff > 0) == good ? Brand.volt : .orange
        }()
        let fmt: (Double) -> String = { v in v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(d.label).font(BrandFont.body(8, .bold)).tracking(0.8).foregroundColor(Brand.mute).lineLimit(1)
            Text(fmt(d.now) + d.unit).font(BrandFont.body(17, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(diff.map { $0 == 0 ? "· same" : "\($0 > 0 ? "▲" : "▼") \(fmt(abs($0))) vs last" } ?? "first one")
                .font(BrandFont.body(10, .bold)).foregroundColor(Brand.readable(color)).lineLimit(1).minimumScaleFactor(0.7)
            if d.history.count >= 2 {
                CheckInSpark(values: d.history, color: color == Brand.mute ? Brand.text.opacity(0.35) : color)
                    .frame(height: 14).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
    }

    /// Before = this pose's earliest photo; after = the one from this check-in (or the latest).
    @ViewBuilder
    private var photoCompare: some View {
        let cal = Calendar.training
        let models = photos.map { $0.toModel() }
        let cats = Array(Set(models.map { $0.category })).sorted { a, b in
            let order = ["Front", "Side", "Back"]
            return (order.firstIndex(of: a) ?? 99, a) < (order.firstIndex(of: b) ?? 99, b)
        }.filter { c in Set(models.filter { $0.category == c }.map { cal.startOfDay(for: $0.date) }).count >= 2 }
        if let cat = photoCategory ?? cats.first {
            let ps = models.filter { $0.category == cat }.sorted { $0.date < $1.date }
            let after = ps.last { cal.isDate($0.date, inSameDayAs: checkIn.date) } ?? ps.last
            if let before = ps.first, let after, before.id != after.id {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("PHOTOS · \(cat.uppercased())").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        Spacer()
                        let weeks = max(1, (cal.dateComponents([.day], from: before.date, to: after.date).day ?? 0) / 7)
                        Text("\(weeks) week\(weeks == 1 ? "" : "s") apart").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                    PhotoRevealSlider(before: before, after: after, urlFor: { APIClient.shared.trainerPhotoURL(photoId: $0.id) })
                        .id(cat)
                    HStack(spacing: 6) {
                        Button {
                            commentText = photos.first { $0.id == after.id }?.trainerComment ?? ""
                            photoComment = photos.first { $0.id == after.id }
                        } label: { Label("Comment on this photo", systemImage: "text.bubble") }
                            .font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                        Spacer()
                        ForEach(cats.prefix(3), id: \.self) { c in
                            Button { photoCategory = c } label: {
                                Text(c).font(BrandFont.body(11, .bold)).foregroundColor(c == cat ? Brand.onVolt : Brand.mute)
                                    .padding(.horizontal, 10).frame(minHeight: 30)
                                    .background(Capsule().fill(c == cat ? Brand.volt : Color.clear))
                                    .overlay(Capsule().stroke(c == cat ? Brand.voltLine : Brand.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let c = after.trainerComment, !c.isEmpty {
                        Text("Your comment: “\(c)”").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                }
                .card(padding: 16)
            }
        }
    }

    private func send() {
        sending = true; failed = false
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await APIClient.shared.trainerRespondCheckIn(checkInId: checkIn.id, response: text)
                await data.loadCheckIns(clientId, force: true)
                await MainActor.run {
                    sending = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    store.loadRoster()
                    dismiss()
                }
            } catch {
                await MainActor.run { sending = false; failed = true }
            }
        }
    }
}

extension APIClient {
    func trainerCommentPhoto(photoId: String, comment: String) async throws {
        _ = try await request("/admin/photos/\(photoId)/comment", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["comment": comment]))
    }
}

/// Tiny trend line inside a week-over-week tile — the metric across every check-in.
private struct CheckInSpark: View {
    let values: [Double]
    var color: Color = Brand.volt
    var body: some View {
        GeometryReader { g in
            let mn = values.min() ?? 0
            let mx = values.max() ?? 1
            let rng = max(mx - mn, 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = (g.size.height - 2) * (1 - CGFloat((v - mn) / rng)) + 1
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Insights (roster totals)

struct TrainerInsightsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let i = store.insights
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DSScreenHeader(eyebrow: "State of the business", title: "Insights", subtitle: "Across your whole roster")
                HStack(spacing: 10) {
                    DSStatTile(value: "\(i.totalClients)", label: "ACTIVE CLIENTS", color: Brand.text)
                    DSStatTile(value: "\(i.workoutsThisWeek)", label: "WORKOUTS THIS WEEK")
                }
                HStack(spacing: 10) {
                    DSStatTile(value: "\(i.needingAttention)", label: "NEED YOU")
                    DSStatTile(value: "\(i.drifting)", label: "GOING QUIET", color: .orange)
                }
                HStack(spacing: 10) {
                    DSStatTile(value: "\(i.awardsThisWeek)", label: "AWARDS THIS WEEK")
                    DSStatTile(value: i.avgDaysSinceTrained > 90 ? "—" : "\(i.avgDaysSinceTrained)d", label: "AVG SINCE TRAINED", color: Brand.text)
                }
                if i.totalClients > 0 {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "WHERE YOUR CREW IS")
                        let fine = max(0, i.totalClients - i.needingAttention - i.drifting)
                        bar("Need you", i.needingAttention, i.totalClients, Brand.volt)
                        bar("Going quiet", i.drifting, i.totalClients, .orange)
                        bar("On track", fine, i.totalClients, Brand.text.opacity(0.6))
                    }
                    .card(padding: 16)
                }
                Text("Updates from your roster each time it loads. Pull down to refresh. Full client data lives in the web console.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable { store.loadRoster() }
    }

    private func bar(_ label: String, _ n: Int, _ total: Int, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(BrandFont.body(12, .bold)).foregroundColor(Brand.text).frame(width: 90, alignment: .leading)
            DSProgressBar(fraction: total > 0 ? Double(n) / Double(total) : 0, height: 8, color: color)
            Text("\(n)").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.text).frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Announcements (one post, every client)

struct AnnouncementsComposerView: View {
    @EnvironmentObject var store: AppStore
    @State private var title = ""
    @State private var messageBody = ""
    @State private var posting = false
    @State private var didPost = false
    @State private var failed = false
    @State private var existing: [APIAnnouncement] = []
    @State private var loading = true
    @State private var confirmDelete: APIAnnouncement? = nil
    @State private var when: When = .now
    @State private var publishAt = Calendar.current.date(byAdding: .hour, value: 24, to: Date()) ?? Date()

    enum When: String, CaseIterable, Hashable { case now = "Post now", later = "Schedule" }

    private var scheduled: [APIAnnouncement] { existing.filter { $0.publishAt != nil }.sorted { ($0.publishAt ?? .distantFuture) < ($1.publishAt ?? .distantFuture) } }
    private var posted: [APIAnnouncement] { existing.filter { $0.publishAt == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "One post, every client", title: "Announcements",
                               subtitle: "Shows on every client's Home and Announcements.")

                VStack(alignment: .leading, spacing: 10) {
                    Text("TITLE").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                    TextField("", text: $title, prompt: Text("New PR Challenge Starts Monday").foregroundColor(Brand.mute))
                        .font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: 1.5))
                    Text("MESSAGE").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                    TextEditor(text: $messageBody)
                        .font(BrandFont.body(15)).foregroundColor(Brand.text)
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHEN").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                        DSCarousel(options: When.allCases.map { DSCarousel<When>.Option(id: $0, label: $0.rawValue) },
                                   selection: $when, itemWidth: 124, accessibilityName: "When to post")
                        if when == .later {
                            DatePicker("Goes out", selection: $publishAt, in: Date().addingTimeInterval(120)...,
                                       displayedComponents: [.date, .hourAndMinute])
                                .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text).tint(Brand.voltText)
                                .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                            Text("Clients won't see it, and nobody's notified, until then.")
                                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                    }
                    if didPost { Text(lastWasScheduled ? "Scheduled. 👑" : "Posted to all clients. 👑").font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText) }
                    if failed { Text("Couldn't post. Check your connection and try again.").font(BrandFont.body(12)).foregroundColor(.orange) }
                    Button { post() } label: {
                        HStack(spacing: 8) {
                            if posting { ProgressView().tint(Brand.black) }
                            Label(when == .later ? "Schedule for \(publishAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))" : "Post to all clients",
                                  systemImage: when == .later ? "clock.fill" : "megaphone.fill")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(title.isEmpty || messageBody.isEmpty || posting)
                    .opacity(title.isEmpty || messageBody.isEmpty ? 0.5 : 1)
                }
                .card(padding: 16)

                if !title.isEmpty || !messageBody.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PREVIEW · WHAT CLIENTS SEE").font(BrandFont.body(10, .bold)).tracking(1.4).foregroundColor(Brand.mute)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "megaphone.fill").font(.system(size: 12)).foregroundColor(Brand.voltText)
                                Text("TODAY").font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                                DSChip(text: "New", color: Brand.volt, filled: true)
                            }
                            Text(title.isEmpty ? "Your title" : title).font(BrandFont.display(26)).foregroundColor(Brand.text)
                            Text(messageBody.isEmpty ? "Your message" : messageBody).font(BrandFont.body(14)).foregroundColor(Brand.text.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
                    }
                }

                if !scheduled.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "SCHEDULED", subtitle: "\(scheduled.count) waiting")
                        ForEach(scheduled, id: \.id) { a in announcementCard(a) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "POSTED")
                    if loading { ProgressView().tint(Brand.volt).frame(maxWidth: .infinity) }
                    else if posted.isEmpty { Text("Nothing posted yet.").font(BrandFont.body(13)).foregroundColor(Brand.mute) }
                    ForEach(posted, id: \.id) { a in announcementCard(a) }
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .task { await loadExisting() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
        .confirmationDialog("Delete this announcement?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let a = confirmDelete { remove(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmDelete?.publishAt != nil ? "It won't go out." : "It disappears from every client's app.") }
    }

    @State private var lastWasScheduled = false

    private func announcementCard(_ a: APIAnnouncement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let at = a.publishAt {
                    Image(systemName: "clock.fill").font(.system(size: 11)).foregroundColor(Brand.voltText)
                    Text(at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()).uppercased())
                        .font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                } else {
                    Text(a.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
                        .font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                }
                Spacer()
                Button { confirmDelete = a } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(Brand.mute)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(a.publishAt != nil ? "Cancel \(a.title)" : "Delete \(a.title)")
            }
            Text(a.title).font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
            Text(a.body).font(BrandFont.body(13)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(a.publishAt != nil ? Brand.voltLine.opacity(0.45) : Color.clear, lineWidth: 1))
    }

    private func loadExisting() async {
        loading = true
        existing = ((try? await APIClient.shared.adminAnnouncements()) ?? []).sorted { $0.createdAt > $1.createdAt }
        loading = false
    }

    private func post() {
        posting = true; didPost = false; failed = false
        let t = title, b = messageBody
        let at: Date? = when == .later ? publishAt : nil
        Task {
            do {
                try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at)
                await loadExisting()
                await MainActor.run {
                    posting = false; didPost = true; lastWasScheduled = at != nil
                    title = ""; messageBody = ""; when = .now
                }
            } catch {
                await MainActor.run { posting = false; failed = true }
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
