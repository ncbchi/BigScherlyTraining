import SwiftUI
import PhotosUI

// MARK: - Share formats
// Rendered at Instagram's native pixel sizes so the export stays sharp.
enum ShareFormat: String, CaseIterable, Identifiable {
    case story  = "Story"
    case post   = "Post 4:5"
    case square = "Square 1:1"
    var id: String { rawValue }
    var short: String { rawValue.components(separatedBy: " ").first ?? rawValue }

    /// Canonical layout size the card is always composed at (fonts and padding are designed
    /// against it), so the preview and the export look identical.
    var layoutWidth: CGFloat { 360 }
    var layoutHeight: CGFloat {
        switch self {
        case .story: return Self.storyHeight
        case .post: return 450
        case .square: return 360
        }
    }

    /// The story card is the phone's own shape (full screen), 1080 wide with an even pixel height.
    static let storyHeight: CGFloat = {
        let b = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds
            ?? CGRect(x: 0, y: 0, width: 393, height: 852)
        let w = min(b.width, b.height), h = max(b.width, b.height)
        let px = (1080 * h / w / 2).rounded() * 2
        return max(640, px / 3)
    }()

    /// Export size in pixels (even, for video).
    var exportPixels: CGSize {
        CGSize(width: 1080, height: ((layoutHeight * exportScale) / 2).rounded() * 2)
    }
    /// 1080 wide: 1080×1920 story, 1080×1350 post, 1080×1080 square.
    var exportScale: CGFloat { 3.0 }
}

/// Crew totals for the coach's share card (Coach ▸ Share). Totals only — never a
/// client's name or numbers. With one of these, ShareView is the crew card.
struct CrewShare {
    var workouts: Int         // logged this week, whole roster
    var athletes: Int         // on the roster
    var trainedThisWeek: Int  // athletes with at least one session this week
    var awards: Int           // earned this week
    var weekStart: Date
}

// MARK: - Share tab: an Instagram-style story editor (rebuilt Oct 9, 2026)
// One full card: your photo underneath, the Big Scherly logo pinned bottom-left (it can't
// be moved or removed), and anything you add on top: our lifting stickers, stickers filled
// in from your real numbers, GIPHY GIFs and stickers, and text. Tools along the top right,
// where it goes along the bottom. Drag to move, pinch to size, twist to turn, drop on the
// bin to remove. Tap a stat sticker to change its style; tap text to edit it; tap empty
// space to add text. Replaces the old Studio and Stickers modes.

private enum ShareRoute: Identifiable {
    case stickers, stats, gifs, send
    case activity([Any])
    var id: String {
        switch self {
        case .stickers: return "stickers"
        case .stats: return "stats"
        case .gifs: return "gifs"
        case .send: return "send"
        case .activity: return "activity"
        }
    }
}

private struct ShareTextEdit {
    var id: UUID?          // nil = new text
    var text: ShareText
}

struct ShareView: View {
    @EnvironmentObject var store: AppStore
    var crew: CrewShare? = nil
    init(crew: CrewShare? = nil) { self.crew = crew }

    @State private var format: ShareFormat = .story
    @State private var items: [ShareItem] = []
    @State private var route: ShareRoute?
    @State private var textEdit: ShareTextEdit?

    // Moving things
    @State private var activeId: UUID?
    @State private var dragging = false
    @State private var dragBase: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var turnBase: Double?
    @State private var overBin = false
    @State private var snapped = false
    @State private var cardScale: CGFloat = 1
    @State private var binY: CGFloat = 0          // the bin, in card points
    /// Stat stickers' numbers, worked out once (not on every drag frame).
    @State private var models: [ShareDataKind: ShareDataModel] = [:]

    // The photo
    @State private var pickedItem: PhotosPickerItem?
    @State private var chosenImage: UIImage?
    @State private var showLibrary = false
    @State private var showCameraDenied = false
    @State private var camera = CameraSession()
    @State private var cameraLive = false        // the viewfinder is the card's photo
    @State private var shooting = false
    @State private var flash = false

    // Sending
    @State private var working: String?
    @State private var toast: String?
    @State private var showTagReminder = false
    @State private var pendingTarget: SocialTarget = .instagram
    @State private var pendingImage: UIImage?
    @State private var pendingVideo: URL?

    private static let space = "shareCard"
    private static let barHeight: CGFloat = 56

    private static var windowInsets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
    }

    private var data: ShareDataSource { ShareDataSource(store: store, crew: crew) }
    private var hasMotion: Bool { items.contains { $0.moves } }
    private var coachThread: ChatThread? {
        guard crew == nil else { return nil }
        return store.chats.max(by: { $0.lastActivity < $1.lastActivity })
    }

    var body: some View {
        GeometryReader { geo in
            // Full screen: the card covers the whole display, status bar to home indicator.
            // The real status-bar / home-indicator room comes from the window: this screen sits
            // in a full-screen container, so the geometry here can report zero.
            let win = Self.windowInsets
            let top = max(geo.safeAreaInsets.top, win.top), bottom = max(geo.safeAreaInsets.bottom, win.bottom)
            let fullW = geo.size.width, fullH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let full = format == .story
            let s = full ? max(fullW / format.layoutWidth, fullH / format.layoutHeight)
                         : min(fullW / format.layoutWidth, (fullH - top - bottom - Self.barHeight - 40) / format.layoutHeight)
            let cw = format.layoutWidth * s, ch = format.layoutHeight * s
            let cardTop = full ? (fullH - ch) / 2 : top + 8
            let barMid = fullH - bottom - 14 - Self.barHeight / 2

            ZStack(alignment: .top) {
                Color.black

                editorCard(s: s)
                    .frame(width: cw, height: ch)
                    .position(x: fullW / 2, y: cardTop + ch / 2)

                // Shutter / share controls, floating over the bottom of the photo.
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.barHeight + bottom + 60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                bottomBar(s: s)
                    .frame(height: Self.barHeight)
                    .position(x: fullW / 2, y: barMid)

                if activeId == nil && textEdit == nil {
                    toolColumn
                        .padding(.top, top + 8)
                        .transition(.opacity)
                    // Upper left: X clears the photo and goes back to the camera.
                    if chosenImage != nil {
                        Button { clearPhoto() } label: {
                            toolIcon { Image(systemName: "xmark").font(.system(size: 17, weight: .bold)) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear the photo")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.top, top + 8)
                        .transition(.opacity)
                    }
                }

                if let t = toast {
                    Text(t).font(.system(size: 14, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(Capsule().fill(Color.white))
                        .padding(.top, top + 56)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                Color.clear.frame(width: 0, height: 0)
                    .onAppear { cardScale = s; binY = (barMid - cardTop) / s }
                    .onChange(of: s) { _, v in cardScale = v; binY = (barMid - cardTop) / v }
                    .onChange(of: barMid - cardTop) { _, d in binY = d / s }
            }
            .frame(width: fullW, height: fullH)
            .animation(.easeInOut(duration: 0.18), value: activeId == nil)
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .overlay {
            ZStack {
                if textEdit != nil {
                    ShareTextEditor(draft: Binding(get: { textEdit?.text ?? ShareText() },
                                                   set: { textEdit?.text = $0 }),
                                    scale: cardScale) { commitText() }
                        .transition(.opacity)
                }
                if let w = working {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView().tint(Color.white).scaleEffect(1.3)
                            Text(w).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            refreshModels()
            Task { await SharePackImages.prewarm() }
            // Share opens on the live camera, with every tool already over it.
            if chosenImage == nil && !cameraLive { openCamera() }
        }
        .onDisappear { stopCamera() }
        .sheet(item: $route) { r in sheet(r) }
        .photosPicker(isPresented: $showLibrary, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: d) {
                    chosenImage = ui
                    stopCamera()
                }
                pickedItem = nil
            }
        }
        .onChange(of: format) { _, _ in keepItemsInside() }
        .alert("Tag your coach!", isPresented: $showTagReminder) {
            Button("Got it — open \(pendingTarget == .facebook ? "Facebook" : "Instagram")") { launchPendingStory() }
            Button("Cancel", role: .cancel) { pendingImage = nil; pendingVideo = nil }
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
    }

    // MARK: Sheets

    @ViewBuilder private func sheet(_ r: ShareRoute) -> some View {
        switch r {
        case .stickers:
            ShareStickerTray(data: data, onAdd: add) {
                route = .gifs
            }
        case .stats:
            ShareStatsTray(data: data, onAdd: add)
        case .gifs:
            ShareGifTray(onAdd: add)
        case .send:
            ShareSendSheet(format: $format, hasMotion: hasMotion, canSendCoach: coachThread != nil) { choice in
                route = nil
                Task { await perform(choice) }
            }
        case .activity(let payload):
            ActivityView(items: payload) { activity in
                // Only social destinations mark the share calendar.
                if crew == nil, let platform = ShareLog.platformName(forActivity: activity) {
                    ShareLog.shared.record(workoutDate: store.shareStats.date, platform: platform)
                }
            }
        }
    }

    // MARK: Top and bottom

    /// Every tool, in one column down the right side, under the ☰ menu button.
    private var toolColumn: some View {
        VStack(spacing: 10) {
            Button { textEdit = ShareTextEdit(id: nil, text: ShareText()) } label: {
                toolIcon { Text("Aa").font(.system(size: 17, weight: .semibold)).tracking(-0.4) }
            }
            .accessibilityLabel("Add text")
            Button { route = .stickers } label: {
                toolIcon { Image(systemName: "face.smiling").font(.system(size: 19, weight: .semibold)) }
            }
            .accessibilityLabel("Stickers and GIFs")
            Button { route = .stats } label: {
                toolIcon { Image(systemName: "chart.xyaxis.line").font(.system(size: 17, weight: .semibold)) }
            }
            .accessibilityLabel("Stats and trends")
            Button { showLibrary = true } label: {
                toolIcon { Image(systemName: "photo.on.rectangle").font(.system(size: 16, weight: .semibold)) }
            }
            .accessibilityLabel("Choose a photo")
            Menu {
                Picker("Size", selection: $format) {
                    ForEach(ShareFormat.allCases) { f in Text(f.rawValue).tag(f) }
                }
                if !items.isEmpty {
                    Button(role: .destructive) { withAnimation { items.removeAll() } } label: {
                        Label("Remove everything", systemImage: "trash")
                    }
                }
            } label: {
                toolIcon { Image(systemName: "aspectratio").font(.system(size: 17, weight: .semibold)) }
            }
            .accessibilityLabel("Card size")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }

    private func toolIcon<L: View>(@ViewBuilder _ label: () -> L) -> some View {
        label()
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.black.opacity(0.25)))
            .contentShape(Circle())
    }

    @ViewBuilder private func bottomBar(s: CGFloat) -> some View {
        if activeId != nil && dragging {
            // While moving something: the bin, under the card.
            Image(systemName: "trash")
                .font(.system(size: overBin ? 24 : 20, weight: .semibold)).foregroundColor(.white)
                .frame(width: overBin ? 64 : 52, height: overBin ? 64 : 52)
                .background(Circle().fill(overBin ? Color.red.opacity(0.85) : Color.white.opacity(0.08)))
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: overBin ? 0 : 2))
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: overBin)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Drop here to remove")
        } else if cameraLive {
            HStack {
                Button { showLibrary = true } label: {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.14)))
                }
                .accessibilityLabel("Choose from library")
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 70, height: 70)
                        Circle().fill(shooting ? Color.white.opacity(0.5) : Color.white).frame(width: 58, height: 58)
                    }
                }
                .disabled(shooting)
                .accessibilityLabel("Take photo")
                Spacer()
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(Color.white.opacity(0.14)))
                }
                .accessibilityLabel("Flip camera")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        } else {
            HStack(spacing: 8) {
                pill(icon: "square.and.arrow.down", "Save") {
                    Task { await perform(ShareSendChoice(external: nil, save: true, coach: false, video: hasMotion)) }
                }
                if coachThread != nil {
                    pill(icon: "bubble.left.fill", "My coach") {
                        Task { await perform(ShareSendChoice(external: nil, save: false, coach: true, video: hasMotion)) }
                    }
                }
                Spacer()
                Button { route = .send } label: {
                    Image(systemName: "arrow.right").font(.system(size: 19, weight: .bold)).foregroundColor(.black)
                        .frame(width: 44, height: 44).background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
            .padding(.horizontal, 14)
        }
    }

    private func pill(icon: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.14)))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.leading, 6).padding(.trailing, 14).frame(height: 40)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: The card

    /// The card in the editor: composed at its layout size, scaled to the screen.
    private func editorCard(s: CGFloat) -> some View {
        let cw = format.layoutWidth * s, ch = format.layoutHeight * s
        return ZStack(alignment: .topLeading) {
            if cameraLive {
                CameraPreview(session: camera.session)
                    .frame(width: cw, height: ch)
            }
            card(editing: true, photo: !cameraLive, s: s)
                .frame(width: format.layoutWidth, height: format.layoutHeight)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: cw, height: ch, alignment: .topLeading)
            if flash {
                Color.white.frame(width: cw, height: ch).allowsHitTesting(false)
            }
        }
        .frame(width: cw, height: ch)
        .clipShape(RoundedRectangle(cornerRadius: format == .story ? 0 : 18, style: .continuous))
    }

    /// Photo, everything added, and the logo. `editing` adds the gestures, the guide and the
    /// top shade for the tools; the export leaves them out.
    private func card(editing: Bool, photo: Bool, s: CGFloat = 1) -> some View {
        let w = format.layoutWidth, h = format.layoutHeight
        return ZStack {
            if photo {
                photoLayer.frame(width: w, height: h).clipped()
            } else {
                Color.clear
            }
            if editing {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110).frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { textEdit = ShareTextEdit(id: nil, text: ShareText()) }
                if chosenImage == nil && !cameraLive && photo { emptyPrompt }
            }
            ForEach(items) { item in
                ShareItemView(kind: item.kind, model: model(for: item.kind))
                    .equatable()
                    .scaleEffect(item.scale)
                    .rotationEffect(.degrees(item.rotation))
                    .opacity(editing && overBin && activeId == item.id ? 0.45 : 1)
                    .position(item.position)
                    .zIndex(activeId == item.id ? 1 : 0)
                    .gesture(itemGesture(item.id, s: s), including: editing ? .all : .none)
                    .onTapGesture { if editing { tap(item.id) } }
                    .allowsHitTesting(editing)
            }
            if editing && snapped {
                Rectangle().fill(Brand.volt).frame(width: 1.5).frame(maxHeight: .infinity)
                    .shadow(color: Brand.volt.opacity(0.6), radius: 3)
                    .allowsHitTesting(false)
            }
            logo(lift: logoLift)
        }
        .frame(width: w, height: h)
        .coordinateSpace(.named(Self.space))
        .clipped()
    }

    private func model(for kind: ShareItemKind) -> ShareDataModel? {
        guard case .data(let k, _) = kind else { return nil }
        return models[k] ?? data.model(k)
    }

    private func refreshModels() {
        var m: [ShareDataKind: ShareDataModel] = [:]
        for k in ShareDataKind.allCases { if let v = data.model(k) { m[k] = v } }
        models = m
    }

    @ViewBuilder private var photoLayer: some View {
        if let img = chosenImage {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color(white: 0.07)
        }
    }

    /// No photo yet: two ways to get one, in the middle of the card (editor only).
    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            if CameraPicker.isAvailable {
                Button { openCamera() } label: {
                    Label("Take a photo", systemImage: "camera.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 20).frame(height: 46)
                        .background(Capsule().fill(Color.white))
                }
            }
            Button { showLibrary = true } label: {
                Label("Choose from library", systemImage: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 20).frame(height: 46)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .buttonStyle(.plain)
    }

    /// Bottom of the logo above the card's bottom edge, in card points: clear of the
    /// Save / send bar floating over a full-screen card.
    private var logoLift: CGFloat {
        guard binY > 0, cardScale > 0 else { return 16 }
        let barTop = binY - Self.barHeight / 2 / cardScale
        return max(16, format.layoutHeight - barTop + 10)
    }

    /// Pinned bottom-left on every card. Not an item: it can't be moved or removed.
    private func logo(lift: CGFloat) -> some View {
        Image("logoVolt").renderingMode(.template).resizable().scaledToFit()
            .foregroundColor(Brand.volt)
            .frame(width: 150)
            .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
            .padding(.leading, 16).padding(.bottom, lift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
    }

    // MARK: Adding and editing

    private func add(_ kind: ShareItemKind) {
        if case .data = kind { refreshModels() }
        let w = format.layoutWidth, h = format.layoutHeight
        let n = CGFloat(items.count % 4)
        let tilts: [Double] = [-4, 3, -2, 5]
        let item = ShareItem(kind: kind,
                             position: CGPoint(x: w / 2 + (n - 1.5) * 14, y: h * 0.42 + n * 18),
                             rotation: tilts[items.count % tilts.count])
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { items.append(item) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func tap(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].kind {
        case .data(let k, let style):
            withAnimation(.easeInOut(duration: 0.15)) { items[i].kind = .data(k, style.next) }
            UISelectionFeedbackGenerator().selectionChanged()
        case .text(let t):
            textEdit = ShareTextEdit(id: id, text: t)
        default:
            let it = items.remove(at: i)
            items.append(it)               // to the front
        }
    }

    private func commitText() {
        guard let edit = textEdit else { return }
        let trimmed = edit.text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = edit.id, let i = items.firstIndex(where: { $0.id == id }) {
            if trimmed.isEmpty { items.remove(at: i) } else { items[i].kind = .text(edit.text) }
        } else if !trimmed.isEmpty {
            items.append(ShareItem(kind: .text(edit.text),
                                   position: CGPoint(x: format.layoutWidth / 2, y: format.layoutHeight * 0.4)))
        }
        textEdit = nil
    }

    /// After a size change, pull anything outside the card back in.
    private func keepItemsInside() {
        for i in items.indices {
            items[i].position.x = min(max(items[i].position.x, 30), format.layoutWidth - 30)
            items[i].position.y = min(max(items[i].position.y, 30), format.layoutHeight - 30)
        }
    }

    // MARK: Moving: drag, pinch and twist together

    private func itemGesture(_ id: UUID, s: CGFloat) -> some Gesture {
        let drag = DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                begin(id)
                guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                if dragBase == nil { dragBase = items[i].position }
                dragging = true
                let mid = format.layoutWidth / 2
                var p = CGPoint(x: (dragBase?.x ?? 0) + v.translation.width, y: (dragBase?.y ?? 0) + v.translation.height)
                let snap = abs(p.x - mid) < 7
                if snap { p.x = mid }
                if snap != snapped {
                    snapped = snap
                    if snap { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
                items[i].position = p
                // The bin sits centred under the card, in the bar below it.
                let bin = CGPoint(x: mid, y: binY)
                let near = hypot(v.location.x - bin.x, v.location.y - bin.y) < 56 / s
                if near != overBin {
                    overBin = near
                    if near { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                }
            }
            .onEnded { _ in finish() }
        let pinch = MagnifyGesture()
            .onChanged { v in
                begin(id)
                guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                if pinchBase == nil { pinchBase = items[i].scale }
                items[i].scale = min(max((pinchBase ?? 1) * v.magnification, 0.3), 4)
            }
            .onEnded { _ in
                pinchBase = nil
                if !dragging { finish() }
            }
        let turn = RotateGesture()
            .onChanged { v in
                begin(id)
                guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                if turnBase == nil { turnBase = items[i].rotation }
                items[i].rotation = (turnBase ?? 0) + v.rotation.degrees
            }
            .onEnded { _ in
                turnBase = nil
                if !dragging { finish() }
            }
        return drag.simultaneously(with: pinch).simultaneously(with: turn)
    }

    private func begin(_ id: UUID) {
        guard activeId != id else { return }
        activeId = id
    }

    private func finish() {
        if overBin, let id = activeId {
            withAnimation(.easeIn(duration: 0.15)) { items.removeAll { $0.id == id } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if let id = activeId, let i = items.firstIndex(where: { $0.id == id }), i != items.count - 1 {
            let it = items.remove(at: i)
            items.append(it)               // what you moved stays in front
        }
        activeId = nil
        dragging = false
        dragBase = nil
        pinchBase = nil
        turnBase = nil
        overBin = false
        snapped = false
    }

    // MARK: Photo

    private func openCamera() {
        guard CameraPicker.isAvailable else { return }      // no camera (simulator): the card offers the library
        Task {
            let ok = await CameraAccess.request()
            if ok {
                withAnimation(.easeInOut(duration: 0.2)) { chosenImage = nil; cameraLive = true }
                camera.start()
            } else {
                showCameraDenied = true
            }
        }
    }

    /// The X: drop the photo and go back to the live camera (stickers stay).
    private func clearPhoto() {
        withAnimation(.easeInOut(duration: 0.2)) { chosenImage = nil }
        if CameraPicker.isAvailable { openCamera() }
    }

    private func stopCamera() {
        camera.stop()
        cameraLive = false
    }

    private func shoot() {
        shooting = true
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.2)) { flash = false }
        }
        camera.capture { image in
            shooting = false
            if let image {
                chosenImage = image
                stopCamera()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: Sending

    private func exportCard(time: Double) -> some View {
        card(editing: false, photo: true)
            .environment(\.shareStickerTime, time)
            .background(Color.black)
    }

    private func renderFrame(_ time: Double) -> CGImage? {
        let r = ImageRenderer(content: exportCard(time: time))
        r.scale = format.exportScale
        r.isOpaque = true
        return r.cgImage
    }

    /// GIFs are decoded before rendering, so no frame comes out as a placeholder.
    private func preloadGifs() async {
        for item in items {
            if case .gif(let g) = item.kind {
                _ = await GifStore.shared.load(g.full, maxPixel: ShareGifImage.cardPixel, maxFrames: ShareGifImage.cardFrames)
            }
        }
    }

    private func makeVideo(still: CGImage?) async throws -> URL {
        let size = format.exportPixels
        if let still {
            return try await ShareVideo.write(size: size, fps: 8) { _ in still }
        }
        return try await ShareVideo.write(size: size) { t in renderFrame(t) }
    }

    private func perform(_ c: ShareSendChoice) async {
        try? await Task.sleep(nanoseconds: 350_000_000)     // let a closing tray finish
        withAnimation { working = c.video ? "Making your video…" : "Getting your card ready…" }
        await preloadGifs()
        guard let still = renderFrame(0) else {
            withAnimation { working = nil }
            showToast("Couldn't make the card. Try again.")
            return
        }
        let image = UIImage(cgImage: still)
        var video: URL? = nil
        if c.video {
            video = try? await makeVideo(still: nil)
        } else if c.coach {
            video = try? await makeVideo(still: still)     // coach chat takes video
        }

        var notes: [String] = []
        if c.save {
            let ok = await SharePhotos.save(image: c.video ? nil : image, video: c.video ? video : nil)
            notes.append(ok ? "Saved to Photos" : "Couldn't save. Allow Photos access in Settings.")
        }
        if c.coach {
            notes.append(await sendToCoach(video))
        }
        withAnimation { working = nil }
        if !notes.isEmpty { showToast(notes.joined(separator: " · ")) }

        guard let target = c.external else { return }
        let payload: Any = (c.video ? video : nil).map { $0 as Any } ?? image
        switch target {
        case .instagram, .facebook:
            if SocialShare.isAvailable(target) {
                pendingTarget = target
                pendingImage = image
                pendingVideo = c.video ? video : nil
                showTagReminder = true
            } else {
                route = .activity([payload])
            }
        case .systemSheet:
            route = .activity([payload])
        }
    }

    private func sendToCoach(_ video: URL?) async -> String {
        guard let thread = coachThread, let video else { return "Couldn't send it to your coach." }
        guard store.isLive else { return "Sending to your coach works once you're signed in." }
        do {
            let out = try await VideoCompressor.compress(video)
            _ = try await APIClient.shared.uploadChatVideo(threadId: thread.id, fileURL: out.url)
            return "Sent to your coach"
        } catch {
            return "Couldn't send it to your coach. Try again."
        }
    }

    private func launchPendingStory() {
        let ok: Bool
        if let v = pendingVideo, let d = try? Data(contentsOf: v) {
            ok = SocialShare.shareVideoToStory(d, target: pendingTarget)
        } else if let img = pendingImage {
            ok = SocialShare.shareToStory(img, target: pendingTarget)
        } else {
            ok = false
        }
        if ok {
            if crew == nil {   // the share calendar is the lifter's own
                ShareLog.shared.record(workoutDate: store.shareStats.date,
                                       platform: pendingTarget == .facebook ? "Facebook" : "Instagram")
            }
        } else if let v = pendingVideo {
            route = .activity([v])
        } else if let img = pendingImage {
            route = .activity([img])
        }
        pendingImage = nil
        pendingVideo = nil
    }

    private func showToast(_ t: String) {
        withAnimation { toast = t }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { if toast == t { toast = nil } }
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
