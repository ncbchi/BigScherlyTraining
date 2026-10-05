import Foundation
import Combine
import ActivityKit
import UIKit
import AVFoundation

// MARK: - Live session
// One place that owns an in-progress workout's rest timer and set logging, so the
// workout screen and the Lock Screen Live Activity always agree. It also builds the
// Live Activity's snapshot (timer, current set, heart rate, last set's Watch data…)
// and answers the card's buttons — even when the app is in the background.
// Target membership: BigScherlyTraining only.

@MainActor
final class LiveSessionController: ObservableObject {
    static let shared = LiveSessionController()

    @Published private(set) var restEnd: Date? = nil
    @Published private(set) var restTotal: Int = 0
    @Published private(set) var workoutId: String? = nil
    /// Bumped on every change, so the in-app live card redraws with the Lock Screen card.
    @Published private(set) var revision = 0

    private weak var store: AppStore?
    private var activity: Activity<WorkoutActivityAttributes>?
    /// Demo Mode also starts the Watch workout session (discarded at the end, never saved to
    /// Health) — so the demo behaves exactly like a real workout on the wrist. Set to false to stop.
    static let demoStartsWatch = true
    /// The workout the Watch was launched for (so it's launched once per workout).
    private var watchLaunchedFor: String?
    /// This card's push token: the server sends rest alerts into it while the app's asleep.
    private var activityToken: String?
    /// iOS 17.2+: lets the server bring a closed card back (with the alert in it).
    private var startToken: String?
    /// This rest's alerts are with the server (into the card) — no notifications scheduled.
    private var alertsOnServer = false
    private var lastAlertUpload = Date.distantPast
    private var openedAt = Date()
    private var restStart: Date? = nil

    // The set loop (left pane)
    private var setStart: Date? = nil           // lifting since (Start set / the Watch's first rep)
    private var logNeeded = false               // the Watch saw the set end; not logged yet

    // What the right pane shows
    private var userView: LiveView = .heartRate // the view you picked
    private var lastSensorView: LiveView = .speed
    private var afterSet = false                // showing the set you just did, until the next set starts

    // Log-set editor (weight in lb)
    private var editing = false
    private var editorAuto = false              // opened by the Watch; closes itself after 10 s idle
    private var editorUntil: Date? = nil
    private var dReps = 0
    private var dWeightLb = 0.0
    private var dRPE = 8.0
    private var editorTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var lastDetectionSeen: Date? = nil
    /// Demo Mode: the reps you watched arrive, kept for the set once it's logged (by set id).
    private var demoMotions: [String: SetMotion] = [:]

    // Heart rate
    private var hrSamples: [(Date, Int)] = []
    private var maxHR = 190

    private var bag = Set<AnyCancellable>()
    private var lastBackgroundHRPush = Date.distantPast

    /// Everything needed to carry on after iOS closes the app in the background and
    /// restarts it for a Lock Screen tap — before any network call finishes.
    private struct Saved: Codable {
        var workout: Workout
        var openedAt: Date
        var restStart: Date?, restEnd: Date?, restTotal: Int
        var setStart: Date?, logNeeded: Bool
        var userView: LiveView, lastSensorView: LiveView, afterSet: Bool
        var editing: Bool, editorAuto: Bool, editorUntil: Date?
        var dReps: Int, dWeightLb: Double, dRPE: Double
        var lastDetectionSeen: Date?
    }
    private let savedKey = "bst_live_session"
    private var pushTask: Task<Void, Never>?

    private init() {}

    private var isDemo: Bool { store?.isDemoMode == true || APIConfig.useMock }

    /// Called once at app launch (before any Lock Screen button can fire).
    func attach(_ store: AppStore) {
        self.store = store
        LiveIntentRouter.handler = { action in await LiveSessionController.shared.handle(action) }
        WatchBridge.shared.$liveHeartRate
            .sink { [weak self] bpm in self?.heartRate(bpm) }
            .store(in: &bag)
        SetMotionStore.shared.$bySet
            .dropFirst()
            .sink { [weak self] _ in self?.push(now: true) }
            .store(in: &bag)
        // The Watch counted the first rep → lifting.
        WatchBridge.shared.$liveSetStartedAt
            .compactMap { $0 }
            .filter { _ in !SetupEngine.shared.active }        // a Watch setup set isn't a workout set
            .sink { [weak self] _ in self?.startSet() }
            .store(in: &bag)
        // The Watch saw the set end → open the log editor for 10 s, pre-filled.
        WatchBridge.shared.$lastDetection
            .compactMap { $0 }
            .filter { _ in !SetupEngine.shared.active }
            .sink { [weak self] d in self?.setEnded(reps: d.reps, workoutId: d.workoutId, at: d.receivedAt) }
            .store(in: &bag)
        // Re-adopt a card left running if the app was relaunched mid-workout, and pick up
        // exactly where the session was (rest, set timer, chosen view, the workout itself).
        if let a = Activity<WorkoutActivityAttributes>.activities.first {
            activity = a
            workoutId = a.attributes.workoutId
            restore()
            watch(a)
        }
        // A card the server started (brought back after you closed it): adopt it.
        Task { [weak self] in
            for await a in Activity<WorkoutActivityAttributes>.activityUpdates { self?.adopt(a) }
        }
        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await data in Activity<WorkoutActivityAttributes>.pushToStartTokenUpdates {
                    self?.startToken = data.map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        // Headphones in or out mid-rest: the alerts' sound changes with it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.resting == true { self?.rescheduleRestAlerts() } }
        }
    }

    // MARK: Session lifecycle

    /// The workout screen opened. Starts (or re-adopts) the Live Activity.
    func begin(workoutId id: String) {
        LocalReminders.cancelWorkout(id)                 // started: no "today's workout" nudge
        // Open the Watch straight into its workout session: it stays on your wrist (every raise
        // brings the card back), taps for rest, and the phone keeps quiet. Once per workout.
        if watchLaunchedFor != id, !isDemo || Self.demoStartsWatch,
           WatchBridge.shared.watchAppAvailable, !WatchBridge.shared.watchSessionLive {
            watchLaunchedFor = id
            WatchBridge.shared.startWatchWorkout { _ in }
        }
        guard let w = store?.workouts.first(where: { $0.id == id }), !w.completed else { return }
        if workoutId != id {
            workoutId = id
            openedAt = Date()
            hrSamples = []
            setStart = nil; logNeeded = false; afterSet = false
            editing = false; editorAuto = false; editorUntil = nil
            restEnd = nil; restStart = nil; restTotal = 0
            Task { maxHR = await HealthActivityReader.observedMaxHR(demo: isDemo) ?? 190 }
        }
        if let a = activity, a.attributes.workoutId != id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            activityToken = nil
        }
        // Settings ▸ Lock Screen card (on unless turned off). Off: no card, but the session
        // itself (rest timer, saving across restarts) carries on as normal.
        let cardOn = UserDefaults.standard.object(forKey: "bst_live_activity") as? Bool ?? true
        if !cardOn, let a = activity { activity = nil; activityToken = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }
        if cardOn, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled, let state = makeState() {
            activity = try? Activity.request(attributes: WorkoutActivityAttributes(workoutId: id, title: w.title),
                                             content: ActivityContent(state: state, staleDate: staleDate()),
                                             pushType: .token)          // so the server can send rest alerts into it
            if let a = activity { watch(a) }
        }
        push(now: true)
    }

    private func persist() {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return }
        let sv = Saved(workout: w, openedAt: openedAt, restStart: restStart, restEnd: restEnd, restTotal: restTotal,
                       setStart: setStart, logNeeded: logNeeded, userView: userView, lastSensorView: lastSensorView,
                       afterSet: afterSet, editing: editing, editorAuto: editorAuto, editorUntil: editorUntil,
                       dReps: dReps, dWeightLb: dWeightLb, dRPE: dRPE, lastDetectionSeen: lastDetectionSeen)
        if let data = try? JSONEncoder().encode(sv) { UserDefaults.standard.set(data, forKey: savedKey) }
    }

    private func restore() {
        guard let store, let wid = workoutId, let data = UserDefaults.standard.data(forKey: savedKey),
              let sv = try? JSONDecoder().decode(Saved.self, from: data), sv.workout.id == wid else { return }
        // The saved copy is the newest for this workout (it has sets logged from the card).
        if let i = store.workouts.firstIndex(where: { $0.id == wid }) { store.workouts[i] = sv.workout }
        else { store.workouts.append(sv.workout) }
        openedAt = sv.openedAt
        restStart = sv.restStart; restEnd = sv.restEnd; restTotal = sv.restTotal
        if (restEnd ?? .distantPast) <= Date() { restStart = nil; restEnd = nil }
        setStart = sv.setStart; logNeeded = sv.logNeeded
        userView = sv.userView; lastSensorView = sv.lastSensorView; afterSet = sv.afterSet
        editing = sv.editing; editorAuto = sv.editorAuto; editorUntil = sv.editorUntil
        if editing, editorAuto, (editorUntil ?? .distantPast) <= Date() { editing = false; editorAuto = false; editorUntil = nil }
        dReps = sv.dReps; dWeightLb = sv.dWeightLb; dRPE = sv.dRPE
        lastDetectionSeen = sv.lastDetectionSeen
        scheduleStageRefresh()
    }

    /// Workout finished (or abandoned): close the card.
    func end() {
        SetVideoRecorder.shared.stopAll()
        endRest()
        let a = activity
        activity = nil
        activityToken = nil
        workoutId = nil
        editing = false
        watchLaunchedFor = nil
        WatchBridge.shared.sendCardEnd(endSession: true)       // the Watch ends its session too
        UserDefaults.standard.removeObject(forKey: savedKey)
        Task { await a?.end(nil, dismissalPolicy: .default) }
    }

    /// Logout: close any card immediately.
    func endAll() {
        SetVideoRecorder.shared.stopAll()
        cancelRestAlerts()
        watchLaunchedFor = nil
        WatchBridge.shared.sendCardEnd(endSession: true)
        activity = nil; workoutId = nil; activityToken = nil
        restEnd = nil; restStart = nil
        UserDefaults.standard.removeObject(forKey: savedKey)
        Task { for a in Activity<WorkoutActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    // MARK: Rest (was in the workout screen)

    func startRest(_ seconds: Int) {
        guard seconds > 0 else { return }
        restTotal = seconds
        restStart = Date()
        restEnd = Date().addingTimeInterval(TimeInterval(seconds))
        RestTimerEngine.shared.requestPermissionIfNeeded()
        rescheduleRestAlerts()
        WatchBridge.shared.startRest(seconds: seconds)
        setStart = nil
        scheduleStageRefresh()
        push(now: true)
    }

    /// "Rest's up · Set 3 of 5" / "Back Squat · 5 × 275 lb" — the set you're about to do.
    private func restAlertTitle() -> String {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              let nx = Self.nextSet(w) else { return "Rest's up" }
        return "Rest's up · Set \(nx.2) of \(nx.0.sets.count)"
    }
    private func restAlertBody() -> String {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              let nx = Self.nextSet(w) else { return "Time for your next set" }
        return "\(nx.0.name) · \(nx.1.targetReps) × \(nx.1.targetWeight > 0 ? StatsUnits.weightText(nx.1.targetWeight) : "BW")"
    }

    func addRest(_ s: Int) {
        guard let end = restEnd else { return }
        let newEnd = max(Date(), end).addingTimeInterval(TimeInterval(s))
        restTotal += s
        restEnd = newEnd
        let left = Int(newEnd.timeIntervalSinceNow)
        rescheduleRestAlerts()
        WatchBridge.shared.startRest(seconds: left)
        scheduleStageRefresh()
        push(now: true)
    }

    func endRest() {
        restEnd = nil; restStart = nil
        cancelRestAlerts()
        push(now: true)
    }

    // MARK: Logging (was in the workout screen)

    /// Log or edit a set. Returns true when the current exercise changed (the screen
    /// opens the next one). A first-time log starts the exercise's rest.
    @discardableResult
    func log(workoutId wid: String, exerciseId: String, setId: String,
             reps: Int, weight: Double, rpe: Double?) -> Bool {
        guard let store,
              let wi = store.workouts.firstIndex(where: { $0.id == wid }),
              let ei = store.workouts[wi].exercises.firstIndex(where: { $0.id == exerciseId }),
              let si = store.workouts[wi].exercises[ei].sets.firstIndex(where: { $0.id == setId }) else { return false }
        let before = Self.current(store.workouts[wi])?.id
        let wasLogged = store.workouts[wi].exercises[ei].sets[si].loggedReps != nil
        store.workouts[wi].exercises[ei].sets[si].loggedReps = reps
        store.workouts[wi].exercises[ei].sets[si].loggedWeight = weight
        store.workouts[wi].exercises[ei].sets[si].rpe = rpe
        if store.workouts[wi].exercises[ei].sets[si].loggedAt == nil {
            store.workouts[wi].exercises[ei].sets[si].loggedAt = Date()
        }
        let ex = store.workouts[wi].exercises[ei]
        store.saveLoggedSets(workoutId: wid, exercise: ex)
        store.checkForPRs(in: store.workouts[wi])
        store.sendActiveWorkoutToWatch()        // the Watch attaches its detected motion to this set
        WatchBridge.shared.clearDetection()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if !wasLogged, isDemo, let first = WatchBridge.shared.liveRepMotions.first,
           let last = WatchBridge.shared.liveRepMotions.last {
            demoMotions[setId] = SetMotion(id: UUID().uuidString, workoutId: wid, exerciseId: exerciseId, setId: setId,
                                           exerciseName: store.workouts[wi].exercises[ei].name, start: first.start, end: last.end,
                                           reps: WatchBridge.shared.liveRepMotions, autoDetected: true, analyzerVersion: 1)
        }
        if !wasLogged {
            SetVideoRecorder.shared.setEnded()      // stop filming; it saves to the Camera Roll
            setStart = nil
            logNeeded = false
            closeEditor()
            // During the rest, the right pane shows the set you just did (if the Watch has it).
            // The Watch sends a set's data a moment after it's logged, so with a live Watch
            // session, show the after-set view and let the data fill in.
            afterSet = isDemo || WatchBridge.shared.watchSessionLive
                || SetMotionStore.shared.motion(workoutId: wid, setId: setId) != nil
            // Settings ▸ Start rest automatically (on unless turned off)
            let autoRest = UserDefaults.standard.object(forKey: "bst_auto_rest") as? Bool ?? true
            // Settings ▸ Notifications ▸ Rest timer ▸ Default rest, when the programme doesn't say.
            let rest = ex.restSeconds > 0 ? ex.restSeconds : NotifPrefs.shared.s.defaultRest
            if Self.current(store.workouts[wi]) != nil && autoRest { startRest(rest) } else { endRest() }
        }
        push(now: true)
        return Self.current(store.workouts[wi])?.id != before
    }

    // MARK: The set loop

    /// Start set (button on the card, or the Watch's first rep).
    func startSet() {
        guard workoutId != nil, stage != .done, setStart == nil || logNeeded else { return }
        if restEnd != nil {
            restEnd = nil; restStart = nil
            cancelRestAlerts()
        }
        setStart = Date()
        logNeeded = false
        afterSet = false                            // back to the view you were on
        SetVideoRecorder.shared.setStarted()        // set videos on: film this set
        scheduleStageRefresh()
        push(now: true)
        if isDemo { simulateDemoSet() }
    }

    /// The Watch saw the set end: open the editor for 10 s, pre-filled with its rep count.
    private func setEnded(reps: Int, workoutId wid: String, at: Date) {
        guard wid == workoutId, lastDetectionSeen != at, Date().timeIntervalSince(at) < 120 else { return }
        lastDetectionSeen = at
        if setStart == nil { setStart = at }
        logNeeded = true
        SetVideoRecorder.shared.setEnded()          // the Watch saw you rack it: stop filming
        openEditor(auto: true, reps: reps)
    }

    private func openEditor(auto: Bool, reps: Int? = nil) {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              let nx = Self.nextSet(w) else { return }
        let ex = nx.0, set = nx.1
        dReps = reps ?? set.targetReps
        dWeightLb = ex.sets.last(where: { $0.loggedWeight != nil })?.loggedWeight ?? set.targetWeight
        dRPE = ex.sets.last(where: { $0.rpe != nil })?.rpe ?? 8
        editing = true
        editorAuto = auto
        if auto { extendEditor() } else { editorUntil = nil; editorTask?.cancel() }
        push(now: true)
    }

    /// Auto editor: close 10 s after the last touch. (If the app is asleep, iOS closes it
    /// on its own at the card's stale date.)
    private func extendEditor() {
        editorUntil = Date().addingTimeInterval(10)
        editorTask?.cancel()
        editorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_200_000_000)
            guard !Task.isCancelled, let self, self.editing, self.editorAuto else { return }
            self.closeEditor()
            self.push(now: true)
        }
    }

    private func closeEditor() {
        editing = false; editorAuto = false; editorUntil = nil
        editorTask?.cancel()
    }

    /// Redraw when rest ends (Start set) while the app is awake. Asleep, iOS redraws at the stale date.
    private func scheduleStageRefresh() {
        stageTask?.cancel()
        guard let end = restEnd else { return }
        let wait = max(0, end.timeIntervalSinceNow) + 0.3
        stageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.push(now: true)
        }
    }

    /// Demo Mode only: pretend the Watch saw the set end ~20 s after Start, so App Review
    /// (and you) can see the 10-second log window without a Watch.
    private func simulateDemoSet() {
        demoTask?.cancel()
        WatchBridge.shared.demoLive(reps: [])
        demoTask = Task { [weak self] in
            guard let self, let wid = self.workoutId, let w = self.store?.workouts.first(where: { $0.id == wid }),
                  let nx = Self.nextSet(w) else { return }
            // Whole reps, the way the Watch sends them: each a little slower than the last,
            // the pause shortening as you tire, and one rep a touch shallow.
            let target = max(1, nx.1.targetReps)
            let base = Self.demoBaseSpeed(nx.0.name)
            let pauseGoal = PauseTarget.target(nx.0)
            var reps: [RepMotion] = []
            var t = Date().addingTimeInterval(3)
            try? await Task.sleep(nanoseconds: 3_000_000_000)          // unrack and set up
            for i in 0..<target {
                guard !Task.isCancelled, self.isDemo, self.stage == .lifting, !self.logNeeded else { return }
                let f = Double(i)
                let v = max(0.12, base * (1 - 0.055 * f) + Double.random(in: -0.02...0.02))
                let ecc = 1.7 + Double.random(in: -0.25...0.25)
                let pause = pauseGoal.map { max(0.3, $0 + 0.1 - 0.15 * f + Double.random(in: -0.12...0.12)) }
                    ?? Double.random(in: 0.1...0.3)
                let travel = 0.62 + Double.random(in: -0.012...0.012) - (target >= 4 && i == target - 2 ? 0.045 : 0)
                let conc = travel / v
                let end = t.addingTimeInterval(ecc + pause + conc)
                reps.append(RepMotion(index: i + 1, start: t, end: end,
                                      eccentricSec: (ecc * 10).rounded() / 10, bottomPauseSec: (pause * 10).rounded() / 10,
                                      concentricSec: (conc * 10).rounded() / 10, topPauseSec: 0.6, travelM: travel,
                                      meanVelocity: (v * 100).rounded() / 100, peakVelocity: (v * 135).rounded() / 100,
                                      stickingPoint: nil, driftM: 0.01))
                t = end.addingTimeInterval(0.6)
                WatchBridge.shared.demoLive(reps: reps)
                self.scheduleCardToWatch(now: true)                       // the Watch shows each rep as it lands
                try? await Task.sleep(nanoseconds: 2_600_000_000)
            }
            guard !Task.isCancelled, self.isDemo, self.stage == .lifting, !self.editing, !reps.isEmpty else { return }
            // Same path a real Watch takes: the detection arrives, the set ends, Log ✓ appears.
            WatchBridge.shared.demoDetection(workoutId: wid, reps: target,
                                             velocity: reps.map { $0.meanVelocity }.reduce(0, +) / Double(reps.count))
        }
    }

    /// Believable bar speeds (m/s) for Demo Mode.
    static func demoBaseSpeed(_ name: String) -> Double {
        let n = name.lowercased()
        if n.contains("bench") { return 0.48 }
        if n.contains("dead") { return 0.52 }
        if n.contains("squat") { return 0.56 }
        if n.contains("press") { return 0.58 }
        return 0.62
    }

    /// Where the left pane is.
    var stage: LiveStage {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return .ready }
        if Self.nextSet(w) == nil { return .done }
        if resting { return .resting }
        if setStart != nil || logNeeded { return .lifting }
        return .ready
    }

    // MARK: Card buttons

    func handle(_ action: LiveAction) async {
        switch action {
        case .prevView, .nextView:
            let avail = available()
            guard !avail.isEmpty else { return }
            let cur = avail.firstIndex(of: shownView()) ?? 0
            var step = -1
            if case .nextView = action { step = 1 }
            pick(avail[(cur + step + avail.count) % avail.count])
        case .show(let v):
            pick(v)
        case .startSet:
            startSet()
        case .rest(let s):
            if s <= 0 { endRest() } else { addRest(s) }
        case .log(let a):
            logAction(a)
        }
        // Send the new card before returning. Once a button's action returns, iOS may put
        // the app straight back to sleep — a scheduled update could then wait seconds.
        await sendNow()
    }

    private func pick(_ v: LiveView) {
        userView = v
        afterSet = false
        if v.isSensor { lastSensorView = v }
    }

    /// Settings ▸ Weight steps: small (2.5 lb / 1.25 kg) or standard (5 lb / 2.5 kg).
    private var displayStep: Double {
        let small = UserDefaults.standard.string(forKey: "bst_weight_step") == "small"
        return StatsUnits.isKg ? (small ? 1.25 : 2.5) : (small ? 2.5 : 5)
    }
    private var weightStepLb: Double { StatsUnits.isKg ? displayStep / 0.45359237 : displayStep }

    private func logAction(_ a: String) {
        let kg = StatsUnits.isKg
        switch a {
        case "open":
            openEditor(auto: false)
            return
        case "cancel":
            closeEditor()
            return
        case "reps+": dReps = min(50, dReps + 1)
        case "reps-": dReps = max(0, dReps - 1)
        case "weight+": dWeightLb = max(0, dWeightLb + weightStepLb)
        case "weight-": dWeightLb = max(0, dWeightLb - weightStepLb)
        case "rpe+": dRPE = min(10, dRPE + 0.5)
        case "rpe-": dRPE = max(1, dRPE - 0.5)
        case "commit":
            guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
                  let nx = Self.nextSet(w) else { closeEditor(); return }
            let ex = nx.0, set = nx.1
            // Round to the nearest plate step so kg ↔ lb conversion never leaves 184.99.
            let step = displayStep
            let shown = (StatsUnits.weight(dWeightLb) / step).rounded() * step
            let lb = kg ? shown / 0.45359237 : shown
            log(workoutId: wid, exerciseId: ex.id, setId: set.id, reps: dReps, weight: lb, rpe: dRPE)
            return
        default:
            return
        }
        if editorAuto { extendEditor() }            // any adjustment restarts the 10 s
    }

    // MARK: Live inputs

    private func heartRate(_ bpm: Int?) {
        guard workoutId != nil, let bpm else { return }
        if hrSamples.last.map({ Date().timeIntervalSince($0.0) >= 5 }) ?? true {
            hrSamples.append((Date(), bpm))
            hrSamples.removeAll { Date().timeIntervalSince($0.0) > 1800 }
        }
        // Redraw for heart rate every few seconds only when it's on screen; otherwise every
        // 15 s (the Dynamic Island shows it). Fewer background redraws = snappier taps.
        if shownView() == .heartRate && !editing {
            push(now: false)
        } else if Date().timeIntervalSince(lastBackgroundHRPush) >= 15 {
            lastBackgroundHRPush = Date()
            push(now: false)
        }
    }

    // MARK: Pushing to the card

    /// Build and send the card right now; returns once iOS has it. Cancels any pending
    /// scheduled update (this one supersedes it).
    private func sendNow() async {
        pushTask?.cancel()
        pushTask = nil
        guard let a = activity, let s = makeState() else { return }
        persist()
        await a.update(ActivityContent(state: s, staleDate: staleDate()))
    }

    /// Coalesced: at most one update every ~2 s unless `now`.
    private func push(now: Bool) {
        revision &+= 1                                  // the in-app card redraws now
        scheduleCardToWatch(now: now)                   // the Watch mirrors the same card
        guard activity != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled, let self, let a = self.activity, let s = self.makeState() else { return }
            self.persist()
            await a.update(ActivityContent(state: s, staleDate: self.staleDate()))
            if self.alertsOnServer, self.resting, Date().timeIntervalSince(self.lastAlertUpload) > 20 {
                self.rescheduleRestAlerts()
            }
        }
    }

    // MARK: The Watch mirrors this card (same data as the Lock Screen card)

    private var cardTask: Task<Void, Never>?

    private func scheduleCardToWatch(now: Bool) {
        guard workoutId != nil else { return }
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            self?.pushCardToWatch()
        }
    }

    /// Sends the card to the Watch: the Lock Screen card's data, plus what only the wrist shows
    /// (the coach note during rest, reps as they arrive, the weight step, the 10-second warning).
    /// In Demo Mode this is the phone's demo, so the Watch shows it live too.
    func pushCardToWatch() {
        guard workoutId != nil, let s = makeState(), let data = try? JSONEncoder().encode(s) else {
            WatchBridge.shared.sendCardEnd(endSession: false)  // no card right now (doesn't end a session)
            return
        }
        var extras: [String: Any] = ["cardDemo": isDemo, "cardStep": displayStep,
                                     "cardWarn": NotifPrefs.shared.s.restWarning]
        if let note = coachNoteForWatch() { extras["cardNote"] = note }
        let live = WatchBridge.shared.liveRepMotions.map(\.meanVelocity)
        if setStart != nil, !live.isEmpty { extras["cardLive"] = live }
        WatchBridge.shared.sendCard(data, extras: extras)
    }

    /// The last set's top coach note, while it's useful: during rest and just after the set.
    private func coachNoteForWatch() -> String? {
        guard resting || afterSet, let store, let wid = workoutId,
              let w = store.workouts.first(where: { $0.id == wid }), let last = lastSetMotion(w) else { return nil }
        let notes = CoachNotes.make(exercise: last.0, set: last.1, motion: last.3,
                                    pauseTarget: PauseTarget.target(last.0), workouts: store.workouts)
        guard let n = notes.first else { return nil }
        return n.detail.isEmpty ? n.title : "\(n.title) — \(n.detail)"
    }

    // MARK: The card's own alerts (instead of separate notifications)

    /// Follow a card: its push token, and whether it's been closed.
    private func watch(_ a: Activity<WorkoutActivityAttributes>) {
        Task { [weak self] in
            for await data in a.pushTokenUpdates {
                guard let self, self.activity?.id == a.id else { continue }
                self.activityToken = data.map { String(format: "%02x", $0) }.joined()
                if self.resting { self.rescheduleRestAlerts() }
            }
        }
        Task { [weak self] in
            for await st in a.activityStateUpdates where st == .dismissed || st == .ended {
                guard let self, self.activity?.id == a.id else { continue }
                self.activity = nil                     // swiped away: next alert brings it back (iOS 17.2+)
                self.activityToken = nil
                if self.resting { self.rescheduleRestAlerts() }
            }
        }
    }

    /// The server brought the card back: carry on with it.
    private func adopt(_ a: Activity<WorkoutActivityAttributes>) {
        guard activity?.id != a.id, a.attributes.workoutId == workoutId else { return }
        if let old = activity { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        activity = a
        watch(a)
        push(now: true)
    }

    /// The app opened mid-workout: bring the card back if it was closed, and take over the rest
    /// alerts here (the in-app bell), so nothing rings twice.
    func appBecameActive() {
        if let id = workoutId, activity == nil { begin(workoutId: id) }
        if resting { rescheduleRestAlerts() }
    }

    /// The app went to the background: hand the rest of this rest's alerts to the card (via the server).
    func appWentToBackground() {
        if resting { rescheduleRestAlerts() }
    }

    /// Where this rest's alerts go:
    ///  • app open → the in-app bell (with notifications behind it, as before);
    ///  • app in the background, card open → into the card, timed by the server;
    ///  • card closed (iOS 17.2+) → the server brings the card back at rest's end, alert inside;
    ///  • no card, no signal, Demo Mode → ordinary notifications.
    func rescheduleRestAlerts() {
        guard let end = restEnd, end.timeIntervalSinceNow > 2 else { cancelRestAlerts(); return }
        // A Watch session is running: the wrist does the tap. The card still flips on time by
        // itself, but no card alerts or notifications — otherwise one event would tap twice.
        if WatchBridge.shared.watchSessionLive { cancelRestAlerts(); return }
        let title = restAlertTitle(), body = restAlertBody()
        let cardOn = UserDefaults.standard.object(forKey: "bst_live_activity") as? Bool ?? true
        let inBackground = UIApplication.shared.applicationState != .active
        guard inBackground, cardOn, store?.isLive == true, let state = makeState(),
              let events = cardEvents(end: end, state: state, title: title, body: body) else {
            notificationAlerts(end: end, title: title, body: body)
            return
        }
        // The card has it: no separate notifications.
        RestTimerEngine.shared.cancel()
        alertsOnServer = true
        lastAlertUpload = Date()
        let bg = UIApplication.shared.beginBackgroundTask(withName: "rest-alerts")
        Task {
            do { try await APIClient.shared.scheduleCardAlerts(events) }
            catch {
                // No signal: notifications instead.
                await MainActor.run { self.notificationAlerts(end: end, title: title, body: body) }
            }
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    private func notificationAlerts(end: Date, title: String, body: String) {
        if alertsOnServer { alertsOnServer = false; Task { try? await APIClient.shared.cancelCardAlerts() } }
        RestTimerEngine.shared.scheduleBackgroundBell(after: Int(end.timeIntervalSinceNow), title: title, body: body)
    }

    private func cancelRestAlerts() {
        RestTimerEngine.shared.cancel()
        if alertsOnServer {
            alertsOnServer = false
            Task { try? await APIClient.shared.cancelCardAlerts() }
        }
    }

    /// The prepared card updates for this rest (nil = can't go into the card).
    private func cardEvents(end: Date, state: WorkoutActivityAttributes.ContentState,
                            title: String, body: String) -> [CardAlert]? {
        let p = NotifPrefs.shared.s
        func snd(_ s: BSTSound) -> String {
            p.restStyle == .haptic || !AudioOutput.soundsAllowed ? "bst_silent.wav" : s.pushName
        }
        // Rest over: the card shows Start set.
        var up = state
        if up.stage == .resting { up.stage = .ready }
        up.restStart = nil; up.restEnd = nil
        var events: [CardAlert] = []
        if let token = activityToken, activity != nil {
            if p.restWarning, end.timeIntervalSinceNow > 15 {
                events.append(CardAlert(at: end.addingTimeInterval(-10), token: token, event: "update", state: state,
                                        staleDate: end, title: "10 seconds", body: "Get set — " + body, sound: snd(.tick)))
            }
            events.append(CardAlert(at: end, token: token, event: "update", state: up, staleDate: nil,
                                    title: title, body: body, sound: snd(p.sound(.rest))))
            if p.restRepeat {
                for i in 1...max(1, min(6, p.restRepeatCount)) {
                    events.append(CardAlert(at: end.addingTimeInterval(TimeInterval(i * max(15, p.restRepeatEvery))),
                                            token: token, event: "update", state: up, staleDate: nil,
                                            title: "Still resting? · " + title.replacingOccurrences(of: "Rest's up · ", with: ""),
                                            body: body, sound: snd(p.sound(.rest))))
                }
            }
        } else if let token = startToken, let wid = workoutId, let w = store?.workouts.first(where: { $0.id == wid }) {
            // The card was closed: bring it back when rest is up, with the alert in it.
            events.append(CardAlert(at: end, token: token, event: "start", state: up, staleDate: nil,
                                    title: title, body: body, sound: snd(p.sound(.rest)),
                                    attributes: WorkoutActivityAttributes(workoutId: wid, title: w.title)))
        } else {
            return nil
        }
        // Apple's limit is 4 KB per update: trim the heart-rate graph if needed, else fall back.
        guard events.allSatisfy({ $0.fits }) else {
            let trimmed = events.map { e -> CardAlert in var e = e; e.state.hrSpark = Array(e.state.hrSpark.suffix(12)); return e }
            return trimmed.allSatisfy({ $0.fits }) ? trimmed : nil
        }
        return events
    }

    /// An instant alert inside the open card (a PR logged from the Lock Screen or the Watch).
    func alertOnCard(title: String, body: String, sound: BSTSound) -> Bool {
        guard let a = activity, let s = makeState() else { return false }
        let quiet = !AudioOutput.soundsAllowed || WatchBridge.shared.watchSessionLive     // the wrist taps instead
        let tone: AlertConfiguration.AlertSound = quiet ? .named("bst_silent.wav") : (sound.file.map { .named($0) } ?? .default)
        let alert = AlertConfiguration(title: "\(title)", body: "\(body)", sound: tone)
        Task { await a.update(ActivityContent(state: s, staleDate: staleDate()), alertConfiguration: alert) }
        return true
    }

    /// When iOS should redraw the card by itself (the app may be asleep by then):
    /// the auto editor closes, or the rest ends and the border becomes Start set.
    private func staleDate() -> Date? {
        if editing, editorAuto, let u = editorUntil { return u }
        if resting { return restEnd }
        return nil
    }

    // MARK: Building the snapshot

    static func current(_ w: Workout) -> Exercise? {
        w.exercises.first { $0.sets.contains { $0.loggedReps == nil } }
    }

    static func nextSet(_ w: Workout) -> (Exercise, ExerciseSet, Int)? {
        for ex in w.exercises {
            if let i = ex.sets.firstIndex(where: { $0.loggedReps == nil }) { return (ex, ex.sets[i], i + 1) }
        }
        return nil
    }

    private var resting: Bool { (restEnd ?? .distantPast) > Date() }

    private func liveHR() -> Int? {
        if isDemo, workoutId != nil { return demoHR(at: Date()) }
        return WatchBridge.shared.watchSessionLive ? WatchBridge.shared.liveHeartRate : nil
    }

    /// Demo mode only: a believable wave so the card (and its graph) can be seen without a Watch.
    private func demoHR(at d: Date) -> Int {
        let t = d.timeIntervalSince(openedAt)
        return Int(122 + 18 * sin(t / 40) + 6 * sin(t / 9))
    }

    /// The last logged set in this workout that has Watch data.
    private func lastMotion(_ w: Workout) -> (Exercise, ExerciseSet, Int, SetMotion)? {
        var best: (Exercise, ExerciseSet, Int, SetMotion, Date)? = nil
        for ex in w.exercises {
            for (i, s) in ex.sets.enumerated() where s.loggedReps != nil {
                let m = setMotion(w, ex, s, index: i)
                guard let m, m.repCount > 0 else { continue }
                let at = s.loggedAt ?? m.end
                if best == nil || at > best!.4 { best = (ex, s, i + 1, m, at) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    private func available() -> [LiveView] {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return [] }
        return available(hasHR: liveHR() != nil, hasMotion: lastMotion(w) != nil)
    }

    private func available(hasHR: Bool, hasMotion: Bool) -> [LiveView] {
        var v: [LiveView] = []
        if hasHR { v.append(.heartRate) }
        if hasMotion { v.append(contentsOf: [.speed, .travel, .tempo, .pause]) }
        v.append(contentsOf: [.sets, .session])
        return v
    }

    /// The right pane: the set you just did while resting (if the Watch has it), otherwise
    /// the view you picked (or the first one available).
    private func shownView() -> LiveView { shownView(available(), stage: stage) }

    private func shownView(_ avail: [LiveView], stage st: LiveStage) -> LiveView {
        if afterSet, st == .resting || st == .ready, avail.contains(lastSensorView) { return lastSensorView }
        if avail.contains(userView) { return userView }
        return avail.first ?? .sets
    }

    private func makeState() -> WorkoutActivityAttributes.ContentState? {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return nil }
        let unit = StatsUnits.weightLabel
        let disp: (Double) -> Double = { (StatsUnits.weight($0) * 2).rounded() / 2 }
        let first = w.exercises.flatMap { $0.sets }.compactMap { $0.loggedAt }.min()
        var s = WorkoutActivityAttributes.ContentState(startedAt: min(first ?? openedAt, openedAt))
        // Your theme accent, made readable on the card's black (Settings ▸ Appearance).
        let accent = RGBColor(hex: ThemeStore.shared.accent).readableOnDark(RGBColor(hex: 0x010101))
        s.accent = accent.hex
        s.accentInkWhite = accent.textOn == .white

        // Left quarter: the set you're on (or the last one, when everything's logged).
        let next = Self.nextSet(w)
        let ex = next?.0 ?? w.exercises.last
        if let ex {
            s.exercise = ex.name
            s.setCount = ex.sets.count
            if let nx = next {
                s.setNumber = nx.2; s.goalReps = nx.1.targetReps; s.goalWeight = disp(nx.1.targetWeight)
            } else if let last = ex.sets.last {
                s.setNumber = ex.sets.count; s.goalReps = last.targetReps; s.goalWeight = disp(last.targetWeight)
            }
        }
        s.unit = unit

        // The set loop
        s.stage = stage
        if resting, let a = restStart, let b = restEnd { s.restStart = a; s.restEnd = b }
        s.setStart = setStart
        s.logNeeded = logNeeded

        // Heart rate
        if let hr = liveHR() {
            s.hr = hr
            let samples = isDemo
                ? stride(from: 300.0, through: 0, by: -5).map { demoHR(at: Date().addingTimeInterval(-$0)) }
                : hrSamples.filter { Date().timeIntervalSince($0.0) <= 300 }.map { $0.1 } + [hr]
            s.hrPeak = max(samples.max() ?? hr, hrSamples.map { $0.1 }.max() ?? hr)
            let pct = Int((Double(hr) / Double(max(maxHR, 1)) * 100).rounded())
            s.hrPct = pct
            s.hrZone = pct < 60 ? 1 : pct < 70 ? 2 : pct < 80 ? 3 : pct < 90 ? 4 : 5
            s.hrMax = maxHR
            let every = max(1, samples.count / 60)
            s.hrSpark = stride(from: 0, to: samples.count, by: every).map { samples[$0] }
        }

        // Last set from the Watch
        let lastM = lastMotion(w)                   // one scan, used for the views list too
        if let lm = lastM {
            let mex = lm.0, n = lm.2, m = lm.3
            s.lastSet = "\(mex.name) · Set \(n)"
            let r2: (Double) -> Double = { ($0 * 100).rounded() / 100 }
            let r1: (Double) -> Double = { ($0 * 10).rounded() / 10 }
            let reps = Array(m.reps.prefix(12))
            s.speeds = reps.map { r2($0.meanVelocity) }
            s.peakSpeed = r2(m.peakVelocity)
            s.speedLoss = m.velocityLossPct.map { Int($0.rounded()) }
            s.effort = Self.effortRead(m.velocityLossPct, repCount: m.repCount)
            s.travel = reps.map { r1(StatsUnits.depth($0.travelM)) }
            s.travelUnit = StatsUnits.isKg ? "cm" : "in"
            s.travelConsistency = m.travelConsistencyPct.map { Int($0.rounded()) }
            s.ecc = reps.map { r1($0.eccentricSec ?? 0) }
            s.pause = reps.map { r1($0.bottomPauseSec ?? 0) }
            s.con = reps.map { r1($0.concentricSec) }
            s.top = reps.map { r1($0.topPauseSec ?? 0) }
            let avg: ([Double]) -> Int = { a in a.isEmpty ? 0 : Int((a.reduce(0, +) / Double(a.count)).rounded()) }
            s.tempo = "\(avg(s.ecc))-\(avg(s.pause))-\(avg(s.con))-\(avg(s.top))"
            s.pauseAvg = m.averageBottomPauseSec.map(r1)
            s.pauseTarget = Self.pauseTarget(mex)
        }

        // Sets of this exercise (window of up to 5 around the current set — fits the card)
        if let ex {
            let cur = next?.1.id
            var rows = ex.sets.enumerated().map { i, st in
                LiveSetRow(n: i + 1, tReps: st.targetReps, tWeight: disp(st.targetWeight),
                           reps: st.loggedReps, weight: st.loggedWeight.map(disp), rpe: st.rpe, current: st.id == cur)
            }
            if rows.count > 5 {
                let ci = rows.firstIndex { $0.current } ?? rows.count - 1
                let start = min(max(0, ci - 2), rows.count - 5)
                rows = Array(rows[start..<(start + 5)])
            }
            s.rows = rows
        }

        // Session
        s.exTotal = w.exercises.count
        s.exDone = w.exercises.filter { !$0.sets.isEmpty && $0.sets.allSatisfy { $0.loggedReps != nil } }.count
        let all = w.exercises.flatMap { $0.sets }
        s.setsTotal = all.count
        s.setsDone = all.filter { $0.loggedReps != nil }.count
        s.volume = Int(StatsUnits.weight(all.reduce(0.0) { $0 + $1.volume }).rounded())
        if let ex, let i = w.exercises.firstIndex(where: { $0.id == ex.id }), i + 1 < w.exercises.count {
            s.upNext = w.exercises[i + 1].name
        }

        // Right pane
        s.available = available(hasHR: s.hr != nil, hasMotion: lastM != nil)
        s.view = shownView(s.available, stage: s.stage)
        s.afterSet = afterSet && s.view.isSensor

        // Predictions for instant previews: what the editor will open with, the rest that
        // Save starts, and the view that comes back after Save.
        if let nx = next {
            s.nextReps = nx.1.targetReps
            s.nextWeight = disp(nx.0.sets.last(where: { $0.loggedWeight != nil })?.loggedWeight ?? nx.1.targetWeight)
            s.nextRPE = nx.0.sets.last(where: { $0.rpe != nil })?.rpe ?? 8
            s.restSeconds = nx.0.restSeconds
        }
        let willShowAfterSet = isDemo || WatchBridge.shared.watchSessionLive
        s.afterSaveView = willShowAfterSet && s.available.contains(lastSensorView) ? lastSensorView
            : (s.available.contains(userView) ? userView : (s.available.first ?? .sets))

        // Editor
        s.editing = editing
        s.editorAuto = editing && editorAuto
        s.editorUntil = editing && editorAuto ? editorUntil : nil
        s.editSet = next?.2 ?? s.setNumber
        s.dReps = dReps
        s.dWeight = disp(dWeightLb)
        s.dRPE = dRPE
        return s
    }

    /// What the speed drop across a set usually means (a rule of thumb, not a measurement).
    static func effortRead(_ loss: Double?, repCount: Int) -> String? {
        guard let loss, repCount >= 3 else { return nil }
        switch loss {
        case ..<10: return "Speed held — likely 3+ left"
        case ..<20: return "Solid — about 2 left"
        case ..<30: return "Hard — about 1 left"
        default:    return "Near your limit"
        }
    }

    /// A prescribed bottom pause, if the exercise says one ("2-sec pause", "pause 1.5s").
    static func pauseTarget(_ ex: Exercise?) -> Double? {
        guard let ex else { return nil }
        let text = [ex.name, ex.coachNotes, ex.formInstructions, ex.description].joined(separator: " ").lowercased()
        let patterns = [#"(\d+(?:\.\d+)?)\s*-?\s*(?:s|sec|secs|second|seconds)\b[^.]{0,20}?pause"#,
                        #"pause[^.\d]{0,15}?(\d+(?:\.\d+)?)\s*-?\s*(?:s|sec|secs|second|seconds)\b"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text), let v = Double(text[r]), v > 0, v <= 10 {
                return v
            }
        }
        return nil
    }

    // MARK: In-app live card (Phase 3) — read-only views of the session state

    var liftingSince: Date? { setStart }
    var setAwaitingLog: Bool { logNeeded }
    /// Heart rate over the last half hour (Demo Mode: the same wave the Lock Screen card shows).
    var heartSamples: [(Date, Int)] {
        guard isDemo, workoutId != nil else { return hrSamples }
        let now = Date()
        return stride(from: -600.0, through: 0, by: 5).map { off in
            let d = now.addingTimeInterval(off)
            return (d, demoHR(at: d))
        }
    }
    /// The Watch is connected (Demo Mode pretends it is during a workout).
    var watchConnected: Bool { isDemo ? workoutId != nil : WatchBridge.shared.watchSessionLive }
    var heartMax: Int { maxHR }
    var currentHeartRate: Int? { liveHR() }
    /// When the workout clock started: the first logged set, or when the workout was opened.
    func sessionStart(_ w: Workout) -> Date {
        let first = w.exercises.flatMap { $0.sets }.compactMap { $0.loggedAt }.min()
        return min(first ?? openedAt, openedAt)
    }
    /// The last logged set in this workout that has Watch data.
    func lastSetMotion(_ w: Workout) -> (Exercise, ExerciseSet, Int, SetMotion)? { lastMotion(w) }
    /// Any logged set's Watch data (Demo Mode: the reps you watched, or believable ones).
    func setMotion(_ w: Workout, _ ex: Exercise, _ s: ExerciseSet, index: Int) -> SetMotion? {
        guard isDemo else { return SetMotionStore.shared.motion(workoutId: w.id, setId: s.id) }
        return demoMotions[s.id]
            ?? DemoMotion.motion(workoutId: w.id, exercise: ex, set: s, setIndex: index, workouts: store?.workouts ?? [])
    }

}

private extension SetMotion {
    /// The exercise this motion belongs to, for pause-target lookup when nothing is current.
    func exerciseFallback(_ w: Workout) -> Exercise? { w.exercises.first { $0.id == exerciseId } }
}

// MARK: - A card alert, prepared for the server to deliver at its moment

nonisolated struct CardAlert {
    var at: Date
    var token: String
    var event: String                                   // "update" or "start"
    var state: WorkoutActivityAttributes.ContentState
    var staleDate: Date?
    var title: String
    var body: String
    var sound: String
    var attributes: WorkoutActivityAttributes? = nil    // start only

    nonisolated private struct Payload: Encodable {
        struct Alert: Encodable { let title: String; let body: String; let sound: String }
        struct Aps: Encodable {
            let event: String
            let contentState: WorkoutActivityAttributes.ContentState
            let staleDate: Int?
            let alert: Alert
            let attributesType: String?
            let attributes: WorkoutActivityAttributes?
            enum CodingKeys: String, CodingKey {
                case event, alert, attributes
                case contentState = "content-state"
                case staleDate = "stale-date"
                case attributesType = "attributes-type"
            }
        }
        let aps: Aps
    }

    /// Encoded exactly as iOS decodes the card's data (the default JSON encoder, the same one
    /// ActivityKit uses), with Apple's field names. The server only adds the timestamp.
    var json: Data? {
        let p = Payload(aps: .init(event: event, contentState: state,
                                   staleDate: staleDate.map { Int($0.timeIntervalSince1970) },
                                   alert: .init(title: title, body: body, sound: sound),
                                   attributesType: event == "start" ? "WorkoutActivityAttributes" : nil,
                                   attributes: event == "start" ? attributes : nil))
        return try? JSONEncoder().encode(p)
    }

    var fits: Bool { (json?.count ?? .max) < 3_800 }
}

