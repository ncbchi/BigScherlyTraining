import SwiftUI

// MARK: - Share tab
// Photo with a volt-green stat border + logo watermark. User picks which stats
// show. Share button opens a drawer (social targets + Apple share sheet).
struct ShareView: View {
    @EnvironmentObject var store: AppStore
    @State private var enabled: Set<ShareStats.Field> = [.totalWeight, .duration, .topLift, .date]
    @State private var showDrawer = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(text: "Show It Off")
                    Text("Share").font(BrandFont.display(48)).foregroundColor(.white)
                    Text("Snap a shot of today's win. Pick what to show on the border, then share.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    // The share card
                    shareCard
                        .padding(.vertical, 8)

                    // Field picker
                    Text("SHOW ON CARD").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    let cols = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(ShareStats.Field.allCases, id: \.self) { f in
                            Button {
                                if enabled.contains(f) { enabled.remove(f) } else { enabled.insert(f) }
                            } label: {
                                HStack {
                                    Image(systemName: enabled.contains(f) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(enabled.contains(f) ? Brand.volt : Brand.mute)
                                    Text(f.rawValue).font(BrandFont.body(13, .semibold)).foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(12).card(padding: 0).padding(.leading, 12)
                            }
                        }
                    }

                    Button {} label: {
                        HStack { Image(systemName: "camera.fill"); Text("Take / Choose Photo") }
                            .font(BrandFont.body(14, .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .overlay(Rectangle().stroke(Brand.volt, lineWidth: 2))
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
            }

            // Floating share button (bottom-right)
            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDrawer = true } } label: {
                Image(systemName: "square.and.arrow.up").foregroundColor(Brand.black).font(.system(size: 22, weight: .bold))
                    .frame(width: 62, height: 62).background(Circle().fill(Brand.volt))
                    .shadow(color: Brand.volt.opacity(0.4), radius: 12)
            }
            .padding(24)

            if showDrawer { ShareDrawer(show: $showDrawer) }
        }
    }

    var shareCard: some View {
        ZStack {
            // Photo placeholder
            Rectangle().fill(Brand.black).aspectRatio(0.8, contentMode: .fit)
                .overlay(Image("photo_front").resizable().scaledToFill())
                .overlay(
                    Image(systemName: "photo").foregroundColor(Brand.mute).font(.system(size: 40))
                        .opacity(UIImage(named: "photo_front") == nil ? 1 : 0)
                )
                .clipped()

            // Stat border overlay
            VStack {
                HStack {
                    if enabled.contains(.date) { statChip(dateLabel(store.shareStats.date)) }
                    Spacer()
                    // Logo watermark — volt-green Big Scherly badge
                    Image("logoVolt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }
                Spacer()
                // Bottom stats
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if enabled.contains(.totalWeight) { bigStat("\(Int(store.shareStats.totalWeight))", "LB LIFTED") }
                        if enabled.contains(.topLift) { statChip(store.shareStats.topLift) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if enabled.contains(.duration) { bigStat(store.shareStats.duration, "DURATION") }
                        if enabled.contains(.setCount) { statChip("\(store.shareStats.setCount) SETS") }
                    }
                }
            }
            .padding(18)
        }
        .overlay(Rectangle().stroke(Brand.volt, lineWidth: 5))
    }

    func bigStat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(BrandFont.display(32)).foregroundColor(Brand.volt)
            Text(l).font(BrandFont.body(9, .bold)).tracking(1.5).foregroundColor(.white)
        }
        .shadow(color: .black, radius: 4)
    }
    func statChip(_ t: String) -> some View {
        Text(t).font(BrandFont.body(11, .bold)).foregroundColor(Brand.black)
            .padding(.horizontal, 10).padding(.vertical, 5).background(Brand.volt)
    }
    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d) }
}

// MARK: - Share drawer (pulls up from bottom)
struct ShareDrawer: View {
    @Binding var show: Bool

    let socials: [(String, String)] = [
        ("Instagram", "camera.circle.fill"),
        ("Facebook", "f.circle.fill"),
        ("X / Twitter", "x.circle.fill"),
        ("Bluesky", "cloud.circle.fill"),
        ("TikTok", "music.note.tv.fill"),
        ("Threads", "at.circle.fill")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { withAnimation { show = false } }
            VStack(alignment: .leading, spacing: 20) {
                Capsule().fill(Brand.mute).frame(width: 40, height: 4).frame(maxWidth: .infinity)
                Text("Share Your Win").font(BrandFont.display(28)).foregroundColor(.white)

                // Social grid
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(socials, id: \.0) { s in
                        Button {} label: {
                            VStack(spacing: 8) {
                                Image(systemName: s.1).font(.system(size: 30)).foregroundColor(Brand.volt)
                                Text(s.0).font(BrandFont.body(11, .semibold)).foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16).card(padding: 0)
                        }
                    }
                }

                // Apple system share sheet
                Button {} label: {
                    HStack { Image(systemName: "square.and.arrow.up"); Text("More — Messages, Mail, AirDrop…") }
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 16).background(Brand.volt)
                }
                Button { withAnimation { show = false } } label: {
                    Text("Cancel").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .padding(24).padding(.bottom, 12)
            .background(Brand.bg)
            .overlay(Rectangle().fill(Brand.volt).frame(height: 3), alignment: .top)
            .transition(.move(edge: .bottom))
        }
    }
}
