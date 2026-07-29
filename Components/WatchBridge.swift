import Foundation
import Combine
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

    // MARK: - Live workout companion

    // Called by the phone when a set is edited from the Watch. The AppStore sets this
    // so incoming wrist edits flow through the same save path as phone edits.
    var onSetLogged: ((_ workoutId: String, _ exerciseId: String, _ setId: String,
                       _ reps: Int?, _ weight: Double?, _ rpe: Int?) -> Void)?

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
}
struct WatchSet: Codable, Identifiable {
    var id: String
    var targetReps: Int
    var targetWeight: Double
    var loggedReps: Int?
    var loggedWeight: Double?
    var rpe: Int?
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    // A set was logged from the wrist → apply it through the phone's save path.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["logSet"] as? Bool == true,
              let workoutId = message["workoutId"] as? String,
              let exerciseId = message["exerciseId"] as? String,
              let setId = message["setId"] as? String else { return }
        let reps = message["reps"] as? Int
        let weight = message["weight"] as? Double
        let rpe = message["rpe"] as? Int
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
