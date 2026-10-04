import SwiftUI
import PhotosUI

// MARK: - Share formats
// Rendered at Instagram's native pixel sizes so the export stays sharp.
enum ShareFormat: String, CaseIterable, Identifiable {
    case story  = "Story 9:16"
    case post   = "Post 4:5"
    case square = "Square 1:1"
    var id: String { rawValue }
    var short: String { rawValue.components(separatedBy: " ").first ?? rawValue }

    /// Canonical layout size the card is always composed at (fonts and padding are designed
    /// against it), so the preview and the export look identical.
    var layoutWidth: CGFloat { 360 }
    var layoutHeight: CGFloat {
        switch self {
        case .story: return 640
        case .post: return 450
        case .square: return 360
        }
    }
    /// 1080 wide: 1080×1920 story, 1080×1350 post, 1080×1080 square.
    var exportScale: CGFloat { 3.0 }
}

// MARK: - Share tab: Studio (styled cards) and Stickers (place your own)

enum ShareMode: String, CaseIterable, Identifiable {
    case studio = "Studio", stickers = "Stickers"
    var id: String { rawValue }
    var icon: String { self == .studio ? "rectangle.on.rectangle.angled" : "sparkles.rectangle.stack" }
}

enum ShareCardStyle: String, CaseIterable, Identifiable {
    case frame = "Frame", stats = "Stats", pr = "PR", minimal = "Minimal"
    var id: String { rawValue }
}

enum StickerKind: String, CaseIterable, Identifiable {
    case pr = "PR", workout = "Workout", stats = "Stats", streak = "Streak", topLift = "Top lift",
         date = "Date", logo = "Logo", award = "Award"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pr: return "trophy.fill"
        case .workout: return "dumbbell.fill"
        case .stats: return "chart.bar.fill"
        case .streak: return "flame.fill"
        case .topLift: return "arrow.up.circle.fill"
        case .date: return "calendar"
        case .logo: return "crown.fill"
        case .award: return "rosette"
        }
    }
}

struct PlacedSticker: Identifiable, Equatable {
    let id = UUID()
    var kind: StickerKind
    var position: CGPoint          // centre, in the card's layout coordinates
    var scale: CGFloat = 1
    var tilt: Double = 0
}

struct ShareView: View {
    @EnvironmentObject var store: AppStore
    @State private var mode: ShareMode = .studio
    @State private var format: ShareFormat = .story
    @State private var style: ShareCardStyle = .frame
    @State private var enabled: Set<ShareStats.Field> = [.totalWeight, .duration, .topLift, .date]
    @State private var stickers: [PlacedSticker] = []
    @State private var selected: UUID? = nil

    @State private var pickedItem: PhotosPickerItem?
    @State private var chosenImage: UIImage?
    @State private var showCamera = false
    @State private var showCameraDenied = false

    @State private var showShareSheet = false
    @State private var renderedCard: UIImage?
    @State private var showTagReminder = false
    @State private var pendingImage: UIImage?
    @State private var pendingTarget: SocialTarget = .instagram

    private var stats: ShareStats { store.shareStats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "Show it off", title: "Share")

                segmented(ShareMode.allCases, mode, label: { $0.rawValue }, icon: { $0.icon }) { m in
                    withAnimation(.easeInOut(duration: 0.2)) { mode = m }
                    if m == .stickers && stickers.isEmpty { placeStarterStickers() }
                }

                formatPills

                preview

                photoRow

                if mode == .studio { studioControls } else { stickerControls }

                shareDock

                Text("Tag @big.scherly so we can find your win and reshare it 👑")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 32)     // clear of the ☰ button, like the other screens
        }
        .background(Brand.bg.ignoresSafeArea())
        .onAppear {
            // Arriving from a celebration: show it by default.
            if store.awardToShare?.isShareable == true { enabled.insert(.award) }
            else if store.lastPRForShare != nil { enabled.insert(.personalRecord) }
        }
        .sheet(isPresented: $showShareSheet) {
            if let img = renderedCard {
                ActivityView(items: [img]) { activity in
                    // Only social destinations mark the calendar.
                    if let platform = ShareLog.platformName(forActivity: activity) {
                        ShareLog.shared.record(workoutDate: stats.date, platform: platform)
                    }
                }
            }
        }
        .alert("Tag your coach!", isPresented: $showTagReminder) {
            Button("Got it — open \(pendingTarget == .facebook ? "Facebook" : "Instagram")") { launchPendingStory() }
            Button("Cancel", role: .cancel) { pendingImage = nil }
        } message: {
            Text("Before you post, remember to tag @big.scherly so we can find your win and reshare it. 👑")
        }
        .alert("Camera access is off", isPresented: $showCameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on Camera for Big Scherly Training in Settings to snap your share photo here.")
        }
        .fullScreenCover(isPresented: $showCamera) {
            // Live viewfinder inside the card: the same overlay, with a clear photo area.
            ShareCameraView(format: format, chrome: AnyView(card(editable: false) { Color.clear })) { image in
                if let image { chosenImage = image }
                showCamera = false
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    await MainActor.run { chosenImage = ui; pickedItem = nil }
                } else {
                    await MainActor.run { pickedItem = nil }
                }
            }
        }
    }

    // MARK: Controls

    private func segmented<T: Hashable>(_ items: [T], _ current: T, label: @escaping (T) -> String,
                                        icon: @escaping (T) -> String?, pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { it in
                let on = it == current
                Button { pick(it) } label: {
                    HStack(spacing: 6) {
                        if let i = icon(it) { Image(systemName: i).font(.system(size: 13, weight: .semibold)) }
                        Text(label(it)).font(BrandFont.body(14, .bold))
                    }
                    .foregroundColor(on ? Brand.onVolt : Brand.text)
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Brand.text.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var formatPills: some View {
        HStack(spacing: 8) {
            ForEach(ShareFormat.allCases) { f in
                let on = f == format
                Button { withAnimation(.easeInOut(duration: 0.2)) { format = f; keepStickersInside() } } label: {
                    Text(f.short).font(BrandFont.body(13, .bold))
                        .foregroundColor(on ? Brand.onVolt : Brand.text)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Capsule().fill(on ? Brand.volt : Color.clear))
                        .overlay(Capsule().stroke(on ? Color.clear : Brand.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(format.rawValue.components(separatedBy: " ").last ?? "").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
        }
    }

    /// The card, composed at its layout size and scaled to fit.
    private var preview: some View {
        let maxW = UIScreen.main.bounds.width - 40
        let maxH: CGFloat = 470
        let s = min(maxW / format.layoutWidth, maxH / format.layoutHeight)
        return card(editable: mode == .stickers) { photoLayer }
            .frame(width: format.layoutWidth, height: format.layoutHeight)
            .scaleEffect(s)
            .frame(width: format.layoutWidth * s, height: format.layoutHeight * s)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
    }

    private var photoRow: some View {
        HStack(spacing: 8) {
            if CameraPicker.isAvailable {
                Button {
                    Task {
                        let ok = await CameraAccess.request()
                        await MainActor.run { if ok { showCamera = true } else { showCameraDenied = true } }
                    }
                } label: { sourceButton("camera.fill", chosenImage == nil ? "Camera" : "Retake") }
                .buttonStyle(.plain)
            }
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                sourceButton("photo.on.rectangle", "Library")
            }
            .buttonStyle(.plain)
            if chosenImage != nil {
                Button { withAnimation { chosenImage = nil } } label: { sourceButton("xmark", "Remove") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func sourceButton(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(title) }
            .font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
    }

    // Studio: styles and what's on the card
    private var studioControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STYLE").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            HStack(spacing: 8) {
                ForEach(ShareCardStyle.allCases) { st in
                    let on = st == style
                    Button { withAnimation(.easeInOut(duration: 0.2)) { style = st } } label: {
                        VStack(spacing: 6) {
                            styleThumb(st, on: on)
                            Text(st.rawValue).font(BrandFont.body(11, .bold)).foregroundColor(on ? Brand.text : Brand.mute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("ON THE CARD").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            let fields = ShareStats.Field.allCases.filter { f in
                if f == .personalRecord { return store.lastPRForShare != nil }
                if f == .award { return store.awardToShare?.isShareable == true }   // never a non-shareable award
                return true
            }
            FlowChips(items: fields.map { $0.rawValue }, on: Set(enabled.map { $0.rawValue })) { raw in
                guard let f = ShareStats.Field(rawValue: raw) else { return }
                if enabled.contains(f) { enabled.remove(f) } else { enabled.insert(f) }
            }
        }
    }

    private func styleThumb(_ st: ShareCardStyle, on: Bool) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16))
            switch st {
            case .frame:
                RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.volt, lineWidth: 3)
                Capsule().fill(Brand.volt).frame(width: 26, height: 5).padding(.bottom, 9)
            case .stats:
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)).frame(height: 24).padding(5)
            case .pr:
                VStack(spacing: 3) {
                    Capsule().fill(Brand.volt).frame(width: 22, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 30, height: 11)
                }
                .frame(maxHeight: .infinity)
            case .minimal:
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: 32, height: 6)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .frame(height: 74)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Brand.voltText : Color.clear, lineWidth: 2).padding(-3))
    }

    // Stickers: the tray
    private var stickerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("STICKERS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                if !stickers.isEmpty {
                    Button("Clear") { withAnimation { stickers.removeAll(); selected = nil } }
                        .font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                }
            }
            Text("Tap to add · drag to place · pinch to resize · double-tap to remove")
                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableStickers) { k in
                        Button { add(k) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: k.icon).font(.system(size: 12, weight: .bold))
                                Text(k.rawValue).font(BrandFont.body(13, .bold))
                            }
                            .foregroundColor(k == .pr ? Brand.onVolt : Brand.text)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Capsule().fill(k == .pr ? Brand.volt : Brand.card))
                            .overlay(Capsule().stroke(k == .pr ? Color.clear : Brand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var availableStickers: [StickerKind] {
        StickerKind.allCases.filter { k in
            if k == .pr { return store.lastPRForShare != nil }
            if k == .award { return store.awardToShare?.isShareable == true }
            return true
        }
    }

    private var shareDock: some View {
        HStack(spacing: 0) {
            dockButton("camera.circle.fill", "Instagram", filled: true) { routeShare(.instagram) }
            dockButton("f.circle.fill", "Facebook", filled: false) { routeShare(.facebook) }
            dockButton("square.and.arrow.up", "More", filled: false) { routeShare(.systemSheet) }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
        .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
    }

    private func dockButton(_ icon: String, _ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                    .foregroundColor(filled ? Brand.onVolt : Brand.text)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 18).fill(filled ? Brand.volt : Brand.text.opacity(0.06)))
                Text(title).font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: Sticker editing

    private func add(_ k: StickerKind) {
        let w = format.layoutWidth, h = format.layoutHeight
        let n = Double(stickers.count)
        let p = CGPoint(x: w / 2 + CGFloat((n.truncatingRemainder(dividingBy: 3)) - 1) * 40,
                        y: h * 0.4 + CGFloat(n.truncatingRemainder(dividingBy: 4)) * 30)
        let tilts: [Double] = [-5, 3, -2, 5, 0]
        let st = PlacedSticker(kind: k, position: p, tilt: tilts[stickers.count % tilts.count])
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { stickers.append(st); selected = st.id }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func placeStarterStickers() {
        let w = format.layoutWidth, h = format.layoutHeight
        if store.lastPRForShare != nil {
            stickers.append(PlacedSticker(kind: .pr, position: CGPoint(x: w * 0.36, y: h * 0.2), tilt: -5))
        } else {
            stickers.append(PlacedSticker(kind: .workout, position: CGPoint(x: w * 0.42, y: h * 0.2), tilt: -3))
        }
        stickers.append(PlacedSticker(kind: .stats, position: CGPoint(x: w * 0.6, y: h * 0.72), tilt: 3))
        stickers.append(PlacedSticker(kind: .logo, position: CGPoint(x: w * 0.3, y: h * 0.9)))
    }

    /// After a format change, pull anything outside the card back in.
    private func keepStickersInside() {
        for i in stickers.indices {
            stickers[i].position.x = min(max(stickers[i].position.x, 30), format.layoutWidth - 30)
            stickers[i].position.y = min(max(stickers[i].position.y, 30), format.layoutHeight - 30)
        }
    }

    // MARK: The card

    private var photoLayer: some View {
        Rectangle().fill(Color.black)
            .overlay(
                Group {
                    if let img = chosenImage { Image(uiImage: img).resizable().scaledToFill() }
                    else if UIImage(named: "photo_front") != nil { Image("photo_front").resizable().scaledToFill() }
                    else {
                        LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                            .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.white.opacity(0.25)))
                    }
                }
            )
            .clipped()
    }

    /// The card around any photo layer. The preview and export pass the real photo; the
    /// camera passes a clear layer so the live viewfinder shows through.
    func card<Photo: View>(editable: Bool, @ViewBuilder photo: () -> Photo) -> some View {
        ZStack {
            photo()
            if mode == .studio { studioOverlay } else { stickerLayer(editable: editable) }
        }
        .frame(width: format.layoutWidth, height: format.layoutHeight)
        .coordinateSpace(name: "shareCard")
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
            if mode == .studio && style == .frame {
                // Inset so Instagram's rounded story crop can't clip the frame.
                RoundedRectangle(cornerRadius: 28).inset(by: 2.5).stroke(Brand.volt, lineWidth: 5)
            }
        }
    }

    // MARK: Studio overlays

    @ViewBuilder private var studioOverlay: some View {
        switch style {
        case .frame: frameOverlay
        case .stats: statsOverlay
        case .pr: prOverlay
        case .minimal: minimalOverlay
        }
    }

    private var workoutTitle: String {
        store.workouts.first { Calendar.current.isDate($0.date, inSameDayAs: stats.date) }?.title ?? "Today's session"
    }
    private var liftedValue: String { StatsUnits.weightText(stats.totalWeight, unit: false) }
    private var liftedLabel: String { "\(StatsUnits.weightLabel.uppercased()) LIFTED" }
    private func dateLabel(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day().year()) }

    private var logo: some View {
        Image("logoVolt").renderingMode(.template).resizable().scaledToFit()
            .foregroundColor(Brand.volt)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private var scrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    /// Frame: the classic — date and logo up top, any PR or award, the numbers along the bottom.
    private var frameOverlay: some View {
        ZStack {
            scrim
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if enabled.contains(.date) { chip(dateLabel(stats.date)) }
                    Spacer()
                    logo.frame(width: 120)
                }
                badges.padding(.top, 10)
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if enabled.contains(.totalWeight) { bigStat(liftedValue, liftedLabel) }
                        if enabled.contains(.topLift) { chip(stats.topLift) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if enabled.contains(.duration) { bigStat(stats.duration, "DURATION", trailing: true) }
                        if enabled.contains(.setCount) { chip("\(stats.setCount) SETS") }
                    }
                }
            }
            .padding(20)
        }
    }

    /// Stats: a dark panel along the bottom with the workout and its numbers.
    private var statsOverlay: some View {
        ZStack {
            scrim
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    logo.frame(width: 96)
                    Spacer()
                    badges
                }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Text(workoutTitle.uppercased()).font(BrandFont.display(26)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
                    if enabled.contains(.date) {
                        Text(dateLabel(stats.date)).font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.volt)
                    }
                    let tiles: [(String, String)] = [
                        enabled.contains(.totalWeight) ? (liftedValue, liftedLabel) : nil,
                        enabled.contains(.duration) ? (stats.duration, "DURATION") : nil,
                        enabled.contains(.setCount) ? ("\(stats.setCount)", "SETS") : nil,
                    ].compactMap { $0 }
                    if !tiles.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.0).font(BrandFont.display(26)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
                                    Text(t.1).font(BrandFont.body(8, .heavy)).tracking(1).foregroundColor(.white.opacity(0.7))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if enabled.contains(.topLift) { chip(stats.topLift) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
            .padding(18)
        }
    }

    /// PR: the record, huge, in the middle (or the top lift when there's no PR).
    private var prOverlay: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                HStack {
                    logo.frame(width: 96)
                    Spacer()
                    if enabled.contains(.date) { chip(dateLabel(stats.date)) }
                }
                Spacer()
                if let pr = store.lastPRForShare {
                    pill(pr.isFirstEver ? "FIRST RECORD" : "NEW PR", icon: "trophy.fill")
                    Text("\(StatsUnits.weightText(pr.weight, unit: false)) × \(pr.reps)")
                        .font(BrandFont.display(84)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                    Text(pr.exercise.uppercased()).font(BrandFont.body(13, .heavy)).tracking(2).foregroundColor(Brand.volt)
                } else {
                    pill("TOP LIFT", icon: "arrow.up.circle.fill")
                    Text(stats.topLift.uppercased()).font(BrandFont.display(48)).foregroundColor(.white)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
                }
                Spacer()
                HStack(spacing: 18) {
                    if enabled.contains(.totalWeight) { smallStat(liftedValue, liftedLabel) }
                    if enabled.contains(.duration) { smallStat(stats.duration, "DURATION") }
                    if enabled.contains(.setCount) { smallStat("\(stats.setCount)", "SETS") }
                }
            }
            .padding(20)
        }
    }

    /// Minimal: the logo, the workout, one quiet line.
    private var minimalOverlay: some View {
        ZStack {
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                logo.frame(width: 84)
                Spacer()
                Text(workoutTitle.uppercased()).font(BrandFont.display(34)).foregroundColor(.white).lineLimit(2).minimumScaleFactor(0.6)
                Capsule().fill(Brand.volt).frame(width: 46, height: 4)
                let bits: [String] = [
                    enabled.contains(.date) ? dateLabel(stats.date) : nil,
                    enabled.contains(.totalWeight) ? "\(liftedValue) \(StatsUnits.weightLabel)" : nil,
                    enabled.contains(.duration) ? stats.duration : nil,
                    enabled.contains(.setCount) ? "\(stats.setCount) sets" : nil,
                ].compactMap { $0 }
                if !bits.isEmpty {
                    Text(bits.joined(separator: "  ·  ")).font(BrandFont.body(11, .heavy)).foregroundColor(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
    }

    /// PR and award badges, when switched on.
    @ViewBuilder private var badges: some View {
        VStack(spacing: 8) {
            if enabled.contains(.award), let aw = store.awardToShare, aw.isShareable {
                VStack(spacing: 2) {
                    pill(aw.title.uppercased(), icon: aw.icon)
                    if let s0 = aw.shareStats.first {
                        Text(s0.value).font(BrandFont.display(22)).foregroundColor(.white).shadow(color: .black.opacity(0.7), radius: 4)
                        Text(s0.label).font(BrandFont.body(7, .bold)).tracking(1.2).foregroundColor(Brand.volt)
                    }
                }
            }
            if enabled.contains(.personalRecord), let pr = store.lastPRForShare, style != .pr {
                VStack(spacing: 2) {
                    pill(pr.isFirstEver ? "FIRST RECORD" : "NEW PR", icon: "trophy.fill")
                    Text("\(pr.reps)×\(StatsUnits.weightText(pr.weight, unit: false))").font(BrandFont.display(22)).foregroundColor(.white)
                        .shadow(color: .black.opacity(0.7), radius: 4)
                    Text(pr.exercise.uppercased()).font(BrandFont.body(7, .bold)).tracking(1.2).foregroundColor(Brand.volt)
                }
            }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(BrandFont.body(11, .bold)).foregroundColor(Brand.onVolt)
            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Brand.volt))
    }

    private func pill(_ t: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(t).font(BrandFont.body(8, .heavy)).tracking(1.2)
        }
        .foregroundColor(Brand.onVolt)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Brand.volt))
    }

    private func bigStat(_ v: String, _ l: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            Text(v).font(BrandFont.display(34)).foregroundColor(Brand.volt)
            Text(l).font(BrandFont.body(9, .bold)).tracking(1.5).foregroundColor(.white)
        }
        .shadow(color: .black, radius: 4)
    }

    private func smallStat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(BrandFont.display(22)).foregroundColor(.white)
            Text(l).font(BrandFont.body(7.5, .heavy)).tracking(1).foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: Stickers on the card

    private func stickerLayer(editable: Bool) -> some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { selected = nil }
                .allowsHitTesting(editable)
            ForEach(stickers) { st in
                StickerView(sticker: st, store: store, selected: editable && selected == st.id)
                    .scaleEffect(st.scale)
                    .rotationEffect(.degrees(st.tilt))
                    .position(st.position)
                    .gesture(stickerGesture(st), including: editable ? .all : .none)
                    .onTapGesture(count: 2) {
                        guard editable else { return }
                        withAnimation(.spring(response: 0.3)) { stickers.removeAll { $0.id == st.id } }
                    }
                    .onTapGesture { if editable { selected = st.id } }
                    .allowsHitTesting(editable)
            }
        }
    }

    /// Drag to place (in the card's own coordinates, so it tracks your finger at any preview size)
    /// and pinch to resize, together.
    private func stickerGesture(_ st: PlacedSticker) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .named("shareCard"))
            .onChanged { v in
                guard let i = stickers.firstIndex(where: { $0.id == st.id }) else { return }
                selected = st.id
                stickers[i].position = CGPoint(x: min(max(v.location.x, 0), format.layoutWidth),
                                               y: min(max(v.location.y, 0), format.layoutHeight))
            }
        let pinch = MagnificationGesture()
            .onChanged { m in
                guard let i = stickers.firstIndex(where: { $0.id == st.id }) else { return }
                stickers[i].scale = min(max(st.scale * m, 0.5), 2.6)
            }
        return drag.simultaneously(with: pinch)
    }

    // MARK: Sharing

    // Renders the finished card once, then routes it. Instagram/Facebook deep-link into
    // their Story composer (after a tag reminder); everything else opens the share sheet.
    @MainActor func routeShare(_ target: SocialTarget) {
        selected = nil
        let renderer = ImageRenderer(content: card(editable: false) { photoLayer }
            .frame(width: format.layoutWidth, height: format.layoutHeight)
            .background(Color.black))
        renderer.scale = format.exportScale
        renderer.isOpaque = true
        guard let img = renderer.uiImage else { return }
        renderedCard = img
        switch target {
        case .instagram, .facebook:
            if SocialShare.isAvailable(target) {
                pendingImage = img
                pendingTarget = target
                showTagReminder = true
            } else {
                showShareSheet = true                 // not installed: the share sheet instead
            }
        case .systemSheet:
            showShareSheet = true
        }
    }

    @MainActor private func launchPendingStory() {
        guard let img = pendingImage else { return }
        if SocialShare.shareToStory(img, target: pendingTarget) {
            ShareLog.shared.record(workoutDate: stats.date, platform: pendingTarget == .facebook ? "Facebook" : "Instagram")
        } else {
            showShareSheet = true
        }
        pendingImage = nil
    }
}

// MARK: - A sticker

private struct StickerView: View {
    let sticker: PlacedSticker
    let store: AppStore
    let selected: Bool

    private var stats: ShareStats { store.shareStats }

    var body: some View {
        content
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundColor(.white.opacity(0.9)).padding(-6)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch sticker.kind {
        case .pr:
            if let pr = store.lastPRForShare {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pr.isFirstEver ? "FIRST RECORD" : "NEW PR").font(BrandFont.body(9, .heavy)).tracking(1.4).opacity(0.75)
                    Text("\(pr.exercise.uppercased()) \(StatsUnits.weightText(pr.weight, unit: false))")
                        .font(BrandFont.display(30)).lineLimit(1)
                    Text("× \(pr.reps)").font(BrandFont.body(11, .heavy))
                }
                .foregroundColor(Brand.onVolt)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            }
        case .workout:
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(BrandFont.display(24)).foregroundColor(.white).lineLimit(1)
                Text(stats.date.formatted(.dateTime.month(.abbreviated).day())).font(BrandFont.body(9, .heavy)).tracking(1.2).foregroundColor(Brand.volt)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
        case .stats:
            HStack(spacing: 16) {
                stat(StatsUnits.weightText(stats.totalWeight, unit: false), StatsUnits.weightLabel.uppercased())
                stat(stats.duration, "TIME")
                stat("\(stats.setCount)", "SETS")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
        case .streak:
            Label("\(max(store.weekStreak, 1))-WEEK STREAK", systemImage: "flame.fill")
                .font(BrandFont.body(13, .heavy)).foregroundColor(.white)
                .padding(.horizontal, 14).frame(height: 38)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .overlay(Capsule().stroke(Brand.volt, lineWidth: 2))
        case .topLift:
            Text(stats.topLift).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.onVolt)
                .padding(.horizontal, 14).frame(height: 36).background(Capsule().fill(Brand.volt))
        case .date:
            Text(stats.date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())
                .font(BrandFont.body(12, .heavy)).tracking(1.2).foregroundColor(.white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(Color.black.opacity(0.6)))
        case .logo:
            Image("logoVolt").renderingMode(.template).resizable().scaledToFit()
                .foregroundColor(Brand.volt).frame(width: 130)
                .shadow(color: .black.opacity(0.5), radius: 4)
        case .award:
            if let aw = store.awardToShare, aw.isShareable {
                HStack(spacing: 8) {
                    Image(systemName: aw.icon).font(.system(size: 18, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(aw.title.uppercased()).font(BrandFont.body(10, .heavy)).tracking(1.2)
                        if let s0 = aw.shareStats.first { Text("\(s0.value) \(s0.label)").font(BrandFont.body(12, .heavy)) }
                    }
                }
                .foregroundColor(Brand.onVolt)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt))
            }
        }
    }

    private var title: String {
        store.workouts.first { Calendar.current.isDate($0.date, inSameDayAs: stats.date) }?.title ?? "Today's session"
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(BrandFont.display(24)).foregroundColor(.white).lineLimit(1)
            Text(l).font(BrandFont.body(8, .heavy)).tracking(1).foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Toggle chips that wrap onto new lines

private struct FlowChips: View {
    let items: [String]
    let on: Set<String>
    let toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { it in
                let isOn = on.contains(it)
                Button { toggle(it) } label: {
                    HStack(spacing: 5) {
                        if isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
                        Text(it).font(BrandFont.body(13, .bold))
                    }
                    .foregroundColor(isOn ? Brand.onVolt : Brand.text)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Capsule().fill(isOn ? Brand.volt : Brand.card))
                    .overlay(Capsule().stroke(isOn ? Color.clear : Brand.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
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
                Capsule().fill(BrandDark.mute).frame(width: 40, height: 4).frame(maxWidth: .infinity)
                Text("Share Your Win").font(BrandFont.display(28)).foregroundColor(.white)

                // Social grid
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(socials, id: \.0) { s in
                        Button { onShare(s.2) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: s.1).font(.system(size: 30)).foregroundColor(BrandDark.volt)
                                Text(s.0).font(BrandFont.body(11, .semibold)).foregroundColor(.white)
                                // Show which ones jump straight into the app.
                                if s.2.canDeepLink {
                                    Text("DIRECT").font(BrandFont.body(7, .bold)).tracking(0.8)
                                        .foregroundColor(BrandDark.volt.opacity(0.8))
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16).card(padding: 0)
                        }
                    }
                }

                // Apple system share sheet
                Button { onShare(.systemSheet) } label: {
                    HStack { Image(systemName: "square.and.arrow.up"); Text("More — Messages, Mail, AirDrop…") }
                        .font(BrandFont.body(14, .bold)).foregroundColor(BrandDark.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 16).background(BrandDark.volt)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Button { withAnimation { show = false } } label: {
                    Text("Cancel").font(BrandFont.body(14, .semibold)).foregroundColor(BrandDark.mute)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .padding(24).padding(.bottom, 12)
            .background(BrandDark.bg)
            .overlay(Rectangle().fill(BrandDark.volt).frame(height: 3), alignment: .top)
            .transition(.move(edge: .bottom))
        }
    }
}

// MARK: - System share sheet wrapper
// Presents UIActivityViewController so the rendered card can go to Instagram,
// Messages, Mail, AirDrop, Photos, or anywhere the user has installed.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// Called with the destination's activity type when a share completes.
    var onComplete: ((String?) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let done = onComplete
        vc.completionWithItemsHandler = { type, completed, _, _ in
            guard completed else { return }
            let raw = type?.rawValue
            DispatchQueue.main.async { done?(raw) }
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
