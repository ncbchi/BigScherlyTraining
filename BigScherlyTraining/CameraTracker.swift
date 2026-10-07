import Foundation

// MARK: - Camera tracking (DEBUG TOOL — removed before release; the analysis may carry into the
// optional production feature)
// The phone's camera follows one joint (the Watch wrist, or the hips on squats) while the Watch
// records its own motion. Vision body pose gives the joint's height in each frame; a known body
// height turns it into centimetres. This file is the data and the maths: counting reps from the
// camera, lining the two clocks up, and pairing camera reps with the Watch's.
//
// Target membership: BigScherlyTraining.

nonisolated struct CameraTrack: Codable, Sendable {
    var joint: String          // "wrist" · "hip" · "plate" (the bar end, followed by its plate)
    var side: String           // which wrist
    var work: String           // "high": a rep is an arrival at the top (press, bench, deadlift) · "low": at the bottom (squats)
    var cmPerUnit: Double      // centimetres per unit of Vision's height (0…1 of the frame)
    var scaleKnown: Bool       // false = no one was measured standing; a typical scale was assumed
    var t: [Double]            // seconds since 1970 (the same clock the Watch stamps its samples with)
    var y: [Double]            // joint height, Vision units (up positive)
    var c: [Double]            // confidence 0…1
    var k: [Double]? = nil     // hip tracks: knee height alongside (Vision units, -1 = not seen)
    var ruler: String? = nil   // what set the scale: "plate 45.0 cm", "height 178 cm", "assumed"
    var isEmpty: Bool { t.count < 8 }
}

nonisolated struct CamRep: Sendable {
    var n: Int
    var start: Double          // seconds since 1970, clock-corrected when it comes from `compare`
    var peak: Double           // the top (press) or the bottom (squat)
    var end: Double
    var travelCm: Double
    var meanV: Double          // m/s on the way up
    var peakV: Double          // m/s
}

nonisolated struct CameraComparison: Sendable {
    var lagSec: Double                    // camera clock minus Watch clock (already removed from the times below)
    var syncR: Double                     // how well the two motions line up, −1…1
    var camReps: [CamRep]
    var camSeries: [(t: Double, cm: Double)]
    var watchSeries: [(t: Double, cm: Double)]
    var pairs: [(cam: CamRep?, watch: RepMotion?)]
    var travelErrCm: Double?              // Watch minus camera, mean over paired reps
    var peakErr: Double?                  // m/s, same
}

nonisolated enum CameraAnalysis {
    static let fs = 20.0

    // MARK: Series

    /// The track on an even 20 Hz grid, smoothed over 0.25 s, in centimetres (not zeroed).
    static func resample(_ track: CameraTrack) -> (t0: Double, cm: [Double]) {
        guard track.t.count >= 2, let t0 = track.t.first, let tEnd = track.t.last, tEnd > t0 else { return (0, []) }
        let scale = track.cmPerUnit > 0 ? track.cmPerUnit : 200
        let n = Int((tEnd - t0) * fs) + 1
        var out = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) / fs
            while j + 1 < track.t.count - 1 && track.t[j + 1] < t { j += 1 }
            let a = track.t[j], b = track.t[min(j + 1, track.t.count - 1)]
            let f = b > a ? min(1, max(0, (t - a) / (b - a))) : 0
            out[i] = (track.y[j] + (track.y[min(j + 1, track.y.count - 1)] - track.y[j]) * f) * scale
        }
        // moving average, 5 samples
        var sm = out
        for i in 0..<n {
            let lo = max(0, i - 2), hi = min(n - 1, i + 2)
            sm[i] = out[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        return (t0, sm)
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
    }

    // MARK: Counting reps from the camera

    /// A rep is an arrival in the work zone (top for press/bench/deadlift, bottom for squats) after
    /// leaving the other zone — hysteresis at 30% / 70% of the 5–95% range. Under 8 cm of range = no reps.
    static func reps(_ track: CameraTrack) -> [CamRep] {
        let (t0, p) = resample(track)
        guard p.count > 20 else { return [] }
        let lo = percentile(p, 0.05), hi = percentile(p, 0.95)
        let range = hi - lo
        guard range >= 8 else { return [] }
        let hiZ = lo + 0.7 * range, loZ = lo + 0.3 * range
        let workHigh = track.work != "low"

        func time(_ i: Int) -> Double { t0 + Double(i) / fs }
        func make(_ n: Int, start: Int, peak: Int, end: Int, riseFrom: Int, riseTo: Int, travel: Double) -> CamRep {
            let dur = max(0.1, Double(riseTo - riseFrom) / fs)
            var pk = 0.0
            if riseTo > riseFrom { for j in riseFrom..<riseTo { pk = max(pk, (p[j + 1] - p[j]) * fs / 100) } }
            return CamRep(n: n, start: time(start), peak: time(peak), end: time(end),
                          travelCm: travel, meanV: travel / 100 / dur, peakV: pk)
        }

        var out: [CamRep] = []
        var zone = 0
        var lowMin = (idx: 0, v: Double.infinity)
        var highMax = (idx: 0, v: -Double.infinity)
        var prevHigh = -1
        var riseFrom = 0
        var openHigh = false
        for i in 0..<p.count {
            let v = p[i]
            let z = v >= hiZ ? 2 : (v <= loZ ? 1 : zone)
            if z == 2, v > highMax.v { highMax = (i, v) }
            if z == 1, v < lowMin.v { lowMin = (i, v) }
            if z != zone {
                if zone == 0 {
                    if z == 2, workHigh { openHigh = true; riseFrom = lowMin.v.isFinite ? lowMin.idx : 0 }
                } else if zone == 1 && z == 2 {                      // rose from the bottom to the top
                    if !workHigh {                                    // squat: bottom → top is one rep
                        let s = prevHigh >= 0 ? prevHigh : 0
                        out.append(make(out.count + 1, start: s, peak: lowMin.idx, end: i, riseFrom: lowMin.idx, riseTo: i,
                                        travel: max(0, p[s] - p[lowMin.idx])))
                    } else { openHigh = true; riseFrom = lowMin.idx }
                    highMax = (i, v)
                } else if zone == 2 && z == 1 {                       // fell from the top to the bottom
                    if workHigh, openHigh {
                        out.append(make(out.count + 1, start: riseFrom, peak: highMax.idx, end: i, riseFrom: riseFrom, riseTo: highMax.idx,
                                        travel: max(0, p[highMax.idx] - p[riseFrom])))
                        openHigh = false
                    }
                    prevHigh = highMax.idx
                    lowMin = (i, v)
                }
            }
            zone = z
        }
        if workHigh, openHigh, highMax.idx > riseFrom {
            out.append(make(out.count + 1, start: riseFrom, peak: highMax.idx, end: p.count - 1, riseFrom: riseFrom, riseTo: highMax.idx,
                            travel: max(0, p[highMax.idx] - p[riseFrom])))
        }
        return out
    }

    // MARK: The Watch's motion as a height series

    /// Vertical acceleration integrated twice with leaks (so drift can't run away): velocity (m/s)
    /// and height (cm), at the capture's 50 Hz, stamped like the camera (seconds since 1970).
    static func watchSeries(_ cap: MotionCapture) -> (t: [Double], v: [Double], y: [Double]) {
        let n = cap.count
        guard n > 10, cap.hz > 0 else { return ([], [], []) }
        let dt = 1 / cap.hz
        let kv = exp(-dt / 1.5), ky = exp(-dt / 3.0)
        var t = [Double](), v = [Double](), y = [Double]()
        var vel = 0.0, pos = 0.0
        let sign: Double = cap.analyzer < 2 ? -1 : 1      // captures from before the sign fix: upside down
        for i in 0..<n {
            let av = sign * Double(cap.raw(0, i)) / 1000
            vel = (vel + av * dt) * kv
            pos = (pos + vel * dt) * ky
            t.append(cap.startT + Double(i) * dt + dt / 2)
            v.append(vel); y.append(pos * 100)
        }
        return (t, v, y)
    }

    // MARK: Lining up and comparing

    static func compare(_ cap: MotionCapture) -> CameraComparison? {
        guard let track = cap.camera, !track.isEmpty else { return nil }
        let (t0, p) = resample(track)
        guard p.count > 20 else { return nil }
        let w = watchSeries(cap)
        guard w.t.count > 20 else { return nil }

        // Camera vertical velocity (m/s) on its 20 Hz grid.
        var vc = [Double](repeating: 0, count: p.count)
        for i in 1..<p.count { vc[i] = (p[i] - p[i - 1]) * fs / 100 }
        // The Watch's velocity on the same grid.
        func watchV(at t: Double) -> Double? {
            let k = Int(((t - cap.startT) * cap.hz).rounded())
            return k >= 0 && k < w.v.count ? w.v[k] : nil
        }
        // Best lag: camera event at (t + lag) matches the Watch's at t.
        var bestLag = 0.0, bestR = -1.0
        var lag = -1.5
        while lag <= 1.5 {
            var xs = [Double](), ys = [Double]()
            for i in 0..<p.count {
                let tc = t0 + Double(i) / fs
                if let a = watchV(at: tc - lag) { xs.append(a); ys.append(vc[i]) }
            }
            if xs.count > 40 {
                let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
                var sxy = 0.0, sxx = 0.0, syy = 0.0
                for k in 0..<xs.count { sxy += (xs[k] - mx) * (ys[k] - my); sxx += (xs[k] - mx) * (xs[k] - mx); syy += (ys[k] - my) * (ys[k] - my) }
                let r = sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
                if r > bestR { bestR = r; bestLag = lag }
            }
            lag += 0.05
        }
        if bestR < 0.25 { bestLag = 0 }                  // no clear match: leave the clocks as they are

        var shifted = track
        shifted.t = track.t.map { $0 - bestLag }
        let reps = Self.reps(shifted)

        let base = percentile(p, 0.05)
        let camSeries = (0..<p.count).map { (t: t0 + Double($0) / fs - bestLag, cm: p[$0] - base) }
        let wBase = percentile(w.y, 0.05)
        let wSeries = (0..<w.t.count).map { (t: w.t[$0], cm: w.y[$0] - wBase) }

        // Pair each Watch rep with the camera rep whose window is nearest in time.
        var pairs: [(cam: CamRep?, watch: RepMotion?)] = []
        var used = Set<Int>()
        for r in cap.reps {
            let mid = (r.start.timeIntervalSince1970 + r.end.timeIntervalSince1970) / 2
            var best: (i: Int, d: Double)?
            for (i, c) in reps.enumerated() where !used.contains(i) {
                let d = abs((c.start + c.end) / 2 - mid)
                if d < 2.0, best == nil || d < best!.d { best = (i, d) }
            }
            if let b = best { used.insert(b.i); pairs.append((reps[b.i], r)) } else { pairs.append((nil, r)) }
        }
        for (i, c) in reps.enumerated() where !used.contains(i) { pairs.append((c, nil)) }
        pairs.sort { ($0.cam?.start ?? $0.watch!.start.timeIntervalSince1970) < ($1.cam?.start ?? $1.watch!.start.timeIntervalSince1970) }

        let both = pairs.compactMap { pr -> (CamRep, RepMotion)? in
            if let c = pr.cam, let w = pr.watch { return (c, w) } else { return nil }
        }
        let travelErr = both.isEmpty ? nil : both.map { $0.1.travelM * 100 - $0.0.travelCm }.reduce(0, +) / Double(both.count)
        let peakErr = both.isEmpty ? nil : both.map { $0.1.peakVelocity - $0.0.peakV }.reduce(0, +) / Double(both.count)
        return CameraComparison(lagSec: bestLag, syncR: bestR, camReps: reps, camSeries: camSeries,
                                watchSeries: wSeries, pairs: pairs, travelErrCm: travelErr, peakErr: peakErr)
    }
}
