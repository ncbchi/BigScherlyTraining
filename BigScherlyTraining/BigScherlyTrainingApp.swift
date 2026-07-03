import SwiftUI

// MARK: - App entry point
@main
struct BigScherlyTrainingApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root routing
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var showBoard = true

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            if !store.isLoggedIn {
                LoginView()
            } else if showBoard {
                WelcomeBoardView(showBoard: $showBoard)
            } else {
                MainShell()
            }
        }
        .onChange(of: store.isLoggedIn) { _, newValue in
            if newValue { showBoard = true }   // show board fresh on each login
        }
    }
}

// MARK: - Main shell (top bar + active screen + tray overlay)
struct MainShell: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Active screen fills the whole space — no top bar stealing room
            Group {
                switch store.activeTab {
                case .dashboard: DashboardView()
                case .workouts: WorkoutsView()
                case .history: HistoryView()
                case .macros: MacrosView()
                case .checkins: CheckInsView()
                case .photos: PhotosView()
                case .chat: ChatListView()
                case .announcements: AnnouncementsView()
                case .share: ShareView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating menu button, upper left, over the content
            FloatingMenuButton()
                .padding(.leading, 16)
                .padding(.top, 8)

            NavTray()
        }
    }
}
