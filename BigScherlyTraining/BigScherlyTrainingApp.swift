import SwiftUI

// MARK: - App entry point
@main
struct BigScherlyTrainingApp: App {
    // One store for the app's lifetime. Created here (not lazily by SwiftUI) so a
    // Lock Screen Live Activity button can log a set even when iOS launches the app
    // in the background just to run it.
    @StateObject private var store = AppStore.shared

    init() {
        LiveSessionController.shared.attach(AppStore.shared)
        WidgetBridge.shared.attach(AppStore.shared)        // keeps Home & Lock Screen widgets current
    }

    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ThemeHost { RootView().environmentObject(store) }    // Settings ▸ Appearance
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep the Watch's glance + complication current whenever the phone
            // comes to the foreground.
            if phase == .active {
                WidgetBridge.shared.mergeWidgetTicks()        // supplements ticked on a widget → your log
                store.syncToWatch()
                ServerSync.shared.flushSoon(after: 1)   // send anything queued while away/offline
            }
        }
    }
}

// MARK: - Root routing
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showBoard = true
    @State private var showSplash = true

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            if !store.isLoggedIn {
                LoginView()
            } else if store.isTrainer {
                // Trainers get an entirely different app — triage, not training.
                TrainerShell().id(theme.signature(scheme))   // redraw once on a theme change
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Active screen fills the whole space — no top bar stealing room
            Group {
                switch store.activeTab {
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keying by activeTab makes each screen a fresh identity, so the
            // transition fires (and per-screen entrance animations replay) on
            // every navigation. Direction comes from store.tabForward.
            .id(store.activeTab)
            .transition(.asymmetric(
                insertion: .move(edge: store.tabForward ? .trailing : .leading)
                    .combined(with: .opacity),
                removal: .move(edge: store.tabForward ? .leading : .trailing)
                    .combined(with: .opacity)
            ))

            // Right-edge swipe -> open the menu, from any screen.
            //
            // A narrow strip pinned to the trailing edge, so it can't steal drags from
            // the content (scroll views, RPE buttons, the share card, etc). It only
            // listens where a system edge-swipe would start anyway, and only reacts to
            // a decisive leftward pull — a vertical scroll that clips the edge is ignored.
            EdgeSwipeCatcher {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    store.showTray = true
                }
            }

            // Floating menu button, upper left, over the content
            FloatingMenuButton()
                .padding(.trailing, 16)
                .padding(.top, 8)

            NavTray()
        }
        // Award celebrations are app-wide: earning one shouldn't depend on which
        // screen happened to be open when it landed.
        .fullScreenCover(item: $store.awardToCelebrate) { award in
            AwardCelebrationView(award: award)
        }
    }
}

// Invisible 20pt strip on the right edge that opens the tray when pulled left.
private struct EdgeSwipeCatcher: View {
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 20)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { v in
                            // Pulled left, and more horizontal than vertical.
                            let dx = v.translation.width
                            let dy = v.translation.height
                            if dx < -25 && abs(dx) > abs(dy) { onOpen() }
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
}
