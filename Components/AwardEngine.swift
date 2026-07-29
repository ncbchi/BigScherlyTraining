import Foundation

// MARK: - Award engine
//
// Evaluates the full award catalog from real history. Pure and idempotent: given the
// same workouts/logs it always returns the same set, so awards can't be double-granted
// and the trophy case rebuilds correctly after a reinstall.
//
// PRIVACY: supplement adherence may GATE an award (Perfect Week requires it), but any
// stat derived from it is flagged `isPrivate` so it can't reach a shared image.

enum AwardEngine {

    /// Every award the client has earned, oldest first.
    static func evaluate(workouts: [Workout],
                         supplements: [Supplement],
                         supplementLogs: [SupplementLog],
                         personalRecords: [PersonalRecord]) -> [Award] {
        var out: [Award] = []
        let cal = Calendar.current
        let done = workouts.filter { $0.completed }.sorted { $0.date < $1.date }

        // ---- Volume milestones ----
        let counts: [(AwardKind, Int)] = [
            (.workouts10, 10), (.workouts25, 25), (.workouts50, 50),
            (.workouts100, 100), (.workouts250, 250)
        ]
        for (kind, n) in counts where done.count >= n {
            let at = done[n - 1].date          // earned on the nth workout
            out.append(Award(kind: kind, earnedAt: at,
                             stats: [AwardStat(value: "\(n)", label: "WORKOUTS"),
                                     AwardStat(value: "\(weeksActive(done))", label: "WEEKS")]))
        }

        // Cumulative pounds moved (logged sets only — real work, not prescribed work).
        let totalVolume = done.reduce(0.0) { sum, w in
            sum + w.exercises.flatMap { $0.sets }.reduce(0.0) { $0 + $1.volume }
        }
        if totalVolume >= 1_000_000 {
            out.append(Award(kind: .millionPounds, earnedAt: done.last?.date ?? Date(),
                             stats: [AwardStat(value: "1M+", label: "LB MOVED"),
                                     AwardStat(value: "\(done.count)", label: "SESSIONS")]))
        }

        // ---- Strength ----
        if let first = personalRecords.min(by: { $0.date < $1.date }) {
            out.append(Award(kind: .firstPR, earnedAt: first.date,
                             stats: [AwardStat(value: "\(first.reps)×\(Int(first.weight))", label: first.exercise.uppercased()),
                                     AwardStat(value: "\(Int(first.estimatedOneRepMax))", label: "EST. 1RM")]))
        }

        // 1,000 lb club — best est. 1RM on each of the big three, summed.
        let sq = ProgressEngine.bestOneRepMax(for: "Back Squat", workouts: workouts)
        let bp = ProgressEngine.bestOneRepMax(for: "Bench Press", workouts: workouts)
        let dl = ProgressEngine.bestOneRepMax(for: "Deadlift", workouts: workouts)
        let total = sq + bp + dl
        if sq > 0, bp > 0, dl > 0, total >= 1000 {
            out.append(Award(kind: .thousandPoundClub, earnedAt: done.last?.date ?? Date(),
                             stats: [AwardStat(value: "\(Int(total))", label: "LB TOTAL"),
                                     AwardStat(value: "\(Int(sq))/\(Int(bp))/\(Int(dl))", label: "S / B / D")]))
        }

        // Triple crown — PR'd all three big lifts within a 12-week window.
        if let at = tripleCrownDate(personalRecords) {
            out.append(Award(kind: .tripleCrown, earnedAt: at,
                             stats: [AwardStat(value: "3", label: "BIG LIFTS PR'D"),
                                     AwardStat(value: "1", label: "BLOCK")]))
        }

        // Up across the board — every main lift trained this week beat the prior week.
        if let at = upAcrossTheBoardDate(workouts: done) {
            out.append(Award(kind: .upAcrossTheBoard, earnedAt: at,
                             stats: [AwardStat(value: "ALL", label: "LIFTS UP"),
                                     AwardStat(value: "1", label: "WEEK")]))
        }

        // ---- Effort ----
        // Full send — a workout where every prescribed set was hit at or above target.
        if let w = done.first(where: { w in
            let c = ProgressEngine.compliance(for: w)
            return c.setsTotal > 0 && c.setsHit == c.setsTotal
        }) {
            let c = ProgressEngine.compliance(for: w)
            out.append(Award(kind: .fullSend, earnedAt: w.date,
                             stats: [AwardStat(value: "\(c.setsHit)/\(c.setsTotal)", label: "SETS HIT"),
                                     AwardStat(value: "100%", label: "OF TARGET")]))
        }

        // Comeback — completed a workout after 14+ days away.
        for (i, w) in done.enumerated() where i > 0 {
            let gap = cal.dateComponents([.day], from: done[i - 1].date, to: w.date).day ?? 0
            if gap >= 14 {
                out.append(Award(kind: .comeback, earnedAt: w.date,
                                 stats: [AwardStat(value: "\(gap)", label: "DAYS OFF"),
                                         AwardStat(value: "1", label: "SESSION BACK")]))
                break
            }
        }

        // ---- Consistency ----
        let weeks = trainingWeeks(done)
        if let at = streakDate(weeks, needed: 4) {
            out.append(Award(kind: .streak4, earnedAt: at,
                             stats: [AwardStat(value: "4", label: "WEEKS"),
                                     AwardStat(value: "0", label: "GAPS")]))
        }
        if let at = streakDate(weeks, needed: 12) {
            out.append(Award(kind: .streak12, earnedAt: at,
                             stats: [AwardStat(value: "12", label: "WEEKS"),
                                     AwardStat(value: "0", label: "GAPS")]))
        }

        // Perfect week — every scheduled workout done AND every dose confirmed.
        if let pw = perfectWeek(workouts: workouts, supplements: supplements, logs: supplementLogs) {
            out.append(Award(kind: .perfectWeek, earnedAt: pw.date,
                             stats: [AwardStat(value: "\(pw.workouts)/\(pw.workouts)", label: "WORKOUTS"),
                                     // Private: never rendered on a shared image.
                                     AwardStat(value: "\(pw.doses)/\(pw.doses)", label: "DOSES", isPrivate: true),
                                     AwardStat(value: "\(streakCount(weeks))", label: "WEEK STREAK")]))
        }

        // Dose streak — 30 days without a missed dose. In-app only, never shareable.
        if let at = doseStreakDate(logs: supplementLogs, days: 30) {
            out.append(Award(kind: .doseStreak30, earnedAt: at,
                             stats: [AwardStat(value: "30", label: "DAYS", isPrivate: true),
                                     AwardStat(value: "0", label: "MISSED", isPrivate: true)]))
        }

        return out.sorted { $0.earnedAt < $1.earnedAt }
    }

    /// Progress toward the countable awards the client hasn't earned yet.
    static func progress(workouts: [Workout],
                         supplementLogs: [SupplementLog],
                         earned: [Award]) -> [AwardProgress] {
        let earnedKinds = Set(earned.map { $0.kind })
        let done = workouts.filter { $0.completed }
        let weeks = trainingWeeks(done)
        var out: [AwardProgress] = []

        for kind in AwardKind.allCases where !earnedKinds.contains(kind) {
            guard let goal = kind.goal else { continue }
            let current: Int
            switch kind {
            case .workouts10, .workouts25, .workouts50, .workouts100, .workouts250:
                current = done.count
            case .streak4, .streak12:
                current = streakCount(weeks)
            case .doseStreak30:
                current = currentDoseStreak(logs: supplementLogs)
            default:
                continue
            }
            out.append(AwardProgress(kind: kind, current: min(current, goal), goal: goal))
        }
        // Closest to completion first — that's the one worth chasing.
        return out.sorted { $0.fraction > $1.fraction }
    }

    // MARK: - Helpers

    private static func weekKey(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
    }

    /// Distinct weeks in which the client trained, sorted.
    private static func trainingWeeks(_ done: [Workout]) -> [DateComponents] {
        let keys = Set(done.map { weekKey($0.date) })
        return keys.sorted {
            ($0.yearForWeekOfYear ?? 0, $0.weekOfYear ?? 0) < ($1.yearForWeekOfYear ?? 0, $1.weekOfYear ?? 0)
        }
    }

    private static func weeksActive(_ done: [Workout]) -> Int { trainingWeeks(done).count }

    /// Length of the current run of consecutive training weeks.
    /// A week with nothing scheduled doesn't break it — we only count weeks trained.
    private static func streakCount(_ weeks: [DateComponents]) -> Int {
        guard !weeks.isEmpty else { return 0 }
        var best = 1, run = 1
        let cal = Calendar.current
        for i in 1..<weeks.count {
            guard let prev = cal.date(from: weeks[i - 1]),
                  let cur = cal.date(from: weeks[i]),
                  let next = cal.date(byAdding: .weekOfYear, value: 1, to: prev)
            else { continue }
            if cal.isDate(cur, equalTo: next, toGranularity: .weekOfYear) {
                run += 1; best = max(best, run)
            } else { run = 1 }
        }
        return best
    }

    /// Date the client first reached a streak of `needed` consecutive weeks.
    private static func streakDate(_ weeks: [DateComponents], needed: Int) -> Date? {
        guard weeks.count >= needed else { return nil }
        let cal = Calendar.current
        var run = 1
        for i in 1..<weeks.count {
            guard let prev = cal.date(from: weeks[i - 1]),
                  let cur = cal.date(from: weeks[i]),
                  let next = cal.date(byAdding: .weekOfYear, value: 1, to: prev)
            else { continue }
            if cal.isDate(cur, equalTo: next, toGranularity: .weekOfYear) {
                run += 1
                if run >= needed { return cal.date(from: weeks[i]) }
            } else { run = 1 }
        }
        return nil
    }

    /// PRs on squat, bench and deadlift all inside one 12-week block.
    private static func tripleCrownDate(_ prs: [PersonalRecord]) -> Date? {
        let big = ["Back Squat", "Bench Press", "Deadlift"]
        let cal = Calendar.current
        let relevant = prs.filter { big.contains($0.exercise) }.sorted { $0.date < $1.date }
        for pr in relevant {
            guard let end = cal.date(byAdding: .weekOfYear, value: 12, to: pr.date) else { continue }
            let window = relevant.filter { $0.date >= pr.date && $0.date <= end }
            if Set(window.map { $0.exercise }).count == 3 {
                return window.map { $0.date }.max()
            }
        }
        return nil
    }

    /// A week where every main lift trained was heavier than the week before.
    private static func upAcrossTheBoardDate(workouts done: [Workout]) -> Date? {
        let cal = Calendar.current
        let weeks = trainingWeeks(done)
        guard weeks.count >= 2 else { return nil }

        for i in 1..<weeks.count {
            guard let prevStart = cal.date(from: weeks[i - 1]),
                  let curStart = cal.date(from: weeks[i]),
                  let expected = cal.date(byAdding: .weekOfYear, value: 1, to: prevStart),
                  cal.isDate(curStart, equalTo: expected, toGranularity: .weekOfYear)
            else { continue }

            let cur = done.filter { cal.isDate($0.date, equalTo: curStart, toGranularity: .weekOfYear) }
            let prev = done.filter { cal.isDate($0.date, equalTo: prevStart, toGranularity: .weekOfYear) }

            func best(_ ws: [Workout], _ lift: String) -> Double {
                ws.flatMap { $0.exercises }.filter { $0.name == lift }
                  .flatMap { $0.sets }
                  .compactMap { s -> Double? in
                      guard let r = s.loggedReps, let w = s.loggedWeight, r > 0, w > 0 else { return nil }
                      return ProgressEngine.oneRepMax(weight: w, reps: r)
                  }.max() ?? 0
            }

            // Main lifts trained in BOTH weeks — need at least two to be meaningful.
            let lifts = ProgressEngine.mainLifts.filter { best(cur, $0) > 0 && best(prev, $0) > 0 }
            guard lifts.count >= 2 else { continue }
            if lifts.allSatisfy({ best(cur, $0) > best(prev, $0) }) {
                return cur.map { $0.date }.max()
            }
        }
        return nil
    }

    private struct PerfectWeek { var date: Date; var workouts: Int; var doses: Int }

    /// A calendar week where every SCHEDULED workout was completed and every supplement
    /// due that week was confirmed. Weeks with nothing scheduled don't count.
    private static func perfectWeek(workouts: [Workout],
                                    supplements: [Supplement],
                                    logs: [SupplementLog]) -> PerfectWeek? {
        let cal = Calendar.current
        let now = Date()
        let weeks = Set(workouts.filter { $0.date < now }.map { weekKey($0.date) })

        var found: PerfectWeek?
        for wk in weeks {
            guard let start = cal.date(from: wk) else { continue }
            let scheduled = workouts.filter {
                cal.isDate($0.date, equalTo: start, toGranularity: .weekOfYear) && $0.date < now
            }
            guard !scheduled.isEmpty, scheduled.allSatisfy({ $0.completed }) else { continue }

            // Every dose logged that week must be 'taken' — no misses, and at least one.
            let weekLogs = logs.filter {
                cal.isDate($0.scheduledFor, equalTo: start, toGranularity: .weekOfYear)
            }
            guard !weekLogs.isEmpty, weekLogs.allSatisfy({ $0.status == .taken }) else { continue }

            let candidate = PerfectWeek(date: scheduled.map { $0.date }.max() ?? start,
                                        workouts: scheduled.count,
                                        doses: weekLogs.count)
            // Keep the earliest qualifying week — that's when it was first earned.
            if found == nil || candidate.date < found!.date { found = candidate }
        }
        return found
    }

    /// Current run of consecutive days with no missed dose (and at least one taken).
    private static func currentDoseStreak(logs: [SupplementLog]) -> Int {
        let cal = Calendar.current
        var streak = 0
        for off in 0..<120 {
            guard let day = cal.date(byAdding: .day, value: -off, to: Date()) else { break }
            let dayLogs = logs.filter { cal.isDate($0.scheduledFor, inSameDayAs: day) }
            if dayLogs.isEmpty { continue }                      // nothing due — neutral
            if dayLogs.contains(where: { $0.status == .missed }) { break }
            if dayLogs.contains(where: { $0.status == .taken }) { streak += 1 }
        }
        return streak
    }

    private static func doseStreakDate(logs: [SupplementLog], days: Int) -> Date? {
        currentDoseStreak(logs: logs) >= days ? Date() : nil
    }
}
