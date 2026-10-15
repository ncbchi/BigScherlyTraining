import SwiftUI

// MARK: - New announcement
// Pulls up from the bottom shortly after the app opens when the coach has posted
// an announcement the client hasn't seen yet. "Got it" remembers it (so it never
// pops up again); "Read later" or swiping it down shows it again next launch.
// Everything stays readable in Menu ▸ Announcements either way.
//
// Drawn as an overlay inside the app shell (not a system sheet), so it can never
// collide with the PR / award celebrations that present at launch.

enum AnnouncementSeen {
    private static let key = "bst_seen_announcements"
    static var ids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func mark(_ id: String) {
        var s = ids; s.insert(id)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
    /// Only announcements this fresh pop up — an old backlog shouldn't greet a returning client.
    static let freshFor: TimeInterval = 3 * 86400
}

struct NewAnnouncementSheet: View {
    let items: [Announcement]          // newest first
    let onDone: () -> Void

    @State private var index = 0
    @State private var shown = false
    @State private var drag: CGFloat = 0

    private var item: Announcement { items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.58 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                .offset(y: shown ? drag : 700)
                .gesture(
                    DragGesture()
                        .onChanged { drag = max(0, $0.translation.height) }
                        .onEnded { v in
                            if v.translation.height > 110 { close() }
                            else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 } }
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Brand.mute.opacity(0.5)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                Image(systemName: "megaphone.fill").font(.system(size: 15, weight: .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 34, height: 34).background(Circle().fill(Brand.volt))
                Text("NEW ANNOUNCEMENT").font(BrandFont.body(11, .heavy)).tracking(1.8).headerPill()
                Spacer(minLength: 0)
                if items.count > 1 {
                    Text("\(index + 1) of \(items.count)").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                }
            }
            Text(item.title).font(BrandFont.display(38)).foregroundColor(Brand.text)
                .lineLimit(3).minimumScaleFactor(0.7)
            Text("Coach Scherly · \(stamp(item.date))")
                .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            Text(item.body).font(BrandFont.body(15)).foregroundColor(Brand.text.opacity(0.88))
                .lineSpacing(4).lineLimit(9)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { close() } label: { Text("Read later") }
                    .buttonStyle(NASecondaryStyle())
                Button {
                    AnnouncementSeen.mark(item.id)
                    if index + 1 < items.count {
                        withAnimation(.easeInOut(duration: 0.2)) { index += 1 }
                    } else {
                        close()
                    }
                } label: { Label("Got it", systemImage: "checkmark") }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30)
                .fill(Brand.black)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30).stroke(Brand.line, lineWidth: 1))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.22)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onDone() }
    }

    private func stamp(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(d) { return "Today, \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday, \(time)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}

private struct NASecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(15, .bold)).tracking(0.3)
            .foregroundColor(Brand.text)
            .frame(minHeight: 48).padding(.horizontal, 22)
            .background(Capsule().fill(Brand.text.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
