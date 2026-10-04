import Foundation

// MARK: - Mock data for the prototype
// Everything here is fake and lives only in-memory. Swap MockData for live API
// calls when the backend is wired up. Structure matches the DB schema exactly.

enum MockData {
    static func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }

    static let client = Client(
        id: "c1", name: "Jordan", email: "jordan@example.com",
        startDate: day(-120), goal: "Add 100lb to total, lean up"
    )

    // MARK: Workouts (past + upcoming)
    static let workouts: [Workout] = {
        // Sample form cueing so the "Proper Form" card is populated in the demo.
        let formCues: [String: String] = [
            "Back Squat": """
SETUP
• Bar on your upper traps, hands just outside the shoulders.
• Feet shoulder-width, toes turned out slightly.
• Big breath into the belly, brace like you're about to be punched.

EXECUTION
• Break at the hips and knees together, sit between your feet.
• Hit depth — hip crease below the knee.
• Drive the whole foot through the floor, chest stays up.

COMMON FAULTS
• Knees caving in → push them out toward your little toes.
• Chest dropping → brace harder, keep the bar over midfoot.
• Cutting depth → lighten the load and own the range.

SAFETY
• Always use the safety pins. If it stalls, bail backward, not forward.
""",
            "Bench Press": """
SETUP
• Eyes under the bar, shoulder blades pinched and tucked down.
• Feet flat and driving into the floor, slight arch in the upper back.
• Grip just outside shoulder-width, wrists stacked over elbows.

EXECUTION
• Lower under control to the lower chest, elbows ~45°.
• Touch, don't bounce. Pause if the coach programs it.
• Press up and slightly back toward your face.

COMMON FAULTS
• Elbows flared to 90° → shoulder pain; tuck them in.
• Losing the shoulder blades → re-set between reps.
• Bouncing the bar → you're skipping the hardest part.

SAFETY
• Use a spotter or the pins for any top set. Never thumbless grip.
""",
            "Deadlift": """
SETUP
• Bar over midfoot, shins nearly touching.
• Grip just outside the knees, hips higher than a squat.
• Pull the slack out of the bar — you should hear it click.

EXECUTION
• Push the floor away, chest and hips rise together.
• Bar drags up the legs, stays in contact.
• Lock out by squeezing the glutes, don't lean back.

COMMON FAULTS
• Hips shooting up first → the bar drifts forward; re-brace.
• Rounding the lower back → drop the weight, it's not worth it.
• Jerking the bar off the floor → build tension first.

SAFETY
• Reset every rep. If the back rounds, the set is over.
"""
        ]
        func sets(_ reps: Int, _ w: Double, _ n: Int, logged: Bool) -> [ExerciseSet] {
            (0..<n).map { i in
                ExerciseSet(id: "s\(i)", targetReps: reps, targetWeight: w,
                            loggedReps: logged ? reps : nil,
                            loggedWeight: logged ? w : nil,
                            // Fixed (not random) so the demo looks the same on every launch.
                            rpe: logged ? [7.0, 8.0, 8.5, 9.0][i % 4] : nil)
            }
        }
        func ex(_ id: String, _ name: String, _ mg: String, _ reps: Int, _ w: Double, _ n: Int, logged: Bool) -> Exercise {
            // Heavier compound lifts get longer rest; accessories shorter
            let rest: Int
            switch name {
            case "Back Squat", "Deadlift", "Bench Press", "Front Squat": rest = 180
            case "Romanian Deadlift", "Overhead Press", "Barbell Row", "Weighted Pull-Up": rest = 120
            default: rest = 75
            }
            return Exercise(id: id, name: name, muscleGroup: mg,
                     description: "\(name) targets the \(mg.lowercased()). Brace hard, control the eccentric, drive through the full range of motion.",
                     coachNotes: "Keep RPE around 8. Leave 1-2 reps in the tank on the last set. Film your top set if it feels off.",
                     sets: sets(reps, w, n, logged: logged),
                     restSeconds: rest,
                     formInstructions: formCues[name] ?? "")
        }
        return [
            // Upcoming (future dates, not completed)
            Workout(id: "w1", title: "Lower — Squat Focus", date: day(0), exercises: [
                ex("e1","Back Squat","Legs",5,275,4, logged:false),
                ex("e2","Romanian Deadlift","Hamstrings",8,205,3, logged:false),
                ex("e3","Leg Press","Quads",12,360,3, logged:false),
                ex("e4","Standing Calf Raise","Calves",15,180,4, logged:false)
            ]),
            Workout(id: "w2", title: "Upper — Bench Focus", date: day(2), exercises: [
                ex("e5","Bench Press","Chest",5,205,4, logged:false),
                ex("e6","Weighted Pull-Up","Back",6,45,4, logged:false),
                ex("e7","Overhead Press","Shoulders",8,115,3, logged:false),
                ex("e8","Barbell Row","Back",10,155,3, logged:false)
            ]),
            Workout(id: "w3", title: "Lower — Deadlift Focus", date: day(4), exercises: [
                ex("e9","Deadlift","Back",3,345,4, logged:false),
                ex("e10","Front Squat","Quads",8,185,3, logged:false),
                ex("e11","Walking Lunge","Legs",12,50,3, logged:false)
            ]),
            Workout(id: "w4", title: "Upper — Volume", date: day(6), exercises: [
                ex("e12","Incline DB Press","Chest",10,80,4, logged:false),
                ex("e13","Lat Pulldown","Back",12,160,4, logged:false),
                ex("e14","Lateral Raise","Shoulders",15,25,4, logged:false)
            ]),
            // Past (completed, logged)
            Workout(id: "w5", title: "Lower — Squat Focus", date: day(-2), exercises: [
                ex("e15","Back Squat","Legs",5,270,4, logged:true),
                ex("e16","Romanian Deadlift","Hamstrings",8,200,3, logged:true),
                ex("e17","Leg Press","Quads",12,350,3, logged:true)
            ], completed: true),
            Workout(id: "w6", title: "Upper — Bench Focus", date: day(-4), exercises: [
                ex("e18","Bench Press","Chest",5,200,4, logged:true),
                ex("e19","Weighted Pull-Up","Back",6,40,4, logged:true),
                ex("e20","Overhead Press","Shoulders",8,110,3, logged:true)
            ], completed: true),
            Workout(id: "w7", title: "Lower — Deadlift Focus", date: day(-6), exercises: [
                ex("e21","Deadlift","Back",3,335,4, logged:true),
                ex("e22","Front Squat","Quads",8,180,3, logged:true)
            ], completed: true)
        ] + pastProgression()
    }()

    // A real 20-week logged progression, so the History charts and PR detection have
    // genuine data to work with in demo mode. Weights climb steadily with one deload
    // dip, which also makes the PR throttle demonstrable (not every bump celebrates).
    private static func pastProgression() -> [Workout] {
        func lset(_ reps: Int, _ w: Double, _ n: Int) -> [ExerciseSet] {
            (0..<n).map { i in
                ExerciseSet(id: "ps\(i)", targetReps: reps, targetWeight: w,
                            loggedReps: reps, loggedWeight: w,
                            rpe: Double(min(10, 7 + (i == n - 1 ? 2 : i % 2))))
            }
        }
        func pex(_ id: String, _ name: String, _ mg: String, _ reps: Int, _ w: Double, _ n: Int) -> Exercise {
            let rest: Int
            switch name {
            case "Back Squat", "Deadlift", "Bench Press", "Front Squat": rest = 180
            case "Romanian Deadlift", "Overhead Press", "Barbell Row": rest = 120
            default: rest = 75
            }
            return Exercise(id: id, name: name, muscleGroup: mg,
                            description: "\(name) targets the \(mg.lowercased()).",
                            coachNotes: "Keep RPE around 8.",
                            sets: lset(reps, w, n), restSeconds: rest)
        }
        var out: [Workout] = []
        // i = 12 (oldest, ~24 weeks ago) -> 1 (most recent). Sessions ~10 days apart,
        // starting before the three hand-written ones above.
        for i in stride(from: 12, through: 1, by: -1) {
            let d = day(-(i * 10 + 8))
            let step = Double(12 - i) * 5.0          // +5 lb per block
            let dip: Double = (i == 5) ? -10 : 0     // a deload, keeps the curve honest
            if (12 - i) % 2 == 0 {
                out.append(Workout(id: "h\(i)", title: "Lower — Squat Focus", date: d, exercises: [
                    pex("h\(i)a", "Back Squat", "Legs", 5, 215 + step + dip, 4),
                    pex("h\(i)b", "Romanian Deadlift", "Hamstrings", 8, 150 + step * 0.6, 3)
                ], completed: true))
            } else {
                out.append(Workout(id: "h\(i)", title: "Upper — Bench Focus", date: d, exercises: [
                    pex("h\(i)a", "Bench Press", "Chest", 5, 160 + step * 0.7 + dip, 4),
                    pex("h\(i)b", "Deadlift", "Back", 3, 270 + step, 3),
                    pex("h\(i)c", "Overhead Press", "Shoulders", 8, 92 + step * 0.4, 3)
                ], completed: true))
            }
        }
        return out
    }

    // MARK: Macros
    static let macroDays: [MacroDay] = (0..<7).map { i in
        let training = [true,false,true,false,true,false,false][i]
        return MacroDay(id: "m\(i)", date: day(i), isTrainingDay: training,
                        calorieGoal: training ? 2850 : 2450,
                        proteinGoal: 220,
                        carbGoal: training ? 320 : 220,
                        fatGoal: training ? 75 : 80)
    }

    // MARK: Check-ins
    static let checkIns: [CheckIn] = [
        // Most recent — full set of the new fields, encoded "Label|kind".
        CheckIn(id: "ci1", date: day(-3), status: .reviewed, photoIDs: ["p1","p2"],
                fields: [
                    CheckInField(id:"hydration",   label:"Hydration|scale",           value:"8"),
                    CheckInField(id:"nutrition",   label:"Nutrition adherence|scale",  value:"9"),
                    CheckInField(id:"consistency", label:"Workout consistency|scale",  value:"9"),
                    CheckInField(id:"sleepQuality",label:"Sleep quality|scale",        value:"8"),
                    CheckInField(id:"energy",      label:"Energy / fatigue|scale",     value:"8"),
                    CheckInField(id:"stress",      label:"Stress load|scale",          value:"3"),
                    CheckInField(id:"soreness",    label:"Soreness / recovery|scale",  value:"7"),
                    CheckInField(id:"cravings",    label:"Cravings / hunger|scale",    value:"4"),
                    CheckInField(id:"motivation",  label:"Motivation / mood|scale",    value:"9"),
                    CheckInField(id:"weight",      label:"Bodyweight|number",          value:"214"),
                    CheckInField(id:"feedback",    label:"How did the workouts feel? (too long/short/hard/easy?)|longText",
                                 value:"Felt strong this week — squats moved well and the sessions were the right length. Last accessory block felt a touch easy, could add a set."),
                    CheckInField(id:"anythingElse",label:"Anything else you'd like to cover?|longText",
                                 value:"Traveling next week so I might have to shuffle two sessions — will keep you posted."),
                ],
                trainerResponse: "Great week — squat looked crisp. Bumping your protein 10g and holding carbs. Keep sleep locked in."),
        // Previous week — for week-over-week comparison (weight higher, sleep lower).
        CheckIn(id: "ci2", date: day(-10), status: .reviewed, photoIDs: ["p3"],
                fields: [
                    CheckInField(id:"hydration",   label:"Hydration|scale",           value:"6"),
                    CheckInField(id:"nutrition",   label:"Nutrition adherence|scale",  value:"7"),
                    CheckInField(id:"consistency", label:"Workout consistency|scale",  value:"8"),
                    CheckInField(id:"sleepQuality",label:"Sleep quality|scale",        value:"6"),
                    CheckInField(id:"energy",      label:"Energy / fatigue|scale",     value:"6"),
                    CheckInField(id:"stress",      label:"Stress load|scale",          value:"5"),
                    CheckInField(id:"soreness",    label:"Soreness / recovery|scale",  value:"6"),
                    CheckInField(id:"cravings",    label:"Cravings / hunger|scale",    value:"6"),
                    CheckInField(id:"motivation",  label:"Motivation / mood|scale",    value:"7"),
                    CheckInField(id:"weight",      label:"Bodyweight|number",          value:"216"),
                    CheckInField(id:"feedback",    label:"How did the workouts feel? (too long/short/hard/easy?)|longText",
                                 value:"Busy week at work, a couple sessions felt rushed but I got them in."),
                ],
                trainerResponse: "Solid. Recovery on point. Let's push bench next block.")
    ]

    // MARK: Photos
    static let photos: [ProgressPhoto] = [
        ProgressPhoto(id:"p1", date: day(-3),  imageName:"photo_front", category:"Front", trainerComment:"Shoulders filling out nicely."),
        ProgressPhoto(id:"p2", date: day(-3),  imageName:"photo_side",  category:"Side", trainerComment:nil),
        ProgressPhoto(id:"p3", date: day(-31), imageName:"photo_front", category:"Front", trainerComment:"Baseline — we'll compare here."),
        ProgressPhoto(id:"p4", date: day(-31), imageName:"photo_back",  category:"Back", trainerComment:nil),
        ProgressPhoto(id:"p5", date: day(-62), imageName:"photo_front", category:"Front", trainerComment:nil)
    ]

    // MARK: Chat
    static let chats: [ChatThread] = [
        ChatThread(id:"t1", topic:"Deadlift form", category:.form, messages:[
            ChatMessage(id:"cm1", text:"Hey coach, my lower back rounds a bit at the bottom — normal?", fromTrainer:false, timestamp: day(-1)),
            ChatMessage(id:"cm2", text:"Send me a video of your top set and I'll take a look. Usually it's bracing timing.", fromTrainer:true, timestamp: day(-1), isRead:false)
        ], lastActivity: day(-1)),
        ChatThread(id:"t2", topic:"This week's macros", category:.nutrition, messages:[
            ChatMessage(id:"cm3", text:"Can I swap rice for potatoes on training days?", fromTrainer:false, timestamp: day(-2)),
            ChatMessage(id:"cm4", text:"Totally — match the carbs and you're good. 👍", fromTrainer:true, timestamp: day(-2))
        ], lastActivity: day(-2)),
        ChatThread(id:"t3", topic:"General check-in", category:.general, messages:[
            ChatMessage(id:"cm5", text:"Feeling great this block, thanks for everything!", fromTrainer:false, timestamp: day(-5))
        ], lastActivity: day(-5))
    ]

    // MARK: Announcements
    static let announcements: [Announcement] = [
        Announcement(id:"a1", date: day(-1), title:"New PR Challenge Starts Monday",
                     body:"We're running a 4-week strength push. Hit a PR on any main lift and tag #bigscherlytraining to get featured. Let's get big together 👑"),
        Announcement(id:"a2", date: day(-8), title:"Holiday Schedule",
                     body:"Check-ins move to Sunday this week due to the holiday. Get your submissions in by 8pm."),
        Announcement(id:"a3", date: day(-20), title:"Welcome to the App!",
                     body:"Your workouts, macros, and check-ins now live here. Reach out in Chat with any questions.")
    ]

    // MARK: Share stats (from most recent completed workout)
    static let shareStats = ShareStats(
        totalWeight: 42_650, duration: "1h 12m", setCount: 22,
        topLift: "Deadlift 345×3", date: day(-2)
    )

    // MARK: - Supplements
    static let supplementStacks: [SupplementStack] = [
        SupplementStack(id: "st_pre",  name: "Pre-Workout Stack"),
        SupplementStack(id: "st_post", name: "Post-Workout Stack"),
    ]

    static let supplements: [Supplement] = [
        Supplement(id: "sup_bcaa", name: "BCAAs",
                   dose: Dose(amount: 1, unit: .g),
                   timing: SupplementTiming(kind: .beforeWorkout, days: nil, times: nil,
                                            offsetMinutes: 30, mealCount: nil),
                   stackId: "st_pre", instructions: "with 500 ml water",
                   quantityOnHand: 4, reorderURL: "https://www.bigscherlytraining.com"),
        Supplement(id: "sup_protein", name: "Whey Protein",
                   dose: Dose(amount: 50, unit: .g),
                   timing: SupplementTiming(kind: .afterWorkout, days: nil, times: nil,
                                            offsetMinutes: 45, mealCount: nil),
                   stackId: "st_post", instructions: nil,
                   quantityOnHand: 18, reorderURL: "https://www.bigscherlytraining.com"),
        Supplement(id: "sup_creatine", name: "Creatine",
                   dose: Dose(amount: 5, unit: .g),
                   timing: SupplementTiming(kind: .daily, days: nil,
                                            times: [TimeOfDay(hour: 9, minute: 0)],
                                            offsetMinutes: nil, mealCount: nil),
                   stackId: "st_post", instructions: nil, quantityOnHand: 40, reorderURL: nil),
        Supplement(id: "sup_gluco", name: "Glucosamine",
                   dose: Dose(amount: 1, unit: .tablet),
                   timing: SupplementTiming(kind: .fixedDays,
                                            days: [.mon, .wed, .fri],
                                            times: [TimeOfDay(hour: 8, minute: 0)],
                                            offsetMinutes: nil, mealCount: nil),
                   stackId: nil, instructions: "with breakfast", quantityOnHand: 60, reorderURL: nil),
    ]

    static let supplementLogs: [SupplementLog] = (1...20).compactMap { i in
        guard i % 3 != 0 else { return nil }   // a couple of gaps for realism
        return SupplementLog(id: "log_\(i)", supplementId: "sup_creatine",
                             scheduledFor: day(-i), takenAt: day(-i), status: .taken)
    }

    // Realistic HealthKit-style session vitals for the demo — a warmup ramp, heavy
    // sets spiking HR, brief recoveries between, and a cooldown. Used in demo mode so
    // the Session Vitals card + sparkline populate without a device or real Health data.
    static func vitals(for workout: Workout) -> WorkoutVitals {
        let start = workout.date
        let durationMin = 52
        let end = Calendar.current.date(byAdding: .minute, value: durationMin, to: start) ?? start

        // Build a believable HR curve: ~95 warmup, climbing to spikes near 168 on top
        // sets, dipping to ~120 in rest, tapering at the end.
        var series: [HeartRateSample] = []
        let points = 96
        for i in 0..<points {
            let t = Double(i) / Double(points - 1)            // 0…1 across the session
            let base = 96 + 46 * sin(t * .pi)                 // arch: low → high → low
            let setWave = 16 * sin(t * .pi * 9)               // per-set spikes/recoveries
            let jitter = Double(Int.random(in: -3...3))
            let bpm = Int(max(88, min(172, base + setWave + jitter)))
            let time = Calendar.current.date(byAdding: .second, value: Int(t * Double(durationMin * 60)), to: start) ?? start
            series.append(HeartRateSample(time: time, bpm: bpm))
        }
        let bpms = series.map { $0.bpm }
        return WorkoutVitals(
            start: start, end: end, durationMinutes: durationMin,
            avgHeartRate: bpms.reduce(0, +) / bpms.count,
            peakHeartRate: bpms.max(),
            activeCalories: 470,
            heartRateSeries: series)
    }

    // Realistic per-exercise heart-rate summary for the demo (History tab). Compound
    // lifts drive HR higher than accessories, so the numbers feel believable.
    static func exerciseHR(for exerciseName: String) -> (avg: Int, peak: Int) {
        let n = exerciseName.lowercased()
        let heavy = ["squat", "deadlift", "bench", "press", "row", "clean"]
        let isCompound = heavy.contains { n.contains($0) }
        if isCompound {
            return (avg: Int.random(in: 138...148), peak: Int.random(in: 162...172))
        } else {
            return (avg: Int.random(in: 118...128), peak: Int.random(in: 138...150))
        }
    }

    // Deterministic per-session HR for the History across-dates graph. Seeded by the
    // session id so the line is stable between redraws (not re-randomized each frame).
    static func sessionHR(exerciseName: String, sessionId: String, index: Int, total: Int) -> (avg: Int, peak: Int) {
        let base = exerciseHR(for: exerciseName)
        // Gentle downward drift in HR over time = improving conditioning for the same lift.
        let trend = total > 1 ? (Double(total - 1 - index) / Double(total - 1)) * 8.0 : 0
        let wobble = Double((abs(sessionId.hashValue) % 7) - 3)
        return (avg: base.avg + Int(trend) + Int(wobble),
                peak: base.peak + Int(trend) + Int(wobble))
    }

    // Deterministic per-set HR for the Workouts by-set graph. HR climbs across sets
    // within a session as fatigue accumulates, seeded by set id for stability.
    static func setHR(exerciseName: String, setId: String, setIndex: Int, totalSets: Int) -> (avg: Int, peak: Int) {
        let base = exerciseHR(for: exerciseName)
        // Ramp: later sets run hotter.
        let ramp = totalSets > 1 ? Double(setIndex) / Double(totalSets - 1) : 0
        let climb = Int(ramp * 14)
        let wobble = Double((abs(setId.hashValue) % 5) - 2)
        return (avg: base.avg - 6 + climb + Int(wobble),
                peak: base.peak - 4 + climb + Int(wobble))
    }
}
