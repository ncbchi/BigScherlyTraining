import Foundation
import Combine
import ActivityKit
import UIKit

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

    private weak var store: AppStore?
    private var activity: Activity<WorkoutActivityAttributes>?
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
            .sink { [weak self] _ in self?.startSet() }
            .store(in: &bag)
        // The Watch saw the set end → open the log editor for 10 s, pre-filled.
        WatchBridge.shared.$lastDetection
            .compactMap { $0 }
            .sink { [weak self] d in self?.setEnded(reps: d.reps, workoutId: d.workoutId, at: d.receivedAt) }
            .store(in: &bag)
        // Re-adopt a card left running if the app was relaunched mid-workout, and pick up
        // exactly where the session was (rest, set timer, chosen view, the workout itself).
        if let a = Activity<WorkoutActivityAttributes>.activities.first {
            activity = a
            workoutId = a.attributes.workoutId
            restore()
        }
    }

    // MARK: Session lifecycle

    /// The workout screen opened. Starts (or re-adopts) the Live Activity.
    func begin(workoutId id: String) {
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
        }
        // Settings ▸ Lock Screen card (on unless turned off). Off: no card, but the session
        // itself (rest timer, saving across restarts) carries on as normal.
        let cardOn = UserDefaults.standard.object(forKey: "bst_live_activity") as? Bool ?? true
        if !cardOn, let a = activity { activity = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }
        if cardOn, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled, let state = makeState() {
            activity = try? Activity.request(attributes: WorkoutActivityAttributes(workoutId: id, title: w.title),
                                             content: ActivityContent(state: state, staleDate: staleDate()),
                                             pushType: nil)
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
        endRest()
        let a = activity
        activity = nil
        workoutId = nil
        editing = false
        UserDefaults.standard.removeObject(forKey: savedKey)
        Task { await a?.end(nil, dismissalPolicy: .default) }
    }

    /// Logout: close any card immediately.
    func endAll() {
        activity = nil; workoutId = nil
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
        RestTimerEngine.shared.scheduleBackgroundBell(after: seconds)
        WatchBridge.shared.startRest(seconds: seconds)
        setStart = nil
        scheduleStageRefresh()
        push(now: true)
    }

    func addRest(_ s: Int) {
        guard let end = restEnd else { return }
        let newEnd = max(Date(), end).addingTimeInterval(TimeInterval(s))
        restTotal += s
        restEnd = newEnd
        let left = Int(newEnd.timeIntervalSinceNow)
        RestTimerEngine.shared.scheduleBackgroundBell(after: left)
        WatchBridge.shared.startRest(seconds: left)
        scheduleStageRefresh()
        push(now: true)
    }

    func endRest() {
        restEnd = nil; restStart = nil
        RestTimerEngine.shared.cancel()
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

        if !wasLogged {
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
            if Self.current(store.workouts[wi]) != nil && autoRest { startRest(ex.restSeconds) } else { endRest() }
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
            RestTimerEngine.shared.cancel()
        }
        setStart = Date()
        logNeeded = false
        afterSet = false                            // back to the view you were on
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
        demoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.isDemo, self.stage == .lifting, !self.editing,
                  let wid = self.workoutId, let w = self.store?.workouts.first(where: { $0.id == wid }),
                  let nx = Self.nextSet(w) else { return }
            self.setEnded(reps: nx.1.targetReps, workoutId: wid, at: Date())
        }
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
        guard activity != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled, let self, let a = self.activity, let s = self.makeState() else { return }
            self.persist()
            await a.update(ActivityContent(state: s, staleDate: self.staleDate()))
        }
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
                let m: SetMotion? = isDemo
                    ? DemoMotion.motion(workoutId: w.id, exercise: ex, set: s, setIndex: i, workouts: store?.workouts ?? [])
                    : SetMotionStore.shared.motion(workoutId: w.id, setId: s.id)
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
}

private extension SetMotion {
    /// The exercise this motion belongs to, for pause-target lookup when nothing is current.
    func exerciseFallback(_ w: Workout) -> Exercise? { w.exercises.first { $0.id == exerciseId } }
}
