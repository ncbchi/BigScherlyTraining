import SwiftUI

// MARK: - Coach HQ on iPad: the shell (Oct 8, 2026)
//
// A coach on an iPad (regular width) gets this instead of MainShell: a black sidebar with the
// Coach HQ sections on the left and the section on the right. Today, Inbox, Check-ins and
// Calendar are built in the Platform design; the other sections show the app's coach screens
// inside this layout until their boards are drawn. Review 1 (Oct 9): the sidebar no longer folds
// by itself. The coach hides and shows it with the sidebar button (remembered); it closes on its own
// only when a client is opened in Clients (to its icon rail), and comes back when they return to the roster. Under
// 1100 points wide it slides over the page.
// Synchronized folder: no target step needed.

enum PadSection: String, CaseIterable, Identifiable {
    case today, clients, checkins, inbox, programs, calendar, library, wins, insights, announcements, notebook, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .clients: return "Clients"
        case .checkins: return "Check-ins"
        case .inbox: return "Inbox"
        case .programs: return "Programs"
        case .calendar: return "Calendar"
        case .library: return "Library"
        case .wins: return "Wins"
        case .insights: return "Insights"
        case .announcements: return "Announcements"
        case .notebook: return "Notebook"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .clients: return "person.2"
        case .checkins: return "checkmark.square"
        case .inbox: return "bubble.left"
        case .programs: return "list.bullet.rectangle"
        case .calendar: return "calendar"
        case .library: return "books.vertical"
        case .wins: return "trophy"
        case .insights: return "chart.bar"
        case .announcements: return "megaphone"
        case .notebook: return "book.closed"
        case .settings: return "gearshape"
        }
    }

    static let groups: [(name: String, items: [PadSection])] = [
        ("Coaching", [.today, .clients, .checkins, .inbox]),
        ("Planning", [.programs, .calendar, .library]),
        ("Results", [.wins, .insights, .announcements]),
        ("You", [.notebook, .settings])
    ]

    /// The matching phone tab, so the app's coach screens keep working when they jump around.
    var appTab: AppTab? {
        switch self {
        case .today: return .coachToday
        case .clients: return .coachClients
        case .checkins: return .coachCheckins
        case .inbox: return .coachChat
        case .programs: return .coachPrograms
        case .wins: return .coachWins
        case .insights: return .coachInsights
        case .announcements: return .coachAnnounce
        case .notebook: return .coachNotebook
        case .settings: return .settings
        case .calendar, .library: return nil
        }
    }
    static func from(_ tab: AppTab) -> PadSection? {
        PadSection.allCases.first { $0.appTab == tab }
    }
}

struct CoachPadShell: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @AppStorage("bst_pad_section") private var sectionRaw = PadSection.today.rawValue
    @State private var sidebarOpen = false
    @AppStorage("bst_pad_sidebar_hidden") private var sidebarHidden = false
    @State private var autoHidden = false     // hidden by opening a client, not by the coach
    @State private var searchOpen = false
    @State private var newWorkoutPick = false
    @State private var newWorkoutFor: RosterItem?
    @State private var broadcast = false

    private var section: PadSection {
        get { PadSection(rawValue: sectionRaw) ?? .today }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    var body: some View {
        GeometryReader { g in
            let sideBySide = g.size.width >= Pad.sideBySideMin
            ZStack {
                Pad.page.ignoresSafeArea()
                HStack(spacing: 0) {
                    if sideBySide && !sidebarHidden {
                        if autoHidden {
                            // A client is open in Clients: the sidebar folds to its icon rail (review 1, Oct 9).
                            PadRail(section: sectionBinding, counts: counts, onSearch: { searchOpen = true },
                                    onExpand: { toggleSidebar(sideBySide) })
                                .transition(.move(edge: .leading))
                        } else {
                            PadSidebar(section: sectionBinding, counts: counts, onSearch: { searchOpen = true })
                                .frame(width: Pad.sidebarWidth)
                                .transition(.move(edge: .leading))
                        }
                        Rectangle().fill(Pad.railLine).frame(width: 1).ignoresSafeArea()
                    }
                    content(sideBySide: sideBySide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The sidebar over the page (portrait, or a folded rail asked to expand).
                if sidebarOpen {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                    HStack(spacing: 0) {
                        PadSidebar(section: Binding(get: { section }, set: { section = $0; close() }),
                                   counts: counts, onSearch: { close(); searchOpen = true })
                            .frame(width: 300)
                            .shadow(color: .black.opacity(0.5), radius: 30, x: 12, y: 0)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                    .transition(.move(edge: .leading))
                }
                PadToastHost()
            }
            .environment(\.padSideBySide, sideBySide)
            .environment(\.padSidebarShown, sideBySide && !sidebarHidden && !autoHidden)
            .environment(\.padOpenSidebar, PadAction { toggleSidebar(sideBySide) })
            .environment(\.padSidebarAuto, PadSidebarAuto(
                // Only ever touches autoHidden: the coach's own choice (sidebarHidden) is never overwritten.
                hide: { if sideBySide && !sidebarHidden && !autoHidden { withAnimation(.easeOut(duration: 0.22)) { autoHidden = true } } },
                restore: { if autoHidden { withAnimation(.easeOut(duration: 0.22)) { autoHidden = false } } }))
            .environment(\.padNewWorkout, PadAction { newWorkoutPick = true })
            .environment(\.padBroadcast, PadAction { broadcast = true })
            .environment(\.padGo, PadGo { section = $0 })
            .onChange(of: sideBySide) { _, now in if now { sidebarOpen = false } }
            .background(
                Button("Show or hide the sidebar") { toggleSidebar(sideBySide) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
        }
        .background(Pad.page.ignoresSafeArea())
        // Keyboard: ⌘K search, ⌘1…⌘9 sections, ⌘⇧S sidebar. Hold ⌘ on a keyboard to see them.
        .background(keyCommands)
        // Coach: anything that opens a client (Today, Inbox, Calendar, search, the app's own coach
        // screens) now opens them in the Clients workspace instead of a sheet.
        .onChange(of: store.selectedClient?.id) { _, id in
            guard let id else { return }
            PadNav.shared.clientId = id
            store.selectedClient = nil
            if section != .clients { section = .clients }
        }
        .fullScreenCover(item: $store.awardToCelebrate) { award in AwardCelebrationView(award: award) }
        .sheet(isPresented: $searchOpen) { PadSearchSheet { section = $0 } }
        .sheet(isPresented: $newWorkoutPick) {
            ClientPickerSheet { c in
                newWorkoutPick = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { newWorkoutFor = c }
            }
        }
        .sheet(item: $newWorkoutFor) { c in
            WorkoutBuilderView(clientId: c.id, clientName: c.name) { Task { await data.refresh(roster: store.roster) } }
        }
        .sheet(isPresented: $broadcast) { PadBroadcastSheet() }
        .onAppear {
            if store.roster.isEmpty { store.loadRoster() }
            Task { await data.refresh(roster: store.roster) }
            data.startAuto(store: store)
            if let t = section.appTab, store.activeTab != t { store.activeTab = t }
        }
        .onDisappear { data.stopAuto() }
        .onChange(of: store.roster.map { $0.id }) { _, _ in Task { await data.refresh(roster: store.roster) } }
        // The app's own coach screens navigate with store.select(.coachPrograms) etc.: follow them.
        .onChange(of: store.activeTab) { _, t in
            if let s = PadSection.from(t), s != section { section = s }
        }
        .onChange(of: sectionRaw) { _, _ in
            if let t = section.appTab, store.activeTab != t { store.activeTab = t }
            // Leaving Clients while a client had closed the sidebar: bring it back.
            if section != .clients, autoHidden { withAnimation(.easeOut(duration: 0.22)) { autoHidden = false } }
        }
        .tint(Pad.voltText)
    }

    private var sectionBinding: Binding<PadSection> {
        Binding(get: { section }, set: { section = $0 })
    }

    private func close() { withAnimation(.easeOut(duration: 0.18)) { sidebarOpen = false } }

    /// The sidebar button: side by side it hides/shows the sidebar (remembered); narrower, it slides over.
    private func toggleSidebar(_ sideBySide: Bool) {
        if sideBySide {
            // Hidden by a client: the button just brings it back (and leaves the coach's setting alone).
            if autoHidden { withAnimation(.easeOut(duration: 0.22)) { autoHidden = false } }
            else { withAnimation(.easeOut(duration: 0.22)) { sidebarHidden.toggle() } }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { sidebarOpen.toggle() }
        }
    }

    private var counts: [PadSection: Int] {
        [.checkins: store.pendingCheckInCount, .inbox: store.totalUnread]
    }

    @ViewBuilder
    private func content(sideBySide: Bool) -> some View {
        switch section {
        case .today: PadTodayView()
        case .inbox: PadInboxView()
        case .checkins: PadCheckInsView()
        case .calendar: PadCalendarView()
        case .library: PadLibraryView()
        case .clients: PadClientsView()
        case .programs: PadLegacyHost(title: "Programs") { NavigationStack { CoachProgramsView() } }
        case .wins: PadLegacyHost(title: "Wins") { WinsFeedView() }
        case .insights: PadLegacyHost(title: "Insights") { TrainerInsightsView() }
        case .announcements: PadLegacyHost(title: "Announcements") { AnnouncementsComposerView() }
        case .notebook: PadLegacyHost(title: "Notebook") { NavigationStack { CoachNotebookView() } }
        case .settings: PadLegacyHost(title: "Settings") { SettingsView() }
        }
    }

    /// Invisible buttons carrying the shortcuts (they show in the ⌘ overlay on a hardware keyboard).
    private var keyCommands: some View {
        Group {
            Button("Search everything") { searchOpen = true }.keyboardShortcut("k", modifiers: .command)
            Button("New workout") { newWorkoutPick = true }.keyboardShortcut("n", modifiers: .command)
            ForEach(Array(PadSection.allCases.prefix(9).enumerated()), id: \.offset) { i, s in
                Button(s.title) { section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

// MARK: - Environment plumbing

struct PadAction { let run: () -> Void; func callAsFunction() { run() } }
struct PadGo { let run: (PadSection) -> Void; func callAsFunction(_ s: PadSection) { run(s) } }

private struct PadSideBySideKey: EnvironmentKey { static let defaultValue = true }
private struct PadOpenSidebarKey: EnvironmentKey { static let defaultValue = PadAction {} }
private struct PadNewWorkoutKey: EnvironmentKey { static let defaultValue = PadAction {} }
private struct PadBroadcastKey: EnvironmentKey { static let defaultValue = PadAction {} }
private struct PadGoKey: EnvironmentKey { static let defaultValue = PadGo { _ in } }
private struct PadSidebarShownKey: EnvironmentKey { static let defaultValue = true }
private struct PadSidebarAutoKey: EnvironmentKey { static let defaultValue = PadSidebarAuto(hide: {}, restore: {}) }

/// Clients closes the sidebar when a client opens, and reopens it on the way back to the roster
/// (only if it was Clients that closed it).
struct PadSidebarAuto { let hide: () -> Void; let restore: () -> Void }

extension EnvironmentValues {
    var padSideBySide: Bool { get { self[PadSideBySideKey.self] } set { self[PadSideBySideKey.self] = newValue } }
    var padOpenSidebar: PadAction { get { self[PadOpenSidebarKey.self] } set { self[PadOpenSidebarKey.self] = newValue } }
    var padNewWorkout: PadAction { get { self[PadNewWorkoutKey.self] } set { self[PadNewWorkoutKey.self] = newValue } }
    var padBroadcast: PadAction { get { self[PadBroadcastKey.self] } set { self[PadBroadcastKey.self] = newValue } }
    var padGo: PadGo { get { self[PadGoKey.self] } set { self[PadGoKey.self] = newValue } }
    var padSidebarShown: Bool { get { self[PadSidebarShownKey.self] } set { self[PadSidebarShownKey.self] = newValue } }
    var padSidebarAuto: PadSidebarAuto { get { self[PadSidebarAutoKey.self] } set { self[PadSidebarAutoKey.self] = newValue } }
}

// MARK: - Page top: the sidebar button, then title, subtitle and actions.

/// The hide/show sidebar button that sits top-left on every page.
struct PadSidebarButton: View {
    @Environment(\.padSidebarShown) private var shown
    @Environment(\.padOpenSidebar) private var toggle
    var body: some View {
        PadIconButton(systemName: "sidebar.left", label: shown ? "Hide the sidebar" : "Show the sidebar", on: shown) { toggle() }
            .help(shown ? "Hide the sidebar (⌘⇧S)" : "Show the sidebar (⌘⇧S)")
    }
}

struct PadPageTop<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleSize: CGFloat = 46
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PadSidebarButton()
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(PadFont.display(titleSize)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    if let subtitle {
                        Text(subtitle).font(PadFont.ui(15)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
            }
        }
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 18)
    }
}

// MARK: - The sidebar (full)

struct PadSidebar: View {
    @EnvironmentObject var store: AppStore
    @Binding var section: PadSection
    let counts: [PadSection: Int]
    var onSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("BIG SCHERLY").font(PadFont.display(28)).foregroundColor(Pad.railText).lineLimit(1).minimumScaleFactor(0.8)
                Text("Coach HQ").font(PadFont.cond(12)).foregroundColor(Pad.volt).tracking(0.4)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            PadKnurl().frame(height: 6)

            Button(action: onSearch) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold))
                    Text("Search everything").font(PadFont.ui(14))
                    Spacer()
                    Text("⌘K").font(PadFont.cond(11)).foregroundColor(Pad.railFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Pad.railLine2, lineWidth: 1))
                }
                .foregroundColor(Pad.railMute)
                .padding(.horizontal, 10).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Pad.railHover))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.railLine2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(PadSection.groups, id: \.name) { g in
                        Text(g.name).font(PadFont.cond(12)).foregroundColor(Pad.railFaint)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(g.items) { s in navRow(s) }
                    }
                }
                .padding(.horizontal, 8)
            }

            HStack(spacing: 10) {
                PadAvatar(name: store.trainerName.isEmpty ? store.client.name : store.trainerName, size: 34, onRail: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.trainerName.isEmpty ? store.client.name : store.trainerName).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.railText).lineLimit(1)
                    Text(store.roster.count.plural("client")).font(PadFont.ui(12)).foregroundColor(Pad.railFaint)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            .overlay(alignment: .top) { Rectangle().fill(Pad.railLine).frame(height: 1) }
        }
        .background(Pad.rail.ignoresSafeArea())
    }

    private func navRow(_ s: PadSection) -> some View {
        let on = s == section
        let n = counts[s] ?? 0
        return Button { section = s } label: {
            HStack(spacing: 11) {
                Image(systemName: s.icon).font(.system(size: 17, weight: .medium)).frame(width: 22)
                Text(s.title).font(PadFont.ui(15, .semibold))
                Spacer(minLength: 0)
                if n > 0 {
                    Text("\(n)").font(PadFont.cond(11, .bold)).foregroundColor(Pad.onVolt)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Pad.volt))
                }
            }
            .foregroundColor(on ? Pad.railText : Pad.railMute)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Pad.railOn : Color.clear))
            .overlay(alignment: .leading) {
                if on { RoundedRectangle(cornerRadius: 1.5).fill(Pad.volt).frame(width: 3).padding(.vertical, 8) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(n > 0 ? "\(s.title), \(n)" : s.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - The sidebar folded to icons

struct PadRail: View {
    @EnvironmentObject var store: AppStore
    @Binding var section: PadSection
    let counts: [PadSection: Int]
    var onSearch: () -> Void
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Text("BS").font(PadFont.display(22)).foregroundColor(Pad.railText)
                    .frame(maxWidth: .infinity).frame(height: 64)
                PadKnurl().frame(height: 5)
            }
            .padding(.bottom, 8)
            railButton("sidebar.left", "Show the sidebar", on: false, count: 0, action: onExpand)
            railButton("magnifyingglass", "Search everything", on: false, count: 0, action: onSearch)
            sep
            ForEach(Array(PadSection.groups.enumerated()), id: \.offset) { i, g in
                if i > 0 { sep }
                ForEach(g.items) { s in
                    railButton(s.icon, s.title, on: s == section, count: counts[s] ?? 0) { section = s }
                }
            }
            Spacer(minLength: 0)
            PadAvatar(name: store.trainerName.isEmpty ? store.client.name : store.trainerName, size: 34, onRail: true)
                .padding(.bottom, 16)
        }
        .frame(width: Pad.railWidth)
        .background(Pad.rail.ignoresSafeArea())
    }

    private var sep: some View { Rectangle().fill(Color.white.opacity(0.09)).frame(width: 28, height: 1).padding(.vertical, 6) }

    private func railButton(_ icon: String, _ label: String, on: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                    .foregroundColor(on ? Pad.railText : Pad.railMute)
                    .frame(width: 52, height: 48)
                if count > 0 {
                    Text("\(count)").font(PadFont.cond(11, .bold)).foregroundColor(Pad.onVolt)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Pad.volt))
                        .offset(x: -3, y: 4)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Pad.railOn : Color.clear))
            .overlay(alignment: .leading) {
                if on { RoundedRectangle(cornerRadius: 1.5).fill(Pad.volt).frame(width: 3).padding(.vertical, 10) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(count > 0 ? "\(label), \(count)" : label)
    }
}

/// The barbell's grip pattern: a thin crosshatch stripe under the brand.
struct PadKnurl: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                p.move(to: CGPoint(x: x + size.height, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                x += 5
            }
            ctx.stroke(p, with: .color(Color.white.opacity(0.16)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The app's own coach screens, inside the iPad layout

struct PadLegacyHost<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.bg.ignoresSafeArea())
            PadSidebarButton().padding(.leading, 16).padding(.top, 8)
        }
    }
}

// MARK: - Search everything (⌘K): clients by name, notebook pages, sections

struct PadSearchSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let go: (PadSection) -> Void
    @State private var q = ""
    @State private var hits: [APINotebookHit] = []
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var clients: [RosterItem] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        return store.roster.filter { $0.name.localizedCaseInsensitiveContains(t) || $0.goal.localizedCaseInsensitiveContains(t) }
    }
    private var sections: [PadSection] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        return PadSection.allCases.filter { $0.title.localizedCaseInsensitiveContains(t) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Pad.mute)
                TextField("Search clients, notes and pages", text: $q)
                    .font(PadFont.ui(17)).foregroundColor(Pad.text).focused($focused)
                    .autocorrectionDisabled().submitLabel(.go)
                    .onSubmit { if let c = clients.first { open(c) } }
                Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            PadRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !clients.isEmpty {
                        PadLab("Clients").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(clients) { c in
                            Button { open(c) } label: {
                                HStack(spacing: 12) {
                                    PadAvatar(name: c.name, size: 34)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                        Text(c.headline).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 18).frame(minHeight: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverEffect(.highlight)
                        }
                    }
                    if !sections.isEmpty {
                        PadLab("Go to").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(sections) { s in
                            Button { go(s); dismiss() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: s.icon).frame(width: 34).foregroundColor(Pad.mute)
                                    Text(s.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                    Spacer()
                                }
                                .padding(.horizontal, 18).frame(minHeight: 48).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverEffect(.highlight)
                        }
                    }
                    if !hits.isEmpty {
                        PadLab("Notebook").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(hits) { h in
                            Button { go(.notebook); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.title.isEmpty ? "Untitled" : h.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                    Text("\(h.binderName) · \(h.snippet)").font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.vertical, 10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverEffect(.highlight)
                        }
                    }
                    if q.trimmingCharacters(in: .whitespaces).count >= 2 && clients.isEmpty && sections.isEmpty && hits.isEmpty {
                        Text("Nothing matches.").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(18)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .onAppear { focused = true }
        .onChange(of: q) { _, t in
            task?.cancel()
            let s = t.trimmingCharacters(in: .whitespaces)
            guard s.count >= 2 else { hits = []; return }
            task = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let r = (try? await APIClient.shared.notebookSearch(s)) ?? []
                if !Task.isCancelled { hits = r }
            }
        }
    }

    private func open(_ c: RosterItem) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.selectedClient = c } }
}

// MARK: - Message everyone

struct PadBroadcastSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var failed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Message everyone").font(PadFont.display(30)).foregroundColor(Pad.text)
                Spacer()
                Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute).keyboardShortcut(.cancelAction)
            }
            Text("Lands in each client's latest conversation as a message from you. For a post on everyone's Home, use Announcements.")
                .font(PadFont.ui(14)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
            QuickReplies { text = $0 }
            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 140).padInput(multiline: true)
            if failed > 0 { Text("\(failed) didn't send. Check your connection and try again.").font(PadFont.ui(13)).foregroundColor(Pad.orange) }
            HStack {
                Spacer()
                Button {
                    send()
                } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(Pad.onVolt) }
                        Text("Send to \(store.roster.count.plural("client"))")
                    }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func send() {
        sending = true; failed = 0
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = store.roster.map { $0.id }
        Task {
            var bad = 0
            for id in ids {
                do { try await CoachMessenger.send(t, to: id) } catch { bad += 1 }
            }
            await MainActor.run {
                sending = false; failed = bad
                if bad == 0 { PadToasts.shared.show("Sent to \(ids.count.plural("client"))"); dismiss() }
            }
        }
    }
}
