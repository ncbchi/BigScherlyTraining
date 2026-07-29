import Foundation
import Combine
import WatchConnectivity
import UserNotifications
import WidgetKit

// The Watch app's single source of truth. Receives glance state from the phone
// (streak, next workout, unread messages) and handles rest-timer start messages
// by scheduling a wrist notification so the tap fires even with the phone away.
@MainActor
final class WatchState: NSObject, ObservableObject {
    static let shared = WatchState()

    // Glance / complication state, mirrored from the phone.
    @Published var streakWeeks: Int = 0
    @Published var trainingStatus: String = "—"
    @Published var nextWorkoutTitle: String = "No workout scheduled"
    @Published var nextWorkoutDate: Date? = nil
    @Published var unreadMessages: Int = 0

    // The live workout the phone says is active (open on phone, or today's/next).
    @Published var activeWorkout: WatchWorkout? = nil

    // Local rest timer state (for the in-app countdown ring).
    @Published var restEndDate: Date? = nil
    /// Total length of the current rest, so the ring can drain accurately.
    @Published private(set) var restTotal: Int = 0

    /// True when the wrist is showing sample content rather than real phone state.
    @Published private(set) var isDemo: Bool = false

    private let restNotifId = "bst.watch.rest.bell"

    // MARK: - Logging a set from the wrist

    // Optimistically update local state, then send to the phone to persist.
    func logSet(exerciseId: String, setId: String, reps: Int?, weight: Double?, rpe: Int?) {
        guard var workout = activeWorkout,
              let ei = workout.exercises.firstIndex(where: { $0.id == exerciseId }),
              let si = workout.exercises[ei].sets.firstIndex(where: { $0.id == setId }) else { return }
        if let reps { workout.exercises[ei].sets[si].loggedReps = reps }
        if let weight { workout.exercises[ei].sets[si].loggedWeight = weight }
        if let rpe { workout.exercises[ei].sets[si].rpe = rpe }
        activeWorkout = workout

        var msg: [String: Any] = [
            "logSet": true, "workoutId": workout.id,
            "exerciseId": exerciseId, "setId": setId
        ]
        if let reps { msg["reps"] = reps }
        if let weight { msg["weight"] = weight }
        if let rpe { msg["rpe"] = rpe }
        if WCSession.default.activationState == .activated, WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        }
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        requestNotificationPermission()
        let hadState = loadCachedContext()

        // When the Watch app runs with no state from the phone — standalone in the
        // Simulator for App Store screenshots, or before the first sync — fall back
        // to sample content so the wrist UI isn't empty.
        //
        // DEBUG-only by design: a shipping build must never show a real client
        // fabricated workouts. To also populate demo content in Release (e.g. so an
        // App Review tester sees a filled screen without opening the phone first),
        // delete the two #if DEBUG / #endif lines below.
        #if DEBUG
        if !hadState { loadDemoData() }
        #endif
    }

    /// Populate the wrist with sample content. Safe to call at any time.
    func loadDemoData() {
        isDemo = true
        streakWeeks = WatchDemoData.streakWeeks
        trainingStatus = WatchDemoData.trainingStatus
        nextWorkoutTitle = WatchDemoData.nextWorkoutTitle
        nextWorkoutDate = WatchDemoData.nextWorkoutDate
        unreadMessages = WatchDemoData.unreadMessages
        activeWorkout = WatchDemoData.workout
    }

    // MARK: - Rest timer (wrist)

    func startRest(seconds: Int) {
        let total = max(1, seconds)
        restTotal = total
        let end = Date().addingTimeInterval(TimeInterval(total))
        restEndDate = end
        scheduleRestNotification(after: seconds)
    }

    func cancelRest() {
        restEndDate = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [restNotifId])
    }

    /// 1.0 at the start of the rest, draining to 0. Accurate now that we keep the total.
    var restProgress: CGFloat {
        guard restTotal > 0 else { return 0 }
        return CGFloat(max(0, min(restTotal, restRemaining))) / CGFloat(restTotal)
    }

    var restRemaining: Int {
        guard let end = restEndDate else { return 0 }
        return max(0, Int(end.timeIntervalSinceNow.rounded()))
    }

    private func scheduleRestNotification(after seconds: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restNotifId])

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Time for your next set 🔔"
        content.sound = .default          // watchOS adds the haptic tap
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, TimeInterval(seconds)), repeats: false)
        center.add(UNNotificationRequest(identifier: restNotifId, content: content, trigger: trigger))
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    // MARK: - Applying phone state

    private func apply(_ context: [String: Any]) {
        // Anything arriving from the phone is real state — stop flagging demo.
        isDemo = false
        if let s = context["streakWeeks"] as? Int { streakWeeks = s }
        if let t = context["trainingStatus"] as? String { trainingStatus = t }
        if let title = context["nextWorkoutTitle"] as? String { nextWorkoutTitle = title }
        if let ts = context["nextWorkoutDate"] as? TimeInterval {
            nextWorkoutDate = Date(timeIntervalSince1970: ts)
        } else {
            nextWorkoutDate = nil
        }
        if let u = context["unreadMessages"] as? Int { unreadMessages = u }
        // Decode the live workout, if present.
        if let data = context["activeWorkout"] as? Data {
            if data.isEmpty {
                activeWorkout = nil
            } else if let w = try? JSONDecoder().decode(WatchWorkout.self, from: data) {
                activeWorkout = w
            }
        }
        cacheContext(context)
        // Nudge complications to refresh.
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Persist the last context so the glance/complication have data at launch.
    // Uses the shared App Group so the complication (a separate process) can read
    // it; falls back to standard defaults if the group isn't configured yet.
    private static let sharedDefaults = UserDefaults(suiteName: "group.com.nicholasbowen.bigscherlytraining") ?? .standard
    private func cacheContext(_ context: [String: Any]) {
        Self.sharedDefaults.set(context, forKey: "bst.watch.lastContext")
        UserDefaults.standard.set(context, forKey: "bst.watch.lastContext")
    }
    @discardableResult
    private func loadCachedContext() -> Bool {
        if let ctx = Self.sharedDefaults.dictionary(forKey: "bst.watch.lastContext")
            ?? UserDefaults.standard.dictionary(forKey: "bst.watch.lastContext") {
            apply(ctx)
            return true
        }
        return false
    }
}

extension WatchState: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    // Glance/complication snapshot (application context).
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    // Rest-timer start (live message).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let seconds = message["restSeconds"] as? Int {
            Task { @MainActor in self.startRest(seconds: seconds) }
        }
    }
}
