import SwiftUI
import UIKit
import Combine
import UserNotifications

/// Remote (push) notifications: asking permission, registering this phone with the server,
/// and opening the right screen when one is tapped. Works for clients and coaches.
@MainActor
final class PushCenter: NSObject, ObservableObject {
    static let shared = PushCenter()
    private static let tokenKey = "bst_apns_token"

    /// Where push stands, shown at the bottom of Settings ▸ Notifications (and in Xcode's console).
    @Published private(set) var status = "Not started"
    @Published private(set) var registered = false

    private func note(_ s: String, ok: Bool = false) {
        status = s
        registered = ok
        print("[Push] \(s)")
    }

    /// This phone's push token, once iOS has given us one.
    var deviceToken: String? { UserDefaults.standard.string(forKey: Self.tokenKey) }

    /// After signing in, and every time the app comes to the front: ask once, then (re)register.
    /// iOS can change the token, so registering each launch keeps the server current.
    /// The store is passed in: login() can run while AppStore.shared is still being created
    /// (restoring a session at launch), and reading .shared from inside that would crash.
    func start(_ store: AppStore) {
        guard store.isLoggedIn else { note("Waiting — not signed in"); return }
        guard store.isLive else { note("Off in Demo Mode"); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                note("Asking for permission…")
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                if granted {
                    note("Registering with Apple…")
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    note("Not allowed — turn on in iOS Settings ▸ Big Scherly ▸ Notifications")
                }
            case .authorized, .provisional, .ephemeral:
                note("Registering with Apple…")
                UIApplication.shared.registerForRemoteNotifications()
            default:
                note("Not allowed — turn on in iOS Settings ▸ Big Scherly ▸ Notifications")
            }
        }
        NotifPrefs.shared.syncOnSignIn(store)          // settings saved on the server, and the time zone
        LocalReminders.refresh(store)
    }

    func didFail(_ error: Error) {
        note("Apple refused registration: \(error.localizedDescription)")
    }

    /// iOS handed us the token: send it to the server.
    func didRegister(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        guard AppStore.shared.isLive, AppStore.shared.isLoggedIn else { return }
        note("Got a token from Apple — saving it on the server…")
        Task {
            do {
                try await APIClient.shared.registerDevice(apnsToken: hex)
                note("Registered ✓  (…\(hex.suffix(6)))", ok: true)
            } catch {
                note("The server couldn't save this phone: \(error.localizedDescription)")
            }
        }
    }

    /// Signing out: this phone stops getting that account's notifications.
    /// (Built while still signed in, so the log-out right after can't race it.)
    func signOut(_ store: AppStore) {
        guard let hex = deviceToken, store.isLive else { return }
        APIClient.shared.unregisterDevice(apnsToken: hex)
    }

    /// A tapped notification opens where it's about.
    func open(route: String?) {
        let store = AppStore.shared
        guard store.isLoggedIn, let route else { return }
        if store.isTrainer {
            switch route {
            case "chat": store.select(.coachChat)
            case "checkins": store.select(.coachCheckins)
            case "today": store.select(.coachToday)
            case "wins": store.select(.coachWins)
            case "clients": store.select(.coachClients)
            case "workouts": store.select(.workouts)      // his own reminders
            case "supplements": store.select(.supplements)
            default: break
            }
        } else {
            switch route {
            case "chat": store.select(.chat)
            case "checkins": store.select(.checkins)
            case "announcements": store.select(.announcements)
            case "workouts": store.select(.workouts)
            case "supplements": store.select(.supplements)
            case "share": store.select(.share)
            default: break
            }
        }
    }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    /// While the app is open: still show the banner — except the rest timer, whose bell
    /// already rings in the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier.hasPrefix("bst.rest.timer.bell") { return [] }   // bell, warning, repeats
        return [.banner, .list, .sound]
    }

    /// Tapped, or one of its buttons: open the screen it's about, or do what the button says.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        var info = content.userInfo
        info["title"] = content.title
        info["body"] = content.body
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let route = (info["route"] as? String) ?? ((info["kind"] as? String) == "supplement" ? "supplements" : nil)
        if action == UNNotificationDefaultActionIdentifier {
            await MainActor.run { PushCenter.shared.open(route: route) }
        } else if action != UNNotificationDismissActionIdentifier {
            let sendable = info.reduce(into: [String: String]()) { r, kv in if let k = kv.key as? String, let v = kv.value as? String { r[k] = v } }
            await NotifActions.handle(action, info: sendable, text: typed)
        }
    }
}

/// The small UIKit hook iOS uses to hand over the push token.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// You closed the app (iOS calls this when the app's running at the time): close the live workout.
    func applicationWillTerminate(_ application: UIApplication) {
        LiveSessionController.shared.closeForTermination()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Diagnostics: a Lock Screen button wakes the app in the background to run its action.
        print("[App] launched · \(application.applicationState == .background ? "in the background" : "in the foreground")")
        // Set before launch finishes, so tapping a notification that opens the app still routes.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        NotifActions.register()                         // Reply, +30 s, Start set, Taken ✓, Snooze, Share
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCenter.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushCenter.shared.didFail(error) }      // e.g. the Push capability isn't on yet
    }
}
