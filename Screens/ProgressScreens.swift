import SwiftUI
import PhotosUI

// MARK: - Check-Ins
// Next check-in (with a start button) → your latest check-in against the one before
// it, with your coach's reply → bodyweight trend → before/after photo slider →
// every past check-in.

struct CheckInsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"
    @State private var showNew = false
    @State private var selected: CheckIn?

    private let cal = Calendar.training
    private var sorted: [CheckIn] { store.checkIns.sorted { $0.date > $1.date } }
    private var submitted: [CheckIn] { sorted.filter { $0.status != .draft } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSScreenHeader(eyebrow: "Progress", title: "Check-Ins",
                               subtitle: "Weekly check-ins and progress photos, side by side.")
                    .staggeredAppear(0)
                nextCard.staggeredAppear(1)
                if let latest = submitted.first {
                    VStack(alignment: .leading, spacing: 12) {
                        DSSectionHeader(title: "LATEST CHECK-IN")
                        Button { selected = latest } label: { comparisonCard(latest, previous: submitted.dropFirst().first) }
                            .buttonStyle(PressableStyle())
                    }
                    .staggeredAppear(2)
                }
                weightTrend.staggeredAppear(3)
                if !store.photos.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        DSSectionHeader(title: "PHOTOS")
                        PhotoCompareCard(showAllLink: true)
                    }
                    .staggeredAppear(4)
                }
                history.staggeredAppear(5)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .sheet(isPresented: $showNew) { NewCheckInForm() }
        .sheet(item: $selected) { ci in CheckInDetailView(checkIn: ci) }
    }

    // MARK: Next check-in

    private var nextCard: some View {
        let today = cal.startOfDay(for: Date())
        let last = submitted.first
        let due = last.map { cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: $0.date)) ?? today } ?? today
        let days = cal.dateComponents([.day], from: today, to: due).day ?? 0
        let draft = sorted.first { $0.status == .draft }
        let headline: String = {
            if last == nil { return "Your first check-in" }
            if days < 0 { return "Overdue by \(-days) day\(days == -1 ? "" : "s")" }
            if days == 0 { return "Due today" }
            return "Due \(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        }()
        let sentThisWeek = last.map { cal.isSameTrainingWeek($0.date, Date()) } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentThisWeek && days > 0 ? "Sent this week · next check-in" : "Next check-in")
                        .font(BrandFont.body(12, .bold)).opacity(0.7)
                    Text(headline).font(BrandFont.display(26))
                }
                Spacer()
            }
            .foregroundColor(Brand.onVolt)
            Button { showNew = true } label: {
                Label(draft != nil ? "Finish your draft" : "Start check-in", systemImage: "square.and.pencil")
            }
            .buttonStyle(DSButtonStyle(kind: .dark))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(days <= 0 || last == nil ? Brand.volt : Brand.volt.opacity(0.85)))
    }

    // MARK: Latest vs previous

    private struct Delta: Identifiable {
        let id: String; let label: String; let now: Double; let prev: Double?; let unit: String; let higherIsBetter: Bool?
    }

    private func value(_ ci: CheckIn?, _ qid: String) -> Double? {
        guard let ci, let q = CheckInSchema.question(qid) else { return nil }
        return ci.fields.first { $0.id == qid || $0.cleanLabel == q.label }.flatMap { Double($0.value) }
    }

    private func comparisonCard(_ ci: CheckIn, previous: CheckIn?) -> some View {
        let specs: [(String, String, Bool?)] = [("weight", "BODYWEIGHT", nil), ("sleepQuality", "SLEEP", true),
                                                ("energy", "ENERGY", true), ("stress", "STRESS", false),
                                                ("nutrition", "NUTRITION", true), ("soreness", "RECOVERY", true)]
        let deltas: [Delta] = specs.compactMap { id, label, better in
            guard let now = value(ci, id) else { return nil }
            let isWeight = id == "weight"
            return Delta(id: id, label: label, now: isWeight ? StatsUnits.weight(now) : now,
                         prev: value(previous, id).map { isWeight ? StatsUnits.weight($0) : $0 },
                         unit: isWeight ? " \(StatsUnits.weightLabel)" : "", higherIsBetter: better)
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(previous.map { "\(ci.date.formatted(.dateTime.month(.abbreviated).day())) vs \($0.date.formatted(.dateTime.month(.abbreviated).day()))" }
                     ?? ci.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                statusChip(ci.status)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(deltas) { d in deltaTile(d) }
            }
            if let reply = ci.trainerResponse {
                VStack(alignment: .leading, spacing: 6) {
                    Text("COACH'S REPLY").font(BrandFont.body(9, .bold)).tracking(1.2).headerPill()
                    Text("“\(reply)”").font(BrandFont.body(13, .medium)).foregroundColor(Brand.text)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
            } else if ci.status == .submitted {
                Label("Sent — your coach will reply here.", systemImage: "paperplane.fill")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            }
            HStack {
                Text("See all answers").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.voltText)
            }
        }
        .card(padding: 16)
    }

    private func deltaTile(_ d: Delta) -> some View {
        let diff = d.prev.map { d.now - $0 }
        let color: Color = {
            guard let diff, diff != 0, let good = d.higherIsBetter else { return Brand.mute }
            return (diff > 0) == good ? Brand.volt : .orange
        }()
        let isWeight = d.id == "weight"
        let fmt: (Double) -> String = { v in
            isWeight && StatsUnits.isKg ? String(format: "%.1f", v) : (v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v))
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(d.label).font(BrandFont.body(8, .bold)).tracking(0.8).foregroundColor(Brand.mute).lineLimit(1)
            Text(fmt(d.now) + d.unit).font(BrandFont.body(17, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(diff.map { $0 == 0 ? "· same" : "\($0 > 0 ? "▲" : "▼") \(fmt(abs($0))) vs last" } ?? "first one")
                .font(BrandFont.body(10, .bold)).foregroundColor(Brand.readable(color)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
    }

    private func statusChip(_ s: CheckInStatus) -> some View {
        switch s {
        case .draft: return DSChip(text: "Draft", icon: "pencil", color: Brand.mute)
        case .submitted: return DSChip(text: "Sent", icon: "paperplane.fill", color: Brand.volt)
        case .reviewed: return DSChip(text: "Reviewed", icon: "checkmark", color: Brand.volt, filled: true)
        }
    }

    // MARK: Bodyweight trend

    @ViewBuilder
    private var weightTrend: some View {
        let points: [(Date, Double)] = submitted.reversed().compactMap { ci in
            value(ci, "weight").map { (ci.date, StatsUnits.weight($0)) }
        }
        if points.count >= 2, let first = points.first?.1, let last = points.last?.1 {
            let change = last - first
            VStack(alignment: .leading, spacing: 12) {
                DSSectionHeader(title: "BODYWEIGHT", subtitle: "from your check-ins")
                VStack(alignment: .leading, spacing: 10) {
                    Text(abs(change) < 0.1 ? "Holding steady at \(fmtW(last))."
                         : "\(change < 0 ? "Down" : "Up") \(fmtW(abs(change))) since \(points.first!.0.formatted(.dateTime.month(.abbreviated).day())).")
                        .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                    MiniChart(lines: [MiniChart.Line(name: "Bodyweight", color: Brand.volt, points: points)],
                              unit: StatsUnits.weightLabel, height: 130)
                }
                .card(padding: 16)
            }
        }
    }

    private func fmtW(_ v: Double) -> String {
        (StatsUnits.isKg ? String(format: "%.1f", v) : (v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v))) + " " + StatsUnits.weightLabel
    }

    // MARK: History

    @ViewBuilder
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "HISTORY", subtitle: sorted.isEmpty ? nil : "\(sorted.count) check-in\(sorted.count == 1 ? "" : "s")")
            if sorted.isEmpty {
                EmptyState(icon: "checklist", title: "No check-ins yet",
                           message: "Start your first one above to send your coach an update.")
            }
            ForEach(sorted) { ci in
                Button { selected = ci } label: {
                    DSListRow(title: "\(ci.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) check-in",
                              subtitle: [ci.status == .reviewed ? "Reviewed" : (ci.status == .submitted ? "Sent" : "Draft"),
                                         value(ci, "weight").map { fmtW(StatsUnits.weight($0)) },
                                         ci.photoIDs.isEmpty ? nil : "\(ci.photoIDs.count) photo\(ci.photoIDs.count == 1 ? "" : "s")",
                                         ci.trainerResponse != nil ? "coach replied" : nil]
                                .compactMap { $0 }.joined(separator: " · "),
                              icon: ci.status == .reviewed ? "checkmark.seal.fill" : (ci.status == .submitted ? "paperplane.fill" : "pencil"))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

// MARK: - Photos
// The before/after slider up top, then every photo grouped by date. Add new photos,
// or pick any two to compare stacked full-width.

struct PhotosView: View {
    @EnvironmentObject var store: AppStore
    @State private var compareMode = false
    @State private var picked: [String] = []
    @State private var pickedItem: PhotosPickerItem?
    @State private var localImages: [String: UIImage] = [:]   // just-added photos (this session)
    @State private var expandedPhoto: ProgressPhoto?          // tapped photo, shown full screen

    private var buckets: [(day: Date, photos: [ProgressPhoto])] {
        let cal = Calendar.training
        let grouped = Dictionary(grouping: store.photos) { cal.startOfDay(for: $0.date) }
        return grouped.map { (day: $0.key, photos: $0.value) }.sorted { $0.day > $1.day }
    }
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "Progress", title: "Photos",
                               subtitle: "\(store.photos.count) photo\(store.photos.count == 1 ? "" : "s") · only you and your coach can see them.")
                HStack(spacing: 10) {
                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        Label("Add photo", systemImage: "plus")
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.onVolt)
                            .frame(maxWidth: .infinity, minHeight: 46).background(Capsule().fill(Brand.volt))
                    }
                    Button { compareMode.toggle(); picked = [] } label: {
                        Label(compareMode ? "Cancel" : "Pick two", systemImage: compareMode ? "xmark" : "rectangle.split.1x2")
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                if compareMode {
                    Text("Pick two photos to compare them stacked, full width.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                } else {
                    PhotoCompareCard(localImages: localImages)
                }

                ForEach(buckets, id: \.day) { bucket in
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
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
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
            PhotoFill(photo: p, local: localImages[p.id])
                .aspectRatio(0.8, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(p.category.uppercased()).font(BrandFont.body(8, .heavy)).tracking(0.8)
                        if p.trainerComment != nil { Image(systemName: "bubble.left.fill").font(.system(size: 8)) }
                    }
                    .foregroundColor(Brand.text)
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
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isPicked ? Brand.voltLine : Brand.line, lineWidth: isPicked ? 3 : 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(p.category) photo, \(p.date.formatted(date: .abbreviated, time: .omitted))\(p.trainerComment != nil ? ", coach commented" : "")")
    }

    private func photo(_ id: String) -> ProgressPhoto { store.photos.first { $0.id == id }! }
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
                            .font(.system(size: 13, weight: .bold)).foregroundColor(Brand.onVolt)
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
                    Text(dateLabel(p.date)).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                    Text(p.category.uppercased())
                        .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.text.opacity(0.85))
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
                DSScreenHeader(eyebrow: "From Coach", title: "Announcements",
                               subtitle: store.liveAnnouncements.isEmpty ? nil
                                   : "\(store.liveAnnouncements.count) for you · clear them once you've read them")

                if store.liveAnnouncements.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(Brand.voltText)
                        Text("You're all caught up. 👑").font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                ForEach(Array(store.liveAnnouncements.enumerated()), id: \.element.id) { i, a in
                    let fresh = Date().timeIntervalSince(a.date) < 3 * 86400
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "megaphone.fill").font(.system(size: 13)).foregroundColor(Brand.voltText)
                            Text(a.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
                                .font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                            if fresh { DSChip(text: "New", color: Brand.volt, filled: true) }
                            Spacer()
                        }
                        Text(a.title).font(BrandFont.display(i == 0 ? 28 : 22)).foregroundColor(Brand.text)
                        Text(a.body).font(BrandFont.body(14)).foregroundColor(Brand.text.opacity(0.8))
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        Button { withAnimation(.spring(response: 0.35)) { store.clearAnnouncement(a.id) } } label: {
                            Label("Clear", systemImage: "checkmark")
                                .font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear \(a.title)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(i == 0 ? Brand.voltLine.opacity(0.5) : Brand.line, lineWidth: 1))
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
    }
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
                .font(BrandFont.display(24)).foregroundColor(Brand.text)
            Text(message)
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60).padding(.horizontal, 24)
    }
}
