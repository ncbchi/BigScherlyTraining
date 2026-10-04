import Foundation
import Combine
import HealthKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// Phone-side bridge that pushes a small snapshot of app state to the Watch
// (streak/status, next workout, unread messages) and forwards rest-timer starts
// so the wrist can buzz. Kept intentionally tiny — the Watch shows glances and
// fires haptics; it is not a second copy of the app.
//
// The payload keys are shared with the Watch app via WatchPayload below.
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    #if canImport(WatchConnectivity)
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }
    #endif

    private override init() {
        super.init()
        activate()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }

    // Push the latest glance/complication state. Uses application context so the
    // Watch always has the most recent snapshot even if it wasn't reachable.
    func sync(_ payload: WatchPayload) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(payload.dictionary)
        #endif
    }

    // Tell the Watch to start a rest timer of `seconds` (it schedules its own
    // wrist notification so the tap fires even with the phone away).
    func startRest(seconds: Int) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["restSeconds": seconds], replyHandler: nil, errorHandler: nil)
        #endif
    }

    // MARK: - Live session state from the Watch
    // Sent by the Watch only while the phone is reachable; nothing here is stored.

    /// A set the Watch just detected, used to pre-fill the phone's set fields.
    struct LiveDetection: Equatable {
        var workoutId: String
        var exerciseId: String?
        var setId: String?
        var reps: Int
        var meanVelocity: Double
        var receivedAt: Date
    }

    @Published private(set) var liveHeartRate: Int? = nil
    @Published private(set) var watchSessionActive = false
    @Published private(set) var lastDetection: LiveDetection? = nil
    @Published private(set) var lastLiveUpdate: Date? = nil
    /// v1.1: when the Watch counted the first rep of a set (drives the Live Activity's "lifting" state).
    @Published private(set) var liveSetStartedAt: Date? = nil
    /// Phase 3: every rep so far in the set in progress, as the Watch counts it.
    @Published private(set) var liveRepMotions: [RepMotion] = []
    /// Their speeds (m/s).
    var liveReps: [Double] { liveRepMotions.map { $0.meanVelocity } }

    /// Session reported live within the last minute (guards against a silent Watch).
    var watchSessionLive: Bool {
        guard watchSessionActive, let t = lastLiveUpdate else { return false }
        return Date().timeIntervalSince(t) < 60
    }

    /// The phone logged the set — don't offer the same detection again.
    func clearDetection() { lastDetection = nil }

    // Demo Mode: drive the live card without a Watch, through the same published values.
    func demoLive(reps: [RepMotion]) { liveRepMotions = reps }
    func demoDetection(workoutId: String, reps: Int, velocity: Double) {
        lastDetection = LiveDetection(workoutId: workoutId, exerciseId: nil, setId: nil,
                                      reps: reps, meanVelocity: velocity, receivedAt: Date())
    }

    fileprivate func applyLive(_ message: [String: Any]) {
        if let active = message["sessionActive"] as? Bool {
            watchSessionActive = active
            if !active { liveHeartRate = nil }
        }
        if let bpm = message["liveHR"] as? Int { liveHeartRate = bpm }
        if message["setStarted"] as? Bool == true { liveSetStartedAt = Date(); liveRepMotions = [] }
        if let data = message["liveRepsData"] as? Data,
           let reps = try? JSONDecoder().decode([RepMotion].self, from: data) { liveRepMotions = reps }
        if message["detectedSet"] as? Bool == true,
           let wid = message["workoutId"] as? String,
           let reps = message["reps"] as? Int {
            lastDetection = LiveDetection(workoutId: wid,
                                          exerciseId: message["exerciseId"] as? String,
                                          setId: message["setId"] as? String,
                                          reps: reps,
                                          meanVelocity: message["velocity"] as? Double ?? 0,
                                          receivedAt: Date())
        }
        lastLiveUpdate = Date()
    }

    // MARK: - Starting the Watch session from the phone

    /// A paired Watch with the app installed.
    var isWatchReady: Bool {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
        #else
        return false
        #endif
    }

    /// Launches the Watch app straight into a strength-training session (it opens on the
    /// wrist even if the app wasn't running). Completion runs on the main thread.
    func startWatchWorkout(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { completion(false); return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        HKHealthStore().startWatchApp(with: config) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Live workout companion

    // Called by the phone when a set is edited from the Watch. The AppStore sets this
    // so incoming wrist edits flow through the same save path as phone edits.
    var onSetLogged: ((_ workoutId: String, _ exerciseId: String, _ setId: String,
                       _ reps: Int?, _ weight: Double?, _ rpe: Double?) -> Void)?

    // Push the currently-active workout to the Watch as JSON (application context,
    // so the Watch always has the latest even if it reconnects).
    func sendActiveWorkout(_ workout: WatchWorkout?) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return }
        var ctx: [String: Any] = [:]
        if let workout, let data = try? JSONEncoder().encode(workout) {
            ctx["activeWorkout"] = data
        } else {
            ctx["activeWorkout"] = Data()   // empty = no active workout
        }
        try? session.updateApplicationContext(ctx)
        #endif
    }
}

// Compact, Codable snapshot of the active workout for the Watch. Mirrors just what
// the wrist UI needs to display and log — not the full app model.
struct WatchWorkout: Codable, Identifiable {
    var id: String
    var title: String
    var exercises: [WatchExercise]
}
struct WatchExercise: Codable, Identifiable {
    var id: String
    var name: String
    var restSeconds: Int
    var sets: [WatchSet]
    var pauseTarget: Double? = nil      // seconds — the Watch taps you when the bottom pause reaches it
}
struct WatchSet: Codable, Identifiable {
    var id: String
    var targetReps: Int
    var targetWeight: Double
    var loggedReps: Int?
    var loggedWeight: Double?
    var rpe: Double?
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    // A set was logged from the wrist → apply it through the phone's save path.
    // Live message when the phone was reachable…
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    // …or queued delivery when it wasn't (also how set motion data always arrives).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleIncoming(userInfo)
    }

    private func handleIncoming(_ message: [String: Any]) {
        // (setStarted and liveReps were missing here, so "set started" never reached the phone.)
        if message["sessionActive"] != nil || message["liveHR"] != nil || message["detectedSet"] != nil
            || message["setStarted"] != nil || message["liveRepsData"] != nil {
            DispatchQueue.main.async { self.applyLive(message) }
            return
        }
        if let data = message["setMotion"] as? Data {
            guard let motion = try? JSONDecoder().decode(SetMotion.self, from: data) else { return }
            DispatchQueue.main.async {
                SetMotionStore.shared.ingest(motion)
            }
            return
        }
        guard message["logSet"] as? Bool == true,
              let workoutId = message["workoutId"] as? String,
              let exerciseId = message["exerciseId"] as? String,
              let setId = message["setId"] as? String else { return }
        let reps = message["reps"] as? Int
        let weight = message["weight"] as? Double
        let rpe = message["rpe"] as? Double     // half steps; whole numbers arrive as Double too
        DispatchQueue.main.async {
            self.onSetLogged?(workoutId, exerciseId, setId, reps, weight, rpe)
        }
    }
}
#endif

// Shared snapshot the phone sends and the Watch renders. Encoded as a plain
// dictionary so both targets can use it without a shared framework.
struct WatchPayload {
    var streakWeeks: Int
    var trainingStatus: String        // e.g. "On track", "Rest day", "2 due"
    var nextWorkoutTitle: String
    var nextWorkoutDate: Date?
    var unreadMessages: Int

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "streakWeeks": streakWeeks,
            "trainingStatus": trainingStatus,
            "nextWorkoutTitle": nextWorkoutTitle,
            "unreadMessages": unreadMessages
        ]
        if let date = nextWorkoutDate {
            d["nextWorkoutDate"] = date.timeIntervalSince1970
        }
        return d
    }

    init(streakWeeks: Int, trainingStatus: String, nextWorkoutTitle: String,
         nextWorkoutDate: Date?, unreadMessages: Int) {
        self.streakWeeks = streakWeeks
        self.trainingStatus = trainingStatus
        self.nextWorkoutTitle = nextWorkoutTitle
        self.nextWorkoutDate = nextWorkoutDate
        self.unreadMessages = unreadMessages
    }
}
