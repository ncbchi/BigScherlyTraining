import Foundation

// MARK: - Watch motion data (shared by the iPhone app and the Watch app)
// One SetMotion per logged set, holding one RepMotion per rep ("lift").
// Recorded and analysed on the wrist; the phone stores it and shows it in Stats.
// Units are metric internally (meters, m/s, seconds) — convert only for display.
//
// Target membership: BOTH BigScherlyTraining and BigScherlyWatch Watch App.

nonisolated enum PauseStyle: String, Codable, Sendable {
    case none        // no descent before this rep (e.g. first rep of a deadlift)
    case touchAndGo  // under 0.15 s at the bottom
    case brief       // 0.15–0.5 s
    case paused      // 0.5 s or longer — a true paused rep
}

nonisolated struct RepMotion: Codable, Sendable, Identifiable, Equatable {
    var index: Int                 // 1-based within the set
    var start: Date                // start of the descent (or of the lift if none)
    var end: Date                  // lockout
    var eccentricSec: Double?      // lowering time
    var bottomPauseSec: Double?    // motionless time at the bottom
    var concentricSec: Double      // lifting time
    var topPauseSec: Double?       // time at lockout before the next descent
    var travelM: Double            // vertical bar travel on the way up
    var meanVelocity: Double       // m/s, average on the way up
    var peakVelocity: Double       // m/s, fastest point on the way up
    var stickingPoint: Double?     // 0–1: how far up the slowest point was (nil if no clear dip)
    var driftM: Double             // horizontal wander on the way up — EXPERIMENTAL, low confidence

    var id: Int { index }

    var pauseStyle: PauseStyle {
        guard let p = bottomPauseSec else { return .none }
        if p < 0.15 { return .touchAndGo }
        if p < 0.5 { return .brief }
        return .paused
    }

    /// A near-limit rep: very slow on the way up.
    var isGrind: Bool { meanVelocity < 0.20 || concentricSec >= 2.5 }
}

nonisolated struct SetMotion: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var workoutId: String
    var exerciseId: String
    var setId: String
    var exerciseName: String
    var start: Date
    var end: Date
    var reps: [RepMotion]
    var autoDetected: Bool
    var analyzerVersion: Int

    var repCount: Int { reps.count }

    /// Total time the bar was under control: lowering + bottom pause + lifting.
    var timeUnderTensionSec: Double {
        reps.reduce(0) { $0 + ($1.eccentricSec ?? 0) + ($1.bottomPauseSec ?? 0) + $1.concentricSec }
    }
    var averageTravelM: Double { mean(reps.map { $0.travelM }) ?? 0 }

    /// How consistent depth was, rep to rep (100 = identical). Coefficient-of-variation based.
    var travelConsistencyPct: Double? {
        let t = reps.map { $0.travelM }
        guard t.count >= 2, let m = mean(t), m > 0 else { return nil }
        let sd = (t.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(t.count)).squareRoot()
        return max(0, 100 * (1 - sd / m))
    }
    var meanVelocity: Double { mean(reps.map { $0.meanVelocity }) ?? 0 }
    var bestVelocity: Double { reps.map { $0.meanVelocity }.max() ?? 0 }
    var peakVelocity: Double { reps.map { $0.peakVelocity }.max() ?? 0 }

    /// Speed lost from the faster of the first two reps to the last rep, in %.
    var velocityLossPct: Double? {
        guard reps.count >= 2 else { return nil }
        let best = max(reps[0].meanVelocity, reps.count > 1 ? reps[1].meanVelocity : 0)
        guard best > 0, let last = reps.last?.meanVelocity else { return nil }
        return max(0, (best - last) / best * 100)
    }
    var averageBottomPauseSec: Double? { mean(reps.compactMap { $0.bottomPauseSec }) }
    var averageEccentricSec: Double? { mean(reps.compactMap { $0.eccentricSec }) }
    var averageConcentricSec: Double? { mean(reps.map { $0.concentricSec }) }
    var pausedRepCount: Int { reps.filter { $0.pauseStyle == .paused }.count }
    var touchAndGoRepCount: Int { reps.filter { $0.pauseStyle == .touchAndGo }.count }
    var grindRepCount: Int { reps.filter { $0.isGrind }.count }
    var averageStickingPoint: Double? { mean(reps.compactMap { $0.stickingPoint }) }
    var averageDriftM: Double? { mean(reps.map { $0.driftM }) }

    private func mean(_ x: [Double]) -> Double? {
        x.isEmpty ? nil : x.reduce(0, +) / Double(x.count)
    }
}
