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
        WatchLink.send(["restSeconds": seconds], label: "restSeconds")       // live, confirmed, once-only
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
    /// The Watch app's build, as it reports it (nil = an older Watch app that doesn't report one).
    @Published private(set) var watchBuild: String?
    /// The Watch build this phone build was made with — a mismatch means the Watch missed an update.
    static let expectedWatchBuild = "2026-10-05.12"
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
    /// The live card for the Watch (see LiveSessionController.pushCardToWatch). Live only:
    /// when the Watch isn't reachable it asks for the latest when it comes back.
    func sendCard(_ data: Data, extras: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var msg = extras
        msg["card"] = data
        // Live, on every change (no "reachable" gate). If a send fails, the newest card goes again.
        WCSession.default.sendMessage(msg, replyHandler: nil) { e in
            print("[Link] card: \(e.localizedDescription) — sending the newest card again")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LiveSessionController.shared.pushCardToWatch() }
        }
    }

    /// No card on the Watch. `endSession`: the workout finished, so the Watch ends its session
    /// too (saved for real workouts, discarded for demos). Without it, just "no card right now".
    /// An event for the Watch (try again, OK, setup over, workout over): live, with a handshake and
    /// fast retries (see WatchLink).
    func sendEvent(_ msg: [String: Any]) {
        WatchLink.send(msg, label: msg.keys.sorted().first ?? "event")
    }

    func sendCardEnd(endSession: Bool) {
        if endSession { sendEvent(["cardEnd": true, "endSession": true]); return }   // the workout's over
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["cardEnd": true, "endSession": false], replyHandler: nil, errorHandler: nil)
    }


    /// The Watch setup's steps (see WatchSetup.swift).
    func sendSetup(_ msg: [String: Any]) {
        // Try again / OK / setup over are events: confirmed delivery. (The step itself is state —
        // it's also on every pull.)
        if msg["setupRetry"] != nil || msg["setupOK"] != nil || msg["setupEnd"] != nil { sendEvent(msg); return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        // The step is state: live, and resent until the Watch says Go (see the setup engine).
        WCSession.default.sendMessage(msg, replyHandler: nil) { print("[Link] setup step: \($0.localizedDescription)") }
    }

    /// A paired Watch with the app installed (so the phone can open it into a workout).
    var watchAppAvailable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
            && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

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
    var haptics: WatchHaptics? = nil       // Settings ▸ Notifications ▸ Watch buzzes
}
struct WatchHaptics: Codable {
    var pauseStrength: Int                 // 0 light · 1 medium · 2 strong
    var pauseTicks: Bool
    var slowRepOn: Bool
    var slowRepPct: Double
    var slowRepPattern: Int                // 0 single · 1 double · 2 long
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
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        print("[Watch] connection \(state == .activated ? "active" : "not active") · paired \(session.isPaired) · Watch app installed \(session.isWatchAppInstalled) · reachable \(session.isReachable)" + (error.map { " · error: \($0.localizedDescription)" } ?? ""))
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        print("[Watch] Watch state changed · paired \(session.isPaired) · Watch app installed \(session.isWatchAppInstalled)")
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// The Watch app came back in reach: catch it up (the card, and a waiting setup step).
    func sessionReachabilityDidChange(_ session: WCSession) {
        print("[Watch] reachable: \(session.isReachable)")
        guard session.isReachable else { return }
        Task { @MainActor in
            LiveSessionController.shared.pushCardToWatch()
            SetupEngine.shared.resendIfActive()
        }
    }

    // A set was logged from the wrist → apply it through the phone's save path.
    // Live message when the phone was reachable…
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    /// The Watch pulls the card (and any setup step waiting for Go): the answer rides back on the
    /// reply — which works even when the phone thinks the Watch isn't reachable.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["cardPull"] as? Bool == true else {
            handleIncoming(message)
            replyHandler(["ack": message["mid"] as? String ?? ""])     // confirms an event
            return
        }
        // The Watch's pull (every 2 s while it's open): it confirms events it got on earlier replies,
        // and gets the card, any setup step, and any of our events it hasn't confirmed yet.
        for mid in (message["acks"] as? [String]) ?? [] {
            if LinkBook.shared.confirm(mid) {                                        // DIAGNOSTIC: rescued
                print("[Link] an event reached the Watch on its pull (the handshake missed it)")
                Task { @MainActor in LinkStats.shared.rescued += 1 }
            }
        }
        let build = message["watchBuild"] as? String
        Task { @MainActor in
            WatchBridge.shared.watchBuild = build
            var payload = LiveSessionController.shared.watchCardPayload()
            if let step = SetupEngine.shared.pendingStepPayload() { payload.merge(step) { current, _ in current } }
            payload["setupActive"] = SetupEngine.shared.active        // none here → the Watch clears its own
            let ours = LinkBook.shared.pendingMessages()
            if !ours.isEmpty { payload["events"] = ours }
            replyHandler(payload)
        }
    }

    // …or queued delivery when it wasn't (also how set motion data always arrives).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleIncoming(userInfo)
    }

    private func handleIncoming(_ message: [String: Any]) {
        if let mid = message["mid"] as? String, !LinkBook.shared.firstTime(mid) { return }   // already handled
        // (setStarted and liveReps were missing here, so "set started" never reached the phone.)
        if message["sessionActive"] != nil || message["liveHR"] != nil || message["detectedSet"] != nil
            || message["setStarted"] != nil || message["liveRepsData"] != nil {
            DispatchQueue.main.async { self.applyLive(message) }
            return
        }
        // The Watch's card buttons go through the same path as the Lock Screen card's.
        if let action = message["cardAction"] as? String {
            Task { @MainActor in
                let live = LiveSessionController.shared
                switch action {
                case "startSet": await live.handle(.startSet)
                case "rest30": await live.handle(.rest(seconds: 30))
                case "skipRest": await live.handle(.rest(seconds: 0))
                default: break
                }
            }
            return
        }
        // Watch setup: Go tapped, the hold done, or the setup set captured.
        if message["setupGo"] as? Bool == true {
            let wrist = message["wrist"] as? String, crown = message["crown"] as? String
            Task { @MainActor in SetupEngine.shared.watchWentGo(wrist: wrist, crown: crown) }
            return
        }
        if let data = message["setupLive"] as? Data {
            let reps = (try? JSONDecoder().decode([RepMotion].self, from: data)) ?? []
            Task { @MainActor in SetupEngine.shared.watchLive(reps) }
            return
        }
        if let m = message["setupStillFailed"] as? String {
            Task { @MainActor in SetupEngine.shared.watchStillFailed(m) }
            return
        }
        if message["setupExit"] as? Bool == true {
            Task { @MainActor in SetupEngine.shared.skip() }
            return
        }
        if message["setupStillDone"] as? Bool == true {
            Task { @MainActor in SetupEngine.shared.watchStillDone() }
            return
        }
        if let data = message["setupReps"] as? Data {
            let reps = (try? JSONDecoder().decode([RepMotion].self, from: data)) ?? []
            Task { @MainActor in SetupEngine.shared.watchCaptured(reps) }
            return
        }
        // The Watch tapped your wrist (10 seconds, rest's up): the phone plays the sound.
        if let cue = message["cue"] as? String {
            Task { @MainActor in RestTimerEngine.shared.playWatchCue(cue) }
            return
        }
        // The Watch (re)opened: send it the card as it is now.
        if message["cardRequest"] as? Bool == true {
            let build = message["watchBuild"] as? String
            Task { @MainActor in
                WatchBridge.shared.watchBuild = build
                LiveSessionController.shared.pushCardToWatch()
                SetupEngine.shared.resendIfActive()           // and the setup step, if one's waiting
            }
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

// MARK: - The live link
/// Events between the phone and the Watch, live with a handshake: sent at once, and the other side
/// confirms the moment it has it. No confirmation within 0.3 s → sent again straight away, and again
/// on a short back-off (seven live attempts within 4 s). Every attempt carries the same id and the
/// receiver handles each id once — a retry can never count twice. Only if every live attempt fails
/// does it fall back to iOS's queued delivery, so nothing is lost. No "reachable" checks: that flag
/// is unreliable, and gating on it is what silently dropped messages.
nonisolated enum WatchLink {
    private static let waits: [Double] = [0.3, 0.3, 0.5, 0.5, 0.8, 0.8, 0.8]     // = 4 s

    static func send(_ msg: [String: Any], label: String) {
        guard WCSession.default.activationState == .activated else { return }
        let mid = UUID().uuidString
        var m = msg
        m["mid"] = mid
        LinkBook.shared.track(mid, m)              // until confirmed (the pull carries it too)
        Task { @MainActor in LinkStats.shared.sent += 1 }                         // DIAGNOSTIC
        attempt(Box(m), mid: mid, label: label, n: 0, started: Date())
    }

    private static func attempt(_ box: Box, mid: String, label: String, n: Int, started: Date) {
        guard !LinkBook.shared.isConfirmed(mid) else { return }
        guard n < waits.count else {
            print("[Link] \(label): no confirmation within 4 s — also handed to iOS's queued delivery")
            Task { @MainActor in LinkStats.shared.queued += 1 }                   // DIAGNOSTIC
            WCSession.default.transferUserInfo(box.m)
            return
        }
        WCSession.default.sendMessage(box.m, replyHandler: { r in
            guard r["ack"] as? String == mid, LinkBook.shared.confirm(mid) else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor in                                                   // DIAGNOSTIC
                if n == 0 { LinkStats.shared.live += 1 } else { LinkStats.shared.retried += 1 }
                LinkStats.shared.lastMs = ms
            }
            if n > 0 || ms > 600 { print("[Link] \(label) confirmed in \(ms) ms" + (n > 0 ? " (attempt \(n + 1))" : "")) }
        }, errorHandler: { e in
            if n == 0 { print("[Link] \(label): \(e.localizedDescription) — retrying") }
        })
        DispatchQueue.global().asyncAfter(deadline: .now() + waits[n]) {
            attempt(box, mid: mid, label: label, n: n + 1, started: started)
        }
    }

    /// (a message, passed between threads by the retry loop)
    final class Box: @unchecked Sendable { let m: [String: Any]; init(_ m: [String: Any]) { self.m = m } }
}

/// Which events have been confirmed (sender) and which ids have been handled (receiver). Locked:
/// touched from WatchConnectivity's threads.
nonisolated final class LinkBook: @unchecked Sendable {
    static let shared = LinkBook()
    private let lock = NSLock()
    private var confirmed: [String] = []
    private var seen: [String] = []
    private var unconfirmed: [(mid: String, msg: [String: Any], at: Date)] = []
    private var acks: [String] = []

    /// An event on its way, until it's confirmed.
    func track(_ mid: String, _ msg: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        unconfirmed.append((mid, msg, Date()))
    }
    /// Events still unconfirmed (from the last minute) — they ride along on the pull.
    func pendingMessages() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        unconfirmed.removeAll { Date().timeIntervalSince($0.at) > 60 }
        return unconfirmed.map { $0.msg }
    }
    /// Events that arrived on a pull reply: confirmed on the next pull.
    func ackLater(_ mid: String) { lock.lock(); acks.append(mid); lock.unlock() }
    func takeAcks() -> [String] { lock.lock(); defer { acks = []; lock.unlock() }; return acks }

    /// Marks it confirmed; true the first time (later replies to retries are ignored).
    func confirm(_ mid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if confirmed.contains(mid) { return false }
        confirmed.append(mid)
        unconfirmed.removeAll { $0.mid == mid }
        if confirmed.count > 400 { confirmed.removeFirst(200) }
        return true
    }
    func isConfirmed(_ mid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return confirmed.contains(mid) }
    /// Already handled? (doesn't record it)
    func hasSeen(_ mid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return seen.contains(mid) }
    /// True the first time an id arrives; a repeat (a retry of something already handled) is false.
    func firstTime(_ mid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if seen.contains(mid) { return false }
        seen.append(mid)
        if seen.count > 400 { seen.removeFirst(200) }
        return true
    }
}

// MARK: - DIAGNOSTIC (temporary): link counters, shown on the workout card. Delete with its views.
@MainActor final class LinkStats: ObservableObject {
    static let shared = LinkStats()
    @Published var sent = 0
    @Published var live = 0        // confirmed on the first attempt
    @Published var retried = 0     // confirmed after a resend
    @Published var rescued = 0     // the handshake missed it — the 2-second pull caught it
    @Published var queued = 0      // no confirmation within 4 s: handed to iOS's queued delivery
    @Published var lastMs: Int?
}
