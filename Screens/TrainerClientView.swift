import SwiftUI

// MARK: - Coach's view of one client
// Read + respond: check-ins, conversations, their photos and awards, your private notes.
// Detailed data review (Stats, Watch data, macros) lives in the web console.

struct TrainerClientView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let client: RosterItem

    enum Section: String, CaseIterable, Identifiable {
        case checkins = "Check-Ins", workouts = "Workouts", chat = "Chat", progress = "Progress",
             photos = "Photos", awards = "Awards", notes = "Notes"
        var id: String { rawValue }
    }
    @State private var section: Section

    init(client: RosterItem) {
        self.client = client
        _section = State(initialValue: client.unreadMessages > 0 ? .chat : .checkins)
    }

    /// Opens on what most likely needs you: unread messages → Chat, otherwise Check-Ins.
    private var likelySection: Section { client.unreadMessages > 0 ? .chat : .checkins }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        CoachAvatar(name: client.name, size: 56, highlighted: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(client.name).font(BrandFont.display(34)).foregroundColor(Brand.text)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            if !client.goal.isEmpty {
                                Text(client.goal).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(2)
                            }
                            Text(client.headline).font(BrandFont.body(12, .bold))
                                .foregroundColor(client.needsAttention ? Brand.voltText : (client.isDrifting ? .orange : Brand.mute))
                        }
                    }
                    HStack(spacing: 10) {
                        DSStatTile(value: "\(client.workoutsThisWeek)", label: "THIS WEEK")
                        DSStatTile(value: "\(client.missedWorkouts)", label: "MISSED", color: client.missedWorkouts > 0 ? .orange : Brand.text)
                        DSStatTile(value: client.daysSinceTrained > 90 ? "—" : "\(client.daysSinceTrained)d", label: "SINCE TRAINED", color: Brand.text)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)

                DSCarousel(options: Section.allCases.map { DSCarousel<Section>.Option(id: $0, label: $0.rawValue) },
                           selection: $section, likely: likelySection, itemWidth: 108,
                           accessibilityName: "Section")
                    .padding(.bottom, 12)

                Group {
                    switch section {
                    case .checkins: TrainerCheckInsView(clientId: client.id, clientName: client.name)
                    case .workouts: TrainerWorkoutsView(clientId: client.id, clientName: client.name)
                    case .chat:     CoachClientThreads(client: client)
                    case .progress: TrainerProgressView(clientId: client.id)
                    case .photos:   TrainerPhotosView(clientId: client.id)
                    case .awards:   TrainerAwardsView(clientId: client.id, clientName: client.name)
                    case .notes:    TrainerNotesView(clientId: client.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 8)
            .background(Brand.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { store.loadRoster(); dismiss() }.foregroundColor(Brand.voltText)
                }
            }
        }
        .tint(Brand.volt)
    }
}

// MARK: Check-ins — open any to review and respond

struct TrainerCheckInsView: View {
    @ObservedObject private var data = CoachData.shared
    let clientId: String
    var clientName: String = ""
    @State private var open: APICheckIn?

    var body: some View {
        let list = (data.checkIns[clientId] ?? []).filter { $0.status != "draft" }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if data.checkIns[clientId] == nil {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if list.isEmpty {
                    Text("No check-ins yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(list, id: \.id) { ci in
                    Button { open = ci } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ci.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    .font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                                Text([ci.photoIds.isEmpty ? nil : "\(ci.photoIds.count) photo\(ci.photoIds.count == 1 ? "" : "s")",
                                      ci.trainerResponse.map { "You: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(1)
                            }
                            Spacer()
                            if ci.status == "reviewed" { DSChip(text: "Reviewed", icon: "checkmark", color: Brand.volt, filled: true) }
                            else { DSChip(text: "Review", icon: "exclamationmark", color: Brand.volt) }
                        }
                        .padding(14)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ci.status == "reviewed" ? Brand.line : Brand.voltLine.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task { await data.loadCheckIns(clientId) }
        .refreshable { await data.loadCheckIns(clientId, force: true) }
        .sheet(item: Binding(get: { open.map { IdentifiedCheckIn(checkIn: $0) } }, set: { open = $0?.checkIn })) { w in
            CoachCheckInReview(clientId: clientId, clientName: clientName, checkIn: w.checkIn)
        }
    }

    private struct IdentifiedCheckIn: Identifiable { let checkIn: APICheckIn; var id: String { checkIn.id } }
}

// MARK: Chat

struct TrainerChatView: View {
    let clientId: String
    let clientName: String
    var threadId: String? = nil          // open a specific thread; nil = first/most-recent
    var categoryLabel: String? = nil     // shown as a chip in the header
    @State private var threads: [APIChatThread] = []
    @State private var messages: [APIChatMessage] = []
    @State private var activeThreadId: String? = nil
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            // Category chip so the trainer always knows which thread they're in.
            if let cat = categoryLabel {
                HStack(spacing: 6) {
                    Text(cat.uppercased())
                        .font(BrandFont.body(10, .bold)).tracking(1)
                        .foregroundColor(Brand.voltText)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if loading {
                            ProgressView().tint(Brand.volt).padding(.top, 30)
                        } else if messages.isEmpty {
                            Text("No messages yet.")
                                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                                .padding(.top, 30)
                        }
                        ForEach(messages, id: \.id) { m in
                            HStack {
                                if m.fromTrainer { Spacer(minLength: 40) }
                                Text(m.text)
                                    .font(BrandFont.body(14))
                                    .foregroundColor(m.fromTrainer ? Brand.onVolt : Brand.text)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(m.fromTrainer ? Brand.volt : Brand.black)
                                    .clipShape(BubbleShape(fromMe: m.fromTrainer))
                                    .overlay(m.fromTrainer ? nil :
                                        BubbleShape(fromMe: false).stroke(Brand.line, lineWidth: 1))
                                if !m.fromTrainer { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 10)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            QuickReplies(options: ["Love to hear it!", "Keep it up 💪", "Send me a video?", "Can we talk this week?"]) { draft = $0 }
                .padding(.horizontal, 20).padding(.top, 6)
            HStack(spacing: 8) {
                TextField("Message \(clientName)…", text: $draft)
                    .font(BrandFont.body(14))
                    .foregroundColor(Brand.text)
                    .padding(12)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Brand.onVolt)
                        .frame(width: 44, height: 44)
                        .background(Brand.volt).clipShape(Capsule())
                }
                .disabled(draft.isEmpty || sending)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Brand.bg)
        }
        .task { await load() }
        .tapToDismissKeyboard()
    }

    private func load() async {
        loading = true
        threads = (try? await APIClient.shared.trainerChats(clientId: clientId)) ?? []
        // Open the requested thread if given, else the most recent one.
        let target = threadId.flatMap { id in threads.first { $0.id == id } } ?? threads.first
        activeThreadId = target?.id
        if let t = target {
            messages = (try? await APIClient.shared.trainerMessages(threadId: t.id)) ?? []
        }
        loading = false
    }

    private func send() {
        guard let tid = activeThreadId, !draft.isEmpty else { return }
        let text = draft
        draft = ""; sending = true
        Task {
            try? await APIClient.shared.trainerSendMessage(threadId: tid, text: text)
            await load()
            await MainActor.run { sending = false }
        }
    }
}

// MARK: Progress — strength trend and recent sessions

struct TrainerProgressView: View {
    let clientId: String
    @State private var workouts: [Workout] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if workouts.filter({ $0.completed }).isEmpty {
                    Text("Nothing logged yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }

                let trends = ProgressEngine.trends(workouts: workouts)
                if !trends.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "STRENGTH TREND")
                        VStack(spacing: 0) {
                            ForEach(trends) { t in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.exercise).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                                        Text("\(t.sessions) session\(t.sessions == 1 ? "" : "s")").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(StatsUnits.weightText(t.current)).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                                        if t.change != 0 {
                                            Text("\(t.change > 0 ? "+" : "−")\(StatsUnits.weightText(abs(t.change)))")
                                                .font(BrandFont.body(11, .heavy)).foregroundColor(t.change > 0 ? Brand.voltText : .orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 12)
                                if t.id != trends.last?.id { Divider().overlay(Brand.line) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    }
                }

                let recent = workouts.filter { $0.completed }.sorted { $0.date > $1.date }.prefix(8)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "RECENT SESSIONS", subtitle: "% of prescribed sets hit")
                        ForEach(Array(recent)) { w in
                            let c = ProgressEngine.compliance(for: w)
                            DSListRow(title: w.title,
                                      subtitle: w.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                      trailing: "\(Int(c.rate * 100))%",
                                      icon: c.rate >= 1 ? "checkmark.circle.fill" : "circle.lefthalf.filled",
                                      iconTint: c.rate >= 1 ? Brand.volt : (c.rate >= 0.8 ? .orange : Brand.mute))
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let api = (try? await APIClient.shared.trainerWorkouts(clientId: clientId)) ?? []
        workouts = api.map { $0.toModel() }
        loading = false
    }
}

// MARK: Awards

struct TrainerAwardsView: View {
    let clientId: String
    let clientName: String
    @State private var awards: [APIAward] = []
    @State private var loading = true
    @State private var compose: CoachCompose? = nil
    @ObservedObject private var congrats = CongratsLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if awards.isEmpty {
                    Text("No awards yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(awards.sorted { $0.earnedAt > $1.earnedAt }) { a in
                    let winId = "aw|\(clientId)|\(a.kind)"
                    let done = congrats.done.contains(winId)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: a.icon).font(.system(size: 18, weight: .bold)).foregroundColor(Brand.onVolt)
                            .frame(width: 44, height: 44).background(Circle().fill(Brand.volt))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                            Text(a.blurb).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Unlocked \(a.earnedAt.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(BrandFont.body(10, .bold)).foregroundColor(Brand.voltText)
                        }
                        Spacer(minLength: 4)
                        if !done {
                            Button {
                                compose = CoachCompose(title: "Congrats to \(clientName.firstName)", subtitle: "Award · \(a.title)",
                                                       clientId: clientId,
                                                       starters: ["\(a.title) — congrats, \(clientName.firstName)!", "Love seeing this. Keep it rolling!", "Proud of you!"],
                                                       initial: "\(a.title) — congrats, \(clientName.firstName)!", winId: winId)
                            } label: {
                                Image(systemName: "sparkles").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.voltText)
                                    .frame(width: 40, height: 40).overlay(Circle().stroke(Brand.voltLine, lineWidth: 1.5))
                            }
                            .accessibilityLabel("Send congrats")
                        }
                    }
                    .padding(14)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine.opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            awards = (try? await APIClient.shared.trainerAwards(clientId: clientId)) ?? []
            loading = false
        }
        .sheet(item: $compose) { c in
            CoachComposeSheet(title: c.title, subtitle: c.subtitle, clientId: c.clientId, starters: c.starters,
                              initial: c.initial) { if let w = c.winId { congrats.mark(w) } }
        }
    }
}

// MARK: Progress photos (your eyes only)

struct TrainerPhotosView: View {
    let clientId: String
    @State private var photos: [APIPhoto] = []
    @State private var loading = true
    @State private var expandedPhoto: APIPhoto?

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let cal = Calendar.training
        let buckets = Dictionary(grouping: photos) { cal.startOfDay(for: $0.date) }
            .map { (day: $0.key, photos: $0.value) }.sorted { $0.day > $1.day }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if photos.isEmpty {
                    Text("No progress photos yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(buckets, id: \.day) { b in
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: b.day.formatted(.dateTime.month(.wide).day().year()).uppercased(),
                                        subtitle: "\(b.photos.count) photo\(b.photos.count == 1 ? "" : "s")")
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(b.photos, id: \.id) { p in
                                Button { expandedPhoto = p } label: {
                                    PhotoFill(photo: p.toModel(), url: APIClient.shared.trainerPhotoURL(photoId: p.id))
                                        .aspectRatio(0.8, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(alignment: .bottomLeading) {
                                            HStack(spacing: 4) {
                                                Text(p.category.uppercased()).font(BrandFont.body(8, .heavy)).tracking(0.8)
                                                if p.trainerComment != nil { Image(systemName: "bubble.left.fill").font(.system(size: 8)) }
                                            }
                                            .foregroundColor(Brand.text)
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Capsule().fill(Color.black.opacity(0.6)))
                                            .padding(6)
                                        }
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel("\(p.category) photo, \(p.date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            photos = (try? await APIClient.shared.trainerPhotos(clientId: clientId)) ?? []
            loading = false
        }
        .fullScreenCover(item: $expandedPhoto) { p in
            FullScreenPhotoView(url: APIClient.shared.trainerPhotoURL(photoId: p.id), caption: p.category)
        }
    }
}

// MARK: Private notes — yours only, one notepad per client

struct TrainerNotesView: View {
    let clientId: String
    @State private var body_ = ""
    @State private var loading = true
    @State private var saving = false
    @State private var savedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(Brand.mute)
                    Text("Private to you — the client never sees this.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    TextEditor(text: $body_)
                        .font(BrandFont.body(15)).foregroundColor(Brand.text)
                        .scrollContentBackground(.hidden)
                        .padding(12).frame(minHeight: 240)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    Button { save() } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(Brand.black) }
                            Label(savedAt != nil ? "Saved" : "Save note", systemImage: savedAt != nil ? "checkmark" : "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(saving)
                    if let d = savedAt {
                        Text("Saved \(d.formatted(date: .abbreviated, time: .shortened))").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            if let n = try? await APIClient.shared.clientNote(clientId: clientId) { body_ = n.body }
            loading = false
        }
        .onChange(of: body_) { _, _ in savedAt = nil }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }

    private func save() {
        saving = true
        Task {
            try? await APIClient.shared.saveClientNote(clientId: clientId, body: body_)
            await MainActor.run { saving = false; savedAt = Date() }
        }
    }
}

// A chat bubble: rounded on three corners, squared on the tail corner (bottom-trailing
// for the sender, bottom-leading for the recipient) — the familiar messaging look.
// Chat now lives in the dedicated Chat tab (where threads can be created with a
// topic + category). The client profile just points the trainer there.
struct GoToChatShortcut: View {
    let clientName: String
    var go: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44)).foregroundColor(Brand.voltText)
            Text("Messages live in the Chat tab")
                .font(BrandFont.display(24)).foregroundColor(Brand.text)
                .multilineTextAlignment(.center)
            Text("Open \(clientName)'s threads or start a new one from there.")
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button(action: go) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right")
                    Text("Go to Chat").font(BrandFont.body(15, .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Brand.volt).foregroundColor(Brand.onVolt).clipShape(Capsule())
            }
            .padding(.horizontal, 40).padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BubbleShape: Shape {
    let fromMe: Bool
    var radius: CGFloat = 16
    func path(in rect: CGRect) -> Path {
        let r = radius
        let tl = r
        let tr = r
        let bl: CGFloat = fromMe ? r : 4
        let br: CGFloat = fromMe ? 4 : r
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
