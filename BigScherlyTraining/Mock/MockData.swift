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
        func sets(_ reps: Int, _ w: Double, _ n: Int, logged: Bool) -> [ExerciseSet] {
            (0..<n).map { i in
                ExerciseSet(id: "s\(i)", targetReps: reps, targetWeight: w,
                            loggedReps: logged ? reps : nil,
                            loggedWeight: logged ? w : nil,
                            rpe: logged ? Int.random(in: 6...9) : nil)
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
                     restSeconds: rest)
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
        ]
    }()

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
        CheckIn(id: "ci1", date: day(-3), status: .reviewed, photoIDs: ["p1","p2"],
                fields: [CheckInField(id:"f1",label:"Weight",value:"214 lb"),
                         CheckInField(id:"f2",label:"Energy (1-10)",value:"8")],
                trainerResponse: "Great week — squat looked crisp. Bumping your protein 10g and holding carbs. Keep sleep locked in."),
        CheckIn(id: "ci2", date: day(-10), status: .reviewed, photoIDs: ["p3"],
                fields: [CheckInField(id:"f3",label:"Weight",value:"216 lb")],
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
                     body:"We're running a 4-week strength push. Hit a PR on any main lift and tag #bigscherlytraining to get featured. Let's get big together, queens 👑"),
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
}
