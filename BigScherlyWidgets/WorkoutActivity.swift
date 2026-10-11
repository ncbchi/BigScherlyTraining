import Foundation
import ActivityKit
import AppIntents

// MARK: - Workout Live Activity: shared between the app and the widget extension
//
// Target membership: BOTH BigScherlyTraining and BigScherlyWidgetsExtension.
//
// The left pane drives the set loop:  rest → Start set → lifting → set done → Log set → rest.
// The right pane shows data: seven views, picked with the icon row or the ‹ › arrows.
// Buttons run the intents at the bottom. LiveActivityIntents always run inside the APP's
// process (iOS wakes it in the background if needed); the app installs
// LiveIntentRouter.handler at launch, and in the extension it stays nil.

/// The data views on the right of the card.
nonisolated enum LiveView: String, Codable, Hashable, CaseIterable, Sendable {
    case heartRate, speed, travel, tempo, pause, sets, session

    var title: String {
        switch self {
        case .heartRate: return "HEART RATE"
        case .speed: return "BAR SPEED"
        case .travel: return "BAR TRAVEL"
        case .tempo: return "TEMPO"
        case .pause: return "PAUSE"
        case .sets: return "SETS"
        case .session: return "SESSION"
        }
    }

    /// SF Symbol for the icon row.
    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .travel: return "arrow.up.and.down"
        case .tempo: return "metronome"
        case .pause: return "pause"
        case .sets: return "list.bullet"
        case .session: return "flag.checkered"
        }
    }

    /// True for the views that show the last set's Watch data.
    var isSensor: Bool { self == .speed || self == .travel || self == .tempo || self == .pause }
}

/// Where you are in the set loop (the left pane).
nonisolated enum LiveStage: String, Codable, Hashable, Sendable {
    case ready      // rest is over (or first set): "Start set N"
    case resting    // rest border counting down
    case lifting    // set timer + Log set
    case done       // every set logged
}

/// One row of the Sets view.
nonisolated struct LiveSetRow: Codable, Hashable, Sendable {
    var n: Int
    var tReps: Int
    var tWeight: Double            // display units
    var reps: Int?
    var weight: Double?            // display units
    var rpe: Double?
    var current: Bool
    var tText: String? = nil       // the plan's reps × weight as the app works it out: "3 × 170", "3 × —" (optional: older payloads decode)
}

nonisolated struct WorkoutActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        // Left pane: the set loop
        var stage: LiveStage = .ready
        var startedAt: Date
        var exercise: String = ""
        var setNumber: Int = 1
        var setCount: Int = 1
        var goalReps: Int = 0
        var goalWeight: Double = 0     // display units
        var unit: String = "lb"
        var restStart: Date? = nil
        var restEnd: Date? = nil       // also the card's stale date: iOS redraws as "Start set" then
        var setStart: Date? = nil      // lifting
        var logNeeded: Bool = false    // the Watch saw the set end, but it isn't logged yet

        // Right pane
        var view: LiveView = .sets
        var accent: UInt32? = nil         // your theme accent (already readable on the card's black)
        var accentInkWhite: Bool? = nil   // text on the accent: white (dark accents) or black
        // Your theme's look on the Lock Screen card (optional: older payloads decode)
        var light: Bool? = nil            // true = Light, false = Dark, nil = follow the Lock Screen (System)
        var fill: UInt32? = nil           // light card: the accent as a fill (the real accent)
        var fillInkWhite: Bool? = nil     // light card: white text on that fill (dark accents) or black
        var lineLight: UInt32? = nil      // light card: accent lines — grey for pale accents (Volt, Toxic, Ice, Amber)
        var headLight: UInt32? = nil      // light card: the accent on the smoke-pill labels
        var available: [LiveView] = []
        var afterSet: Bool = false     // showing the set you just did (until the next set starts)
        var liveSet: Bool? = nil       // the sensor views show the set in progress, rep by rep (optional: older payloads decode)

        // Heart rate (Apple Watch)
        var hr: Int? = nil
        var hrPeak: Int? = nil
        var hrPct: Int? = nil          // % of max
        var hrZone: Int? = nil         // 1–5
        var hrSpark: [Int] = []        // last 5 minutes, one reading every ~5 s
        var hrMax: Int? = nil          // for the zone lines on the graph

        // Last set (Apple Watch motion)
        var lastSet: String? = nil     // "Back Squat · Set 2"
        var speeds: [Double] = []      // m/s per rep
        var peakSpeed: Double? = nil
        var speedLoss: Int? = nil      // %
        var effort: String? = nil
        var travel: [Double] = []      // in or cm per rep
        var travelUnit: String = "in"
        var travelConsistency: Int? = nil
        var ecc: [Double] = []         // seconds per rep
        var pause: [Double] = []
        var con: [Double] = []
        var top: [Double] = []
        var tempo: String? = nil       // "3-1-1-0"
        var pauseAvg: Double? = nil
        var pauseTarget: Double? = nil

        // Sets in this exercise
        var rows: [LiveSetRow] = []

        // Session
        var exDone: Int = 0
        var exTotal: Int = 0
        var setsDone: Int = 0
        var setsTotal: Int = 0
        var volume: Int = 0            // display units
        var upNext: String? = nil

        // Predicted results, so a tap can show its outcome instantly (before the app runs)
        var nextReps: Int = 0          // the next set's planned reps
        var nextWeight: Double = 0     // display units
        var nextRPE: Double = 8
        var restSeconds: Int = 0       // this exercise's rest (Log set → rest border)
        var afterSaveView: LiveView = .sets   // the right pane after Log set

        // The set waiting to be logged (logNeeded): filled in, nothing to enter on the card.
        // dReps: the Watch's count (or the plan) · dWeight: last set's weight plus the plan's step ·
        // dRPE: estimated from how the set went. The Watch reads these same fields for its log tile.
        var editing: Bool = false      // always false now (no editor on the card); the Watch still reads it
        var editorAuto: Bool = false
        var editorUntil: Date? = nil
        var editSet: Int = 1           // the set's number
        var dReps: Int = 0
        var dWeight: Double = 0        // display units
        var dRPE: Double = 8
        var editStep: Int? = nil       // unused (kept so older payloads decode)
        var repsPage: Int? = nil       // unused (kept so older payloads decode)
        // Optional: older payloads decode.
        var rpeWhy: String? = nil      // "speed dropped 22% · last rep a grind"
        var doneByWatch: Bool? = nil   // true: the Watch saw the set end · false: you ended it
        var editLink: String? = nil    // Edit: opens the app on this set, reps selected
        // Settings ▸ Lock Screen & Dynamic Island (optional: older payloads decode)
        var island: String? = nil      // the Dynamic Island's right pill: "hr" · "sets" · "rest"
        var afterSetMode: String? = nil // after a set: "ask" (Log set + Edit) · "auto" (logs itself) · "off"
        var autoLogAt: Date? = nil     // "auto": when the set logs itself (the card counts down to it)
        // Set types (optional: older payloads decode). The app works out the weight (SetTarget);
        // these are the same "reps × weight" as always, with that weight in it.
        var goalText: String? = nil    // the set you're on: "5 × 275 lb", "3 × 170 lb", "3 × —"
        var nextGoalText: String? = nil // the set after it in this exercise (Log set's instant preview)
    }

    var workoutId: String
    var title: String
}

// MARK: - Button actions

nonisolated enum LiveAction: Sendable {
    case prevView, nextView
    case show(LiveView)
    case startSet
    case rest(seconds: Int)            // 0 = skip
    case log(String)                   // end (finish the set you're lifting), commit (log the filled-in set)
}

nonisolated enum LiveIntentRouter {
    /// Installed by the app at launch. Never called inside the widget extension.
    nonisolated(unsafe) static var handler: (@Sendable (LiveAction) async -> Void)?
}

// One small action per button. (No changeable parameters: those clash with running safely
// in the background, and are an error in Swift 6.) Hidden from the Shortcuts app.

nonisolated struct LiveStartSetIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start the next set"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool    // instant-preview switch
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.startSet); return .result() }
}

nonisolated struct LiveRestPlus30Intent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 30 seconds of rest"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool    // instant-preview switch
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.rest(seconds: 30)); return .result() }
}

nonisolated struct LiveSkipRestIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool    // instant-preview switch
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.rest(seconds: 0)); return .result() }
}

nonisolated struct LiveEndSetIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "End the set"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool    // instant-preview switch
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.log("end")); return .result() }
}

nonisolated struct LiveLogCommitIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Log the set"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool    // instant-preview switch
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.log("commit")); return .result() }
}

// View selector and the set-loop controls: on/off switches (iOS redraws a switch the instant it's tapped, before the
// app runs). Each icon is a switch that's normally off; its "on" look is that view's
// content, so the view appears immediately and the app's update follows.
// (Note: switch actions need a changeable `value`, which Swift 5 accepts with a warning.)

nonisolated struct LiveSelectHeartRateIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show heart rate"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.heartRate)); return .result() }
}

nonisolated struct LiveSelectSpeedIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show bar speed"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.speed)); return .result() }
}

nonisolated struct LiveSelectTravelIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show bar travel"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.travel)); return .result() }
}

nonisolated struct LiveSelectTempoIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show tempo"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.tempo)); return .result() }
}

nonisolated struct LiveSelectPauseIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show pause"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.pause)); return .result() }
}

nonisolated struct LiveSelectSetsIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show sets"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.sets)); return .result() }
}

nonisolated struct LiveSelectSessionIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Show session"
    static let isDiscoverable = false          // card buttons only — not listed in Shortcuts
    @Parameter(title: "On") var value: Bool
    init() {}
    func perform() async throws -> some IntentResult { await LiveIntentRouter.handler?(.show(.session)); return .result() }
}
