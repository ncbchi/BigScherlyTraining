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
    /// The phone paused the workout (Oct 27, 2026): Health stops counting, motion stops recording.
    @Published private(set) var isPaused = false
    /// A demo session (the phone's Demo Mode): thrown away at the end, never saved to Health.
    var discardOnEnd = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private override init() { super.init() }

    // MARK: Start / end

    /// One start at a time — but only for a few seconds, so a start that never answers (asked while
    /// the app was in the background) can't block every later one.
    private var startingSince: Date?

    func start() async {
        guard !isRunning, HKHealthStore.isHealthDataAvailable() else { return }
        if let since = startingSince, Date().timeIntervalSince(since) < 6 { return }
        startingSince = Date()
        defer { startingSince = nil }
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
            startLeftoverGuard()
        } catch {
            session = nil
            builder = nil
            lastError = "Couldn't start the session."
            recover()                      // one may already be running for this app (e.g. after an update)
        }
    }

    private var ending = false                 // our own end() — not "stopped from outside"

    func end() async {
        guard let s = session, let b = builder else { return }
        ending = true
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

    /// The phone's Pause: the session pauses (Apple Health leaves the paused time out of the workout).
    func pause() {
        guard isRunning, !isPaused, let s = session else { return }
        s.pause()
        isPaused = true
        MotionRecorder.shared.stop()
    }

    /// The phone's Resume.
    func resume() {
        guard isRunning, isPaused, let s = session else { return }
        s.resume()
        isPaused = false
        MotionRecorder.shared.start()
    }

    /// Called after a crash/relaunch mid-session (see WatchAppDelegate). watchOS relaunches the app
    /// on its own to hand back a session that was still running — so check with the phone straight
    /// away, and let the leftover guard end it if nothing is using it (Oct 16, 2026).
    func recover() {
        store.recoverActiveWorkoutSession { recovered, _ in
            guard let recovered else { return }
            Task { @MainActor in
                let m = WorkoutSessionManager.shared
                m.adopt(recovered)
                WatchState.shared.requestCard()              // a live workout on the phone sends its card back
                // Handed back by watchOS with nothing asking for it (Oct 16, 11 AM: it came on by itself
                // again): a real workout's card comes back within seconds — if nothing has claimed the
                // session after 30 s, end it now (nothing saved) instead of buzzing for 10 minutes.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard m.isRunning, m.session === recovered, !m.inUse, !m.ending else { return }
                print("[Session] recovered session unused after 30 s — ending it")
                m.discardOnEnd = true
                await m.end()
            }
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
        startLeftoverGuard()
        // Recovered long past any workout (left running overnight): end it now, nothing saved.
        if Date().timeIntervalSince(startDate ?? Date()) > Self.hardCap {
            print("[Session] recovered a session from \(Int(Date().timeIntervalSince(startDate ?? Date()) / 3600)) h ago — ending it")
            discardOnEnd = true
            Task { await end() }
        }
    }

    // MARK: Leftover sessions (Oct 16, 2026)
    // A session nothing is using — no workout card from the phone, no setup, no recording — kept the
    // motion recorder running, so everyday arm movement buzzed the wrist as "reps", and watchOS kept
    // relaunching the app to hand it back. Checked once a minute while a session runs: unused for
    // 10 minutes it ends (thrown away, not saved to Health); past 4¼ hours it ends whatever (the
    // phone's own cap is 4 hours, so a real workout is over by then).
    private static let unusedLimit: TimeInterval = 10 * 60
    private static let hardCap: TimeInterval = 4.25 * 3600
    private var unusedSince: Date?
    private var leftoverTask: Task<Void, Never>?

    /// A workout card from the phone, a setup, or a debug/gym recording is using the session.
    var inUse: Bool {
        isPaused || WatchState.shared.card != nil || WatchState.shared.setup != nil || WatchDebugRecorder.shared.arm != nil
    }

    private func startLeftoverGuard() {
        leftoverTask?.cancel()
        unusedSince = nil
        leftoverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.checkLeftover()
            }
        }
    }

    private func checkLeftover() async {
        guard isRunning, !ending else { return }
        if let s = startDate, Date().timeIntervalSince(s) > Self.hardCap {
            print("[Session] running over 4¼ h — ending it")
            if !inUse { discardOnEnd = true }
            await end()
            return
        }
        if inUse { unusedSince = nil; return }
        WatchState.shared.requestCard()                 // the phone may have a workout we haven't heard about
        let since = unusedSince ?? Date()
        unusedSince = since
        guard Date().timeIntervalSince(since) >= Self.unusedLimit else { return }
        print("[Session] no workout, setup or recording for 10 min — ending the leftover session")
        discardOnEnd = true
        await end()
    }

    private func reset() {
        leftoverTask?.cancel(); leftoverTask = nil
        unusedSince = nil
        ending = false
        WatchState.sendLive(["sessionActive": false])
        discardOnEnd = false
        isPaused = false
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
                                    from fromState: HKWorkoutSessionState, date: Date) {
        // Ended or stopped from outside (another workout app, the system): we're not running any more,
        // so the next setup step or workout starts a fresh one instead of thinking it still has one.
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in
            guard self.session === workoutSession, self.isRunning, !self.ending else { return }
            self.handleFailure()
        }
    }

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
