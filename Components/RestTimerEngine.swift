import SwiftUI
import AVFoundation
import AudioToolbox
import UserNotifications
import UIKit
import Combine

// MARK: - Rest Timer Engine
// Handles the parts that must work even when the app is backgrounded:
//  • Foreground: plays the bell through AVAudioPlayer, ducking any music.
//  • Background/locked: a scheduled local notification fires the bell on time.
//  • On return: the countdown recomputes from a saved end-time so it's always accurate.
final class RestTimerEngine: ObservableObject {
    static let shared = RestTimerEngine()

    private var player: AVAudioPlayer?
    private let notifId = "bst.rest.timer.bell"

    private init() { }

    private var audioPrepared = false
    private func prepareAudioIfNeeded() {
        guard !audioPrepared else { return }
        audioPrepared = true
        guard let url = Bundle.main.url(forResource: "bell", withExtension: "mp3") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    // Ask once for notification permission (needed for the background bell).
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    // MARK: Background alerts (Settings ▸ Notifications ▸ Rest timer)

    private var warnId: String { notifId + ".warn" }
    private func repeatId(_ i: Int) -> String { notifId + ".r\(i)" }
    private var allIds: [String] { [notifId, warnId] + (1...6).map(repeatId) }

    /// What's pending, so the alert can be rescheduled if the audio output changes mid-rest.
    private var pendingEnd: Date?
    private var pendingTitle = "Rest's up"
    private var pendingBody = "Time for your next set"
    private var routeObserver: NSObjectProtocol?

    /// Schedules the rest-over alert (with +30 s / Start set), the 10-second warning and repeats.
    @MainActor
    func scheduleBackgroundBell(after seconds: Int, title: String = "Rest's up", body: String = "Time for your next set") {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIds)
        let p = NotifPrefs.shared.s
        pendingEnd = Date().addingTimeInterval(TimeInterval(max(1, seconds)))
        pendingTitle = title
        pendingBody = body
        // (Headphones in/out mid-rest is handled by LiveSessionController, for card and notifications alike.)

        // The sound: yours, a silent one for haptic-only, or silent when output rules say so.
        let sound: UNNotificationSound = p.restStyle == .haptic ? BSTSound.silent : AudioOutput.notificationSound(p.sound(.rest))

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.categoryIdentifier = "BST_REST"
        content.interruptionLevel = .timeSensitive          // gets through Focus and quiet hours
        content.userInfo = ["kind": "rest"]
        center.add(UNNotificationRequest(identifier: notifId, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, TimeInterval(seconds)), repeats: false)))

        if p.restWarning && seconds > 15 {
            let w = UNMutableNotificationContent()
            w.title = "10 seconds"
            w.body = "Get set — " + body
            w.sound = p.restStyle == .haptic ? BSTSound.silent : AudioOutput.notificationSound(.tick)
            w.interruptionLevel = .timeSensitive
            w.userInfo = ["kind": "rest"]
            center.add(UNNotificationRequest(identifier: warnId, content: w,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds - 10), repeats: false)))
        }

        if p.restRepeat {
            for i in 1...max(1, min(6, p.restRepeatCount)) {
                let r = UNMutableNotificationContent()
                r.title = "Still resting? · " + title.replacingOccurrences(of: "Rest's up · ", with: "")
                r.body = body
                r.sound = sound
                r.categoryIdentifier = "BST_REST"
                r.interruptionLevel = .timeSensitive
                r.userInfo = ["kind": "rest"]
                center.add(UNNotificationRequest(identifier: repeatId(i), content: r,
                                                 trigger: UNTimeIntervalNotificationTrigger(
                                                    timeInterval: TimeInterval(seconds + i * max(15, p.restRepeatEvery)), repeats: false)))
            }
        }
    }

    /// Headphones plugged in or out mid-rest: reschedule with the right sound.
    private func watchRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let end = self.pendingEnd else { return }
                let left = Int(end.timeIntervalSinceNow)
                if left > 1 { self.scheduleBackgroundBell(after: left, title: self.pendingTitle, body: self.pendingBody) }
            }
        }
    }

    /// The Watch is tapping your wrist: play the sound here — through whatever audio is selected,
    /// following Play sounds — with no vibration (the wrist already has the tap). Arrives even with
    /// the phone locked: a message from the Watch wakes the app, and background audio lets it play.
    @MainActor
    func playWatchCue(_ cue: String) {
        let p = NotifPrefs.shared.s
        guard p.restStyle != .haptic else { return }               // haptic-only: the wrist covers it
        switch cue {
        case "warning": if p.restWarning { SoundPlayer.shared.play(.tick) }
        case "restUp": SoundPlayer.shared.play(p.sound(.rest))
        default: break
        }
    }

    // Rest finished with the app open: clear the scheduled alerts and ring here instead.
    @MainActor
    func fireForegroundBell() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allIds)
        pendingEnd = nil
        if WatchBridge.shared.watchSessionLive { return }          // the Watch taps and cues the sound
        let p = NotifPrefs.shared.s
        if p.restStyle != .haptic { SoundPlayer.shared.play(p.sound(.rest)) }     // respects Play sounds
        if p.restStyle != .sound {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    // Ten seconds left with the app open: a soft tick.
    @MainActor
    func fireForegroundWarning() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [warnId])
        if WatchBridge.shared.watchSessionLive { return }          // the Watch taps and cues the sound
        let p = NotifPrefs.shared.s
        guard p.restWarning else { return }
        if p.restStyle != .haptic { SoundPlayer.shared.play(.tick) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // Cancel everything (rest skipped, or the next set started).
    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allIds)
        pendingEnd = nil
    }
}
