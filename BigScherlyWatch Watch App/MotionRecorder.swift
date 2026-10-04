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
    /// Every rep so far in the set in progress (speed, lowering, pause, lifting, travel) —
    /// sent on to the phone's live card as each one is counted.
    var onLiveReps: (([RepMotion]) -> Void)?

    /// Called on the main actor when a finished set has at least one rep.
    var onSetDetected: ((_ reps: [RepMotion], _ start: Date, _ end: Date) -> Void)?
    /// v1.1: the first rep of a set was counted — the phone's Live Activity switches to "lifting".
    var onSetStarted: (() -> Void)?
    private var announcedStart = false

    private let processor = MotionProcessor()

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
        if buzz { WKInterfaceDevice.current().play(.directionDown) }
    }

    /// The exercise you're on asks for this bottom pause (nil or 0 = off).
    func setPauseTarget(_ seconds: Double?) {
        let s = max(0, seconds ?? 0)
        guard s != pauseTarget else { return }
        pauseTarget = s
        processor.setPauseTarget(s)
    }

    private func applyPause(bottomAt: TimeInterval?, reached: Bool) {
        guard let bottomAt else { pauseStart = nil; pauseReached = false; return }
        pauseStart = Date(timeIntervalSince1970: bottomAt)
        pauseReached = reached
        if reached { WKInterfaceDevice.current().play(.success) }     // the tap: drive up
    }

    private func applySetEnded(reps: [RepMotion], start: Date, end: Date) {
        announcedStart = false
        pauseStart = nil; pauseReached = false
        liveRepCount = nil
        liveLastVelocity = nil
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
    // second, too coarse to tap at exactly 2 s). Leaky-integrated vertical velocity tells
    // descending from settled; stillness after a descent is the bottom.
    private var pauseTarget = 0.0
    private var vel = 0.0
    private var lastT: TimeInterval = 0
    private var descendFor = 0.0
    private var bottomAt: TimeInterval? = nil
    private var pauseReached = false

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
        let ux = m.userAcceleration.x, uy = m.userAcceleration.y, uz = m.userAcceleration.z
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

        buffer.append(MotionSample(t: t, av: av, h1: h1, h2: h2, rot: rot))

        // Activity (≈0.3 s smoothing).
        let alpha = 0.032
        smoothA += alpha * (abs(av) - smoothA)
        smoothR += alpha * (rot - smoothR)
        let active = smoothA > activeAccel || smoothR > activeRot
        let idx = buffer.count - 1

        if !inSet {
            if active {
                inSet = true
                setStartIndex = max(0, idx - Int(preroll * RepAnalyzer.sampleRate))
                lastActiveIndex = idx
                liveReps = 0
                buzzed = false
                lastLiveAnalysis = t
                vel = 0; lastT = t; descendFor = 0; bottomAt = nil; pauseReached = false
            } else if buffer.count > 600 {
                // Idle: keep just a couple of seconds for the preroll.
                buffer.removeFirst(buffer.count - 300)
            }
            return
        }

        if active { lastActiveIndex = idx }
        pauseStep(av: av, t: t)
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
    private func pauseStep(av: Double, t: TimeInterval) {
        let dt = lastT > 0 ? min(0.05, max(0, t - lastT)) : 1.0 / RepAnalyzer.sampleRate
        lastT = t
        vel = (vel + av * dt) * 0.985               // local direction, without long-term drift
        guard pauseTarget > 0 else { return }
        let still = smoothA < 0.22 && smoothR < 0.5
        if let b = bottomAt {
            if vel > 0.10 || smoothA > 0.45 {         // driving up (or moving): the pause is over
                bottomAt = nil; descendFor = 0
                onPause?(nil, false)
            } else if !pauseReached, t - b >= pauseTarget {
                pauseReached = true
                onPause?(b, true)
            }
        } else {
            if vel < -0.12 { descendFor += dt } else if vel > 0.08 { descendFor = 0 }
            if descendFor >= 0.3, still, abs(vel) < 0.08 {
                let at = t - 0.25                     // stillness is spotted about ¼ s after it starts
                bottomAt = at
                pauseReached = false
                descendFor = 0
                onPause?(at, false)
            }
        }
    }

    private func liveAnalysis() {
        let slice = Array(buffer[setStartIndex...])
        let reps = RepAnalyzer.analyze(slice)
        guard reps.count != liveReps else { return }
        liveReps = reps.count
        var buzz = false
        if buzzEnabled, !buzzed, reps.count >= 3 {
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
        let reps = RepAnalyzer.analyze(slice)
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

