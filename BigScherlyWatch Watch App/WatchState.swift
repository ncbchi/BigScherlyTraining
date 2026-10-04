import Foundation
import Combine
import WatchConnectivity
import UserNotifications
import WidgetKit
import WatchKit

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
    @Published var activeWorkout: WatchWorkout? = nil {
        didSet { updatePauseTarget() }
    }

    // Local rest timer state (for the in-app countdown ring).
    @Published var restEndDate: Date? = nil
    /// Total length of the current rest, so the ring can drain accurately.
    @Published private(set) var restTotal: Int = 0

    /// True when the wrist is showing sample content rather than real phone state.
    @Published private(set) var isDemo: Bool = false

    private let restNotifId = "bst.watch.rest.bell"

    // MARK: - Auto-detected sets

    /// The exercise screen currently open on the wrist (best hint for what's being lifted).
    @Published var focusedExerciseId: String? = nil {
        didSet { updatePauseTarget() }
    }
    /// The detected set currently shown in the confirm sheet.
    @Published var presentedDetection: DetectedSet? = nil {
        didSet { if presentedDetection == nil { presentNextDetection() } }
    }
    /// Detected sets not yet matched. A swiped-away one stays here so logging the set
    /// by hand within a few minutes still picks up its motion data.
    private var detections: [DetectedSet] = []
    private var shownDetectionIds: Set<UUID> = []
    private var lastRestEnd: Date? = nil
    private var lastLoggedExerciseId: String? = nil

    // MARK: - Logging a set from the wrist

    // Optimistically update local state, then send to the phone to persist.
    // `motion` is the detected set being confirmed, if any; otherwise a recent
    // unmatched detection for this exercise is attached automatically.
    func logSet(exerciseId: String, setId: String, reps: Int?, weight: Double?, rpe: Double?,
                motion: DetectedSet? = nil) {
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
        msg["loggedAt"] = Date().timeIntervalSince1970
        Self.sendReliably(msg)

        lastLoggedExerciseId = exerciseId
        if let d = motion ?? recentDetection(for: exerciseId) {
            sendMotion(d, workout: workout, exerciseId: exerciseId, setId: setId)
            removeDetection(d)
        }
    }

    /// Live-only message for the phone (heart rate, session state, detected sets).
    /// Dropped when the phone isn't reachable — it's only useful in the moment.
    nonisolated static func sendLive(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
    }

    /// Live message when the phone is reachable; otherwise queued so it arrives later.
    nonisolated private static func sendReliably(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(msg)
            }
        } else {
            WCSession.default.transferUserInfo(msg)
        }
    }

    // MARK: - Detected sets

    /// A finished set came in from the motion recorder.
    func handleDetectedSet(reps: [RepMotion], start: Date, end: Date) {
        guard let workout = activeWorkout, !reps.isEmpty else { return }
        let exId = suggestedExercise(in: workout)
        let setId = exId.flatMap { id in
            workout.exercises.first(where: { $0.id == id })?.sets.first(where: { $0.loggedReps == nil })?.id
        }
        // "Around when the rest timer went off" → confident match.
        let confident = lastRestEnd.map { abs(start.timeIntervalSince($0)) <= 90 } ?? false
        let d = DetectedSet(start: start, end: end, reps: reps,
                            suggestedExerciseId: exId, suggestedSetId: setId, confident: confident)
        detections.removeAll { Date().timeIntervalSince($0.end) > 600 }   // forget stale ones
        detections.append(d)
        // Let the phone pre-fill its set fields if it's open (live only; never queued).
        var live: [String: Any] = ["detectedSet": true, "workoutId": workout.id,
                                   "reps": reps.count, "velocity": d.meanVelocity]
        if let exId { live["exerciseId"] = exId }
        if let setId { live["setId"] = setId }
        Self.sendLive(live)
        WKInterfaceDevice.current().play(.click)
        if presentedDetection == nil { presentNextDetection() }
    }

    func discardDetection(_ d: DetectedSet) {
        removeDetection(d)
        if presentedDetection?.id == d.id { presentedDetection = nil }
    }

    private func removeDetection(_ d: DetectedSet) {
        detections.removeAll { $0.id == d.id }
    }

    private func presentNextDetection() {
        guard let next = detections.first(where: { !shownDetectionIds.contains($0.id) }) else { return }
        shownDetectionIds.insert(next.id)
        presentedDetection = next
    }

    /// An unmatched detection that ended within the last 3 minutes, for this exercise
    /// (or with no exercise guess at all).
    private func recentDetection(for exerciseId: String) -> DetectedSet? {
        detections.last { d in
            Date().timeIntervalSince(d.end) <= 180 &&
            (d.suggestedExerciseId == nil || d.suggestedExerciseId == exerciseId)
        }
    }

    private func suggestedExercise(in w: WatchWorkout) -> String? {
        func hasOpen(_ id: String?) -> Bool {
            guard let id, let ex = w.exercises.first(where: { $0.id == id }) else { return false }
            return ex.sets.contains { $0.loggedReps == nil }
        }
        if hasOpen(focusedExerciseId) { return focusedExerciseId }
        if hasOpen(lastLoggedExerciseId) { return lastLoggedExerciseId }
        return w.exercises.first(where: { $0.sets.contains { $0.loggedReps == nil } })?.id
    }

    /// A set was logged on the phone instead of the wrist: hand it the matching motion.
    /// Pause buzz: the target for the exercise you're on — the screen open on the wrist, else the next set's.
    private func updatePauseTarget() {
        guard let w = activeWorkout else { MotionRecorder.shared.setPauseTarget(nil); return }
        let ex = w.exercises.first { $0.id == focusedExerciseId }
            ?? w.exercises.first { $0.sets.contains { $0.loggedReps == nil } }
        MotionRecorder.shared.setPauseTarget(ex?.pauseTarget)
    }

    private func attachDetectionsToPhoneLoggedSets(old: WatchWorkout?, new: WatchWorkout) {
        guard let old, old.id == new.id, !detections.isEmpty else { return }
        for ex in new.exercises {
            guard let oldEx = old.exercises.first(where: { $0.id == ex.id }) else { continue }
            for set in ex.sets where set.loggedReps != nil {
                guard oldEx.sets.first(where: { $0.id == set.id })?.loggedReps == nil else { continue }
                let match = detections.first(where: { $0.suggestedSetId == set.id }) ?? recentDetection(for: ex.id)
                if let d = match {
                    sendMotion(d, workout: new, exerciseId: ex.id, setId: set.id)
                    removeDetection(d)
                    if presentedDetection?.id == d.id { presentedDetection = nil }
                }
            }
        }
    }

    /// Ship the motion for a logged set to the phone (queued — survives the phone being away).
    private func sendMotion(_ d: DetectedSet, workout: WatchWorkout, exerciseId: String, setId: String) {
        guard !isDemo else { return }
        let name = workout.exercises.first(where: { $0.id == exerciseId })?.name ?? ""
        let record = SetMotion(id: UUID().uuidString, workoutId: workout.id,
                               exerciseId: exerciseId, setId: setId, exerciseName: name,
                               start: d.start, end: d.end, reps: d.reps,
                               autoDetected: true, analyzerVersion: RepAnalyzer.version)
        guard WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(record) else { return }
        WCSession.default.transferUserInfo(["setMotion": data])
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        requestNotificationPermission()
        let hadState = loadCachedContext()
        MotionRecorder.shared.onSetDetected = { [weak self] reps, start, end in
            self?.handleDetectedSet(reps: reps, start: start, end: end)
        }
        // v1.1: tell the phone a set has started (its Lock Screen card switches to "lifting").
        MotionRecorder.shared.onSetStarted = { [weak self] in
            guard let wid = self?.activeWorkout?.id else { return }
            Self.sendLive(["setStarted": true, "workoutId": wid])
        }
        // Phase 3: every rep so far, as each is counted, for the phone's live card.
        MotionRecorder.shared.onLiveReps = { [weak self] reps in
            guard let wid = self?.activeWorkout?.id, let data = try? JSONEncoder().encode(reps) else { return }
            Self.sendLive(["liveRepsData": data, "workoutId": wid])
        }

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
        lastRestEnd = end
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
                let previous = activeWorkout
                activeWorkout = w
                attachDetectionsToPhoneLoggedSets(old: previous, new: w)
            }
        }
        cacheContext(context)
        // Nudge complications to refresh.
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Persist the last context so the glance/complication have data at launch.
    // Uses the shared App Group so the complication (a separate process) can read
    // it; falls back to standard defaults if the group isn't configured yet.
    private static let sharedDefaults = UserDefaults(suiteName: "group.bigscherlytraining.app") ?? .standard
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
