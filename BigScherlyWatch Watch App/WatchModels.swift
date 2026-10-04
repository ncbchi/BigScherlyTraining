import Foundation

// Compact, Codable snapshot of the active workout, shared in shape with the phone's
// WatchBridge definitions. Kept in the Watch target so the wrist UI can decode what
// the phone sends and encode set edits back.
struct WatchWorkout: Codable, Identifiable {
    var id: String
    var title: String
    var exercises: [WatchExercise]
}
struct WatchExercise: Codable, Identifiable {
    var id: String
    var name: String
    var restSeconds: Int
    var sets: [WatchSet]
    var pauseTarget: Double? = nil      // seconds — tap the wrist when the bottom pause reaches it
}
struct WatchSet: Codable, Identifiable {
    var id: String
    var targetReps: Int
    var targetWeight: Double
    var loggedReps: Int?
    var loggedWeight: Double?
    var rpe: Double?
}

// A set the wrist detected on its own, waiting to be matched to a planned set.
struct DetectedSet: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let reps: [RepMotion]
    /// Best guess at which planned set this was (nil if nothing is left to log).
    var suggestedExerciseId: String?
    var suggestedSetId: String?
    /// True when it started right around the end of a rest timer.
    var confident: Bool

    var meanVelocity: Double {
        reps.isEmpty ? 0 : reps.map { $0.meanVelocity }.reduce(0, +) / Double(reps.count)
    }
    var averageTravelM: Double {
        reps.isEmpty ? 0 : reps.map { $0.travelM }.reduce(0, +) / Double(reps.count)
    }
}
