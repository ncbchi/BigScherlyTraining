import SwiftUI
import PhotosUI

// Trainer-side share: a business/roster stats card ("state of the business")
// pulled from live roster insights — NOT personal lifting stats, and never mock
// data. Reuses the same share machinery as the client ShareView (ShareFormat,
// SocialShare, ShareDrawer, ActivityView).
struct TrainerShareView: View {
    @EnvironmentObject var store: AppStore

    // Which business stats to show on the card.
    enum BizField: String, CaseIterable, Identifiable {
        case clients, workouts, attention, awards, drifting, avgTrained
        var id: String { rawValue }
        var label: String {
            switch self {
            case .clients:    return "Active Clients"
            case .workouts:   return "Workouts / Week"
            case .attention:  return "Need Attention"
            case .awards:     return "Awards / Week"
            case .drifting:   return "Drifting"
            case .avgTrained: return "Avg Days Trained"
            }
        }
    }

    @State private var enabled: Set<BizField> = [.clients, .workouts, .awards]
    @State private var format: ShareFormat = .story
    @State private var showDrawer = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var chosenImage: UIImage?
    @State private var showShareSheet = false
    @State private var renderedCard: UIImage?
    @State private var pendingImage: UIImage?
    @State private var pendingTarget: SocialTarget = .instagram
    @State private var showTagReminder = false

    private var i: RosterInsights { store.insights }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(text: "Show It Off")
                    Text("Share").font(BrandFont.display(48)).foregroundColor(.white)
                    Text("Share how your crew is showing up. Pick what to feature, then post it.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    // Format
                    Text("FORMAT").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    HStack(spacing: 10) {
                        ForEach(ShareFormat.allCases) { f in
                            Button { format = f } label: {
                                Text(f.rawValue)
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundColor(format == f ? Brand.black : .white)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(format == f ? Brand.volt : Brand.black)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Brand.line, lineWidth: format == f ? 0 : 1))
                            }
                        }
                    }

                    // Live preview of the card
                    shareCard
                        .frame(width: 260, height: format == .post ? 325 : 462)
                        .frame(maxWidth: .infinity)

                    // Stat toggles
                    Text("SHOW ON CARD").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                    let cols = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(BizField.allCases) { f in
                            Button {
                                if enabled.contains(f) { enabled.remove(f) } else { enabled.insert(f) }
                            } label: {
                                HStack {
                                    Image(systemName: enabled.contains(f) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(enabled.contains(f) ? Brand.volt : Brand.mute)
                                    Text(f.label).font(BrandFont.body(13, .semibold)).foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(12).background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                            }
                        }
                    }

                    // Optional background photo
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.on.rectangle").foregroundColor(Brand.volt)
                            Text(chosenImage == nil ? "Add a background photo" : "Change background photo")
                                .font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(14).background(Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                    }
                }
                .padding(.top, 70).padding(.horizontal, 20).padding(.bottom, 120)
            }
            .background(Brand.bg.ignoresSafeArea())
            .refreshable { store.loadRoster() }

            // Share button
            Button { withAnimation { showDrawer = true } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .bold))
                    Text("Share").font(BrandFont.body(16, .bold))
                }
                .foregroundColor(Brand.black)
                .padding(.horizontal, 28).padding(.vertical, 16)
                .background(Brand.volt).clipShape(Capsule())
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            }
            .padding(20)
        }
        .overlay {
            if showDrawer { ShareDrawer(show: $showDrawer, onShare: routeShare) }
        }
        .sheet(isPresented: $showShareSheet) {
            if let img = renderedCard { ActivityView(items: [img]) }
        }
        .alert("Tag Big Scherly!", isPresented: $showTagReminder) {
            Button("Got it — open \(pendingTarget == .facebook ? "Facebook" : "Instagram")") {
                launchPendingStory()
            }
            Button("Cancel", role: .cancel) { pendingImage = nil }
        } message: {
            Text("Before you post, tag @big.scherly so your crew's wins get reshared. 👑")
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

    // The rendered card — business stats over an optional photo.
    var shareCard: some View {
        ZStack {
            Rectangle().fill(Brand.black)
                .overlay(
                    Group {
                        if let img = chosenImage {
                            Image(uiImage: img).resizable().scaledToFill()
                        }
                    }
                )
                .clipped()

            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STATE OF THE CREW")
                            .font(BrandFont.body(8, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        Text("This Week")
                            .font(BrandFont.display(22)).foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                    }
                    Spacer()
                    Image("logoVolt").resizable().scaledToFit()
                        .frame(width: 110).shadow(color: .black.opacity(0.5), radius: 4)
                }

                Spacer()

                // Business stats grid
                let shown = BizField.allCases.filter { enabled.contains($0) }
                let cols = [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)]
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(shown) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value(for: f))
                                .font(BrandFont.display(30)).foregroundColor(Brand.volt)
                                .shadow(color: .black.opacity(0.7), radius: 3)
                            Text(f.label.uppercased())
                                .font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(.white)
                                .shadow(color: .black.opacity(0.7), radius: 2)
                        }
                    }
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28).inset(by: 2.5)
                .stroke(Brand.volt, lineWidth: 5)
        )
        .padding(10)
    }

    private func value(for f: BizField) -> String {
        switch f {
        case .clients:    return "\(i.totalClients)"
        case .workouts:   return "\(i.workoutsThisWeek)"
        case .attention:  return "\(i.needingAttention)"
        case .awards:     return "\(i.awardsThisWeek)"
        case .drifting:   return "\(i.drifting)"
        case .avgTrained: return i.avgDaysSinceTrained > 90 ? "—" : "\(i.avgDaysSinceTrained)d"
        }
    }

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
        if !ok { showShareSheet = true }
        pendingImage = nil
    }
}
