import SwiftUI

// MARK: - Awards (trophy case)
// Counts up top, the award you're closest to as a hero card, then every award
// grouped by kind: earned ones solid, the rest as outlines with progress where
// it can be counted. Tap any award for the details.

struct AwardsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Award?
    @State private var locked: LockedItem?

    struct LockedItem: Identifiable {
        let kind: AwardKind
        let current: Int?
        let goal: Int?
        var id: String { kind.rawValue }
        var fraction: Double? {
            guard let c = current, let g = goal, g > 0 else { return nil }
            return min(1, Double(c) / Double(g))
        }
    }

    private var earned: [Award] { store.awards.sorted { $0.earnedAt > $1.earnedAt } }
    private func earnedAward(_ k: AwardKind) -> Award? { store.awards.first { $0.kind == k } }

    /// Progress for every locked award we can count — the engine's, plus the strength
    /// and volume totals.
    private var lockedItems: [LockedItem] {
        let engine = AwardEngine.progress(workouts: store.workouts, supplementLogs: store.supplementLogs,
                                          earned: store.awards)
        var items: [AwardKind: LockedItem] = [:]
        for p in engine { items[p.kind] = LockedItem(kind: p.kind, current: p.current, goal: p.goal) }
        let earnedKinds = Set(store.awards.map { $0.kind })
        if !earnedKinds.contains(.thousandPoundClub) {
            let total = ProgressEngine.bestOneRepMax(for: "Back Squat", workouts: store.workouts)
                + ProgressEngine.bestOneRepMax(for: "Bench Press", workouts: store.workouts)
                + ProgressEngine.bestOneRepMax(for: "Deadlift", workouts: store.workouts)
            if total > 0 { items[.thousandPoundClub] = LockedItem(kind: .thousandPoundClub, current: Int(total), goal: 1000) }
        }
        if !earnedKinds.contains(.millionPounds) {
            let vol = store.workouts.filter { $0.completed }.flatMap { $0.exercises.flatMap { $0.sets } }
                .reduce(0.0) { $0 + $1.volume }
            if vol > 0 { items[.millionPounds] = LockedItem(kind: .millionPounds, current: Int(vol), goal: 1_000_000) }
        }
        for k in AwardKind.allCases where !earnedKinds.contains(k) && items[k] == nil {
            items[k] = LockedItem(kind: k, current: nil, goal: nil)
        }
        return Array(items.values)
    }

    private var closest: LockedItem? {
        lockedItems.filter { $0.fraction != nil && $0.kind.isShareable }.max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
    }

    private static let groups: [(String, [AwardKind])] = [
        ("CONSISTENCY", [.perfectWeek, .perfectMonth, .streak4, .streak12, .comeback, .doseStreak30]),
        ("VOLUME", [.workouts10, .workouts25, .workouts50, .workouts100, .workouts250, .millionPounds]),
        ("STRENGTH", [.firstPR, .upAcrossTheBoard, .tripleCrown, .thousandPoundClub]),
        ("EFFORT", [.fullSend])
    ]

    var body: some View {
        let lockedList = lockedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DSScreenHeader(eyebrow: "Trophy Case", title: "Awards", subtitle: "Earned once, kept forever.")
                    .staggeredAppear(0)

                HStack(spacing: 10) {
                    DSStatTile(value: "\(earned.count)", label: "WINS UNLOCKED", sub: "of \(AwardKind.allCases.count)")
                    DSStatTile(value: "\(lockedList.filter { ($0.fraction ?? 0) > 0 }.count)", label: "IN PROGRESS", color: Brand.text)
                    if let c = closest, let f = c.fraction {
                        DSStatTile(value: "\(Int((f * 100).rounded(.down)))%", label: "CLOSEST", sub: c.kind.title)
                    }
                }
                .staggeredAppear(1)

                if let c = closest { almostThere(c).staggeredAppear(2) }

                if let latest = earned.first {
                    Button { selected = latest } label: { latestCard(latest) }
                        .buttonStyle(PressableStyle())
                        .staggeredAppear(3)
                }

                ForEach(Array(Self.groups.enumerated()), id: \.offset) { gi, group in
                    VStack(alignment: .leading, spacing: 10) {
                        let have = group.1.filter { earnedAward($0) != nil }.count
                        DSSectionHeader(title: group.0, subtitle: "\(have) of \(group.1.count)")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(group.1) { kind in
                                if let a = earnedAward(kind) {
                                    Button { selected = a } label: { badge(kind, earned: a, item: nil) }
                                        .buttonStyle(PressableStyle())
                                } else {
                                    let item = lockedList.first { $0.kind == kind }
                                    Button { locked = item ?? LockedItem(kind: kind, current: nil, goal: nil) } label: {
                                        badge(kind, earned: nil, item: item)
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                        }
                    }
                    .staggeredAppear(4 + gi)
                }

                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).foregroundColor(Brand.voltText)
                    Text("Earned awards can go straight onto your Share card — tap one, then Share it.")
                        .font(BrandFont.body(12, .medium)).foregroundColor(Brand.text.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 40)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .sheet(item: $selected) { a in AwardDetailView(award: a) }
        .sheet(item: $locked) { item in
            LockedAwardSheet(item: item).presentationDetents([.medium])
        }
    }

    // MARK: Almost there

    private func almostThere(_ c: LockedItem) -> some View {
        let f = c.fraction ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: c.kind.icon).font(.system(size: 24, weight: .semibold)).foregroundColor(Brand.voltText)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(f >= 0.9 ? "SO CLOSE" : "ALMOST THERE").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                    Text(c.kind.title).font(BrandFont.body(18, .heavy)).foregroundColor(Brand.text)
                    Text(detail(c)).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            DSProgressBar(fraction: f, height: 10)
            HStack {
                Text(progressText(c)).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                Spacer()
                Text(toGo(c)).font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
            }
            Text(hype(f)).font(BrandFont.body(13, .semibold)).foregroundColor(Brand.voltText)
        }
        .padding(16)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
    }

    private func latestCard(_ a: Award) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.icon).font(.system(size: 20, weight: .bold)).foregroundColor(Brand.onVolt)
                .frame(width: 44, height: 44).background(Circle().fill(Brand.volt))
            VStack(alignment: .leading, spacing: 2) {
                Text("LATEST WIN · \(a.earnedAt.formatted(.dateTime.month(.abbreviated).day()).uppercased())")
                    .font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                Text("\(a.title) — \(a.kind.cheer)").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                Text(a.blurb).font(BrandFont.body(12)).foregroundColor(Brand.text.opacity(0.8)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .card(padding: 14)
    }

    // MARK: Badge

    private func badge(_ kind: AwardKind, earned: Award?, item: LockedItem?) -> some View {
        VStack(spacing: 7) {
            ZStack {
                if earned != nil {
                    Circle().fill(Brand.volt).frame(width: 56, height: 56)
                    Image(systemName: kind.icon).font(.system(size: 24, weight: .bold)).foregroundColor(Brand.onVolt)
                } else {
                    Circle().stroke(Brand.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 56, height: 56)
                    Image(systemName: kind.icon).font(.system(size: 22, weight: .semibold)).foregroundColor(Brand.mute)
                }
            }
            Text(kind.title).font(BrandFont.body(13, .heavy)).foregroundColor(earned != nil ? Brand.text : Brand.text.opacity(0.8))
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            if let a = earned {
                Text(kind.cheer).font(BrandFont.body(12, .heavy)).foregroundColor(Brand.voltText)
                    .multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.7)
                Text("Unlocked \(a.earnedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(BrandFont.body(10)).foregroundColor(Brand.mute)
            } else if let item, let f = item.fraction {
                Text(progressText(item)).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
                DSProgressBar(fraction: f, height: 5, color: Brand.mute)
            } else {
                Text(kind.howTo).font(BrandFont.body(10)).foregroundColor(Brand.mute)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.horizontal, 10).padding(.vertical, 14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(earned != nil ? Brand.voltLine.opacity(0.45) : Brand.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Text helpers

    private func progressText(_ c: LockedItem) -> String {
        guard let cur = c.current, let goal = c.goal else { return "" }
        switch c.kind {
        case .thousandPoundClub: return "\(cur.formatted()) of 1,000 lb"
        case .millionPounds: return "\(cur.formatted()) of 1,000,000 lb"
        case .streak4, .streak12: return "\(cur) of \(goal) weeks"
        case .doseStreak30: return "\(cur) of \(goal) days"
        default: return "\(cur) of \(goal)"
        }
    }

    private func toGo(_ c: LockedItem) -> String {
        guard let cur = c.current, let goal = c.goal else { return "" }
        let left = max(0, goal - cur)
        switch c.kind {
        case .thousandPoundClub, .millionPounds: return "\(left.formatted()) lb to go"
        case .streak4, .streak12: return "\(left) week\(left == 1 ? "" : "s") to go"
        default: return "\(left) to go"
        }
    }

    private func detail(_ c: LockedItem) -> String {
        if c.kind == .thousandPoundClub {
            let sq = Int(ProgressEngine.bestOneRepMax(for: "Back Squat", workouts: store.workouts))
            let bp = Int(ProgressEngine.bestOneRepMax(for: "Bench Press", workouts: store.workouts))
            let dl = Int(ProgressEngine.bestOneRepMax(for: "Deadlift", workouts: store.workouts))
            return "Squat \(sq) + Bench \(bp) + Deadlift \(dl) (estimated 1RMs)"
        }
        return c.kind.howTo
    }

    /// A little encouragement for the "almost there" card.
    private func hype(_ f: Double) -> String {
        switch f {
        case 0.9...: return "You can taste it — one more push."
        case 0.75...: return "The finish line's in sight. Keep going!"
        case 0.5...: return "Over halfway there. Keep stacking wins."
        default: return "Every session moves the needle."
        }
    }
}

// MARK: - A locked award: what it is and how far along you are

struct LockedAwardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: AwardsView.LockedItem

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5).padding(.top, 10)
            ZStack {
                Circle().stroke(Brand.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).frame(width: 96, height: 96)
                Image(systemName: item.kind.icon).font(.system(size: 38, weight: .semibold)).foregroundColor(Brand.mute)
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 26, height: 26).background(Circle().fill(Brand.volt))
                    .offset(x: 34, y: 34)
            }
            .padding(.top, 8)
            Text(item.kind.title).font(BrandFont.display(32)).foregroundColor(Brand.text)
            Text("HOW TO UNLOCK").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
            Text(item.kind.howTo).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            if let f = item.fraction, let cur = item.current, let goal = item.goal {
                VStack(spacing: 6) {
                    DSProgressBar(fraction: f, height: 8)
                    Text("\(cur.formatted()) of \(goal.formatted())").font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
                }
                .padding(.horizontal, 40)
            }
            if !item.kind.isShareable {
                Text("This one stays between you and your coach.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            Spacer()
            Button("Close") { dismiss() }.font(BrandFont.body(14)).foregroundColor(Brand.mute).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Brand.bg.ignoresSafeArea())
    }
}

// Tapping an earned award — the moment again, plus the option to share it.
struct AwardDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let award: Award

    @State private var appear = false
    @State private var ringPulse = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5).padding(.top, 10)

            Spacer(minLength: 8)

            // ---- Radiant hero: the icon sits in a burst of concentric rings ----
            ZStack {
                // Ambient glow behind everything
                Circle()
                    .fill(Brand.volt)
                    .frame(width: 230, height: 230)
                    .blur(radius: 70)
                    .opacity(0.28)

                // Concentric rings that gently breathe
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Brand.voltLine.opacity(0.18 - Double(i) * 0.05), lineWidth: 1.5)
                        .frame(width: 150 + CGFloat(i) * 46, height: 150 + CGFloat(i) * 46)
                        .scaleEffect(ringPulse ? 1.04 : 0.98)
                        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3), value: ringPulse)
                }

                // Radiating spokes for a burst / medallion feel
                ForEach(0..<12) { i in
                    Capsule()
                        .fill(Brand.volt.opacity(0.5))
                        .frame(width: 2.5, height: 12)
                        .offset(y: -104)
                        .rotationEffect(.degrees(Double(i) / 12 * 360))
                        .opacity(appear ? 1 : 0)
                        .scaleEffect(appear ? 1 : 0.3)
                        .animation(.spring(response: 0.6, dampingFraction: 0.6)
                            .delay(0.15 + Double(i) * 0.02), value: appear)
                }

                // The medallion
                Circle()
                    .fill(Brand.volt)
                    .frame(width: 128, height: 128)
                    .overlay(
                        Image(systemName: award.icon)
                            .font(.system(size: 56, weight: .bold))
                            .foregroundColor(Brand.onVolt)
                    )
                    .shadow(color: Brand.volt.opacity(0.5), radius: 24)
                    .scaleEffect(appear ? 1 : 0.5)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appear)
            }
            .frame(height: 260)

            // ---- Title + blurb ----
            Text(award.kind.cheer.uppercased())
                .font(BrandFont.body(12, .heavy)).tracking(2).headerPill()
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.2), value: appear)
            Text(award.title)
                .font(BrandFont.display(40)).foregroundColor(Brand.text)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)
                .animation(.easeOut(duration: 0.4).delay(0.25), value: appear)

            Text(award.blurb)
                .font(BrandFont.body(15)).foregroundColor(Brand.mute)
                .multilineTextAlignment(.center).padding(.horizontal, 36)
                .padding(.top, 8)
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.32), value: appear)

            // ---- Stat cards: bold, filling, one card each ----
            HStack(spacing: 10) {
                ForEach(Array(award.stats.enumerated()), id: \.element.id) { i, s in
                    VStack(spacing: 4) {
                        Text(s.value)
                            .font(BrandFont.display(30)).foregroundColor(Brand.voltText)
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(s.label)
                            .font(BrandFont.body(9, .bold)).tracking(1.3)
                            .foregroundColor(Brand.mute)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7)
                        .delay(0.4 + Double(i) * 0.08), value: appear)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            // ---- Earned date, as a quiet pill ----
            Text("UNLOCKED \(award.earnedAt.formatted(date: .abbreviated, time: .omitted).uppercased())")
                .font(BrandFont.body(10, .bold)).tracking(1.5)
                .foregroundColor(Brand.mute)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                .padding(.top, 18)
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.55), value: appear)

            Spacer(minLength: 12)

            // ---- Actions ----
            if award.isShareable {
                Button {
                    store.awardToShare = award
                    store.activeTab = .share
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Show it off").font(BrandFont.body(15, .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Brand.volt).foregroundColor(Brand.onVolt).clipShape(Capsule())
                }
                .padding(.horizontal, 24)
            } else {
                Text("This one stays between you and your coach.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .padding(.bottom, 8)
            }

            Button("Close") { dismiss() }
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                .padding(.top, 12).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // A subtle vertical wash so the hero glow has somewhere to fall off into.
            LinearGradient(colors: [Brand.volt.opacity(0.06), Brand.bg, Brand.bg],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .onAppear { appear = true; ringPulse = true }
    }
}
