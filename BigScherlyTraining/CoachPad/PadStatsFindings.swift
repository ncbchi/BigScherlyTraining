import SwiftUI

// MARK: - Coach HQ on iPad: what a client's numbers say (Oct 9, 2026)
//
// Findings for the coach, worked out from the same sessions the phone's Stats uses. Each one is a
// plain sentence and a quieter line of evidence. Findings only, no fix buttons (Nick, Oct 9).
// Only shown when the data really says it; thin data says nothing.
// Synchronized folder: no target step needed.

@MainActor
enum PadStatsFindings {

    // MARK: Small helpers

    private static func w(_ lb: Double) -> String { StatsUnits.weightText(lb) }
    private static func wn(_ lb: Double) -> String { StatsUnits.weightText(lb, unit: false) }
    private static func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
    private static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private static func weeks(_ from: Date, _ to: Date) -> Int { max(1, Int((to.timeIntervalSince(from) / (7 * 86_400)).rounded())) }
    private static func avg(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }

    /// (date, best e1RM) per session for one exercise name, oldest first.
    private static func e1rms(_ name: String, in sessions: [StatsSession]) -> [(date: Date, value: Double)] {
        sessions.compactMap { s in
            let v = s.exercises.filter { $0.name == name }.map { $0.bestE1RM }.max()
            return v.map { (date: s.date, value: $0) }
        }
    }

    /// Everything trained in these sessions, most-trained first, SBD lifts ahead of ties.
    private static func exerciseNames(_ sessions: [StatsSession]) -> [String] {
        var count: [String: Int] = [:]
        var sbd: Set<String> = []
        for s in sessions { for e in s.exercises { count[e.name, default: 0] += 1; if e.sbd != nil { sbd.insert(e.name) } } }
        return count.keys.sorted { a, b in
            let ca = count[a] ?? 0, cb = count[b] ?? 0
            if ca != cb { return ca > cb }
            return sbd.contains(a) && !sbd.contains(b)
        }
    }

    // MARK: Building blocks (shared by the levels)

    /// Up or down over the period for one lift. nil when there's too little to say.
    static func trend(_ name: String, sessions: [StatsSession], ctx: PadStatsContext) -> PadNote? {
        let pts = e1rms(name, in: sessions)
        guard pts.count >= 3, let f = pts.first, let l = pts.last, f.value > 0 else { return nil }
        let best = pts.map { $0.value }.max() ?? l.value
        let change = best - f.value
        let p = change / f.value * 100
        if p >= 2 {
            let pr = ctx.prs.filter { $0.exercise == name && $0.date >= f.date && !$0.isFirstEver }.max { $0.date < $1.date }
            let aside: String = pr.map { "New best \(day($0.date)): \(wn($0.weight)) × \($0.reps), an estimated 1RM of \(w($0.estimatedOneRepMax))." }
                ?? "Best estimated 1RM is now \(w(best))."
            return PadNote(icon: "bolt.fill", tint: Pad.voltText,
                           text: "\(name) is up \(w(change)) in the \(ctx.windowLabel) (+\(String(format: "%.1f", p))%).", aside: aside)
        }
        let drop = (l.value - best) / best * 100
        if drop <= -4, pts.count >= 4 {
            return PadNote(icon: "arrow.down.right", tint: Pad.orange,
                           text: "\(name) is down \(w(best - l.value)) from its best.",
                           aside: "Best \(w(best)) earlier in the period; the latest session estimates \(w(l.value)).")
        }
        return nil
    }

    /// Stalled: nothing better in the last 4 weeks than before them. Adds the effort creep at the same load.
    static func stall(_ name: String, sessions: [StatsSession], ctx: PadStatsContext) -> PadNote? {
        let pts = e1rms(name, in: sessions)
        guard pts.count >= 5, let last = pts.last else { return nil }
        let cut = last.date.addingTimeInterval(-28 * 86_400)
        let recent = pts.filter { $0.date > cut }, before = pts.filter { $0.date <= cut }
        guard recent.count >= 3, before.count >= 2,
              let rb = recent.map({ $0.value }).max(), let pb = before.map({ $0.value }).max(), rb <= pb * 1.01 else { return nil }
        // How long it's been at this level: the first session that reached within 1.5% of it.
        let plateau = max(rb, pb)
        let since = pts.first { $0.value >= plateau * 0.985 }?.date ?? cut
        let wk = weeks(since, last.date)
        guard wk >= 3 else { return nil }
        let level = pts.filter { $0.date >= since }.map { $0.value }
        let lo = level.min() ?? rb, hi = level.max() ?? rb
        let range: String = abs(hi - lo) < 1 ? wn(hi) : "\(wn(lo))–\(wn(hi))"
        let creep = effortCreep(name, sessions: sessions)
        let aside: String = creep.map { "The same \(w($0.load)) sets now rate RPE \($0.now.rpeText), up from \($0.then.rpeText)." }
            ?? "Best estimated 1RM \(w(plateau)), first reached \(day(since))."
        return PadNote(icon: "arrow.right", tint: Pad.orange, text: "\(name) has stalled at \(range) for \(wk) weeks.", aside: aside)
    }

    /// The most-used load for a lift: RPE at the start of the period against the last 3 weeks.
    static func effortCreep(_ name: String, sessions: [StatsSession]) -> (load: Double, then: Double, now: Double)? {
        let sets: [(date: Date, set: SetStat)] = sessions.flatMap { s in s.exercises.filter { $0.name == name }.flatMap { e in e.sets.map { (date: s.date, set: $0) } } }
        guard let lastDate = sets.map({ $0.date }).max() else { return nil }
        let cut = lastDate.addingTimeInterval(-21 * 86_400)
        var byLoad: [Double: Int] = [:]
        for x in sets where x.set.rpe != nil { byLoad[x.set.weight, default: 0] += 1 }
        for (load, _) in byLoad.sorted(by: { $0.value > $1.value }).prefix(3) {
            let early = sets.filter { $0.set.weight == load && $0.date <= cut }.compactMap { $0.set.rpe }
            let late = sets.filter { $0.set.weight == load && $0.date > cut }.compactMap { $0.set.rpe }
            guard early.count >= 2, late.count >= 2, let a = avg(early), let b = avg(late), b - a >= 0.75 else { continue }
            return (load, (a * 2).rounded() / 2, (b * 2).rounded() / 2)
        }
        return nil
    }

    /// Sets rated harder (or easier) than the bar speed says, in these sessions.
    static func effortMismatch(_ sessions: [StatsSession], first: String, period: String) -> [PadNote] {
        var under: [(String, Date, SetStat, Double)] = []   // rated hard, speed held: reps left
        var over: [(String, Date, SetStat, Double)] = []    // rated easy, speed fell: closer to failure
        for s in sessions {
            for e in s.exercises {
                for st in e.sets {
                    guard let m = st.motion, m.repCount >= 3, let rpe = st.rpe, let loss = m.velocityLossPct else { continue }
                    let expected = StatsEngine.expectedRPE(velocityLoss: loss, grinds: m.grindRepCount)
                    if rpe - expected >= 2 { under.append((e.name, s.date, st, loss)) }
                    else if expected - rpe >= 2 { over.append((e.name, s.date, st, loss)) }
                }
            }
        }
        var out: [PadNote] = []
        if let ex = under.last {
            let n = under.count
            let lead: String = n == 1 ? "One set \(period) was rated harder than the bar speed showed."
                                      : "\(n) sets \(period) were rated harder than the bar speed showed."
            out.append(PadNote(icon: "gauge.with.dots.needle.33percent", tint: Pad.orange, text: lead,
                               aside: "\(ex.0), \(day(ex.1)), set \(ex.2.number): RPE \((ex.2.rpe ?? 0).rpeText), only \(pct(ex.3)) slower by the last rep. Sets like that usually have 2 or more reps left."))
        }
        if let ex = over.last {
            let n = over.count
            let lead: String = n == 1 ? "One set \(period) was closer to failure than \(first) rated it."
                                      : "\(n) sets \(period) were closer to failure than \(first) rated them."
            out.append(PadNote(icon: "gauge.with.dots.needle.67percent", tint: Pad.orange, text: lead,
                               aside: "\(ex.0), \(day(ex.1)), set \(ex.2.number): RPE \((ex.2.rpe ?? 0).rpeText), but bar speed fell \(pct(ex.3))."))
        }
        return out
    }

    /// Speed loss per set rising: sets ending closer to failure.
    static func fatigue(_ name: String, sessions: [StatsSession], first: String) -> PadNote? {
        let tracked: [(Date, Double)] = sessions.compactMap { s in
            let losses = s.exercises.filter { $0.name == name }.flatMap { $0.motions.compactMap { $0.velocityLossPct } }
            return avg(losses).map { (s.date, $0) }
        }
        guard tracked.count >= 6 else { return nil }
        guard let a = avg(tracked.prefix(3).map { $0.1 }), let b = avg(tracked.suffix(3).map { $0.1 }), b - a >= 6 else { return nil }
        return PadNote(icon: "chart.line.downtrend.xyaxis", tint: Pad.orange, text: "\(first)’s \(name.lowercased()) sets are ending closer to failure.",
                       aside: "Speed loss per set went from about \(pct(a)) to \(pct(b)) over the period.")
    }

    /// Load–speed line from earlier sessions: (intercept, slope) of best rep speed against load.
    static func profile(_ name: String, before date: Date, in sessions: [StatsSession]) -> (a: Double, b: Double)? {
        var pts: [(Double, Double)] = []
        for s in sessions where s.date < date {
            for e in s.exercises where e.name == name {
                for st in e.sets {
                    if let m = st.motion, let best = m.reps.map({ $0.meanVelocity }).max() { pts.append((st.weight, best)) }
                }
            }
        }
        guard pts.count >= 4 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map { $0.0 }.reduce(0, +) / n, my = pts.map { $0.1 }.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for p in pts { sxy += (p.0 - mx) * (p.1 - my); sxx += (p.0 - mx) * (p.0 - mx) }
        guard sxx > 0 else { return nil }
        let b = sxy / sxx
        guard b < 0 else { return nil }
        return (my - b * mx, b)
    }

    /// First set of a lift in a session against that lift's usual speed at the load.
    static func readiness(_ s: StatsSession, all: [StatsSession], first: String) -> PadNote? {
        for e in s.exercises {
            guard let st = e.sets.first, let m = st.motion, let best = m.reps.map({ $0.meanVelocity }).max(),
                  let p = profile(e.name, before: s.date, in: all) else { continue }
            let predicted = p.a + p.b * st.weight
            guard predicted > 0.05 else { continue }
            let diff = (best - predicted) / predicted * 100
            guard abs(diff) >= 3 else { continue }
            if diff > 0 {
                return PadNote(icon: "bolt.fill", tint: Pad.voltText, text: "\(first)’s first \(e.name.lowercased()) set moved \(pct(diff)) faster than usual for \(w(st.weight)).",
                               aside: "A good-day signal.")
            }
            return PadNote(icon: "bolt.slash", tint: Pad.orange, text: "\(first)’s first \(e.name.lowercased()) set moved \(pct(-diff)) slower than usual for \(w(st.weight)).",
                           aside: "Sleep, food and stress all show up here first.")
        }
        return nil
    }

    // MARK: Level 0: the client's Stats

    static func home(_ ctx: PadStatsContext) -> [PadNote] {
        var out: [PadNote] = []
        let names = exerciseNames(ctx.sessions)
        // Biggest gain among the lifts trained at least 3 times.
        let gains: [(String, PadNote, Double)] = names.compactMap { n in
            let pts = e1rms(n, in: ctx.sessions)
            guard pts.count >= 3, let f = pts.first?.value, f > 0, let best = pts.map({ $0.value }).max(),
                  let note = trend(n, sessions: ctx.sessions, ctx: ctx), note.icon == "bolt.fill" else { return nil }
            return (n, note, (best - f) / f)
        }
        if let g = gains.max(by: { $0.2 < $1.2 }) { out.append(g.1) }
        // The most-trained lift that has stalled.
        if let st = names.lazy.compactMap({ stall($0, sessions: ctx.sessions, ctx: ctx) }).first { out.append(st) }
        // Effort against bar speed, last 4 weeks.
        let cut = Date().addingTimeInterval(-28 * 86_400)
        out.append(contentsOf: effortMismatch(ctx.sessions.filter { $0.date >= cut }, first: ctx.first, period: "in the last 4 weeks"))
        // Sets ending closer to failure on a main lift.
        if let f = names.lazy.compactMap({ fatigue($0, sessions: ctx.sessions, first: ctx.first) }).first { out.append(f) }
        // Balance between opposing muscle groups.
        if let b = balance(ctx) { out.append(b) }
        // The latest session's readiness.
        if let last = ctx.sessions.last(where: { $0.hasMotion }), let r = readiness(last, all: ctx.history, first: ctx.first) {
            out.append(PadNote(icon: r.icon, tint: r.tint, text: r.text, aside: "\(day(last.date)), \(last.title). " + r.aside))
        }
        return out
    }

    /// Sets per muscle: the smaller of each opposing pair, when it's well behind.
    static func balance(_ ctx: PadStatsContext) -> PadNote? {
        var sets: [String: Int] = [:]
        for s in ctx.sessions { for e in s.exercises { sets[e.muscleGroup.lowercased(), default: 0] += e.sets.count } }
        func total(_ keys: [String]) -> Int { sets.filter { row in keys.contains { row.key.contains($0) } }.map { $0.value }.reduce(0, +) }
        let pairs: [(String, [String], String, [String])] = [("Back", ["back", "lat"], "chest", ["chest", "pec"]),
                                                             ("Hamstrings", ["hamstring", "posterior"], "quads", ["quad"])]
        for (aName, aKeys, bName, bKeys) in pairs {
            let a = total(aKeys), b = total(bKeys)
            guard a > 0, b >= 12, Double(a) / Double(b) <= 0.6 else { continue }
            let r = Double(a) / Double(b)
            let share: String = r <= 0.38 ? "about a third of" : (r <= 0.55 ? "about half" : "\(Int((r * 100).rounded()))% of")
            return PadNote(icon: "scalemass", tint: Pad.mute, text: "\(aName) gets \(share) the sets \(bName) does.",
                           aside: "\(a) against \(b) in the \(ctx.windowLabel).")
        }
        return nil
    }

    // MARK: Level 1: one lift, one workout, or SBD

    static func subject(_ ctx: PadStatsContext, subject: StatsSubject, sessions: [StatsSession]) -> [PadNote] {
        var out: [PadNote] = []
        switch subject {
        case .exercise(let name):
            if let t = trend(name, sessions: sessions, ctx: ctx) { out.append(t) }
            if let s = stall(name, sessions: sessions, ctx: ctx) { out.append(s) }
            else if let c = effortCreep(name, sessions: sessions) {
                out.append(PadNote(icon: "gauge.with.dots.needle.67percent", tint: Pad.orange,
                                   text: "The same \(w(c.load)) sets feel harder.", aside: "RPE \(c.now.rpeText) lately, \(c.then.rpeText) earlier in the period."))
            }
            if let f = fatigue(name, sessions: sessions, first: ctx.first) { out.append(f) }
            if let v = speedVsReps(name, sessions: sessions, ctx: ctx) { out.append(v) }
            if let d = depth(name, sessions: sessions) { out.append(d) }
            let grinds = sessions.suffix(4).flatMap { $0.exercises.flatMap { $0.motions } }.map { $0.grindRepCount }.reduce(0, +)
            if grinds >= 2 {
                out.append(PadNote(icon: "tortoise", tint: Pad.orange, text: "\(grinds) grinding reps in the last 4 sessions.",
                                   aside: "Reps that slow below 0.20 m/s or take 2.5 s or more on the way up."))
            }
            out.append(contentsOf: effortMismatch(Array(sessions.suffix(4)), first: ctx.first, period: "in the last 4 sessions").prefix(1))
        case .sbd:
            for n in exerciseNames(sessions).filter({ SBDLift.classify($0) != nil }).prefix(3) {
                if let t = trend(n, sessions: sessions, ctx: ctx) { out.append(t) }
                else if let s = stall(n, sessions: sessions, ctx: ctx) { out.append(s) }
            }
        case .workout(let title):
            if let v = sessions.last?.volume, let f = sessions.first?.volume, sessions.count >= 3, f > 0 {
                let p = (v - f) / f * 100
                if abs(p) >= 8 {
                    out.append(PadNote(icon: p > 0 ? "arrow.up.right" : "arrow.down.right", tint: p > 0 ? Pad.voltText : Pad.orange,
                                       text: "\(title) volume is \(p > 0 ? "up" : "down") \(pct(abs(p))) in the period.",
                                       aside: "\(wn(f)) to \(w(v)) lifted per session."))
                }
            }
            let durations = sessions.compactMap { $0.durationMin }
            if durations.count >= 3, let a = avg(durations.prefix(durations.count / 2).map { Double($0) }), let b = avg(durations.suffix(durations.count / 2).map { Double($0) }), abs(b - a) >= 8 {
                out.append(PadNote(icon: "clock", tint: Pad.mute, text: "Sessions are \(b < a ? "shorter" : "longer") than they were.",
                                   aside: "About \(Int(b.rounded())) minutes lately, \(Int(a.rounded())) earlier."))
            }
            out.append(contentsOf: effortMismatch(Array(sessions.suffix(4)), first: ctx.first, period: "in the last 4 of these").prefix(1))
        case .session:
            break
        }
        return out
    }

    /// Speed-based 1RM against the rep-max estimate.
    static func speedVsReps(_ name: String, sessions: [StatsSession], ctx: PadStatsContext) -> PadNote? {
        guard let last = sessions.last, let v = ctx.engine.velocityE1RM(exerciseName: name, asOf: last.date, sessions: sessions) else { return nil }
        let best = e1rms(name, in: sessions).map { $0.value }.max() ?? 0
        guard best > 0, abs(v - best) / best >= 0.02 else { return nil }
        if v > best {
            return PadNote(icon: "speedometer", tint: Pad.voltText, text: "\(ctx.first)’s speed says \(wn(v)), the reps say \(wn(best)).",
                           aside: "The load–speed line puts the 1RM about \(w(v - best)) above the rep maxes.")
        }
        return PadNote(icon: "speedometer", tint: Pad.orange, text: "\(ctx.first)’s speed says \(wn(v)), the reps say \(wn(best)).",
                       aside: "Bar speed is lower than the rep maxes suggest. Fatigue often shows here first.")
    }

    /// Depth: steady, or getting shallower.
    static func depth(_ name: String, sessions: [StatsSession]) -> PadNote? {
        let tracked = sessions.filter { s in s.exercises.contains { $0.name == name && $0.hasMotion } }
        guard tracked.count >= 4 else { return nil }
        func travel(_ s: StatsSession) -> Double? { avg(s.exercises.filter { $0.name == name }.flatMap { $0.reps.map { $0.travelM } }) }
        let early = tracked.prefix(tracked.count - 3).compactMap(travel), late = tracked.suffix(3).compactMap(travel)
        if let a = avg(early), let b = avg(late), a > 0, b < a * 0.93 {
            return PadNote(icon: "arrow.up.to.line", tint: Pad.orange, text: "\(name) depth is getting shallower.",
                           aside: "About \(StatsUnits.depthText(a - b)) less bar travel in the last 3 sessions than before.")
        }
        let cons = tracked.suffix(4).flatMap { $0.exercises.filter { $0.name == name }.flatMap { $0.motions.compactMap { $0.travelConsistencyPct } } }
        if let c = avg(cons), c >= 92 {
            return PadNote(icon: "ruler", tint: Pad.mute, text: "Depth is steady.", aside: "\(pct(c)) consistent rep to rep over the last 4 sessions.")
        }
        return nil
    }

    // MARK: Level 2: one session

    static func session(_ ctx: PadStatsContext, _ s: StatsSession) -> [PadNote] {
        var out: [PadNote] = []
        let prs = ctx.prs.filter { Calendar.training.isDate($0.date, inSameDayAs: s.date) && !$0.isFirstEver }
        if let p = prs.max(by: { $0.estimatedOneRepMax < $1.estimatedOneRepMax }) {
            out.append(PadNote(icon: "trophy.fill", tint: Pad.voltText, text: "PR: \(p.exercise), \(wn(p.weight)) × \(p.reps).",
                               aside: "Estimated 1RM \(w(p.estimatedOneRepMax)), up \(w(p.gain))."))
        }
        if let r = readiness(s, all: ctx.history, first: ctx.first) { out.append(r) }
        out.append(contentsOf: effortMismatch([s], first: ctx.first, period: "in this session"))
        // Skipped sets (planned, not logged).
        if let wk = ctx.workouts.first(where: { $0.id == s.id }) {
            let skipped = wk.exercises.map { e in (e.name, e.sets.filter { $0.loggedReps == nil }.count) }.filter { $0.1 > 0 }
            if let worst = skipped.max(by: { $0.1 < $1.1 }) {
                let total = skipped.map { $0.1 }.reduce(0, +)
                out.append(PadNote(icon: "minus.circle", tint: Pad.orange, text: "\(total.plural("planned set")) not logged.",
                                   aside: "Most from \(worst.0) (\(worst.1))."))
            }
        }
        // Shorter or longer than usual for this workout.
        if let d = s.durationMin {
            let others = ctx.history.filter { $0.title == s.title && $0.id != s.id }.compactMap { $0.durationMin }
            if others.count >= 3, let u = avg(others.map { Double($0) }), abs(Double(d) - u) >= 12 {
                out.append(PadNote(icon: "clock", tint: Pad.mute, text: "\(d) minutes, usually \(Int(u.rounded())).",
                                   aside: Double(d) < u ? "Finished early." : "Ran long."))
            }
        }
        return out
    }

    // MARK: Level 3: one set

    static func set(_ ctx: PadStatsContext, session s: StatsSession, exercise e: ExerciseStat, set st: SetStat) -> [PadNote] {
        var out: [PadNote] = []
        guard let m = st.motion else {
            return [PadNote(icon: "applewatch.slash", tint: Pad.mute, text: "This set wasn’t tracked by the Watch.", aside: "Only the load, reps and RPE were logged.")]
        }
        if let rpe = st.rpe, let loss = m.velocityLossPct, m.repCount >= 3 {
            let expected = StatsEngine.expectedRPE(velocityLoss: loss, grinds: m.grindRepCount)
            if rpe - expected >= 1.5 {
                out.append(PadNote(icon: "gauge.with.dots.needle.33percent", tint: Pad.orange,
                                   text: "Rated RPE \(rpe.rpeText), but the last rep was only \(pct(loss)) slower than the first.",
                                   aside: "Sets with this little slowdown usually rate about \(expected.rpeText), so \(ctx.first) likely had reps left."))
            } else if expected - rpe >= 1.5 {
                out.append(PadNote(icon: "gauge.with.dots.needle.67percent", tint: Pad.orange,
                                   text: "Rated RPE \(rpe.rpeText), but bar speed fell \(pct(loss)).",
                                   aside: "That usually means about RPE \(expected.rpeText): closer to failure than it felt."))
            } else {
                out.append(PadNote(icon: "checkmark.circle", tint: Pad.mute, text: "RPE \(rpe.rpeText) matches the bar speed.",
                                   aside: "\(pct(loss)) slower by the last rep."))
            }
        }
        // Depth against this lift's usual.
        let usual = ctx.history.flatMap { $0.exercises.filter { $0.name == e.name }.flatMap { $0.reps.map { $0.travelM } } }.sorted()
        if usual.count >= 10 {
            let median = usual[usual.count / 2]
            let shallow = m.reps.filter { $0.travelM < median * 0.95 }
            if !shallow.isEmpty {
                let which = shallow.map { "\($0.index)" }.joined(separator: " and ")
                let diff = median - (avg(shallow.map { $0.travelM }) ?? median)
                out.append(PadNote(icon: "arrow.up.to.line", tint: Pad.orange,
                                   text: "\(shallow.count == 1 ? "Rep" : "Reps") \(which) \(shallow.count == 1 ? "was" : "were") about \(StatsUnits.depthText(diff)) shallower than usual.",
                                   aside: "Usual depth for \(e.name.lowercased()) is \(StatsUnits.depthText(median))."))
            }
        }
        if m.grindRepCount > 0 {
            out.append(PadNote(icon: "tortoise", tint: Pad.orange, text: "\(m.grindRepCount.plural("grinding rep")).",
                               aside: "Slower than 0.20 m/s or 2.5 s or more on the way up."))
        } else if let sp = avg(m.reps.compactMap { $0.stickingPoint }) {
            out.append(PadNote(icon: "arrow.up", tint: Pad.mute, text: "No grinding reps.", aside: "The sticking point stayed about \(pct(sp * 100)) of the way up."))
        }
        // Speed against the usual at this load.
        if let p = profile(e.name, before: s.date, in: ctx.history), let best = m.reps.map({ $0.meanVelocity }).max() {
            let predicted = p.a + p.b * st.weight
            if predicted > 0.05 {
                let diff = (best - predicted) / predicted * 100
                if abs(diff) >= 4 {
                    out.append(PadNote(icon: "speedometer", tint: diff > 0 ? Pad.voltText : Pad.orange,
                                       text: "Best rep was \(pct(abs(diff))) \(diff > 0 ? "faster" : "slower") than usual for \(w(st.weight)).",
                                       aside: String(format: "%.2f m/s, usually about %.2f.", best, predicted)))
                }
            }
        }
        return out
    }
}
