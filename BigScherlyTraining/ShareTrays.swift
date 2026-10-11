import SwiftUI
import UIKit

// MARK: - Share editor trays (Oct 9, 2026)
// Instagram's layout: each tray slides up over the card, dark, and is only as tall as
// what's in it (results scroll inside a fixed window, so the tray never grows to the top).
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

private struct ShareTrayExpandedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when a tray has been dragged up to full screen.
    var shareTrayExpanded: Bool {
        get { self[ShareTrayExpandedKey.self] }
        set { self[ShareTrayExpandedKey.self] = newValue }
    }
}

/// A tray's scrolling results: a fixed window while the tray fits its content, the whole
/// height once it's dragged up to full screen.
struct ShareTrayWindow: ViewModifier {
    var height: CGFloat? = nil
    var cap: CGFloat? = nil
    @Environment(\.shareTrayExpanded) private var expanded

    func body(content: Content) -> some View {
        if expanded {
            content.frame(maxHeight: .infinity)
        } else {
            content.frame(height: height).frame(maxHeight: cap)
        }
    }
}

/// Opens only as tall as its content; drag it up and it goes to the top of the screen.
private struct ShareTrayFit: ViewModifier {
    @State private var height: CGFloat = 0
    @State private var expanded = false

    func body(content: Content) -> some View {
        let fit = PresentationDetent.height(SheetFit.clamp(height > 0 ? height : 420))
        content
            .environment(\.shareTrayExpanded, expanded)
            .fixedSize(horizontal: false, vertical: !expanded)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !expanded { height = $0 } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            .presentationDetents([fit, .large], selection: Binding(
                get: { expanded ? .large : fit },
                set: { d in withAnimation(.easeInOut(duration: 0.2)) { expanded = (d == .large) } }))
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(26)
            .presentationBackground(Color(white: 0.11))
    }
}

extension View {
    func shareTrayFit() -> some View { modifier(ShareTrayFit()) }
}

private let trayMute = Color(white: 0.92).opacity(0.55)

struct ShareSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(trayMute)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(trayMute)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.46).opacity(0.24)))
    }

    @ViewBuilder private var field: some View {
        let tf = TextField("", text: $text, prompt: Text(placeholder).foregroundColor(trayMute))
            .font(.system(size: 16)).foregroundColor(.white)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.search)
        if let focus { tf.focused(focus) } else { tf }
    }
}

/// Wraps its children onto centred rows.
struct ShareFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 360
        let rs = rows(subviews, maxW)
        let h = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: maxW, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, _ maxW: CGFloat) -> [Row] {
        var out: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if !cur.items.isEmpty && add > maxW {
                out.append(cur)
                cur = Row()
                cur.items = [i]; cur.width = s.width; cur.height = s.height
            } else {
                cur.items.append(i); cur.width = add; cur.height = max(cur.height, s.height)
            }
        }
        if !cur.items.isEmpty { out.append(cur) }
        return out
    }
}

/// A white chip with gradient caps, like Instagram's interactive stickers.
struct ShareDataChip: View {
    let title: String
    let icon: String
    let tint: [Color]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundColor(tint.first ?? .black)
            Text(title).font(.system(size: 15, weight: .heavy)).tracking(-0.2)
                .foregroundStyle(LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
    }
}

private func poweredBy(_ text: String) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(trayMute)
        .frame(maxWidth: .infinity).padding(.vertical, 6)
}

// MARK: - Stickers

struct ShareStickerTray: View {
    let data: ShareDataSource
    let onAdd: (ShareItemKind) -> Void
    let onGIFs: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remote: [ShareGif] = []
    @State private var failed = false
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var category = ""          // "" = All: our pack, then trending
    private let provider: any ShareGifProvider = GiphyProvider.shared
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
    private let categories = ["", "Gym", "Hype", "Love", "Funny", "Words", "Celebrate", "Emoji", "Animals", "Food"]
    /// What GIPHY is asked for: the typed search, else the category.
    private var term: String { query.isEmpty ? category : query }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShareSearchField(placeholder: "Search stickers", text: $query)
            if query.isEmpty {
                ShareFlow(spacing: 8) {
                    Button { onGIFs() } label: {
                        ShareDataChip(title: "GIF", icon: "rectangle.stack.badge.play.fill",
                                      tint: [Color(red: 0.11, green: 0.36, blue: 0.84), Color(red: 0.42, green: 0.25, blue: 0.85)])
                    }
                    .buttonStyle(.plain)
                    ForEach(data.available.filter { Self.chipKinds.contains($0) }) { k in
                        Button { add(.data(k, k.defaultStyle)) } label: { ShareDataChip(title: k.chip, icon: k.icon, tint: k.tint) }
                            .buttonStyle(.plain)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { c in
                        let on = category == c && query.isEmpty
                        Button { category = c; query = "" } label: {
                            Text(c.isEmpty ? "All" : c).font(.system(size: 14, weight: .semibold))
                                .foregroundColor(on ? .black : .white)
                                .padding(.horizontal, 13).frame(height: 32)
                                .background(Capsule().fill(on ? Color.white : Color(white: 0.46).opacity(0.24)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let packs = matchingPacks
                    if !packs.isEmpty {
                        LazyVGrid(columns: cols, spacing: 6) {
                            ForEach(packs) { p in
                                Button { add(.pack(p)) } label: {
                                    Group {
                                        if let img = SharePackImages.image(p) {
                                            Image(uiImage: img).resizable().scaledToFit()
                                        } else {
                                            Color.clear
                                        }
                                    }
                                    .frame(height: 74).frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(p.keywords.components(separatedBy: " ").first ?? p.rawValue)
                            }
                        }
                    }
                    if !remote.isEmpty {
                        Text(term.isEmpty ? "Trending on GIPHY" : "From GIPHY")
                            .font(.system(size: 13, weight: .bold)).foregroundColor(trayMute)
                            .padding(.top, 6)
                        LazyVGrid(columns: cols, spacing: 6) {
                            ForEach(remote) { g in
                                Button { add(.gif(g)) } label: {
                                    ShareGifImage(url: g.preview, maxPixel: 140, maxFrames: 16)
                                        .aspectRatio(g.aspect, contentMode: .fit)
                                        .frame(height: 76).frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(g.title.isEmpty ? "Sticker" : g.title)
                                .onAppear { if g.id == remote.last?.id { Task { await loadMore() } } }
                            }
                        }
                        poweredBy(provider.attribution)
                    } else if failed {
                        Text("Couldn't load more stickers. Check your connection and search again.")
                            .font(.system(size: 13)).foregroundColor(trayMute).padding(.vertical, 8)
                    }
                }
            }
            .modifier(ShareTrayWindow(height: 300))
        }
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 4)
        .task(id: term) {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            reachedEnd = false
            do {
                remote = try await provider.search(term, .stickers, offset: 0)
                failed = false
            } catch {
                if !Task.isCancelled { remote = []; failed = true }
            }
        }
        .shareTrayFit()
    }

    /// Endless: the next page when the last sticker scrolls into view.
    private func loadMore() async {
        guard !loadingMore, !reachedEnd else { return }
        loadingMore = true
        defer { loadingMore = false }
        let q = term
        guard let more = try? await provider.search(q, .stickers, offset: remote.count), q == term else { return }
        let seen = Set(remote.map { $0.id })
        let fresh = more.filter { !seen.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true } else { remote += fresh }
    }

    /// The sticker tray's chips: the everyday ones. Everything else lives in Stats and trends.
    private static let chipKinds: Set<ShareDataKind> = [.pr, .workout, .stats, .streak, .topLift, .date, .award,
                                                        .barSpeed, .estMax, .volume, .trend, .crewWeek, .crewTrained, .crewAwards]

    private var matchingPacks: [SharePack] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return category.isEmpty || category == "Gym" ? SharePack.allCases : [] }
        return SharePack.allCases.filter { $0.keywords.contains(q) }
    }

    private func add(_ k: ShareItemKind) {
        onAdd(k)
        dismiss()
    }
}

// MARK: - Stats and trends

struct ShareStatsTray: View {
    let data: ShareDataSource
    let onAdd: (ShareItemKind) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Each sticker drawn once as a picture, then fitted into an even grid.
    @State private var shots: [ShareDataKind: UIImage] = [:]
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private static let session: [ShareDataKind] = [.pr, .workout, .stats, .today, .heaviestSet, .totalReps, .avgRPE,
                                                   .exercises, .sessionPRs, .topLift, .streak, .date, .award,
                                                   .crewWeek, .crewTrained, .crewAwards]
    private static let watch: [ShareDataKind] = [.barSpeed, .peakSpeed, .tut, .depth, .pausedReps]
    private static let trends: [ShareDataKind] = [.estMax, .liftTrend, .big3, .volume, .trend, .weeklySets,
                                                  .weekCount, .monthCount, .consistency, .prsMonth]
    private static let allTime: [ShareDataKind] = [.allTime, .lifetimeVolume, .prCount, .awardsTotal, .checkIns]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stats and trends").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            if data.available.isEmpty {
                Text("Log a workout and your numbers show up here.")
                    .font(.system(size: 14)).foregroundColor(trayMute).padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(crewMode ? "This week" : "This session", Self.session)
                        section("From your Watch", Self.watch)
                        section("Trends", Self.trends)
                        section("All time", Self.allTime)
                    }
                    .padding(.bottom, 8)
                }
                .modifier(ShareTrayWindow(cap: 500))
            }
        }
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 4)
        .task {
            var out: [ShareDataKind: UIImage] = [:]
            for k in data.available {
                guard let m = data.model(k) else { continue }
                let r = ImageRenderer(content: ShareDataStickerView(model: m, style: k.defaultStyle).padding(6))
                r.scale = 3
                if let img = r.uiImage { out[k] = img }
            }
            shots = out
        }
        .shareTrayFit()
    }

    private var crewMode: Bool { data.crew != nil }

    @ViewBuilder private func section(_ title: String, _ kinds: [ShareDataKind]) -> some View {
        let shown = kinds.filter { shots[$0] != nil }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(trayMute)
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(shown) { k in
                        Button { onAdd(.data(k, k.defaultStyle)); dismiss() } label: {
                            VStack(spacing: 6) {
                                if let img = shots[k] {
                                    Image(uiImage: img).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: 76)
                                        .frame(height: 76)
                                }
                                Text(k.chip.capitalized).font(.system(size: 12, weight: .semibold)).foregroundColor(trayMute)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - GIFs

struct ShareGifTray: View {
    let onAdd: (ShareItemKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ShareGif] = []
    @State private var failed = false
    @State private var loadingMore = false
    @State private var reachedEnd = false
    private let provider: any ShareGifProvider = GiphyProvider.shared
    /// Empty = Trending. Ideas only: search takes anything.
    private let suggestions = ["", "Hype", "Let's go", "Yes", "Celebrate", "Funny", "Mood", "Tired", "Flex", "Deadlift", "Leg day", "Gym fail"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ShareSearchField(placeholder: "Search GIFs", text: $query)
                Button("Cancel") { dismiss() }.font(.system(size: 16)).foregroundColor(.white)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        let on = query.caseInsensitiveCompare(s) == .orderedSame
                        Button { query = s } label: {
                            Text(s.isEmpty ? "Trending" : s).font(.system(size: 14, weight: .semibold))
                                .foregroundColor(on ? .black : .white)
                                .padding(.horizontal, 13).frame(height: 32)
                                .background(Capsule().fill(on ? Color.white : Color(white: 0.46).opacity(0.24)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ScrollView {
                if results.isEmpty {
                    Text(failed ? "Couldn't load GIFs. Check your connection and search again." : " ")
                        .font(.system(size: 13)).foregroundColor(trayMute)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let cols = split
                    HStack(alignment: .top, spacing: 6) {
                        column(cols.0, last: cols.0.last?.id)
                        column(cols.1, last: cols.1.last?.id)
                    }
                    poweredBy(provider.attribution)
                }
            }
            .modifier(ShareTrayWindow(height: 360))
        }
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 4)
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            reachedEnd = false
            do {
                results = try await provider.search(query, .gifs, offset: 0)
                failed = false
            } catch {
                if !Task.isCancelled { results = []; failed = true }
            }
        }
        .shareTrayFit()
    }

    /// Endless: the next page when either column's last GIF scrolls into view.
    private func loadMore() async {
        guard !loadingMore, !reachedEnd else { return }
        loadingMore = true
        defer { loadingMore = false }
        let q = query
        guard let more = try? await provider.search(q, .gifs, offset: results.count), q == query else { return }
        let seen = Set(results.map { $0.id })
        let fresh = more.filter { !seen.contains($0.id) }
        if fresh.isEmpty { reachedEnd = true } else { results += fresh }
    }

    /// Two columns, each GIF at its own height; every GIF goes in the shorter column.
    private var split: ([ShareGif], [ShareGif]) {
        var a: [ShareGif] = [], b: [ShareGif] = []
        var ha: CGFloat = 0, hb: CGFloat = 0
        for g in results {
            let h = 1 / max(g.aspect, 0.2)
            if ha <= hb { a.append(g); ha += h } else { b.append(g); hb += h }
        }
        return (a, b)
    }

    private func column(_ gifs: [ShareGif], last: String?) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(gifs) { g in
                Button { onAdd(.gif(g)); dismiss() } label: {
                    ShareGifImage(url: g.preview)
                        .aspectRatio(g.aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(g.title.isEmpty ? "GIF" : g.title)
                .onAppear { if g.id == last { Task { await loadMore() } } }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Send

struct ShareSendChoice {
    var external: SocialTarget? = nil     // Instagram, Facebook, or the share sheet (one app at a time)
    var save = false
    var coach = false
    var video = false
}

struct ShareSendSheet: View {
    @Binding var format: ShareFormat
    let hasMotion: Bool
    let canSendCoach: Bool
    let onShare: (ShareSendChoice) -> Void

    @State private var choice = ShareSendChoice(external: .instagram)
    @State private var asVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Share to").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                Spacer()
                if hasMotion {
                    segmented(["Photo", "Video"], asVideo ? 1 : 0) { asVideo = $0 == 1 }
                        .frame(width: 150)
                }
            }
            segmented(ShareFormat.allCases.map { $0.rawValue }, ShareFormat.allCases.firstIndex(of: format) ?? 0) { i in
                withAnimation(.easeInOut(duration: 0.2)) { format = ShareFormat.allCases[i] }
            }
            VStack(spacing: 0) {
                row("Instagram story", "Opens Instagram with your card", icon: "camera.circle.fill",
                    bg: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.98, green: 0.8, blue: 0.2), Color(red: 0.93, green: 0.16, blue: 0.48), Color(red: 0.38, green: 0.16, blue: 0.84)], startPoint: .bottomLeading, endPoint: .topTrailing)),
                    on: choice.external == .instagram) { pickExternal(.instagram) }
                row("Facebook story", "Opens Facebook with your card", icon: "f.circle.fill",
                    bg: AnyShapeStyle(Color(red: 0.09, green: 0.47, blue: 0.95)),
                    on: choice.external == .facebook) { pickExternal(.facebook) }
                if canSendCoach {
                    row("My coach", "Sends it to your coach chat", icon: "bubble.left.fill",
                        bg: AnyShapeStyle(Brand.volt), fg: Brand.onVolt, on: choice.coach) { choice.coach.toggle() }
                }
                row("Save to Photos", hasMotion && asVideo ? "As a video" : "As a photo", icon: "square.and.arrow.down",
                    bg: AnyShapeStyle(Color(white: 0.46).opacity(0.3)), on: choice.save) { choice.save.toggle() }
                row("More", "Snapchat, Messages, AirDrop…", icon: "ellipsis",
                    bg: AnyShapeStyle(Color(white: 0.46).opacity(0.3)), on: choice.external == .systemSheet) { pickExternal(.systemSheet) }
            }
            Button {
                var c = choice
                c.video = hasMotion && asVideo
                onShare(c)
            } label: {
                Text(count > 1 ? "Share to \(count)" : "Share")
                    .font(.system(size: 17, weight: .bold)).foregroundColor(.black)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 4)
        .shareTrayFit()
    }

    private var count: Int { (choice.external == nil ? 0 : 1) + (choice.save ? 1 : 0) + (choice.coach ? 1 : 0) }

    private func pickExternal(_ t: SocialTarget) {
        choice.external = choice.external == t ? nil : t
    }

    private func segmented(_ items: [String], _ current: Int, pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                Button { pick(i) } label: {
                    Text(t).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(i == current ? .white : Color.white.opacity(0.7))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(i == current ? Color(white: 0.39) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.46).opacity(0.24)))
    }

    private func row(_ title: String, _ sub: String, icon: String, bg: AnyShapeStyle, fg: Color = .white,
                     on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundColor(fg)
                    .frame(width: 44, height: 44).background(Circle().fill(bg))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Text(sub).font(.system(size: 13)).foregroundColor(trayMute)
                }
                Spacer()
                ZStack {
                    if on {
                        Circle().fill(Brand.volt).frame(width: 24, height: 24)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt)
                    } else {
                        Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5).frame(width: 22, height: 22)
                    }
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Text editor (over the card, Instagram style)

struct ShareTextEditor: View {
    @Binding var draft: ShareText
    /// The card's on-screen scale, so the text is the size it will be on the card.
    let scale: CGFloat
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDone() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    toolButton(label: "Background") {
                        Text("A").font(.system(size: 15, weight: .heavy))
                            .foregroundColor(draft.backing == .none ? .white : .black)
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(draft.backing == .none ? Color.clear : Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: draft.backing == .none ? 1.5 : 0))
                    } action: { draft.backing = draft.backing.next }
                    Spacer()
                    Button("Done") { onDone() }
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                        .padding(.trailing, 70)          // clear of the menu button
                }
                .padding(.horizontal, 14).padding(.top, 10)

                HStack(alignment: .center, spacing: 0) {
                    sizeSlider.padding(.leading, 12)
                    Spacer(minLength: 8)
                    TextField("", text: $draft.text, axis: .vertical)
                        .focused($focused)
                        .font(draft.font.font(draft.size * scale))
                        .multilineTextAlignment(.center)
                        .foregroundColor(textColor)
                        .padding(.horizontal, draft.backing == .none ? 0 : 12).padding(.vertical, draft.backing == .none ? 0 : 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(backingColor))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 310 * scale)
                        .tint(Brand.volt)
                    Spacer(minLength: 8)
                    Color.clear.frame(width: 20)
                }
                .frame(maxHeight: .infinity)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<ShareTextPalette.count, id: \.self) { i in
                            let c = ShareTextPalette.color(i)
                            Button { draft.color = i } label: {
                                Circle().fill(c).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .padding(3)
                                    .overlay(Circle().stroke(Color.white, lineWidth: draft.color == i ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(i + 1)")
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ShareTextFont.allCases) { f in
                            let on = draft.font == f
                            Button { draft.font = f } label: {
                                Text(f.rawValue).font(f.font(17))
                                    .foregroundColor(on ? .black : .white)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(Capsule().fill(on ? Color.white : Color.black.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear { focused = true }
    }

    private var textColor: Color {
        switch draft.backing {
        case .none: return ShareTextPalette.color(draft.color)
        case .solid: return ShareTextPalette.onColor(ShareTextPalette.color(draft.color))
        case .accent: return Brand.onVolt
        }
    }

    private var backingColor: Color {
        switch draft.backing {
        case .none: return .clear
        case .solid: return ShareTextPalette.color(draft.color)
        case .accent: return Brand.volt
        }
    }

    private func toolButton<L: View>(label: String, @ViewBuilder _ content: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: 40, height: 40).background(Circle().fill(Color.black.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Drag up and down to size the text.
    private var sizeSlider: some View {
        let h: CGFloat = 200
        let lo: CGFloat = 22, hi: CGFloat = 100
        let f = (draft.size - lo) / (hi - lo)
        return ZStack(alignment: .top) {
            Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                .frame(width: 6, height: h)
            Circle().fill(Color.white).frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .offset(y: (1 - f) * (h - 22))
        }
        .frame(width: 26, height: h)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let y = min(max(v.location.y, 0), h)
            draft.size = lo + (1 - y / h) * (hi - lo)
        })
        .accessibilityElement()
        .accessibilityLabel("Text size")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: draft.size = min(hi, draft.size + 6)
            case .decrement: draft.size = max(lo, draft.size - 6)
            @unknown default: break
            }
        }
    }
}
