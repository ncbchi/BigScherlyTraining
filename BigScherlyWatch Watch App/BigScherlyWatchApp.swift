import SwiftUI

@main
struct BigScherlyWatchApp: App {
    @StateObject private var state = WatchState.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(state)
        }
    }
}
