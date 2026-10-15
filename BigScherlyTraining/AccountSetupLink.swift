import SwiftUI
import Combine

// MARK: - "Set Up My Account" from the welcome email (server 2.5.0, Oct 11, 2026)
// The email's button is https://api.bigscherlytraining.com/setup/<token>. With Associated
// Domains on (applinks:api.bigscherlytraining.com), iOS opens the app with that URL instead
// of Safari. The app trades the token for a sign-in (it works once), and because a new client
// still has the coach's temporary password, RootView goes straight to SetPasswordView, which
// skips the temporary-password field for this kind of sign-in.
final class AccountSetupLink: ObservableObject {
    static let shared = AccountSetupLink()

    @Published var working = false
    @Published var error: String?

    /// The token in a setup link, or nil if the URL isn't one.
    static func token(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let isOurs = (url.scheme == "https" && (url.host ?? "").hasSuffix("bigscherlytraining.com"))
            || (url.scheme == "bigscherly" && url.host == "setup")
        guard isOurs else { return nil }
        if url.scheme == "bigscherly" { return parts.first }
        guard parts.count >= 2, parts[0] == "setup", parts[1].count >= 20 else { return nil }
        return parts[1]
    }

    /// Handles a setup link. Returns false (does nothing) for any other URL.
    @MainActor
    func handle(_ url: URL, store: AppStore) -> Bool {
        guard let token = Self.token(in: url) else { return false }
        guard !working else { return true }
        working = true
        error = nil
        Task {
            do {
                let r = try await APIClient.shared.setupAccount(token: token)
                await MainActor.run {
                    working = false
                    // Someone else signed in on this phone? The link is for the new client.
                    if store.isLoggedIn || store.isDemoMode { store.logout() }
                    let resp = LoginResponse(token: r.token, role: r.role, name: r.name, id: r.id,
                                             mustChangePassword: r.mustChangePassword)
                    LoginFinish.apply(resp, email: r.email, viaCode: true, store: store)
                }
            } catch {
                await MainActor.run {
                    working = false
                    self.error = (error as? APIClient.APIError)?.message
                        ?? "Couldn't open your account. Check your connection, then tap the button in the email again."
                }
            }
        }
        return true
    }
}

/// Everything after the server says yes — shared by the password login, the emailed-code
/// sheets and the welcome email's setup link, so all of them land in exactly the same state.
enum LoginFinish {
    @MainActor
    static func apply(_ resp: LoginResponse, email: String, viaCode: Bool, store: AppStore) {
        APIClient.shared.setToken(resp.token)
        // A code session may set its first password without the temporary one (SetPasswordView).
        UserDefaults.standard.set(viaCode, forKey: "bst_codeSignIn")
        // The same login screen serves both roles — the server tells us which shell to show.
        store.isTrainer = (resp.role == "trainer")
        store.trainerName = resp.name
        store.isDemoMode = false   // isLive computes from this
        // Set identity immediately from the login response
        // so the greeting is correct even before /me loads.
        if resp.role != "trainer" {
            store.client = Client(id: resp.id, name: resp.name,
                                  email: email, startDate: store.client.startDate,
                                  goal: store.client.goal)
        }
        // Persist role + name so relaunch restores the
        // correct shell and identity, not a default.
        UserDefaults.standard.set(resp.role == "trainer", forKey: "bst_isTrainer")
        UserDefaults.standard.set(resp.name, forKey: "bst_userName")

        if store.isTrainer {
            // His own training runs on a hidden profile; keep his login
            // name and email on screen.
            store.client = Client(id: resp.id, name: resp.name, email: email,
                                  startDate: store.client.startDate, goal: store.client.goal)
            UserDefaults.standard.set(email, forKey: "bst_userEmail")
            store.login()
            store.startCoachSession()
        } else {
            store.mustChangePassword = resp.mustChangePassword
            store.login()
            if !resp.mustChangePassword { store.loadAllFromAPI() }
        }
    }
}
