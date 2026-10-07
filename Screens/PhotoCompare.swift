import SwiftUI
import UIKit

// MARK: - Progress photo compare (reveal slider)
// One photo over the other with a draggable divider: drag left/right to reveal
// before vs after. Used on Check-Ins and Photos. Category chips pick the pose;
// it compares that pose's earliest photo with its latest.

struct PhotoRevealSlider: View {
    let before: ProgressPhoto
    let after: ProgressPhoto
    var localImages: [String: UIImage] = [:]
    /// The coach app loads photos from the coach route; nil = the client's own route.
    var urlFor: ((ProgressPhoto) -> URL)? = nil

    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                PhotoFill(photo: after, local: localImages[after.id], url: urlFor?(after)).frame(width: w, height: h)
                PhotoFill(photo: before, local: localImages[before.id], url: urlFor?(before)).frame(width: w, height: h)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * split)) }

                // Labels
                label("BEFORE", before.date).padding(10)
                label("AFTER", after.date).padding(10)
                    .frame(width: w, alignment: .trailing)

                // Divider + handle
                Rectangle().fill(Brand.volt).frame(width: 3, height: h)
                    .offset(x: w * split - 1.5)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 14, weight: .heavy)).foregroundColor(Brand.onVolt)
                    .frame(width: 40, height: 40).background(Circle().fill(Brand.volt))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: w * split - 20, y: h / 2 - 20)
            }
            // Sideways drags move the divider; anything with up/down in it is refused
            // and goes to the scroll view, so the page still scrolls over the photo.
            .overlay(HorizontalPan { x in split = min(0.98, max(0.02, x)) })
        }
        .aspectRatio(0.8, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Before and after comparison, \(before.date.formatted(date: .abbreviated, time: .omitted)) and \(after.date.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityValue("\(Int(split * 100)) percent before")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: split = min(0.98, split + 0.1)
            case .decrement: split = max(0.02, split - 0.1)
            @unknown default: break
            }
        }
    }

    private func label(_ t: String, _ d: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(BrandFont.body(9, .heavy)).tracking(1)
            Text(d.formatted(.dateTime.month(.abbreviated).day())).font(BrandFont.body(12, .bold))
        }
        .foregroundColor(.white)        // the scrim is black in both themes
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
    }
}

/// A progress photo filling its frame: just-added local image, else the server copy.
struct PhotoFill: View {
    let photo: ProgressPhoto
    var local: UIImage? = nil
    var url: URL? = nil

    var body: some View {
        ZStack {
            Brand.black
            if let local {
                Image(uiImage: local).resizable().scaledToFill()
            } else {
                AuthedAsyncImage(url: url ?? APIClient.shared.photoURL(photo.id)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { failed in
                    VStack(spacing: 6) {
                        if failed {
                            Image(systemName: "photo").font(.system(size: 26)).foregroundColor(Brand.mute)
                            Text(photo.category.uppercased()).font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
                        } else {
                            ProgressView().tint(Brand.volt)
                        }
                    }
                }
            }
        }
        .clipped()
    }
}

/// Category chips + the slider + coach's comment on the newer photo.
struct PhotoCompareCard: View {
    @EnvironmentObject var store: AppStore
    var localImages: [String: UIImage] = [:]
    var showAllLink = false

    @State private var category: String? = nil

    /// Poses with photos on at least two different days, most-photographed first.
    private var categories: [String] {
        let cal = Calendar.training
        let grouped = Dictionary(grouping: store.photos, by: { $0.category })
        return grouped.filter { _, ps in Set(ps.map { cal.startOfDay(for: $0.date) }).count >= 2 }
            .sorted { a, b in
                let order = ["Front", "Side", "Back"]
                let ia = order.firstIndex(of: a.key) ?? 99, ib = order.firstIndex(of: b.key) ?? 99
                return ia == ib ? a.value.count > b.value.count : ia < ib
            }
            .map { $0.key }
    }

    private func pair(_ cat: String) -> (ProgressPhoto, ProgressPhoto)? {
        let ps = store.photos.filter { $0.category == cat }.sorted { $0.date < $1.date }
        guard let first = ps.first, let last = ps.last, first.id != last.id else { return nil }
        return (first, last)
    }

    var body: some View {
        let cats = categories
        if let cat = category ?? cats.first, let pr = pair(cat) {
            let b = pr.0, a = pr.1
            let weeks = max(1, Calendar.training.dateComponents([.day], from: b.date, to: a.date).day.map { $0 / 7 } ?? 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("COMPARE · \(cat.uppercased())").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                    Spacer()
                    Text("\(weeks) week\(weeks == 1 ? "" : "s") apart").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
                PhotoRevealSlider(before: b, after: a, localImages: localImages)
                    .id(cat)
                HStack(spacing: 6) {
                    Text("Drag to compare").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    Spacer()
                    ForEach(cats.prefix(4), id: \.self) { c in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { category = c } } label: {
                            Text(c).font(BrandFont.body(11, .bold))
                                .foregroundColor(c == cat ? Brand.onVolt : Brand.mute)
                                .padding(.horizontal, 10).frame(minHeight: 30)
                                .background(Capsule().fill(c == cat ? Brand.volt : Color.clear))
                                .overlay(Capsule().stroke(c == cat ? Brand.voltLine : Brand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let comment = a.trainerComment ?? b.trainerComment {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 12)).foregroundColor(Brand.voltText).padding(.top, 2)
                        Text("Coach: “\(comment)”").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showAllLink {
                    Button { store.select(.photos) } label: {
                        DSListRow(title: "All progress photos", subtitle: "\(store.photos.count) photos", icon: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .card(padding: 16)
        }
    }
}


// MARK: - A pan that only begins for clearly sideways movement
// UIKit decides whether a pan begins from its first few points of movement. Refusing
// anything that isn't mostly horizontal hands the touch to the scroll view underneath,
// which a SwiftUI DragGesture can't do once it has claimed the touch.

struct HorizontalPan: UIViewRepresentable {
    /// Called with the touch's x as a fraction of the view's width.
    var onChanged: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.onChanged = onChanged }

    func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        init(onChanged: @escaping (CGFloat) -> Void) { self.onChanged = onChanged }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let v = pan.view else { return false }
            let t = pan.translation(in: v)
            return abs(t.x) > abs(t.y) * 2          // clearly sideways, or it isn't ours
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began, .changed: onChanged(g.location(in: v).x / max(v.bounds.width, 1))
            default: break
            }
        }
    }
}
