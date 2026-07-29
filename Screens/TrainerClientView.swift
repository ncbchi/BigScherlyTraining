import SwiftUI

// MARK: - Trainer's view of one client
// Everything needed to answer them, nothing for authoring their program.

struct TrainerClientView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let client: RosterItem

    enum Section: String, CaseIterable, Identifiable {
        case checkins = "Check-Ins"
        case chat     = "Chat"
        case progress = "Progress"
        case photos   = "Photos"
        case awards   = "Awards"
        case notes    = "Notes"
        var id: String { rawValue }
    }
    @State private var section: Section = .checkins

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(client.name).font(BrandFont.display(34)).foregroundColor(.white)
                    if !client.goal.isEmpty {
                        Text(client.goal).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    HStack(spacing: 14) {
                        stat("\(client.workoutsThisWeek)", "THIS WEEK")
                        stat("\(client.missedWorkouts)", "MISSED")
                        stat(client.daysSinceTrained > 90 ? "—" : "\(client.daysSinceTrained)d", "SINCE TRAINED")
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 14)

                // Section picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Section.allCases) { s in
                            Button { section = s } label: {
                                Text(s.rawValue)
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundColor(section == s ? Brand.black : .white)
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(section == s ? Brand.volt : Brand.black).clipShape(Capsule())
                                    .overlay(Capsule().stroke(section == s ? Brand.volt : Brand.line, lineWidth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 12)

                Group {
                    switch section {
                    case .checkins: TrainerCheckInsView(clientId: client.id)
                    case .chat:     GoToChatShortcut(clientName: client.name) {
                                        store.trainerTab = .chat
                                        dismiss()
                                    }
                    case .progress: TrainerProgressView(clientId: client.id)
                    case .photos:   TrainerPhotosView(clientId: client.id)
                    case .awards:   TrainerAwardsView(clientId: client.id, clientName: client.name)
                    case .notes:    TrainerNotesView(clientId: client.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Brand.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { store.loadRoster(); dismiss() }
                        .foregroundColor(Brand.volt)
                }
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(BrandFont.display(20)).foregroundColor(Brand.volt)
            Text(l).font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.mute)
        }
    }
}

// MARK: Check-ins — read and respond

struct TrainerCheckInsView: View {
    let clientId: String
    @State private var checkIns: [APICheckIn] = []
    @State private var responses: [String: String] = [:]
    @State private var loading = true
    @State private var sendingFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if checkIns.isEmpty {
                    Text("No check-ins yet.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }

                ForEach(checkIns, id: \.id) { ci in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(ci.date.formatted(date: .abbreviated, time: .omitted))
                                .font(BrandFont.body(14, .bold)).foregroundColor(.white)
                            Spacer()
                            Text(ci.status.uppercased())
                                .font(BrandFont.body(9, .bold)).tracking(1)
                                .foregroundColor(ci.status == "reviewed" ? Brand.black : Brand.volt)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(ci.status == "reviewed" ? Brand.volt : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))
                        }

                        // Awards won in the week leading up to this check-in — so he can
                        // open with the win instead of hunting for it.
                        if let aw = ci.awards, !aw.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("WON THIS WEEK")
                                    .font(BrandFont.body(9, .bold)).tracking(1.4)
                                    .foregroundColor(Brand.volt)
                                ForEach(aw, id: \.kind) { a in
                                    HStack(spacing: 6) {
                                        Image(systemName: a.icon)
                                            .font(.system(size: 11)).foregroundColor(Brand.volt)
                                        Text(a.title)
                                            .font(BrandFont.body(12, .semibold)).foregroundColor(.white)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Brand.volt.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))
                        }

                        ForEach(ci.fields, id: \.id) { f in
                            HStack {
                                Text(f.cleanLabel).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                                Spacer()
                                Text(f.value).font(BrandFont.body(13, .bold)).foregroundColor(.white)
                            }
                        }

                        if let r = ci.trainerResponse, !r.isEmpty {
                            Text("YOUR RESPONSE")
                                .font(BrandFont.body(9, .bold)).tracking(1.4).foregroundColor(Brand.volt)
                                .padding(.top, 4)
                            Text(r).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        } else {
                            TextEditor(text: Binding(
                                get: { responses[ci.id] ?? "" },
                                set: { responses[ci.id] = $0 }))
                                .font(BrandFont.body(14))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(height: 90)
                                .background(Brand.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                            Button {
                                respond(ci)
                            } label: {
                                HStack {
                                    if sendingFor == ci.id { ProgressView().tint(Brand.black) }
                                    Text("Send response").font(BrandFont.body(13, .bold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
                            }
                            .disabled((responses[ci.id] ?? "").isEmpty || sendingFor == ci.id)
                        }
                    }
                    .padding(16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task { await load() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }

    private func load() async {
        loading = true
        checkIns = (try? await APIClient.shared.trainerCheckIns(clientId: clientId)) ?? []
        loading = false
    }

    private func respond(_ ci: APICheckIn) {
        guard let text = responses[ci.id], !text.isEmpty else { return }
        sendingFor = ci.id
        Task {
            try? await APIClient.shared.trainerRespondCheckIn(checkInId: ci.id, response: text)
            await load()
            await MainActor.run { sendingFor = nil }
        }
    }
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
                        .foregroundColor(Brand.volt)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Capsule().stroke(Brand.volt, lineWidth: 1))
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
                                    .foregroundColor(m.fromTrainer ? Brand.black : .white)
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

            HStack(spacing: 8) {
                TextField("Message \(clientName)…", text: $draft)
                    .font(BrandFont.body(14))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Brand.black)
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

// MARK: Progress — what they've actually been lifting

struct TrainerProgressView: View {
    let clientId: String
    @State private var workouts: [Workout] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if workouts.filter({ $0.completed }).isEmpty {
                    Text("Nothing logged yet.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }

                let trends = ProgressEngine.trends(workouts: workouts)
                if !trends.isEmpty {
                    Text("STRENGTH TREND")
                        .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    VStack(spacing: 0) {
                        ForEach(trends) { t in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.exercise).font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                                    Text("\(t.sessions) session\(t.sessions == 1 ? "" : "s")")
                                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(t.current)) lb")
                                        .font(BrandFont.body(14, .bold)).foregroundColor(.white)
                                    if t.change != 0 {
                                        Text("\(t.change > 0 ? "+" : "")\(Int(t.change)) lb")
                                            .font(BrandFont.body(11, .bold))
                                            .foregroundColor(t.change > 0 ? Brand.volt : .orange)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            Divider().overlay(Brand.line)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }

                // Recent sessions with how much of the target they actually hit.
                let recent = workouts.filter { $0.completed }
                    .sorted { $0.date > $1.date }.prefix(8)
                if !recent.isEmpty {
                    Text("RECENT SESSIONS")
                        .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        .padding(.top, 8)
                    ForEach(Array(recent)) { w in
                        let c = ProgressEngine.compliance(for: w)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.title).font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                                Text(w.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                            Text("\(Int(c.rate * 100))%")
                                .font(BrandFont.body(15, .bold))
                                .foregroundColor(c.rate >= 1 ? Brand.volt
                                                 : c.rate >= 0.8 ? .orange : Brand.mute)
                        }
                        .padding(14)
                        .background(Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if awards.isEmpty {
                    Text("No awards yet.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }

                ForEach(awards) { a in
                    HStack(spacing: 12) {
                        Circle().fill(Brand.volt).frame(width: 38, height: 38)
                            .overlay(
                                Image(systemName: a.icon)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(Brand.black)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(BrandFont.body(14, .bold)).foregroundColor(.white)
                            Text(a.blurb).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(a.earnedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                    }
                    .padding(14)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            loading = true
            awards = (try? await APIClient.shared.trainerAwards(clientId: clientId)) ?? []
            loading = false
        }
    }
}

// MARK: Progress photos — transformation review (trainer's eyes only)

struct TrainerPhotosView: View {
    let clientId: String
    @State private var photos: [APIPhoto] = []
    @State private var loading = true
    @State private var expandedPhoto: APIPhoto?

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if photos.isEmpty {
                    Text("No check-in photos yet.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    Text("Newest first — tap to enlarge.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(photos, id: \.id) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                AuthedAsyncImage(url: APIClient.shared.trainerPhotoURL(photoId: p.id)) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { failed in
                                    if failed {
                                        Image(systemName: "photo").foregroundColor(Brand.mute)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } else {
                                        ProgressView().tint(Brand.volt)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .frame(height: 200)
                                .clipped()
                                .background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                                .contentShape(Rectangle())
                                .onTapGesture { expandedPhoto = p }

                                Text(p.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                                if !p.category.isEmpty {
                                    Text(p.category.uppercased())
                                        .font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.volt)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            loading = true
            photos = (try? await APIClient.shared.trainerPhotos(clientId: clientId)) ?? []
            loading = false
        }
        .fullScreenCover(item: $expandedPhoto) { p in
            FullScreenPhotoView(url: APIClient.shared.trainerPhotoURL(photoId: p.id),
                                caption: p.category)
        }
    }
}

// MARK: Private notes — trainer-only, one notepad per client

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
                    Text("Private to you — the client never sees this.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }

                if loading {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    TextEditor(text: $body_)
                        .font(BrandFont.body(15)).foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(12).frame(minHeight: 240)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                    Button {
                        save()
                    } label: {
                        HStack {
                            if saving { ProgressView().tint(Brand.black) }
                            Text(savedAt != nil ? "Saved" : "Save note").font(BrandFont.body(15, .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
                    }
                    .disabled(saving)

                    if let d = savedAt {
                        Text("Saved \(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .task {
            loading = true
            if let n = try? await APIClient.shared.clientNote(clientId: clientId) { body_ = n.body }
            loading = false
        }
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
                .font(.system(size: 44)).foregroundColor(Brand.volt)
            Text("Messages live in the Chat tab")
                .font(BrandFont.display(24)).foregroundColor(.white)
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
                .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
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
