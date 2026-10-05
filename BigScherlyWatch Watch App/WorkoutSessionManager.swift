import Foundation
import Combine
import HealthKit

// MARK: - Workout session (wrist)
// A real HealthKit strength-training session. It keeps the app running with the
// wrist down (so motion keeps recording), gives dense heart rate, and saves the
// session to Apple Health as a workout when it ends.

@MainActor
final class WorkoutSessionManager: NSObject, ObservableObject {
    static let shared = WorkoutSessionManager()

    @Published private(set) var isRunning = false
    @Published private(set) var startDate: Date? = nil
    @Published private(set) var heartRate: Int? = nil
    @Published private(set) var lastError: String? = nil
    /// A demo session (the phone's Demo Mode): thrown away at the end, never saved to Health.
    var discardOnEnd = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private override init() { super.init() }

    // MARK: Start / end

    func start() async {
        guard !isRunning, HKHealthStore.isHealthDataAvailable() else { return }
        lastError = nil
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)])
        } catch {
            lastError = "Health access is needed to run a session."
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            let now = Date()
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            startDate = now
            isRunning = true
            MotionRecorder.shared.start()
            WatchState.sendLive(["sessionActive": true])
        } catch {
            session = nil
            builder = nil
            lastError = "Couldn't start the session."
        }
    }

    func end() async {
        guard let s = session, let b = builder else { return }
        MotionRecorder.shared.stop()
        s.end()
        do {
            try await b.endCollection(at: Date())
            if discardOnEnd { b.discardWorkout() }       // demo: nothing saved to Health
            else { _ = try await b.finishWorkout() }
        } catch {
            // The session still ends; Health just may not get the saved workout.
        }
        reset()
    }

    /// Called after a crash/relaunch mid-session (see WatchAppDelegate).
    func recover() {
        store.recoverActiveWorkoutSession { recovered, _ in
            guard let recovered else { return }
            Task { @MainActor in WorkoutSessionManager.shared.adopt(recovered) }
        }
    }

    private func adopt(_ s: HKWorkoutSession) {
        guard session == nil else { return }
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: s.workoutConfiguration)
        s.delegate = self
        b.delegate = self
        session = s
        builder = b
        startDate = s.startDate ?? Date()
        isRunning = true
        MotionRecorder.shared.start()
    }

    private func reset() {
        WatchState.sendLive(["sessionActive": false])
        discardOnEnd = false
        session = nil
        builder = nil
        isRunning = false
        startDate = nil
        heartRate = nil
    }

    fileprivate func handleFailure() {
        MotionRecorder.shared.stop()
        reset()
        lastError = "The session stopped unexpectedly."
    }

    private var lastHRSent: Date = .distantPast

    fileprivate func updateHeartRate(_ bpm: Int) {
        heartRate = bpm
        // Mirror to the phone every few seconds so the workout screen can show it.
        if Date().timeIntervalSince(lastHRSent) >= 5 {
            lastHRSent = Date()
            WatchState.sendLive(["sessionActive": true, "liveHR": bpm])
        }
    }
}

extension WorkoutSessionManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.handleFailure() }
    }
}

extension WorkoutSessionManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hr),
              let q = workoutBuilder.statistics(for: hr)?.mostRecentQuantity() else { return }
        let bpm = Int(q.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        Task { @MainActor in self.updateHeartRate(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
