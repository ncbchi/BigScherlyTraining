import SwiftUI

// MARK: - App entry point
@main
struct BigScherlyTrainingApp: App {
    // One store for the app's lifetime. Created here (not lazily by SwiftUI) so a
    // Lock Screen Live Activity button can log a set even when iOS launches the app
    // in the background just to run it.
    @StateObject private var store = AppStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate     // push: iOS hands the token here

    init() {
        BrandFont.registerFonts()                          // the display face, before anything draws
        LiveSessionController.shared.attach(AppStore.shared)
        WidgetBridge.shared.attach(AppStore.shared)        // keeps Home & Lock Screen widgets current
    }

    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ThemeHost {
                RootView().environmentObject(store)                  // Settings ▸ Appearance
                    // Push: register on launch too — a saved session is restored without login().
                    .task { PushCenter.shared.start(store) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep the Watch's glance + complication current whenever the phone
            // comes to the foreground.
            if phase == .active {
                WidgetBridge.shared.mergeWidgetTicks()        // supplements ticked on a widget → your log
                store.syncToWatch()
                ServerSync.shared.flushSoon(after: 1)   // send anything queued while away/offline
                PushCenter.shared.start(store)          // keep this phone registered for notifications
                LocalReminders.refresh(store)           // check-in and workout reminders
                LiveSessionController.shared.appBecameActive()     // card back if closed; rest alerts here
            } else if phase == .background {
                LiveSessionController.shared.appWentToBackground() // rest alerts go into the card
            }
        }
    }
}

// MARK: - Root routing
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showBoard = true
    @State private var showSplash = true

    /// Coach HQ on iPad (Oct 8, 2026): a coach on an iPad with room for a sidebar gets the
    /// split layout. In a narrow Split View window (compact width) it's the phone layout.
    private var padLayout: Bool { UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular }

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            if !store.isLoggedIn {
                LoginView()
            } else if store.isTrainer && padLayout {
                CoachPadShell().id(theme.signature(scheme))
            } else if store.isTrainer {
                // Coaches get the same app as everyone else — they train too — with the
                // COACH group of screens added to the top of the menu.
                MainShell().id(theme.signature(scheme))   // redraw once on a theme change
            } else if store.mustChangePassword {
                SetPasswordView()
            } else if showBoard {
                WelcomeBoardView(showBoard: $showBoard)
            } else {
                MainShell().id(theme.signature(scheme))
            }

            // Animated splash sits on top at launch, then fades to reveal login
            if showSplash {
                SplashView { withAnimation(.easeInOut(duration: 0.4)) { showSplash = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onChange(of: store.isLoggedIn) { _, newValue in
            if newValue { showBoard = true }   // show board fresh on each login
        }
        .plateCalculatorHost()        // Tools ▸ Plate calculator and the set-card barbell open here
        // A widget was tapped: skip the welcome board and go where it points.
        .onOpenURL { url in
            showBoard = false
            WidgetBridge.shared.handle(url)
        }
    }
}

// MARK: - Main shell (top bar + active screen + tray overlay)
struct MainShell: View {
    @EnvironmentObject var store: AppStore
    // Settings ▸ Navigation ▸ Hand. Right-handed: back on the left edge, menu on the right.
    @AppStorage("bst_hand") private var hand = "right"
    @State private var pendingAnnouncements: [Announcement] = []
    @State private var showAnnouncement = false
    @State private var snoozedAnnouncements: Set<String> = []
    // Edge swipe back: how far the current screen has been pulled, and how wide it is.
    @State private var backDrag: CGFloat = 0
    @State private var shellWidth: CGFloat = 390

    private var leftHanded: Bool { hand == "left" }
    /// Back lives on the leading edge for a right-handed grip, the trailing edge for a left-handed one.
    private var backOnLeading: Bool { !leftHanded }
    private var backDragging: Bool { abs(backDrag) > 1 }
    private var backProgress: CGFloat { min(1, abs(backDrag) / max(shellWidth, 1)) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Brand.bg.ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    if w > 1 { shellWidth = w }
                }

            // The screens, as a keyed list: normally just the active one. During a back
            // swipe the screen we're heading to is laid underneath as well. Keying by tab
            // means that when the swipe commits, the revealed screen simply *becomes* the
            // active one — same instance, no rebuild, no second entrance animation.
            ForEach(layers, id: \.self) { tab in
                let isActive = tab == store.activeTab
                screen(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(isActive ? 1 : 0.94 + 0.06 * backProgress,
                                 anchor: backOnLeading ? .leading : .trailing)
                    .opacity(isActive ? 1 : 0.9 + 0.1 * backProgress)
                    .offset(x: isActive ? backDrag : 0)
                    .allowsHitTesting(isActive)
                    // Each screen is its own identity, so the transition fires (and
                    // per-screen entrance animations replay) on every navigation.
                    // Direction comes from store.tabForward.
                    .transition(.asymmetric(
                        insertion: .move(edge: store.tabForward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: store.tabForward ? .leading : .trailing)
                            .combined(with: .opacity)
                    ))
            }

            // The seam of the page swiping away: a soft shadow strip and the tag riding
            // it — half on, half off. Drawn as cheap flat shapes, not a view shadow.
            if backDragging, let target = store.backTarget {
                GeometryReader { g in
                    seamShadow
                        .frame(width: 28, height: g.size.height)
                        .position(x: seamX + (backOnLeading ? -14 : 14), y: g.size.height / 2)
                    backTag(target)
                        .position(x: seamX, y: g.size.height * 0.46)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Edge swipe -> back one screen, from any screen with somewhere to go.
            //
            // A narrow strip pinned to one edge, so it can't steal drags from the
            // content (scroll views, RPE buttons, the share card, etc). It only
            // listens where a system edge-swipe would start anyway.
            EdgeSwipeCatcher(edge: backOnLeading ? .leading : .trailing,
                             onChanged: { dx in
                                 guard store.backTarget != nil, store.sessionWorkoutId == nil || store.sessionMinimized else { return }
                                 backDrag = backOnLeading ? max(0, dx) : min(0, dx)
                             },
                             onEnded: { dx, predicted in
                                 guard backDragging else { backDrag = 0; return }
                                 let far = abs(dx) > shellWidth * 0.28
                                 let flick = abs(predicted) > 220
                                 if far || flick { commitBack() } else { cancelBack() }
                             })

            // Edge swipe -> open the menu, from any screen. Opposite edge to back.
            EdgeSwipeCatcher(edge: backOnLeading ? .trailing : .leading,
                             onChanged: { _ in },
                             onEnded: { dx, _ in
                                 // Pulled away from its edge, and far enough to mean it.
                                 let inward = backOnLeading ? -dx : dx
                                 if inward > 25 {
                                     withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                         store.showTray = true
                                     }
                                 }
                             })

            // Floating menu button, upper right, over the content. Not on Share: the editor's
            // tools live there (the menu still opens with the edge swipe).
            if store.activeTab != .share && store.activeTab != .coachShare {
                FloatingMenuButton()
                    .padding(.trailing, 16)
                    .padding(.top, 8)
            }

            NavTray()

            // The docked workout: the live bar at the bottom while you get on with
            // something else. The card itself is a full-screen cover (below).
            if let id = store.sessionWorkoutId, store.sessionMinimized {
                WorkoutDockHost(workoutId: id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }

            if showAnnouncement {
                NewAnnouncementSheet(items: pendingAnnouncements) { dismissAnnouncements() }
                    .zIndex(30)
            }
        }
        // The workout card: its own presentation, like it always was — so it stays
        // smooth whatever is underneath. Minimising dismisses it to the dock above.
        .fullScreenCover(isPresented: Binding(
            get: { store.sessionWorkoutId != nil && !store.sessionMinimized },
            set: { if !$0, store.sessionWorkoutId != nil { store.sessionMinimized = true } }
        )) {
            if let id = store.sessionWorkoutId {
                WorkoutSessionCard(workoutId: id)
            }
        }
        // Award celebrations are app-wide: earning one shouldn't depend on which
        // screen happened to be open when it landed.
        .fullScreenCover(item: $store.awardToCelebrate) { award in
            AwardCelebrationView(award: award)
        }
        // Coach: one place opens a client's profile, from any coach screen.
        .sheet(item: $store.selectedClient) { c in TrainerClientView(client: c) }
        .onAppear { if store.isTrainer && store.roster.isEmpty { store.loadRoster() } }
        // A new coach announcement pulls up from the bottom shortly after the app opens.
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            presentNewAnnouncements()
        }
        .onChange(of: store.liveAnnouncements.map { $0.id }) { _, _ in presentNewAnnouncements() }
        .onChange(of: store.prToCelebrate?.id) { _, _ in presentNewAnnouncements() }
        .onChange(of: store.awardToCelebrate?.id) { _, _ in presentNewAnnouncements() }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard: DashboardView()
        case .workouts: WorkoutsView()
        case .history: StatsView()
        case .macros: MacrosView()
        case .supplements: SupplementsView()
        case .awards: AwardsView()
        case .checkins: CheckInsView()
        case .photos: PhotosView()
        case .chat: ChatListView()
        case .announcements: AnnouncementsView()
        case .share: ShareView()
        case .settings: SettingsView()
        // Coach screens
        case .coachToday: TrainerTodayView()
        case .coachClients: RosterView()
        case .coachPrograms: NavigationStack { CoachProgramsView() }
        case .coachNotebook: NavigationStack { CoachNotebookView() }
        case .coachChat: NavigationStack { TrainerChatSection() }
        case .coachCheckins: CheckInQueueView()
        case .coachWins: WinsFeedView()
        case .coachInsights: TrainerInsightsView()
        case .coachAnnounce: AnnouncementsComposerView()
        case .coachShare: TrainerShareView()
        }
    }

    // MARK: Back swipe

    /// Which screens are on stage: the active one, plus — mid-swipe — the one underneath.
    private var layers: [AppTab] {
        if backDragging, let t = store.backTarget, t != store.activeTab { return [t, store.activeTab] }
        return [store.activeTab]
    }

    /// The seam between the page sliding away and the one underneath.
    private var seamX: CGFloat { backOnLeading ? backDrag : shellWidth + backDrag }

    private var seamShadow: some View {
        LinearGradient(colors: backOnLeading ? [.black.opacity(0.35), .clear] : [.clear, .black.opacity(0.35)],
                       startPoint: .trailing, endPoint: .leading)
            .opacity(Double(min(1, abs(backDrag) / 40)))
    }

    private func backTag(_ target: AppTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: backOnLeading ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .heavy))
            Text(target.rawValue).font(BrandFont.body(13, .heavy)).lineLimit(1)
        }
        .foregroundColor(Brand.onVolt)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Brand.volt))
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        .fixedSize()
    }

    private func commitBack() {
        // Slide the page right off, then swap underneath it — the screen behind is
        // already the one we're going to, so the switch itself is invisible.
        withAnimation(.easeOut(duration: 0.22)) {
            backDrag = backOnLeading ? shellWidth : -shellWidth
        }
        UISelectionFeedbackGenerator().selectionChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
            // Both in one turn: the revealed layer becomes the active one at offset 0,
            // the old one is dropped without animation. Nothing visibly changes.
            backDrag = 0
            store.goBack(animated: false)
        }
    }

    private func cancelBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { backDrag = 0 }
    }

    // MARK: Announcements

    private func dismissAnnouncements() {
        // Swiped away or "Read later": don't re-pop this session; it returns next launch.
        let seen = AnnouncementSeen.ids
        for a in pendingAnnouncements where !seen.contains(a.id) { snoozedAnnouncements.insert(a.id) }
        showAnnouncement = false
    }

    private func presentNewAnnouncements() {
        // Never interrupt a workout or a celebration.
        guard !showAnnouncement, store.activeWorkoutId == nil, store.sessionWorkoutId == nil,
              store.awardToCelebrate == nil, store.prToCelebrate == nil else { return }
        let seen = AnnouncementSeen.ids
        let cutoff = Date().addingTimeInterval(-AnnouncementSeen.freshFor)
        let fresh = store.liveAnnouncements.filter {
            !seen.contains($0.id) && !snoozedAnnouncements.contains($0.id) && $0.date > cutoff
        }
        guard !fresh.isEmpty else { return }
        pendingAnnouncements = fresh
        showAnnouncement = true
    }
}

// Invisible 20pt strip on one edge: back on one side, the menu on the other.
private struct EdgeSwipeCatcher: View {
    let edge: HorizontalEdge
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { Spacer(minLength: 0) }
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 20)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            // More horizontal than vertical, or it's a scroll clipping the edge.
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            onChanged(v.translation.width)
                        }
                        .onEnded { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else {
                                onEnded(0, 0); return
                            }
                            onEnded(v.translation.width, v.predictedEndTranslation.width)
                        }
                )
            if edge == .leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
