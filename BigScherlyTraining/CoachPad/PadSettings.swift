import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Settings (round 3, Oct 9, 2026)
//
// Grouped like the sidebar: coaching first, your account last. Theme & accent has exactly the
// phone's options (Dark, Light, System, Custom; the Custom base, the nine accents or any colour,
// True black, High contrast). It's kept on this iPad for now, separate from the phone; following the
// phone's theme is on the 2.1 list. Everything the phone's Settings has that isn't here yet is
// one tap away under "Everything else".
// Synchronized folder: no target step needed.

enum PadSettingsPane: String, CaseIterable, Identifiable {
    case replies, forms, risk, alerts, units, theme, layout, account, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .replies: return "Saved replies"
        case .forms: return "Check-in forms"
        case .risk: return "Flight risk & renewals"
        case .alerts: return "Client alerts"
        case .units: return "Units & weight steps"
        case .theme: return "Theme & accent"
        case .layout: return "Sidebar & panes"
        case .account: return "Account"
        case .app: return "Everything else"
        }
    }
    var icon: String {
        switch self {
        case .replies: return "text.bubble"
        case .forms: return "list.bullet.clipboard"
        case .risk: return "exclamationmark.triangle"
        case .alerts: return "bell.badge"
        case .units: return "scalemass"
        case .theme: return "paintpalette"
        case .layout: return "sidebar.left"
        case .account: return "person.crop.circle"
        case .app: return "gearshape.2"
        }
    }
    static let groups: [(name: String, items: [PadSettingsPane])] = [
        ("Coaching", [.replies, .forms, .risk, .alerts]),
        ("Planning", [.units]),
        ("Look", [.theme, .layout]),
        ("You", [.account, .app]),
    ]
}

struct PadSettingsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("bst_pad_settings_pane") private var paneRaw = PadSettingsPane.replies.rawValue
    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_weight_step") private var weightStep = "standard"

    private var pane: PadSettingsPane { PadSettingsPane(rawValue: paneRaw) ?? .replies }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadPageTop(title: "Settings", subtitle: "Grouped like the sidebar. Coaching first, your account last.") { EmptyView() }
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                nav
                    .frame(width: 260)
                Rectangle().fill(Pad.line).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Pad.page.ignoresSafeArea())
    }

    // MARK: Left: the groups

    private var nav: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(PadSettingsPane.groups, id: \.name) { g in
                    PadLab(g.name, color: Pad.faint, size: 12).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                    ForEach(g.items) { p in navRow(p) }
                }
                Button { store.logout() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 22)
                        Text("Sign out").font(PadFont.ui(15, .semibold))
                        Spacer()
                    }
                    .foregroundColor(Pad.mute)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverEffect(.highlight)
                .padding(.top, 12)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
    }

    private func navRow(_ p: PadSettingsPane) -> some View {
        let on = p == pane
        return Button { paneRaw = p.rawValue } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).font(.system(size: 15, weight: .medium)).frame(width: 22)
                Text(p.title).font(PadFont.ui(15, .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(aside(p)).font(PadFont.cond(12)).foregroundColor(Pad.faint).lineLimit(1)
            }
            .foregroundColor(on ? Pad.text : Pad.mute)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.raised : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func aside(_ p: PadSettingsPane) -> String {
        switch p {
        case .replies: return "\(store.savedReplies.count)"
        case .units: return units
        case .theme: return theme.choice == .custom ? theme.accentName(theme.customAccent) : theme.choice.label
        default: return ""
        }
    }

    // MARK: Right: the pane

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .replies: PadSavedRepliesPane()
        case .forms: ScrollView { PadFormsPane().padding(20) }
        case .risk: ScrollView { PadRiskPane().padding(20) }
        case .alerts: ScrollView { PadAlertsPane().padding(20) }
        case .units: ScrollView { unitsPane.padding(20) }
        case .theme: ScrollView { PadThemePane().padding(20) }
        case .layout: ScrollView { PadLayoutPane().padding(20) }
        case .account: ScrollView { PadAccountPane().padding(20) }
        case .app:
            SettingsView()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.bg.ignoresSafeArea())
        }
    }

    private var unitsPane: some View {
        let small: String = units == "kg" ? "1.25 kg" : "2.5 lb"
        let standard: String = units == "kg" ? "2.5 kg" : "5 lb"
        return VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Units", aside: "weights everywhere: workouts, Stats, check-ins") {
                PadSeg(options: [(id: "lb", label: "Pounds"), (id: "kg", label: "Kilograms")], selection: $units)
            }
            PadPane(title: "Weight steps", aside: "how far a weight moves with one tap, and what increases round to") {
                PadSeg(options: [(id: "small", label: small), (id: "standard", label: standard)], selection: $weightStep)
                PadLab("The same setting as on your phone's Lock Screen card. Kept on this iPad.", size: 12)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

// MARK: - A settings row (title, a quiet line under it, the control on the right)

struct PadSettingRow<Control: View>: View {
    let title: String
    var sub: String = ""
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                if !sub.isEmpty {
                    Text(sub).font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Saved replies

struct PadSavedRepliesPane: View {
    @EnvironmentObject var store: AppStore
    @State private var items: [Line] = []
    @State private var newText = ""
    @State private var loaded = false
    @FocusState private var adding: Bool

    struct Line: Identifiable, Equatable { var id = UUID(); var text: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Saved replies").font(PadFont.ui(17, .bold)).foregroundColor(Pad.text)
                Spacer()
                PadLab("drag to reorder · swipe to delete · used in Check-ins and Inbox", color: Pad.faint, size: 12)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            List {
                ForEach($items) { $line in
                    TextField("Reply", text: $line.text, axis: .vertical)
                        .font(PadFont.ui(15)).foregroundColor(Pad.text)
                        .onSubmit { commit() }
                        .listRowBackground(Pad.surface)
                }
                .onDelete { items.remove(atOffsets: $0); commit() }
                .onMove { items.move(fromOffsets: $0, toOffset: $1); commit() }
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundColor(Pad.voltText)
                    TextField("Add a reply…", text: $newText)
                        .font(PadFont.ui(15)).foregroundColor(Pad.text)
                        .focused($adding)
                        .onSubmit { add() }
                    if !newText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add") { add() }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
                    }
                }
                .listRowBackground(Pad.surface)
                .moveDisabled(true)
                .deleteDisabled(true)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .frame(maxWidth: 820)
            PadLab("They show as one-tap chips when you reply to a check-in or a message, in this order. Saved to your account, so the phone has them too.", size: 12)
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            items = store.savedReplies.map { Line(text: $0) }
        }
        .onDisappear { commit() }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(Line(text: t))
        newText = ""
        commit()
        adding = true
    }

    private func commit() {
        let list = items.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard list != store.savedReplies else { return }
        store.setSavedReplies(list)
    }
}

// MARK: - Check-in forms

struct PadFormsPane: View {
    @State private var forms: [APICheckInForm] = []
    @State private var loading = true
    @State private var editingDefault = false
    @State private var editing: APICheckInForm?
    @State private var creating = false

    private var defaultLine: String {
        CheckInSchema.custom == nil ? "Standard questions · everyone unless you pick another"
                                    : "\(CheckInSchema.questions.count) questions · everyone unless you pick another"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Check-in forms", aside: "give a client a form from their Check-ins") {
                VStack(spacing: 0) {
                    formRow("Default form", defaultLine) { editingDefault = true }
                    if loading {
                        PadSkeleton(height: 44).padding(.vertical, 6)
                    }
                    ForEach(forms) { f in
                        PadRule()
                        formRow(f.name, subline(f)) { editing = f }
                    }
                }
                Button { creating = true } label: { Label("New form", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadLab("Changes apply from each client's next check-in.", size: 12)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task { await load() }
        .sheet(isPresented: $editingDefault) { CheckInFormEditor() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { f in CheckInFormEditor(form: f) }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { CheckInFormEditor(newForm: true) }
    }

    private func subline(_ f: APICheckInForm) -> String {
        let n: Int = CheckInSchema.parse(f.json)?.count ?? 0
        let who: String = f.clientCount == 0 ? "not given to anyone" : f.clientCount.plural("client")
        return "\(n) questions · \(who)"
    }

    private func formRow(_ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                    Text(sub).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.faint)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func load() async {
        let f = (try? await APIClient.shared.checkInForms()) ?? []
        forms = f
        loading = false
    }
}

// MARK: - Flight risk & renewals

struct PadRiskPane: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(PadPrefs.showRiskKey) private var showRisk = true
    @AppStorage(PadPrefs.lateGraceKey) private var grace = 0
    @AppStorage(PadPrefs.renewWindowKey) private var window = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Flight risk & renewals") {
                VStack(spacing: 0) {
                    PadSettingRow(title: "Show “At risk”",
                                  sub: "Only for someone who has stopped training and has several other warning signs. Off: nobody is labelled, and the risk card leaves Clients.") {
                        Toggle("", isOn: $showRisk).labelsHidden().tint(Pad.volt)
                    }
                    PadRule()
                    PadSettingRow(title: "Count a check-in late after", sub: "Days past the week it was due.") {
                        Menu {
                            ForEach([0, 1, 2, 3, 5], id: \.self) { d in
                                Button(d == 0 ? "Straight away" : d.plural("day")) { grace = d }
                            }
                        } label: { menuLabel(grace == 0 ? "Straight away" : grace.plural("day")) }
                    }
                    PadRule()
                    PadSettingRow(title: "Show renewals coming up within", sub: "On Insights and Today. Renewal dates are set on each client's Overview.") {
                        Menu {
                            ForEach([14, 30, 45, 60, 90], id: \.self) { d in
                                Button(d.plural("day")) { window = d }
                            }
                        } label: { menuLabel(window.plural("day")) }
                    }
                }
            }
            PadLab("Kept on this iPad.", size: 12)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func menuLabel(_ t: String) -> some View {
        HStack(spacing: 6) {
            Text(t).font(PadFont.ui(15, .semibold))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(Pad.text)
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
    }
}

// MARK: - Client alerts

struct PadAlertsPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var push = PushCenter.shared
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Client alerts", aside: "what reaches you, and how") {
                PadSettingRow(title: "Messages, videos, check-ins, PRs, going quiet",
                              sub: "Which ones notify you, their sounds, and quiet hours. The same settings as on your phone.") {
                    Button("Open") { open = true }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                PadRule()
                HStack(spacing: 8) {
                    Image(systemName: push.registered ? "checkmark.circle.fill" : "bell.badge")
                        .foregroundColor(push.registered ? Pad.voltText : Pad.mute)
                    Text("Push: \(push.status)").font(PadFont.ui(13)).foregroundColor(Pad.mute)
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .sheet(isPresented: $open) { NotificationSettingsView().environmentObject(store) }
    }
}

// MARK: - Theme & accent (the phone's options, kept on this iPad)

struct PadThemePane: View {
    @ObservedObject private var theme = ThemeStore.shared
    @State private var customPick: Color = Color(hex: 0x00E5FF)

    private var explainer: String {
        switch theme.choice {
        case .custom: return "Your own look. Set it up below; it's remembered when you switch back."
        case .system: return "Follows this iPad's light or dark setting."
        case .light: return "The standard Big Scherly look, light, in Volt."
        case .dark: return "The standard Big Scherly look, in Volt."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Theme", aside: "the same options as the phone app") {
                HStack(spacing: 8) {
                    ForEach(ThemeChoice.allCases) { c in choiceTile(c) }
                }
                Text(explainer).font(PadFont.ui(13)).foregroundColor(Pad.mute)
            }
            if theme.choice == .custom {
                PadPane(title: "Base") {
                    PadSeg(options: ThemeBase.allCases.map { (id: $0, label: $0.label) }, selection: $theme.customBase)
                }
                PadPane(title: "Accent", aside: theme.accentName(theme.customAccent)) {
                    HStack(spacing: 10) {
                        ForEach(ThemeStore.accents) { a in swatch(a) }
                    }
                    HStack(spacing: 12) {
                        ColorPicker("Any colour", selection: $customPick, supportsOpacity: false)
                            .font(PadFont.ui(15)).foregroundColor(Pad.text)
                            .fixedSize()
                        Button("Use colour") { theme.customAccent = Self.hex(of: customPick) }
                            .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        Spacer()
                    }
                }
                PadPane(title: "Options") {
                    VStack(spacing: 0) {
                        PadSettingRow(title: "True black", sub: "Pure black backgrounds in dark mode.") {
                            Toggle("", isOn: $theme.trueBlack).labelsHidden().tint(Pad.volt)
                                .disabled(theme.customBase == .light)
                        }
                        PadRule()
                        PadSettingRow(title: "High contrast", sub: "Brighter secondary text, stronger outlines.") {
                            Toggle("", isOn: $theme.highContrast).labelsHidden().tint(Pad.volt)
                        }
                    }
                }
            }
            preview
            PadLab("Kept on this iPad, separate from your phone for now. Following your phone's theme is coming.", size: 12)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func choiceTile(_ c: ThemeChoice) -> some View {
        let on = theme.choice == c
        let fg: Color = on ? Pad.onVolt : Pad.text
        let bg: Color = on ? Pad.volt : Pad.well
        return Button { theme.choice = c } label: {
            VStack(spacing: 6) {
                Image(systemName: c.icon).font(.system(size: 18, weight: .semibold))
                Text(c.label).font(PadFont.ui(14, .bold))
            }
            .foregroundColor(fg)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 12).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.clear : Pad.line2, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func swatch(_ a: AccentOption) -> some View {
        let on = theme.customAccent == a.hex
        let mark: Color = RGBColor(hex: a.hex).textOn.color
        return Button { theme.customAccent = a.hex } label: {
            ZStack {
                Circle().fill(Color(hex: UInt(a.hex)))
                if on { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundColor(mark) }
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().stroke(on ? Pad.text : Color.clear, lineWidth: 2).padding(-4))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(a.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A small piece of the app in the current look.
    private var preview: some View {
        PadPane(title: "Preview") {
            HStack(alignment: .top, spacing: 12) {
                PadStatTile(stat: PadStat(label: "Sessions this week", value: "4", unit: "of 5", sub: "+1 on last week", good: true))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PadAvatar(name: "Jordan", size: 34, volt: true)
                        Text("Jordan is lifting now").font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                        PadTag(text: "PR", kind: .volt)
                    }
                    HStack(spacing: 8) {
                        Button("Reply") {}.buttonStyle(PadButtonStyle(kind: .primary, small: true))
                        Button("Open") {}.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        PadTag(text: "Missed", kind: .warn)
                    }
                }
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    private static func hex(of c: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBColor(r: Double(r), g: Double(g), b: Double(b)).hex
    }
}

// MARK: - Sidebar & panes

struct PadLayoutPane: View {
    @AppStorage("bst_pad_sidebar_hidden") private var sidebarHidden = false
    @ObservedObject private var biz = PadBizPrefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Sidebar") {
                PadSettingRow(title: "Keep the sidebar hidden", sub: "The button top-left on every page shows and hides it (⌘⇧S). Opening a client folds it to icons either way.") {
                    Toggle("", isOn: $sidebarHidden).labelsHidden().tint(Pad.volt)
                }
            }
            PadPane(title: "Business panes on Clients", aside: "shown beside the roster") {
                VStack(spacing: 0) {
                    ForEach(Array(biz.order.enumerated()), id: \.element) { i, p in
                        if i > 0 { PadRule() }
                        PadSettingRow(title: p.title) {
                            Toggle("", isOn: binding(p)).labelsHidden().tint(Pad.volt)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func binding(_ p: PadBizPane) -> Binding<Bool> {
        Binding(get: { biz.on.contains(p) }, set: { v in
            if v { biz.on.insert(p) } else { biz.on.remove(p) }
        })
    }
}

// MARK: - Account

struct PadAccountPane: View {
    @EnvironmentObject var store: AppStore
    @State private var changing = false
    private var name: String { store.trainerName.isEmpty ? store.client.name : store.trainerName }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PadPane(title: "Account") {
                VStack(spacing: 0) {
                    PadSettingRow(title: "Name") { Text(name).font(PadFont.ui(15)).foregroundColor(Pad.mute) }
                    PadRule()
                    PadSettingRow(title: "Email") { Text(store.client.email).font(PadFont.ui(15)).foregroundColor(Pad.mute) }
                    PadRule()
                    PadSettingRow(title: "Password") {
                        Button("Change") { changing = true }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    }
                    PadRule()
                    PadSettingRow(title: "Clients", sub: "On your roster now.") {
                        Text("\(store.roster.count)").font(PadFont.ui(15)).foregroundColor(Pad.mute)
                    }
                }
            }
            HStack {
                Button { store.logout() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(PadButtonStyle(kind: .outline))
                Spacer()
            }
            PadLab("Deleting your account, your own training, Apple Watch and Health live under Everything else.", size: 12)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .sheet(isPresented: $changing) { ChangePasswordSheet() }
    }
}
