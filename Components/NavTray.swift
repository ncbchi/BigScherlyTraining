import SwiftUI

// MARK: - Floating hamburger (three bars) — upper LEFT, volt green, no bar
struct FloatingMenuButton: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showTray.toggle() }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(Brand.volt).frame(width: 26, height: 3)
                    }
                }
                .padding(10)
                // subtle dark backing so it stays legible over any content
                .background(Brand.bg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if store.unreadMessages > 0 || !store.liveAnnouncements.isEmpty {
                    Circle().fill(Brand.volt).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Brand.bg, lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }
        }
    }
}

// MARK: - Slide-in navigation tray
struct NavTray: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .trailing) {
            if store.showTray {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { withAnimation { store.showTray = false } }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hey, \(store.client.name.split(separator: " ").first.map(String.init) ?? store.client.name)!").font(BrandFont.display(28)).foregroundColor(.white)
                            Text("Let's get big 👑").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.volt)
                        }
                        Spacer()
                        Button { withAnimation { store.showTray = false } } label: {
                            Image(systemName: "xmark").foregroundColor(.white).font(.system(size: 18, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)

                    Rectangle().fill(Brand.line).frame(height: 1)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(AppTab.allCases) { tab in
                                trayRow(tab)
                            }
                        }
                        .padding(.vertical, 12)
                    }

                    Rectangle().fill(Brand.line).frame(height: 1)
                    Button { store.logout() } label: {
                        HStack {
                            Image(systemName: "arrow.right.square").foregroundColor(Brand.mute)
                            Text("Log Out").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                    }
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Brand.bg)
                .overlay(Rectangle().fill(Brand.volt).frame(width: 3), alignment: .leading)
                .transition(.move(edge: .trailing))
                // Swipe the tray back to the right to dismiss it — the mirror of the
                // right-edge swipe that opens it.
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { v in
                            if v.translation.width > 50 &&
                               abs(v.translation.width) > abs(v.translation.height) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    store.showTray = false
                                }
                            }
                        }
                )
            }
        }
    }

    func trayRow(_ tab: AppTab) -> some View {
        Button { store.select(tab) } label: {
            HStack(spacing: 16) {
                Image(systemName: tab.icon)
                    .frame(width: 24).foregroundColor(store.activeTab == tab ? Brand.black : Brand.volt)
                Text(tab.rawValue.uppercased())
                    .font(BrandFont.body(14, .bold)).tracking(1)
                    .foregroundColor(store.activeTab == tab ? Brand.black : Brand.white)
                Spacer()
                if tab == .chat && store.unreadMessages > 0 { badge("\(store.unreadMessages)") }
                if tab == .announcements && !store.liveAnnouncements.isEmpty { badge("\(store.liveAnnouncements.count)") }
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .background(store.activeTab == tab ? Brand.volt : Color.clear)
        }
    }
    func badge(_ t: String) -> some View {
        Text(t).font(BrandFont.body(11, .bold))
            .foregroundColor(Brand.black).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Brand.volt))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Brand.black, lineWidth: 1))
    }
}
