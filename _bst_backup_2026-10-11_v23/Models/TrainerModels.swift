import Foundation
import SwiftUI

// The trainer app's sections, shown in the slide-in tray (same nav pattern as the
// client app — no bottom tab bar). Order here is the order they appear in the tray.
enum TrainerTab: String, CaseIterable, Identifiable {
    case today     = "Today"
    case clients   = "Clients"
    case chat      = "Chat"
    case checkins  = "Check-In Queue"
    case wins      = "Wins"
    case share     = "Share"
    case insights  = "Insights"
    case announce  = "Announcements"
    case me        = "Me"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today:     return "sun.max.fill"
        case .clients:   return "person.2.fill"
        case .chat:      return "bubble.left.and.bubble.right.fill"
        case .checkins:  return "checkmark.square.fill"
        case .wins:      return "trophy.fill"
        case .share:     return "square.and.arrow.up.fill"
        case .insights:  return "chart.bar.fill"
        case .announce:  return "megaphone.fill"
        case .me:        return "gearshape.fill"
        }
    }
}

// MARK: - Trainer models
//
// The trainer app is a READ + RESPOND tool, not an authoring tool. Building programs
// happens in the web console where a calendar and a set editor actually fit on screen.
// On the phone, the job is: who needs me, what do they need, answer it.

struct RosterItem: Identifiable, Decodable {
    let id: String
    let name: String
    let goal: String
    let unreadMessages: Int
    let pendingCheckIns: Int
    let missedWorkouts: Int
    let workoutsThisWeek: Int
    let daysSinceTrained: Int
    let recentAwards: Int
    let attentionScore: Int

    /// Does this person need the trainer to actually do something?
    var needsAttention: Bool {
        unreadMessages > 0 || pendingCheckIns > 0
    }

    /// Quietly drifting — nothing to answer, but they've gone missing.
    var isDrifting: Bool {
        !needsAttention && (daysSinceTrained >= 7 || missedWorkouts >= 2)
    }

    /// The single most important thing to say about this client right now.
    var headline: String {
        if unreadMessages > 0 {
            return "\(unreadMessages) unread message\(unreadMessages == 1 ? "" : "s")"
        }
        if pendingCheckIns > 0 {
            return "\(pendingCheckIns) check-in\(pendingCheckIns == 1 ? "" : "s") to review"
        }
        if daysSinceTrained >= 7 {
            return "Hasn't trained in \(daysSinceTrained) days"
        }
        if missedWorkouts >= 2 {
            return "\(missedWorkouts) missed workouts"
        }
        if recentAwards > 0 {
            return "\(recentAwards) award\(recentAwards == 1 ? "" : "s") this week"
        }
        return "\(workoutsThisWeek) workout\(workoutsThisWeek == 1 ? "" : "s") this week"
    }

    var statusColor: Color {
        if needsAttention { return Brand.volt }
        if isDrifting { return .orange }
        return Brand.mute
    }
}

struct RosterAward: Identifiable, Decodable {
    var id: String { "\(clientId)_\(kind)" }
    let clientId: String
    let clientName: String
    let kind: String
    let title: String
    let blurb: String
    let icon: String
    let earnedAt: Date
}

// A pending check-in with the client it belongs to, for the cross-roster queue.
struct QueuedCheckIn: Identifiable, Decodable {
    var id: String { checkIn.id }
    let checkIn: APICheckIn
    let clientId: String
    let clientName: String
}

struct ClientNote: Decodable {
    let body: String
    let updatedAt: Date
}

// Derived on-device from the roster — no extra endpoint needed.
struct RosterInsights {
    var totalClients: Int
    var needingAttention: Int
    var drifting: Int
    var workoutsThisWeek: Int
    var awardsThisWeek: Int
    var avgDaysSinceTrained: Int
}
