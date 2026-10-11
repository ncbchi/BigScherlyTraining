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
    static let version = 6          // 2: true sign of vertical acceleration (1 had it upside down)
                                    // 3: lift order (press/deadlift pair with the lowering after), pauses
                                    //    measured from where you actually stop, not where the phase ends
                                    // 4: a press/deadlift rep counts only once it's back down
                                    // 5: a squat/bench rep needs its lowering first
                                    // 6: drift taken out per cycle when there's no still moment (half reps,
                                    //    a fast set straight out of a rest); a lift with a lot of wrist
                                    //    turning (hand to the head, a flick) isn't a rep — per lift
    static let sampleRate = 100.0

    /// Which way a rep goes first. Squats and bench lower first, then lift; a press or a deadlift
    /// lifts first, then lowers. It decides which lowering belongs to which lift (the count is the
    /// same either way; the tempo split, start time and pauses aren't).
    enum Order: Sendable { case downFirst, upFirst, either

        /// From the exercise's name (nil name or no match → either).
        static func forExercise(_ name: String?) -> Order {
            guard let n = name?.lowercased() else { return .either }
            func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
            if has("bench", "squat", "dip", "romanian", "rdl", "good morning", "lunge", "incline", "decline", "leg press", "push-up", "push up") { return .downFirst }
            if has("deadlift", "press", "ohp", "row", "pull", "chin", "clean", "snatch", "curl", "raise", "shrug", "jerk") { return .upFirst }
            return .either
        }
    }

    private struct Phase { var s: Int; var e: Int; var disp: Double }

    /// Per-lift limits (v6). `angMax`: total wrist turning during the lift, rad — a press keeps the
    /// forearm upright (reps ≈ 0.5–1.4; a hand to the head ≈ 2.4–5), lying on a bench the wrist
    /// legitimately turns a lot, so bench gets no filter. Measured live on 2026-10-08.
    static func angMax(for order: Order) -> Double { order == .upFirst ? 2.0 : .infinity }

    static func analyze(_ s: [MotionSample], fs: Double = sampleRate, order: Order = .either) -> [RepMotion] {
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

        // 3b. (v6) Cycle closure. With no still moment to reset at (half reps, a fast set straight out
        //     of a rest) the bias drifts and travel balloons until the rep is thrown out. Between two
        //     consecutive bottoms (velocity crossing up through zero after a real descent) the wrist
        //     is back at about the same height, so the net displacement over that cycle is ~0: take
        //     whatever's left out as a constant velocity offset across the cycle.
        do {
            var i = 0
            while i < n {
                if still[i] { i += 1; continue }
                var j = i
                while j < n && !still[j] { j += 1 }
                if j - i > 5 {
                    let vs = lowPass(Array(v[i..<j]), fc: 3, fs: fs)
                    var bots: [Int] = []
                    var k = 1
                    while k < vs.count {
                        if vs[k - 1] < 0 && vs[k] >= 0 {
                            var back = k
                            while back > 0 && vs[back - 1] <= 0 { back -= 1 }
                            if (vs[back..<k].min() ?? 0) < -0.15 { bots.append(k) }
                        }
                        k += 1
                    }
                    if bots.count >= 2 {
                        for q in 0..<(bots.count - 1) {
                            let b1 = i + bots[q], b2 = i + bots[q + 1]
                            var d = 0.0, amp = 0.0
                            for k in b1..<b2 { d += v[k]; amp += abs(v[k]) }
                            d *= dt; amp *= dt / 2
                            let span = Double(b2 - b1) * dt
                            if amp > 0.05 && abs(d) > 0.08 * amp {
                                let c = d / span
                                for k in b1..<b2 { v[k] -= c }
                            }
                        }
                    }
                }
                i = j
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
                var stopped = false
                for k in last.e..<c.s { between += min(0, v[k]); if still[k] { stopped = true } }
                // …but not across a real stop (e.g. arm up into the rack, a pause, then the press).
                if tt(c.s) - tt(last.e) < 1.5 && between * dt > -0.02 && !stopped {
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
        // Pauses are measured between the moments you're really moving (over 0.12 m/s), not the phase
        // edges — at the bottom of a hold the wrist settles slowly for a second, which the phase edges
        // counted as still lowering (a 1.8 s hold read as 0.7 s; checked against the camera, Oct 6).
        let moving = 0.12
        func liftStart(_ p: Phase) -> Int { (p.s..<p.e).first { v[$0] > moving } ?? p.s }
        func liftEnd(_ p: Phase) -> Int { (p.s..<p.e).last { v[$0] > moving } ?? p.e }
        func lowerStart(_ p: Phase) -> Int { (p.s..<p.e).first { v[$0] < -moving } ?? p.s }
        func lowerEnd(_ p: Phase) -> Int { (p.s..<p.e).last { v[$0] < -moving } ?? p.e }
        var reps: [RepMotion] = []
        for (ci, c) in con.enumerated() {
            let cs = c.s, ce = c.e
            let prevCe = ci > 0 ? con[ci - 1].e : -1
            let nextCs = ci + 1 < con.count ? con[ci + 1].s : n
            // Lowering phases next to this lift (by where they start/end — the widened phases can
            // overlap by a few samples, which used to drop real reps).
            let slack = Int(0.4 * fs)
            let before = ecc.filter { $0.e <= cs + slack && $0.s < cs && $0.e > prevCe }
            let after = ecc.filter { $0.s >= ce - slack && $0.s < nextCs && $0.e > ce }

            var lowerBefore = before.last
            var lowerAfter = after.first
            var bottom: Double? = lowerBefore.map { tt(liftStart(c)) - tt(lowerEnd($0)) }
            if let b = bottom, b > 8 { lowerBefore = nil; bottom = nil }
            var top: Double? = lowerAfter.map { tt(lowerStart($0)) - tt(liftEnd(c)) }
            if let t0 = top, t0 > 8 { lowerAfter = nil; top = nil }

            let seg = Array(v[cs..<ce])
            guard !seg.isEmpty else { continue }
            let dur = tt(ce - 1) - tt(cs) + dt
            let travel = seg.reduce(0, +) * dt

            // Must go back the other way, and be a plausible lift.
            let okBefore = lowerBefore.map { $0.disp >= 0.5 * travel } ?? false
            let okAfter = lowerAfter.map { $0.disp >= 0.5 * travel } ?? false
            // A press or deadlift only counts once it's come back down (counting it on the way up
            // showed half a rep, then took it back). A squat or bench rep needs its lowering first —
            // standing up out of a crouch (or unracking) isn't a rep. Unknown lifts: either side.
            let complete = order == .upFirst ? okAfter : (order == .downFirst ? okBefore : (okBefore || okAfter))
            guard complete, dur >= 0.2, dur <= 8.0, travel > 0, travel <= 1.2 else { continue }
            // (v6) Wrist turning through the lift, total rad: a hand to the head, a wrist flick.
            var turned = 0.0
            for k in cs..<ce { turned += r[k] }
            turned *= dt
            guard turned <= angMax(for: order) else { continue }

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

            // This rep's own lowering: the one before the lift (squat, bench), or after it (press,
            // deadlift). The rep runs from the start of its first phase to the end of its last.
            let own: Phase? = order == .upFirst ? (okAfter ? lowerAfter : nil) : (okBefore ? lowerBefore : nil)
            let startIdx = order == .upFirst ? cs : (own?.s ?? cs)
            let endIdx = order == .upFirst ? (own?.e ?? ce) : ce
            let eccSec: Double? = own.map { tt($0.e - 1) - tt($0.s) + dt }

            reps.append(RepMotion(
                index: reps.count + 1,
                start: Date(timeIntervalSince1970: tt(startIdx)),
                end: Date(timeIntervalSince1970: tt(endIdx)),
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
