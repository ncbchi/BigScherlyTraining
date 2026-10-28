import SwiftUI
import Combine
import ActivityKit
import HealthKit

// MARK: - Quick start tour (client) — Oct 15, 2026
//
// A guided tour on the real screens. Home shows a card the first time (Start tour / Skip); Skip
// leaves it in Settings ▸ Tools. While the tour runs, everything dims except the one thing being
// explained (one spotlight that glides from target to target) and a tip sits beside it.
//
// The workout part runs on a PRACTICE workout: the real LiveCard, fed sample Watch data through
// `LiveCard(demo:)`. Nothing touches the store, the live session, the Watch or the server, and the
// client's own window count and metrics (bst_live_windows / bst_live_metrics) are never written.
//
// Targets: any view marks itself with `.tourTarget("id")`; its on-screen frame is kept here.
// Progress is remembered per account on this phone (bst_tour_status_<client id>).
//
// File lives in the synchronized BigScherlyTraining folder — no target step needed.

// MARK: - Steps

enum TourScreen { case home, workout, stats }
enum TourDemo { case none, windows, swipe, setEnds, rest }
enum TourExtra { case none, watchFeeds, windowCounts, metricStrip }
enum TourAction { case none, logSet, openPlates, connectHealth }
enum TourPart: Int, CaseIterable { case home = 0, card, after
    var label: String { ["Home", "Live card", "After your set"][rawValue] }
}
enum PracticeStage { case rest, lifting, logging }

struct TourStep: Identifiable, Equatable {
    let id: String
    var target: String?                 // nil: a centred tip, no spotlight
    var screen: TourScreen
    var part: TourPart
    var title: String
    var body: String
    var extra: TourExtra = .none
    var next: String = "Next"
    var demo: TourDemo = .none
    var action: TourAction = .none
    var radius: CGFloat = 20
    var pad: CGFloat = 6
    var via: String? = nil              // a control the spotlight lands on before the screen changes
}

struct TourPartProgress: Identifiable {
    let part: TourPart
    let total: Int
    let done: Int
    var id: Int { part.rawValue }
}

/// Asks the scroll view holding a target to bring it into view (n changes every request).
struct TourScroll: Equatable { var id: String; var n: Int }

// MARK: - The tour

@MainActor
final class QuickStartTour: ObservableObject {
    static let shared = QuickStartTour()

    @Published private(set) var isActive = false
    @Published private(set) var steps: [TourStep] = []
    @Published private(set) var index = 0
    @Published private(set) var screen: TourScreen = .home
    @Published private(set) var spot: CGRect? = nil            // global coordinates
    @Published private(set) var aperture: CGFloat = 0           // extra margin while the spotlight opens/closes
    @Published private(set) var dim: Double = 0
    @Published private(set) var pulse = false
    @Published private(set) var homeScroll: TourScroll? = nil
    @Published private(set) var practiceScroll: TourScroll? = nil
    @Published private(set) var hint: CGFloat = 0               // the Swipe pill: −1 … 1
    @Published private(set) var showHint = false
    @Published var showToast = false
    @Published private(set) var cardDismissed = false           // left part-way: back next launch
    @Published private(set) var cardAway = false                // Start / Skip: the card leaves (animated)
    @Published private(set) var revision = 0                    // status changed: card + Settings redraw

    // The practice workout
    @Published var demoWindows = 1
    @Published var demoMetrics: [LiveMetric] = QuickStartTour.defaultMetrics
    @Published var demoNotes = false
    @Published var demoStage: PracticeStage = .rest
    @Published var demoReps = 0
    @Published var demoLogged = false
    @Published var logPressed = false
    @Published var restEnd = Date().addingTimeInterval(95)
    let restTotal: Double = 120

    static let defaultMetrics: [LiveMetric] = [.speed, .heartRate, .tempo, .depth]

    private var frames: [String: CGRect] = [:]
    private var transitioning = false
    private var demoTask: Task<Void, Never>?
    private var scrollN = 0
    private var undo: (String, String?)? = nil
    /// Start at this step instead of the first (Home's "Try a practice set", Oct 26, 2026).
    private var startAt: String? = nil
    private var store: AppStore { AppStore.shared }

    var current: TourStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isLast: Bool { index == steps.count - 1 }
    /// The numbered steps (the closing "You're set" isn't counted).
    var countedSteps: Int { max(1, steps.count - 1) }

    // MARK: Motion

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// The live-card window spring (Oct 11): the spotlight and the tip move on this.
    static var glide: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82) }
    /// The side dots' spring: small things.
    static var quick: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85) }
    static var present: Animation { reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.9) }

    // MARK: Status (per account, on this phone)

    private var account: String {
        let id = store.client.id
        return id.isEmpty ? "device" : id
    }
    private var statusKey: String { "bst_tour_status_" + account }
    private var stepKey: String { "bst_tour_step_" + account }
    /// "none", "inProgress", "skipped" or "done".
    var status: String { UserDefaults.standard.string(forKey: statusKey) ?? "none" }
    var savedStep: String? { UserDefaults.standard.string(forKey: stepKey) }
    var canResume: Bool { status == "inProgress" && savedStep != nil }

    /// Home's card: the first time, and again (once per launch) after leaving part-way.
    var showsCard: Bool { !isActive && !cardAway && !cardDismissed && (status == "none" || status == "inProgress") }

    var settingsSubtitle: String {
        if canResume, let s = savedStep {
            let all = buildSteps(health: false)
            if let i = all.firstIndex(where: { $0.id == s }) {
                return "Paused at \(i + 1) of \(max(1, all.count - 1)) · \(all[i].part.label)"
            }
        }
        return status == "done" ? "Take it again anytime · about 2 minutes" : "A quick look around · about 2 minutes"
    }

    /// The resume card's bar: how far through each part.
    func partProgress() -> [TourPartProgress] {
        let all = buildSteps(health: false).filter { $0.id != "END" }
        let at = savedStep.flatMap { s in all.firstIndex { $0.id == s } } ?? 0
        return TourPart.allCases.map { p in
            let idx = all.indices.filter { all[$0].part == p }
            return TourPartProgress(part: p, total: idx.count, done: idx.filter { $0 < at }.count)
        }
    }
    var resumeNumber: Int {
        let all = buildSteps(health: false)
        return (savedStep.flatMap { s in all.firstIndex { $0.id == s } } ?? 0) + 1
    }
    var resumeTotal: Int { max(1, buildSteps(health: false).count - 1) }
    var resumeNextTitle: String {
        let all = buildSteps(health: false)
        return savedStep.flatMap { s in all.first { $0.id == s }?.title } ?? ""
    }

    private func save(_ status: String, step: String?) {
        UserDefaults.standard.set(status, forKey: statusKey)
        if let step { UserDefaults.standard.set(step, forKey: stepKey) } else { UserDefaults.standard.removeObject(forKey: stepKey) }
        revision += 1
    }

    // MARK: Targets

    func report(_ id: String, _ r: CGRect) {
        guard r.width > 1, r.height > 1 else { frames[id] = nil; return }
        frames[id] = r
        // Follows scrolling exactly (no animation of its own).
        guard isActive, !transitioning, current?.target == id else { return }
        spot = r
    }

    func forget(prefix: String) {
        for k in frames.keys where k.hasPrefix(prefix) { frames[k] = nil }
    }

    // MARK: Card

    func skip() {
        undo = (status, savedStep)
        withAnimation(Self.present) { cardAway = true }
        save("skipped", step: nil)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Self.present) { showToast = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(Self.present) { self.showToast = false }
        }
    }

    func undoSkip() {
        if let u = undo { save(u.0, step: u.1) } else { save("none", step: nil) }
        undo = nil
        withAnimation(Self.present) { showToast = false; cardAway = false }
    }

    func dismissCardForNow() {
        withAnimation(Self.present) { cardDismissed = true }
    }

    // MARK: Start / end

    /// From Settings ▸ Tools: go Home, then start (or pick up where they left off).
    func startFromSettings() {
        store.showTray = false
        if store.activeTab != .dashboard { store.select(.dashboard) }
        start(resume: canResume, delay: 0.55)
    }

    /// New user Home (Oct 26, 2026): "Try a practice set" on the empty hero goes straight into the
    /// practice workout (the live card part of the tour). Nothing gets logged.
    func startPractice() {
        guard !isActive, store.sessionWorkoutId == nil else { return }
        startAt = "WC-01"
        start(resume: false)
    }

    func start(resume: Bool, delay: Double = 0.15) {
        guard !isActive, store.sessionWorkoutId == nil else { return }
        store.showTray = false
        withAnimation(Self.present) { cardAway = true; showToast = false }
        Task { @MainActor in
            let health = await Self.healthNeedsAsking()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))   // Home laid out: its targets are known
            self.steps = self.buildSteps(health: health)
            guard !self.steps.isEmpty else { return }
            let jump = self.startAt.flatMap { id in self.steps.firstIndex { $0.id == id } }
            self.startAt = nil
            self.index = resume ? (self.savedStep.flatMap { s in self.steps.firstIndex { $0.id == s } } ?? 0) : (jump ?? 0)
            self.resetDemo()
            self.screen = .home
            self.spot = nil
            self.aperture = 60
            self.dim = 0
            self.isActive = true
            self.save("inProgress", step: self.steps[self.index].id)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            self.enter(self.index, from: nil)
        }
    }

    /// End tour (part-way) or Done (finished). The spotlight widens off-screen as the dimming lifts.
    func end(finished: Bool = false) {
        guard isActive else { return }
        demoTask?.cancel()
        if finished {
            save("done", step: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            save("inProgress", step: current?.id)
            cardDismissed = true                 // the card comes back next launch
        }
        withAnimation(.easeOut(duration: 0.4)) {
            aperture = 600
            dim = 0
            showHint = false
        }
        if screen != .home { withAnimation(Self.present) { screen = .home } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            self.isActive = false
            self.cardAway = false
            self.spot = nil
            self.aperture = 0
            self.transitioning = false
            self.forget(prefix: "live.")
            self.forget(prefix: "stats.")
        }
    }

    // MARK: Moving through

    func next() {
        guard isActive, let step = current else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch step.action {
        case .logSet:
            logSet()
            return
        case .connectHealth:
            Task { @MainActor in
                _ = await HealthKitManager.shared.requestAuthorization()
                self.advance()
            }
            return
        case .none, .openPlates:
            break
        }
        advance()
    }

    func back() {
        guard isActive, index > 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        go(index - 1)
    }

    /// A tap on the lit-up area does the real thing.
    func tapSpot() {
        guard isActive, let step = current else { return }
        if step.action == .openPlates {
            var r = PlateCalcRequest()
            r.exerciseName = "Back Squat"
            r.startTotal = StatsUnits.weight(185)
            r.lift = PlateLift.of("Back Squat")
            PlateCalc.shared.open(r)
            return
        }
        next()
    }

    func replay() {
        guard let step = current, step.demo != .none else { return }
        applyBase(for: index)
        runDemo(step.demo)
    }

    private func advance() {
        if index + 1 < steps.count { go(index + 1) } else { end(finished: true) }
    }

    private func go(_ i: Int) {
        let old = index
        demoTask?.cancel()
        withAnimation(Self.quick) { showHint = false }
        withAnimation(Self.glide) { index = i }
        enter(i, from: old)
    }

    private func enter(_ i: Int, from old: Int?) {
        guard steps.indices.contains(i) else { return }
        let step = steps[i]
        save("inProgress", step: step.id)
        withAnimation(Self.glide) { applyBase(for: i) }

        guard step.screen != screen else { settle(step); return }

        // Changing screens. Forward from Home: land on the control first (Start workout), pulse, then open.
        transitioning = true
        let forwardFromHome = screen == .home && (old ?? -1) < i
        Task { @MainActor in
            if forwardFromHome, let via = step.via, let r = self.frames[via] {
                withAnimation(Self.glide) { self.spot = r; self.aperture = 0; self.dim = 1 }
                try? await Task.sleep(nanoseconds: 420_000_000)
                withAnimation(.easeOut(duration: 0.12)) { self.pulse = true }
                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.easeIn(duration: 0.15)) { self.pulse = false }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            withAnimation(Self.present) { self.screen = step.screen }
            try? await Task.sleep(nanoseconds: 560_000_000)        // the practice screen has slid in
            if step.screen == .home { self.forget(prefix: "live."); self.forget(prefix: "stats.") }
            self.transitioning = false
            self.settle(step)
        }
    }

    /// The spotlight goes to the step's target (scrolling it into view first), then its demo runs.
    private func settle(_ step: TourStep) {
        if let t = step.target {
            scrollN += 1
            if t.hasPrefix("home.") { homeScroll = TourScroll(id: t, n: scrollN) }
            if t.hasPrefix("live.") { practiceScroll = TourScroll(id: t, n: scrollN) }
        }
        withAnimation(Self.glide) {
            spot = step.target.flatMap { frames[$0] }
            aperture = 0
            dim = 1
        }
        // A target still laying out (the practice card's windows mount a frame apart): catch up.
        if let t = step.target {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard self.isActive, self.current?.target == t, let r = self.frames[t], r != self.spot else { return }
                withAnimation(Self.glide) { self.spot = r }
            }
        }
        runDemo(step.demo)
    }

    // MARK: Practice workout state

    private func resetDemo() {
        demoWindows = 1
        demoMetrics = Self.defaultMetrics
        demoNotes = false
        demoStage = .rest
        demoReps = 0
        demoLogged = false
        logPressed = false
        restEnd = Date().addingTimeInterval(95)
        practiceStart = Date().addingTimeInterval(-24 * 60)
        heart = Self.makeHeart(start: practiceStart)
    }

    /// Where the practice card should be for step i, so Back always looks right.
    private func applyBase(for i: Int) {
        let ids = steps.map(\.id)
        let windowsAt = ids.firstIndex(of: "WC-04") ?? Int.max
        let endsAt = ids.firstIndex(of: "WC-07") ?? Int.max
        let logAt = ids.firstIndex(of: "WC-08") ?? Int.max
        let step = steps[i]

        if step.demo != .windows { demoWindows = i < windowsAt ? 1 : 2 }
        if step.demo != .swipe { demoMetrics = Self.defaultMetrics }
        if i < endsAt || i == endsAt {
            demoStage = .rest; demoNotes = false; demoLogged = false; demoReps = 0
        } else if i == logAt {
            demoStage = .logging; demoNotes = true; demoLogged = false; demoReps = 5
        } else {
            demoStage = .rest; demoNotes = false; demoLogged = true; demoReps = 5
        }
        if demoStage == .rest, restEnd.timeIntervalSinceNow < 20 { restEnd = Date().addingTimeInterval(95) }
        logPressed = false
    }

    private func runDemo(_ d: TourDemo) {
        demoTask?.cancel()
        guard d != .none else { return }
        if Self.reduceMotion {                               // the end state, no movement
            switch d {
            case .windows: demoWindows = 4
            case .setEnds: demoStage = .logging; demoReps = 5; demoNotes = true
            case .rest: restEnd = Date().addingTimeInterval(95)
            case .swipe, .none: break
            }
            return
        }
        demoTask = Task { @MainActor in
            func wait(_ s: Double) async -> Bool {
                try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                return !Task.isCancelled
            }
            let tick = UISelectionFeedbackGenerator()
            switch d {
            case .windows:
                // The tour taps the chevron: 1 → 2 → 3 → 4, the card's own window animation.
                demoWindows = 1
                guard await wait(0.6) else { return }
                for n in 2...4 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { demoWindows = n }
                    tick.selectionChanged()
                    guard await wait(0.5) else { return }
                }
            case .swipe:
                // A Swipe pill slides left once, and the top window really pages: Bar speed → Tempo → back.
                guard await wait(0.5) else { return }
                hint = 0.6
                withAnimation(Self.quick) { showHint = true }
                withAnimation(.easeInOut(duration: 0.55)) { hint = -0.6 }
                guard await wait(0.3) else { return }
                withAnimation(.easeOut(duration: 0.15)) { setTop(.tempo) }
                tick.selectionChanged()
                guard await wait(1.1) else { return }
                withAnimation(.easeInOut(duration: 0.55)) { hint = 0.6 }
                guard await wait(0.3) else { return }
                withAnimation(.easeOut(duration: 0.15)) { setTop(.speed) }
                tick.selectionChanged()
                guard await wait(0.6) else { return }
                withAnimation(Self.quick) { showHint = false }
            case .setEnds:
                // The practice set: lifting, the Watch counts 1…5, then SET DONE and the notes take over.
                withAnimation(.spring(response: 0.4)) { demoStage = .lifting; demoReps = 0; demoNotes = false }
                for r in 1...5 {
                    guard await wait(0.42) else { return }
                    withAnimation(.spring(response: 0.4)) { demoReps = r }
                }
                guard await wait(0.55) else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { demoStage = .logging; demoNotes = true }
                tick.selectionChanged()
            case .rest:
                restEnd = Date().addingTimeInterval(95)
            case .none:
                break
            }
        }
    }

    private func setTop(_ m: LiveMetric) {
        var all = demoMetrics
        if let j = all.firstIndex(of: m), j != 0 { all.swapAt(0, j) } else if all.first != m { all[0] = m }
        demoMetrics = all
    }

    /// Log set on the practice card: the tile squeezes, its tick lands, Set 3 fills in, then on.
    private func logSet() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { logPressed = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self.logPressed = false
                self.demoLogged = true
                self.demoNotes = false
                self.demoStage = .rest
                self.restEnd = Date().addingTimeInterval(95)
            }
            try? await Task.sleep(nanoseconds: 380_000_000)
            self.advance()
        }
    }

    // MARK: The practice workout's data (sample Watch data, never saved)

    private(set) var practiceStart = Date().addingTimeInterval(-24 * 60)
    private(set) var heart: [(Date, Int)] = []

    private static let speeds: [[Double]] = [[0.52, 0.51, 0.49, 0.47, 0.45],
                                             [0.52, 0.50, 0.47, 0.44, 0.41],
                                             [0.53, 0.51, 0.48, 0.45, 0.42]]

    var practiceWorkout: Workout {
        let now = Date()
        var sets: [ExerciseSet] = (1...4).map { n in
            ExerciseSet(id: "tour-set-\(n)", targetReps: 5, targetWeight: 185)
        }
        for i in 0..<2 {
            sets[i].loggedReps = 5; sets[i].loggedWeight = 185; sets[i].rpe = 7 + Double(i)
            sets[i].loggedAt = now.addingTimeInterval(Double(i - 2) * 240)
        }
        if demoLogged {
            sets[2].loggedReps = 5; sets[2].loggedWeight = 185; sets[2].rpe = 8.5; sets[2].loggedAt = now
        }
        let ex = Exercise(id: "tour-squat", name: "Back Squat", muscleGroup: "Quads",
                          description: "", coachNotes: "", sets: sets, restSeconds: 120)
        return Workout(id: "tour-practice", title: "Practice workout", date: now, exercises: [ex])
    }

    func motion(_ setIndex: Int) -> SetMotion {
        let v = Self.speeds[min(max(setIndex, 0), 2)]
        var t = practiceStart.addingTimeInterval(Double(setIndex) * 240)
        var reps: [RepMotion] = []
        for (i, s) in v.enumerated() {
            let ecc = 2.0 + 0.05 * Double(i)
            let pause = 0.3 + 0.07 * Double(i)
            let con = 0.56 / s
            let end = t.addingTimeInterval(ecc + pause + con)
            reps.append(RepMotion(index: i + 1, start: t, end: end, eccentricSec: ecc, bottomPauseSec: pause,
                                  concentricSec: con, topPauseSec: 0.8, travelM: 0.56 - 0.004 * Double(i),
                                  meanVelocity: s, peakVelocity: s * 1.45, stickingPoint: 0.35, driftM: 0.02))
            t = end.addingTimeInterval(0.8)
        }
        return SetMotion(id: "tour-motion-\(setIndex)", workoutId: "tour-practice", exerciseId: "tour-squat",
                         setId: "tour-set-\(setIndex + 1)", exerciseName: "Back Squat",
                         start: reps.first?.start ?? t, end: reps.last?.end ?? t, reps: reps,
                         autoDetected: true, analyzerVersion: 1)
    }

    var liveDemo: TourLiveDemo {
        let w = practiceWorkout
        let ex = w.exercises[0]
        let showing = (demoLogged || demoStage == .logging) ? 2 : 1          // set 3 once it's done, else set 2
        var set = ex.sets[showing]
        if set.loggedReps == nil { set.loggedReps = 5; set.loggedWeight = 185; set.rpe = 8.5 }
        let m = motion(showing)
        let notes = CoachNotes.make(exercise: ex, set: set, motion: m, pauseTarget: PauseTarget.target(ex), workouts: store.workouts)
        let live: [RepMotion]? = demoStage == .lifting ? Array(motion(2).reps.prefix(demoReps)) : nil
        let ctx = LiveMetricContext(exercise: ex, motion: m, liveReps: live, lastTime: nil,
                                    notes: notes, notesMotion: m, notesLabel: "Back Squat · Set \(showing + 1)")
        let done = w.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        return TourLiveDemo(windows: demoWindows, metrics: demoMetrics, notesTakeover: demoNotes, ctx: ctx,
                            heart: heart, hrNow: demoStage == .lifting ? 152 : 118, start: practiceStart,
                            watchReady: WatchBridge.shared.isWatchReady, setsDone: done,
                            setsTotal: w.exercises.flatMap { $0.sets }.count,
                            setWindows: { [weak self] n in self?.demoWindows = n },
                            setMetrics: { [weak self] all in self?.demoMetrics = all; self?.demoNotes = false })
    }

    private static func makeHeart(start: Date) -> [(Date, Int)] {
        // Every 15 s since the start: a climb for each set, recovery between.
        var out: [(Date, Int)] = []
        var t = start
        let now = Date()
        var k = 0
        while t <= now {
            let phase = Double(k % 16) / 16
            let bump = phase < 0.25 ? phase / 0.25 : max(0, 1 - (phase - 0.25) / 0.6)
            out.append((t, Int(102 + 58 * bump + Double((k * 7) % 5))))
            t = t.addingTimeInterval(15); k += 1
        }
        return out
    }

    // MARK: Which steps

    static func healthNeedsAsking() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        var types = Set<HKObjectType>([HKObjectType.workoutType()])
        for id in [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .bodyMass] {
            if let q = HKObjectType.quantityType(forIdentifier: id) { types.insert(q) }
        }
        let s = try? await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: types)
        return s == .shouldRequest
    }

    private func buildSteps(health: Bool) -> [TourStep] {
        let s = store
        let cal = Calendar.training
        let watch = WatchBridge.shared.isWatchReady
        let hasHero = s.workouts.contains { !$0.completed && cal.isDateInToday($0.date) } || !s.upcomingWorkouts.isEmpty
        let edge = (UserDefaults.standard.string(forKey: "bst_hand") ?? "right") == "left" ? "left" : "right"
        var menu: [String] = []
        if !s.checkIns.isEmpty { menu.append("check-ins") }
        if !s.macroDays.isEmpty { menu.append("macros") }
        menu.append("chat with your coach")
        let menuText = (menu.count > 1 ? menu.dropLast().joined(separator: ", ") + " and " + menu.last! : menu[0])
        let activitiesOff = !ActivityAuthorizationInfo().areActivitiesEnabled

        var out: [TourStep] = []
        out.append(TourStep(id: "CT-01", target: "home.hero", screen: .home, part: .home,
                            title: hasHero ? "Today's workout lives here." : "Your next workout shows up here.",
                            body: hasHero ? (watch ? "One tap starts it. The Watch button starts it on your wrist instead." : "One tap starts it.")
                                          : "When your coach posts it, one tap starts it.",
                            radius: 24))
        out.append(TourStep(id: "CT-02", target: "home.week", screen: .home, part: .home,
                            title: "Your week, at a glance.",
                            body: "Tap a day to see what's planned or what you did. Pull the handle down for the whole month."))
        if frames["home.doses"] != nil {
            out.append(TourStep(id: "CT-12", target: "home.doses", screen: .home, part: .home,
                                title: "Today's doses.", body: "Tap a row when you take it. Your coach sees what you've taken."))
        }
        out.append(TourStep(id: "CT-03", target: "menu.button", screen: .home, part: .home,
                            title: "Everything else is in the menu.",
                            body: menuText.prefix(1).uppercased() + menuText.dropFirst() + ". You can also swipe in from the \(edge) edge.",
                            radius: 18, pad: 8))
        out.append(TourStep(id: "WC-01", target: "live.card", screen: .workout, part: .card,
                            title: "This is your live card.",
                            body: "It fills in while you lift, set by set. This is a practice workout, so nothing here is saved.",
                            radius: 26, pad: 4, via: hasHero ? "home.start" : nil))
        out.append(watch
            ? TourStep(id: "WC-02", target: "live.status", screen: .workout, part: .card,
                       title: "Your Apple Watch records every rep.",
                       body: "Time, sets done and heart rate sit up here. Everything below comes from your wrist. Nothing to tap.",
                       extra: .watchFeeds, radius: 16)
            : TourStep(id: "WC-02", target: "live.status", screen: .workout, part: .card,
                       title: "Pair an Apple Watch to record every rep.",
                       body: "Bar speed, tempo, pauses, depth and heart rate fill in on their own. Coach notes, trend and your sets work without one.",
                       radius: 16))
        if watch && !SetupEngine.bodyDone {
            out.append(TourStep(id: "CT-08", target: nil, screen: .workout, part: .card,
                                title: "Set up your Watch once.",
                                body: "It takes about a minute, in Settings › Apple Watch setup, and teaches it to count your reps."))
        }
        out.append(TourStep(id: "WC-04", target: "live.side", screen: .workout, part: .card,
                            title: "Show up to four windows at once.",
                            body: "Tap the arrow to add one, or tap a dot to jump straight there.",
                            extra: .windowCounts, demo: .windows, radius: 13, pad: 5))
        out.append(TourStep(id: "WC-05", target: "live.win0", screen: .workout, part: .card,
                            title: "Swipe a window to change it.",
                            body: "Each window shows something different. Pick from:",
                            extra: .metricStrip, demo: .swipe, radius: 16, pad: 4))
        out.append(TourStep(id: "WC-07", target: "live.win0", screen: .workout, part: .card,
                            title: "When a set ends, the top window shows its notes.",
                            body: "Your next set brings back what you picked.",
                            demo: .setEnds, radius: 16, pad: 4))
        out.append(TourStep(id: "WC-08", target: "live.setcard", screen: .workout, part: .card,
                            title: watch ? "Your Watch sees the set end." : "Log each set when you finish it.",
                            body: watch ? "Check the weight and reps, then log it. Edit fixes anything it got wrong."
                                        : "Check the weight and reps, then log it.",
                            next: "Log set", action: .logSet, radius: 24, pad: 4))
        out.append(TourStep(id: "WC-09", target: "stats.set", screen: .stats, part: .card,
                            title: "Every rep is saved with the set.",
                            body: "You'll see it in Stats, and so will your coach."))
        out.append(TourStep(id: "CT-05", target: "live.setcard", screen: .workout, part: .after,
                            title: "Rest follows you to the Lock Screen.",
                            body: "The timer and your next set show on the Lock Screen and in the Dynamic Island. +30s and Skip work there too."
                                + (activitiesOff ? " Live Activities are off for this app: turn them on in Settings › Big Scherly." : ""),
                            demo: .rest, radius: 24, pad: 4))
        out.append(TourStep(id: "CT-06", target: "live.plates", screen: .workout, part: .after,
                            title: "These are your plates.",
                            body: "The bubbles show what goes on each side of the bar. Tap them for the plate calculator.",
                            action: .openPlates, radius: 18, pad: 6))
        out.append(TourStep(id: "CT-07", target: "live.video", screen: .workout, part: .after,
                            title: "Show your coach a set.",
                            body: "Turn this on to film your sets. Ask anything in Chat, and your coach replies right in the app.",
                            radius: 27, pad: 5))
        if health {
            out.append(TourStep(id: "CT-09", target: nil, screen: .home, part: .after,
                                title: "Connect Apple Health.",
                                body: "So your coach can see heart rate and calories for each session.",
                                next: "Connect", action: .connectHealth))
        }
        out.append(TourStep(id: "END", target: nil, screen: .home, part: .after,
                            title: "You're set.",
                            body: "Make it yours in Settings › Appearance: your accent colour, light or dark, lb or kg. Replay this tour anytime in Settings › Tools.",
                            next: "Done"))
        return out
    }
}

// MARK: - Marking a target

extension View {
    /// Report this view's on-screen frame to the tour under `id` (only when `on`).
    func tourTarget(_ id: String, _ on: Bool = true) -> some View { modifier(TourTargetModifier(id: id, on: on)) }
}

private struct TourTargetModifier: ViewModifier {
    let id: String
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                QuickStartTour.shared.report(id, r)
            }
        } else {
            content
        }
    }
}

// MARK: - What the practice card is fed (see LiveCard(demo:))

struct TourLiveDemo {
    var windows: Int
    var metrics: [LiveMetric]
    var notesTakeover: Bool
    var ctx: LiveMetricContext
    var heart: [(Date, Int)]
    var hrNow: Int
    var start: Date
    var watchReady: Bool
    var setsDone: Int
    var setsTotal: Int
    var setWindows: (Int) -> Void
    var setMetrics: ([LiveMetric]) -> Void
}

/// The live card's thin status bar, for the practice workout.
struct TourStatusBar: View {
    let demo: TourLiveDemo
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(demo.watchReady ? Brand.danger : Brand.mute.opacity(0.5)).frame(width: 7, height: 7)
            Text(demo.start, style: .timer)
                .font(BrandFont.body(12, .heavy)).monospacedDigit().foregroundColor(Brand.text)
            Text("· \(demo.setsDone)/\(demo.setsTotal) sets").font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            if demo.watchReady {
                Image(systemName: "applewatch").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.voltText)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 10)).foregroundColor(Brand.danger)
                    Text("\(demo.hrNow)").font(BrandFont.body(12, .heavy)).monospacedDigit().foregroundColor(Brand.text)
                        .contentTransition(.numericText())
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "applewatch.slash").font(.system(size: 10, weight: .semibold))
                    Text("No Watch").font(BrandFont.body(11, .bold))
                }
                .foregroundColor(Brand.mute)
                .padding(.horizontal, 8).frame(height: 22)
                .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Home: the tour card, and the note after Skip

struct TourHomeCardHost: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var tour = QuickStartTour.shared
    @State private var shown = false

    private var eligible: Bool {
        let _ = tour.revision
        return tour.showsCard && !store.isTrainer && store.activeTab == .dashboard
            && store.sessionWorkoutId == nil && !store.showTray
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if shown && eligible {
                // Home dims a little behind the card.
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                TourStartCard()
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)))
            }
            if tour.showToast {
                TourSkipToast()
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .task(id: eligible) {
            if eligible {
                try? await Task.sleep(nanoseconds: 1_100_000_000)    // after Home's own entrance
                withAnimation(QuickStartTour.present) { shown = true }
            } else {
                withAnimation(QuickStartTour.present) { shown = false }
            }
        }
    }
}

private struct TourStartCard: View {
    @ObservedObject private var tour = QuickStartTour.shared

    var body: some View {
        let resume = tour.canResume
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity).padding(.top, -6)
            HStack(spacing: 9) {
                Image(systemName: "map.fill").font(.system(size: 13, weight: .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 28, height: 28).background(Circle().fill(Brand.volt))
                Text("QUICK START").font(BrandFont.body(11, .heavy)).tracking(1.6).foregroundColor(Brand.volt)
                Spacer()
                Text(resume ? "\(tour.resumeNumber) of \(tour.resumeTotal)" : "About 2 min")
                    .font(BrandFont.body(12, .bold)).monospacedDigit().foregroundColor(Color(hex: 0x9C9C9F))
            }
            Text(resume ? "Pick up where you left off." : "New here? Take the tour.")
                .font(BrandFont.display(30)).foregroundColor(.white).lineLimit(2).minimumScaleFactor(0.8)
            Text(resume ? "Next: " + tour.resumeNextTitle.tourLowerFirst
                        : "Start a workout, read your live card and reach your coach. You practise on a sample workout, so nothing gets logged.")
                .font(BrandFont.body(13.5)).foregroundColor(Color(hex: 0xD6D6D8)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if resume { progressBar }
            HStack(spacing: 10) {
                Button { tour.start(resume: resume) } label: {
                    Label(resume ? "Resume" : "Start tour", systemImage: "play.fill")
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                if resume {
                    Button("Start over") { tour.start(resume: false) }
                        .buttonStyle(TourGhostButton(bordered: true))
                    Button("Skip") { tour.skip() }.buttonStyle(TourGhostButton(bordered: false))
                } else {
                    Button("Skip") { tour.skip() }.buttonStyle(TourGhostButton(bordered: true))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28).fill(Color(hex: 0x121214).opacity(0.94)))
        .background(RoundedRectangle(cornerRadius: 28).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: -6)
        .environment(\.colorScheme, .dark)
    }

    /// Three parts — Home, Live card, After your set — filled to where they stopped (one sweep in).
    private var progressBar: some View {
        let parts = tour.partProgress()
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(parts) { p in
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule().fill(Brand.volt)
                                .frame(width: g.size.width * (p.total == 0 ? 0 : CGFloat(p.done) / CGFloat(p.total)))
                        }
                    }
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(Double(max(p.total, 1)))
                }
            }
            HStack {
                ForEach(parts) { p in
                    Text(p.part.label).font(BrandFont.body(10.5, .bold)).foregroundColor(Color(hex: 0x9C9C9F))
                        .frame(maxWidth: .infinity, alignment: p.part == .home ? .leading : (p.part == .after ? .trailing : .center))
                }
            }
        }
    }
}

private struct TourGhostButton: ButtonStyle {
    let bordered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(15, .bold))
            .foregroundColor(bordered ? .white : Color(hex: 0x9C9C9F))
            .padding(.horizontal, 18).frame(minHeight: 48)
            .overlay(Capsule().stroke(bordered ? Color.white.opacity(0.16) : .clear, lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .fixedSize()
    }
}

private struct TourSkipToast: View {
    @ObservedObject private var tour = QuickStartTour.shared
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "map.fill").font(.system(size: 13, weight: .bold)).foregroundColor(Brand.volt)
                .frame(width: 30, height: 30).background(Circle().fill(Brand.volt.opacity(0.14)))
            (Text("Tour skipped. It's in ") + Text("Settings › Tools").bold() + Text(" whenever you want it."))
                .font(BrandFont.body(13)).foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") { tour.undoSkip() }
                .font(BrandFont.body(14, .heavy)).foregroundColor(Brand.volt)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x2A2A2D)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 8)
        .environment(\.colorScheme, .dark)
    }
}


private extension String {
    var tourLowerFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - The overlay: dimming with one spotlight, and the tip

/// The dimming with a rounded hole; the hole's rect and corner animate, so the spotlight glides.
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat
    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(hole.animatableData, radius) }
        set { hole.animatableData = newValue.first; radius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -40, dy: -40))
        if hole.width > 0.5 && hole.height > 0.5 {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: min(radius, hole.width / 2, hole.height / 2),
                                                          height: min(radius, hole.width / 2, hole.height / 2)),
                             style: .continuous)
        }
        return p
    }
}

/// The tip's pointer: a small triangle, its two outer sides outlined.
private struct TipArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}

struct TourOverlay: View {
    @ObservedObject private var tour = QuickStartTour.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tipHeight: CGFloat = 180
    @State private var breathe = false

    private let tipBG = Color(hex: 0x232326)

    var body: some View {
        if tour.isActive, let step = tour.current {
            GeometryReader { g in
                let origin = g.frame(in: .global).origin
                let size = g.size
                let hole: CGRect? = tour.spot.map {
                    $0.offsetBy(dx: -origin.x, dy: -origin.y)
                      .insetBy(dx: -(step.pad + tour.aperture), dy: -(step.pad + tour.aperture))
                }
                let shapeHole = hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
                let r = hole == nil ? 0 : step.radius + tour.aperture * 0.25
                let place = tipPlacement(hole: hole, size: size)

                ZStack(alignment: .topLeading) {
                    // A whisper of blur, then the dark: deeper than plain black.
                    SpotlightShape(hole: shapeHole, radius: r)
                        .fill(.ultraThinMaterial, style: FillStyle(eoFill: true))
                        .opacity(0.45 * tour.dim)
                    SpotlightShape(hole: shapeHole, radius: r)
                        .fill(Color.black.opacity(0.66 * tour.dim), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        // The lit area does the real thing; the dark does nothing (no accidental exits).
                        .onTapGesture(coordinateSpace: .local) { p in
                            if let h = hole, h.contains(p) { tour.tapSpot() }
                        }

                    if let h = hole {
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .stroke(Brand.volt, lineWidth: 2)
                            .shadow(color: Brand.volt.opacity(breathe ? 0.5 : 0.28), radius: breathe ? 13 : 8)
                            .frame(width: h.width, height: h.height)
                            .scaleEffect(tour.pulse ? 1.05 : 1)
                            .position(x: h.midX, y: h.midY)
                            .opacity(tour.dim)
                            .allowsHitTesting(false)

                        if tour.showHint {
                            swipeHint
                                .position(x: h.midX + 34 * tour.hint, y: h.maxY - 34)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                .allowsHitTesting(false)
                        }
                    }

                    if place.arrow, let h = hole {
                        let ax = min(max(h.midX, place.x + 30), place.x + place.w - 30)
                        TipArrow()
                            .fill(tipBG)
                            .overlay(TipArrow().stroke(Brand.volt, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                            .frame(width: 18, height: 9)
                            .rotationEffect(.degrees(place.below ? 0 : 180))
                            .position(x: ax, y: place.below ? place.y - 3.5 : place.y + tipHeight + 3.5)
                            .opacity(tour.dim)
                            .zIndex(2)
                    }

                    TourTip(step: step)
                        .frame(width: place.w)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            withAnimation(QuickStartTour.quick) { tipHeight = h }
                        }
                        .offset(x: place.x, y: place.y + CGFloat(12 * (1 - tour.dim)))
                        .opacity(tour.dim)
                        .zIndex(1)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .onAppear {
                guard !reduceMotion else { return }
                // A very slow breath on the ring while a tip waits.
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
            }
            .onDisappear { breathe = false }
        }
    }

    private var swipeHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .heavy))
            Text("Swipe").font(BrandFont.body(12, .heavy))
        }
        .foregroundColor(Brand.volt)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .overlay(Capsule().stroke(Brand.volt, lineWidth: 1))
    }

    /// Below the spotlight if it fits, else above, else over the bottom; centred when there's no spotlight.
    private func tipPlacement(hole: CGRect?, size: CGSize) -> (x: CGFloat, y: CGFloat, w: CGFloat, below: Bool, arrow: Bool) {
        let w = min(size.width - 32, 360)
        let x = (size.width - w) / 2
        let top: CGFloat = 60, bottom: CGFloat = 40, gap: CGFloat = 16
        guard let h = hole else { return (x, (size.height - tipHeight) / 2, w, true, false) }
        if h.maxY + gap + tipHeight <= size.height - bottom { return (x, h.maxY + gap, w, true, true) }
        if h.minY - gap - tipHeight >= top { return (x, h.minY - gap - tipHeight, w, false, true) }
        return (x, size.height - bottom - tipHeight, w, false, false)
    }
}

// MARK: - The tip

private struct TourTip: View {
    let step: TourStep
    @ObservedObject private var tour = QuickStartTour.shared

    var body: some View {
        let number = tour.index + 1
        let total = tour.countedSteps
        let frac = tour.isLast ? 1 : CGFloat(number) / CGFloat(total)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if !tour.isLast {
                    Text("\(number) of \(total)")
                        .font(BrandFont.body(11, .heavy)).monospacedDigit().foregroundColor(Brand.volt)
                        .contentTransition(.numericText(value: Double(number)))
                }
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Brand.volt).frame(height: 3)
                            .scaleEffect(x: frac, y: 1, anchor: .leading)
                    }
                if step.demo != .none && step.demo != .rest {
                    Button { tour.replay() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .heavy))
                            .foregroundColor(Color(hex: 0x9C9C9F)).frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show it again")
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(step.title).font(BrandFont.body(16, .heavy)).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.body.isEmpty {
                    Text(step.body).font(BrandFont.body(13)).foregroundColor(Color(hex: 0xD6D6D8)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch step.extra {
                case .none: EmptyView()
                case .watchFeeds: TourWatchFeeds()
                case .windowCounts: TourWindowCounts(current: tour.demoWindows)
                case .metricStrip: TourMetricStrip(top: tour.demoMetrics.first ?? .speed)
                }
            }
            .id(step.id)
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))

            HStack(spacing: 8) {
                if !tour.isLast {
                    Button("End tour") { tour.end() }
                        .font(BrandFont.body(13, .bold)).foregroundColor(Color(hex: 0x9C9C9F))
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if tour.index > 0 {
                    Button("Back") { tour.back() }.buttonStyle(TourPill(primary: false))
                }
                Button(step.next) { tour.next() }.buttonStyle(TourPill(primary: true))
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x232326)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Brand.volt, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.55), radius: 17, x: 0, y: 14)
        .environment(\.colorScheme, .dark)
    }
}

private struct TourPill: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(14, .heavy))
            .foregroundColor(primary ? Brand.onVolt : .white)
            .padding(.horizontal, 16).frame(height: 38)
            .background(Capsule().fill(primary ? Brand.volt : Color.clear))
            .overlay(Capsule().stroke(primary ? Color.clear : Color.white.opacity(0.16), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The Watch, and what it records: the chips arrive one after another, 40 ms apart.
private struct TourWatchFeeds: View {
    @State private var shown = 0
    private let items: [(String, String)] = [("gauge.with.dots.needle.67percent", "Bar speed"), ("metronome.fill", "Tempo"),
                                             ("pause.fill", "Pauses"), ("arrow.down.to.line", "Depth"),
                                             ("heart.fill", "Heart rate"), ("list.bullet", "Reps")]
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "applewatch").font(.system(size: 20, weight: .semibold)).foregroundColor(Brand.volt)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt.opacity(0.14)))
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .heavy)).foregroundColor(Color(hex: 0x9C9C9F))
            TourFlow(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(spacing: 3) {
                        Image(systemName: it.0).font(.system(size: 9, weight: .bold)).foregroundColor(Brand.volt)
                        Text(it.1).font(BrandFont.body(10.5, .bold)).foregroundColor(.white)
                    }
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .opacity(i < shown ? 1 : 0)
                    .offset(x: i < shown ? 0 : -6)
                }
            }
        }
        .task {
            if QuickStartTour.reduceMotion { shown = items.count; return }
            for i in 1...items.count {
                try? await Task.sleep(nanoseconds: 40_000_000)
                withAnimation(.easeOut(duration: 0.2)) { shown = i }
            }
        }
    }
}

/// 1 · 2 · 3 · 4 layouts; the one on the card lights up.
private struct TourWindowCounts: View {
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { n in
                let on = n == current
                VStack(spacing: 5) {
                    VStack(spacing: 2) {
                        ForEach(Array(heights(n).enumerated()), id: \.offset) { _, h in
                            RoundedRectangle(cornerRadius: 3).fill(on ? Brand.volt : Color.white.opacity(0.22)).frame(height: h)
                        }
                    }
                    .padding(4)
                    .frame(width: 44, height: 46, alignment: .top)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Brand.volt : Color.white.opacity(0.18), lineWidth: 1.5))
                    Text("\(n)").font(BrandFont.body(10.5, .bold)).foregroundColor(on ? Brand.volt : Color(hex: 0x9C9C9F))
                }
                .frame(maxWidth: .infinity)
                .animation(QuickStartTour.quick, value: current)
            }
        }
        .padding(.vertical, 2)
    }
    private func heights(_ n: Int) -> [CGFloat] {
        switch n { case 1: return [36]; case 2: return [17, 17]; case 3: return [17, 8, 8]; default: return [11, 7, 7, 7] }
    }
}

/// The nine views a window can show; the one the top window is on lights up.
private struct TourMetricStrip: View {
    let top: LiveMetric
    var body: some View {
        TourFlow(spacing: 5) {
            ForEach(LiveMetric.allCases) { m in
                let on = m == top
                HStack(spacing: 4) {
                    Image(systemName: m.icon).font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(on ? Brand.onVolt : Brand.volt)
                    Text(m.title).font(BrandFont.body(11, .bold)).foregroundColor(on ? Brand.onVolt : .white)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(Capsule().fill(on ? Brand.volt : Color.clear))
                .overlay(Capsule().stroke(on ? Color.clear : Color.white.opacity(0.16), lineWidth: 1))
                .animation(QuickStartTour.quick, value: on)
            }
        }
    }
}

/// Wraps its children onto as many rows as they need.
private struct TourFlow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - The practice workout screen

struct TourPracticeView: View {
    @ObservedObject private var tour = QuickStartTour.shared

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            if tour.screen == .stats {
                TourSetDetail()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            } else {
                workoutPage
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .onDisappear { tour.forget(prefix: "live."); tour.forget(prefix: "stats.") }
    }

    private var workoutPage: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .heavy)).foregroundColor(Brand.text)
                Spacer()
                Text("WORKOUT IN PROGRESS").font(BrandFont.body(11, .heavy)).tracking(1.5).foregroundColor(Brand.mute)
                Spacer()
                Color.clear.frame(width: 15, height: 15)
            }
            .padding(.horizontal, 20).frame(height: 44)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "map.fill").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.voltText)
                            Text("Practice workout").font(BrandFont.body(12.5, .bold)).foregroundColor(Brand.voltText)
                            Text("· nothing gets saved").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.voltLine.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))

                        Text("Back Squat practice").font(BrandFont.display(30)).foregroundColor(Brand.text)

                        LiveCard(workout: tour.practiceWorkout, demo: tour.liveDemo)
                            .id("live.card")
                        TourSetCard()
                            .id("live.setcard")
                        TourExerciseCard()
                            .id("live.exercise")
                    }
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .onChange(of: tour.practiceScroll) { _, s in
                    guard let s else { return }
                    let (id, anchor) = scrollTarget(s.id)
                    withAnimation(QuickStartTour.glide) { proxy.scrollTo(id, anchor: anchor) }
                }
            }
        }
    }

    private func scrollTarget(_ t: String) -> (String, UnitPoint) {
        switch t {
        case "live.setcard", "live.video": return ("live.setcard", .center)
        case "live.plates": return ("live.exercise", .center)
        default: return ("live.card", .top)
        }
    }
}

/// The set card under the live card, in the practice workout (same look as LiveSetCard).
private struct TourSetCard: View {
    @ObservedObject private var tour = QuickStartTour.shared

    var body: some View {
        let next = tour.demoLogged ? 4 : 3
        HStack(alignment: .center, spacing: 12) {
            tile.frame(width: 118, height: 86)
            videoButton
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Back Squat").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                Text(kicker(next)).font(BrandFont.body(9, .heavy)).tracking(1.1)
                    .foregroundColor(tour.demoStage == .lifting ? Brand.danger : Brand.mute).lineLimit(1).minimumScaleFactor(0.75)
                Text(value).font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(tour.demoStage == .rest ? Brand.voltText : Brand.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    switch tour.demoStage {
                    case .rest:
                        pill("+30s", filled: false)
                        pill("Skip", filled: true)
                    case .logging: pill("Edit", filled: false)
                    case .lifting: EmptyView()
                    }
                }
                .padding(.top, 5)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
            .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3))
        .tourTarget("live.setcard")
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: tour.demoStage)
    }

    private func kicker(_ next: Int) -> String {
        switch tour.demoStage {
        case .rest: return "UP NEXT · SET \(next) OF 4"
        case .lifting: return "SET 3 OF 4 · LIFTING"
        case .logging: return "SET 3 DONE" + (WatchBridge.shared.isWatchReady ? " · FROM YOUR WATCH" : "")
        }
    }

    private var value: String {
        switch tour.demoStage {
        case .rest: return "5 × " + StatsUnits.weightText(185)
        case .lifting: return tour.demoReps == 0 ? "Waiting for rep 1" : "Rep \(tour.demoReps) of 5"
        case .logging: return "5 × " + StatsUnits.weightText(185) + " · RPE 8.5~"
        }
    }

    @ViewBuilder private var tile: some View {
        switch tour.demoStage {
        case .rest:
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let left = max(0, tour.restEnd.timeIntervalSince(ctx.date))
                let s = Int(ceil(left))
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Brand.text.opacity(0.05))
                    RoundedRectangle(cornerRadius: 16).inset(by: 3).stroke(Brand.text.opacity(0.10), lineWidth: 6)
                    RoundedRectangle(cornerRadius: 16).inset(by: 3)
                        .trim(from: 0, to: min(1, left / tour.restTotal))
                        .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .animation(.linear(duration: 0.25), value: left)
                    VStack(spacing: 0) {
                        Text("REST").font(BrandFont.body(8, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                        Text(String(format: "%d:%02d", s / 60, s % 60))
                            .font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(Brand.text)
                            .contentTransition(.numericText())
                    }
                }
            }
        case .lifting:
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Brand.text.opacity(0.05))
                RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1.5)
                VStack(spacing: 1) {
                    Text("SET 3 · LIFTING").font(BrandFont.body(7.5, .heavy)).tracking(0.8).foregroundColor(Brand.voltText)
                    Text("\(tour.demoReps)").font(.system(size: 28, weight: .heavy, design: .rounded))
                        .monospacedDigit().foregroundColor(Brand.text).contentTransition(.numericText(value: Double(tour.demoReps)))
                }
            }
        case .logging:
            VStack(spacing: 4) {
                Image(systemName: tour.logPressed ? "checkmark.circle.fill" : "checkmark")
                    .font(.system(size: 24, weight: .heavy))
                    .contentTransition(.symbolEffect(.replace))
                Text("Log set").font(.system(size: 13, weight: .heavy))
            }
            .foregroundColor(Brand.onVolt)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt))
            .scaleEffect(tour.logPressed ? 0.94 : 1)
        }
    }

    /// Same look as SetVideoToggle (off): the set-video button.
    private var videoButton: some View {
        Circle().fill(Brand.card)
            .overlay(Circle().stroke(Brand.voltLine, lineWidth: 1.6))
            .overlay(Image(systemName: "video.fill").font(.system(size: 15, weight: .heavy)).foregroundColor(Brand.voltText))
            .frame(width: 42, height: 42)
            .tourTarget("live.video")
    }

    private func pill(_ t: String, filled: Bool) -> some View {
        Text(t).font(BrandFont.body(12, .heavy))
            .foregroundColor(filled ? Brand.onVolt : Brand.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(filled ? Brand.volt : Color.clear))
            .overlay(Capsule().stroke(filled ? Color.clear : Brand.line, lineWidth: 1.5))
    }
}

/// The exercise's sets in the practice workout; the next set carries its plate bubbles.
private struct TourExerciseCard: View {
    @ObservedObject private var tour = QuickStartTour.shared
    @ObservedObject private var gym = GymEquipment.shared

    var body: some View {
        let w = tour.practiceWorkout
        let sets = w.exercises[0].sets
        let nextIdx = sets.firstIndex { $0.loggedReps == nil }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("1 OF 1 · QUADS").font(BrandFont.body(9, .bold)).tracking(1.2).foregroundColor(Brand.voltText)
                Text("Back Squat").font(BrandFont.display(28)).foregroundColor(Brand.text)
            }
            ForEach(Array(sets.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    ZStack {
                        if s.loggedReps != nil {
                            Circle().fill(Brand.volt)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(Brand.onVolt)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Circle().stroke(i == nextIdx ? Brand.voltLine : Brand.line, lineWidth: 1.6)
                            Text("\(i + 1)").font(BrandFont.body(11, .heavy)).foregroundColor(Brand.voltText)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text("Set \(i + 1)").font(BrandFont.body(13, .bold)).foregroundColor(Brand.mute).frame(width: 46, alignment: .leading)
                    Text("5 × " + StatsUnits.weightText(185)).font(BrandFont.body(14, .bold))
                        .foregroundColor(s.loggedReps != nil || i == nextIdx ? Brand.text : Brand.mute)
                    Spacer(minLength: 4)
                    if s.loggedReps != nil, i < 3 {
                        Text(StatsUnits.velocityText(tour.motion(i).meanVelocity)).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
                    } else if i == nextIdx, let lift = PlateLift.of("Back Squat") {
                        PlateBubbles(plates: gym.iconPlates(lift: lift, total: StatsUnits.weight(185)),
                                     kg: gym.isKg, pair: gym.setup(for: lift).sides == 2)
                            .padding(3)
                            .tourTarget("live.plates")
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: s.loggedReps)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.voltLine.opacity(0.45), lineWidth: 1))
    }
}

/// Stats for a moment: the practice set, rep by rep, and who sees it.
private struct TourSetDetail: View {
    @ObservedObject private var tour = QuickStartTour.shared
    @State private var grown = false

    var body: some View {
        let m = tour.motion(2)
        let best = m.reps.map(\.meanVelocity).max() ?? 1
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .heavy)).foregroundColor(Brand.text)
                Spacer()
                Text("Back Squat").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                Spacer()
                Color.clear.frame(width: 17, height: 17)
            }
            .padding(.horizontal, 20).frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(["Bar speed", "Tempo", "Depth", "Heart rate"], id: \.self) { t in
                            let on = t == "Bar speed"
                            Text(t).font(BrandFont.body(12, .heavy))
                                .foregroundColor(on ? Brand.onVolt : Brand.text)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? Brand.volt : Color.clear))
                                .overlay(Capsule().stroke(on ? Color.clear : Brand.line, lineWidth: 1))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("SET 3 · 5 × \(StatsUnits.weightText(185).uppercased())")
                                .font(BrandFont.body(11, .heavy)).tracking(1.4).foregroundColor(Brand.voltText)
                            Spacer()
                            Text("Today").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        }
                        HStack(alignment: .bottom, spacing: 7) {
                            ForEach(Array(m.reps.enumerated()), id: \.offset) { i, r in
                                VStack(spacing: 4) {
                                    Text(String(format: "%.2f", r.meanVelocity)).font(BrandFont.body(9.5, .heavy)).foregroundColor(Brand.mute)
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(r.meanVelocity < 0.43 ? Color(hex: 0xF2A03D) : Brand.volt)
                                        .frame(height: 104 * r.meanVelocity / best)
                                        .scaleEffect(x: 1, y: grown ? 1 : 0.02, anchor: .bottom)
                                        .animation(QuickStartTour.reduceMotion ? nil
                                                   : .spring(response: 0.5, dampingFraction: 0.8).delay(0.05 * Double(i)), value: grown)
                                    Text("R\(r.index)").font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 140, alignment: .bottom)
                        ForEach(m.reps) { r in
                            HStack {
                                Text("Rep \(r.index)").font(BrandFont.body(12.5, .bold)).foregroundColor(Brand.mute).frame(width: 46, alignment: .leading)
                                Text(StatsUnits.secondsText(r.eccentricSec ?? 0) + " down").frame(maxWidth: .infinity, alignment: .leading)
                                Text(StatsUnits.secondsText(r.bottomPauseSec ?? 0) + " pause").frame(maxWidth: .infinity, alignment: .leading)
                                Text(StatsUnits.depthText(r.travelM)).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(BrandFont.body(12.5)).monospacedDigit().foregroundColor(Brand.text)
                            .padding(.vertical, 6)
                            .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
                        }
                        HStack(spacing: 7) {
                            Image(systemName: "person.fill").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.voltText)
                            Text("Your coach sees this set, rep by rep.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        }
                        .opacity(grown ? 1 : 0)
                        .animation(.easeOut(duration: 0.3).delay(0.35), value: grown)
                        .padding(.top, 2)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
                    .tourTarget("stats.set")
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 40)
            }
            .scrollDisabled(true)
        }
        .task {
            try? await Task.sleep(nanoseconds: 450_000_000)          // after the push
            grown = true
        }
    }
}
