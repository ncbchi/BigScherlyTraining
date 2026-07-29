import SwiftUI

// MARK: - Settings
// Client settings: Apple Health connect/status, account + change password, notification
// toggles, units, legal/support links, log out, and (an App Review requirement)
// delete account. Reached via the nav tray (AppTab.settings). Add to the main app target.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var health = HealthKitManager.shared

    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_notif_checkins") private var notifCheckins = true
    @AppStorage("bst_notif_messages") private var notifMessages = true
    @AppStorage("bst_notif_supplements") private var notifSupplements = true

    @State private var showChangePassword = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var connecting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(text: "You")
                Text("Settings").font(BrandFont.display(48)).foregroundColor(.white)

                account
                appleHealth
                notifications
                preferences
                about
                accountActions

                Text("Big Scherly Training  ·  v1.0.0")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 28)
        }
        .background(Brand.bg.ignoresSafeArea())
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases your account and all your data — workouts, photos, check-ins, everything. It can't be undone.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Sections

    private var account: some View {
        section("Account") {
            infoRow("Name", store.client.name)
            rowDivider
            infoRow("Email", store.client.email)
            rowDivider
            tapRow("Change Password", systemIcon: "lock.fill") { showChangePassword = true }
        }
    }

    private var appleHealth: some View {
        section("Apple Health") {
            if !health.isAvailable {
                statusRow(icon: "heart.slash.fill", tint: Brand.mute,
                          title: "Not available",
                          subtitle: "This device can't access Apple Health.")
            } else if health.authorizationRequested {
                statusRow(icon: "heart.fill", tint: Brand.volt,
                          title: "Connected",
                          subtitle: "Heart rate and workout data sync to your sessions.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect Apple Health so your coach can see heart rate and calories for each session.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    Button {
                        connecting = true
                        Task { @MainActor in
                            _ = await health.requestAuthorization()
                            connecting = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if connecting { ProgressView().tint(Brand.black) }
                            Text(connecting ? "Requesting…" : "Connect Apple Health")
                                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.black)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Brand.volt).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(connecting)
                }
                .padding(16)
            }
        }
    }

    private var notifications: some View {
        section("Notifications") {
            toggleRow("Check-in reminders", $notifCheckins)
            rowDivider
            toggleRow("Coach messages", $notifMessages)
            rowDivider
            toggleRow("Supplement reminders", $notifSupplements)
        }
    }

    private var preferences: some View {
        section("Preferences") {
            HStack {
                Text("Units").font(BrandFont.body(15)).foregroundColor(.white)
                Spacer()
                Picker("Units", selection: $units) {
                    Text("lb").tag("lb")
                    Text("kg").tag("kg")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var about: some View {
        section("About") {
            linkRow("Privacy Policy", url: "https://www.bigscherlytraining.com/privacy")
            rowDivider
            linkRow("Terms of Service", url: "https://www.bigscherlytraining.com/terms")
            rowDivider
            linkRow("Contact Support", url: "mailto:coach@bigscherlytraining.com")
        }
    }

    private var accountActions: some View {
        VStack(spacing: 12) {
            Button { store.logout() } label: {
                Text("Log Out")
                    .font(BrandFont.body(15, .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
            }
            Button { confirmDelete = true } label: {
                HStack(spacing: 8) {
                    if deleting { ProgressView().tint(Brand.danger) }
                    Text(deleting ? "Deleting…" : "Delete Account")
                        .font(BrandFont.body(15, .bold)).foregroundColor(Brand.danger)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(Brand.danger.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.danger.opacity(0.4), lineWidth: 1))
            }
            .disabled(deleting)
        }
    }

    private func performDelete() {
        deleting = true
        Task { @MainActor in
            do {
                try await APIClient.shared.deleteAccount()
                store.logout()
            } catch {
                errorMessage = "Couldn't delete your account. Please try again, or email coach@bigscherlytraining.com."
                deleting = false
            }
        }
    }

    // MARK: Row helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
            VStack(spacing: 0) { content() }
                .background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Brand.line).padding(.leading, 16)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.body(15)).foregroundColor(Brand.mute)
            Spacer()
            Text(value).font(BrandFont.body(15, .semibold)).foregroundColor(.white)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private func tapRow(_ title: String, systemIcon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemIcon).foregroundColor(Brand.volt).frame(width: 20)
                Text(title).font(BrandFont.body(15)).foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title).font(BrandFont.body(15)).foregroundColor(.white)
        }
        .tint(Brand.volt)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(string: "https://www.bigscherlytraining.com")!) {
            HStack(spacing: 12) {
                Text(title).font(BrandFont.body(15)).foregroundColor(.white)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(15, .semibold)).foregroundColor(.white)
                Text(subtitle).font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Change Password sheet
// Voluntary change, separate from the forced first-login flow (SetPasswordView),
// so it can't interfere with the temp-password path.
struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPass = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?

    private var canSubmit: Bool {
        !current.isEmpty && newPass.count >= 8 && newPass == confirm && !working
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    field("Current password", text: $current)
                    field("New password", text: $newPass)
                    field("Confirm new password", text: $confirm)

                    if !newPass.isEmpty && newPass.count < 8 {
                        Text("New password must be at least 8 characters.")
                            .font(BrandFont.body(12)).foregroundColor(Brand.danger)
                    } else if !confirm.isEmpty && newPass != confirm {
                        Text("Passwords don't match.")
                            .font(BrandFont.body(12)).foregroundColor(Brand.danger)
                    }
                    if let error {
                        Text(error).font(BrandFont.body(12)).foregroundColor(Brand.danger)
                    }

                    Button { submit() } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().tint(Brand.black) }
                            Text(working ? "Saving…" : "Update Password")
                                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.black)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(canSubmit ? Brand.volt : Brand.volt.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSubmit)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(Brand.mute)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
            SecureField("", text: text)
                .textContentType(.password)
                .padding(14).background(Brand.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                .foregroundColor(.white)
        }
    }

    private func submit() {
        working = true; error = nil
        Task { @MainActor in
            do {
                try await APIClient.shared.changePassword(current: current, new: newPass)
                dismiss()
            } catch {
                self.error = "Couldn't update password. Check your current password and try again."
                working = false
            }
        }
    }
}
