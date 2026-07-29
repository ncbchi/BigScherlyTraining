import SwiftUI
import AVFoundation
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

    // Called when the user taps Done. Schedules the background bell.
    func scheduleBackgroundBell(after seconds: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notifId])

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Time for your next set 🔔"
        // Uses the bundled bell.caf as the notification sound
        content.sound = UNNotificationSound(named: UNNotificationSoundName("bell.caf"))

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, TimeInterval(seconds)), repeats: false)
        center.add(UNNotificationRequest(identifier: notifId, content: content, trigger: trigger))
    }

    // If the rest finishes while in the foreground, cancel the scheduled
    // notification (so it doesn't double-fire) and play the ducking bell now.
    func fireForegroundBell() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifId])
        duckAndPlay()
    }

    // Cancel everything (user skipped rest).
    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifId])
    }

    // Lower any playing music, play the bell, then restore audio.
    private func duckAndPlay() {
        prepareAudioIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)

        player?.currentTime = 0
        player?.play()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Restore other audio after the bell finishes
        let dur = player?.duration ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.1) {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
