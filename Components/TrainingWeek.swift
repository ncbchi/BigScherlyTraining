import Foundation

// MARK: - Training week (Monday – Sunday, everywhere in the app)
// Every calendar, week strip, streak and "same week" rule uses this, so the app
// agrees with itself regardless of the phone's region settings.

extension Calendar {
    static let training: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = .current
        c.timeZone = .current
        c.firstWeekday = 2              // Monday
        c.minimumDaysInFirstWeek = 4    // ISO-style weeks
        return c
    }()

    /// Column headers for Monday-first calendars.
    static let trainingWeekdayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    /// Monday of the week containing `date`.
    func trainingWeekStart(_ date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }

    /// The seven days (Mon…Sun) of the week containing `date`.
    func trainingWeek(_ date: Date) -> [Date] {
        let start = trainingWeekStart(date)
        return (0..<7).compactMap { self.date(byAdding: .day, value: $0, to: start) }
    }

    func isSameTrainingWeek(_ a: Date, _ b: Date) -> Bool {
        trainingWeekStart(a) == trainingWeekStart(b)
    }
}
