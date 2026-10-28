import SwiftUI
import PhotosUI
import UIKit

// MARK: - Photos (Oct 27, 2026)
// Every photo, newest first, grouped by day. Add photo, Pick two and Filter float in a
// round column under the menu button, over the photos, and tuck away with it while you
// scroll down (they come back as soon as you scroll up).
// Hold a photo for its menu: Favorite, Share…, Make a share card, Compare with…,
// Save to Photos, Change label, Delete. Favorite / label / delete need server 2.7.5.

// MARK: Server calls (2.7.5)

extension APIClient {
    /// Change a photo's label and/or favorite. Returns the updated photo.
    @discardableResult
    func editPhoto(id: String, category: String? = nil, favorite: Bool? = nil) async throws -> APIPhoto {
        var body: [String: Any] = [:]
        if let category { body["category"] = category }
        if let favorite { body["favorite"] = favorite }
        let data = try await request("/photos/\(id)", method: "PATCH",
                                     body: try JSONSerialization.data(withJSONObject: body))
        return try decoder.decode(APIPhoto.self, from: data)
    }

    /// Gone from the app and the coach's view, and off any check-in it was sent with.
    func deletePhoto(id: String) async throws {
        _ = try await request("/photos/\(id)", method: "DELETE")
    }
}

// MARK: Filters (kept until you clear them)

enum PhotoShow: String, CaseIterable { case all, favorites }

enum PhotoLabelFilter: String, CaseIterable {
    case any, front, side, back, other
    var title: String {
        switch self {
        case .any: return "Any label"
        case .front: return "Front"
        case .side: return "Side"
        case .back: return "Back"
        case .other: return "Other"
        }
    }
    /// "Other" is anything that isn't Front, Side or Back (including "New").
    func matches(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .any: return true
        case .front: return c == "front"
        case .side: return c == "side"
        case .back: return c == "back"
        case .other: return !["front", "side", "back"].contains(c)
        }
    }
}

enum PhotoSourceFilter: String, CaseIterable {
    case any, checkIns, mine
    var title: String {
        switch self {
        case .any: return "Anywhere"
        case .checkIns: return "From check-ins"
        case .mine: return "Added by me"
        }
    }
}

enum PhotoTimeFilter: String, CaseIterable {
    case any, days30, months3, year
    var title: String {
        switch self {
        case .any: return "Any time"
        case .days30: return "Last 30 days"
        case .months3: return "Last 3 months"
        case .year: return "This year"
        }
    }
    func start(now: Date, cal: Calendar) -> Date? {
        let today = cal.startOfDay(for: now)
        switch self {
        case .any: return nil
        case .days30: return cal.date(byAdding: .day, value: -30, to: today)
        case .months3: return cal.date(byAdding: .month, value: -3, to: today)
        case .year: return cal.dateInterval(of: .year, for: now)?.start
        }
    }
}

extension ProgressPhoto {
    var isFavorite: Bool { favorite ?? false }
    var hasCoachComment: Bool { !(trainerComment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct PhotoShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - The screen

struct PhotosView: View {
    @EnvironmentObject var store: AppStore
    @State private var compareMode = false
    @State private var picked: [String] = []
    @State private var pickedItem: PhotosPickerItem?
    @State private var localImages: [String: UIImage] = [:]   // just-added photos (this session)
    @State private var expandedPhoto: ProgressPhoto?          // tapped photo, shown full screen
    @State private var scrollAnchor: CGFloat = 0              // where the last show/tuck happened
    @State private var shareItem: PhotoShareItem?
    @State private var toDelete: ProgressPhoto?
    @State private var toast: String?
    @State private var localOnly: Set<String> = []            // added here but never uploaded

    @AppStorage("bst_photos_show") private var show: PhotoShow = .all
    @AppStorage("bst_photos_label") private var label: PhotoLabelFilter = .any
    @AppStorage("bst_photos_source") private var source: PhotoSourceFilter = .any
    @AppStorage("bst_photos_coach") private var coachOnly = false
    @AppStorage("bst_photos_time") private var time: PhotoTimeFilter = .any

    static let labels = ["Front", "Side", "Back", "Other"]
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    // MARK: Filtering

    private var activeCount: Int {
        (show == .favorites ? 1 : 0) + (label != .any ? 1 : 0) + (source != .any ? 1 : 0)
            + (coachOnly ? 1 : 0) + (time != .any ? 1 : 0)
    }

    private var filtered: [ProgressPhoto] {
        let fromCheckIns = Set(store.checkIns.flatMap { $0.photoIDs })
        let start = time.start(now: Date(), cal: Calendar.training)
        return store.photos.filter { p in
            if show == .favorites && !p.isFavorite { return false }
            if !label.matches(p.category) { return false }
            switch source {
            case .any: break
            case .checkIns: if !fromCheckIns.contains(p.id) { return false }
            case .mine: if fromCheckIns.contains(p.id) { return false }
            }
            if coachOnly && !p.hasCoachComment { return false }
            if let start, p.date < start { return false }
            return true
        }
    }

    /// Newest day first; newest photo first within a day.
    private func buckets(_ photos: [ProgressPhoto]) -> [(day: Date, photos: [ProgressPhoto])] {
        let cal = Calendar.training
        let grouped = Dictionary(grouping: photos) { cal.startOfDay(for: $0.date) }
        return grouped.map { (day: $0.key, photos: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if show == .favorites { parts.append("Favorites") }
        if label != .any { parts.append(label.title) }
        if source != .any { parts.append(source.title) }
        if coachOnly { parts.append("Coach commented") }
        if time != .any { parts.append(time.title) }
        return parts.joined(separator: " · ")
    }

    private func clearFilters() {
        withAnimation(.easeInOut(duration: 0.2)) {
            show = .all; label = .any; source = .any; coachOnly = false; time = .any
        }
    }

    // MARK: Body

    var body: some View {
        let shown = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "Progress", title: "Photos",
                               subtitle: "\(store.photos.count) photo\(store.photos.count == 1 ? "" : "s") · only you and your coach can see them.")
                    .padding(.trailing, 60)          // clear of the floating buttons

                if activeCount > 0 && !store.photos.isEmpty {
                    activeLine(count: shown.count)
                }

                if compareMode {
                    Text("Pick two photos to compare them stacked, full width.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .padding(.trailing, 60)
                } else {
                    PhotoCompareCard(localImages: localImages)
                }

                ForEach(buckets(shown), id: \.day) { bucket in
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: bucket.day.formatted(.dateTime.month(.wide).day().year()).uppercased(),
                                        subtitle: "\(bucket.photos.count) photo\(bucket.photos.count == 1 ? "" : "s")")
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(bucket.photos) { p in photoTile(p) }
                        }
                    }
                    .padding(.top, 4)
                }

                if store.photos.isEmpty {
                    EmptyState(icon: "photo.on.rectangle",
                               title: "No photos yet",
                               message: "Add your first progress photo — or include them with your next check-in.")
                } else if shown.isEmpty {
                    VStack(spacing: 0) {
                        EmptyState(icon: "line.3.horizontal.decrease",
                                   title: "No photos match",
                                   message: "Nothing for \(filterSummary).")
                        Button { clearFilters() } label: {
                            Text("Clear filters").font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                                .padding(.horizontal, 18).frame(height: 40)
                                .overlay(Capsule().stroke(Brand.line, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .offset(y: -40)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
            scrolled(y)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .overlay(alignment: .topTrailing) { floatingButtons }
        .overlay(alignment: .bottom) { toastView }
        .onDisappear { store.menuButtonTucked = false }
        .sheet(isPresented: Binding(get: { picked.count == 2 }, set: { if !$0 { picked = [] } })) {
            if picked.count == 2, let a = photo(picked[0]), let b = photo(picked[1]) {
                CompareView(a: a, b: b)
            }
        }
        .fullScreenCover(item: $expandedPhoto) { p in
            FullScreenPhotoView(url: APIClient.shared.photoURL(p.id),
                                localImage: localImages[p.id],
                                caption: p.category)
        }
        .sheet(item: $shareItem) { s in
            ActivityView(items: [s.image])
                .presentationDetents([.medium, .large])
        }
        .alert("Delete this photo?",
               isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
               presenting: toDelete) { p in
            Button("Delete", role: .destructive) { delete(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(deleteMessage(p))
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    // Compress for upload (server caps at 3MB), then send to the server
                    // so the coach can see it. Keep the local image for instant display.
                    let jpeg = ui.jpegData(compressionQuality: 0.8) ?? data
                    if store.isLive {
                        if let created = try? await APIClient.shared.uploadPhoto(imageData: jpeg, category: "New") {
                            await MainActor.run {
                                localImages[created.id] = ui
                                store.photos.insert(created.toModel(), at: 0)
                                pickedItem = nil
                            }
                            return
                        }
                    }
                    // Demo mode (or upload failure) — fall back to local-only.
                    let id = UUID().uuidString
                    await MainActor.run {
                        localImages[id] = ui
                        localOnly.insert(id)
                        store.photos.insert(ProgressPhoto(id: id, date: Date(),
                                                          imageName: id, category: "New",
                                                          trainerComment: nil), at: 0)
                        pickedItem = nil
                    }
                } else {
                    await MainActor.run { pickedItem = nil }
                }
            }
        }
    }

    // MARK: Scrolling: tuck the buttons (and the menu button) away going down

    private func scrolled(_ y: CGFloat) {
        if y < 40 {                                   // at the top: always showing
            scrollAnchor = y
            if store.menuButtonTucked { store.menuButtonTucked = false }
            return
        }
        if store.menuButtonTucked {
            scrollAnchor = max(scrollAnchor, y)
            if scrollAnchor - y > 24 { store.menuButtonTucked = false; scrollAnchor = y }
        } else {
            scrollAnchor = min(scrollAnchor, y)
            if y - scrollAnchor > 24 { store.menuButtonTucked = true; scrollAnchor = y }
        }
    }

    // MARK: Floating buttons, under the menu button

    private var floatingButtons: some View {
        let n = activeCount
        return VStack(spacing: 8) {
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                PhotoRoundButton(icon: "plus", filled: true)
            }
            .accessibilityLabel("Add photo")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { compareMode.toggle(); picked = [] }
            } label: {
                PhotoRoundButton(icon: compareMode ? "xmark" : "rectangle.split.1x2", filled: compareMode)
            }
            .accessibilityLabel(compareMode ? "Stop picking" : "Pick two to compare")

            filterMenu(count: n)
        }
        .buttonStyle(.plain)
        // The menu button is 60 wide at 16 from the edge, 36 from the top; this column
        // sits 10 under it, centred on it.
        .padding(.trailing, 16 + (60 - 44) / 2)
        .padding(.top, 36 + 60 + 10)
        .opacity(store.menuButtonTucked ? 0 : 1)
        .offset(y: store.menuButtonTucked ? -40 : 0)
        .allowsHitTesting(!store.menuButtonTucked)
        .animation(.easeInOut(duration: 0.22), value: store.menuButtonTucked)
    }

    private func filterMenu(count n: Int) -> some View {
        Menu {
            Group {
                Section("Show") {
                    Toggle("All photos", isOn: Binding(get: { show == .all }, set: { if $0 { show = .all } }))
                    Toggle(isOn: Binding(get: { show == .favorites }, set: { show = $0 ? .favorites : .all })) {
                        Label("Favorites", systemImage: "star.fill")
                    }
                }
                Section("Label") {
                    ForEach(PhotoLabelFilter.allCases, id: \.self) { f in
                        Toggle(f.title, isOn: Binding(get: { label == f }, set: { if $0 { label = f } }))
                    }
                }
                Section("Source") {
                    ForEach(PhotoSourceFilter.allCases, id: \.self) { f in
                        Toggle(f.title, isOn: Binding(get: { source == f }, set: { if $0 { source = f } }))
                    }
                }
                Section {
                    Toggle("Coach commented", isOn: $coachOnly)
                }
                Section("Time") {
                    ForEach(PhotoTimeFilter.allCases, id: \.self) { f in
                        Toggle(f.title, isOn: Binding(get: { time == f }, set: { if $0 { time = f } }))
                    }
                }
            }
            .menuActionDismissBehavior(.disabled)     // stays open: set several at once
            Section {
                Button(role: .destructive) { clearFilters() } label: { Text("Clear filters") }
                    .disabled(n == 0)
            }
        } label: {
            PhotoRoundButton(icon: "line.3.horizontal.decrease", filled: n > 0, badge: n > 0 ? "\(n)" : nil)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(n > 0 ? "Filter photos, \(n) on" : "Filter photos")
    }

    private func activeLine(count: Int) -> some View {
        HStack(spacing: 8) {
            (Text(filterSummary).bold().foregroundColor(Brand.text)
             + Text(" · \(count) photo\(count == 1 ? "" : "s")").foregroundColor(Brand.mute))
                .font(BrandFont.body(13))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { clearFilters() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .heavy))
                    Text("Clear").font(BrandFont.body(12, .heavy))
                }
                .foregroundColor(Brand.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(Brand.text.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 60)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(BrandFont.body(13, .bold)).foregroundColor(Brand.bg)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Brand.text))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                if toast == text { withAnimation(.easeIn(duration: 0.2)) { toast = nil } }
            }
        }
    }

    // MARK: A photo

    private func photoTile(_ p: ProgressPhoto) -> some View {
        let isPicked = picked.contains(p.id)
        return Button {
            if compareMode {
                if isPicked { picked.removeAll { $0 == p.id } }
                else if picked.count < 2 { picked.append(p.id) }
            } else {
                expandedPhoto = p
            }
        } label: {
            // The tile's size comes from the grid column (a clear 4:5 box); the photo fills it
            // as an overlay. Sizing the photo itself let a tall image (a screenshot) push the
            // tile wider than its column, over its neighbours.
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .overlay { PhotoFill(photo: p, local: localImages[p.id]) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(p.category.uppercased()).font(BrandFont.body(8, .heavy)).tracking(0.8)
                        if p.hasCoachComment { Image(systemName: "bubble.left.fill").font(.system(size: 8)) }
                    }
                    .foregroundColor(.white)        // the scrim is black in both themes
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if compareMode {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isPicked ? Brand.voltText : Brand.text)
                            .padding(6)
                    } else if p.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(red: 1, green: 0.84, blue: 0.04))   // gold, both themes
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                            .padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isPicked ? Brand.voltLine : Brand.line, lineWidth: isPicked ? 3 : 1))
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if !compareMode { menuItems(p) }
        }
        .accessibilityLabel("\(p.category) photo, \(p.date.formatted(date: .abbreviated, time: .omitted))\(p.isFavorite ? ", favorite" : "")\(p.hasCoachComment ? ", coach commented" : "")")
    }

    @ViewBuilder private func menuItems(_ p: ProgressPhoto) -> some View {
        Button { setFavorite(p, !p.isFavorite) } label: {
            Label(p.isFavorite ? "Unfavorite" : "Favorite", systemImage: p.isFavorite ? "star.slash" : "star")
        }
        Button { share(p) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
        Button { makeShareCard(p) } label: { Label("Make a share card", systemImage: "rectangle.portrait.on.rectangle.portrait") }
        Button { startCompare(with: p) } label: { Label("Compare with…", systemImage: "rectangle.split.1x2") }
        Button { saveToPhotos(p) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
        Menu {
            ForEach(Self.labels, id: \.self) { l in
                Toggle(l, isOn: Binding(get: { p.category.caseInsensitiveCompare(l) == .orderedSame },
                                        set: { _ in relabel(p, l) }))
            }
        } label: {
            Label("Change label", systemImage: "tag")
        }
        Divider()
        Button(role: .destructive) { toDelete = p } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Actions

    private func photo(_ id: String) -> ProgressPhoto? { store.photos.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout ProgressPhoto) -> Void) {
        if let i = store.photos.firstIndex(where: { $0.id == id }) { change(&store.photos[i]) }
    }

    private func setFavorite(_ p: ProgressPhoto, _ on: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { update(p.id) { $0.favorite = on } }
        guard store.isLive, isOnServer(p) else { return }
        Task {
            do { try await APIClient.shared.editPhoto(id: p.id, favorite: on) }
            catch {
                await MainActor.run {
                    update(p.id) { $0.favorite = !on }
                    flash("Couldn't save that\(Self.why(error)).")
                }
            }
        }
    }

    private func relabel(_ p: ProgressPhoto, _ newLabel: String) {
        let old = p.category
        guard old != newLabel else { return }
        update(p.id) { $0.category = newLabel }
        guard store.isLive, isOnServer(p) else { return }
        Task {
            do { try await APIClient.shared.editPhoto(id: p.id, category: newLabel) }
            catch {
                await MainActor.run {
                    update(p.id) { $0.category = old }
                    flash("Couldn't change the label\(Self.why(error)).")
                }
            }
        }
    }

    private func deleteMessage(_ p: ProgressPhoto) -> String {
        let inCheckIn = store.checkIns.contains { $0.photoIDs.contains(p.id) }
        return "It's removed for you and your coach\(inCheckIn ? ", and taken off the check-in it was sent with" : ""). This can't be undone."
    }

    private func delete(_ p: ProgressPhoto) {
        guard store.isLive, isOnServer(p) else { removeLocally(p); return }
        Task {
            do {
                try await APIClient.shared.deletePhoto(id: p.id)
                await MainActor.run { removeLocally(p); flash("Photo deleted") }
            } catch {
                await MainActor.run { flash("Couldn't delete that photo\(Self.why(error)).") }
            }
        }
    }

    private func removeLocally(_ p: ProgressPhoto) {
        withAnimation(.easeInOut(duration: 0.25)) {
            store.photos.removeAll { $0.id == p.id }
        }
        for i in store.checkIns.indices { store.checkIns[i].photoIDs.removeAll { $0 == p.id } }
        localImages[p.id] = nil
        picked.removeAll { $0 == p.id }
    }

    /// What the server said, so a failure can be traced: " (server: 405)", " (no connection)".
    static func why(_ error: Error) -> String {
        if let s = error as? APIClient.HTTPStatusError { return " (server: \(s.status))" }
        if error is URLError { return " (no connection)" }
        return ""
    }

    /// A photo added while offline (upload failed) or in demo lives only on this phone.
    private func isOnServer(_ p: ProgressPhoto) -> Bool { !localOnly.contains(p.id) }

    private func startCompare(with p: ProgressPhoto) {
        withAnimation(.easeInOut(duration: 0.2)) { compareMode = true; picked = [p.id] }
    }

    private func loadImage(_ p: ProgressPhoto) async -> UIImage? {
        if let l = localImages[p.id] { return l }
        let url = APIClient.shared.photoURL(p.id)
        var req = URLRequest(url: url)
        if let token = APIClient.shared.token(for: url.path) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let reply = try? await URLSession.shared.data(for: req),
              let http = reply.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return UIImage(data: reply.0)
    }

    private func share(_ p: ProgressPhoto) {
        Task {
            if let img = await loadImage(p) { await MainActor.run { shareItem = PhotoShareItem(image: img) } }
            else { await MainActor.run { flash("Couldn't load that photo.") } }
        }
    }

    private func makeShareCard(_ p: ProgressPhoto) {
        Task {
            if let img = await loadImage(p) {
                await MainActor.run {
                    store.photoForShareCard = img          // ShareView picks it up instead of the camera
                    store.select(.share)
                }
            } else {
                await MainActor.run { flash("Couldn't load that photo.") }
            }
        }
    }

    private func saveToPhotos(_ p: ProgressPhoto) {
        Task {
            guard let img = await loadImage(p) else { await MainActor.run { flash("Couldn't load that photo.") }; return }
            let ok = await SharePhotos.save(image: img, video: nil)
            await MainActor.run { flash(ok ? "Saved to Photos" : "Couldn't save. Allow Photos in Settings.") }
        }
    }
}

// MARK: - Round floating button (44pt, under the 60pt menu button)

struct PhotoRoundButton: View {
    let icon: String
    var filled = false
    var badge: String? = nil

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(filled ? Brand.onVolt : Brand.text)
            .frame(width: 44, height: 44)
            .background(Circle().fill(filled ? Brand.volt : Brand.bg))
            .overlay(Circle().stroke(filled ? Color.clear : Brand.line, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 7, x: 0, y: 3)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(BrandFont.body(10, .heavy)).foregroundColor(Brand.bg)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Brand.text))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Circle())
    }
}
