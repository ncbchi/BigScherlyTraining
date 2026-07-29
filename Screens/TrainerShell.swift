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
                                .font(BrandFont.display(28)).foregroundColor(.white)
                            Text("Coach dashboard").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.volt)
                        }
                        Spacer()
                        Button { withAnimation { store.showTray = false } } label: {
                            Image(systemName: "xmark").foregroundColor(.white).font(.system(size: 18, weight: .bold))
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
                                            .foregroundColor(store.trainerTab == tab ? Brand.volt : Brand.mute)
                                            .frame(width: 24)
                                        Text(tab.rawValue)
                                            .font(BrandFont.body(15, store.trainerTab == tab ? .bold : .semibold))
                                            .foregroundColor(store.trainerTab == tab ? .white : Brand.mute)
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
        Text("\(n)").font(BrandFont.body(10, .bold)).foregroundColor(Brand.black)
            .frame(minWidth: 18, minHeight: 18)
            .background(Circle().fill(Brand.volt))
    }
}

// MARK: - Roster (triage)

struct RosterView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var filter: RosterFilter = .all

    enum RosterFilter: String, CaseIterable, Identifiable {
        case all = "All", attention = "Needs You", drifting = "Drifting"
        var id: String { rawValue }
    }

    private var filtered: [RosterItem] {
        store.roster.filter { c in
            let matchesQuery = query.isEmpty ||
                c.name.localizedCaseInsensitiveContains(query) ||
                c.goal.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool = {
                switch filter {
                case .all:       return true
                case .attention: return c.needsAttention
                case .drifting:  return c.isDrifting
                }
            }()
            return matchesQuery && matchesFilter
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Your Roster")
                Text("Clients").font(BrandFont.display(44)).foregroundColor(.white)

                if store.attentionCount > 0 {
                    Text("\(store.attentionCount) need\(store.attentionCount == 1 ? "s" : "") you")
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.volt)
                } else if !store.roster.isEmpty {
                    Text("All caught up.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }

                // Search + filter — matters once the roster grows past a handful.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.mute).font(.system(size: 14))
                    TextField("Search clients…", text: $query)
                        .font(BrandFont.body(14)).foregroundColor(.white)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Brand.mute)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                HStack(spacing: 8) {
                    ForEach(RosterFilter.allCases) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue)
                                .font(BrandFont.body(12, .semibold))
                                .foregroundColor(filter == f ? Brand.black : Brand.mute)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(filter == f ? Brand.volt : Brand.black).clipShape(Capsule())
                                .overlay(Capsule().stroke(filter == f ? Brand.volt : Brand.line, lineWidth: 1))
                        }
                    }
                }

                if store.rosterLoading && store.roster.isEmpty {
                    ProgressView().tint(Brand.volt)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }

                ForEach(filtered) { c in
                    Button { store.selectedClient = c } label: {
                        RosterRow(item: c)
                    }
                }

                if !store.rosterLoading && filtered.isEmpty {
                    Text(store.roster.isEmpty ? "No active clients yet." : "No clients match.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
        .sheet(item: $store.selectedClient) { c in
            TrainerClientView(client: c)
        }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }
}

struct RosterRow: View {
    let item: RosterItem

    var body: some View {
        HStack(spacing: 14) {
            // Status stripe — volt = needs you, amber = drifting, grey = fine.
            Rectangle()
                .fill(item.statusColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(BrandFont.body(16, .bold)).foregroundColor(.white)
                Text(item.headline)
                    .font(BrandFont.body(12))
                    .foregroundColor(item.needsAttention ? Brand.volt
                                     : item.isDrifting ? .orange : Brand.mute)
            }
            Spacer()

            HStack(spacing: 6) {
                if item.unreadMessages > 0 {
                    countPill("\(item.unreadMessages)", "message.fill")
                }
                if item.pendingCheckIns > 0 {
                    countPill("\(item.pendingCheckIns)", "checkmark.square.fill")
                }
                if item.recentAwards > 0 {
                    countPill("\(item.recentAwards)", "trophy.fill")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12)).foregroundColor(Brand.mute)
            }
        }
        .padding(.vertical, 14).padding(.trailing, 14)
        .background(Brand.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func countPill(_ n: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(n).font(BrandFont.body(11, .bold))
        }
        .foregroundColor(Brand.black)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Brand.volt).clipShape(Capsule())
    }
}

// MARK: - Wins feed (celebrate)

struct WinsFeedView: View {
    @EnvironmentObject var store: AppStore
    @State private var congratsFor: RosterAward?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Celebrate Them")
                Text("Wins").font(BrandFont.display(44)).foregroundColor(.white)
                Text("Awards earned across your roster in the last 30 days.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                if store.recentAwards.isEmpty {
                    Text("No awards yet this month.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }

                ForEach(store.recentAwards) { a in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Circle().fill(Brand.volt)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Image(systemName: a.icon)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(Brand.black)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.clientName)
                                    .font(BrandFont.body(15, .bold)).foregroundColor(.white)
                                Text(a.title)
                                    .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.volt)
                            }
                            Spacer()
                            Text(a.earnedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                        Text(a.blurb)
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)

                        Button {
                            congratsFor = a
                        } label: {
                            Text("Send congrats")
                                .font(BrandFont.body(13, .bold))
                                .foregroundColor(Brand.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Brand.volt).clipShape(Capsule())
                        }
                    }
                    .padding(16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))
                }
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { store.loadRoster() }
        .sheet(item: $congratsFor) { a in
            CongratsComposer(award: a)
        }
    }
}

// One-tap congratulations, prefilled but editable.
struct CongratsComposer: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let award: RosterAward

    @State private var text = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity).padding(.top, 10)

            Text("Congratulate \(award.clientName)")
                .font(BrandFont.display(28)).foregroundColor(.white)
            Text(award.title)
                .font(BrandFont.body(12, .bold)).tracking(1.2).foregroundColor(Brand.volt)

            TextEditor(text: $text)
                .font(BrandFont.body(15))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 120)
                .background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

            if failed {
                Text("Couldn't send. Try again.")
                    .font(BrandFont.body(12)).foregroundColor(.orange)
            }

            Button {
                send()
            } label: {
                HStack {
                    if sending { ProgressView().tint(Brand.black) }
                    Text(sent ? "Sent" : "Send").font(BrandFont.body(15, .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
            }
            .disabled(sending || sent || text.isEmpty)

            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
        .onAppear {
            text = "Congrats on \(award.title), \(award.clientName)! 👏 Huge work — keep it rolling."
        }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
    }

    private func send() {
        sending = true; failed = false
        Task {
            do {
                // Find (or fall back gracefully on) the client's thread.
                let threads = try await APIClient.shared.trainerChats(clientId: award.clientId)
                guard let t = threads.first else {
                    await MainActor.run { sending = false; failed = true }
                    return
                }
                try await APIClient.shared.trainerSendMessage(threadId: t.id, text: text)
                await MainActor.run {
                    sending = false; sent = true
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { sending = false; failed = true }
            }
        }
    }
}

// MARK: - Me (trainer settings)

struct TrainerMeView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Coach")
                Text(store.trainerName.isEmpty ? "Coach" : store.trainerName)
                    .font(BrandFont.display(44)).foregroundColor(.white)

                VStack(alignment: .leading, spacing: 10) {
                    Text("BUILDING PROGRAMS")
                        .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    Text("Programs, macros, and supplement protocols are built in the web console — there's room there for the calendar and the set editor. This app is for keeping up with your clients between sessions.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    Text("bigscherlytraining.com/admin")
                        .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.volt)
                }
                .padding(16)
                .background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                Button {
                    store.logout()
                } label: {
                    Text("Log out")
                        .font(BrandFont.body(15, .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }
                .padding(.top, 10)
            }
            .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
    }
}
