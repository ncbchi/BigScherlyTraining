import SwiftUI
import WatchKit
import HealthKit

// Lets HealthKit hand back a workout session that was running when the app was
// relaunched (crash, low memory), so recording carries on.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        WorkoutSessionManager.shared.recover()
    }

    /// The phone's "Start on Watch" button lands here.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in await WorkoutSessionManager.shared.start() }
    }
}

@main
struct BigScherlyWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var state = WatchState.shared
    @StateObject private var session = WorkoutSessionManager.shared
    @StateObject private var motion = MotionRecorder.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(state)
                .environmentObject(session)
                .environmentObject(motion)
                // The pause countdown, over any screen — except the card, whose tile shows the hold.
                .overlay { if !state.cardVisible && state.setup == nil { PauseCountdownOverlay() } }
                // The first-time setup, over everything while it runs (the phone drives it).
                .overlay { if state.setup != nil { WatchSetupView() } }
                // (A detected set now appears on the card's tile as "Log set", not a pop-up.)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { state.requestCard() }      // pick up the phone's card as it is now
                }
        }
    }
}
