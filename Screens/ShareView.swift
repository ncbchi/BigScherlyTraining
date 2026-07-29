import SwiftUI
import PhotosUI

// MARK: - Share tab
// Photo with a volt-green stat border + logo watermark. User picks which stats
// show. Share button opens a drawer (social targets + Apple share sheet).
// Instagram's two native formats. Rendering at these exact pixel sizes keeps the
// export sharp instead of letting Instagram upscale a small image.
enum ShareFormat: String, CaseIterable, Identifiable {
    case post  = "Post 4:5"
    case story = "Story 9:16"
    var id: String { rawValue }

    /// Canonical layout size the card is always composed at. Everything (fonts,
    /// padding) is designed against this, so the card looks identical whether it's
    /// shown small in the preview or exported at full resolution.
    var layoutWidth: CGFloat { 360 }
    var layoutHeight: CGFloat { self == .post ? 450 : 640 }

    /// Exported at Instagram's native pixel size: 1080×1350 (post) / 1080×1920 (story).
    var exportScale: CGFloat { 3.0 }
}

struct ShareView: View {
    @EnvironmentObject var store: AppStore
    @State private var enabled: Set<ShareStats.Field> = [.totalWeight, .duration, .topLift, .date]
    @State private var format: ShareFormat = .story
    @State private var showDrawer = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var chosenImage: UIImage?
    @State private var showShareSheet = false
    @State private var renderedCard: UIImage?
    @State private var showTagReminder = false
    @State private var pendingImage: UIImage?
    @State private var pendingTarget: SocialTarget = .instagram

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(text: "Show It Off")
                    Text("Share").font(BrandFont.display(48)).foregroundColor(.white)
                    Text("Snap a shot of today's win. Pick what to show on the border, then share.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    // Format — Story gives far more room for the PR to be the hero.
                    Text("FORMAT").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    HStack(spacing: 10) {
                        ForEach(ShareFormat.allCases) { f in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { format = f }
                            } label: {
                                Text(f.rawValue)
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundColor(format == f ? Brand.black : .white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(format == f ? Brand.volt : Brand.black).clipShape(Capsule())
                                    .overlay(Capsule().stroke(format == f ? Brand.volt : Brand.line, lineWidth: 1))
                            }
                        }
                    }

                    // The share card — full width, as it was. Composed at its canonical
                    // size and scaled up to fill the screen width.
                    let cw = UIScreen.main.bounds.width - 40      // matches the 20pt side padding
                    let s = cw / format.layoutWidth
                    shareCard
                        .frame(width: format.layoutWidth, height: format.layoutHeight)
                        .scaleEffect(s)
                        .frame(width: cw, height: format.layoutHeight * s)
                        .padding(.vertical, 8)
                        .onAppear {
                            // Arriving here from a celebration — show it by default.
                            if store.awardToShare?.isShareable == true {
                                enabled.insert(.award)
                            } else if store.lastPRForShare != nil {
                                enabled.insert(.personalRecord)
                            }
                        }

                    // Field picker
                    Text("SHOW ON CARD").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    let cols = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        // "New PR" only makes sense when there's actually a record to show.
                        let fields = ShareStats.Field.allCases.filter { f in
                            if f == .personalRecord { return store.lastPRForShare != nil }
                            // Never offer to share a non-shareable award (dose streak).
                            if f == .award { return store.awardToShare?.isShareable == true }
                            return true
                        }
                        ForEach(fields, id: \.self) { f in
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

                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        HStack { Image(systemName: "camera.fill"); Text(chosenImage == nil ? "Take / Choose Photo" : "Change Photo") }
                            .font(BrandFont.body(14, .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 2))
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

            if showDrawer { ShareDrawer(show: $showDrawer, onShare: routeShare) }
        }
        .sheet(isPresented: $showShareSheet) {
            if let img = renderedCard { ActivityView(items: [img]) }
        }
        .alert("Tag your coach!", isPresented: $showTagReminder) {
            Button("Got it — open \(pendingTarget == .facebook ? "Facebook" : "Instagram")") {
                launchPendingStory()
            }
            Button("Cancel", role: .cancel) { pendingImage = nil }
        } message: {
            Text("Before you post, remember to tag @big.scherly so we can find your win and reshare it. 👑")
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    await MainActor.run { chosenImage = ui; pickedItem = nil }
                } else {
                    await MainActor.run { pickedItem = nil }
                }
            }
        }
    }

    // Renders the finished card once, then routes it based on which button was tapped.
    // Instagram/Facebook deep-link into their Story composer (after a tag reminder);
    // everything else opens the iOS share sheet.
    @MainActor func routeShare(_ target: SocialTarget) {
        let renderer = ImageRenderer(
            content: shareCard
                .frame(width: format.layoutWidth, height: format.layoutHeight)
                .background(Color.black))
        renderer.scale = format.exportScale
        renderer.isOpaque = true
        guard let img = renderer.uiImage else { showDrawer = false; return }
        renderedCard = img
        showDrawer = false

        switch target {
        case .instagram, .facebook:
            // If the app is installed, remind the user to tag, then launch its composer.
            // If not installed, quietly fall back to the share sheet.
            if SocialShare.isAvailable(target) {
                pendingImage = img
                pendingTarget = target
                showTagReminder = true
            } else {
                showShareSheet = true
            }
        case .systemSheet:
            showShareSheet = true
        }
    }

    @MainActor private func launchPendingStory() {
        guard let img = pendingImage else { return }
        let ok = SocialShare.shareToStory(img, target: pendingTarget)
        if !ok { showShareSheet = true }   // not installed after all — fall back
        pendingImage = nil
    }

    var shareCard: some View {
        ZStack {
            // Photo — fills the card's fixed canonical frame.
            Rectangle().fill(Brand.black)
                .overlay(
                    Group {
                        if let img = chosenImage {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Image("photo_front").resizable().scaledToFill()
                        }
                    }
                )
                .overlay(
                    Image(systemName: "photo").foregroundColor(Brand.mute).font(.system(size: 40))
                        .opacity(chosenImage == nil && UIImage(named: "photo_front") == nil ? 1 : 0)
                )
                .clipped()

            // Scrim behind the text so stats stay readable on a bright photo.
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            // Stat overlay
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if enabled.contains(.date) { statChip(dateLabel(store.shareStats.date)) }
                    Spacer()
                    Image("logoVolt")
                        .resizable().scaledToFit()
                        .frame(width: 120)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }

                // NEW PR — sits high under the header, sized to complement the photo
                // rather than cover it.
                // Award badge — only awards flagged shareable, and only their
                // share-safe stats (supplement counts are stripped upstream).
                if enabled.contains(.award), let aw = store.awardToShare, aw.isShareable {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: aw.icon)
                                .font(.system(size: 7)).foregroundColor(Brand.black)
                            Text(aw.title.uppercased())
                                .font(BrandFont.body(7, .bold)).tracking(1.2)
                                .foregroundColor(Brand.black)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Brand.volt).clipShape(Capsule())

                        if let s0 = aw.shareStats.first {
                            Text(s0.value)
                                .font(BrandFont.display(20)).foregroundColor(.white)
                                .shadow(color: .black.opacity(0.7), radius: 4)
                            Text(s0.label)
                                .font(BrandFont.body(7, .bold)).tracking(1.2)
                                .foregroundColor(Brand.volt)
                                .shadow(color: .black.opacity(0.7), radius: 3)
                        }
                    }
                    .padding(.top, 10)
                }

                if enabled.contains(.personalRecord), let pr = store.lastPRForShare {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 7)).foregroundColor(Brand.black)
                            Text(pr.isFirstEver ? "FIRST RECORD" : "NEW PR")
                                .font(BrandFont.body(7, .bold)).tracking(1.2).foregroundColor(Brand.black)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Brand.volt).clipShape(Capsule())

                        Text("\(pr.reps)×\(Int(pr.weight))")
                            .font(BrandFont.display(20))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.7), radius: 4)
                        Text(pr.exercise.uppercased())
                            .font(BrandFont.body(7, .bold)).tracking(1.2)
                            .foregroundColor(Brand.volt)
                            .shadow(color: .black.opacity(0.7), radius: 3)
                    }
                    .padding(.top, 10)
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
        // Round the whole card and inset the border so Instagram/Facebook's
        // rounded-corner story crop can't clip the edge or the volt frame.
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .inset(by: 2.5)
                .stroke(Brand.volt, lineWidth: 5)
        )
        .padding(10)
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
            .padding(.horizontal, 10).padding(.vertical, 5).background(Brand.volt).clipShape(Capsule())
    }
    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d) }
}

// MARK: - Share drawer (pulls up from bottom)
struct ShareDrawer: View {
    @Binding var show: Bool
    let onShare: (SocialTarget) -> Void       // parent renders the card + routes

    let socials: [(String, String, SocialTarget)] = [
        ("Instagram", "camera.circle.fill", .instagram),
        ("Facebook", "f.circle.fill", .facebook),
        ("X / Twitter", "x.circle.fill", .systemSheet),
        ("Bluesky", "cloud.circle.fill", .systemSheet),
        ("TikTok", "music.note.tv.fill", .systemSheet),
        ("Threads", "at.circle.fill", .systemSheet)
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
                        Button { onShare(s.2) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: s.1).font(.system(size: 30)).foregroundColor(Brand.volt)
                                Text(s.0).font(BrandFont.body(11, .semibold)).foregroundColor(.white)
                                // Show which ones jump straight into the app.
                                if s.2.canDeepLink {
                                    Text("DIRECT").font(BrandFont.body(7, .bold)).tracking(0.8)
                                        .foregroundColor(Brand.volt.opacity(0.8))
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16).card(padding: 0)
                        }
                    }
                }

                // Apple system share sheet
                Button { onShare(.systemSheet) } label: {
                    HStack { Image(systemName: "square.and.arrow.up"); Text("More — Messages, Mail, AirDrop…") }
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 16).background(Brand.volt)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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

// MARK: - System share sheet wrapper
// Presents UIActivityViewController so the rendered card can go to Instagram,
// Messages, Mail, AirDrop, Photos, or anywhere the user has installed.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
