import Foundation

// MARK: - Supplements
// Trainer-prescribed supplement protocols with structured dosing, flexible timing,
// adherence logging, cycles, stacks, and refill tracking.

// Structured dose: a number + a unit (never freeform).
enum DoseUnit: String, Codable, CaseIterable, Identifiable {
    case g, mg, mcg, iu = "IU", mL, capsule, tablet, scoop, drop
    var id: String { rawValue }

    func label(for amount: Double) -> String {
        switch self {
        case .g, .mg, .mcg, .iu, .mL: return rawValue           // "50 g"
        case .capsule, .tablet, .scoop, .drop:                  // pluralize countables
            return amount == 1 ? rawValue : rawValue + "s"
        }
    }
}

struct Dose: Codable, Hashable {
    var amount: Double
    var unit: DoseUnit
    var display: String {
        let n = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(amount)) : String(amount)
        return "\(n) \(unit.label(for: amount))"
    }
}

// A wall-clock time of day, stored as minutes since midnight (client-local).
struct TimeOfDay: Codable, Hashable, Comparable {
    var minutes: Int   // 0..<1440
    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }
    static func < (l: TimeOfDay, r: TimeOfDay) -> Bool { l.minutes < r.minutes }

    var display: String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let cal = Calendar.current
        if let d = cal.date(from: c) {
            let f = DateFormatter(); f.timeStyle = .short
            return f.string(from: d)
        }
        return String(format: "%02d:%02d", hour, minute)
    }
    init(minutes: Int) { self.minutes = max(0, min(1439, minutes)) }
    init(hour: Int, minute: Int) { self.init(minutes: hour * 60 + minute) }
}

enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sun = 1, mon, tue, wed, thu, fri, sat
    var id: Int { rawValue }
    var short: String { ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][rawValue] }
}

// Timing is modeled as a flat, discriminated struct so it serializes cleanly to/from
// the server as JSON (rather than a Swift enum with associated values).
enum TimingKind: String, Codable {
    case fixedDays       // specific weekdays at set time(s)
    case daily           // every day at set time(s)
    case beforeWorkout   // N minutes before a (predicted) workout
    case afterWorkout    // within N minutes after a workout
    case withMeals       // with meals (count per day)
}

struct SupplementTiming: Codable, Hashable {
    var kind: TimingKind
    var days: [Weekday]?      // fixedDays
    var times: [TimeOfDay]?   // fixedDays / daily
    var offsetMinutes: Int?   // before/afterWorkout
    var mealCount: Int?       // withMeals

    // Human-readable summary for the UI.
    var summary: String {
        switch kind {
        case .fixedDays:
            let d = (days ?? []).sorted { $0.rawValue < $1.rawValue }.map(\.short).joined(separator: ", ")
            let t = (times ?? []).map(\.display).joined(separator: " & ")
            return [d, t].filter { !$0.isEmpty }.joined(separator: " · ")
        case .daily:
            let t = (times ?? []).map(\.display).joined(separator: " & ")
            return t.isEmpty ? "Every day" : "Daily · \(t)"
        case .beforeWorkout:
            return "\(offsetMinutes ?? 30) min before workout"
        case .afterWorkout:
            return "Within \(offsetMinutes ?? 45) min after workout"
        case .withMeals:
            let c = mealCount ?? 1
            return "With meals · \(c)×/day"
        }
    }

    var isWorkoutRelative: Bool { kind == .beforeWorkout || kind == .afterWorkout }
}

struct SupplementStack: Identifiable, Codable, Hashable {
    let id: String
    var name: String          // e.g. "Pre-Workout Stack"
}

struct Supplement: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var dose: Dose
    var timing: SupplementTiming
    var stackId: String? = nil
    var instructions: String? = nil   // e.g. "with 500 ml water"
    var isPrescription: Bool = false

    // Cycle / date-range (nil = ongoing)
    var cycleStart: Date? = nil
    var cycleEnd: Date? = nil

    // Refill tracking (nil = untracked)
    var quantityOnHand: Int? = nil    // doses remaining
    var reorderURL: String? = nil     // Shopify product link

    var isActive: Bool {
        let now = Date()
        if let s = cycleStart, now < s { return false }
        if let e = cycleEnd, now > e { return false }
        return true
    }
    var lowStock: Bool {
        guard let q = quantityOnHand else { return false }
        return q <= 5
    }
}

enum DoseStatus: String, Codable { case pending, taken, missed, skipped }

// One scheduled dose occurrence + its adherence outcome.
struct SupplementLog: Identifiable, Codable, Hashable {
    let id: String
    var supplementId: String
    var scheduledFor: Date
    var takenAt: Date?
    var status: DoseStatus
}

// Rolled-up adherence for display and for the trainer's compliance view.
struct SupplementAdherence {
    var taken: Int
    var total: Int
    var streakDays: Int
    var rate: Double { total == 0 ? 0 : Double(taken) / Double(total) }
    var percentLabel: String { total == 0 ? "—" : "\(Int((rate * 100).rounded()))%" }
}
