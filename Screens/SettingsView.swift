import SwiftUI
import UIKit

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

    // Phase 5: theme, menu layout, workout and Stats defaults
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("bst_launch_tab") private var launchTab = AppTab.dashboard.rawValue
    @AppStorage("bst_keep_awake") private var keepAwake = true
    @AppStorage("bst_auto_rest") private var autoRest = true
    @AppStorage("bst_live_activity") private var liveActivity = true
    @AppStorage("bst_weight_step") private var weightStep = "standard"
    @AppStorage("bst_pause_buzz") private var pauseBuzz = true
    @ObservedObject private var setupEngine = SetupEngine.shared
    @AppStorage(SetupEngine.remindKey) private var setupRemind = true
    @AppStorage(SetupEngine.cameraKey) private var setupCamera = true
    @ObservedObject private var push = PushCenter.shared
    @State private var showNotifications = false
    @AppStorage("bst_stats_window") private var statsWindow = StatsWindow.w12.rawValue
    @State private var editingMenu = false
    @State private var customPick: Color = Color(hex: 0x00E5FF)

    @State private var showChangePassword = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var connecting = false
    @State private var errorMessage: String?

    /// Whether the Home & Lock Screen widgets can see the app's data (the App Group).
    private var widgetStatus: some View {
        let connected = WidgetShared.isConnected
        let saved = WidgetShared.load()?.generatedAt
        return HStack(spacing: 6) {
            Image(systemName: connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(connected ? Brand.voltText : .orange)
            Text(connected
                 ? "Widgets connected (\(WidgetShared.appGroup))" + (saved.map { " · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? " · saving…")
                 : "Widgets not connected — no App Group named \(WidgetShared.knownGroups[0]) or \(WidgetShared.knownGroups[1]) on the app target")
                .multilineTextAlignment(.center)
        }
        .font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear { WidgetBridge.shared.refreshNow() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSScreenHeader(eyebrow: "You", title: "Settings")

                appearance          // first: a theme change redraws the app, and this stays in view
                account
                appleHealth
                notifications
                preferences
                workoutPrefs
                watchSetup
                navigation
                statsDefaults
                about
                accountActions

                Text("Big Scherly Training  ·  v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                widgetStatus
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 28)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        // Leaving Settings withdraws a setup started here (it had nowhere else to show its card).
        .onDisappear { setupEngine.withdraw(from: .settings) }
        // Recalibrate opens the setup card right here, over Settings.
        .sheet(item: Binding(get: { setupEngine.origin == .settings ? setupEngine.request : nil },
                             set: { setupEngine.request = $0 })) { _ in
            SetupSheet()
                .presentationBackground(Brand.bg)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .sheet(isPresented: $editingMenu) { MenuOrderEditor() }
        .sheet(isPresented: $showNotifications) { NotificationSettingsView().environmentObject(store) }
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
                                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.onVolt)
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
            Button { showNotifications = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill").foregroundColor(Brand.voltText).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").font(BrandFont.body(15)).foregroundColor(Brand.text)
                        Text(push.registered ? "Sounds, reminders, rest timer, Watch buzzes" : "Push: \(push.status)")
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.mute)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var preferences: some View {
        section("Preferences") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Units").font(BrandFont.body(15)).foregroundColor(Brand.text)
                    Text("Weights everywhere — workouts, Stats, check-ins").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
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
                    .font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
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

    // MARK: Appearance — Dark · Light · System · Custom

    private var appearance: some View {
        section("Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(ThemeChoice.allCases) { c in
                        let on = theme.choice == c
                        Button { theme.choice = c } label: {
                            VStack(spacing: 4) {
                                Image(systemName: c.icon).font(.system(size: 15, weight: .semibold))
                                Text(c.label).font(BrandFont.body(12, .bold))
                            }
                            .foregroundColor(on ? Brand.onVolt : Brand.text)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Brand.text.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Text(theme.choice == .custom ? "Your own look — set it up below. It's remembered when you switch back."
                     : theme.choice == .system ? "Follows your iPhone's light or dark setting." : "The standard Big Scherly look, in Volt.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            .padding(14)
            if theme.choice == .custom {
                rowDivider
                customTheme
            }
        }
    }

    private var customTheme: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("BASE").font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                Picker("Base", selection: $theme.customBase) {
                    ForEach(ThemeBase.allCases) { b in Text(b.label).tag(b) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ACCENT").font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                    Spacer()
                    Text(theme.accentName(theme.customAccent)).font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText)
                }
                HStack(spacing: 0) {
                    ForEach(ThemeStore.accents) { a in
                        let on = theme.customAccent == a.hex
                        Button { theme.customAccent = a.hex } label: {
                            ZStack {
                                Circle().fill(Color(hex: UInt(a.hex)))
                                if on {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
                                        .foregroundColor(RGBColor(hex: a.hex).textOn.color)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(on ? Brand.text : Color.clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.name)
                        .frame(maxWidth: .infinity)
                    }
                }
                // Any colour: pick it, then tap Use (applying live would redraw the app under the picker).
                HStack(spacing: 10) {
                    ColorPicker("Custom colour", selection: $customPick, supportsOpacity: false)
                        .font(BrandFont.body(14)).foregroundColor(Brand.text)
                    Button("Use colour") { theme.customAccent = Self.hex(of: customPick) }
                        .font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                }
            }
            Toggle(isOn: $theme.trueBlack) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("True black").font(BrandFont.body(15)).foregroundColor(Brand.text)
                    Text("Pure black backgrounds in dark mode — easier on OLED battery").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            }
            .tint(Brand.volt)
            .disabled(theme.customBase == .light)
            Toggle(isOn: $theme.highContrast) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High contrast").font(BrandFont.body(15)).foregroundColor(Brand.text)
                    Text("Brighter secondary text, stronger outlines").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            }
            .tint(Brand.volt)
        }
        .padding(14)
    }

    private static func hex(of c: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBColor(r: Double(r), g: Double(g), b: Double(b)).hex
    }

    // MARK: Apple Watch Setup

    /// Each calibration's status, Recalibrate (opens the setup card right away), and the options.
    private var watchSetup: some View {
        section("Apple Watch setup") {
            setupRow("Body setup",
                     SetupEngine.bodyDone ? "Done — hold still, presses, air squats to depth" : "Not done yet — about 60 seconds",
                     done: SetupEngine.bodyDone) { setupEngine.recalibrate(.body) }
            ForEach(SetupLift.allCases, id: \.self) { lift in
                rowDivider
                let c = LiftCalibration.saved(lift)
                setupRow(lift.title,
                         c.map { "Your range \(Self.rangeText($0.fullTravelM)) · set \($0.date.formatted(.dateTime.month(.abbreviated).day()))" }
                            ?? "Not set up — just the bar, the first time it's up",
                         done: c != nil) { setupEngine.recalibrate(.lift(lift)) }
            }
            rowDivider
            subToggle("Remind me until it's done", "Offer setup between sets until each one is finished", $setupRemind)
            rowDivider
            subToggle("Check squat depth with the camera", "Prop the phone side-on — nothing is recorded", $setupCamera)
            rowDivider
            Button {
                SetupEngine.resetAll()
                setupEngine.recalibrate(.body)
            } label: {
                HStack {
                    Text("Recalibrate everything").font(BrandFont.body(15)).foregroundColor(Brand.voltText)
                    Spacer()
                    Image(systemName: "arrow.counterclockwise").foregroundColor(Brand.voltText)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func setupRow(_ title: String, _ status: String, done: Bool, recalibrate: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18, weight: .semibold)).foregroundColor(done ? Brand.voltText : Brand.mute)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                Text(status).font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: recalibrate) {
                Text(done ? "Recalibrate" : "Set up").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.onVolt)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Brand.volt))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private static func rangeText(_ m: Double) -> String {
        StatsUnits.isKg ? "\(Int((m * 100).rounded())) cm" : "\(Int((m * 39.37).rounded())) in"
    }

    // MARK: Workouts

    private var workoutPrefs: some View {
        section("Workouts") {
            subToggle("Keep screen awake", "While the workout screen is open", $keepAwake)
            rowDivider
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight steps").font(BrandFont.body(15)).foregroundColor(Brand.text)
                    Text("The Lock Screen card's −/+").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
                Spacer()
                Picker("Weight steps", selection: $weightStep) {
                    Text(units == "kg" ? "1.25" : "2.5").tag("small")
                    Text(units == "kg" ? "2.5" : "5").tag("standard")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func subToggle(_ title: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        .tint(Brand.volt)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Navigation

    private var navigation: some View {
        section("Navigation") {
            tapRow("Menu order", systemIcon: "line.3.horizontal") { editingMenu = true }
            rowDivider
            HStack {
                Text("Open on launch").font(BrandFont.body(15)).foregroundColor(Brand.text)
                Spacer()
                Picker("Open on launch", selection: $launchTab) {
                    ForEach(AppTab.allCases) { t in Text(t.rawValue).tag(t.rawValue) }
                }
                .tint(Brand.voltText)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    // MARK: Stats

    private var statsDefaults: some View {
        section("Stats") {
            HStack {
                Text("Default time window").font(BrandFont.body(15)).foregroundColor(Brand.text)
                Spacer()
                Picker("Default time window", selection: $statsWindow) {
                    ForEach(StatsWindow.allCases) { w in Text(w.rawValue).tag(w.rawValue) }
                }
                .tint(Brand.voltText)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
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
                .font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            VStack(spacing: 0) { content() }
                .background(Brand.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Brand.line).padding(.leading, 16)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.body(15)).foregroundColor(Brand.mute)
            Spacer()
            Text(value).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private func tapRow(_ title: String, systemIcon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemIcon).foregroundColor(Brand.voltText).frame(width: 20)
                Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
        }
        .tint(Brand.volt)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(string: "https://www.bigscherlytraining.com")!) {
            HStack(spacing: 12) {
                Text(title).font(BrandFont.body(15)).foregroundColor(Brand.text)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(Brand.readable(tint)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
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
                                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.onVolt)
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
                .foregroundColor(Brand.text)
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

// MARK: - Menu order (drag to reorder within a group; the eye hides a screen)

struct MenuOrderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var order: [MenuGroup: [AppTab]] =
        Dictionary(uniqueKeysWithValues: MenuGroup.allCases.map { ($0, MenuLayout.ordered($0)) })
    @State private var hidden: Set<String> = MenuLayout.hidden

    var body: some View {
        NavigationStack {
            List {
                ForEach(MenuGroup.allCases) { g in
                    Section(g.rawValue.uppercased()) {
                        ForEach(order[g] ?? []) { tab in
                            let off = hidden.contains(tab.rawValue)
                            HStack(spacing: 12) {
                                Image(systemName: tab.icon).foregroundColor(off ? Brand.mute : Brand.voltText).frame(width: 22)
                                Text(tab.rawValue).font(BrandFont.body(15, .semibold))
                                    .foregroundColor(off ? Brand.mute : Brand.text).strikethrough(off)
                                Spacer()
                                Button {
                                    if off { hidden.remove(tab.rawValue) } else { hidden.insert(tab.rawValue) }
                                    save()
                                } label: {
                                    Image(systemName: off ? "eye.slash" : "eye").foregroundColor(off ? Brand.mute : Brand.voltText)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(off ? "Show \(tab.rawValue)" : "Hide \(tab.rawValue)")
                            }
                            .listRowBackground(Brand.card)
                        }
                        .onMove { from, to in
                            order[g]?.move(fromOffsets: from, toOffset: to)
                            save()
                        }
                    }
                }
                Section {
                    Text("Settings, Appearance and Log out always stay at the bottom of the menu.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Menu order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(Brand.voltText)
                }
            }
        }
    }

    private func save() {
        MenuLayout.order = MenuGroup.allCases.flatMap { order[$0] ?? [] }.map(\.rawValue)
        MenuLayout.hidden = hidden
    }
}

