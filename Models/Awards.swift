import Foundation

// MARK: - Awards
//
// Milestones derived from what the client actually did — completed workouts, logged
// sets, and (privately) supplement adherence. Nothing is awarded for merely opening the app.
//
// PRIVACY RULE — supplements never surface in an award's title, blurb, stats, or share
// card. Adherence can gate an award internally (Perfect Week requires it), but the
// client's protocol is nobody else's business: someone sharing a win should never be
// outing themselves as being on a given supplement or prescription. If you add an award,
// it must be displayable without disclosing anything about what they take.
//
// Each award is earned ONCE, ever. The engine re-evaluates from full history, so an
// award can't be double-granted, and re-installing the app rebuilds the same trophy case.

enum AwardKind: String, Codable, CaseIterable, Identifiable {
    // Consistency
    case perfectWeek
    case perfectMonth
    case streak4
    case streak12
    case doseStreak30
    // Volume
    case workouts10, workouts25, workouts50, workouts100, workouts250
    case millionPounds
    // Strength
    case firstPR
    case upAcrossTheBoard
    case tripleCrown
    case thousandPoundClub
    // Effort
    case fullSend
    case comeback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perfectWeek:        return "Perfect Week"
        case .perfectMonth:       return "Perfect Month"
        case .streak4:            return "4-Week Streak"
        case .streak12:           return "12-Week Streak"
        case .doseStreak30:       return "Never Missed a Dose"
        case .workouts10:         return "10 Workouts"
        case .workouts25:         return "25 Workouts"
        case .workouts50:         return "50 Workouts"
        case .workouts100:        return "100 Workouts"
        case .workouts250:        return "250 Workouts"
        case .millionPounds:      return "Million Pound Club"
        case .firstPR:            return "First PR"
        case .upAcrossTheBoard:   return "Up Across the Board"
        case .tripleCrown:        return "Triple Crown"
        case .thousandPoundClub:  return "1,000 lb Club"
        case .fullSend:           return "Full Send"
        case .comeback:           return "Comeback"
        }
    }

    var blurb: String {
        switch self {
        case .perfectWeek:        return "Every workout done. Everything your coach asked for. Nothing missed."
        case .perfectMonth:       return "Four perfect weeks back to back. That's a habit now."
        case .streak4:            return "Four straight weeks of training. No gaps."
        case .streak12:           return "Twelve straight weeks. This is who you are now."
        case .doseStreak30:       return "Thirty days. Every single one, on time."
        case .workouts10:         return "Ten workouts in the books. You've started."
        case .workouts25:         return "Twenty-five sessions deep."
        case .workouts50:         return "Fifty workouts. Halfway to triple digits."
        case .workouts100:        return "Triple digits. Not a phase anymore."
        case .workouts250:        return "Two hundred and fifty sessions. Veteran status."
        case .millionPounds:      return "One million pounds moved. Cumulatively, you've lifted a house."
        case .firstPR:            return "Your first personal record. The first of many."
        case .upAcrossTheBoard:   return "Heavier on every main lift this week."
        case .tripleCrown:        return "PR'd the squat, bench, and deadlift in one block."
        case .thousandPoundClub:  return "Squat, bench, and deadlift now total over 1,000 lb."
        case .fullSend:           return "Every prescribed set, at or above target. No rep left behind."
        case .comeback:           return "You came back. That's the hardest set of all."
        }
    }

    /// SF Symbol shown in the badge.
    var icon: String {
        switch self {
        case .perfectWeek, .perfectMonth:            return "flame.fill"
        case .streak4, .streak12:                    return "calendar.badge.checkmark"
        case .doseStreak30:                          return "checkmark.seal.fill"
        case .workouts10, .workouts25, .workouts50:  return "dumbbell.fill"
        case .workouts100, .workouts250:             return "trophy.fill"
        case .millionPounds:                         return "scalemass.fill"
        case .firstPR:                               return "rosette"
        case .upAcrossTheBoard:                      return "chart.line.uptrend.xyaxis"
        case .tripleCrown:                           return "crown.fill"
        case .thousandPoundClub:                     return "medal.fill"
        case .fullSend:                              return "bolt.fill"
        case .comeback:                              return "arrow.uturn.up"
        }
    }

    /// Whether this award may appear on a shared image. "Never Missed a Dose" is
    /// celebrated in-app but never shared: its title alone would tell the world the
    /// client is on a supplement protocol, which is their business and no one else's.
    var isShareable: Bool {
        self != .doseStreak30
    }

    /// Target used for the progress bars on locked awards (nil = not a countable goal).
    var goal: Int? {
        switch self {
        case .workouts10:   return 10
        case .workouts25:   return 25
        case .workouts50:   return 50
        case .workouts100:  return 100
        case .workouts250:  return 250
        case .streak4:      return 4
        case .streak12:     return 12
        case .doseStreak30: return 30
        default:            return nil
        }
    }
}

struct Award: Identifiable, Codable, Equatable {
    var id: String { kind.rawValue }
    var kind: AwardKind
    var earnedAt: Date
    /// Concrete proof shown on the celebration, e.g. ("7/7", "WORKOUTS").
    /// May include private stats — use `shareStats` for anything leaving the app.
    var stats: [AwardStat]

    var title: String { kind.title }
    var blurb: String { kind.blurb }
    var icon: String { kind.icon }

    /// Stats safe to render on a shared image — private ones are stripped.
    var shareStats: [AwardStat] { stats.filter { !$0.isPrivate } }

    /// Can this award be shown on a share card at all? Anything whose very name
    /// discloses the client's supplement protocol cannot.
    var isShareable: Bool { kind.isShareable }
}

struct AwardStat: Codable, Equatable, Identifiable {
    var id: String { label }
    var value: String
    var label: String
    /// Shown in-app, never on a shared image (e.g. supplement dose counts).
    var isPrivate: Bool = false
}

/// Progress toward an award the client hasn't earned yet.
struct AwardProgress: Identifiable {
    var id: String { kind.rawValue }
    var kind: AwardKind
    var current: Int
    var goal: Int
    var fraction: Double { goal == 0 ? 0 : min(1, Double(current) / Double(goal)) }
}
