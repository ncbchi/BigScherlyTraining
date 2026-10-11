import Foundation
import Combine
import CoreMotion
import WatchKit
import SwiftUI

// MARK: - Motion recording on the wrist
// Runs only while a workout session is active (the session is what keeps the app
// alive with the wrist down). Watches for sets automatically: motion starts a
// set, ~7 seconds of quiet ends it, then RepAnalyzer turns it into per-rep metrics.
// While a set is in progress it re-analyses every half second so the wrist can
// show a live rep count and buzz once if bar speed drops past the threshold.

/// Speed-loss buzz settings (watch-local). Defaults: on, 20%.
nonisolated enum MotionSettings {
    static let buzzEnabledKey = "bst.motion.velocityLossBuzz"
    static let buzzThresholdKey = "bst.motion.velocityLossPct"
    static var buzzEnabled: Bool {
        UserDefaults.standard.object(forKey: buzzEnabledKey) as? Bool ?? true
    }
    static var buzzThresholdPct: Double {
        let v = UserDefaults.standard.double(forKey: buzzThresholdKey)
        return v > 0 ? v : 20
    }
}

/// What the grip check measured: how steady, and how the Watch sits in your grip.
nonisolated struct GripReading: Sendable {
    var shake: Double       // m/s², spread of vertical acceleration
    var rot: Double         // rad/s, median rotation
    var count: Int          // samples (0 = the Watch wasn't measuring)
    var tiltDeg: Double     // how far the Watch face is tipped from level in this grip
    var restZero: Double    // m/s², the resting vertical reading — the sensor's zero
}

@MainActor
final class MotionRecorder: ObservableObject {
    static let shared = MotionRecorder()

    @Published private(set) var isRecording = false
    /// Non-nil while a set is in progress.
    @Published private(set) var liveRepCount: Int? = nil
    @Published private(set) var liveLastVelocity: Double? = nil

    /// Phase 3 — pause buzz. Non-nil while you're held at the bottom of a rep.
    @Published private(set) var pauseStart: Date? = nil
    @Published private(set) var pauseTarget: Double = 0       // 0 = off
    @Published private(set) var pauseReached = false
    /// The phone's card says a set is under way (WatchState keeps this in step with the card).
    /// Outside a set, a still wrist after lowering your arm isn't a "bottom pause": no HOLD/GO
    /// screen and no GO tap. (Setup and a set the Watch has already started still count.)
    var setActive = false {
        didSet { if !setActive && (liveRepCount ?? 0) < 1 && !calibrating { applyPause(bottomAt: nil, reached: false) } }
    }
    /// From the phone (Settings ▸ Notifications ▸ Watch buzzes).
    var haptics = WatchHaptics(pauseStrength: 1, pauseTicks: false, slowRepOn: true, slowRepPct: 20, slowRepPattern: 0)
    /// Every rep so far in the set in progress (speed, lowering, pause, lifting, travel) —
    /// sent on to the phone's live card as each one is counted.
    var onLiveReps: (([RepMotion]) -> Void)?

    /// Called on the main actor when a finished set has at least one rep.
    var onSetDetected: ((_ reps: [RepMotion], _ start: Date, _ end: Date) -> Void)?
    /// v1.1: the first rep of a set was counted — the phone's Live Activity switches to "lifting".
    var onSetStarted: (() -> Void)?
    private var announcedStart = false

    private let processor = MotionProcessor()

    // MARK: Calibration (first-time setup) — reps go to the setup flow, not to a "set"
    /// While true: no "set started" for the phone, no slow-rep buzz, no set detection —
    /// reps and the set's end go to `onCalibReps` / `onCalibEnded` instead.
    var calibrating = false
    private var calibEndPending = false
    var onCalibReps: (([RepMotion]) -> Void)?
    var onCalibEnded: ((_ reps: [RepMotion], _ start: Date, _ end: Date) -> Void)?
    /// Briefly after setup, a set ending is still setup motion — ignore it.
    private var ignoreSetsUntil: Date?
    private var stillDone: ((GripReading) -> Void)?

    /// Setup finished. If a set is still open, stay in setup mode until it closes, so its tail
    /// can't be mistaken for a real set.
    /// Setup / debug recording starts: reps go to the setup flow. Clears a pending end from an
    /// earlier setup that was closed mid-set (otherwise this one would silently end at its first set).
    func beginCalibration() {
        calibrating = true
        calibEndPending = false
    }

    func endCalibration() {
        ignoreSetsUntil = Date().addingTimeInterval(10)
        if liveRepCount == nil { calibrating = false } else { calibEndPending = true }
    }

    /// "Hold still": measure how much the Watch moves (vertical shake m/s², rotation rad/s).
    func beginStillProbe() { processor.beginStillProbe() }

    /// Setup, rep steps: after the countdown, wait until you've settled into the starting position
    /// (still for `needed` seconds) — then it starts measuring. `done(false)` = gave up waiting.
    func waitForStillness(needed: Double, timeout: Double, _ done: @escaping @Sendable (Bool) -> Void) {
        processor.waitForStillness(needed: needed, timeout: timeout, done)
    }
    func cancelStillnessWait() { processor.cancelStillnessWait() }
    func endStillProbe(_ done: @escaping (GripReading) -> Void) {
        stillDone = done
        processor.endStillProbe { reading in
            Task { @MainActor in MotionRecorder.shared.finishStill(reading) }
        }
    }
    private func finishStill(_ reading: GripReading) {
        stillDone?(reading)
        stillDone = nil
    }

    // MARK: Motion capture (debug tool) — every raw sample from Go to hand-over
    func beginCapture() { processor.beginCapture() }
    func endCapture(_ done: @escaping @Sendable ([MotionSample]) -> Void) { processor.endCapture(done) }
    /// Live debug session: everything captured since the last call, and keep capturing.
    func drainCapture(_ done: @escaping @Sendable ([MotionSample]) -> Void) { processor.drainCapture(done) }

    private init() {
        // The recorder is a singleton, so the callbacks reach it through `shared`
        // instead of capturing `self` across threads.
        processor.onLive = { reps, buzz in
            Task { @MainActor in
                MotionRecorder.shared.applyLive(reps: reps, buzz: buzz)
            }
        }
        processor.onPause = { bottomAt, reached in
            Task { @MainActor in
                MotionRecorder.shared.applyPause(bottomAt: bottomAt, reached: reached)
            }
        }
        processor.onSetEnded = { reps, start, end in
            Task { @MainActor in
                MotionRecorder.shared.applySetEnded(reps: reps, start: start, end: end)
            }
        }
    }

    private func applyLive(reps: [RepMotion], buzz: Bool) {
        if calibrating {                                 // setup reps: to the setup flow only
            liveRepCount = reps.count
            liveLastVelocity = reps.last?.meanVelocity
            onCalibReps?(reps)
            return
        }
        let velocities = reps.map { $0.meanVelocity }
        let count = velocities.count
        // First counted rep (not just movement — unracking or walking doesn't count).
        if count >= 1 && !announcedStart {
            announcedStart = true
            onSetStarted?()
        }
        liveRepCount = count
        liveLastVelocity = velocities.last
        if count >= 1 { onLiveReps?(reps) }
        if buzz { slowRepBuzz() }
    }

    /// The slow-rep buzz, in the pattern chosen on the phone.
    private func slowRepBuzz() {
        let device = WKInterfaceDevice.current()
        switch haptics.slowRepPattern {
        case 1:
            device.play(.directionDown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { device.play(.directionDown) }
        case 2:
            device.play(.notification)
        default:
            device.play(.directionDown)
        }
    }

    /// Pause done: the clear "drive up" buzz, at the strength chosen on the phone (setup: at least medium).
    private func pauseTap() {
        WatchBuzz.pauseDone(strength: calibrating ? max(1, haptics.pauseStrength) : haptics.pauseStrength)
    }

    /// While you hold: gentle taps that come faster and firmer as the pause fills, so you can feel
    /// how far along you are. Always in setup; in workouts when "Build-up taps" is on (phone setting).
    private var buildTask: Task<Void, Never>?
    private func startBuildUp(from start: Date) {
        buildTask?.cancel()
        guard pauseTarget > 0, calibrating || haptics.pauseTicks else { return }
        let target = pauseTarget
        buildTask = Task { @MainActor in
            while !Task.isCancelled {
                let f = Date().timeIntervalSince(start) / target
                guard f < 0.97, self.pauseStart == start, !self.pauseReached else { return }
                WatchBuzz.pauseBuild(f)
                try? await Task.sleep(nanoseconds: UInt64(WatchBuzz.pauseGap(f) * 1_000_000_000))
            }
        }
    }
    private func stopBuildUp() { buildTask?.cancel(); buildTask = nil }

    /// Which way this exercise's reps go first (see RepAnalyzer.Order).
    func setRepOrder(_ o: RepAnalyzer.Order) { processor.setOrder(o) }

    /// The exercise you're on asks for this bottom pause (nil or 0 = off).
    func setPauseTarget(_ seconds: Double?) {
        let s = max(0, seconds ?? 0)
        guard s != pauseTarget else { return }
        pauseTarget = s
        processor.setPauseTarget(s)
    }

    private func applyPause(bottomAt: TimeInterval?, reached: Bool) {
        // Only when a rep is expected: setup, a set you've started, or once the Watch has counted a rep.
        // (liveRepCount is 0, not nil, as soon as any movement starts — a wave or a gesture — so 0 doesn't count.)
        guard let bottomAt, calibrating || setActive || (liveRepCount ?? 0) >= 1 else {
            stopBuildUp(); pauseStart = nil; pauseReached = false; return
        }
        let start = Date(timeIntervalSince1970: bottomAt)
        let isNew = pauseStart != start
        pauseStart = start
        pauseReached = reached
        if reached { stopBuildUp(); pauseTap() }                    // the tap: drive up
        else if isNew { startBuildUp(from: start) }
    }

    private func applySetEnded(reps: [RepMotion], start: Date, end: Date) {
        announcedStart = false
        stopBuildUp()
        pauseStart = nil; pauseReached = false
        liveRepCount = nil
        liveLastVelocity = nil
        if calibrating {
            if calibEndPending { calibrating = false; calibEndPending = false }
            else { onCalibEnded?(reps, start, end) }
            return
        }
        if let until = ignoreSetsUntil, Date() < until { return }   // the tail of setup motion
        if !reps.isEmpty { onSetDetected?(reps, start, end) }
    }

    func start() {
        guard !isRecording else { return }
        guard processor.start(buzzEnabled: MotionSettings.buzzEnabled,
                              buzzThresholdPct: MotionSettings.buzzThresholdPct) else { return }
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        processor.stop()      // flushes a set that was still open
        isRecording = false
    }
}

// MARK: - Sample processing (background queue)

nonisolated final class MotionProcessor: @unchecked Sendable {
    // Callbacks fire on the processing queue.
    var onLive: (@Sendable (_ reps: [RepMotion], _ buzz: Bool) -> Void)?
    /// Pause buzz: bottomAt = when you settled at the bottom (nil = you've left it); reached = target hit.
    var onPause: (@Sendable (_ bottomAt: TimeInterval?, _ reached: Bool) -> Void)?
    var onSetEnded: (@Sendable (_ reps: [RepMotion], _ start: Date, _ end: Date) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "bst.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    // Everything below is touched only on `queue`.
    private let G = 9.80665
    private var buffer: [MotionSample] = []
    private var bootOffset: TimeInterval = 0
    private var smoothA = 0.0
    private var smoothR = 0.0
    private var inSet = false
    private var setStartIndex = 0
    private var lastActiveIndex = 0
    private var lastLiveAnalysis: TimeInterval = 0
    private var liveReps = 0
    private var buzzed = false
    private var buzzEnabled = true
    private var buzzThreshold = 20.0

    // Pause buzz: a light, per-sample bottom detector (the rep analyser runs only twice a
    // second, too coarse to tap at exactly 2 s). Velocity is integrated and zeroed whenever the
    // Watch is truly still; a real descent (15 cm+, faster than 0.3 m/s) followed by a quarter
    // second of barely moving is the bottom; moving up again ends it. (Rewritten Oct 6 against the
    // camera: the old one fired at the top of every squat and missed a real 1.8 s hold.)
    private var pauseTarget = 0.0
    private var vel = 0.0
    private var lastT: TimeInterval = 0
    private var pA = 0.0                  // vertical acceleration, lightly smoothed
    private var pQuiet = 0.0              // seconds truly still
    private var pSeg = 0.0                // height change since the last still moment (m)
    private var pVmin = 0.0               // fastest descent in it (m/s, negative)
    private var pSlow = 0.0               // seconds barely moving after a descent
    private var pDescended = false
    private var bottomAt: TimeInterval? = nil
    private var pauseReached = false

    /// Which way reps go first, for the analyser (set from the exercise or the setup step).
    private var order: RepAnalyzer.Order = .either
    func setOrder(_ o: RepAnalyzer.Order) { queue.addOperation { [self] in self.order = o } }
    /// What was last handed to the live callback, so a rep's numbers still settling get sent again.
    private var liveSignature = ""

    // "Hold still" probe: vertical acceleration and rotation while it runs (touched only on `queue`).
    private var probe: [(av: Double, rot: Double, nz: Double)]? = nil

    func beginStillProbe() { queue.addOperation { [self] in self.probe = [] } }

    // Waiting for the starting position (touched only on `queue`).
    private var armWait: (needed: Double, since: TimeInterval?, deadline: TimeInterval, done: @Sendable (Bool) -> Void)?

    func waitForStillness(needed: Double, timeout: Double, _ done: @escaping @Sendable (Bool) -> Void) {
        queue.addOperation { [self] in
            let now = ProcessInfo.processInfo.systemUptime + self.bootOffset
            self.armWait = (needed, nil, now + timeout, done)
        }
    }
    func cancelStillnessWait() { queue.addOperation { [self] in self.armWait = nil } }

    // Motion capture (debug tool): every sample from Go until hand-over (touched only on `queue`).
    private var capture: [MotionSample]? = nil
    private let captureLimit = 12000                      // 2 min at 100 Hz (a live session drains it every 15 s)

    func beginCapture() { queue.addOperation { [self] in self.capture = [] } }
    func drainCapture(_ done: @escaping @Sendable ([MotionSample]) -> Void) {
        queue.addOperation { [self] in
            let c = self.capture ?? []
            if self.capture != nil { self.capture = [] }
            done(c)
        }
    }
    func endCapture(_ done: @escaping @Sendable ([MotionSample]) -> Void) {
        queue.addOperation { [self] in
            let c = self.capture ?? []
            self.capture = nil
            done(c)
        }
    }

    /// The steady part of the hold: shake = spread of vertical acceleration (m/s², the largest 5% of
    /// deviations ignored, so one stray bump doesn't fail it); rot = median rotation (rad/s).
    /// Also the sample count — 0 means the Watch wasn't measuring at all.
    func endStillProbe(_ done: @escaping @Sendable (GripReading) -> Void) {
        queue.addOperation { [self] in
            let p = self.probe ?? []
            self.probe = nil
            guard p.count >= 30 else {
                done(GripReading(shake: 0, rot: 0, count: p.count, tiltDeg: 0, restZero: 0)); return
            }
            let avs = p.map { $0.av }.sorted()
            let median = avs[avs.count / 2]
            let dev = avs.map { abs($0 - median) }.sorted()
            let kept = dev.prefix(max(1, Int(Double(dev.count) * 0.95)))
            let shake = (kept.reduce(0) { $0 + $1 * $1 } / Double(kept.count)).squareRoot()
            let rots = p.map { $0.rot }.sorted()
            let nzs = p.map { $0.nz }.sorted()
            let tilt = acos(min(1, abs(nzs[nzs.count / 2]))) * 180 / .pi      // face tipped from level
            done(GripReading(shake: shake, rot: rots[rots.count / 2], count: p.count, tiltDeg: tilt, restZero: median))
        }
    }

    func setPauseTarget(_ s: Double) {
        queue.addOperation { [self] in
            self.pauseTarget = s
            if s <= 0, self.bottomAt != nil { self.bottomAt = nil; self.onPause?(nil, false) }
        }
    }

    // Tuning
    private let activeAccel = 0.30        // m/s², smoothed |vertical accel|
    private let activeRot = 0.60          // rad/s, smoothed rotation
    private let quietToEnd = 7.0          // seconds of stillness that end a set
    private let preroll = 1.0             // seconds kept before the first motion
    private let maxSet = 180.0            // seconds — force-close a set this long

    func start(buzzEnabled: Bool, buzzThresholdPct: Double) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        manager.deviceMotionUpdateInterval = 1.0 / RepAnalyzer.sampleRate
        queue.addOperation { [self] in
            self.buffer.removeAll(keepingCapacity: true)
            self.inSet = false
            self.smoothA = 0; self.smoothR = 0
            self.buzzEnabled = buzzEnabled
            self.buzzThreshold = buzzThresholdPct
            self.bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.ingest(motion)
        }
        return true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        queue.addOperation { [self] in
            if self.inSet { self.finishSet() }
            self.buffer.removeAll()
        }
    }

    // MARK: Per sample

    private func ingest(_ m: CMDeviceMotion) {
        // Gravity direction in the watch's own frame → vertical / horizontal split.
        let gx = m.gravity.x, gy = m.gravity.y, gz = m.gravity.z
        let gl = (gx * gx + gy * gy + gz * gz).squareRoot()
        guard gl > 0.1 else { return }
        let nx = gx / gl, ny = gy / gl, nz = gz / gl
        // CoreMotion reports userAcceleration with the opposite sign to the real movement (the same
        // convention as its raw accelerometer: lifting the Watch reads as acceleration toward the
        // ground). Flipped here so everything below is the true acceleration. Confirmed against the
        // camera on Oct 6: unflipped, every press read as a lowering.
        let ux = -m.userAcceleration.x, uy = -m.userAcceleration.y, uz = -m.userAcceleration.z
        let along = ux * nx + uy * ny + uz * nz          // along gravity (down)
        let av = -along * G                              // up positive

        // Horizontal axes: project the watch's x (or y) axis onto the horizontal plane.
        var e1x = 1 - nx * nx, e1y = -nx * ny, e1z = -nx * nz
        var e1l = (e1x * e1x + e1y * e1y + e1z * e1z).squareRoot()
        if e1l < 0.3 {
            e1x = -ny * nx; e1y = 1 - ny * ny; e1z = -ny * nz
            e1l = (e1x * e1x + e1y * e1y + e1z * e1z).squareRoot()
        }
        e1x /= e1l; e1y /= e1l; e1z /= e1l
        let e2x = ny * e1z - nz * e1y, e2y = nz * e1x - nx * e1z, e2z = nx * e1y - ny * e1x
        let h1 = (ux * e1x + uy * e1y + uz * e1z) * G
        let h2 = (ux * e2x + uy * e2y + uz * e2z) * G

        let rr = m.rotationRate
        let rot = (rr.x * rr.x + rr.y * rr.y + rr.z * rr.z).squareRoot()
        let t = m.timestamp + bootOffset
        if probe != nil { probe?.append((av: av, rot: rot, nz: nz)) }
        let sample = MotionSample(t: t, av: av, h1: h1, h2: h2, rot: rot)
        buffer.append(sample)
        if capture != nil, capture!.count < captureLimit { capture!.append(sample) }

        // Activity (≈0.3 s smoothing).
        let alpha = 0.032
        smoothA += alpha * (abs(av) - smoothA)
        smoothR += alpha * (rot - smoothR)
        let active = smoothA > activeAccel || smoothR > activeRot
        let idx = buffer.count - 1

        if let a = armWait {                                 // settled into the starting position?
            if smoothA < 0.22 && smoothR < 0.5 {
                let since = a.since ?? t
                armWait?.since = since
                if t - since >= a.needed { armWait = nil; a.done(true) }
            } else {
                armWait?.since = nil
            }
            if armWait != nil, t >= a.deadline { armWait = nil; a.done(false) }
        }

        if !inSet {
            if active {
                inSet = true
                setStartIndex = max(0, idx - Int(preroll * RepAnalyzer.sampleRate))
                lastActiveIndex = idx
                liveReps = 0
                buzzed = false
                lastLiveAnalysis = t
                vel = 0; lastT = t; bottomAt = nil; pauseReached = false
                pA = 0; pQuiet = 0; pSeg = 0; pVmin = 0; pSlow = 0; pDescended = false
                liveSignature = ""
            } else if buffer.count > 600 {
                // Idle: keep just a couple of seconds for the preroll.
                buffer.removeFirst(buffer.count - 300)
            }
            return
        }

        if active { lastActiveIndex = idx }
        pauseStep(av: av, rot: rot, t: t)
        let quietFor = t - buffer[lastActiveIndex].t
        let setLength = t - buffer[setStartIndex].t

        if quietFor >= quietToEnd || setLength >= maxSet {
            finishSet()
            return
        }

        if t - lastLiveAnalysis >= 0.5 {
            lastLiveAnalysis = t
            liveAnalysis()
        }
    }

    /// Runs on every sample during a set.
    private func pauseStep(av: Double, rot: Double, t: TimeInterval) {
        let dt = lastT > 0 ? min(0.05, max(0, t - lastT)) : 1.0 / RepAnalyzer.sampleRate
        lastT = t
        pA += (1 - pow(0.75, dt * 25)) * (av - pA)
        pQuiet = (abs(pA) < 0.35 && rot < 1.0) ? pQuiet + dt : 0
        vel += pA * dt
        if pQuiet >= 0.2 { vel = 0 }                  // truly still: no speed, whatever the sums say
        pSeg += vel * dt
        guard pauseTarget > 0 else { return }
        if let b = bottomAt {
            if vel > 0.15 {                           // driving up: the pause is over
                bottomAt = nil
                pDescended = false; pSeg = 0; pVmin = 0; pSlow = 0
                onPause?(nil, false)
            } else if !pauseReached, t - b >= pauseTarget {
                pauseReached = true
                onPause?(b, true)
            }
        } else {
            if pQuiet >= 0.2 && !pDescended { pSeg = 0; pVmin = 0 }   // standing still: re-zero
            pVmin = min(pVmin, vel)
            if vel > 0.15 { pDescended = false; pSeg = 0; pVmin = 0 }  // going up: not heading for a bottom
            if pSeg <= -0.15 && pVmin <= -0.3 { pDescended = true }
            pSlow = (pDescended && abs(vel) < 0.10) ? pSlow + dt : 0
            if pSlow >= 0.25 {
                let at = t - 0.25                     // settled a quarter second ago
                bottomAt = at
                pauseReached = false
                pSlow = 0
                onPause?(at, false)
            }
        }
    }

    private func liveAnalysis() {
        let slice = Array(buffer[setStartIndex...])
        let reps = RepAnalyzer.analyze(slice, order: order)
        // Send again whenever the count OR the last rep's numbers change: a rep is counted as soon as
        // it's clear, but its travel and pauses keep settling for a moment after (only sending on a new
        // count left the setup's last squat at 15 cm instead of 62).
        let sig = reps.last.map { String(format: "%d|%.2f|%.2f|%.2f|%.2f", reps.count, $0.end.timeIntervalSince1970,
                                         $0.travelM, $0.bottomPauseSec ?? -1, $0.topPauseSec ?? -1) } ?? "0"
        guard sig != liveSignature else { return }
        liveSignature = sig
        let countChanged = reps.count != liveReps
        liveReps = reps.count
        var buzz = false
        if countChanged, buzzEnabled, !buzzed, reps.count >= 3 {
            let best = max(reps[0].meanVelocity, reps[1].meanVelocity)
            if let last = reps.last?.meanVelocity, best > 0,
               (best - last) / best * 100 >= buzzThreshold {
                buzz = true
                buzzed = true
            }
        }
        onLive?(reps, buzz)
    }

    private func finishSet() {
        inSet = false
        if bottomAt != nil { bottomAt = nil; onPause?(nil, false) }
        let endIdx = min(buffer.count, lastActiveIndex + Int(1.5 * RepAnalyzer.sampleRate))
        guard endIdx > setStartIndex else { return }
        let slice = Array(buffer[setStartIndex..<endIdx])
        let reps = RepAnalyzer.analyze(slice, order: order)
        let start = reps.first?.start ?? Date(timeIntervalSince1970: slice.first?.t ?? 0)
        let end = reps.last?.end ?? Date(timeIntervalSince1970: slice.last?.t ?? 0)
        // Keep the tail so a quick next set still has its preroll.
        let keep = Int(preroll * RepAnalyzer.sampleRate) * 2
        if buffer.count > keep { buffer.removeFirst(buffer.count - keep) }
        smoothA = 0; smoothR = 0
        liveReps = 0
        onSetEnded?(reps, start, end)
    }
}

// MARK: - Pause countdown (over every screen while you're held at the bottom)

struct PauseCountdownOverlay: View {
    @ObservedObject private var motion = MotionRecorder.shared
    private let volt = Color(red: 237 / 255, green: 1, blue: 61 / 255)

    var body: some View {
        if let start = motion.pauseStart, motion.pauseTarget > 0 {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let target = motion.pauseTarget
                let held = max(0, ctx.date.timeIntervalSince(start))
                let done = motion.pauseReached || held >= target
                ZStack {
                    Color.black.opacity(0.9).ignoresSafeArea()
                    if done {
                        Circle().fill(volt).padding(14)
                        VStack(spacing: 0) {
                            Text("GO").font(.system(size: 46, weight: .black)).foregroundColor(.black)
                            Text(String(format: "%.1f s ✓", target)).font(.system(size: 12, weight: .heavy)).foregroundColor(.black)
                        }
                    } else {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 10).padding(14)
                        Circle().trim(from: 0, to: min(1, held / target))
                            .stroke(volt, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(14)
                        VStack(spacing: 0) {
                            Text("PAUSE").font(.system(size: 11, weight: .heavy)).foregroundColor(.gray)
                            Text(String(format: "%.1f", held)).font(.system(size: 44, weight: .black)).foregroundColor(.white).monospacedDigit()
                            Text(String(format: "of %.1f s", target)).font(.system(size: 11, weight: .semibold)).foregroundColor(.gray)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}


// MARK: - The wrist's vocabulary
// One pattern per meaning, so each can be told apart without looking:
//   countdown   tick-tick each second (a quick triple on the last one) — get set
//   go          one firm tap — measuring from now
//   rep         a rising double tap — a rep was counted (setup screens; ready for workouts)
//   pause       taps that start gentle and slow, then come faster and firmer as the hold fills…
//   pause done  …then a strong buzz and a rising flourish — drive up
// (Apple Watch haptics come in fixed types, so "stronger" means firmer types, closer together.)

@MainActor
enum WatchBuzz {
    private static func play(_ t: WKHapticType, after s: Double = 0) {
        if s <= 0 { WKInterfaceDevice.current().play(t); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { WKInterfaceDevice.current().play(t) }
    }

    /// A plain acknowledgement (the Go tap).
    static func tap() { play(.click) }

    /// Countdown: `left` seconds still to go.
    static func countdown(_ left: Int) {
        play(.click); play(.click, after: 0.14)
        if left <= 1 { play(.click, after: 0.28) }
    }

    /// Measuring starts now.
    static func go() { play(.start) }

    /// A rep was counted.
    static func rep() { play(.directionUp) }

    /// One tap of the pause build-up; `f` = how far through the hold (0…1).
    static func pauseBuild(_ f: Double) { play(f < 0.7 ? .click : .start) }
    /// Seconds until the next build-up tap: 0.6 s at first, down to about 0.2 s near the end.
    static func pauseGap(_ f: Double) -> Double { max(0.2, 0.6 - 0.45 * min(1, max(0, f))) }

    /// The pause is complete. 0 light · 1 medium · 2 strong (the phone's setting).
    static func pauseDone(strength: Int) {
        switch strength {
        case 0: play(.success)
        case 2: play(.notification); play(.notification, after: 0.3); play(.success, after: 0.6)
        default: play(.notification); play(.success, after: 0.3)
        }
    }
}
