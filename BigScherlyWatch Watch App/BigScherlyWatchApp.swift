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

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(state)
                .environmentObject(session)
                .environmentObject(motion)
                .overlay { PauseCountdownOverlay() }       // Phase 3: the pause buzz countdown
                .sheet(item: $state.presentedDetection) { d in
                    WatchDetectedSetView(detection: d)
                        .environmentObject(state)
                        .environmentObject(session)
                        .environmentObject(motion)
                }
        }
    }
}
