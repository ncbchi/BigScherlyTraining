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

    @Published private(set) var card: WatchCard? = nil {
        didSet { MotionRecorder.shared.setActive = card?.stage == "lifting" }   // pause GO only during a set
    }
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
        var grip = false                                                 // the bar-grip step (lift setups) rather than hold-still
        var holdAtBottom: Bool { lift == "squat" || lift == "bench" || caps == "HIP BELOW KNEE" }
    }
    @Published private(set) var setup: SetupStep? = nil
    /// When the phone last said the workout is over — Home goes back to its top screen.
    @Published private(set) var workoutEndedAt: Date? = nil
    /// ready (Go) · holding (still check) · capturing · checking (phone) · ok
    @Published private(set) var setupPhase = "ready"
    @Published private(set) var setupMessage: String? = nil
    /// What the phone measured, shown under "Got it" (e.g. "3 reps · 48 cm · 0.9 m/s").
    @Published private(set) var setupDetail: String? = nil
    /// Motion capture (debug): true while the raw stream since Go is being kept.
    private var captureOpen = false
    @Published private(set) var setupCount = 0
    @Published private(set) var holdStarted: Date? = nil
    private var setupGoAt = Date.distantPast
    private var setupSent = false
    private var setupLatest: [RepMotion] = []
    private var setupTapped = 0                           // reps already tapped for since Go
    private var setupFinish: Task<Void, Never>?
    /// This session was opened just for setup (from Settings, no workout): discard it afterwards.
    private var setupSolo = false

    /// DIAGNOSTIC (temporary): what the last still check measured, shown under its message.
    @Published private(set) var setupDiag: String? = nil
    private var setupAppliedAt = Date.distantPast

    fileprivate func applySetup(_ d: [String: Any]) {
        // The phone re-sends the step until it hears Go, and every sync carries it: a repeat of the
        // step on screen is ignored in every phase (it was cancelling the countdown midway).
        if let cur = setup, cur.n == (d["n"] as? Int ?? 1), cur.title == (d["title"] as? String ?? "") { return }
        setupAppliedAt = Date()
        setupDiag = nil
        setupDetail = nil
        setup = SetupStep(title: d["title"] as? String ?? "Setup", hint: d["hint"] as? String ?? "",
                          caps: d["caps"] as? String ?? "", kind: d["kind"] as? String ?? "reps",
                          target: d["target"] as? Int ?? 0, n: d["n"] as? Int ?? 1, of: d["of"] as? Int ?? 1,
                          lift: d["lift"] as? String ?? "body", grip: (d["grip"] as? Int ?? 0) == 1)
        stopCountdown()
        setupPhase = "ready"
        setupCount = 0
        setupFinish?.cancel(); setupFinish = nil
        if d["solo"] as? Int == 1 {
            setupSolo = true
            WorkoutSessionManager.shared.discardOnEnd = true        // nothing goes to Apple Health
        }
        // (a retry message, if one just arrived, stays up until Go)
        ensureSetupSession()
    }

    /// Setup only works inside a workout session: it keeps the app on screen with your arm down,
    /// and the motion sensors only run in one. The phone opens the Watch into a session, but if that
    /// didn't happen (the Watch app was just reinstalled, or you opened it yourself) start one here.
    /// Without a workout on the phone it's a setup-only session, thrown away afterwards.
    private func ensureSetupSession() {
        let sessions = WorkoutSessionManager.shared
        guard !sessions.isRunning else { return }
        if card == nil {
            setupSolo = true
            sessions.discardOnEnd = true                  // nothing goes to Apple Health
        }
        print("[Setup] no workout session running — starting one on the Watch")
        Task { await sessions.start() }
    }

    /// Go: right before you touch the weight.
    /// Go: tap, lower your arm, get set. A 3-second countdown (a tap each second) — nothing is measured
    /// until it ends, and your arm moving into place isn't counted as a rep (or a "set").
    @Published private(set) var countdownEnds: Date? = nil
    @Published private(set) var countdownTotal: Double = 3
    private var countdownTask: Task<Void, Never>?

    func setupGo() {
        guard setup != nil, setupPhase == "ready" else { return }
        // Measuring needs the workout session running FIRST: it's what keeps the app (and the motion
        // sensors) going once your wrist drops. Without one the countdown froze at 1 and "Hold still"
        // never finished. Start it, wait for it (a few seconds at most), then go.
        if !WorkoutSessionManager.shared.isRunning {
            ensureSetupSession()                          // (the app's in front now, so it can start)
            setupMessage = nil
            setupPhase = "starting"
            Task {
                for _ in 0..<25 where !WorkoutSessionManager.shared.isRunning {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard self.setupPhase == "starting" else { return }
                self.setupPhase = "ready"
                if WorkoutSessionManager.shared.isRunning {
                    self.setupGo()
                } else {
                    let why = WorkoutSessionManager.shared.lastError.map { " (\($0))" } ?? ""
                    self.setupMessage = "Your Watch couldn't start its workout\(why) — it needs one to keep measuring with your arm down. Close the app on your Watch, open it again, then tap Go."
                    WKInterfaceDevice.current().play(.retry)
                }
            }
            return
        }
        setupMessage = nil
        setupPhase = "countdown"
        // Still checks: 3 s. Rep steps: 5 s to get into the starting position — and then it waits
        // until you've actually settled there before it measures anything.
        let total = setup?.kind == "still" ? 3 : 5
        countdownTotal = Double(total)
        countdownEnds = Date().addingTimeInterval(Double(total))
        MotionRecorder.shared.calibrating = true          // arm moving into place: not a rep, not a set
        WatchBuzz.tap()                                   // Go: got it
        countdownTask?.cancel()
        countdownTask = Task {
            for left in stride(from: total - 1, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.setupPhase == "countdown" else { return }
                WatchBuzz.countdown(left)                 // tick-tick each second, quicker at the end
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, self.setupPhase == "countdown" else { return }
            self.countdownEnds = nil
            if self.setup?.kind == "still" {
                WatchBuzz.go()                             // measuring from here
                self.beginCapture()
            } else {
                self.setupPhase = "arming"                 // hold the starting position; it starts when you're still
                MotionRecorder.shared.waitForStillness(needed: 0.8, timeout: 12) { _ in
                    Task { @MainActor in
                        guard self.setupPhase == "arming" else { return }
                        WatchBuzz.go()                     // measuring from here
                        self.beginCapture()
                    }
                }
            }
        }
    }

    private func stopCountdown() {
        MotionRecorder.shared.cancelStillnessWait()
        countdownTask?.cancel(); countdownTask = nil
        countdownEnds = nil
    }

    /// After the countdown: measure.
    private func beginCapture() {
        guard let step = setup else { return }
        setupGoAt = Date()
        setupSent = false
        setupMessage = nil
        setupDetail = nil
        setupLatest = []
        setupTapped = 0
        setupCount = 0
        MotionRecorder.shared.beginCapture()              // motion capture: every sample from here
        captureOpen = true
        let device = WKInterfaceDevice.current()
        Self.sendLive(["setupGo": true,
                       "wrist": device.wristLocation == .left ? "left" : "right",
                       "crown": device.crownOrientation == .right ? "right" : "left"])
        if step.kind == "still" {
            setupPhase = "holding"
            holdStarted = Date()
            Task {
                // The start tap just shook the Watch: let it settle before measuring.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.setupPhase == "holding" else { return }
                MotionRecorder.shared.beginStillProbe()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let stillHolding = self.setupPhase == "holding"
                MotionRecorder.shared.endStillProbe { reading in           // (always ends the probe)
                    if stillHolding { self.stillMeasured(reading) }
                }
            }
        } else {
            setupPhase = "capturing"
            MotionRecorder.shared.calibrating = true
            // Presses and deadlifts go up first; squats and bench go down first.
            let upFirst = step.lift == "deadlift" || step.title.lowercased().contains("press")
            MotionRecorder.shared.setRepOrder(upFirst ? .upFirst : .downFirst)
            // Bottom holds: the Watch taps at exactly two seconds — "hold until the tap".
            MotionRecorder.shared.setPauseTarget(step.holdAtBottom ? 2.0 : nil)
        }
    }

    /// Limits for "still": arm hanging at your side moves far less than this; lowering an arm,
    /// shifting your feet or adjusting the strap moves far more.
    private static let stillShakeLimit = 0.35     // m/s², steady spread of vertical acceleration
    private static let stillRotLimit = 0.30       // rad/s, median rotation

    private func stillMeasured(_ g: GripReading) {
        let shake = g.shake, rot = g.rot, n = g.count
        holdStarted = nil
        let diag = n == 0 ? "no samples" :
            String(format: "measured %.2f m/s² · %.2f rad/s  (limit %.2f · %.2f) · tilt %.0f° · %d samples",
                   shake, rot, Self.stillShakeLimit, Self.stillRotLimit, g.tiltDeg, n)
        print("[Setup] still check: \(diag)")
        setupDiag = diag                                                    // DIAGNOSTIC
        finishCapture(reps: [], diag: diag)
        if n > 0, shake < Self.stillShakeLimit, rot < Self.stillRotLimit {
            setupPhase = "checking"
            // The grip: how the Watch sits and its resting zero — kept here, and sent to the phone.
            UserDefaults.standard.set(["tilt": g.tiltDeg, "zero": g.restZero, "at": Date().timeIntervalSince1970],
                                      forKey: "bst.watch.grip")
            Self.sendLive(["setupStillDone": true, "gripTilt": g.tiltDeg, "gripZero": g.restZero])
            return
        }
        let message = n == 0
            ? "Your Watch wasn't measuring — make sure the workout is running on it, then tap Go again."
            : (setup?.grip == true
               ? "Your grip moved — hold the bar (or your hand) completely still, then tap Go again."
               : "You moved a little — arm relaxed at your side, stand completely still, then tap Go again.")
        setupPhase = "ready"
        setupMessage = message
        WKInterfaceDevice.current().play(.retry)
        Self.sendLive(["setupStillFailed": message])                       // the phone says so too
    }

    /// "Exit setup" on the wrist: the phone closes its setup too (otherwise the next sync brings it back).
    func setupExit() {
        Self.sendLive(["setupExit": true])
        setupEnd()
    }

    /// The phone's sync says it has no setup running (it ended, or the phone app restarted): clear
    /// ours. (Not in the first moments after a step arrives — a sync can be overtaken by the step.)
    fileprivate func phoneHasNoSetup() {
        guard setup != nil, Date().timeIntervalSince(setupAppliedAt) > 3 else { return }
        print("[Setup] the phone has no setup running — clearing it here")
        setupEnd()
    }

    /// Setup reps since Go, as they're counted.
    fileprivate func setupLive(_ reps: [RepMotion]) {
        guard let step = setup, setupPhase == "capturing" else { return }
        let mine = reps.filter { $0.start >= setupGoAt.addingTimeInterval(-0.5) }
        // A tap for every rep it counts (setup only, for now — workouts can use WatchBuzz.rep() later).
        if mine.count > setupTapped {
            setupTapped = mine.count
            WatchBuzz.rep()
        }
        setupLatest = mine
        setupCount = mine.count
        if let data = try? JSONEncoder().encode(mine) { Self.sendLive(["setupLive": data]) }
        if step.target > 0, mine.count >= step.target, setupFinish == nil {
            // Target reached: give the last rep a moment to settle, then hand them over — but only if
            // the count still holds. (A rep counted early can be withdrawn when the analysis sees more;
            // handing over then sent "Only 2 reps" for a full set of 3. Now it just keeps measuring.)
            setupFinish = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                guard self.setupLatest.count >= step.target else { self.setupFinish = nil; return }
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
        finishCapture(reps: reps, diag: nil)
        Self.sendLive(["setupReps": data])
    }

    /// Motion capture (debug tool): stop recording, pack the raw stream and send it to the phone
    /// with the Watch's own count — the phone adds its verdict and keeps it for Copy.
    private func finishCapture(reps: [RepMotion], diag: String?) {
        guard captureOpen, let step = setup else { return }
        captureOpen = false
        let repsData = (try? JSONEncoder().encode(reps)) ?? Data()
        let title = step.title, lift = step.lift, kind = step.kind, n = step.n, of = step.of
        let build = WatchBuild.tag
        MotionRecorder.shared.endCapture { samples in
            guard samples.count >= 50 else { return }
            let packed = MotionCapturePack.pack(samples)
            var m: [String: Any] = ["motionCapture": packed.data, "mcReps": repsData,
                                    "mcTitle": title, "mcLift": lift, "mcKind": kind, "mcN": n, "mcOf": of,
                                    "mcStart": packed.startT, "mcHz": MotionCapturePack.outRate,
                                    "mcBuild": build, "mcAnalyzer": RepAnalyzer.version, "mcRaw": samples.count]
            if let diag { m["mcDiag"] = diag }
            WatchState.sendLive(m)
        }
    }

    fileprivate func setupRetry(_ message: String) {
        stopCountdown()
        setupDiag = nil
        setupMessage = message
        setupPhase = "ready"
        setupFinish?.cancel(); setupFinish = nil
        WKInterfaceDevice.current().play(.retry)
    }

    fileprivate func setupOK(detail: String?) {
        setupDetail = detail
        setupPhase = "ok"
        WKInterfaceDevice.current().play(.success)
    }

    func setupEnd() {
        stopCountdown()
        if captureOpen { captureOpen = false; MotionRecorder.shared.endCapture { _ in } }   // nothing to send
        setupDetail = nil
        setup = nil
        setupPhase = "ready"
        setupMessage = nil
        setupFinish?.cancel(); setupFinish = nil
        MotionRecorder.shared.endCalibration()
        updatePauseTarget()                               // back to the exercise's own pause
        if setupSolo {                                    // a session just for setup: close it, unsaved
            setupSolo = false
            if card == nil, WorkoutSessionManager.shared.isRunning {
                Task { await WorkoutSessionManager.shared.end() }
            }
        }
    }

    /// Ask the phone for the card as it is now (on launch, and when the app comes back).
    /// Ask the phone for the card (and any setup step waiting for Go). The answer comes back on the
    /// reply and goes through the normal message handler — so it works even when the phone thinks
    /// the Watch isn't reachable (it only answers; it doesn't have to reach out).
    func requestCard() {
        guard WCSession.default.activationState == .activated else { return }
        let me = self                                   // (main-actor class: safe to hand to the reply)
        var pull: [String: Any] = ["cardPull": true, "watchBuild": WatchBuild.tag]
        let acks = LinkBook.shared.takeAcks()
        if !acks.isEmpty { pull["acks"] = acks }
        WCSession.default.sendMessage(pull, replyHandler: { reply in
            // The phone's events that hadn't been confirmed (each handled once), then the state.
            for e in (reply["events"] as? [[String: Any]]) ?? [] {
                if let mid = e["mid"] as? String {
                    if !LinkBook.shared.hasSeen(mid) {                               // DIAGNOSTIC: rescued
                        print("[Link] the pull caught an event the handshake missed")
                        Task { @MainActor in LinkStats.shared.rescued += 1 }
                    }
                    LinkBook.shared.ackLater(mid)
                }
                me.session(WCSession.default, didReceiveMessage: e)
            }
            var state = reply
            state.removeValue(forKey: "events")
            if !state.isEmpty { me.session(WCSession.default, didReceiveMessage: state) }
        }, errorHandler: { e in
            for a in acks { LinkBook.shared.ackLater(a) }       // confirm them on the next pull
            print("[Link] pull: \(e.localizedDescription)")
        })
    }

    private var pullTask: Task<Void, Never>?
    /// While the app is open: pull every 2 seconds, alongside the live messages — the card and setup
    /// step are never more than 2 s stale, and any of the phone's events that didn't get through
    /// directly come back on the reply. (Stops when the wrist drops or the app closes.)
    func startPulling() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.requestCard()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func stopPulling() { pullTask?.cancel(); pullTask = nil }

    /// The phone came back in reach: catch up at once (the card and any setup step).
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.requestCard() }
    }

    fileprivate func applyCard(_ data: Data, note: String?, live: [Double], demo: Bool, step: Double?, warn: Bool?) {
        guard let c = try? JSONDecoder().decode(WatchCard.self, from: data) else { return }
        card = c
        reconcileDetections(with: c)
        WorkoutSessionManager.shared.discardOnEnd = demo          // a demo session isn't saved
        cardNote = note
        cardLiveSpeeds = live
        cardDemo = demo
        if let step, step > 0 { weightStep = step }
        if let warn { restWarning = warn }
        applyTheme(c.accent, inkWhite: c.accentInkWhite)
        scheduleRestTaps()
    }

    /// Your theme accent — from the card during a workout, and from every pull otherwise (setup from
    /// Settings has no card, and a reinstalled Watch app starts with no saved accent).
    fileprivate func applyTheme(_ accent: UInt32?, inkWhite: Bool?) {
        if let a = accent, a != 0, a != accentHex {
            accentHex = a
            UserDefaults.standard.set(Int(a), forKey: "bst.watch.accent")
        }
        if let ink = inkWhite, ink != accentInkWhite {
            accentInkWhite = ink
            UserDefaults.standard.set(ink, forKey: "bst.watch.accentInk")
        }
    }

    /// No card. `finished`: the phone's workout ended, so the session ends too
    /// (saved for real workouts, discarded for demos).
    fileprivate func endCard(finished: Bool) {
        if finished, card != nil || WorkoutSessionManager.shared.isRunning { workoutEndedAt = Date() }
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
        // Logged: every suggestion for a set that ended before now is out of date. Clear them all
        // first — clearing just this one showed the next in the queue (another stale "Log set"),
        // which kept rest off the tile.
        detections.removeAll { $0.end <= Date() }
        if presentedDetection != nil { presentedDetection = nil }
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
    /// Events that must arrive (exactly once). Everything else — heart rate, reps as they come, the
    /// sound cue — is a live stream: best-effort, a missed sample doesn't matter.
    nonisolated private static let eventKeys: Set<String> =
        ["cardAction", "setupGo", "setupStillDone", "setupStillFailed", "setupExit", "setupReps",
         "setStarted", "detectedSet", "sessionActive", "motionCapture", "dbgGo", "dbgStopped", "dbgDone"]

    nonisolated static func sendLive(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        guard let key = msg.keys.first(where: { eventKeys.contains($0) }) else {
            // A live stream. (Not gated on "reachable" — that flag is unreliable; a failed try is fine.)
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
            return
        }
        // An event: live, with a handshake and fast retries (see WatchLink).
        WatchLink.send(msg, label: key)
    }

    /// A set log: live, confirmed and handled once by the phone (queued delivery only as the last resort).
    nonisolated private static func sendReliably(_ msg: [String: Any]) {
        WatchLink.send(msg, label: msg.keys.sorted().first ?? "log")            // live, confirmed, once-only
    }


    // MARK: - Detected sets

    /// A finished set came in from the motion recorder.
    func handleDetectedSet(reps: [RepMotion], start: Date, end: Date) {
        guard let workout = activeWorkout, !reps.isEmpty else { return }
        // Already logged (from the phone or Lock Screen) and resting: this is that set's tail —
        // don't show Log set for the next one.
        if let c = card, c.stage == "resting", let rs = c.restStart, rs <= end.addingTimeInterval(10) { return }
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

    /// The phone's card has moved on, so any "Log set" the Watch was suggesting for an earlier set is
    /// out of date: resting means the set was logged on the phone (or Lock Screen); lifting means a
    /// new set has started. Without this, a suggestion from wrist motion (walking to the bar,
    /// loading plates) took over the tile — no lifting timer, and no rest after logging on the phone.
    private func reconcileDetections(with c: WatchCard) {
        let cutoff: Date?
        switch c.stage {
        case "resting": cutoff = c.restStart?.addingTimeInterval(15)   // sets that ended before this rest
        case "lifting": cutoff = c.setStart                             // sets from before this one began
        default: cutoff = nil
        }
        guard let cut = cutoff else { return }
        detections.removeAll { $0.end <= cut }
        if let p = presentedDetection, p.end <= cut { presentedDetection = nil }   // (shows the next newer one, if any)
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
        MotionRecorder.shared.setRepOrder(.forExercise(ex?.name))
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
        MotionRecorder.shared.onCalibReps = { [weak self] reps in
            self?.setupLive(reps)
            WatchDebugRecorder.shared.live(reps)              // DEBUG recorder (removed before release)
        }
        MotionRecorder.shared.onCalibEnded = { [weak self] reps, _, _ in
            self?.setupSetEnded(reps)
            WatchDebugRecorder.shared.setEnded(reps)          // DEBUG recorder
        }
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
        if let mid = message["mid"] as? String, !LinkBook.shared.firstTime(mid) { return }   // already handled
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
        if let a = message["themeAccent"] as? Int {
            let ink = message["themeInkWhite"] as? Bool
            Task { @MainActor in self.applyTheme(UInt32(truncatingIfNeeded: a), inkWhite: ink) }
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
                for k in ["target", "n", "of", "solo", "grip"] { if let s = step[k], let i = Int(s) { typed[k] = i } }
                self.applySetup(typed)
            }
        }
        if let m = message["setupRetry"] as? String { Task { @MainActor in self.setupRetry(m) } }
        if message["setupActive"] as? Bool == false { Task { @MainActor in self.phoneHasNoSetup() } }
        if message["setupOK"] as? Bool == true {
            let detail = message["detail"] as? String
            Task { @MainActor in self.setupOK(detail: detail) }
        }
        if message["setupEnd"] as? Bool == true { Task { @MainActor in self.setupEnd() } }
        // DEBUG recorder (removed before release): the phone arms / ends it.
        if let d = message["dbgArm"] as? [String: Any] {
            let lift = d["lift"] as? String ?? "other", title = d["title"] as? String ?? "Recording"
            let upFirst = (d["upFirst"] as? Int ?? 0) == 1
            Task { @MainActor in WatchDebugRecorder.shared.armed(lift: lift, title: title, upFirst: upFirst) }
        }
        if message["dbgEnd"] as? Bool == true { Task { @MainActor in WatchDebugRecorder.shared.ended() } }
    }

    // A finished workout queued while the Watch was away.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        self.session(session, didReceiveMessage: userInfo)      // queued delivery: same handling
    }

    /// The phone's events, sent directly: handle (once) and confirm in the reply.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        self.session(session, didReceiveMessage: message)
        replyHandler(["ack": message["mid"] as? String ?? ""])
    }
}

private extension UInt32 {
    var nonZero: UInt32? { self == 0 ? nil : self }
}

/// Which build of the Watch app this is — shown on Home and reported to the phone, so a Watch
/// that missed an update is obvious instead of a mystery. Bump with each Watch delivery.
enum WatchBuild {
    static let tag = "2026-10-07.1"
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
