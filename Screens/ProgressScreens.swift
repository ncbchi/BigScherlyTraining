import SwiftUI
import PhotosUI

// MARK: - Check-Ins (container ready; custom fields TBD)
struct CheckInsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showNew = false
    @State private var selected: CheckIn?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Accountability")
                Text("Check-Ins").font(BrandFont.display(48)).foregroundColor(.white)

                VoltButton(title: "+ New Check-In") { showNew = true }

                if store.checkIns.isEmpty {
                    EmptyState(icon: "checklist",
                               title: "No check-ins yet",
                               message: "Tap “+ New Check-In” to send your first update to your coach.")
                }

                ForEach(store.checkIns) { ci in
                    Button { selected = ci } label: { CheckInSummaryCard(checkIn: ci) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .sheet(isPresented: $showNew) { NewCheckInForm() }
        .sheet(item: $selected) { ci in CheckInDetailView(checkIn: ci) }
    }

    func statusPill(_ s: CheckInStatus) -> some View {
        let (t, c): (String, Color) = {
            switch s {
            case .draft: return ("DRAFT", Brand.mute)
            case .submitted: return ("SUBMITTED", Brand.volt)
            case .reviewed: return ("REVIEWED", Brand.volt)
            }
        }()
        return Text(t).font(BrandFont.body(10, .bold)).tracking(1)
            .foregroundColor(s == .reviewed ? Brand.black : c)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(s == .reviewed ? Brand.volt : Color.clear)
            .overlay(s == .reviewed ? nil : Capsule().stroke(c, lineWidth: 1))
    }
    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d) }
}

// MARK: - Photos (date buckets + side-by-side compare + trainer comments)
struct PhotosView: View {
    @EnvironmentObject var store: AppStore
    @State private var compareMode = false
    @State private var picked: [String] = []
    @State private var pickedItem: PhotosPickerItem?
    @State private var localImages: [String: UIImage] = [:]   // just-added photos (this session)
    @State private var expandedPhoto: ProgressPhoto?          // tapped photo, shown full screen

    var buckets: [(String, [ProgressPhoto])] {
        let grouped = Dictionary(grouping: store.photos) { p -> String in
            let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f.string(from: p.date)
        }
        return grouped.sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
    }
    let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Progress")
                        Text("Photos").font(BrandFont.display(48)).foregroundColor(.white)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        HStack { Image(systemName: "plus"); Text("ADD") }
                            .font(BrandFont.body(12, .bold)).foregroundColor(Brand.black)
                            .padding(.horizontal, 16).padding(.vertical, 10).background(Brand.volt).clipShape(Capsule())
                    }
                    Button { compareMode.toggle(); picked = [] } label: {
                        HStack { Image(systemName: "rectangle.split.2x1"); Text(compareMode ? "CANCEL" : "COMPARE") }
                            .font(BrandFont.body(12, .bold)).foregroundColor(compareMode ? Brand.danger : Brand.volt)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .overlay(Capsule().stroke(compareMode ? Brand.danger : Brand.volt, lineWidth: 2))
                    }
                }
                if compareMode {
                    Text("Pick two photos to compare side by side.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                }

                ForEach(buckets, id: \.0) { (label, pics) in
                    Text(label.uppercased()).font(BrandFont.body(12, .bold)).tracking(1.5).foregroundColor(Brand.volt).padding(.top, 8)
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(pics) { p in
                            photoTile(p)
                        }
                    }
                }

                if store.photos.isEmpty {
                    EmptyState(icon: "photo.on.rectangle",
                               title: "No photos yet",
                               message: "Tap ADD to upload your first progress photo.")
                }
            }
            .padding(20)
        }
        .sheet(isPresented: Binding(get: { picked.count == 2 }, set: { if !$0 { picked = [] } })) {
            CompareView(a: photo(picked[0]), b: photo(picked[1]))
        }
        .fullScreenCover(item: $expandedPhoto) { p in
            FullScreenPhotoView(url: APIClient.shared.photoURL(p.id),
                                localImage: localImages[p.id],
                                caption: p.category)
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

    func photoTile(_ p: ProgressPhoto) -> some View {
        Button {
            if compareMode {
                if picked.contains(p.id) { picked.removeAll { $0 == p.id } }
                else if picked.count < 2 { picked.append(p.id) }
            } else {
                expandedPhoto = p   // tap to view full screen
            }
        } label: {
            RoundedRectangle(cornerRadius: 16).fill(Brand.black)
                .aspectRatio(0.8, contentMode: .fit)
                .overlay(
                    Group {
                        if let ui = localImages[p.id] {
                            Image(uiImage: ui).resizable().scaledToFill()
                        } else {
                            // Load the encrypted server photo with the JWT attached.
                            // Plain Image(named:)/AsyncImage can't, so they showed "?".
                            AuthedAsyncImage(url: APIClient.shared.photoURL(p.id)) { img in
                                img.resizable().scaledToFill()
                            } placeholder: { failed in
                                if failed {
                                    Image(systemName: "photo").foregroundColor(Brand.mute)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    ProgressView().tint(Brand.volt)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }
                )
                .overlay(Text(p.category).font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute))
                .overlay(alignment: .bottomLeading) {
                    if p.trainerComment != nil {
                        Image(systemName: "text.bubble.fill").foregroundColor(Brand.volt).padding(6)
                    }
                }
                .overlay(picked.contains(p.id) ? RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 3) : nil)
                .clipped()
        }
    }
    func photo(_ id: String) -> ProgressPhoto { store.photos.first { $0.id == id }! }
}

// MARK: - Side-by-side compare
struct CompareView: View {
    @Environment(\.dismiss) var dismiss
    let a: ProgressPhoto, b: ProgressPhoto

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                // Two full-width photos stacked top/bottom — the right layout for
                // tall physique shots (side-by-side made them useless slivers).
                VStack(spacing: 10) {
                    comparePane(a)
                    comparePane(b)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Context footer: how the two shots relate, with a clean close.
                HStack(spacing: 12) {
                    Text(footerText)
                        .font(BrandFont.body(11, .bold)).tracking(1.5)
                        .foregroundColor(Brand.mute)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold)).foregroundColor(Brand.black)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Brand.volt))
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func comparePane(_ p: ProgressPhoto) -> some View {
        // Fills the full width, fit (not cropped) so the whole physique is visible,
        // with the date/category as an overlay strip at the top.
        Group {
            AuthedAsyncImage(url: APIClient.shared.photoURL(p.id)) { img in
                img.resizable().scaledToFit()
            } placeholder: { failed in
                if failed {
                    Image(systemName: "photo").foregroundColor(Brand.mute)
                } else {
                    ProgressView().tint(Brand.volt)
                }
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    Text(dateLabel(p.date)).font(BrandFont.body(13, .bold)).foregroundColor(.white)
                    Text(p.category.uppercased())
                        .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(.white.opacity(0.85))
                }
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.black.opacity(0.65), .clear],
                                           startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
            .background(Brand.black.clipShape(RoundedRectangle(cornerRadius: 14)))
    }

    // "12 weeks apart", "Same day · Front vs Side", etc.
    private var footerText: String {
        let days = Calendar.current.dateComponents([.day], from: min(a.date, b.date), to: max(a.date, b.date)).day ?? 0
        if days == 0 { return "\(a.category.uppercased()) vs \(b.category.uppercased())" }
        if days < 14 { return "\(days) DAYS APART" }
        return "\(days / 7) WEEKS APART"
    }

    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d) }
}

// MARK: - Announcements (newest first, clearable)
struct AnnouncementsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "From Coach")
                Text("Announcements").font(BrandFont.display(44)).foregroundColor(.white)

                if store.liveAnnouncements.isEmpty {
                    Text("You're all caught up. 👑").font(BrandFont.body(15)).foregroundColor(Brand.mute).padding(.top, 20)
                }

                ForEach(store.liveAnnouncements) { a in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(dateLabel(a.date)).font(BrandFont.body(11, .bold)).tracking(1).foregroundColor(Brand.volt)
                            Spacer()
                            Button { withAnimation { store.clearAnnouncement(a.id) } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(Brand.mute)
                            }
                        }
                        Text(a.title).font(BrandFont.display(24)).foregroundColor(.white)
                        Text(a.body).font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
            }
            .padding(20)
        }
    }
    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d) }
}

// MARK: - Reusable empty state
// A polite placeholder shown on any screen that currently has no data.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Brand.mute)
            Text(title)
                .font(BrandFont.display(24)).foregroundColor(.white)
            Text(message)
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60).padding(.horizontal, 24)
    }
}
