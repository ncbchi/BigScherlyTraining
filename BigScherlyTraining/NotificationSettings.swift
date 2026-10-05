import SwiftUI
import UIKit
import Combine
import AVFoundation
import UserNotifications

// MARK: - Sounds (bundled in BigScherlyTraining/Sounds, made for the app)

enum BSTSound: String, CaseIterable, Identifiable, Codable {
    case bell, chime, plate, whistle, pulse, rise, system, none
    case tick                                   // the rest timer's 10-second warning only (not in the picker)
    var id: String { rawValue }

    static let made: [BSTSound] = [.bell, .chime, .plate, .whistle, .pulse, .rise]

    var title: String {
        switch self {
        case .bell: return "Bell"
        case .chime: return "Chime"
        case .plate: return "Plate clank"
        case .whistle: return "Whistle"
        case .pulse: return "Pulse"
        case .rise: return "Rise"
        case .tick: return "Tick"
        case .system: return "iPhone default"
        case .none: return "None (haptic only)"
        }
    }

    var blurb: String {
        switch self {
        case .bell: return "Bright, single strike"
        case .chime: return "Three rising notes"
        case .plate: return "Two plates kissing"
        case .whistle: return "Coach's short whistle"
        case .pulse: return "One bright ping, faint echo"
        case .rise: return "Quick upward sweep"
        case .tick: return "Soft wooden tock"
        case .system: return "The standard iPhone sound"
        case .none: return "Vibrates, no sound"
        }
    }

    /// The file in the app bundle (none plays a silent file, so iPhone still vibrates).
    var file: String? {
        switch self {
        case .system: return nil
        case .none: return "bst_silent.wav"
        default: return "bst_\(rawValue).wav"
        }
    }

    var notificationSound: UNNotificationSound {
        guard let f = file else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(f))
    }

    /// What the server puts in a push ("default" = the iPhone sound).
    var pushName: String { file ?? "default" }

    static let silent = UNNotificationSound(named: UNNotificationSoundName("bst_silent.wav"))
}

// MARK: - Kinds of notification

enum NotifKind: String, CaseIterable {
    // From the coach (push)
    case messages, checkinReviewed, workouts, announcements
    // From clients (push, coaches)
    case clientMessages, clientVideos, clientCheckins
    // On the phone
    case rest, supplements, checkinReminder, workoutReminder, prs

    var isPush: Bool { [.messages, .checkinReviewed, .workouts, .announcements, .clientMessages, .clientVideos, .clientCheckins].contains(self) }

    var defaultSound: BSTSound {
        switch self {
        case .messages, .clientMessages, .clientVideos: return .chime
        case .checkinReviewed, .clientCheckins: return .bell
        case .rest: return .bell
        case .supplements: return .rise
        case .prs: return .whistle
        default: return .system
        }
    }
}

enum SoundMode: String, Codable, CaseIterable { case always, headphones, never }
enum RestStyle: String, Codable, CaseIterable { case sound, haptic, both }

// MARK: - Settings (on the phone, and the push parts on the server)

struct NotifSettings: Codable, Equatable {
    var off: Set<String> = [NotifKind.workoutReminder.rawValue]
    var sounds: [String: String] = [:]
    var soundMode: SoundMode = .always
    var quietOn = false
    var quietStart = 22 * 60
    var quietEnd = 7 * 60
    var showText = true
    // Reminders
    var checkinWeekday = 1                  // 1 = Sunday … 7 = Saturday
    var checkinMinutes = 9 * 60
    var workoutReminderMinutes = 17 * 60
    // Rest
    var restStyle: RestStyle = .both
    var restWarning = true
    var restRepeat = true
    var restRepeatEvery = 30
    var restRepeatCount = 3
    var defaultRest = 120
    // Watch
    var pauseStrength = 1                   // 0 light · 1 medium · 2 strong
    var pauseTicks = false
    var slowRepOn = true
    var slowRepPct = 25.0
    var slowRepPattern = 1                  // 0 single · 1 double · 2 long

    func isOn(_ k: NotifKind) -> Bool { !off.contains(k.rawValue) }
    func sound(_ k: NotifKind) -> BSTSound { sounds[k.rawValue].flatMap { BSTSound(rawValue: $0) } ?? k.defaultSound }
}

@MainActor
final class NotifPrefs: ObservableObject {
    static let shared = NotifPrefs()
    private static let key = "bst_notif_settings"

    @Published var s: NotifSettings {
        didSet {
            guard s != oldValue else { return }
            save()
            if pushFieldsChanged(oldValue) { scheduleServerSync() }
            if watchFieldsChanged(oldValue) { AppStore.shared.sendActiveWorkoutToWatch() }
            if reminderFieldsChanged(oldValue) { LocalReminders.refresh(AppStore.shared) }
        }
    }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key), let saved = try? JSONDecoder().decode(NotifSettings.self, from: data) {
            s = saved
        } else {
            // First run: carry over the three switches from the old Settings screen.
            var n = NotifSettings()
            if d.object(forKey: "bst_notif_messages") as? Bool == false { n.off.insert(NotifKind.messages.rawValue) }
            if d.object(forKey: "bst_notif_supplements") as? Bool == false { n.off.insert(NotifKind.supplements.rawValue) }
            if d.object(forKey: "bst_notif_checkins") as? Bool == false { n.off.insert(NotifKind.checkinReminder.rawValue) }
            s = n
        }
    }

    func binding(_ k: NotifKind) -> Binding<Bool> {
        Binding(get: { self.s.isOn(k) },
                set: { on in if on { self.s.off.remove(k.rawValue) } else { self.s.off.insert(k.rawValue) } })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private func pushFieldsChanged(_ old: NotifSettings) -> Bool {
        old.off != s.off || old.sounds != s.sounds || old.soundMode != s.soundMode || old.quietOn != s.quietOn
            || old.quietStart != s.quietStart || old.quietEnd != s.quietEnd || old.showText != s.showText
    }
    private func reminderFieldsChanged(_ old: NotifSettings) -> Bool {
        old.off != s.off || old.quietOn != s.quietOn || old.quietStart != s.quietStart || old.quietEnd != s.quietEnd
            || old.checkinWeekday != s.checkinWeekday || old.checkinMinutes != s.checkinMinutes
            || old.workoutReminderMinutes != s.workoutReminderMinutes || old.soundMode != s.soundMode
    }
    private func watchFieldsChanged(_ old: NotifSettings) -> Bool {
        old.pauseStrength != s.pauseStrength || old.pauseTicks != s.pauseTicks || old.slowRepOn != s.slowRepOn
            || old.slowRepPct != s.slowRepPct || old.slowRepPattern != s.slowRepPattern
    }

    // MARK: Server (so a switched-off kind isn't sent at all)

    private var syncTask: Task<Void, Never>?

    private func scheduleServerSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await pushToServer()
        }
    }

    var serverPayload: APINotifPrefs {
        let pushKinds = NotifKind.allCases.filter(\.isPush)
        var sounds: [String: String] = [:]
        for k in pushKinds { sounds[k.rawValue] = s.sound(k).pushName }
        return APINotifPrefs(muted: pushKinds.filter { !s.isOn($0) }.map(\.rawValue),
                             quietStart: s.quietOn ? s.quietStart : -1, quietEnd: s.quietOn ? s.quietEnd : -1,
                             timeZone: TimeZone.current.identifier, showText: s.showText,
                             soundMode: s.soundMode.rawValue, sounds: sounds)
    }

    func pushToServer() async {
        guard AppStore.shared.isLive, AppStore.shared.isLoggedIn else { return }
        try? await APIClient.shared.putNotificationPrefs(serverPayload)
    }

    /// On sign-in: a new phone picks up settings saved on the server; otherwise this phone's win.
    func syncOnSignIn(_ store: AppStore) {
        guard store.isLive, store.isLoggedIn else { return }
        Task {
            let fresh = UserDefaults.standard.data(forKey: Self.key) == nil || !UserDefaults.standard.bool(forKey: "bst_notif_synced")
            if fresh, let server = try? await APIClient.shared.getNotificationPrefs(),
               !server.muted.isEmpty || server.quietStart >= 0 || !server.showText || server.soundMode != "always" {
                var n = s
                for k in NotifKind.allCases where k.isPush {
                    if server.muted.contains(k.rawValue) { n.off.insert(k.rawValue) } else { n.off.remove(k.rawValue) }
                    if let file = server.sounds[k.rawValue], let snd = BSTSound.allCases.first(where: { $0.pushName == file }) {
                        n.sounds[k.rawValue] = snd.rawValue
                    }
                }
                n.quietOn = server.quietStart >= 0
                if server.quietStart >= 0 { n.quietStart = server.quietStart; n.quietEnd = server.quietEnd }
                n.showText = server.showText
                n.soundMode = SoundMode(rawValue: server.soundMode) ?? .always
                s = n
            } else {
                await pushToServer()                 // also keeps the time zone current
            }
            UserDefaults.standard.set(true, forKey: "bst_notif_synced")
        }
    }

    var watchHaptics: WatchHaptics {
        WatchHaptics(pauseStrength: s.pauseStrength, pauseTicks: s.pauseTicks, slowRepOn: s.slowRepOn,
                     slowRepPct: s.slowRepPct, slowRepPattern: s.slowRepPattern)
    }
}

/// The server's copy of the push-related settings.
struct APINotifPrefs: Codable {
    var muted: [String]
    var quietStart: Int
    var quietEnd: Int
    var timeZone: String
    var showText: Bool
    var soundMode: String
    var sounds: [String: String]
}

// MARK: - Speaker or headphones?

enum AudioOutput {
    /// AirPods, headphones, the car, AirPlay — anything that isn't the phone's own speaker.
    static var external: Bool {
        let ports: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                                              .carAudio, .airPlay, .usbAudio, .lineOut, .HDMI]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ports.contains($0.portType) }
    }

    @MainActor static var soundsAllowed: Bool {
        switch NotifPrefs.shared.s.soundMode {
        case .always: return true
        case .never: return false
        case .headphones: return external
        }
    }

    /// For a notification scheduled now: its sound, or silent (still vibrates) when sound isn't allowed.
    @MainActor static func notificationSound(_ snd: BSTSound) -> UNNotificationSound {
        soundsAllowed ? snd.notificationSound : BSTSound.silent
    }
}

/// Plays a sound inside the app (previews, the rest bell), mixing politely with music.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    private var player: AVAudioPlayer?

    func play(_ snd: BSTSound, respectOutput: Bool = true) {
        if respectOutput && !AudioOutput.soundsAllowed { return }
        let url: URL?
        if let f = snd.file, snd != .none {
            url = Bundle.main.url(forResource: (f as NSString).deletingPathExtension, withExtension: "wav")
        } else if snd == .system {
            url = Bundle.main.url(forResource: "bell", withExtension: "mp3")
        } else {
            url = nil
        }
        guard let url else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        let length = player?.duration ?? 1
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.3) {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}

// MARK: - Buttons on notifications

enum NotifActions {
    static func register() {
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let openChat = UNNotificationAction(identifier: "open", title: "Open chat", options: [.foreground])
        let more = UNNotificationAction(identifier: "rest30", title: "+30 s", options: [])
        let start = UNNotificationAction(identifier: "startSet", title: "Start set", options: [])
        let taken = UNNotificationAction(identifier: "taken", title: "Taken ✓", options: [])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Remind me in 1 h", options: [])
        let share = UNNotificationAction(identifier: "share", title: "Share it", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "BST_MESSAGE", actions: [reply, openChat], intentIdentifiers: []),
            UNNotificationCategory(identifier: "BST_REST", actions: [more, start], intentIdentifiers: []),
            UNNotificationCategory(identifier: "SUPPLEMENT_DUE", actions: [taken, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "BST_PR", actions: [share], intentIdentifiers: []),
        ])
    }

    /// A button was tapped (the app may have been woken in the background for it).
    @MainActor static func handle(_ action: String, info: [String: String], text: String?) async {
        if info["preview"] == "1" { return }            // a preview's buttons are for show
        let store = AppStore.shared
        switch action {
        case "reply":
            guard let tid = info["threadId"], let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if store.isTrainer { try? await APIClient.shared.trainerSendMessage(threadId: tid, text: text) }
            else { try? await APIClient.shared.sendMessage(threadId: tid, text: text) }
        case "rest30":
            LiveSessionController.shared.addRest(30)
        case "startSet":
            LiveSessionController.shared.startSet()
        case "taken":
            if let id = info["supplementId"], let s = store.supplements.first(where: { $0.id == id }) {
                store.confirmSupplement(s)
            }
        case "snooze":
            let c = UNMutableNotificationContent()
            c.title = info["title"] ?? "Supplement reminder"
            c.body = info["body"] ?? ""
            c.categoryIdentifier = "SUPPLEMENT_DUE"
            c.userInfo = info.filter { $0.key != "title" && $0.key != "body" }
            c.sound = AudioOutput.notificationSound(NotifPrefs.shared.s.sound(.supplements))
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "bst.snooze.\(UUID().uuidString)", content: c,
                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)))
        case "share":
            store.select(.share)
        case "open":
            PushCenter.shared.open(route: "chat")
        default:
            break
        }
    }
}

// MARK: - Reminders scheduled on the phone (check-ins, workouts, PRs)

enum LocalReminders {
    static let checkinId = "bst.checkin.reminder"
    static let workoutPrefix = "bst.workout.reminder."

    @MainActor static func refresh(_ store: AppStore) {
        let center = UNUserNotificationCenter.current()
        let p = NotifPrefs.shared.s
        // Clear what we may have scheduled before (by id, in order — so the new ones below survive).
        center.removePendingNotificationRequests(withIdentifiers: [checkinId] + store.workouts.map { workoutPrefix + $0.id })
        guard store.isLoggedIn, !store.isTrainer else { return }

        // Weekly check-in
        if p.isOn(.checkinReminder) && !inQuiet(p.checkinMinutes, p) {
            let c = UNMutableNotificationContent()
            c.title = "Check-in day"
            c.body = "Two minutes: weight, photos, how the week went."
            c.sound = AudioOutput.notificationSound(.system)
            c.userInfo = ["route": "checkins"]
            var comps = DateComponents()
            comps.weekday = p.checkinWeekday; comps.hour = p.checkinMinutes / 60; comps.minute = p.checkinMinutes % 60
            center.add(UNNotificationRequest(identifier: checkinId, content: c,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        }

        // Training days you haven't started (the next week)
        guard p.isOn(.workoutReminder), !inQuiet(p.workoutReminderMinutes, p) else { return }
        let cal = Calendar.current
        let horizon = Date().addingTimeInterval(7 * 86_400)
        for w in store.workouts where !w.completed && w.date <= horizon {
            guard let when = cal.date(bySettingHour: p.workoutReminderMinutes / 60, minute: p.workoutReminderMinutes % 60,
                                      second: 0, of: w.date), when > Date() else { continue }
            let c = UNMutableNotificationContent()
            c.title = "Today: \(w.title)"
            c.body = "\(w.exercises.count) exercises — tap to start."
            c.sound = AudioOutput.notificationSound(.system)
            c.userInfo = ["route": "workouts"]
            center.add(UNNotificationRequest(identifier: workoutPrefix + w.id, content: c,
                                             trigger: UNCalendarNotificationTrigger(
                                                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: when),
                                                repeats: false)))
        }
    }

    /// The workout started: no nudge for it.
    static func cancelWorkout(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [workoutPrefix + id])
    }

    /// A PR earned while the app was in the background (logged on the Watch or Lock Screen).
    @MainActor static func announcePR(exercise: String, oneRepMax: Double, gain: Double) {
        guard NotifPrefs.shared.s.isOn(.prs), UIApplication.shared.applicationState != .active else { return }
        let title = "New PR · \(exercise)"
        let body = "Est. 1RM \(StatsUnits.weightText(oneRepMax))" + (gain > 0 ? " — up \(StatsUnits.weightText(gain))." : ".") + " Share it?"
        // The workout card is open: the alert goes into it instead of a separate notification.
        if LiveSessionController.shared.alertOnCard(title: title, body: body, sound: NotifPrefs.shared.s.sound(.prs)) { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = AudioOutput.notificationSound(NotifPrefs.shared.s.sound(.prs))
        c.categoryIdentifier = "BST_PR"
        c.userInfo = ["route": "share"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bst.pr.\(UUID().uuidString)", content: c, trigger: nil))
    }

    private static func inQuiet(_ minutes: Int, _ p: NotifSettings) -> Bool {
        guard p.quietOn, p.quietStart != p.quietEnd else { return false }
        return p.quietStart < p.quietEnd ? (minutes >= p.quietStart && minutes < p.quietEnd)
                                         : (minutes >= p.quietStart || minutes < p.quietEnd)
    }
}

// MARK: - Preview: every kind of notification, one every 3 seconds, grouped by function

enum NotifPreview {
    private struct Item {
        let title: String, body: String, kind: NotifKind?, category: String?, sound: BSTSound?
        var timeSensitive = false
    }

    private static let batches: [(String, [Item])] = [
        ("coach", [
            Item(title: "Big Scherly", body: "Go for it! Hit 285 today — you've earned it 💪", kind: .messages, category: "BST_MESSAGE", sound: nil),
            Item(title: "Check-in reviewed", body: "“Great progress on the squat this week — keep that depth.”", kind: .checkinReviewed, category: nil, sound: nil),
            Item(title: "New workout: Lower Body Power", body: "Scheduled for Tue, Oct 6", kind: .workouts, category: nil, sound: nil),
            Item(title: "New PR Challenge Starts Monday", body: "4-week strength challenge — details in Announcements.", kind: .announcements, category: nil, sound: nil),
        ]),
        ("clients", [
            Item(title: "Jordan", body: "Hey coach, quick question about tomorrow's session", kind: .clientMessages, category: "BST_MESSAGE", sound: nil),
            Item(title: "Jordan", body: "Sent a video 🎥", kind: .clientVideos, category: "BST_MESSAGE", sound: nil),
            Item(title: "Jordan sent a check-in", body: "Tap to review.", kind: .clientCheckins, category: nil, sound: nil),
        ]),
        ("rest", [
            Item(title: "10 seconds", body: "Get set — Back Squat · 5 × 275 lb", kind: nil, category: nil, sound: .tick, timeSensitive: true),
            Item(title: "Rest's up · Set 3 of 5", body: "Back Squat · 5 × 275 lb", kind: .rest, category: "BST_REST", sound: nil, timeSensitive: true),
            Item(title: "Still resting? · Set 3 of 5", body: "Back Squat · 5 × 275 lb", kind: .rest, category: "BST_REST", sound: nil, timeSensitive: true),
        ]),
        ("supplements", [
            Item(title: "Time for Creatine", body: "5 g · with breakfast — open the app to confirm you took it.", kind: .supplements, category: "SUPPLEMENT_DUE", sound: nil, timeSensitive: true),
            Item(title: "Post-workout: Protein", body: "1 scoop — open the app to confirm you took it.", kind: .supplements, category: "SUPPLEMENT_DUE", sound: nil, timeSensitive: true),
        ]),
        ("reminders", [
            Item(title: "Check-in day", body: "Two minutes: weight, photos, how the week went.", kind: .checkinReminder, category: nil, sound: .system),
            Item(title: "Today: Lower Body Power", body: "6 exercises — tap to start.", kind: .workoutReminder, category: nil, sound: .system),
        ]),
        ("prs", [
            Item(title: "New PR · Back Squat", body: "Est. 1RM 321 lb — up 12 lb. Share it?", kind: .prs, category: "BST_PR", sound: nil),
        ]),
        ("privacy", [
            Item(title: "Big Scherly Training", body: "New message from your coach", kind: .messages, category: "BST_MESSAGE", sound: nil),
        ]),
    ]

    static var count: Int { batches.reduce(0) { $0 + $1.1.count } }

    /// Schedules them all: 3 s apart, with an extra beat between groups.
    @MainActor static func sendAll() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return false }
        let prefs = NotifPrefs.shared.s
        var at: TimeInterval = 3
        for (group, items) in batches {
            for (i, item) in items.enumerated() {
                let c = UNMutableNotificationContent()
                c.title = item.title
                c.body = item.body
                c.threadIdentifier = "bst.preview.\(group)"           // each function stacks together
                if let cat = item.category { c.categoryIdentifier = cat }
                c.userInfo = ["preview": "1"]
                let snd = item.sound ?? item.kind.map { prefs.sound($0) } ?? .system
                c.sound = AudioOutput.notificationSound(snd)
                if item.timeSensitive { c.interruptionLevel = .timeSensitive }
                try? await center.add(UNNotificationRequest(identifier: "bst.preview.\(group).\(i)", content: c,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: at, repeats: false)))
                at += 3
            }
            at += 3
        }
        return true
    }
}

// MARK: - Screens

private struct NSection<C: View>: View {
    let title: String
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
        }
    }
}

private struct NDivider: View {
    var body: some View { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 16) }
}

private struct NToggle: View {
    let title: String
    var sub: String? = nil
    @Binding var on: Bool
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                if let sub { Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute) }
            }
        }
        .tint(Brand.volt)
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

private struct NLink<D: View>: View {
    let title: String
    var sub: String? = nil
    let value: String
    @ViewBuilder var destination: () -> D
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                    if let sub { Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute) }
                }
                Spacer()
                Text(value).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private func clock(_ minutes: Int) -> String {
    var c = DateComponents(); c.hour = minutes / 60; c.minute = minutes % 60
    let d = Calendar.current.date(from: c) ?? Date()
    return d.formatted(date: .omitted, time: .shortened)
}

/// A time-of-day picker over minutes after midnight.
private struct TimeRow: View {
    let title: String
    @Binding var minutes: Int
    var body: some View {
        DatePicker(title, selection: Binding(
            get: {
                var c = DateComponents(); c.hour = minutes / 60; c.minute = minutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .font(BrandFont.body(15)).foregroundColor(Brand.text).tint(Brand.voltText)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Settings ▸ Notifications.
struct NotificationSettingsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var prefs = NotifPrefs.shared
    @ObservedObject private var push = PushCenter.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bst_pause_buzz") private var pauseBuzz = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.isTrainer { coachKinds } else { clientKinds; reminders; workout }
                    delivery
                    previewButton
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: push.registered ? "checkmark.circle.fill" : "bell.badge")
                            .foregroundColor(push.registered ? Brand.voltText : Brand.mute)
                        Text("Push: \(push.status)").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundColor(Brand.voltText) }
            }
        }
    }

    @State private var previewNote: String?

    private var previewButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    let ok = await NotifPreview.sendAll()
                    previewNote = ok ? "Sending \(NotifPreview.count), one every 3 seconds — lock your phone to see them on the Lock Screen."
                                     : "Notifications are off for Big Scherly — turn them on in iOS Settings."
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                    Text("Preview all notifications").font(BrandFont.body(15, .bold))
                }
                .foregroundColor(Brand.onVolt)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt))
            }
            .buttonStyle(.plain)
            Text(previewNote ?? "Every kind, with your sounds — grouped by function. The buttons on previews don't change anything.")
                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func kindToggle(_ title: String, _ k: NotifKind, sub: String? = nil) -> some View {
        NLink(title: title, sub: sub, value: prefs.s.isOn(k) ? prefs.s.sound(k).title : "Off") {
            KindDetailView(title: title, kind: k)
        }
    }

    private var clientKinds: some View {
        NSection(title: "From your coach") {
            kindToggle("Messages", .messages); NDivider()
            kindToggle("Check-in reviewed", .checkinReviewed); NDivider()
            kindToggle("New workouts", .workouts); NDivider()
            kindToggle("Announcements", .announcements)
        }
    }

    private var coachKinds: some View {
        NSection(title: "From your clients") {
            kindToggle("Messages", .clientMessages); NDivider()
            kindToggle("Videos", .clientVideos); NDivider()
            kindToggle("Check-ins", .clientCheckins)
        }
    }

    private var reminders: some View {
        NSection(title: "Reminders") {
            NLink(title: "Check-in reminder",
                  value: prefs.s.isOn(.checkinReminder)
                    ? "\(Calendar.current.shortWeekdaySymbols[(prefs.s.checkinWeekday - 1) % 7]) \(clock(prefs.s.checkinMinutes))" : "Off") {
                CheckInReminderView()
            }
            NDivider()
            NLink(title: "Supplements", sub: "Each at its scheduled time",
                  value: prefs.s.isOn(.supplements) ? prefs.s.sound(.supplements).title : "Off") {
                KindDetailView(title: "Supplements", kind: .supplements)
            }
            NDivider()
            NLink(title: "Workout reminder", sub: "On training days you haven't started",
                  value: prefs.s.isOn(.workoutReminder) ? clock(prefs.s.workoutReminderMinutes) : "Off") {
                WorkoutReminderView()
            }
        }
    }

    private var workout: some View {
        NSection(title: "During workouts") {
            NLink(title: "Rest timer", value: prefs.s.restStyle == .both ? "Sound + haptic" : prefs.s.restStyle.rawValue.capitalized) {
                RestTimerSettingsView()
            }
            NDivider()
            NLink(title: "Watch buzzes", sub: "Pause and slow-rep taps on your Apple Watch",
                  value: pauseBuzz || prefs.s.slowRepOn ? "On" : "Off") {
                WatchBuzzSettingsView()
            }
            NDivider()
            NToggle(title: "PRs & awards", sub: "When you earn one while the app's closed", on: prefs.binding(.prs))
        }
    }

    private var delivery: some View {
        NSection(title: "Delivery") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Play sounds").font(BrandFont.body(15)).foregroundColor(Brand.text)
                Picker("Play sounds", selection: $prefs.s.soundMode) {
                    Text("Always").tag(SoundMode.always)
                    Text("Headphones").tag(SoundMode.headphones)
                    Text("Never").tag(SoundMode.never)
                }
                .pickerStyle(.segmented)
                Text(prefs.s.soundMode == .headphones
                     ? "Only through AirPods, headphones or the car — never out loud. Coach messages arrive silently (with a buzz), since the phone can't check what's plugged in when they arrive."
                     : prefs.s.soundMode == .never ? "Silent everywhere. Haptics still buzz." : "Sounds play wherever audio is going.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            NDivider()
            NToggle(title: "Quiet hours", sub: "Only rest alerts get through", on: $prefs.s.quietOn)
            if prefs.s.quietOn {
                TimeRow(title: "From", minutes: $prefs.s.quietStart)
                TimeRow(title: "Until", minutes: $prefs.s.quietEnd)
            }
            NDivider()
            NToggle(title: "Show message text", sub: "Off: “New message from your coach” on the Lock Screen", on: $prefs.s.showText)
        }
    }
}

/// One kind: on/off and its sound.
struct KindDetailView: View {
    let title: String
    let kind: NotifKind
    @ObservedObject private var prefs = NotifPrefs.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NSection(title: title) {
                    NToggle(title: "Notify me", on: prefs.binding(kind))
                    if prefs.s.isOn(kind) {
                        NDivider()
                        NLink(title: "Sound", value: prefs.s.sound(kind).title) { SoundPickerView(kind: kind) }
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ten sounds made for the app — tap ▶ to hear one.
struct SoundPickerView: View {
    let kind: NotifKind
    @ObservedObject private var prefs = NotifPrefs.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array((BSTSound.made + [.system, .none]).enumerated()), id: \.element) { i, snd in
                        let on = prefs.s.sound(kind) == snd
                        HStack(spacing: 12) {
                            Button { SoundPlayer.shared.play(snd, respectOutput: false) } label: {
                                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                                    .foregroundColor(on ? Brand.onVolt : Brand.text)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(on ? Brand.volt : Brand.text.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .opacity(snd == .none ? 0.3 : 1)
                            .disabled(snd == .none)
                            .accessibilityLabel("Play \(snd.title)")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snd.title).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                Text(snd.blurb).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                            if on { Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundColor(Brand.voltText) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            prefs.s.sounds[kind.rawValue] = snd.rawValue
                            SoundPlayer.shared.play(snd, respectOutput: false)
                        }
                        if i < BSTSound.made.count + 1 { NDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                Text("Tap ▶ to hear one. Each kind of notification can have its own sound.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute).padding(.horizontal, 4)
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RestTimerSettingsView: View {
    @ObservedObject private var prefs = NotifPrefs.shared
    @AppStorage("bst_auto_rest") private var autoRest = true
    @AppStorage("bst_live_activity") private var liveActivity = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NSection(title: "When rest is up") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Alert").font(BrandFont.body(15)).foregroundColor(Brand.text)
                        Picker("Alert", selection: $prefs.s.restStyle) {
                            Text("Sound").tag(RestStyle.sound)
                            Text("Haptic").tag(RestStyle.haptic)
                            Text("Both").tag(RestStyle.both)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    if prefs.s.restStyle != .haptic {
                        NDivider()
                        NLink(title: "Sound", value: prefs.s.sound(.rest).title) { SoundPickerView(kind: .rest) }
                    }
                    NDivider()
                    NToggle(title: "10-second warning", sub: "A soft tick so you can get set", on: $prefs.s.restWarning)
                    NDivider()
                    NToggle(title: "Repeat if ignored", sub: "Every \(prefs.s.restRepeatEvery) s, up to \(prefs.s.restRepeatCount) times",
                            on: $prefs.s.restRepeat)
                }
                NSection(title: "Timing") {
                    NToggle(title: "Start automatically", sub: "When you log a set", on: $autoRest)
                    NDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default rest").font(BrandFont.body(15)).foregroundColor(Brand.text)
                            Text("When the programme doesn't say").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                        Spacer()
                        Stepper(String(format: "%d:%02d", prefs.s.defaultRest / 60, prefs.s.defaultRest % 60),
                                value: $prefs.s.defaultRest, in: 30...600, step: 15)
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.text).fixedSize()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    NDivider()
                    NToggle(title: "Lock Screen card", sub: "Countdown on the Lock Screen and Dynamic Island", on: $liveActivity)
                }
                Text("The in-app bell follows these too, and respects “Play sounds”.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute).padding(.horizontal, 4)
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Rest timer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WatchBuzzSettingsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var prefs = NotifPrefs.shared
    @AppStorage("bst_pause_buzz") private var pauseBuzz = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NSection(title: "Pause buzz") {
                    NToggle(title: "Tap when the pause is done", sub: "Uses each exercise's target pause", on: $pauseBuzz)
                    if pauseBuzz {
                        NDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Strength").font(BrandFont.body(15)).foregroundColor(Brand.text)
                            Picker("Strength", selection: $prefs.s.pauseStrength) {
                                Text("Light").tag(0); Text("Medium").tag(1); Text("Strong").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        NDivider()
                        NToggle(title: "Countdown ticks", sub: "A light tick each second while you hold", on: $prefs.s.pauseTicks)
                    }
                }
                NSection(title: "Slow-rep buzz") {
                    NToggle(title: "Buzz when reps slow down", on: $prefs.s.slowRepOn)
                    if prefs.s.slowRepOn {
                        NDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Speed drop").font(BrandFont.body(15)).foregroundColor(Brand.text)
                                Spacer()
                                Text("\(Int(prefs.s.slowRepPct))%").font(BrandFont.body(15, .heavy)).foregroundColor(Brand.voltText)
                            }
                            Slider(value: $prefs.s.slowRepPct, in: 10...40, step: 1).tint(Brand.volt)
                            Text("A rep this much slower than your fastest — a sign you're close to your limit.")
                                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        NDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pattern").font(BrandFont.body(15)).foregroundColor(Brand.text)
                            Picker("Pattern", selection: $prefs.s.slowRepPattern) {
                                Text("Single").tag(0); Text("Double").tag(1); Text("Long").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Watch buzzes")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pauseBuzz) { _, _ in store.sendActiveWorkoutToWatch() }
    }
}

struct CheckInReminderView: View {
    @ObservedObject private var prefs = NotifPrefs.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NSection(title: "Check-in reminder") {
                    NToggle(title: "Remind me", on: prefs.binding(.checkinReminder))
                    if prefs.s.isOn(.checkinReminder) {
                        NDivider()
                        Picker("Day", selection: $prefs.s.checkinWeekday) {
                            ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                        }
                        .tint(Brand.voltText)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        NDivider()
                        TimeRow(title: "Time", minutes: $prefs.s.checkinMinutes)
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Check-in reminder")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkoutReminderView: View {
    @ObservedObject private var prefs = NotifPrefs.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NSection(title: "Workout reminder") {
                    NToggle(title: "Nudge me", sub: "On training days you haven't started yet", on: prefs.binding(.workoutReminder))
                    if prefs.s.isOn(.workoutReminder) {
                        NDivider()
                        TimeRow(title: "At", minutes: $prefs.s.workoutReminderMinutes)
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Workout reminder")
        .navigationBarTitleDisplayMode(.inline)
    }
}
