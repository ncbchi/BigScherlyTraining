import Foundation

// Compact, Codable snapshot of the active workout, shared in shape with the phone's
// WatchBridge definitions. Kept in the Watch target so the wrist UI can decode what
// the phone sends and encode set edits back.
struct WatchWorkout: Codable, Identifiable {
    var id: String
    var title: String
    var exercises: [WatchExercise]
    var haptics: WatchHaptics? = nil       // the phone's Settings ▸ Notifications ▸ Watch buzzes
}
struct WatchHaptics: Codable {
    var pauseStrength: Int                 // 0 light · 1 medium · 2 strong
    var pauseTicks: Bool
    var slowRepOn: Bool
    var slowRepPct: Double
    var slowRepPattern: Int                // 0 single · 1 double · 2 long
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

// MARK: - The live card (mirrors the phone; the same data the Lock Screen card draws)
// Decoded straight from the phone's card data: same field names, so the two can't drift.
// Weights are in your display units (`unit`); times are exact moments, so the Watch,
// the Lock Screen and the app all count down together.

struct WatchCardRow: Codable, Equatable, Hashable {
    var n: Int
    var tReps: Int
    var tWeight: Double
    var reps: Int?
    var weight: Double?
    var rpe: Double?
    var current: Bool
}

struct WatchCard: Codable, Equatable {
    var stage: String                 // ready · resting · lifting · done
    var startedAt: Date
    var exercise: String
    var setNumber: Int
    var setCount: Int
    var goalReps: Int
    var goalWeight: Double
    var unit: String
    var restStart: Date?
    var restEnd: Date?
    var setStart: Date?
    var logNeeded: Bool
    var accent: UInt32?
    var accentInkWhite: Bool?
    var hr: Int?
    var hrPeak: Int?
    var hrPct: Int?
    var hrZone: Int?
    var hrSpark: [Int]
    var hrMax: Int?
    var lastSet: String?
    var speeds: [Double]
    var peakSpeed: Double?
    var speedLoss: Int?
    var effort: String?
    var travel: [Double]
    var travelUnit: String
    var travelConsistency: Int?
    var ecc: [Double]
    var pause: [Double]
    var con: [Double]
    var top: [Double]
    var tempo: String?
    var pauseAvg: Double?
    var pauseTarget: Double?
    var rows: [WatchCardRow]
    var exDone: Int
    var exTotal: Int
    var setsDone: Int
    var setsTotal: Int
    var volume: Int
    var upNext: String?
    var nextReps: Int
    var nextWeight: Double
    var nextRPE: Double
    var restSeconds: Int
    var editing: Bool
    var editSet: Int
    var dReps: Int
    var dWeight: Double
    var dRPE: Double
}

