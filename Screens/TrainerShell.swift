import SwiftUI

// MARK: - Trainer shell
//
// Read + respond. Same slide-in tray navigation as the client app (no bottom tab bar),
// for a consistent experience across both. Authoring stays in the web console.

struct TrainerShell: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Active section
            Group {
                switch store.trainerTab {
                case .today:     TrainerTodayView()
                case .clients:   RosterView()
                case .chat:      NavigationStack { TrainerChatSection() }
                case .checkins:  CheckInQueueView()
                case .wins:      WinsFeedView()
                case .share:     TrainerShareView()
                case .insights:  TrainerInsightsView()
                case .announce:  AnnouncementsComposerView()
                case .me:        TrainerMeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Same hamburger (upper right) + right-edge swipe as the client app.
            TrainerEdgeSwipeCatcher {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showTray = true }
            }
            FloatingMenuButton()
                .padding(.trailing, 16).padding(.top, 8)

            TrainerTray()
        }
        .background(Brand.bg.ignoresSafeArea())
        .onAppear { if store.roster.isEmpty { store.loadRoster() } }
        // One place opens a client's profile, from any section.
        .sheet(item: $store.selectedClient) { c in TrainerClientView(client: c) }
    }
}

// Right-edge swipe to open the tray — mirror of the client app's catcher.
private struct TrainerEdgeSwipeCatcher: View {
    let onOpen: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear.contentShape(Rectangle()).frame(width: 20)
                .gesture(
                    DragGesture(minimumDistance: 12).onEnded { v in
                        if v.translation.width < -25 && abs(v.translation.width) > abs(v.translation.height) {
                            onOpen()
                        }
                    })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Trainer tray (same look as client NavTray, trainer sections)

struct TrainerTray: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .trailing) {
            if store.showTray {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { withAnimation { store.showTray = false } }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.trainerName.isEmpty ? "Coach" : store.trainerName)
                                .font(BrandFont.display(28)).foregroundColor(Brand.text)
                            Text("Coach dashboard").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                        }
                        Spacer()
                        Button { withAnimation { store.showTray = false } } label: {
                            Image(systemName: "xmark").foregroundColor(Brand.text).font(.system(size: 18, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)

                    Rectangle().fill(Brand.line).frame(height: 1)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(TrainerTab.allCases) { tab in
                                Button {
                                    store.trainerTab = tab
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        store.showTray = false
                                    }
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: tab.icon)
                                            .font(.system(size: 16))
                                            .foregroundColor(store.trainerTab == tab ? Brand.voltText : Brand.mute)
                                            .frame(width: 24)
                                        Text(tab.rawValue)
                                            .font(BrandFont.body(15, store.trainerTab == tab ? .bold : .semibold))
                                            .foregroundColor(store.trainerTab == tab ? Brand.text : Brand.mute)
                                        Spacer()
                                        // Attention badges next to the relevant sections.
                                        if tab == .clients && store.attentionCount > 0 {
                                            badge(store.attentionCount)
                                        }
                                        if tab == .chat && store.totalUnread > 0 {
                                            badge(store.totalUnread)
                                        }
                                        if tab == .checkins && store.pendingCheckInCount > 0 {
                                            badge(store.pendingCheckInCount)
                                        }
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 15)
                                    .background(store.trainerTab == tab ? Brand.black : Color.clear)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }

                    Rectangle().fill(Brand.line).frame(height: 1)
                    Button { store.logout() } label: {
                        HStack {
                            Image(systemName: "arrow.right.square").foregroundColor(Brand.mute)
                            Text("Log Out").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                    }
                }
                .frame(width: 300).frame(maxHeight: .infinity)
                .background(Brand.bg)
                .overlay(Rectangle().fill(Brand.volt).frame(width: 3), alignment: .leading)
                .transition(.move(edge: .trailing))
                .gesture(
                    DragGesture(minimumDistance: 12).onEnded { v in
                        if v.translation.width > 50 && abs(v.translation.width) > abs(v.translation.height) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showTray = false }
                        }
                    })
            }
        }
    }

    private func badge(_ n: Int) -> some View {
        Text("\(n)").font(BrandFont.body(10, .bold)).foregroundColor(Brand.onVolt)
            .frame(minWidth: 18, minHeight: 18)
            .background(Circle().fill(Brand.volt))
    }
}

// MARK: - Today (the coach's home)

struct TrainerTodayView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var congrats = CongratsLog.shared
    @State private var compose: CoachCompose?
    @State private var threadFor: RosterItem?
    @State private var reviewFor: QueuedCheckIn?

    private var needsYou: [RosterItem] { store.roster.filter { $0.needsAttention } }
    private var quiet: [RosterItem] { store.roster.filter { $0.isDrifting } }
    private var weekWins: [CoachWin] { CoachWins.build(awards: store.recentAwards, days: 7) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSScreenHeader(eyebrow: greeting, title: "Today",
                               subtitle: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .staggeredAppear(0)

                Text(summary).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggeredAppear(1)

                HStack(spacing: 10) {
                    tileButton("\(store.totalUnread)", "UNREAD", Brand.volt) { store.trainerTab = .chat }
                    tileButton("\(store.pendingCheckInCount)", "CHECK-INS", Brand.volt) { store.trainerTab = .checkins }
                    tileButton("\(quiet.count)", "GOING QUIET", .orange) { store.trainerTab = .clients }
                }
                .staggeredAppear(2)

                if store.rosterLoading && store.roster.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                }

                if !needsYou.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "NEEDS YOU")
                        ForEach(needsYou) { c in needsRow(c) }
                    }
                    .staggeredAppear(3)
                }

                if !quiet.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GOING QUIET").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(.orange)
                        ForEach(quiet) { c in
                            CoachRow(client: c, line: c.headline, lineColor: .orange,
                                     sub: c.missedWorkouts > 0 ? "\(c.missedWorkouts) missed this week" : c.goal) {
                                CoachActionPill(title: "Nudge", icon: "bolt.fill", primary: false) {
                                    compose = CoachCompose(title: "Nudge \(c.name.firstName)", subtitle: "A friendly check-in",
                                                           clientId: c.id,
                                                           starters: ["Hey \(c.name.firstName)! Haven't seen a session in a bit — everything okay?",
                                                                      "Missing you in the logs! Want to adjust this week's plan?",
                                                                      "Quick check-in — how are you feeling?"])
                                }
                            }
                        }
                    }
                    .staggeredAppear(4)
                }

                if !weekWins.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "WINS THIS WEEK", subtitle: weekWins.count > 1 ? "swipe" : nil)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(weekWins) { w in winCard(w) }
                            }
                        }
                    }
                    .staggeredAppear(5)
                }

                if !store.rosterLoading && needsYou.isEmpty && quiet.isEmpty && !store.roster.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(Brand.voltText)
                        Text("All caught up — nobody's waiting on you.").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable { store.loadRoster() }
        .sheet(item: $compose) { c in
            CoachComposeSheet(title: c.title, subtitle: c.subtitle, clientId: c.clientId, starters: c.starters,
                              initial: c.initial) { if let w = c.winId { congrats.mark(w) } }
        }
        .sheet(item: $threadFor) { c in CoachThreadSheet(client: c) }
        .sheet(item: $reviewFor) { q in CoachCheckInReview(clientId: q.clientId, clientName: q.clientName, checkIn: q.checkIn) }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
        return "\(part), coach"
    }

    private var summary: String {
        if store.roster.isEmpty { return store.rosterLoading ? "Loading your roster…" : "No active clients yet." }
        var parts: [String] = []
        if !needsYou.isEmpty { parts.append("\(needsYou.count) client\(needsYou.count == 1 ? "" : "s") need\(needsYou.count == 1 ? "s" : "") you") }
        if store.pendingCheckInCount > 0 { parts.append("\(store.pendingCheckInCount) check-in\(store.pendingCheckInCount == 1 ? "" : "s") to review") }
        if !quiet.isEmpty { parts.append("\(quiet.count) going quiet") }
        return parts.isEmpty ? "All caught up." : parts.joined(separator: " · ") + "."
    }

    private func tileButton(_ v: String, _ l: String, _ c: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { DSStatTile(value: v, label: l, color: c) }
            .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private func needsRow(_ c: RosterItem) -> some View {
        let queued = store.checkInQueue.first { $0.clientId == c.id }
        CoachRow(client: c, line: c.headline, lineColor: Brand.volt, sub: c.goal, highlighted: true) {
            if c.unreadMessages > 0 {
                CoachActionPill(title: "Reply", icon: "bubble.left.fill") { threadFor = c }
            } else if let q = queued {
                CoachActionPill(title: "Review", icon: "checkmark") { reviewFor = q }
            }
        }
    }

    private func winCard(_ w: CoachWin) -> some View {
        let done = congrats.done.contains(w.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: w.icon).font(.system(size: 15, weight: .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 34, height: 34).background(Circle().fill(Brand.volt))
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.clientName.firstName.uppercased())
                        .font(BrandFont.body(10, .heavy)).tracking(1).headerPill()
                    Text(w.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text).lineLimit(2)
                    Text(w.detail).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(2)
                }
            }
            if done {
                Label("Congratulated", systemImage: "checkmark").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
            } else {
                CoachActionPill(title: "Send congrats", icon: "sparkles", primary: false) {
                    compose = congratsCompose(w)
                }
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(done ? Brand.line : Brand.voltLine.opacity(0.45), lineWidth: 1))
    }
}

/// Congrats composer config for a win (shared by Today and Wins).
func congratsCompose(_ w: CoachWin) -> CoachCompose {
    let first = w.clientName.firstName
    let starters = ["\(w.title) — congrats, \(first)!", "Love seeing this. Keep it rolling!", "Proud of you!"]
    return CoachCompose(title: "Congrats to \(first)", subtitle: "Award · \(w.title)",
                        clientId: w.clientId, starters: starters, initial: starters[0], winId: w.id)
}

/// A client row with an optional trailing action. Tapping the row opens the client.
struct CoachRow<Action: View>: View {
    @EnvironmentObject var store: AppStore
    let client: RosterItem
    let line: String
    var lineColor: Color = Brand.volt
    var sub: String = ""
    var highlighted = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Button { store.selectedClient = client } label: {
                HStack(spacing: 12) {
                    CoachAvatar(name: client.name, size: 42, highlighted: highlighted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.name).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                        Text(line).font(BrandFont.body(12, .bold)).foregroundColor(Brand.readable(lineColor))
                        if !sub.isEmpty { Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            action()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

/// Opens straight into the client's most relevant conversation (unread first).
struct CoachThreadSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let client: RosterItem
    @State private var thread: APIChatThread?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let t = thread {
                    TrainerChatThreadScreen(clientId: client.id, clientName: client.name, threadId: t.id, categoryLabel: t.category)
                } else if loaded {
                    VStack(spacing: 12) {
                        Text("No conversations with \(client.name.firstName) yet.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { store.loadRoster(); dismiss() }.foregroundColor(Brand.voltText) } }
        }
        .tint(Brand.volt)
        .task {
            let threads = (try? await APIClient.shared.trainerChats(clientId: client.id)) ?? []
            thread = threads.first { $0.unread > 0 } ?? threads.max { $0.lastActivity < $1.lastActivity }
            loaded = true
        }
    }
}

// MARK: - Clients (roster)

struct RosterView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var filter = "All"

    private var filtered: [RosterItem] {
        store.roster.filter { c in
            let q = query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || c.goal.localizedCaseInsensitiveContains(query)
            let f: Bool = filter.hasPrefix("Needs") ? c.needsAttention : (filter.hasPrefix("Going") ? c.isDrifting : true)
            return q && f
        }
    }

    var body: some View {
        let needs = store.roster.filter { $0.needsAttention }.count
        let quiet = store.roster.filter { $0.isDrifting }.count
        let options: [(label: String, color: Color)] = [("All · \(store.roster.count)", Brand.volt),
                                                         ("Needs you · \(needs)", Brand.volt),
                                                         ("Going quiet · \(quiet)", .orange)]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DSScreenHeader(eyebrow: "Roster", title: "Clients",
                               subtitle: "Everyone you coach, sorted by who needs you most.")
                CoachSearchField(prompt: "Search clients", text: $query)
                CoachFilterChips(options: options, selected: Binding(
                    get: { options.first { $0.label.hasPrefix(filter) }?.label ?? options[0].label },
                    set: { filter = $0.components(separatedBy: " ·").first ?? "All" }))

                if store.rosterLoading && store.roster.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(filtered) { c in
                    Button { store.selectedClient = c } label: { CoachRosterRow(item: c) }
                        .buttonStyle(PressableStyle())
                }
                if !store.rosterLoading && filtered.isEmpty {
                    Text(store.roster.isEmpty ? "No active clients yet." : "No clients match.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable { store.loadRoster() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }
}

struct CoachRosterRow: View {
    let item: RosterItem

    var body: some View {
        HStack(spacing: 12) {
            CoachAvatar(name: item.name, size: 44, highlighted: item.needsAttention)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                    Circle().fill(item.statusColor).frame(width: 7, height: 7)
                }
                if !item.goal.isEmpty { Text(item.goal).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1) }
                Text(item.headline).font(BrandFont.body(12, .bold))
                    .foregroundColor(item.needsAttention ? Brand.voltText : (item.isDrifting ? .orange : Brand.mute))
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if item.unreadMessages > 0 { pill("\(item.unreadMessages)", "bubble.left.fill") }
                if item.pendingCheckIns > 0 { pill("\(item.pendingCheckIns)", "checkmark.square.fill") }
                if item.recentAwards > 0 { pill("\(item.recentAwards)", "trophy.fill") }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func pill(_ n: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(n).font(BrandFont.body(11, .heavy))
        }
        .foregroundColor(Brand.onVolt)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Brand.volt))
    }
}

// MARK: - Wins

struct WinsFeedView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var congrats = CongratsLog.shared
    @State private var filter = "All"
    @State private var compose: CoachCompose?

    var body: some View {
        let all = CoachWins.build(awards: store.recentAwards, days: 30)
        let shown = filter == "Not congratulated" ? all.filter { !congrats.done.contains($0.id) } : all
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DSScreenHeader(eyebrow: "Celebrate them", title: "Wins",
                               subtitle: "Awards earned across your roster · last 30 days")
                CoachFilterChips(options: [("All", Brand.volt), ("Not congratulated", Brand.volt)], selected: $filter)
                if store.rosterLoading && all.isEmpty {
                    ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                } else if shown.isEmpty {
                    Text(all.isEmpty ? "No awards in the last 30 days yet." : "Everyone's been congratulated.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(shown) { w in card(w) }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .refreshable { store.loadRoster() }
        .sheet(item: $compose) { c in
            CoachComposeSheet(title: c.title, subtitle: c.subtitle, clientId: c.clientId, starters: c.starters,
                              initial: c.initial) { if let w = c.winId { congrats.mark(w) } }
        }
    }

    private func card(_ w: CoachWin) -> some View {
        let done = congrats.done.contains(w.id)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if let c = store.roster.first(where: { $0.id == w.clientId }) { store.selectedClient = c }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: w.icon).font(.system(size: 18, weight: .bold)).foregroundColor(Brand.onVolt)
                        .frame(width: 44, height: 44).background(Circle().fill(Brand.volt))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.clientName.uppercased())
                            .font(BrandFont.body(10, .heavy)).tracking(1).headerPill()
                        Text(w.title).font(BrandFont.body(18, .heavy)).foregroundColor(Brand.text)
                        Text(w.detail).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Text(w.date.formatted(.dateTime.month(.abbreviated).day())).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if done {
                Label("Congratulated", systemImage: "checkmark").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
            } else {
                HStack { CoachActionPill(title: "Send congrats", icon: "sparkles") { compose = congratsCompose(w) }; Spacer() }
            }
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(done ? Brand.line : Brand.voltLine.opacity(0.45), lineWidth: 1))
    }
}

// MARK: - Me (coach settings)

struct TrainerMeView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    CoachAvatar(name: store.trainerName.isEmpty ? "Coach" : store.trainerName, size: 64, highlighted: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("COACH").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        Text(store.trainerName.isEmpty ? "Coach" : store.trainerName)
                            .font(BrandFont.display(38)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .padding(.top, 52)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.system(size: 18)).foregroundColor(Brand.voltText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Build programs on the web").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                        Text("Programs, macros and supplement protocols live in the web console — there's room there for the calendar and set editor.")
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                        Text("bigscherlytraining.com/admin").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.voltText)
                    }
                }
                .card(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "NOTIFICATIONS")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        DSListRow(title: "Notification settings",
                                  subtitle: "You're notified about new messages, check-ins and more. Choose how in iOS Settings.",
                                  icon: "bell.badge.fill")
                    }
                    .buttonStyle(PressableStyle())
                }

                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "PREFERENCES")
                    VStack(spacing: 14) {
                        HStack {
                            Text("Units").font(BrandFont.body(15)).foregroundColor(Brand.text)
                            Spacer()
                            Picker("Units", selection: $units) { Text("lb").tag("lb"); Text("kg").tag("kg") }
                                .pickerStyle(.segmented).fixedSize()
                        }
                        HStack {
                            Text("Week starts").font(BrandFont.body(15)).foregroundColor(Brand.text)
                            Spacer()
                            Text("Monday").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                        }
                    }
                    .card(padding: 16)
                }

                Button { store.logout() } label: { Text("Log out") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))

                Text("Big Scherly Training  ·  v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
    }
}
