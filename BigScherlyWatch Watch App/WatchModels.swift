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
}
struct WatchSet: Codable, Identifiable {
    var id: String
    var targetReps: Int
    var targetWeight: Double
    var loggedReps: Int?
    var loggedWeight: Double?
    var rpe: Int?
}
