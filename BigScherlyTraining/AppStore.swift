import SwiftUI
import Combine

// MARK: - App Store
// Single source of truth for the prototype's in-memory state. In production this
// becomes the layer that calls the API and caches responses.
final class AppStore: ObservableObject {
    @Published var isLoggedIn = false
    @Published var showTray = false

    @Published var client = MockData.client
    @Published var workouts = MockData.workouts
    @Published var macroDays = MockData.macroDays
    @Published var checkIns = MockData.checkIns
    @Published var photos = MockData.photos
    @Published var chats = MockData.chats
    @Published var announcements = MockData.announcements
    @Published var shareStats = MockData.shareStats

    @Published var activeTab: AppTab = .dashboard

    // Login photo board — trainer-curated shots (see conversation note on IG)
    let boardPhotos = ["board1","board2","board3","board4","board5","board6"]

    // Derived
    var upcomingWorkouts: [Workout] {
        workouts.filter { !$0.completed }.sorted { $0.date < $1.date }
    }
    var pastWorkouts: [Workout] {
        workouts.filter { $0.completed }.sorted { $0.date > $1.date }
    }
    var todayMacros: MacroDay? {
        macroDays.first { Calendar.current.isDateInToday($0.date) } ?? macroDays.first
    }
    var unreadMessages: Int { chats.reduce(0) { $0 + $1.unread } }
    var liveAnnouncements: [Announcement] {
        announcements.filter { !$0.cleared }.sorted { $0.date > $1.date }
    }

    func login() { withAnimation(.easeOut(duration: 0.4)) { isLoggedIn = true } }

    // MARK: Exercise history
    // In the prototype this is generated so the table + graph are populated.
    // In production it comes from the API (every logged set is already stored).
    func history(for exerciseName: String) -> [ExerciseHistorySession] {
        // Seed a deterministic starting weight per lift so it's stable across views
        let base: Double
        switch exerciseName {
        case "Back Squat": base = 225
        case "Bench Press": base = 165
        case "Deadlift": base = 275
        case "Romanian Deadlift": base = 155
        case "Overhead Press": base = 95
        case "Front Squat": base = 155
        default: base = 135
        }
        var sessions: [ExerciseHistorySession] = []
        let reps = 5
        // 10 sessions over the past ~20 weeks, trending up with small noise
        for i in stride(from: 10, through: 1, by: -1) {
            let weeksAgo = i * 2
            let date = Calendar.current.date(byAdding: .day, value: -weeksAgo * 7, to: Date())!
            let progress = Double(10 - i) * 5.0            // +5lb every couple weeks
            let noise = Double((i * 7) % 3) * 2.5 - 2.5    // small deterministic wobble
            let working = base + progress + noise
            let setCount = 4
            let sets = (0..<setCount).map { s in
                LoggedSetRecord(id: "h\(i)-\(s)", reps: reps,
                                weight: working - Double(s) * 0,   // flat working sets
                                rpe: min(10, 7 + (s == setCount-1 ? 2 : s % 2)))
            }
            sessions.append(ExerciseHistorySession(id: "hist\(i)", date: date, sets: sets))
        }
        return sessions.sorted { $0.date < $1.date }
    }
    func logout() { isLoggedIn = false; showTray = false; activeTab = .dashboard }

    func clearAnnouncement(_ id: String) {
        if let i = announcements.firstIndex(where: { $0.id == id }) {
            announcements[i].cleared = true
        }
    }
    func select(_ tab: AppTab) {
        activeTab = tab
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showTray = false }
    }
}

// MARK: - Navigation tabs (order matches the requested tray layout)
enum AppTab: String, CaseIterable, Identifiable {
    case dashboard   = "Home"
    case workouts    = "Workouts"
    case history     = "History"
    case macros      = "Macros"
    case checkins    = "Check-Ins"
    case photos      = "Photos"
    case chat        = "Chat"
    case announcements = "Announcements"
    case share       = "Share"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .workouts: return "dumbbell.fill"
        case .history: return "chart.line.uptrend.xyaxis"
        case .macros: return "chart.bar.fill"
        case .checkins: return "checkmark.seal.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .announcements: return "megaphone.fill"
        case .share: return "square.and.arrow.up.fill"
        }
    }
}
