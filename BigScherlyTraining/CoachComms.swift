import SwiftUI
import Combine

// MARK: - Communications (Oct 11, 2026)
// The coach menus (phone COMMUNICATIONS group, iPad sidebar, Coach HQ on the web) gather
//   Inbox          email to coach@ (Oct 15: live in the apps, CoachMail.swift / CoachMailViews.swift / CoachPad/PadMail.swift)
//   Messages       the app's chat with clients (was Inbox on iPad and the web, Chat on the phone)
//   Check-ins
//   Announcements
// each with its own badge. Synchronized folder: no target step needed.

/// Badge counts that don't come with the roster.
@MainActor
final class CommsBadges: ObservableObject {
    static let shared = CommsBadges()
    /// Announcements scheduled to go out later.
    @Published var scheduledAnnouncements = 0
    /// Unread email from people (automatic mail doesn't count), set by MailBox.poll.
    @Published var unreadMail = 0
    private var last = Date.distantPast

    /// Cheap to call often: it asks the server at most once a minute unless forced.
    func refresh(force: Bool = false) {
        let store = AppStore.shared
        guard store.isTrainer, !store.isDemoMode else { return }
        guard force || Date().timeIntervalSince(last) > 60 else { return }
        last = Date()
        Task {
            if let a = try? await APIClient.shared.adminAnnouncementsWithReads() {
                let now = Date()
                scheduledAnnouncements = a.filter { ($0.publishAt ?? .distantPast) > now }.count
            }
            await MailBox.shared.poll(force: force)
        }
    }
}
