import Foundation

// MARK: - Rep analysis
// Turns ~100 Hz wrist motion into per-rep metrics. Pure logic, no device APIs.
//
// How it works:
//  1. Low-pass (5 Hz, zero-phase) the vertical acceleration.
//  2. Find moments the bar is truly still (low accel + low rotation, and the
//     integrated speed says it had actually stopped — so a slow grind isn't
//     mistaken for a stop). Sensor bias is measured during those still moments.
//  3. Integrate to velocity, re-zeroing at every still moment and removing drift
//     linearly in between.
//  4. Upward runs = lifting phases, downward runs = lowering phases. Each rep is
//     one lifting phase, paired with the lowering phase before it (squat/bench)
//     or after it (first rep of a deadlift). A rep must move back the other way,
//     which rejects walking and arm swings.
//
// Verified against synthetic squat, paused squat, competition-pause bench,
// touch-and-go and dead-stop deadlift, grinding and continuous-rep sets, and
// rejected walking. Thresholds may want tuning once real wrist data comes in.

nonisolated struct MotionSample: Sendable {
    var t: TimeInterval   // seconds since 1970
    var av: Double        // vertical acceleration, m/s², up positive, gravity removed
    var h1: Double        // horizontal acceleration, m/s², axis 1
    var h2: Double        // horizontal acceleration, m/s², axis 2
    var rot: Double       // rotation rate magnitude, rad/s
}

nonisolated enum RepAnalyzer {
    static let version = 1
    static let sampleRate = 100.0

    private struct Phase { var s: Int; var e: Int; var disp: Double }

    static func analyze(_ s: [MotionSample], fs: Double = sampleRate) -> [RepMotion] {
        let n = s.count
        guard n > Int(fs) else { return [] }
        let dt = 1 / fs
        func tt(_ i: Int) -> TimeInterval { s[min(max(i, 0), n - 1)].t }

        var a = lowPass(s.map { $0.av }, fc: 5, fs: fs)
        let h1 = lowPass(s.map { $0.h1 }, fc: 5, fs: fs)
        let h2 = lowPass(s.map { $0.h2 }, fc: 5, fs: fs)
        let amag = lowPass(s.map { ($0.av * $0.av + $0.h1 * $0.h1 + $0.h2 * $0.h2).squareRoot() }, fc: 5, fs: fs)
        let r = lowPass(s.map { $0.rot }, fc: 5, fs: fs)

        // 1. Candidate still runs (threshold adapts to this watch's noise floor).
        let floor = amag.sorted()[Int(0.10 * Double(n - 1))]
        let athr = max(0.25, 2.0 * floor)
        let minRun = Int(0.10 * fs)
        var runs: [(Int, Int)] = []
        var i = 0
        while i < n {
            if amag[i] < athr && r[i] < 0.35 {
                var j = i
                while j < n && amag[j] < athr && r[j] < 0.35 { j += 1 }
                if j - i >= minRun { runs.append((i, j)) }
                i = j
            } else {
                i += 1
            }
        }

        // 2. Sensor bias from the still moments.
        var bsum = 0.0, bcnt = 0
        for (rs, re) in runs { for k in rs..<re { bsum += a[k]; bcnt += 1 } }
        let bias = bcnt > 0 ? bsum / Double(bcnt) : 0
        for k in 0..<n { a[k] -= bias }

        // 3. Velocity with zero-velocity updates. A candidate only counts as a stop
        //    if the bar had actually slowed down coming into it.
        var v = [Double](repeating: 0, count: n)
        var still = [Bool](repeating: false, count: n)
        var vint = 0.0, peak = 0.0, segStart = 0, ri = 0
        i = 0
        while i < n {
            if ri < runs.count && i == runs[ri].0 {
                let (rs, re) = runs[ri]
                ri += 1
                if abs(vint) < max(0.07, 0.25 * peak) {
                    let L = rs - segStart
                    if L > 0 {
                        for (m, k) in (segStart..<rs).enumerated() {
                            v[k] -= vint * Double(m + 1) / Double(L)
                        }
                    }
                    for k in rs..<re { v[k] = 0; still[k] = true }
                    vint = 0; peak = 0; segStart = re; i = re
                    continue
                }
            }
            vint += a[i] * dt
            v[i] = vint
            peak = max(peak, abs(vint))
            i += 1
        }
        if segStart < n {
            let L = n - segStart
            for (m, k) in (segStart..<n).enumerated() {
                v[k] -= vint * Double(m + 1) / Double(L)
            }
        }

        // Horizontal velocity, same still moments (for the experimental drift metric).
        func horizontalVelocity(_ h: [Double]) -> [Double] {
            var hs = 0.0, hc = 0
            for k in 0..<n where still[k] { hs += h[k]; hc += 1 }
            let hb = hc > 0 ? hs / Double(hc) : 0
            var out = [Double](repeating: 0, count: n)
            var acc = 0.0, st = 0
            for k in 0...n {
                if k == n || still[k] {
                    let L = k - st
                    if L > 0 {
                        for (m, q) in (st..<k).enumerated() { out[q] -= acc * Double(m + 1) / Double(L) }
                    }
                    acc = 0
                    st = k + 1
                } else {
                    acc += (h[k] - hb) * dt
                    out[k] = acc
                }
            }
            return out
        }
        let hv1 = horizontalVelocity(h1)
        let hv2 = horizontalVelocity(h2)

        // 4. Phases.
        let vt = 0.04
        func phases(_ sign: Double) -> [Phase] {
            var raw: [(Int, Int)] = []
            var i = 0
            while i < n {
                if sign * v[i] > vt {
                    var j = i
                    while j < n && sign * v[j] > vt { j += 1 }
                    raw.append((i, j))
                    i = j
                } else {
                    i += 1
                }
            }
            var merged: [(Int, Int)] = []
            for rr in raw {
                if let last = merged.last, rr.0 - last.1 < Int(0.35 * fs) {
                    var gap = 0.0
                    for k in last.1..<rr.0 { gap += v[k] }
                    if gap * dt * sign > -0.02 {
                        merged[merged.count - 1].1 = rr.1
                        continue
                    }
                }
                merged.append(rr)
            }
            var res: [Phase] = []
            for (s0, e0) in merged {
                var d = 0.0
                for k in s0..<e0 { d += v[k] }
                d = abs(d * dt)
                if d >= 0.10 { res.append(Phase(s: s0, e: e0, disp: d)) }
            }
            return res
        }

        var con = phases(1)
        var ecc = phases(-1)

        // A grind can nearly stall mid-rep; rejoin lifting phases with no real descent between.
        var mc: [Phase] = []
        for c in con {
            if var last = mc.last {
                var between = 0.0
                for k in last.e..<c.s { between += min(0, v[k]) }
                if tt(c.s) - tt(last.e) < 1.5 && between * dt > -0.02 {
                    last.e = c.e
                    last.disp += c.disp
                    mc[mc.count - 1] = last
                    continue
                }
            }
            mc.append(c)
        }
        con = mc

        func widen(_ p: Phase, _ sign: Double) -> Phase {
            var a0 = p.s, b0 = p.e
            while a0 > 0 && sign * v[a0 - 1] > 0.005 { a0 -= 1 }
            while b0 < n && sign * v[b0] > 0.005 { b0 += 1 }
            return Phase(s: a0, e: b0, disp: p.disp)
        }
        con = con.map { widen($0, 1) }
        ecc = ecc.map { widen($0, -1) }

        // 5. Reps.
        var reps: [RepMotion] = []
        for (ci, c) in con.enumerated() {
            let cs = c.s, ce = c.e
            let prevCe = ci > 0 ? con[ci - 1].e : -1
            let nextCs = ci + 1 < con.count ? con[ci + 1].s : n
            let before = ecc.filter { $0.e <= cs && $0.s >= prevCe }
            let after = ecc.filter { $0.s >= ce && $0.e <= nextCs }

            var eccP = before.last
            var bottom: Double? = eccP.map { tt(cs) - tt($0.e) }
            if let b = bottom, b > 8 { eccP = nil; bottom = nil }
            var top: Double? = after.first.map { tt($0.s) - tt(ce) }
            if let t0 = top, t0 > 8 { top = nil }

            let seg = Array(v[cs..<ce])
            guard !seg.isEmpty else { continue }
            let dur = tt(ce - 1) - tt(cs) + dt
            let travel = seg.reduce(0, +) * dt

            // Must go back the other way, and be a plausible lift.
            let okBefore = eccP.map { $0.disp >= 0.5 * travel } ?? false
            let okAfter = after.first.map { $0.disp >= 0.5 * travel } ?? false
            guard okBefore || okAfter, dur >= 0.2, dur <= 8.0, travel > 0, travel <= 1.2 else { continue }

            let pk = seg.max() ?? 0

            // Sticking point: the slowest moment after the first surge, before the last 10%.
            var cum: [Double] = []
            var c0 = 0.0
            for x in seg { c0 += x * dt; cum.append(c0) }
            var sticking: Double? = nil
            var firstPeak: Int? = nil
            if seg.count >= 3 {
                for k in 1..<(seg.count - 1) where seg[k] >= seg[k - 1] && seg[k] >= seg[k + 1] && seg[k] > 0.25 * pk {
                    firstPeak = k
                    break
                }
            }
            if let fp = firstPeak {
                var mi: Int? = nil
                var k = fp + 1
                while k < seg.count {
                    if cum[k] > 0.9 * travel { break }
                    if mi == nil || seg[k] < seg[mi!] { mi = k }
                    k += 1
                }
                if let m = mi, seg[m] < 0.85 * seg[fp], (seg[m...].max() ?? 0) > seg[m] * 1.15 {
                    sticking = cum[m] / travel
                }
            }

            // Horizontal wander during the lift (experimental).
            var px = 0.0, py = 0.0, drift = 0.0
            for k in cs..<ce {
                px += hv1[k] * dt
                py += hv2[k] * dt
                drift = max(drift, (px * px + py * py).squareRoot())
            }

            let startIdx = eccP?.s ?? cs
            let eccSec: Double? = eccP.map { tt($0.e - 1) - tt($0.s) + dt }

            reps.append(RepMotion(
                index: reps.count + 1,
                start: Date(timeIntervalSince1970: tt(startIdx)),
                end: Date(timeIntervalSince1970: tt(ce)),
                eccentricSec: eccSec,
                bottomPauseSec: bottom.map { max(0, $0) },
                concentricSec: dur,
                topPauseSec: top.map { max(0, $0) },
                travelM: travel,
                meanVelocity: travel / dur,
                peakVelocity: pk,
                stickingPoint: sticking,
                driftM: drift))
        }
        return reps
    }

    // MARK: Filtering

    /// Zero-phase 2nd-order Butterworth low-pass (forward + backward), edge-padded.
    static func lowPass(_ x: [Double], fc: Double, fs: Double) -> [Double] {
        guard x.count > 2, let first = x.first, let last = x.last else { return x }
        let pad = min(50, x.count - 1)
        var xp = [Double](repeating: first, count: pad) + x + [Double](repeating: last, count: pad)
        xp = biquad(xp, fc: fc, fs: fs)
        xp = Array(biquad(Array(xp.reversed()), fc: fc, fs: fs).reversed())
        return Array(xp[pad..<(pad + x.count)])
    }

    private static func biquad(_ x: [Double], fc: Double, fs: Double) -> [Double] {
        let K = tan(Double.pi * fc / fs)
        let s2 = 2.0.squareRoot()
        let norm = 1 / (1 + s2 * K + K * K)
        let b0 = K * K * norm, b1 = 2 * b0, b2 = b0
        let a1 = 2 * (K * K - 1) * norm
        let a2 = (1 - s2 * K + K * K) * norm
        var y = [Double](repeating: 0, count: x.count)
        var x1 = x[0], x2 = x[0], y1 = x[0], y2 = x[0]
        for i in 0..<x.count {
            let xi = x[i]
            let o = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xi; y2 = y1; y1 = o
            y[i] = o
        }
        return y
    }
}
