import Foundation

// MARK: - Home & Lock Screen widgets: the data they read
//
// Target membership: BOTH BigScherlyTraining and BigScherlyWidgetsExtension.
//
// Widgets can't see the app's memory, so the app saves this snapshot into the shared
// App Group whenever your data changes (WidgetBridge, app side), and every widget reads it.
// It covers two weeks of days, so widgets roll over to "tomorrow" at midnight on their own.

nonisolated enum WidgetShared {
    /// Signing & Capabilities ▸ App Groups — the same group on the app and the widget extension.
    /// The project's group is group.bigscherlytraining.app (signed into the app, the widget
    /// and the Watch app). The others are fallbacks; each target uses whichever it has.
    static let knownGroups = ["group.bigscherlytraining.app", "group.com.bigscherlytraining.app",
                              "group.com.nicholasbowen.bigscherlytraining"]
    static let appGroup: String = knownGroups.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    } ?? knownGroups[0]
    private static let snapshotKey = "bst_widget_snapshot"
    private static let pendingKey = "bst_widget_pending_supplements"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// True when this target (app or widget) has the App Group switched on. Without it,
    /// each side reads and writes its own private storage and the widgets never see data.
    static var isConnected: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    /// What a widget shows when there's no snapshot: why, rather than a generic "sign in".
    static func loadOrExplain() -> WidgetSnapshot {
        if let s = load() { return s }
        return WidgetSnapshot(generatedAt: Date(), state: isConnected ? .waiting : .notConnected)
    }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ s: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(s) { defaults?.set(data, forKey: snapshotKey) }
    }

    // Supplements ticked on a widget: marked in the snapshot straight away (so the widget
    // shows it), and queued for the app to add to your log next time it runs.
    static func markTaken(_ supplementId: String) {
        if var s = load(), let i = s.supplements.firstIndex(where: { $0.id == supplementId }) {
            s.supplements[i].taken = true
            save(s)
        }
        var p = pendingTicks()
        p[supplementId] = Date()
        if let data = try? JSONEncoder().encode(p) { defaults?.set(data, forKey: pendingKey) }
    }

    static func pendingTicks() -> [String: Date] {
        guard let data = defaults?.data(forKey: pendingKey),
              let p = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return p
    }

    static func clearPendingTicks() { defaults?.removeObject(forKey: pendingKey) }
}

nonisolated struct WidgetSnapshot: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case client, loggedOut, coach
        case waiting        // App Group fine, but the app hasn't saved anything yet
        case notConnected   // this widget can't reach the App Group
    }

    var generatedAt: Date
    var state: State
    var unit: String = "lb"
    var days: [Day] = []                 // Monday of this week → 13 days on
    var lifts: [Lift] = []               // most recently trained first
    var supplements: [Supp] = []
    var lastCheckIn: Date? = nil
    var latest: String? = nil            // latest award, worded
    var latestDate: Date? = nil
    var unreadCoach: Int = 0
    var month: Month = .init()

    nonisolated struct Day: Codable, Sendable, Identifiable {
        var id: Date { date }
        var date: Date                   // start of day
        var workout: Workout?
        var macros: Macros?
    }
    nonisolated struct Workout: Codable, Sendable {
        var id: String
        var title: String
        var exercises: [Ex]
        var completed: Bool
        var setsDone: Int { exercises.reduce(0) { $0 + $1.done } }
        var setsTotal: Int { exercises.reduce(0) { $0 + $1.total } }
        /// The exercise being worked on (first not finished).
        var current: Ex? { exercises.first { $0.done < $0.total } }
    }
    nonisolated struct Ex: Codable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var done: Int
        var total: Int
    }
    nonisolated struct Macros: Codable, Sendable {
        var kcal: Int
        var protein: Int
        var carbs: Int
        var fat: Int
        var training: Bool
        var note: String?                // "moved from Wed", "+312 from your run"
    }
    nonisolated struct Lift: Codable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var e1rm: Double                 // display units
        var change: Double               // vs ~8 weeks ago, display units
        var points: [Double]             // recent sessions' best est. 1RM
        var sessions: Int
        var last: Date
        var speed: Double?               // last session's average bar speed (m/s)
    }
    nonisolated struct Supp: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var timing: String
        var taken: Bool
    }
    nonisolated struct Month: Codable, Sendable {
        var sessions = 0
        var sets = 0
        var volume = 0                   // display units
        var prs = 0
    }

    // MARK: Reading it for a given moment (the widget's timeline date)

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2               // Monday — matches the app
        c.timeZone = .current
        return c
    }

    func day(_ d: Date) -> Day? { days.first { Self.calendar.isDate($0.date, inSameDayAs: d) } }

    enum DayStatus { case done, planned, today, missed, rest }

    func status(of day: Day, at now: Date) -> DayStatus {
        let cal = Self.calendar
        guard let w = day.workout else { return .rest }
        if w.completed { return .done }
        if cal.isDate(day.date, inSameDayAs: now) { return .today }
        return day.date < cal.startOfDay(for: now) ? .missed : .planned
    }

    /// Monday → Sunday of the week containing `d`.
    func week(of d: Date) -> [(date: Date, day: Day?)] {
        let cal = Self.calendar
        guard let monday = cal.dateInterval(of: .weekOfYear, for: d)?.start else { return [] }
        return (0..<7).compactMap { i -> (date: Date, day: Day?)? in
            guard let date = cal.date(byAdding: .day, value: i, to: monday) else { return nil }
            return (date: date, day: day(date))
        }
    }

    func weekProgress(_ d: Date) -> (done: Int, planned: Int) {
        let w = week(of: d).compactMap { $0.day?.workout }
        return (w.filter { $0.completed }.count, w.count)
    }

    /// Upcoming workouts from today on (today's first, if it isn't finished).
    func upcoming(from d: Date, limit: Int) -> [(date: Date, workout: Workout)] {
        let today = Self.calendar.startOfDay(for: d)
        let list = days.filter { $0.date >= today }.compactMap { d -> (date: Date, workout: Workout)? in
            guard let w = d.workout, !w.completed else { return nil }
            return (date: d.date, workout: w)
        }
        return Array(list.prefix(limit))
    }

    /// Ticks only count on the day they were saved; a new day starts with none taken.
    func supplements(at d: Date) -> [Supp] {
        Self.calendar.isDate(generatedAt, inSameDayAs: d) ? supplements : supplements.map { var s = $0; s.taken = false; return s }
    }

    var nextCheckIn: Date? { lastCheckIn.flatMap { Self.calendar.date(byAdding: .day, value: 7, to: $0) } }

    func daysToCheckIn(_ d: Date) -> Int? {
        guard let n = nextCheckIn else { return nil }
        let cal = Self.calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: n)).day
    }

    func lift(named name: String?) -> Lift? {
        if let name, let l = lifts.first(where: { $0.name == name }) { return l }
        return lifts.first
    }

    // MARK: Sample (widget gallery previews and placeholders)

    static var sample: WidgetSnapshot {
        let cal = calendar
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        let todayIdx = (cal.component(.weekday, from: Date()) + 5) % 7
        let titles = ["Lower — Squat Focus", "Upper — Push", nil, "Lower — Hinge", "Upper — Pull", nil, nil] as [String?]
        var days: [Day] = []
        for i in 0..<14 {
            let date = cal.date(byAdding: .day, value: i, to: monday)!
            var w: Workout? = nil
            if let t = titles[i % 7] {
                let done = i < todayIdx
                let ex = [Ex(name: "Back Squat", done: done ? 4 : (i == todayIdx ? 4 : 0), total: 4),
                          Ex(name: "Romanian Deadlift", done: done ? 3 : (i == todayIdx ? 2 : 0), total: 3),
                          Ex(name: "Walking Lunge", done: done ? 3 : 0, total: 3),
                          Ex(name: "Leg Curl", done: done ? 3 : 0, total: 3)]
                w = Workout(id: "sample-\(i)", title: t, exercises: ex, completed: done)
            }
            let training = w != nil
            days.append(Day(date: date, workout: w,
                            macros: Macros(kcal: training ? 2850 : 2400, protein: 200, carbs: training ? 300 : 220,
                                           fat: training ? 80 : 85, training: training, note: nil)))
        }
        return WidgetSnapshot(
            generatedAt: Date(), state: .client, unit: "lb", days: days,
            lifts: [Lift(name: "Back Squat", e1rm: 321, change: 12, points: [296, 298, 301, 305, 304, 310, 316, 321], sessions: 14, last: Date(), speed: 0.47),
                    Lift(name: "Bench Press", e1rm: 236, change: 6, points: [226, 228, 229, 231, 230, 233, 236], sessions: 12, last: Date(), speed: 0.52),
                    Lift(name: "Deadlift", e1rm: 402, change: 15, points: [378, 382, 387, 390, 395, 398, 402], sessions: 10, last: Date(), speed: 0.38)],
            supplements: [Supp(id: "s1", name: "Creatine", timing: "Daily", taken: true),
                          Supp(id: "s2", name: "Vitamin D", timing: "Morning", taken: false),
                          Supp(id: "s3", name: "Fish oil", timing: "With meals", taken: false)],
            lastCheckIn: cal.date(byAdding: .day, value: -6, to: Date()),
            latest: "Squat PR", latestDate: Date(), unreadCoach: 2,
            month: Month(sessions: 11, sets: 196, volume: 128_400, prs: 3))
    }

    static var loggedOut: WidgetSnapshot { WidgetSnapshot(generatedAt: Date(), state: .loggedOut) }
}
