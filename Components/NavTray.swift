import SwiftUI
import UIKit

// MARK: - Floating menu button (three bars, upper right)
struct FloatingMenuButton: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Button {
            if !store.showTray { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showTray.toggle() }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(Brand.voltText).frame(width: 26, height: 3)
                    }
                }
                .padding(10)
                // Solid backing with a hairline edge: content scrolling under the button
                // is cleanly covered, not smeared through a translucent square.
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line, lineWidth: 1))

                if store.unreadMessages > 0 || !store.liveAnnouncements.isEmpty {
                    Circle().fill(Brand.volt).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Brand.bg, lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .accessibilityLabel("Menu")
    }
}

// MARK: - Menu groups and your layout (Settings ▸ Menu order)

enum MenuGroup: String, CaseIterable, Identifiable {
    case train = "Train", fuel = "Fuel", progress = "Progress", connect = "Connect"
    var id: String { rawValue }
    var tabs: [AppTab] {
        switch self {
        case .train: return [.dashboard, .workouts, .history]
        case .fuel: return [.macros, .supplements]
        case .progress: return [.checkins, .photos, .awards]
        case .connect: return [.chat, .announcements, .share]
        }
    }
}

/// Your menu layout: the order within each group, and which screens are hidden.
enum MenuLayout {
    static let orderKey = "bst_menu_order"
    static let hiddenKey = "bst_menu_hidden"

    static var order: [String] {
        get { UserDefaults.standard.string(forKey: orderKey)?.split(separator: ",").map(String.init) ?? [] }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: orderKey) }
    }
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.string(forKey: hiddenKey)?.split(separator: ",").map(String.init) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: ","), forKey: hiddenKey) }
    }
    /// A group's screens in your order (hidden ones included — the editor shows them).
    static func ordered(_ g: MenuGroup) -> [AppTab] {
        let o = order
        func rank(_ t: AppTab) -> (Int, Int) { (o.firstIndex(of: t.rawValue) ?? Int.max, g.tabs.firstIndex(of: t) ?? 0) }
        return g.tabs.sorted { rank($0) < rank($1) }
    }
    static func visible(_ g: MenuGroup) -> [AppTab] { ordered(g).filter { !hidden.contains($0.rawValue) } }
}

// MARK: - Slide-in menu

struct NavTray: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var theme = ThemeStore.shared
    @State private var confirmLogout = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if store.showTray {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)

                    panel
                        .frame(width: min(geo.size.width * 0.86, 360))
                        .frame(maxHeight: .infinity)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 30)
                                .fill(Brand.bg)
                                .shadow(color: .black.opacity(0.35), radius: 20, x: -8, y: 0)
                                .ignoresSafeArea()
                        )
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 30)
                                .stroke(Brand.line, lineWidth: 1)
                                .ignoresSafeArea()
                        )
                        .transition(.move(edge: .trailing))
                        // Swipe back to the right to close — the mirror of the edge swipe that opens it.
                        .gesture(
                            DragGesture(minimumDistance: 12).onEnded { v in
                                if v.translation.width > 50 && abs(v.translation.width) > abs(v.translation.height) { close() }
                            }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(store.showTray)     // closed: touches go straight to the screen underneath
        .confirmationDialog(store.isDemoMode ? "Leave Demo Mode?" : "Log out of Big Scherly?",
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button(store.isDemoMode ? "Exit demo" : "Log out", role: .destructive) {
                close()
                store.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.isDemoMode ? "You'll go back to the sign-in screen." : "Your workouts and notes stay safe on your account.")
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showTray = false }
    }

    // MARK: The panel

    private var panel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundColor(Brand.mute)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Close menu")
                }
                .padding(.bottom, -6)

                profile

                ForEach(MenuGroup.allCases) { g in
                    let tabs = MenuLayout.visible(g)
                    if !tabs.isEmpty {
                        section(g.rawValue.uppercased()) {
                            ForEach(tabs) { tab in
                                row(icon: tab.icon, title: tab.rawValue, on: store.activeTab == tab, trailing: trailing(for: tab)) {
                                    store.select(tab)
                                }
                            }
                        }
                    }
                }

                section("SETTINGS") {
                    row(icon: AppTab.settings.icon, title: "Settings", on: store.activeTab == .settings, trailing: nil) {
                        store.select(.settings)
                    }
                    row(icon: theme.choice.icon, title: "Appearance", on: false,
                        trailing: AnyView(HStack(spacing: 5) {
                            Text(theme.choice.label).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
                        })) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        theme.cycle()                 // Dark → Light → System → Custom
                    }
                    row(icon: "rectangle.portrait.and.arrow.right", title: store.isDemoMode ? "Exit demo" : "Log out",
                        on: false, trailing: nil, muted: true) {
                        confirmLogout = true
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
    }

    // MARK: Profile card: initials with this week's progress ring

    private var firstName: String { store.client.name.split(separator: " ").first.map(String.init) ?? store.client.name }
    private var initials: String {
        let parts = store.client.name.split(separator: " ")
        let a = parts.first?.first.map(String.init) ?? ""
        let b = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (a + b).uppercased()
    }
    private var weekProgress: (done: Int, planned: Int) {
        let cal = Calendar.training, now = Date()
        let week = store.workouts.filter { cal.isSameTrainingWeek($0.date, now) }
        return (week.filter { $0.completed }.count, week.count)
    }

    private var profile: some View {
        let p = weekProgress
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Brand.text.opacity(0.10), lineWidth: 3.5)
                Circle().trim(from: 0, to: p.planned > 0 ? Double(p.done) / Double(p.planned) : 0)
                    .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(Brand.volt).padding(6)
                Text(initials.isEmpty ? "👑" : initials).font(BrandFont.display(20)).foregroundColor(Brand.onVolt)
            }
            .frame(width: 56, height: 56)
            .accessibilityLabel("\(p.done) of \(p.planned) sessions this week")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Hey, \(firstName)!").font(BrandFont.body(18, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                    if store.isDemoMode {
                        Text("DEMO").font(BrandFont.body(9, .heavy)).tracking(1).headerPill()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
                    }
                }
                Text("Let's Get Big! 👑").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
        .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
    }

    // MARK: Groups and rows

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BrandFont.body(11, .heavy)).tracking(1.8).headerPill().padding(.leading, 2)
            VStack(spacing: 0) { rows() }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
                .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
        }
    }

    private func row(icon: String, title: String, on: Bool, trailing: AnyView?, muted: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundColor(on ? Brand.onVolt : (muted ? Brand.mute : Brand.voltText))
                    .frame(width: 22)
                Text(title).font(BrandFont.body(15, .bold))
                    .foregroundColor(on ? Brand.onVolt : (muted ? Brand.mute : Brand.text))
                Spacer(minLength: 6)
                if !on, let trailing { trailing }
            }
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: What each row shows on the right

    private func trailing(for tab: AppTab) -> AnyView? {
        switch tab {
        case .chat where store.unreadMessages > 0:
            return AnyView(badge("\(store.unreadMessages)"))
        case .announcements where !store.liveAnnouncements.isEmpty:
            return AnyView(badge("\(store.liveAnnouncements.count)"))
        case .workouts:
            let cal = Calendar.training
            if store.workouts.contains(where: { cal.isDateInToday($0.date) && !$0.completed }) { return AnyView(hint("Today")) }
        case .checkins:
            if let last = store.checkIns.filter({ $0.status != .draft }).map(\.date).max() {
                let cal = Calendar.training
                let since = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: Date())).day ?? 0
                let days = 7 - since
                return AnyView(hint(days <= 0 ? "Due" : "\(days)d"))
            }
        case .supplements:
            let cal = Calendar.current
            let left = store.supplements.filter { s in
                !store.supplementLogs.contains { $0.supplementId == s.id && $0.status == .taken && cal.isDateInToday($0.takenAt ?? .distantPast) }
            }.count
            if left > 0 { return AnyView(hint("\(left) left")) }
        default:
            break
        }
        return nil
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.onVolt)
            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Brand.volt))
    }
}
