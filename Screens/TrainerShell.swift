import SwiftUI

// The coach screens. They live inside the app's own shell (MainShell) — the COACH
// group at the top of the menu — so a coach trains with the same app as his clients.

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
    /// The progression engine's changes from the last 3 days (Programs).
    @State private var autoChanges: [APIProgressionChange] = []
    @State private var movesReload = 0

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
                        // Same paged-card mechanism as the client's Insights row:
                        // one card ~82% wide, neighbours peeking, snaps card-by-card.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(weekWins) { w in
                                    winCard(w)
                                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.82 }
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollClipDisabled()
                    }
                    .staggeredAppear(5)
                }

                MovedSessionsSection(reloadKey: movesReload)   // calendar moves (Oct 8, 2026)

                if !autoChanges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "AUTOMATIC CHANGES", subtitle: "last 3 days")
                        ForEach(autoChanges.prefix(3)) { c in ProgressionChangeRow(change: c) }
                        if autoChanges.count > 3 {
                            Button { store.select(.coachPrograms) } label: {
                                Text("All \(autoChanges.count) in Programs").font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                            }
                        }
                    }
                    .staggeredAppear(6)
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
        .task { autoChanges = (try? await APIClient.shared.progressionChanges(days: 3))?.filter { $0.undoneAt == nil } ?? [] }
        .refreshable {
            store.loadRoster()
            movesReload += 1
            autoChanges = (try? await APIClient.shared.progressionChanges(days: 3))?.filter { $0.undoneAt == nil } ?? []
        }
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

