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

    /// The congratulations — shown on the celebration, the badge and the detail screen.
    var blurb: String {
        switch self {
        case .perfectWeek:        return "Every single workout, every single thing your coach asked for — done. Not one missed. That's a perfect week."
        case .perfectMonth:       return "Four perfect weeks, back to back. This isn't motivation anymore — it's who you are."
        case .streak4:            return "Four straight weeks without missing a beat. The habit is officially built."
        case .streak12:           return "Twelve weeks in a row. Three months of showing up, no excuses. That's elite."
        case .doseStreak30:       return "Thirty days straight, every one on time. That kind of discipline is rare — be proud of it."
        case .workouts10:         return "Ten workouts in the books! The hardest part was starting, and you're officially rolling."
        case .workouts25:         return "Twenty-five sessions deep. You're not trying it out anymore — you're doing it."
        case .workouts50:         return "FIFTY workouts. Halfway to triple digits and stronger with every single one."
        case .workouts100:        return "One hundred workouts. Let that sink in. This is a lifestyle now."
        case .workouts250:        return "Two hundred and fifty sessions. Veteran status unlocked — absolute legend."
        case .millionPounds:      return "ONE MILLION POUNDS moved. You've lifted the weight of a house. Several, honestly."
        case .firstPR:            return "Your first personal record! The strongest you've ever been — and it's only the first of many."
        case .upAcrossTheBoard:   return "Heavier on every main lift in a single week. No weak links — you're getting strong everywhere."
        case .tripleCrown:        return "PRs on squat, bench AND deadlift in one block. The crown is yours — you earned it."
        case .thousandPoundClub:  return "Squat, bench and deadlift now total over 1,000 lb. Four digits. Welcome to the club."
        case .fullSend:           return "Every prescribed set hit at or above target. No rep left behind — that's how it's done."
        case .comeback:           return "You came back — and that's the hardest set of all. So proud of you for showing up again."
        }
    }

    /// A short shout for the badge itself.
    var cheer: String {
        switch self {
        case .perfectWeek:        return "Flawless!"
        case .perfectMonth:       return "Untouchable!"
        case .streak4:            return "On a roll!"
        case .streak12:           return "Unstoppable!"
        case .doseStreak30:       return "Locked in!"
        case .workouts10:         return "Ten down!"
        case .workouts25:         return "Twenty-five strong!"
        case .workouts50:         return "Fifty & fierce!"
        case .workouts100:        return "Triple digits!"
        case .workouts250:        return "Legendary!"
        case .millionPounds:      return "Seven figures!"
        case .firstPR:            return "Record breaker!"
        case .upAcrossTheBoard:   return "Stronger everywhere!"
        case .tripleCrown:        return "Crowned!"
        case .thousandPoundClub:  return "Welcome to the club!"
        case .fullSend:           return "Full send!"
        case .comeback:           return "Welcome back!"
        }
    }

    /// How to earn it — shown on locked awards. Encouraging, never preachy.
    var howTo: String {
        switch self {
        case .perfectWeek:        return "Finish every workout your coach plans in a week, nothing missed."
        case .perfectMonth:       return "String four perfect weeks together, back to back."
        case .streak4:            return "Train at least once a week, four weeks running."
        case .streak12:           return "Train at least once a week for twelve straight weeks."
        case .doseStreak30:       return "Thirty days in a row, every dose on time. Private — just you and your coach."
        case .workouts10:         return "Complete 10 workouts."
        case .workouts25:         return "Complete 25 workouts."
        case .workouts50:         return "Complete 50 workouts."
        case .workouts100:        return "Complete 100 workouts."
        case .workouts250:        return "Complete 250 workouts."
        case .millionPounds:      return "Move 1,000,000 lb in total across every set you log."
        case .firstPR:            return "Set your first personal record on a main lift."
        case .upAcrossTheBoard:   return "Go heavier on every main lift in the same week."
        case .tripleCrown:        return "PR your squat, bench and deadlift within one 12-week block."
        case .thousandPoundClub:  return "Get your squat, bench and deadlift to total 1,000 lb (estimated 1RMs)."
        case .fullSend:           return "Hit every prescribed set at or above target in one workout."
        case .comeback:           return "Come back and train after 14+ days away. It counts — big time."
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
