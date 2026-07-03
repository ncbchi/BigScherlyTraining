import SwiftUI

// MARK: - Check-Ins (container ready; custom fields TBD)
struct CheckInsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Accountability")
                Text("Check-Ins").font(BrandFont.display(48)).foregroundColor(.white)

                VoltButton(title: "+ New Check-In") { showNew = true }

                ForEach(store.checkIns) { ci in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(dateLabel(ci.date)).font(BrandFont.display(22)).foregroundColor(.white)
                            Spacer()
                            statusPill(ci.status)
                        }
                        // Submitted data
                        ForEach(ci.fields) { f in
                            HStack {
                                Text(f.label).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                                Spacer()
                                Text(f.value).font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                            }
                        }
                        if !ci.photoIDs.isEmpty {
                            Text("\(ci.photoIDs.count) photo\(ci.photoIDs.count>1 ? "s" : "") attached")
                                .font(BrandFont.body(12)).foregroundColor(Brand.volt)
                        }
                        // Trainer response
                        if let resp = ci.trainerResponse {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("COACH RESPONSE").font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.volt)
                                Text(resp).font(BrandFont.body(14)).foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).background(Brand.bg)
                            .overlay(Rectangle().stroke(Brand.volt.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .card()
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .sheet(isPresented: $showNew) { NewCheckInSheet() }
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

struct NewCheckInSheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Check-in fields are being finalized with your coach. The photo attach and submit flow are ready.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    // Placeholder for custom fields (defined later)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR DATA").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        Text("(Custom fields will appear here)").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
                            .overlay(Rectangle().stroke(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [6])))
                    }

                    // Photo attach — always available
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ATTACH PHOTOS").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        Button {} label: {
                            HStack { Image(systemName: "photo.on.rectangle.angled"); Text("Select from your photos") }
                                .font(BrandFont.body(14, .semibold)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 18).card(padding: 0)
                        }
                    }

                    VoltButton(title: "Submit Check-In") { dismiss() }
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New Check-In")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }
}

// MARK: - Photos (date buckets + side-by-side compare + trainer comments)
struct PhotosView: View {
    @EnvironmentObject var store: AppStore
    @State private var compareMode = false
    @State private var picked: [String] = []

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
                    Button {} label: {
                        HStack { Image(systemName: "plus"); Text("ADD") }
                            .font(BrandFont.body(12, .bold)).foregroundColor(Brand.black)
                            .padding(.horizontal, 16).padding(.vertical, 10).background(Brand.volt)
                    }
                    Button { compareMode.toggle(); picked = [] } label: {
                        HStack { Image(systemName: "rectangle.split.2x1"); Text(compareMode ? "CANCEL" : "COMPARE") }
                            .font(BrandFont.body(12, .bold)).foregroundColor(compareMode ? Brand.danger : Brand.volt)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .overlay(Rectangle().stroke(compareMode ? Brand.danger : Brand.volt, lineWidth: 2))
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
            }
            .padding(20)
        }
        .sheet(isPresented: Binding(get: { picked.count == 2 }, set: { if !$0 { picked = [] } })) {
            CompareView(a: photo(picked[0]), b: photo(picked[1]))
        }
    }

    func photoTile(_ p: ProgressPhoto) -> some View {
        Button {
            if compareMode {
                if picked.contains(p.id) { picked.removeAll { $0 == p.id } }
                else if picked.count < 2 { picked.append(p.id) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 2).fill(Brand.black)
                .aspectRatio(0.8, contentMode: .fit)
                .overlay(Image(p.imageName).resizable().scaledToFill())
                .overlay(Text(p.category).font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute))
                .overlay(alignment: .bottomLeading) {
                    if p.trainerComment != nil {
                        Image(systemName: "text.bubble.fill").foregroundColor(Brand.volt).padding(6)
                    }
                }
                .overlay(picked.contains(p.id) ? Rectangle().stroke(Brand.volt, lineWidth: 3) : nil)
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
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    comparePane(a); comparePane(b)
                }
                Spacer()
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Compare")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }
    func comparePane(_ p: ProgressPhoto) -> some View {
        VStack(spacing: 8) {
            Image(p.imageName).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 420).clipped()
                .background(Brand.black)
            Text(dateLabel(p.date)).font(BrandFont.body(13, .bold)).foregroundColor(.white)
            Text(p.category).font(BrandFont.body(11)).foregroundColor(Brand.mute)
        }
    }
    func dateLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d) }
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
