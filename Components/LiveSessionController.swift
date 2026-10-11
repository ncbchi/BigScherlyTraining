import Foundation
import Combine
import ActivityKit
import UIKit
import AVFoundation
import SwiftUI

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

    // The finished set waiting for Log set (logNeeded): filled in, nothing to enter on the card.
    private var doneReps: Int? = nil            // the Watch's count for it (nil: the reps you lifted live, or the plan)
    private var doneByWatch = true              // the Watch saw it end (false: you tapped End set)
    private var doneMotion: [RepMotion] = []    // its reps from the Watch, for the RPE estimate
    /// What you've typed for it in the app (after Edit) — wins over the filled-in values everywhere,
    /// so if the next set starts before you tap Log set, it's your numbers that get logged.
    private var draft: (setId: String, reps: Int, weightLb: Double, rpe: Double?)? = nil
    /// Edit (Lock Screen card, or the in-app card): the set to open in the app, reps selected.
    @Published var editRequest: String? = nil
    /// Settings ▸ After a set ▸ Log by itself: when the waiting set logs itself (nil: not counting down).
    private var autoLogAt: Date? = nil
    private var autoLogTask: Task<Void, Never>?
    private var autoLogBG: UIBackgroundTaskIdentifier = .invalid
    private var autoLogCommitting = false       // logging by itself right now: keep the background time until the card's sent
    /// Settings ▸ Auto-end if idle: the last time anything happened in the workout.
    private var lastActivity = Date()
    private var idleTask: Task<Void, Never>?
    /// The card was ended for being idle: it comes back when something happens (or the app opens).
    private var idleEnded = false
    /// What the card settings were last time (a change mid-workout redraws or ends the card).
    private var lastPrefs = ""
    /// The sample card from Settings (ended after 15 s).
    private var sample: Activity<WorkoutActivityAttributes>?
    static let sampleId = "sample"
    /// Settings ▸ When you close the app ▸ Close it, but keep the workout: the workout that's waiting.
    private let closedKeepKey = "bst_card_closed_keep"
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
        var lastDetectionSeen: Date?
        var doneReps: Int? = nil, doneByWatch: Bool? = nil, doneMotion: [RepMotion]? = nil   // optional: older saves decode
    }
    private let savedKey = "bst_live_session"
    /// The workout whose live session you closed (by closing the app) — never revived from a card.
    private let closedKey = "bst_live_closed"

    /// The workout of the saved live session, if one's saved (finishing a workout deletes it).
    private func savedWorkoutId() -> String? {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let sv = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return sv.workout.id
    }
    private var pushTask: Task<Void, Never>?
    /// When a set was last logged (Lock Screen, app or Watch) — a Watch "set ended" just after is its tail.
    private var lastLoggedAt: Date?
    private var pushSerial = 0
    private var lastCardUpdate = Date.distantPast
    private var cardUpdates = 0

    private init() {}

    private var isDemo: Bool { store?.isDemoMode == true || APIConfig.useMock }

    /// Called once at app launch (before any Lock Screen button can fire).
    func attach(_ store: AppStore) {
        self.store = store
        LiveIntentRouter.handler = { action in
            print("[Live] Lock Screen button → \(action)")        // diagnostics: the tap reached the app
            await LiveSessionController.shared.handle(action)
        }
        print("[Live] launch · cards: " + (Activity<WorkoutActivityAttributes>.activities
            .map { "\($0.id.prefix(8)) \($0.activityState)" }.joined(separator: ", ")).ifEmpty("none"))
        WatchBridge.shared.$liveHeartRate
            .sink { [weak self] bpm in self?.heartRate(bpm) }
            .store(in: &bag)
        // Theme or accent changed mid-workout: redraw the card in the new look.
        ThemeStore.shared.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.push(now: true) }
            .store(in: &bag)
        // Each rep from the Watch, while you're lifting: the card's sensor views fill in as you go.
        WatchBridge.shared.$liveRepMotions
            .dropFirst()
            .filter { _ in !SetupEngine.shared.active }
            .sink { [weak self] _ in if self?.setStart != nil { self?.push(now: true) } }
            .store(in: &bag)
        SetMotionStore.shared.$bySet
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)   // a reload of many sets = one update
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
        // Only carry on with a card that's still live. iOS ends a card after 8 hours (e.g. a workout
        // left open overnight); an ended card stays on the Lock Screen but can't take taps — every
        // tap just opens the app. Clear those away (the workout's session is still restored).
        let cards = Activity<WorkoutActivityAttributes>.activities
        let closed = UserDefaults.standard.string(forKey: closedKey)
        let saved = savedWorkoutId()
        for old in cards where !Self.isLive(old) || old.attributes.workoutId == closed
                                || old.attributes.workoutId == Self.sampleId {
            print("[Live] clearing card \(old.id.prefix(8)) (\(old.activityState))")
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let keptWorkout = UserDefaults.standard.string(forKey: closedKeepKey)
        UserDefaults.standard.removeObject(forKey: closedKeepKey)
        if let a = cards.first(where: { Self.isLive($0) && $0.attributes.workoutId != closed
                                         && $0.attributes.workoutId != Self.sampleId }) {
            activity = a
            workoutId = a.attributes.workoutId
            restore()
            watch(a)
        } else if let ended = cards.first(where: { !Self.isLive($0) && $0.attributes.workoutId == saved }) {
            // iOS ended the card (its 8-hour limit) but the workout's still going (its session is saved):
            // carry on, and a fresh card starts on open. A finished workout has no saved session, so it
            // isn't revived — that was bringing finished workouts back onto the Watch.
            workoutId = ended.attributes.workoutId
            restore()
        } else if let kept = keptWorkout, kept == saved {
            // Settings ▸ Close it, but keep the workout: the card went when the app closed; the workout
            // waits. Pick it up here — a fresh card starts when the app's in front.
            print("[Live] picking up the workout kept when the app closed")
            workoutId = kept
            restore()
        } else if saved != nil, cards.isEmpty,
                  UserDefaults.standard.object(forKey: "bst_live_activity") as? Bool ?? true,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            // A saved session with no card at all: you swiped the card away while the app was asleep.
            // That closes the live workout — the Watch clears and ends its session too.
            print("[Live] the card was swiped away — closing the live workout")
            UserDefaults.standard.removeObject(forKey: savedKey)
            WatchBridge.shared.sendCardEnd(endSession: true)
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
        // Settings ▸ Lock Screen & Dynamic Island changed: apply it to the card that's up.
        lastPrefs = Self.prefsSignature()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.cardPrefsChanged() }
            .store(in: &bag)
        // Headphones in or out mid-rest: the alerts' sound changes with it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.resting == true { self?.rescheduleRestAlerts() } }
        }
    }

    // MARK: Session lifecycle

    /// The workout screen opened. Starts (or re-adopts) the Live Activity.
    func begin(workoutId id: String) {
        let t0 = Date(); func mark(_ s: String) { print(String(format: "[Open] begin · %@ · %.0f ms", s, Date().timeIntervalSince(t0) * 1000)) }
        defer { mark("done") }
        LocalReminders.cancelWorkout(id)                 // started: no "today's workout" nudge
        UserDefaults.standard.removeObject(forKey: closedKey)
        // Open the Watch straight into its workout session: it stays on your wrist (every raise
        // brings the card back), taps for rest, and the phone keeps quiet. Once per workout.
        if watchLaunchedFor != id, !isDemo || Self.demoStartsWatch,
           WatchBridge.shared.watchAppAvailable, !WatchBridge.shared.watchSessionLive {
            watchLaunchedFor = id
            WatchBridge.shared.startWatchWorkout { _ in }
            mark("watch app launch requested")
        }
        guard let w = store?.workouts.first(where: { $0.id == id }), !w.completed else { return }
        touch()
        if workoutId != id {
            workoutId = id
            openedAt = Date()
            hrSamples = []
            setStart = nil; logNeeded = false; afterSet = false
            clearDone()
            restEnd = nil; restStart = nil; restTotal = 0
            userView = CardPrefs.startView          // Settings ▸ Starts on
            idleEnded = false
            touch()
            Task { maxHR = await HealthActivityReader.observedMaxHR(demo: isDemo) ?? 190 }
        }
        if let a = activity, a.attributes.workoutId != id || !Self.isLive(a) {
            Task { await a.end(nil, dismissalPolicy: .immediate) }   // another workout's, or one iOS has ended
            activity = nil
            activityToken = nil
        }
        // Settings ▸ Lock Screen card (on unless turned off). Off: no card, but the session
        // itself (rest timer, saving across restarts) carries on as normal.
        let cardOn = CardPrefs.showCard
        if !cardOn, let a = activity { activity = nil; activityToken = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }
        // Settings ▸ Start the card ▸ First set: no card until you start lifting (or a set's logged).
        let earned = CardPrefs.startAt == .open || setStart != nil || logNeeded || restEnd != nil
            || w.exercises.contains { $0.sets.contains { $0.loggedReps != nil } }
        // No card yet by choice (First set): if the app's closed before then, the workout is kept, not ended.
        if cardOn, !earned, activity == nil { UserDefaults.standard.set(id, forKey: closedKeepKey) }
        if cardOn, earned, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled, let state = makeState() {
            do {
                activity = try Activity.request(attributes: WorkoutActivityAttributes(workoutId: id, title: w.title),
                                                content: ActivityContent(state: state, staleDate: staleDate()),
                                                pushType: .token)          // so the server can send rest alerts into it
                print("[Live] card started \(activity.map { String($0.id.prefix(8)) } ?? "?")")
                UserDefaults.standard.removeObject(forKey: closedKeepKey)
            } catch {
                print("[Live] couldn't start the card: \(error)")
            }
            if let a = activity { watch(a) }
            mark("live activity")
        }
        push(now: true)
        mark("first card push")
        LiveLink.shared.start()                          // the coach's iPad can find this session (Bluetooth, in the room)
    }

    private func persist() {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return }
        let sv = Saved(workout: w, openedAt: openedAt, restStart: restStart, restEnd: restEnd, restTotal: restTotal,
                       setStart: setStart, logNeeded: logNeeded, userView: userView, lastSensorView: lastSensorView,
                       afterSet: afterSet, lastDetectionSeen: lastDetectionSeen,
                       doneReps: doneReps, doneByWatch: doneByWatch, doneMotion: doneMotion)
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
        doneReps = sv.doneReps; doneByWatch = sv.doneByWatch ?? true; doneMotion = sv.doneMotion ?? []
        lastDetectionSeen = sv.lastDetectionSeen
        scheduleStageRefresh()
    }

    /// Workout finished (or abandoned): close the card.
    /// `dismissal` nil: Settings ▸ End with the workout (on: gone at once · off: iOS shows the last state a while).
    func end(dismissal: ActivityUIDismissalPolicy? = nil) {
        let dismissal: ActivityUIDismissalPolicy = dismissal ?? (CardPrefs.endWithWorkout ? .immediate : .default)
        UserDefaults.standard.removeObject(forKey: closedKeepKey)
        SetVideoRecorder.shared.stopAll()
        endRest()
        let a = activity
        activity = nil
        activityToken = nil
        workoutId = nil
        LiveLink.shared.stop()                           // the coach's iPad: session over
        clearDone()
        watchLaunchedFor = nil
        WatchBridge.shared.sendCardEnd(endSession: true)       // the Watch ends its session too
        UserDefaults.standard.removeObject(forKey: savedKey)
        Task { await a?.end(nil, dismissalPolicy: dismissal) }
    }

    /// You closed the app: the live workout closes with it — the Lock Screen card, and the Watch's
    /// card and session. (iOS only tells the app when it's running; closed while asleep, the Lock
    /// Screen card stays — and swiping that away closes everything.)
    func closeForTermination() {
        endCloseWatch()
        switch CardPrefs.close {
        case .keep:
            // Settings ▸ Keep it while a workout is going: closing the app is just closing the app.
            print("[Live] app closing — the card stays (Settings: keep it while a workout is going)")
            persist()
            return
        case .closeKeep:
            // Settings ▸ Close it, but keep the workout: the card goes; the workout waits in the app.
            print("[Live] app closing — the card goes, the workout's kept")
            if let wid = workoutId { UserDefaults.standard.set(wid, forKey: closedKeepKey); persist() }
            cancelRestAlerts()
            activity = nil; activityToken = nil                    // so the card's end isn't read as a swipe-away
            pushTask?.cancel(); pushTask = nil
            WatchBridge.shared.sendCardEnd(endSession: false)      // the Watch's card goes; its session stays
            Self.endAllCardsAndWait(timeout: 3)
            return
        case .close:
            print("[Live] app closing — taking the card down")
            UserDefaults.standard.removeObject(forKey: closedKeepKey)
        }
        if let wid = workoutId {
            UserDefaults.standard.set(wid, forKey: closedKey)
            SetVideoRecorder.shared.stopAll()
            restEnd = nil; restStart = nil
            cancelRestAlerts()
            pushTask?.cancel(); pushTask = nil
            activity = nil; activityToken = nil
            workoutId = nil
            clearDone()
            watchLaunchedFor = nil
            WatchBridge.shared.sendCardEnd(endSession: true)       // the Watch ends its session too
            UserDefaults.standard.removeObject(forKey: savedKey)
        }
        // iOS stops the app the moment it returns from here — a card ended in a Task never
        // actually goes. So wait (up to 3 s) until iOS has taken the card and the Dynamic Island down.
        Self.endAllCardsAndWait(timeout: 3)
    }

    /// Ends every card right now and returns once iOS has done it (or the timeout passes). Spins the
    /// main run loop while it waits, so nothing the end needs on the main thread is blocked.
    private static func endAllCardsAndWait(timeout: TimeInterval) {
        let done = DoneFlag()
        Task.detached {
            for a in Activity<WorkoutActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            done.set()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done.isSet, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        print("[Live] card \(done.isSet ? "ended" : "end timed out") before close")
    }

    // MARK: Closing the app shortly after leaving it
    // iOS only tells the app it's being closed while the app is still running. Left alone, a
    // backgrounded app is put to sleep within seconds — swipe it away after that and iOS says
    // nothing, so the card would stay. During a workout, the app asks to keep running for the
    // time iOS allows (about 30 s) after you leave it, so a close in that window is caught.
    // After that it's asleep, and no app can see the close.

    private var closeWatch: UIBackgroundTaskIdentifier = .invalid

    private func beginCloseWatch() {
        guard workoutId != nil, CardPrefs.close != .keep, closeWatch == .invalid else { return }
        closeWatch = UIApplication.shared.beginBackgroundTask(withName: "workout-close-watch") { [weak self] in
            MainActor.assumeIsolated { self?.endCloseWatch() }   // iOS's time is up: let the app sleep (runs on main)
        }
    }

    private func endCloseWatch() {
        guard closeWatch != .invalid else { return }
        UIApplication.shared.endBackgroundTask(closeWatch)
        closeWatch = .invalid
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
        touch()
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
        return "\(nx.0.name) · \(SetTarget.text(nx.1, in: nx.0))"
    }

    func addRest(_ s: Int) {
        guard let end = restEnd else { return }
        touch()
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
        if restEnd != nil { touch() }
        restEnd = nil; restStart = nil
        cancelRestAlerts()
        push(now: true)
    }

    // MARK: Logging (was in the workout screen)

    /// Log or edit a set. Returns true when the current exercise changed (the screen
    /// opens the next one). A first-time log starts the exercise's rest.
    /// `thenRest: false` — logged because the next set already started (no rest in between).
    @discardableResult
    func log(workoutId wid: String, exerciseId: String, setId: String,
             reps: Int, weight: Double, rpe: Double?, thenRest: Bool = true) -> Bool {
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
        if !wasLogged { lastLoggedAt = Date() }
        touch()
        cancelAutoLog()
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
            clearDone()
            if editRequest == setId { editRequest = nil }
            // During the rest, the right pane shows the set you just did (if the Watch has it).
            // The Watch sends a set's data a moment after it's logged, so with a live Watch
            // session, show the after-set view and let the data fill in.
            afterSet = isDemo || WatchBridge.shared.watchSessionLive
                || SetMotionStore.shared.motion(workoutId: wid, setId: setId) != nil
            // Settings ▸ Start rest automatically (on unless turned off)
            let autoRest = UserDefaults.standard.object(forKey: "bst_auto_rest") as? Bool ?? true
            // Settings ▸ Notifications ▸ Rest timer ▸ Default rest, when the programme doesn't say.
            let rest = ex.restSeconds > 0 ? ex.restSeconds : NotifPrefs.shared.s.defaultRest
            if !thenRest {
                // The next set is already under way: no rest.
            } else if Self.current(store.workouts[wi]) != nil && autoRest { startRest(rest) } else { endRest() }
        }
        push(now: true)
        return Self.current(store.workouts[wi])?.id != before
    }

    // MARK: The set loop

    /// Start set (button on the card, or the Watch's first rep).
    func startSet() {
        guard workoutId != nil, stage != .done, setStart == nil || logNeeded else { return }
        // The last set was never logged: log it as it was filled in, then start this one.
        if logNeeded {
            commitDone(thenRest: false)
            guard stage != .done else { return }
        }
        if restEnd != nil {
            restEnd = nil; restStart = nil
            cancelRestAlerts()
        }
        setStart = Date()
        logNeeded = false
        afterSet = false                            // back to the view you were on
        touch()
        if activity == nil { startCardMidWorkout() } // Start the card ▸ First set, or it was ended for being idle
        SetVideoRecorder.shared.setStarted()        // set videos on: film this set
        scheduleStageRefresh()
        push(now: true)
        if isDemo { simulateDemoSet() }
    }

    /// The Watch saw the set end: the card shows the set filled in, with Log set and Edit.
    private func setEnded(reps: Int, workoutId wid: String, at: Date) {
        guard wid == workoutId, lastDetectionSeen != at, Date().timeIntervalSince(at) < 120 else { return }
        lastDetectionSeen = at
        // The Watch reports a set's end after ~7 s of stillness. If you've already logged that set
        // (rest is running and no new set has started, or you saved moments ago), this is its tail —
        // don't show the next set as done.
        if resting && setStart == nil { return }
        if let l = lastLoggedAt, at.timeIntervalSince(l) < 15 { return }
        if logNeeded { return }                     // already showing this set
        doneMotion = thisSetReps(endedAt: at)       // before setStart is filled in below
        if setStart == nil { setStart = at }
        logNeeded = true
        doneReps = reps
        doneByWatch = true
        SetVideoRecorder.shared.setEnded()          // the Watch saw you rack it: stop filming
        touch()
        scheduleAutoLog()
        push(now: true)
    }

    /// End set (the card's button while lifting, without a Watch to see it end).
    func endSet() {
        guard stage == .lifting, !logNeeded else { return }
        doneMotion = thisSetReps(endedAt: Date())
        logNeeded = true
        doneReps = doneMotion.isEmpty ? nil : doneMotion.count
        doneByWatch = false
        SetVideoRecorder.shared.setEnded()
        touch()
        scheduleAutoLog()
        push(now: true)
    }

    /// The Watch's reps for the set you just did (only this set's: the previous set's may still be there).
    private func thisSetReps(endedAt: Date) -> [RepMotion] {
        let live = WatchBridge.shared.liveRepMotions
        if let started = setStart { return live.filter { $0.start >= started.addingTimeInterval(-5) } }
        return live.filter { $0.end >= endedAt.addingTimeInterval(-180) }
    }

    private func clearDone() {
        doneReps = nil; doneByWatch = true; doneMotion = []; draft = nil
        cancelAutoLog()
    }

    // MARK: Settings ▸ After a set ▸ Log by itself

    /// Counts down (10–30 s, your pick), then logs the set as it's filled in. Edit stops it. The app
    /// asks iOS to keep running for the wait, so it logs even with the phone locked.
    private func scheduleAutoLog() {
        cancelAutoLog()
        guard logNeeded, CardPrefs.afterSet == .auto else { return }
        let at = Date().addingTimeInterval(TimeInterval(CardPrefs.autoLogSeconds))
        autoLogAt = at
        autoLogBG = UIApplication.shared.beginBackgroundTask(withName: "auto-log") { [weak self] in
            MainActor.assumeIsolated { self?.endAutoLogBG() }
        }
        autoLogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, at.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.autoLogAt == at, self.logNeeded else { self.cancelAutoLog(); return }
            print("[Live] logging the set by itself (Settings ▸ After a set)")
            self.autoLogCommitting = true
            self.commitDone(thenRest: true)
            await self.sendNow()
            self.autoLogCommitting = false
            self.cancelAutoLog()
            self.endAutoLogBG()
        }
    }

    private func cancelAutoLog() {
        guard !autoLogCommitting else { autoLogAt = nil; return }   // mid-log: the task finishes and tidies up
        autoLogAt = nil
        autoLogTask?.cancel(); autoLogTask = nil
        endAutoLogBG()
    }

    private func endAutoLogBG() {
        guard autoLogBG != .invalid else { return }
        UIApplication.shared.endBackgroundTask(autoLogBG)
        autoLogBG = .invalid
    }

    // MARK: Settings ▸ Auto-end if idle

    /// Something happened in the workout: the idle clock restarts (and a card ended for being idle can come back).
    private func touch() {
        lastActivity = Date()
        idleTask?.cancel()
        let minutes = CardPrefs.idleMinutes
        guard minutes > 0 else { return }
        let wait = TimeInterval(minutes * 60) + 1
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.checkIdle()
        }
    }

    /// No set logged and no rest running for the time you picked: the card ends. The workout is kept —
    /// open the app (or start a set) and the card comes back. Checked on a timer while the app's awake,
    /// and on every update (the Watch's heart rate wakes the app often during a workout).
    private func checkIdle() {
        let minutes = CardPrefs.idleMinutes
        guard minutes > 0, activity != nil, !resting, autoLogAt == nil,
              Date().timeIntervalSince(lastActivity) >= TimeInterval(minutes * 60) else { return }
        print("[Live] idle \(minutes) min — ending the card (the workout's kept)")
        idleEnded = true
        endCardKeepingWorkout()
    }

    /// The card goes (now, not iOS's default linger); the workout and its saved session stay.
    private func endCardKeepingWorkout() {
        guard let a = activity else { return }
        if let wid = workoutId { UserDefaults.standard.set(wid, forKey: closedKeepKey) }   // relaunch: kept, not swiped away
        activity = nil; activityToken = nil
        pushTask?.cancel(); pushTask = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// A set started with no card up (Start the card ▸ First set, or it was ended for being idle).
    /// In the app: start it. Asleep (the Watch saw the set start): iOS won't let the app start a card
    /// from the background, so the server starts it (iOS 17.2+), the same way it brings back a closed card.
    private func startCardMidWorkout() {
        guard CardPrefs.showCard, let wid = workoutId else { return }
        idleEnded = false
        if UIApplication.shared.applicationState == .active { begin(workoutId: wid); return }
        guard let token = startToken, let store, let w = store.workouts.first(where: { $0.id == wid }),
              let state = makeState() else { return }
        let set = Self.nextSet(w)
        let start = CardAlert(at: Date(), token: token, event: "start", state: state, staleDate: nil,
                              title: set.map { "\($0.0.name) · Set \($0.2)" } ?? w.title, body: "Lifting",
                              sound: "bst_silent.wav", attributes: WorkoutActivityAttributes(workoutId: wid, title: w.title))
        guard start.fits else { return }
        Task { try? await APIClient.shared.scheduleCardAlerts([start]) }
    }

    // MARK: Settings changed mid-workout

    private static func prefsSignature() -> String {
        [CardPrefs.showCard ? "1" : "0", CardPrefs.look.rawValue, String(CardPrefs.accent ?? 0), CardPrefs.island,
         CardPrefs.afterSet.rawValue, String(CardPrefs.autoLogSeconds), String(CardPrefs.idleMinutes),
         CardPrefs.startAt.rawValue, UserDefaults.standard.string(forKey: "bst_weight_step") ?? ""].joined(separator: "|")
    }

    private func cardPrefsChanged() {
        let sig = Self.prefsSignature()
        guard sig != lastPrefs else { return }
        lastPrefs = sig
        guard let wid = workoutId else { return }
        if !CardPrefs.showCard {
            endCardKeepingWorkout()                 // turned off: the card goes; the workout carries on
            return
        }
        if CardPrefs.afterSet != .auto { cancelAutoLog() }
        touch()
        if activity == nil, UIApplication.shared.applicationState == .active { begin(workoutId: wid) }
        push(now: true)                             // the new look, Island pill, after-set mode
    }

    // MARK: Settings ▸ Show a sample card

    /// A 15-second demo card (a rest, with the last set's bar speed). Only when no workout card is up.
    func showSample() -> Bool {
        guard activity == nil, workoutId == nil, Activity<WorkoutActivityAttributes>.activities.isEmpty,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        var s = WorkoutActivityAttributes.ContentState(startedAt: Date().addingTimeInterval(-24 * 60 - 31))
        Self.applyLook(&s)
        s.exercise = "Back Squat"; s.setNumber = 5; s.setCount = 5; s.goalReps = 5; s.goalWeight = 275
        s.unit = StatsUnits.weightLabel
        s.stage = .resting; s.restStart = Date(); s.restEnd = Date().addingTimeInterval(118)
        s.hr = 142; s.hrPeak = 156; s.hrPct = 74; s.hrZone = 3; s.hrMax = 190
        s.hrSpark = [118, 121, 125, 131, 138, 142, 139, 134, 129, 127, 133, 141, 148, 151, 146, 142]
        s.lastSet = "Back Squat · Set 4"
        s.speeds = [0.58, 0.56, 0.53, 0.49, 0.45]; s.peakSpeed = 0.78; s.speedLoss = 22
        s.effort = Self.effortRead(22, repCount: 5)
        s.travel = [24.5, 24.4, 24.6, 23.1, 24.3]; s.travelUnit = "in"
        s.ecc = [1.8, 1.7, 1.9, 1.7, 1.8]; s.pause = [0.4, 0.4, 0.3, 0.3, 0.2]
        s.con = [1.1, 1.1, 1.2, 1.3, 1.4]; s.top = [0.6, 0.6, 0.6, 0.6, 0.6]; s.tempo = "2-0-1-1"
        s.available = [.heartRate, .speed, .travel, .tempo, .pause, .sets, .session]
        s.view = .speed; s.afterSet = true
        s.rows = (1...5).map { LiveSetRow(n: $0, tReps: 5, tWeight: 275, reps: $0 < 5 ? 5 : nil, weight: $0 < 5 ? 275 : nil,
                                          rpe: $0 < 5 ? [7, 7.5, 8, 8.5][$0 - 1] : nil, current: $0 == 5) }
        s.exTotal = 4; s.exDone = 0; s.setsTotal = 18; s.setsDone = 4; s.volume = 5500; s.upNext = "Romanian Deadlift"
        do {
            let a = try Activity.request(attributes: WorkoutActivityAttributes(workoutId: Self.sampleId, title: "Sample"),
                                         content: ActivityContent(state: s, staleDate: nil), pushType: nil)
            sample = a
            let bg = UIApplication.shared.beginBackgroundTask(withName: "sample-card")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await a.end(nil, dismissalPolicy: .immediate)
                self?.sample = nil
                UIApplication.shared.endBackgroundTask(bg)
            }
            return true
        } catch {
            print("[Live] couldn't show the sample card: \(error)")
            return false
        }
    }

    /// Log the finished set exactly as it's filled in.
    private func commitDone(thenRest: Bool) {
        guard logNeeded, let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              let nx = Self.nextSet(w), let p = prefill(w) else { return }
        // Round to the nearest plate step so kg ↔ lb conversion never leaves 184.99.
        let step = displayStep
        let shown = (StatsUnits.weight(p.weightLb) / step).rounded() * step
        let lb = StatsUnits.isKg ? shown / 0.45359237 : shown
        log(workoutId: wid, exerciseId: nx.0.id, setId: nx.1.id, reps: p.reps, weight: lb, rpe: p.rpe, thenRest: thenRest)
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

    /// Demo Mode only: pretend the Watch saw the set end after the last rep, so App Review
    /// (and you) can see the finished set, filled in, without a Watch.
    private func simulateDemoSet() {
        demoTask?.cancel()
        WatchBridge.shared.demoLive(reps: [])
        demoTask = Task { [weak self] in
            guard let self, let wid = self.workoutId, let w = self.store?.workouts.first(where: { $0.id == wid }),
                  let nx = Self.nextSet(w) else { return }
            // Whole reps, the way the Watch sends them: each a little slower than the last,
            // the pause shortening as you tire, and one rep a touch shallow.
            let target = SetTarget.isAmrap(nx.1) ? max(nx.1.targetReps, 6) + 2 : max(1, nx.1.targetReps)
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
            guard !Task.isCancelled, self.isDemo, self.stage == .lifting, !self.logNeeded, !reps.isEmpty else { return }
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
        touch()
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
        switch a {
        case "end": endSet()
        case "commit": commitDone(thenRest: true)
        default: return
        }
    }

    // MARK: The finished set, filled in

    struct Prefill {
        var reps: Int
        var weightLb: Double
        var rpe: Double
        var why: String
        var byWatch: Bool
    }

    /// The set waiting for Log set, filled in — nil when no set is waiting.
    func prefill(forSet id: String) -> Prefill? {
        guard logNeeded, let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              Self.nextSet(w)?.1.id == id else { return nil }
        return prefill(w)
    }

    /// Reps: the Watch's count (or the reps it saw, or the plan). Weight, by the kind of set (SetTarget):
    ///  • fixed: last set's, plus the plan's step between that set and this one (when that one was fixed too);
    ///  • back-off: the heaviest set logged in this exercise less its % (empty until one's logged);
    ///  • RPE (you pick): the last weight you used on this lift today, else last session's top set;
    ///  • bodyweight: 0.
    /// RPE: estimated from how the set went (an RPE set's target goes beside it, not in place of it).
    private func prefill(_ w: Workout) -> Prefill? {
        guard let nx = Self.nextSet(w) else { return nil }
        let ex = nx.0, set = nx.1, i = nx.2 - 1
        let prev = ex.sets[..<i].last(where: { $0.loggedReps != nil })
        let prevN = prev.flatMap { p in ex.sets.firstIndex { $0.id == p.id } }.map { $0 + 1 }
        // AMRAP with no count from the Watch: its minimum, else what you did last set (never 0).
        let planReps = SetTarget.isAmrap(set) && set.targetReps <= 0 ? max(prev?.loggedReps ?? 1, 1) : set.targetReps
        let reps = doneReps ?? (doneMotion.isEmpty ? planReps : doneMotion.count)
        var weight: Double
        if SetTarget.isFixed(set) || SetTarget.isBodyweight(set) {
            weight = set.targetWeight
            if let p = prev, let lw = p.loggedWeight, SetTarget.isFixed(p) || SetTarget.isBodyweight(p) {
                weight = max(0, lw + (set.targetWeight - p.targetWeight))
            }
        } else {
            weight = SetTarget.startWeight(set, in: ex, workoutId: w.id, workouts: store?.workouts ?? [])
                ?? prev?.loggedWeight ?? 0
        }
        // On the plate step (Settings ▸ Weight steps), so the card, the app and the log all say the same.
        weight = SetTarget.roundToStep(weight)
        // "Short of target" only counts against a real target: an AMRAP's minimum, if it has one.
        let guess = Self.estimateRPE(reps: doneMotion, done: reps, target: set.targetReps,
                                     pauseGoal: PauseTarget.target(ex),
                                     prevRPE: prev?.rpe, prevWeightLb: prev?.loggedWeight, prevNumber: prevN,
                                     weightLb: weight)
        if let d = draft, d.setId == set.id {
            return Prefill(reps: d.reps, weightLb: d.weightLb, rpe: d.rpe ?? guess.rpe,
                           why: d.rpe == nil ? guess.why : "you set it", byWatch: doneByWatch)
        }
        return Prefill(reps: reps, weightLb: weight, rpe: guess.rpe, why: guess.why, byWatch: doneByWatch)
    }

    /// The set row in the app, as you type (only for the set waiting to be logged).
    func setDraft(setId: String, reps: Int, weightLb: Double, rpe: Double?) {
        guard logNeeded, let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }),
              Self.nextSet(w)?.1.id == setId else { return }
        draft = (setId, reps, weightLb, rpe)
        if autoLogAt != nil { cancelAutoLog() }     // you're typing: no logging by itself
        push(now: false)
    }

    /// An RPE guess from the set: how much the bar slowed (the base — the same reading as the card's
    /// "about 2 left" line: 15% ≈ 8, 25% ≈ 9, 35%+ ≈ 10), a grinding last rep, stalling at the bottom,
    /// missed reps, and last set's RPE adjusted for any weight change. Rounded to the half, 5–10.
    static func estimateRPE(reps: [RepMotion], done: Int, target: Int, pauseGoal: Double?,
                            prevRPE: Double?, prevWeightLb: Double?, prevNumber: Int?,
                            weightLb: Double) -> (rpe: Double, why: String) {
        var why: [String] = []
        // From the bar speed (3+ reps from the Watch)
        var speed: Double? = nil
        if reps.count >= 3 {
            let v = reps.map { $0.meanVelocity }
            let best = max(v[0], v[1])
            if best > 0, let last = v.last {
                let loss = max(0, (best - last) / best * 100)
                var r = 6.5 + loss / 10
                why.append("speed dropped \(Int(loss.rounded()))%")
                let firstCon = reps.prefix(2).map { $0.concentricSec }.max() ?? 0
                if let lr = reps.last, lr.isGrind || (firstCon > 0 && lr.concentricSec >= firstCon * 1.6) {
                    r += 0.5; why.append("last rep a grind")
                }
                let early = reps.prefix(2).compactMap { $0.bottomPauseSec }
                if pauseGoal == nil, !early.isEmpty, let lp = reps.last?.bottomPauseSec,
                   lp - early.reduce(0, +) / Double(early.count) >= 0.4 {
                    r += 0.5; why.append("stalled at the bottom")
                }
                speed = r
            }
        }
        // From last set: its RPE, +0.5 for fatigue, ±0.5 for every 2.5% heavier or lighter
        var prior: Double? = nil
        var weightNote: String? = nil
        if let pr = prevRPE {
            var r = pr + 0.5
            if let pw = prevWeightLb, pw > 0 {
                let pct = (weightLb - pw) / pw * 100
                r += (pct / 2.5) * 0.5
                let d = StatsUnits.weight(weightLb) - StatsUnits.weight(pw)
                if abs(d) >= 0.5 {
                    let step = d == d.rounded() ? String(Int(abs(d))) : String(format: "%.1f", abs(d))
                    weightNote = "\(d > 0 ? "+" : "−")\(step) \(StatsUnits.weightLabel) from set \(prevNumber ?? 0)"
                }
            }
            prior = r
        }
        var rpe: Double
        switch (speed, prior) {
        case let (s?, p?):
            rpe = 0.6 * s + 0.4 * p
            if let n = weightNote { why.append(n) }
        case let (s?, nil):
            rpe = s
        case let (nil, p?):
            rpe = p
            why.append("set \(prevNumber ?? 0) was RPE \(prevRPE.map { $0.rpeText } ?? "")"
                       + (weightNote.map { " · \($0)" } ?? ", same weight · +0.5"))
        case (nil, nil):
            rpe = 8
            why.append("no speed data yet")
        }
        if done < target {
            rpe = max(rpe, target - done >= 2 ? 9.5 : 9)
            why.insert("\(target - done) short of \(target)", at: 0)
        }
        rpe = min(10, max(5, (rpe * 2).rounded() / 2))
        return (rpe, why.joined(separator: " · "))
    }

    /// Edit (the Lock Screen card's link, or the in-app card): the app's set row, reps selected.
    func requestEdit(setId: String?) {
        editRequest = setId
        if autoLogAt != nil { cancelAutoLog(); push(now: true) }   // Edit stops "Log by itself"
    }

    /// Log set on the in-app card: the same as the Lock Screen card's (the set as it's filled in).
    func logDone() { commitDone(thenRest: true) }

    // MARK: Live inputs

    private func heartRate(_ bpm: Int?) {
        guard workoutId != nil, let bpm else { return }
        if hrSamples.last.map({ Date().timeIntervalSince($0.0) >= 5 }) ?? true {
            hrSamples.append((Date(), bpm))
            hrSamples.removeAll { Date().timeIntervalSince($0.0) > 1800 }
        }
        // Redraw for heart rate every few seconds only when it's on screen; otherwise every
        // 15 s (the Dynamic Island shows it). Fewer background redraws = snappier taps.
        if shownView() == .heartRate && !logNeeded {
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
        guard let a = activity else { return }
        guard Self.isLive(a) else { replaceDeadCard(a); return }
        guard let s = makeState() else { return }
        persist()
        await a.update(ActivityContent(state: s, staleDate: staleDate()))
    }

    /// A card iOS can still show and take taps on.
    static func isLive(_ a: Activity<WorkoutActivityAttributes>) -> Bool {
        switch a.activityState {
        case .active, .stale: return true
        default: return false
        }
    }

    /// The card was ended by iOS: stop updating it, clear it away, and start a fresh one if the
    /// app's open (a new card can only be started from the foreground — otherwise on next open).
    private func replaceDeadCard(_ a: Activity<WorkoutActivityAttributes>) {
        print("[Live] card \(a.id.prefix(8)) is \(a.activityState) — replacing it")
        if activity?.id == a.id { activity = nil; activityToken = nil }
        Task { await a.end(nil, dismissalPolicy: .immediate) }
        if UIApplication.shared.applicationState == .active, let id = workoutId { begin(workoutId: id) }
    }

    /// Coalesced: at most one update every ~2 s unless `now`.
    private func push(now: Bool) {
        revision &+= 1                                  // the in-app card redraws now
        checkIdle()
        scheduleCardToWatch(now: now)                   // the Watch mirrors the same card
        guard activity != nil else { return }
        // One card update at a time, at most about once a second. Every update makes iOS redraw the
        // Lock Screen card: a flood of them makes taps land mid-redraw — and can get the app killed —
        // so the card's buttons stop working. A routine update that finds one already on its way
        // rides along with it (it'll carry the latest state); an urgent one replaces it.
        if !now, pushTask != nil { return }
        pushTask?.cancel()
        pushSerial &+= 1
        let serial = pushSerial
        let since = Date().timeIntervalSince(lastCardUpdate)
        let delay = now ? max(0, 1.0 - since) : max(2.0, 1.0 - since)
        pushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            if self.pushSerial == serial { self.pushTask = nil }
            guard let a = self.activity else { return }
            guard Self.isLive(a) else { self.replaceDeadCard(a); return }
            guard let s = self.makeState() else { return }
            self.persist()
            self.lastCardUpdate = Date()
            self.cardUpdates += 1
            print("[Live] card update #\(self.cardUpdates)\(now ? "" : " (routine)")")
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
        guard let (data, extras) = watchCardParts() else {
            WatchBridge.shared.sendCardEnd(endSession: false)  // no card right now (doesn't end a session)
            return
        }
        WatchBridge.shared.sendCard(data, extras: extras)
    }

    /// The card as one message — the same keys the Watch already handles. Used to answer the
    /// Watch's pull (which works even when the phone thinks the Watch isn't reachable).
    func watchCardPayload() -> [String: Any] {
        guard let (data, extras) = watchCardParts() else { return ["cardEnd": true, "endSession": false] }
        var p = extras
        p["card"] = data
        return p
    }

    private func watchCardParts() -> (Data, [String: Any])? {
        guard workoutId != nil, let s = makeState(), let data = try? JSONEncoder().encode(s) else { return nil }
        var extras: [String: Any] = ["cardDemo": isDemo, "cardStep": displayStep,
                                     "cardWarn": NotifPrefs.shared.s.restWarning]
        if let note = coachNoteForWatch() { extras["cardNote"] = note }
        let live = WatchBridge.shared.liveRepMotions.map(\.meanVelocity)
        if setStart != nil, !live.isEmpty { extras["cardLive"] = live }
        return (data, extras)
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
            for await st in a.activityStateUpdates {
                print("[Live] card \(a.id.prefix(8)): \(st)")      // diagnostics: what iOS thinks of the card
                guard st == .dismissed || st == .ended else { continue }
                guard let self, self.activity?.id == a.id else { continue }
                if st == .dismissed {
                    // You swiped the card away: that closes the live workout — the Watch's card and
                    // session clear too, and rest alerts stop. Opening the workout starts it again.
                    print("[Live] card swiped away — closing the live workout")
                    self.end(dismissal: .immediate)
                    continue
                }
                self.activity = nil
                self.activityToken = nil
                if self.resting { self.rescheduleRestAlerts() }
                // Ended by iOS (the 8-hour limit) while you're using the app: a fresh card right away.
                if st == .ended, UIApplication.shared.applicationState == .active, let id = self.workoutId {
                    self.begin(workoutId: id)
                }
            }
        }
    }

    /// The server brought the card back: carry on with it.
    private func adopt(_ a: Activity<WorkoutActivityAttributes>) {
        guard activity?.id != a.id, a.attributes.workoutId == workoutId else { return }
        if let old = activity { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        activity = a
        UserDefaults.standard.removeObject(forKey: closedKeepKey)
        watch(a)
        push(now: true)
    }

    /// The app opened mid-workout: bring the card back if it was closed, and take over the rest
    /// alerts here (the in-app bell), so nothing rings twice.
    func appBecameActive() {
        endCloseWatch()
        idleEnded = false
        touch()                                         // opening the app is activity: no idle end in your face
        if let id = workoutId, activity == nil { begin(workoutId: id) }
        if resting { rescheduleRestAlerts() }
    }

    /// The app went to the background: hand the rest of this rest's alerts to the card (via the server).
    func appWentToBackground() {
        beginCloseWatch()
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
    /// the rest ends and the border becomes Start set.
    private func staleDate() -> Date? {
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
        // A sensor view you picked stays put while the Watch is tracking — it fills in at the first rep.
        if userView.isSensor, isDemo || WatchBridge.shared.watchSessionLive { return userView }
        return avail.first ?? .sets
    }

    // MARK: Live link (the coach's iPad)

    /// The same picture the Lock Screen card shows, for the coach's iPad.
    func cardStateForLink() -> WorkoutActivityAttributes.ContentState? { makeState() }
    /// When the workout was opened (the iPad's session clock).
    func elapsedSinceForLink() -> Date { openedAt }
    /// The coach did something: counts as activity (the card isn't ended for being idle).
    func touchFromLink() { touch() }
    /// The coach changed the plan from the iPad (the workout's been fetched again): redraw the card.
    func planChangedFromLink() { touch(); push(now: true) }

    private func makeState() -> WorkoutActivityAttributes.ContentState? {
        guard let store, let wid = workoutId, let w = store.workouts.first(where: { $0.id == wid }) else { return nil }
        let unit = StatsUnits.weightLabel
        let disp: (Double) -> Double = { (StatsUnits.weight($0) * 2).rounded() / 2 }
        let first = w.exercises.flatMap { $0.sets }.compactMap { $0.loggedAt }.min()
        var s = WorkoutActivityAttributes.ContentState(startedAt: min(first ?? openedAt, openedAt))
        Self.applyLook(&s)

        // Left quarter: the set you're on (or the last one, when everything's logged).
        let next = Self.nextSet(w)
        let ex = next?.0 ?? w.exercises.last
        if let ex {
            s.exercise = ex.name
            s.setCount = ex.sets.count
            // The goal line: reps × weight as always, with the weight worked out here (SetTarget) — a
            // back-off's, an RPE set's starting weight, or "—". goalWeight is the same weight as a number
            // (the Watch shows and edits it; 0 = bodyweight, or a back-off with nothing logged yet).
            let goalSet = next?.1 ?? ex.sets.last
            if let g = goalSet {
                s.setNumber = next?.2 ?? ex.sets.count
                s.goalReps = g.targetReps
                s.goalWeight = disp(SetTarget.shownWeight(g, in: ex) ?? 0)
                s.goalText = SetTarget.text(g, in: ex)
            }
            if let nx = next, nx.2 < ex.sets.count {
                // Log set's instant preview: the next set as it'll read once this one is logged (a back-off
                // gets its weight from the set you're about to log, not "—").
                var after = ex
                if logNeeded, let p = prefill(w) {
                    after.sets[nx.2 - 1].loggedReps = p.reps
                    after.sets[nx.2 - 1].loggedWeight = p.weightLb
                }
                s.nextGoalText = SetTarget.text(after.sets[nx.2], in: after)
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

        // Last set from the Watch — or, while you're lifting, the set in progress, rep by rep
        // (only reps from this set: right after Start, the previous set's may still be here).
        var lastM = lastMotion(w)                   // one scan, used for the views list too
        let live = WatchBridge.shared.liveRepMotions
        var isLive = false
        if let started = setStart, let first = live.first, let lastRep = live.last,
           first.start >= started.addingTimeInterval(-5), let nx = Self.nextSet(w) {
            let m = SetMotion(id: "live", workoutId: wid, exerciseId: nx.0.id, setId: nx.1.id, exerciseName: nx.0.name,
                              start: first.start, end: lastRep.end, reps: live, autoDetected: true, analyzerVersion: 1)
            lastM = (nx.0, nx.1, nx.2, m)
            isLive = true
        }
        s.liveSet = isLive ? true : nil
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
                LiveSetRow(n: i + 1, tReps: st.targetReps, tWeight: disp(SetTarget.shownWeight(st, in: ex) ?? 0),
                           reps: st.loggedReps, weight: st.loggedWeight.map(disp), rpe: st.rpe, current: st.id == cur,
                           tText: SetTarget.short(st, in: ex))
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

        // Predictions for instant previews: the rest that Log set starts, and the view that
        // comes back after it.
        if let nx = next {
            s.nextReps = nx.1.targetReps
            s.nextWeight = disp(SetTarget.isFixed(nx.1) || SetTarget.isBodyweight(nx.1)
                ? (nx.0.sets.last(where: { $0.loggedWeight != nil })?.loggedWeight ?? nx.1.targetWeight)
                : (SetTarget.startWeight(nx.1, in: nx.0, workoutId: wid, workouts: store.workouts) ?? 0))
            s.nextRPE = nx.0.sets.last(where: { $0.rpe != nil })?.rpe ?? 8
            s.restSeconds = nx.0.restSeconds
        }
        let willShowAfterSet = isDemo || WatchBridge.shared.watchSessionLive
        s.afterSaveView = willShowAfterSet && s.available.contains(lastSensorView) ? lastSensorView
            : (s.available.contains(userView) ? userView : (s.available.first ?? .sets))

        // The finished set, filled in (the Watch's log tile reads the same fields)
        s.editing = false
        s.editSet = next?.2 ?? s.setNumber
        if logNeeded, let p = prefill(w) {
            s.dReps = p.reps
            s.dWeight = disp(p.weightLb)
            s.dRPE = p.rpe
            s.rpeWhy = p.why
            s.doneByWatch = p.byWatch
            s.autoLogAt = autoLogAt
            if let nx = next {
                var c = URLComponents(); c.scheme = "bigscherly"; c.host = "editset"
                c.queryItems = [URLQueryItem(name: "id", value: wid), URLQueryItem(name: "set", value: nx.1.id)]
                s.editLink = c.url?.absoluteString
            }
        } else {
            s.dReps = s.nextReps
            s.dWeight = s.nextWeight
            s.dRPE = s.nextRPE
        }
        return s
    }

    /// The card's look (Settings ▸ Lock Screen & Dynamic Island): Light / Dark / Auto (nil: the card
    /// follows the Lock Screen) or the app's theme; the accent (the app's, or the card's own pick)
    /// made readable on the black card, and its shades on the white one — the app's Light rules;
    /// pale accents draw their lines in grey. Plus the Island pill and what happens after a set.
    static func applyLook(_ s: inout WorkoutActivityAttributes.ContentState) {
        let theme = ThemeStore.shared
        let raw = RGBColor(hex: CardPrefs.accent ?? theme.accent)
        let accent = raw.readableOnDark(RGBColor(hex: 0x010101))
        s.accent = accent.hex
        s.accentInkWhite = accent.textOn == .white
        switch CardPrefs.look {
        case .app: s.light = theme.forcedScheme.map { $0 == .light }
        case .light: s.light = true
        case .dark: s.light = false
        case .auto: s.light = nil
        }
        s.fill = raw.hex
        s.fillInkWhite = raw.textOn == .white
        s.lineLight = raw.contrast(.white) < 1.6 ? 0x8E8E93 : raw.hex
        s.headLight = raw.readableOnDark(RGBColor(hex: 0x39393B)).hex
        s.island = CardPrefs.island
        s.afterSetMode = CardPrefs.afterSet.rawValue
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

/// A thread-safe "finished" flag (the card's end runs off the main thread while the main thread waits).
nonisolated private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

