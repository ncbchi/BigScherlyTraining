import SwiftUI
import Combine

// MARK: - Server 2.3.0 (Oct 11, 2026)
//
// Everything the app uses from server 2.3.0, kept out of APIClient.swift:
//  · client accents (the phone sends its accent; the coach's iPad fills avatars with it)
//  · announcements to a group, and who has read them
//  · reply time and retention for Insights
//  · the coach's phone theme, which the iPad can follow (ThemeSync below)
// Before 2.3.0 is installed, ServerVersion.has23 is false and every caller falls back to what it did before
// (a group post still goes as messages, so it can never land on everyone's Home by mistake).
// Synchronized folder: no target step needed.

// MARK: Models

struct APIAnnouncementRead: Decodable {
    let clientId: String
    let readAt: Date
}

/// The coach's list. `audience` nil = everyone; `audienceIds` is who that meant when it went out.
struct APIAdminAnnouncement: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let createdAt: Date
    let publishAt: Date?
    let audience: [String]?
    let audienceLabel: String?
    let audienceIds: [String]?
    let reads: [APIAnnouncementRead]?

    var isEveryone: Bool { audience == nil }
    var readIds: Set<String> { Set((reads ?? []).map { $0.clientId }) }
    /// Who it went to that hasn't opened it.
    var unreadIds: [String] { (audienceIds ?? []).filter { !readIds.contains($0) } }
    var hasReceipts: Bool { reads != nil && audienceIds != nil }
}

struct APIReplyWeek: Decodable {
    let weekStart: Date
    let medianHours: Double?
    let replies: Int
}

struct APIReplyClient: Decodable {
    let clientId: String
    let medianHours: Double?
    let replies: Int
    let waitingSince: Date?
}

struct APIReplyInsights: Decodable {
    let weeks: [APIReplyWeek]
    let medianHours: Double?
    let prevMedianHours: Double?
    let replies: Int
    let within24hPct: Int?
    let readMedianHours: Double?
    let byClient: [APIReplyClient]
}

struct APIRetentionEvent: Decodable {
    let status: String
    let at: Date
    let backfilled: Bool
}

struct APIRetentionClient: Decodable, Identifiable {
    let clientId: String
    let name: String
    let status: String
    let start: Date
    let endedAt: Date?
    let months: Double
    let events: [APIRetentionEvent]
    var id: String { clientId }
}

struct APIRetention: Decodable {
    let activeNow: Int
    let pausedNow: Int
    let endedLast12Months: Int
    let startedLast12Months: Int
    let averageStayMonths: Double?
    let stayed90Pct: Int?
    let historyFrom: Date?
    let clients: [APIRetentionClient]
}

/// The coach's phone theme, as saved under the coachTheme setting.
struct CoachThemeSnapshot: Codable, Equatable {
    var choice: String
    var base: String
    var accent: String
    var trueBlack: Bool
    var highContrast: Bool
}

// MARK: Which server is this?

/// Asks /version once (again after 10 minutes, so installing 2.3.0 is noticed without a relaunch).
enum ServerVersion {
    private static var version: String?
    private static var checkedAt: Date?

    static func current() async -> String? {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < 600 { return version }
        struct V: Decodable { let server: String? }
        if let data = try? await APIClient.shared.request("/version", method: "GET"),
           let v = try? JSONDecoder().decode(V.self, from: data) {
            version = v.server
            checkedAt = Date()
        }
        return version
    }

    /// True once the server is 2.3.0 or later.
    static func has23() async -> Bool {
        guard let v = await current() else { return false }
        return v.compare("2.3.0", options: .numeric) != .orderedAscending
    }
}

// MARK: Calls

extension APIClient {
    /// The client's accent ("#RRGGBB"), or nil to clear it.
    func setMyAccent(_ hex: String?) async throws {
        _ = try await request("/me/accent", method: "PUT",
                              body: try JSONSerialization.data(withJSONObject: ["accent": hex ?? ""]))
    }

    /// The client has seen these announcements.
    func markAnnouncementsRead(_ ids: [String]) async throws {
        _ = try await request("/announcements/read", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    /// An announcement to some clients only (server 2.3.0). `clientIds` nil = everyone.
    func createAnnouncement(title: String, body: String, publishAt: Date?, clientIds: [String]?, audienceLabel: String?) async throws {
        var payload: [String: Any] = ["title": title, "body": body]
        if let publishAt { payload["publishAt"] = ISO8601DateFormatter().string(from: publishAt) }
        if let clientIds { payload["clientIds"] = clientIds }
        if let audienceLabel { payload["audienceLabel"] = audienceLabel }
        _ = try await request("/admin/announcements", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: payload))
    }

    /// The coach's announcements with audience and reads (the extra fields are empty before 2.3.0).
    func adminAnnouncementsWithReads() async throws -> [APIAdminAnnouncement] {
        try await get("/admin/announcements")
    }

    func replyInsights(weeks: Int) async throws -> APIReplyInsights {
        try await get("/admin/insights/replies?weeks=\(weeks)")
    }

    func retentionInsights() async throws -> APIRetention {
        try await get("/admin/insights/retention")
    }
}

// MARK: - Client accents (avatars on the coach's screens)

enum ClientAccents {
    /// "#00E5FF" → 0x00E5FF.
    static func parse(_ s: String?) -> UInt32? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return v
    }

    static func hexString(_ v: UInt32) -> String { String(format: "#%06X", v) }

    /// The accent a client picked in their app, by id or (failing that) by name. nil = they haven't picked one.
    static func hex(id: String? = nil, name: String) -> UInt32? {
        let roster = AppStore.shared.roster
        if let id, let r = roster.first(where: { $0.id == id }) { return parse(r.accent) }
        return parse(roster.first(where: { $0.name == name })?.accent)
    }
}

// MARK: - Announcement reads (client side)

enum AnnouncementReads {
    private static let key = "bst_ann_read_sent"
    private static var sending: Set<String> = []

    /// Tell the coach these were seen. Each id goes once; failures (offline, or a server before 2.3.0) try again later.
    static func mark(_ ids: [String]) {
        let store = AppStore.shared
        guard store.isLive, !store.isTrainer else { return }
        let sent = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let todo = ids.filter { !sent.contains($0) && !sending.contains($0) }
        guard !todo.isEmpty else { return }
        sending.formUnion(todo)
        Task {
            do {
                try await APIClient.shared.markAnnouncementsRead(todo)
                var s = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
                s.formUnion(todo)
                UserDefaults.standard.set(Array(s.suffix(400)), forKey: key)
            } catch { }
            sending.subtract(todo)
        }
    }
}

// MARK: - Theme sync

/// iPhone: a client sends their accent (so the coach's iPad can show it); the coach sends his whole theme.
/// iPad, with "Use my phone's theme" on: takes the coach's phone theme. The iPad never sends its own.
final class ThemeSync {
    static let shared = ThemeSync()
    static let followKey = "bst_pad_follow_phone_theme"

    private var bag: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var applying = false
    private var started = false

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var followsPhone: Bool { UserDefaults.standard.bool(forKey: followKey) }
    /// What was last sent is remembered per account, so a second person signing in on this phone still sends theirs.
    private static var account: String { (UserDefaults.standard.string(forKey: "bst_userEmail") ?? "").lowercased() }

    func start() {
        guard !started else { return }
        started = true
        let store = AppStore.shared
        ThemeStore.shared.objectWillChange
            .sink { [weak self] _ in self?.soon() }
            .store(in: &bag)
        store.$isLoggedIn.removeDuplicates()
            .sink { [weak self] _ in self?.soon() }
            .store(in: &bag)
        store.$isTrainer.removeDuplicates()
            .sink { [weak self] _ in self?.soon() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.soon() }
            .store(in: &bag)
    }

    /// Called by the iPad's switch.
    func setFollow(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.followKey)
        if on { soon(delay: 0.1) }
    }

    private func soon(delay: Double = 1.5) {
        guard !applying else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        let store = AppStore.shared
        guard store.isLive, store.isLoggedIn else { return }
        guard await ServerVersion.has23() else { return }
        if isPhone {
            if store.isTrainer { await sendCoachTheme() } else { await sendAccent() }
        } else if store.isTrainer && Self.followsPhone {
            await takeCoachTheme()
        }
    }

    // iPhone, client: only a colour they picked themselves. Volt is the standard look (and on the coach's
    // screens it means "lifting now"), so it's sent as no accent.
    private func sendAccent() async {
        let t = ThemeStore.shared
        let pick: UInt32? = (t.choice == .custom && t.customAccent != ThemeStore.volt) ? t.customAccent : nil
        let hex = pick.map { ClientAccents.hexString($0) }
        let key = "bst_accent_sent_" + Self.account
        let last = UserDefaults.standard.string(forKey: key)
        guard last != (hex ?? "none") else { return }
        do {
            try await APIClient.shared.setMyAccent(hex)
            UserDefaults.standard.set(hex ?? "none", forKey: key)
        } catch { }
    }

    static func snapshot() -> CoachThemeSnapshot {
        let t = ThemeStore.shared
        return CoachThemeSnapshot(choice: t.choice.rawValue, base: t.customBase.rawValue,
                                  accent: ClientAccents.hexString(t.customAccent),
                                  trueBlack: t.trueBlack, highContrast: t.highContrast)
    }

    // iPhone, coach: the whole theme.
    private func sendCoachTheme() async {
        let snap = Self.snapshot()
        guard let data = try? JSONEncoder().encode(snap), let json = String(data: data, encoding: .utf8) else { return }
        let key = "bst_coach_theme_sent_" + Self.account
        guard UserDefaults.standard.string(forKey: key) != json else { return }
        do {
            _ = try await APIClient.shared.saveTrainerSetting("coachTheme", json: json)
            UserDefaults.standard.set(json, forKey: key)
        } catch { }
    }

    /// The phone theme last seen on the server (shown on the iPad's Theme pane).
    private(set) var lastPhoneTheme: CoachThemeSnapshot?

    // iPad: take the phone's theme.
    private func takeCoachTheme() async {
        guard let s = try? await APIClient.shared.trainerSetting("coachTheme"), let json = s.json,
              let snap = try? JSONDecoder().decode(CoachThemeSnapshot.self, from: Data(json.utf8)) else { return }
        lastPhoneTheme = snap
        guard snap != Self.snapshot() else { return }
        let t = ThemeStore.shared
        applying = true
        if let c = ThemeChoice(rawValue: snap.choice), t.choice != c { t.choice = c }
        if let b = ThemeBase(rawValue: snap.base), t.customBase != b { t.customBase = b }
        if let a = ClientAccents.parse(snap.accent), t.customAccent != a { t.customAccent = a }
        if t.trueBlack != snap.trueBlack { t.trueBlack = snap.trueBlack }
        if t.highContrast != snap.highContrast { t.highContrast = snap.highContrast }
        // objectWillChange fires before each change lands; let those settle before listening again.
        try? await Task.sleep(nanoseconds: 300_000_000)
        applying = false
        NotificationCenter.default.post(name: .bstPhoneThemeApplied, object: nil)
    }

    /// The iPad's "Check now".
    func refreshNow() { soon(delay: 0) }
}

extension Notification.Name {
    static let bstPhoneThemeApplied = Notification.Name("bstPhoneThemeApplied")
}
