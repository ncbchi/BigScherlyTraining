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
                // The pause countdown, over any screen — except the card, whose tile shows the hold.
                .overlay { if !state.cardVisible && state.setup == nil { PauseCountdownOverlay() } }
                // The first-time setup, over everything while it runs (the phone drives it).
                .overlay { if state.setup != nil { WatchSetupView() } }
                .overlay { DebugRecordOverlay() }                // DEBUG recorder (removed before release)
                // (A detected set now appears on the card's tile as "Log set", not a pop-up.)
                .onChange(of: scenePhase) { _, phase in
                    // Open: pull every 2 s alongside the live messages; stop when the wrist drops.
                    if phase == .active { state.startPulling() } else { state.stopPulling() }
                }
                .onAppear { state.startPulling() }
                // Last, so everything above — the overlays included — can see them. (Attached before
                // the overlays, the setup screen couldn't find them, and the app stopped when Go appeared.)
                .environmentObject(state)
                .environmentObject(session)
                .environmentObject(motion)
        }
    }
}
