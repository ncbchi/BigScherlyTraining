import Foundation
import Combine

// MARK: - Share log
// Remembers which workouts were shared to social media (and where), so the Stats
// calendar can mark them. Recorded by the Share tab when a share actually goes out:
// the Instagram/Facebook story composer opening, or the share sheet finishing on a
// social app. Saving to Photos or texting a friend isn't counted.
// Stored on this device; cleared on logout.

@MainActor
final class ShareLog: ObservableObject {
    static let shared = ShareLog()

    struct Entry: Codable, Equatable {
        var workoutDay: Date      // start of the day of the workout that was shared
        var sharedAt: Date
        var platform: String      // "Instagram", "Facebook", "X"…
    }

    @Published private(set) var entries: [Entry] = []
    private let key = "bst_share_log"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    func record(workoutDate: Date, platform: String) {
        entries.append(Entry(workoutDay: Calendar.current.startOfDay(for: workoutDate),
                             sharedAt: Date(), platform: platform))
        save()
    }

    /// Platforms the workout on this day was shared to (deduplicated, in order).
    func platforms(on day: Date) -> [String] {
        let d = Calendar.current.startOfDay(for: day)
        var seen: [String] = []
        for e in entries where e.workoutDay == d && !seen.contains(e.platform) { seen.append(e.platform) }
        return seen
    }

    func reset() {
        entries = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Friendly name for a share-sheet destination, or nil if it isn't a social platform.
    nonisolated static func platformName(forActivity raw: String?) -> String? {
        guard let r = raw?.lowercased() else { return nil }
        let map: [(String, String)] = [
            ("instagram", "Instagram"), ("burbn.barcelona", "Threads"), ("threads", "Threads"),
            ("facebook", "Facebook"), ("tweetie", "X"), ("twitter", "X"),
            ("musically", "TikTok"), ("tiktok", "TikTok"), ("bluesky", "Bluesky"),
            ("picaboo", "Snapchat"), ("snapchat", "Snapchat"), ("linkedin", "LinkedIn"),
            ("reddit", "Reddit"), ("tumblr", "Tumblr"), ("pinterest", "Pinterest")
        ]
        return map.first { r.contains($0.0) }?.1
    }
}
