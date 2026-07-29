import Foundation

/// Sample content for the Watch app, mirroring the phone's demo session
/// ("Lower — Squat Focus"). Used when the wrist has no state from the phone —
/// which is the case when the Watch app runs standalone, e.g. in the Simulator
/// while capturing App Store screenshots.
///
/// Add this file to the **BigScherlyWatch Watch App** target.
enum WatchDemoData {

    // Glance / home-screen values.
    static let streakWeeks = 6
    static let trainingStatus = "1 due today"
    static let nextWorkoutTitle = "Lower — Squat Focus"
    static let unreadMessages = 2
    static var nextWorkoutDate: Date { Date() }

    /// Today's session, matching the phone's MockData workout `w1`.
    static var workout: WatchWorkout {
        WatchWorkout(
            id: "w1",
            title: "Lower — Squat Focus",
            exercises: [
                exercise("e1", "Back Squat",          reps: 5,  weight: 275, sets: 4, rest: 180,
                         loggedThrough: 1),
                exercise("e2", "Romanian Deadlift",   reps: 8,  weight: 205, sets: 3, rest: 150),
                exercise("e3", "Leg Press",           reps: 12, weight: 360, sets: 3, rest: 120),
                exercise("e4", "Standing Calf Raise", reps: 15, weight: 180, sets: 4, rest: 90)
            ])
    }

    /// Builds an exercise; `loggedThrough` marks the first N sets as already completed
    /// so screenshots show a session genuinely in progress rather than untouched.
    private static func exercise(_ id: String, _ name: String,
                                 reps: Int, weight: Double, sets: Int, rest: Int,
                                 loggedThrough: Int = 0) -> WatchExercise {
        WatchExercise(
            id: id, name: name, restSeconds: rest,
            sets: (1...sets).map { i in
                let done = i <= loggedThrough
                return WatchSet(
                    id: "\(id)_s\(i)",
                    targetReps: reps,
                    targetWeight: weight,
                    loggedReps:   done ? reps : nil,
                    loggedWeight: done ? weight : nil,
                    rpe:          done ? 8 : nil)
            })
    }
}
