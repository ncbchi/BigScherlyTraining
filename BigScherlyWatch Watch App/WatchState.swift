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
        didSet {
            updatePauseTarget()
            if let h = activeWorkout?.haptics { applyHaptics(h) }
        }
    }

    // Local rest timer state (for the in-app countdown ring).
    @Published var restEndDate: Date? = nil
    /// Total length of the current rest, so the ring can drain accurately.
    @Published private(set) var restTotal: Int = 0

    /// True when the wrist is showing sample content rather than real phone state.
    @Published private(set) var isDemo: Bool = false

    private let restNotifId = "bst.watch.rest.bell"

    // MARK: - The live card (mirrors the phone's: same data as the Lock Screen card)

    @Published private(set) var card: WatchCard? = nil
    /// The last set's coach note, during rest.
    @Published private(set) var cardNote: String? = nil
    /// Reps as they arrive, from the phone (its Demo Mode); the Watch's own reps are `liveSpeeds`.
    @Published private(set) var cardLiveSpeeds: [Double] = []
    /// True while the phone is in Demo Mode — the Watch is showing the phone's demo.
    @Published private(set) var cardDemo = false
    /// Your weight step, in display units (crown clicks).
    @Published private(set) var weightStep: Double = 5
    /// This Watch's reps in the current set, as they're counted (m/s each).
    @Published private(set) var liveSpeeds: [Double] = []
    /// The card is on screen (it shows the pause hold itself, so the overlay steps aside).
    @Published var cardVisible = false
    /// Your theme accent, from the phone (kept between launches).
    @Published private(set) var accentHex: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "bst.watch.accent")).nonZero ?? 0xEDFF3D
    @Published private(set) var accentInkWhite: Bool = UserDefaults.standard.bool(forKey: "bst.watch.accentInk")
    private var restWarning = true
    private var restTaps: [DispatchWorkItem] = []

    // MARK: - Watch setup (first time) — driven by the phone's WatchSetup.swift

    struct SetupStep: Equatable {
        var title: String, hint: String, caps: String, kind: String     // kind: still · reps
        var target: Int, n: Int, of: Int, lift: String                   // lift: body · squat · bench · deadlift
        var holdAtBottom: Bool { lift == "squat" || lift == "bench" || caps == "HIP BELOW KNEE" }
    }
    @Published private(set) var setup: SetupStep? = nil
    /// ready (Go) · holding (still check) · capturing · checking (phone) · ok
    @Published private(set) var setupPhase = "ready"
    @Published private(set) var setupMessage: String? = nil
    @Published private(set) var setupCount = 0
    @Published private(set) var holdStarted: Date? = nil
    private var setupGoAt = Date.distantPast
    private var setupSent = false
    private var setupLatest: [RepMotion] = []
    private var setupFinish: Task<Void, Never>?

    fileprivate func applySetup(_ d: [String: Any]) {
        // The phone re-sends the step until it hears Go — ignore a repeat of the step in progress.
        if let cur = setup, cur.n == (d["n"] as? Int ?? 1), cur.title == (d["title"] as? String ?? ""),
           ["holding", "capturing", "checking"].contains(setupPhase) { return }
        if let cur = setup, cur.n == (d["n"] as? Int ?? 1), cur.title == (d["title"] as? String ?? ""),
           setupPhase == "ready" { return }                 // already showing Go for it
        setup = SetupStep(title: d["title"] as? String ?? "Setup", hint: d["hint"] as? String ?? "",
                          caps: d["caps"] as? String ?? "", kind: d["kind"] as? String ?? "reps",
                          target: d["target"] as? Int ?? 0, n: d["n"] as? Int ?? 1, of: d["of"] as? Int ?? 1,
                          lift: d["lift"] as? String ?? "body")
        setupPhase = "ready"
        setupCount = 0
        setupFinish?.cancel(); setupFinish = nil
        // (a retry message, if one just arrived, stays up until Go)
    }

    /// Go: right before you touch the weight.
    func setupGo() {
        guard let step = setup else { return }
        setupGoAt = Date()
        setupSent = false
        setupMessage = nil
        setupLatest = []
        setupCount = 0
        let device = WKInterfaceDevice.current()
        Self.sendLive(["setupGo": true,
                       "wrist": device.wristLocation == .left ? "left" : "right",
                       "crown": device.crownOrientation == .right ? "right" : "left"])
        if step.kind == "still" {
            setupPhase = "holding"
            holdStarted = Date()
            MotionRecorder.shared.beginStillProbe()
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                MotionRecorder.shared.endStillProbe { [weak self] shake, rot in
                    guard let self else { return }
                    self.holdStarted = nil
                    if shake < 0.15 && rot < 0.25 {
                        self.setupPhase = "checking"
                        Self.sendLive(["setupStillDone": true])
                    } else {
                        self.setupPhase = "ready"
                        self.setupMessage = "You moved a little — stand completely still, then tap Go again."
                        WKInterfaceDevice.current().play(.retry)
                    }
                }
            }
        } else {
            setupPhase = "capturing"
            MotionRecorder.shared.calibrating = true
            // Bottom holds: the Watch taps at exactly two seconds — "hold until the tap".
            MotionRecorder.shared.setPauseTarget(step.holdAtBottom ? 2.0 : nil)
        }
    }

    /// Setup reps since Go, as they're counted.
    fileprivate func setupLive(_ reps: [RepMotion]) {
        guard let step = setup, setupPhase == "capturing" else { return }
        let mine = reps.filter { $0.start >= setupGoAt.addingTimeInterval(-0.5) }
        setupLatest = mine
        setupCount = mine.count
        if let data = try? JSONEncoder().encode(mine) { Self.sendLive(["setupLive": data]) }
        if step.target > 0, mine.count >= step.target, setupFinish == nil {
            // Target reached: give the last rep a moment to settle, then hand them over.
            setupFinish = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self.sendSetupReps(self.setupLatest)
            }
        }
    }

    /// The set ended before the target — hand over what there is (the phone says what's missing).
    fileprivate func setupSetEnded(_ reps: [RepMotion]) {
        guard setup != nil, setupPhase == "capturing" else { return }
        let mine = reps.filter { $0.start >= setupGoAt.addingTimeInterval(-0.5) }
        sendSetupReps(mine.isEmpty ? setupLatest : mine)
    }

    private func sendSetupReps(_ reps: [RepMotion]) {
        guard !setupSent, let data = try? JSONEncoder().encode(reps) else { return }
        setupSent = true
        setupFinish?.cancel(); setupFinish = nil
        setupPhase = "checking"
        Self.sendLive(["setupReps": data])
    }

    fileprivate func setupRetry(_ message: String) {
        setupMessage = message
        setupPhase = "ready"
        setupFinish?.cancel(); setupFinish = nil
        WKInterfaceDevice.current().play(.retry)
    }

    fileprivate func setupOK() {
        setupPhase = "ok"
        WKInterfaceDevice.current().play(.success)
    }

    func setupEnd() {
        setup = nil
        setupPhase = "ready"
        setupMessage = nil
        setupFinish?.cancel(); setupFinish = nil
        MotionRecorder.shared.endCalibration()
        updatePauseTarget()                               // back to the exercise's own pause
    }

    /// Ask the phone for the card as it is now (on launch, and when the app comes back).
    func requestCard() { Self.sendLive(["cardRequest": true, "watchBuild": WatchBuild.tag]) }

    fileprivate func applyCard(_ data: Data, note: String?, live: [Double], demo: Bool, step: Double?, warn: Bool?) {
        guard let c = try? JSONDecoder().decode(WatchCard.self, from: data) else { return }
        card = c
        WorkoutSessionManager.shared.discardOnEnd = demo          // a demo session isn't saved
        cardNote = note
        cardLiveSpeeds = live
        cardDemo = demo
        if let step, step > 0 { weightStep = step }
        if let warn { restWarning = warn }
        if let a = c.accent, a != accentHex {
            accentHex = a
            UserDefaults.standard.set(Int(a), forKey: "bst.watch.accent")
        }
        if let ink = c.accentInkWhite, ink != accentInkWhite {
            accentInkWhite = ink
            UserDefaults.standard.set(ink, forKey: "bst.watch.accentInk")
        }
        scheduleRestTaps()
    }

    /// No card. `finished`: the phone's workout ended, so the session ends too
    /// (saved for real workouts, discarded for demos).
    fileprivate func endCard(finished: Bool) {
        card = nil; cardNote = nil; cardLiveSpeeds = []
        restTaps.forEach { $0.cancel() }; restTaps = []
        if finished, WorkoutSessionManager.shared.isRunning {
            Task { await WorkoutSessionManager.shared.end() }
        }
    }

    // The card's buttons: show the result at once, and send it to the phone (which confirms
    // by sending the card back — to the Watch, the Lock Screen and the app alike).

    func cardStartSet() {
        card?.stage = "lifting"; card?.setStart = Date(); card?.restStart = nil; card?.restEnd = nil
        liveSpeeds = []
        restTaps.forEach { $0.cancel() }; restTaps = []
        Self.sendLive(["cardAction": "startSet"])
    }

    func cardAddRest() {
        if let e = card?.restEnd { card?.restEnd = max(Date(), e).addingTimeInterval(30) }
        scheduleRestTaps()
        Self.sendLive(["cardAction": "rest30"])
    }

    func cardSkipRest() {
        card?.stage = "ready"; card?.restStart = nil; card?.restEnd = nil
        restTaps.forEach { $0.cancel() }; restTaps = []
        Self.sendLive(["cardAction": "skipRest"])
    }

    /// The set to log: the detected one if the Watch saw it, else the next open set.
    func setToLog() -> (WatchExercise, WatchSet, Int)? {
        guard let w = activeWorkout else { return nil }
        if let d = presentedDetection, let exId = d.suggestedExerciseId, let setId = d.suggestedSetId,
           let ex = w.exercises.first(where: { $0.id == exId }), let i = ex.sets.firstIndex(where: { $0.id == setId }) {
            return (ex, ex.sets[i], i + 1)
        }
        for ex in w.exercises {
            if let i = ex.sets.firstIndex(where: { $0.loggedReps == nil }) { return (ex, ex.sets[i], i + 1) }
        }
        return nil
    }

    /// Save from the crown editor. Weight arrives in display units; sets are stored in lb.
    func cardLog(reps: Int, weight: Double, rpe: Double) {
        guard let (ex, set, _) = setToLog() else { return }
        let lb = card?.unit == "kg" ? weight / 0.45359237 : weight
        let detection = presentedDetection
        logSet(exerciseId: ex.id, setId: set.id, reps: reps, weight: lb, rpe: rpe, motion: detection)
        if detection != nil { presentedDetection = nil }
        liveSpeeds = []
        // Rest starts now on the wrist; the phone's card follows in a moment.
        let more = activeWorkout?.exercises.contains { $0.sets.contains { $0.loggedReps == nil } } ?? false
        if more, ex.restSeconds > 0 {
            let now = Date()
            card?.stage = "resting"; card?.restStart = now; card?.restEnd = now.addingTimeInterval(TimeInterval(ex.restSeconds))
            card?.logNeeded = false; card?.setStart = nil
            scheduleRestTaps()
            // No phone right now: this Watch keeps the rest itself (with its own wrist alert).
            if !WCSession.default.isReachable { startRest(seconds: ex.restSeconds) }
        } else if !more {
            card?.stage = "done"
        }
    }

    private func restIsUp() {
        guard card?.stage == "resting" else { return }
        card?.stage = "ready"; card?.restEnd = nil; card?.restStart = nil
    }

    /// While a Watch session runs (the app stays awake), the wrist taps at 10 seconds and when
    /// rest is up — and cues the phone, which plays the sound through whatever audio is selected
    /// (AirPods, headphones, the car, the speaker) without vibrating. One tap, one sound.
    private func scheduleRestTaps() {
        restTaps.forEach { $0.cancel() }; restTaps = []
        guard WorkoutSessionManager.shared.isRunning, let end = card?.restEnd else { return }
        let left = end.timeIntervalSinceNow
        guard left > 0 else { return }
        if restWarning, left > 12 {
            let w = DispatchWorkItem {
                WKInterfaceDevice.current().play(.click)
                Self.sendLive(["cue": "warning"])          // the phone plays the sound (no vibration there)
            }
            restTaps.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + left - 10, execute: w)
        }
        let up = DispatchWorkItem { [weak self] in
            WKInterfaceDevice.current().play(.notification)
            Self.sendLive(["cue": "restUp"])
            Task { @MainActor in self?.restIsUp() }
        }
        restTaps.append(up)
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: up)
    }

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
    /// The phone's buzz settings: the slow-rep switch and threshold (read when a set starts),
    /// and the pause tap's strength, ticks and the slow-rep pattern.
    private func applyHaptics(_ h: WatchHaptics) {
        UserDefaults.standard.set(h.slowRepOn, forKey: MotionSettings.buzzEnabledKey)
        UserDefaults.standard.set(h.slowRepPct, forKey: MotionSettings.buzzThresholdKey)
        MotionRecorder.shared.haptics = h
    }

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
            self?.liveSpeeds = []
            guard let wid = self?.activeWorkout?.id else { return }
            Self.sendLive(["setStarted": true, "workoutId": wid])
        }
        // Phase 3: every rep so far, as each is counted, for the phone's live card.
        MotionRecorder.shared.onCalibReps = { [weak self] reps in self?.setupLive(reps) }
        MotionRecorder.shared.onCalibEnded = { [weak self] reps, _, _ in self?.setupSetEnded(reps) }
        MotionRecorder.shared.onLiveReps = { [weak self] reps in
            self?.liveSpeeds = reps.map(\.meanVelocity)
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
        // A live card with a running session taps the wrist itself (see scheduleRestTaps).
        if !(card != nil && WorkoutSessionManager.shared.isRunning) { scheduleRestNotification(after: seconds) }
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
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.requestCard() }
    }

    // Glance/complication snapshot (application context).
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    // Rest-timer start (live message).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let seconds = message["restSeconds"] as? Int {
            Task { @MainActor in self.startRest(seconds: seconds) }
        }
        // The live card (the phone's — including its Demo Mode).
        if let data = message["card"] as? Data {
            let note = message["cardNote"] as? String
            let live = message["cardLive"] as? [Double] ?? []
            let demo = message["cardDemo"] as? Bool ?? false
            let step = message["cardStep"] as? Double
            let warn = message["cardWarn"] as? Bool
            Task { @MainActor in self.applyCard(data, note: note, live: live, demo: demo, step: step, warn: warn) }
        }
        if message["cardEnd"] as? Bool == true {
            let finished = message["endSession"] as? Bool == true
            Task { @MainActor in self.endCard(finished: finished) }
        }
        // The Watch setup (first time), from the phone.
        if let d = message["setup"] as? [String: Any] {
            let step = d.compactMapValues { v -> String? in
                if let s = v as? String { return s }
                if let i = v as? Int { return String(i) }
                return nil
            }
            Task { @MainActor in
                var typed: [String: Any] = step
                for k in ["target", "n", "of"] { if let s = step[k], let i = Int(s) { typed[k] = i } }
                self.applySetup(typed)
            }
        }
        if let m = message["setupRetry"] as? String { Task { @MainActor in self.setupRetry(m) } }
        if message["setupOK"] as? Bool == true { Task { @MainActor in self.setupOK() } }
        if message["setupEnd"] as? Bool == true { Task { @MainActor in self.setupEnd() } }
    }

    // A finished workout queued while the Watch was away.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["cardEnd"] as? Bool == true, userInfo["endSession"] as? Bool == true {
            Task { @MainActor in self.endCard(finished: true) }
        }
    }
}

private extension UInt32 {
    var nonZero: UInt32? { self == 0 ? nil : self }
}

/// Which build of the Watch app this is — shown on Home and reported to the phone, so a Watch
/// that missed an update is obvious instead of a mystery. Bump with each Watch delivery.
enum WatchBuild {
    static let tag = "2026-10-05.1"
}

