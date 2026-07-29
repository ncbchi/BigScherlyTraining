import Foundation
import UserNotifications

// MARK: - Supplement Engine
// Owns supplement reminders and adherence logic. Reminders are PRIORITY
// (time-sensitive) local notifications that REPEAT every hour until the user opens
// the app and confirms the dose. Workout-relative doses are predicted from the
// client's historical training times (workouts are ad-hoc, with no set start time).
final class SupplementEngine {
    static let shared = SupplementEngine()
    private init() {}

    private let idPrefix = "bst.supp."
    private let followUpCount = 6          // nag hourly up to 6 more times…
    private let followUpGapMin = 60        // …one hour apart, until confirmed

    // MARK: Permission
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: Workout-time prediction (from history)
    // Median time-of-day of recent completed workouts, in minutes since midnight.
    func usualWorkoutMinutes(from workouts: [Workout]) -> Int {
        let cal = Calendar.current
        let mins = workouts.filter { $0.completed }
            .sorted { $0.date > $1.date }.prefix(12)
            .map { cal.component(.hour, from: $0.date) * 60 + cal.component(.minute, from: $0.date) }
            .sorted()
        guard !mins.isEmpty else { return 17 * 60 }   // sensible default: 5 PM
        return mins[mins.count / 2]
    }

    // Weekdays the client usually trains (≥2 sessions in recent history).
    func usualTrainingWeekdays(from workouts: [Workout]) -> [Weekday] {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for w in workouts.filter({ $0.completed }).sorted(by: { $0.date > $1.date }).prefix(30) {
            counts[cal.component(.weekday, from: w.date), default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }.keys.compactMap { Weekday(rawValue: $0) }
    }

    // MARK: Scheduling
    // Cancels everything and reschedules all active supplements from scratch.
    func rescheduleAll(supplements: [Supplement], logs: [SupplementLog], workouts: [Workout]) {
        cancelAll()
        let usualMin = usualWorkoutMinutes(from: workouts)
        let trainDays = usualTrainingWeekdays(from: workouts)

        for s in supplements where s.isActive {
            switch s.timing.kind {
            case .fixedDays:
                for day in s.timing.days ?? [] {
                    for t in s.timing.times ?? [] { schedule(s, weekday: day, minutes: t.minutes) }
                }
            case .daily, .withMeals:
                let times = s.timing.times ?? [TimeOfDay(hour: 9, minute: 0)]
                for t in times { schedule(s, weekday: nil, minutes: t.minutes) }
            case .beforeWorkout:
                // Predict: fire (offset) before the usual workout time on usual training days.
                let fire = max(0, usualMin - (s.timing.offsetMinutes ?? 30))
                for day in trainDays { schedule(s, weekday: day, minutes: fire) }
            case .afterWorkout:
                // Handled reactively when a workout is completed (see scheduleAfterWorkout).
                break
            }
        }
    }

    // A due dose + its hourly follow-ups, all cancelable on confirm.
    private func schedule(_ s: Supplement, weekday: Weekday?, minutes: Int) {
        let center = UNUserNotificationCenter.current()
        for i in 0...followUpCount {
            var comps = DateComponents()
            comps.hour = (minutes + i * followUpGapMin) / 60 % 24
            comps.minute = (minutes + i * followUpGapMin) % 60
            if let wd = weekday { comps.weekday = wd.rawValue }

            let content = UNMutableNotificationContent()
            content.title = i == 0 ? "Time for \(s.name)" : "Still need your \(s.name)"
            content.body = "\(s.dose.display)" + (s.instructions.map { " · \($0)" } ?? "")
                + " — open the app to confirm you took it."
            content.sound = .default
            content.interruptionLevel = .timeSensitive         // PRIORITY: pierces Focus
            content.categoryIdentifier = "SUPPLEMENT_DUE"
            content.userInfo = ["supplementId": s.id, "kind": "supplement"]

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let id = "\(idPrefix)\(s.id).\(weekday?.rawValue ?? 0).\(minutes).\(i)"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    // After-workout dose: called when a workout is marked complete.
    func scheduleAfterWorkout(_ supplements: [Supplement]) {
        let center = UNUserNotificationCenter.current()
        for s in supplements where s.isActive && s.timing.kind == .afterWorkout {
            for i in 0...followUpCount {
                let content = UNMutableNotificationContent()
                content.title = i == 0 ? "Post-workout: \(s.name)" : "Still need your \(s.name)"
                content.body = "\(s.dose.display) — open the app to confirm you took it."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.categoryIdentifier = "SUPPLEMENT_DUE"
                content.userInfo = ["supplementId": s.id, "kind": "supplement"]

                let secs = Double((s.timing.offsetMinutes ?? 45) + i * followUpGapMin) * 60
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, secs), repeats: false)
                center.add(UNNotificationRequest(
                    identifier: "\(idPrefix)\(s.id).after.\(i)", content: content, trigger: trigger))
            }
        }
    }

    // MARK: Confirmation — stops the nagging for that supplement.
    func cancelReminders(for supplementId: String) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(self.idPrefix + supplementId) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func cancelAll() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(self.idPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: Pre-workout confirm-on-open
    // Supplements that should be taken before a workout and haven't been logged as taken
    // today — the workout page prompts for these when opened.
    /// Supplements the client should take BEFORE training right now.
    ///
    /// Returns [] unless there is genuinely something to take, so the prompt never
    /// appears for no reason. A dose only counts as due when ALL of these hold:
    ///   • the supplement is timed `.beforeWorkout` and is inside its cycle window
    ///   • it hasn't already been confirmed today
    ///   • there is an UNCOMPLETED workout scheduled for today (no workout = nothing
    ///     to pre-load for; this is the check that was missing)
    func duePreWorkout(supplements: [Supplement],
                       logs: [SupplementLog],
                       workouts: [Workout]) -> [Supplement] {
        let cal = Calendar.current

        // No workout still to do today → nothing is "before workout".
        let hasWorkoutToday = workouts.contains {
            !$0.completed && cal.isDateInToday($0.date)
        }
        guard hasWorkoutToday else { return [] }

        return supplements.filter { s in
            guard s.isActive, s.timing.kind == .beforeWorkout else { return false }
            let takenToday = logs.contains {
                $0.supplementId == s.id && $0.status == .taken
                && cal.isDateInToday($0.takenAt ?? .distantPast)
            }
            return !takenToday
        }
    }

    // MARK: Adherence
    func adherence(logs: [SupplementLog], days: Int = 30) -> SupplementAdherence {
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let recent = logs.filter { $0.scheduledFor >= since }
        let taken = recent.filter { $0.status == .taken }.count
        let total = recent.filter { $0.status != .skipped }.count

        // Streak: consecutive days (back from today) with no missed dose and ≥1 taken.
        var streak = 0
        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { break }
            let dayLogs = logs.filter { cal.isDate($0.scheduledFor, inSameDayAs: day) }
            if dayLogs.isEmpty && offset > 0 { continue }             // nothing scheduled → skip
            if dayLogs.contains(where: { $0.status == .missed }) { break }
            if dayLogs.contains(where: { $0.status == .taken }) { streak += 1 } else if offset > 0 { break }
        }
        return SupplementAdherence(taken: taken, total: total, streakDays: streak)
    }
}
