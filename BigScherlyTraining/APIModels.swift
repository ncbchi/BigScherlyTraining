import Foundation

// MARK: - API response models
// These match the server's DTOs exactly (camelCase, since ASP.NET returns camelCase JSON).
// Each maps into the app's existing UI models so the screens don't need to change.

// Stored HealthKit data for a workout, returned from the server for slicing.
struct WorkoutHealthResponse: Decodable {
    let start: Date
    let end: Date
    let durationMinutes: Int
    let avgHeartRate: Int?
    let peakHeartRate: Int?
    let activeCalories: Int?
    let heartRateSeries: [HRPointResponse]

    struct HRPointResponse: Decodable { let t: Date; let b: Int }

    func toVitals() -> WorkoutVitals {
        WorkoutVitals(
            start: start, end: end, durationMinutes: durationMinutes,
            avgHeartRate: avgHeartRate, peakHeartRate: peakHeartRate, activeCalories: activeCalories,
            heartRateSeries: heartRateSeries.map { HeartRateSample(time: $0.t, bpm: $0.b) })
    }
}

struct APISet: Decodable {
    let id: String
    let targetReps: Int
    let targetWeight: Double
    let loggedReps: Int?
    let loggedWeight: Double?
    let rpe: Double?
    let setOrder: Int
    let loggedAt: Date?
    // Set types. Optional so a server that predates them still decodes.
    let targetRpe: Double?
    let percent: Double?
    let amrap: Bool?

    func toModel() -> ExerciseSet {
        ExerciseSet(id: id, targetReps: targetReps, targetWeight: targetWeight,
                    loggedReps: loggedReps, loggedWeight: loggedWeight, rpe: rpe,
                    loggedAt: loggedAt, targetRpe: targetRpe, percent: percent, amrap: amrap)
    }
}

struct APIExercise: Decodable {
    let id: String
    let name: String
    let muscleGroup: String
    let description: String
    let coachNotes: String
    let clientNotes: String
    let sortOrder: Int
    let restSeconds: Int
    let sets: [APISet]
    // Optional so a server that predates this field still decodes cleanly.
    let formInstructions: String?
    let videoUrl: String?   // coach's exercise library (Oct 8, 2026)

    func toModel() -> Exercise {
        Exercise(id: id, name: name, muscleGroup: muscleGroup, description: description,
                 coachNotes: coachNotes, sets: sets.map { $0.toModel() },
                 clientNotes: clientNotes, restSeconds: restSeconds,
                 formInstructions: formInstructions ?? "", videoUrl: videoUrl)
    }
}

struct APIWorkout: Decodable {
    let id: String
    let title: String
    let scheduledDate: Date
    let completed: Bool
    let exercises: [APIExercise]
    // v1.1 server. Optional so an older server still decodes.
    let clientNote: String?
    let originalDate: Date?
    // Programs (Oct 8, 2026): "Strength Base · 3-Day · Base · Wk 4" on program sessions.
    let programLabel: String?

    func toModel() -> Workout {
        Workout(id: id, title: title, date: scheduledDate,
                exercises: exercises.map { $0.toModel() }, completed: completed)
    }
}

struct APIWorkoutSummary: Decodable {
    let id: String
    let title: String
    let scheduledDate: Date
    let completed: Bool
    let exerciseSummary: String
}

struct APIMacroDay: Decodable {
    let id: String
    let date: Date
    let isTrainingDay: Bool
    let calorieGoal: Int
    let proteinGoal: Int
    let carbGoal: Int
    let fatGoal: Int

    func toModel() -> MacroDay {
        MacroDay(id: id, date: date, isTrainingDay: isTrainingDay,
                 calorieGoal: calorieGoal, proteinGoal: proteinGoal,
                 carbGoal: carbGoal, fatGoal: fatGoal)
    }
}

struct APICheckInField: Decodable {
    let id: String
    let label: String
    let value: String
    let fieldOrder: Int
    // Fields are stored as "Hydration|scale" — strip the encoded kind suffix so the
    // trainer sees a clean label, matching what the client shows.
    var cleanLabel: String { label.components(separatedBy: "|").first ?? label }
    func toModel() -> CheckInField { CheckInField(id: id, label: label, value: value) }
}

struct APICheckIn: Decodable {
    let id: String
    let date: Date
    let status: String
    let trainerResponse: String?
    let fields: [APICheckInField]
    let photoIds: [String]
    // Awards earned in the week up to this check-in. Only sent on the trainer's
    // endpoint; optional so the client's own check-in decoding is unaffected.
    let awards: [APIAward]?

    func toModel() -> CheckIn {
        CheckIn(id: id, date: date,
                status: CheckInStatus(rawValue: status) ?? .submitted,
                photoIDs: photoIds,
                fields: fields.map { $0.toModel() },
                trainerResponse: trainerResponse)
    }
}

struct APIPhoto: Decodable, Identifiable {
    let id: String
    let date: Date
    let category: String
    let trainerComment: String?
    func toModel() -> ProgressPhoto {
        // imageName holds the photo id; the app fetches the image via /photos/{id}
        ProgressPhoto(id: id, date: date, imageName: id, category: category, trainerComment: trainerComment)
    }
}

struct APIAwardStat: Decodable {
    let value: String
    let label: String
    let isPrivate: Bool?
}

struct APIAward: Decodable, Identifiable {
    var id: String { kind }
    let kind: String
    let title: String
    let blurb: String
    let icon: String
    let earnedAt: Date
    let stats: [APIAwardStat]?
}

struct APIChatThread: Decodable {
    let id: String
    let topic: String
    let category: String
    let lastActivity: Date
    let preview: String
    let unread: Int

    func toModel() -> ChatThread {
        ChatThread(id: id, topic: topic,
                   category: ChatCategory(rawValue: category) ?? .general,
                   messages: [], lastActivity: lastActivity)
    }
}

struct APIChatMessage: Decodable {
    let id: String
    let fromTrainer: Bool
    let text: String
    let imageKey: String?
    let videoKey: String?
    let isRead: Bool
    let createdAt: Date
    // Inbox extras (Oct 8, 2026); optional so an older server still decodes.
    let kind: String?
    let voiceSeconds: Double?
    let voiceAvailable: Bool?
    let voiceExpiresAt: Date?
    let transcript: String?
    let setRef: APISetRef?
    var isVoice: Bool { kind == "voice" }
    func toModel() -> ChatMessage {
        ChatMessage(id: id, text: text, fromTrainer: fromTrainer, timestamp: createdAt,
                    imageName: kind == "video" ? nil : imageKey, videoKey: videoKey ?? (kind == "video" ? imageKey : nil), isRead: isRead,
                    kind: kind, voiceSeconds: voiceSeconds, voiceAvailable: voiceAvailable, voiceExpiresAt: voiceExpiresAt,
                    transcript: transcript, setRef: setRef)
    }
}

struct APIAnnouncement: Decodable {
    let id: String
    let title: String
    let body: String
    let createdAt: Date
    /// Set on the coach's list for a post that hasn't gone out yet.
    let publishAt: Date?
    func toModel() -> Announcement {
        Announcement(id: id, date: createdAt, title: title, body: body, cleared: false)
    }
}

struct APIProfile: Decodable {
    let id: String
    let name: String
    let email: String
    let goal: String
    let startDate: Date
    let mustChangePassword: Bool
}

struct APIShareStats: Decodable {
    let totalWeight: Double
    let duration: String
    let setCount: Int
    let topLift: String
    let date: Date
}

// MARK: - Supplements
// The server returns supplements/logs in the exact JSON shape of the client models
// (see the server contract). Timing is the flat discriminated struct; Weekday is its
// Int rawValue, TimeOfDay is { "minutes": Int }, DoseUnit is its string rawValue.
typealias APISupplement = Supplement
typealias APISupplementStack = SupplementStack
typealias APISupplementLog = SupplementLog
