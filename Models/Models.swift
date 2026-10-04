import Foundation

// MARK: - Core Models
// These mirror the SQLite schema (see Docs/DATABASE_SCHEMA.md). In the prototype
// they're populated from MockData; in production they decode from the API.

struct Client: Identifiable, Codable {
    var id: String
    var name: String
    var email: String
    var startDate: Date
    var goal: String
}

// MARK: Workouts
struct Workout: Identifiable, Codable {
    var id: String
    var title: String
    var date: Date
    var exercises: [Exercise]
    var completed: Bool = false

    var exerciseSummary: String {
        exercises.map { $0.name }.joined(separator: " · ")
    }
    var dayOfWeek: String {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: date)
    }
    var dateLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: date)
    }
}

struct Exercise: Identifiable, Codable {
    var id: String
    var name: String
    var muscleGroup: String
    var description: String
    var coachNotes: String
    var sets: [ExerciseSet]
    var clientNotes: String = ""
    var restSeconds: Int = 90        // trainer-specified rest between sets
    // Trainer-written form cueing (optional). Decodes as "" when the server omits it,
    // so older payloads still work.
    var formInstructions: String = ""
}

struct ExerciseSet: Identifiable, Codable {
    var id: String
    var targetReps: Int
    var targetWeight: Double          // prescribed
    var loggedReps: Int? = nil        // actual achieved
    var loggedWeight: Double? = nil
    var rpe: Double? = nil            // 1–10 in half steps (rate of perceived exertion)
    var loggedAt: Date? = nil         // when this set was recorded (for per-exercise HR slicing)

    var volume: Double {              // for total-weight stats
        Double(loggedReps ?? 0) * (loggedWeight ?? 0)
    }
}

// MARK: Exercise history (per-lift, across sessions)
struct ExerciseHistorySession: Identifiable, Codable {
    var id: String
    var date: Date
    var sets: [LoggedSetRecord]

    // Best set weight that session
    var topWeight: Double { sets.map { $0.weight }.max() ?? 0 }
    // Average working weight across the session's sets
    var avgWeight: Double {
        sets.isEmpty ? 0 : sets.map { $0.weight }.reduce(0,+) / Double(sets.count)
    }
    // Best estimated 1RM that session (Epley: w * (1 + reps/30))
    var estimatedOneRepMax: Double {
        sets.map { $0.weight * (1 + Double($0.reps) / 30.0) }.max() ?? 0
    }
    var avgRpe: Double {
        let r = sets.compactMap { $0.rpe }
        return r.isEmpty ? 0 : Double(r.reduce(0,+)) / Double(r.count)
    }
    var setSummary: String {
        sets.map { "\($0.reps)×\(Int($0.weight))" }.joined(separator: ", ")
    }
}

struct LoggedSetRecord: Identifiable, Codable {
    var id: String
    var reps: Int
    var weight: Double
    var rpe: Double?
}

extension Double {
    /// RPE the way people write it: "8" or "8.5".
    var rpeText: String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}

// MARK: Macros
struct MacroDay: Identifiable, Codable {
    var id: String
    var date: Date
    var isTrainingDay: Bool
    var calorieGoal: Int
    var proteinGoal: Int    // grams
    var carbGoal: Int
    var fatGoal: Int
}

enum TrackerApp: String, CaseIterable, Codable {
    case myFitnessPal = "MyFitnessPal"
    case cronometer   = "Cronometer"
    case loseIt       = "Lose It!"

    var urlScheme: String {
        switch self {
        case .myFitnessPal: return "mfp://"
        case .cronometer:   return "cronometer://"
        case .loseIt:       return "loseit://"
        }
    }

    // Fallback if the app isn't installed — open its App Store page.
    var appStoreURL: String {
        switch self {
        case .myFitnessPal: return "https://apps.apple.com/app/id341232718"
        case .cronometer:   return "https://apps.apple.com/app/id1145935738"
        case .loseIt:       return "https://apps.apple.com/app/id297368629"
        }
    }
}

// MARK: Check-ins
struct CheckIn: Identifiable, Codable {
    var id: String
    var date: Date
    var status: CheckInStatus
    var photoIDs: [String]
    var fields: [CheckInField]      // custom fields TBD — container is ready
    var trainerResponse: String?
}

enum CheckInStatus: String, Codable { case draft, submitted, reviewed }

struct CheckInField: Identifiable, Codable {
    var id: String
    var label: String
    var value: String
}

// MARK: Photos
struct ProgressPhoto: Identifiable, Codable {
    var id: String
    var date: Date
    var imageName: String           // asset name in prototype; URL/key in prod
    var category: String            // e.g. "Front", "Side", "Back"
    var trainerComment: String?
}

// MARK: Chat
struct ChatThread: Identifiable, Codable {
    var id: String
    var topic: String               // categorizable, e.g. "Deadlift form"
    var category: ChatCategory
    var messages: [ChatMessage]
    var lastActivity: Date

    var preview: String { messages.last?.text ?? "" }
    var unread: Int { messages.filter { !$0.isRead && $0.fromTrainer }.count }
}

enum ChatCategory: String, CaseIterable, Codable {
    case general = "General"
    case form = "Form Check"
    case nutrition = "Nutrition"
    case program = "Program"
    case admin = "Admin"
}

struct ChatMessage: Identifiable, Codable {
    var id: String
    var text: String
    var fromTrainer: Bool
    var timestamp: Date
    var imageName: String? = nil
    var videoKey: String? = nil      // server key for an attached video (≤120s, 540p)
    var isRead: Bool = true
}

// MARK: Announcements
struct Announcement: Identifiable, Codable {
    var id: String
    var date: Date
    var title: String
    var body: String
    var cleared: Bool = false
}

// MARK: Share card
struct ShareStats {
    var totalWeight: Double
    var duration: String
    var setCount: Int
    var topLift: String
    var date: Date

    // Each stat can be toggled on/off by the user for the card
    enum Field: String, CaseIterable {
        case totalWeight = "Total Weight"
        case duration = "Duration"
        case setCount = "Sets"
        case topLift = "Top Lift"
        case personalRecord = "New PR"
        case award = "Award"
        case date = "Date"
    }
}
