import SwiftUI

// MARK: - Awards (trophy case)
// Earned awards up top, then what's closest to being earned next.

struct AwardsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Award?

    private var earned: [Award] { store.awards.sorted { $0.earnedAt > $1.earnedAt } }
    private var progress: [AwardProgress] {
        AwardEngine.progress(workouts: store.workouts,
                             supplementLogs: store.supplementLogs,
                             earned: store.awards)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Earn Your Stripes")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Awards").font(BrandFont.display(48)).foregroundColor(.white)
                    Text("\(earned.count) of \(AwardKind.allCases.count)")
                        .font(BrandFont.body(13, .bold)).foregroundColor(Brand.volt)
                }
                Text("Milestones you've actually earned — from the work you logged.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                if earned.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "trophy")
                            .font(.system(size: 40)).foregroundColor(Brand.line)
                        Text("No awards yet")
                            .font(BrandFont.body(15, .bold)).foregroundColor(.white)
                        Text("Finish your first workouts and they'll start landing here.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }

                // ---- Earned ----
                if !earned.isEmpty {
                    let cols = [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(earned) { a in
                            Button { selected = a } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: a.icon)
                                        .font(.system(size: 22))
                                        .foregroundColor(Brand.volt)
                                    Text(a.title)
                                        .font(BrandFont.body(10, .semibold))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))
                            }
                        }
                    }
                }

                // ---- Next up ----
                if !progress.isEmpty {
                    Text("NEXT UP").font(BrandFont.body(12, .bold))
                        .tracking(1.5).foregroundColor(Brand.volt)
                        .padding(.top, 14)

                    VStack(spacing: 14) {
                        ForEach(progress.prefix(4)) { p in
                            VStack(spacing: 6) {
                                HStack {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 11)).foregroundColor(Brand.mute)
                                    Text(p.kind.title)
                                        .font(BrandFont.body(13, .semibold)).foregroundColor(.white)
                                    Spacer()
                                    Text("\(p.current) / \(p.goal)")
                                        .font(BrandFont.body(12, .bold)).foregroundColor(Brand.volt)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(Brand.line).frame(height: 4)
                                        Rectangle().fill(Brand.volt)
                                            .frame(width: geo.size.width * p.fraction, height: 4)
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                    .padding(16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 40)
        }
        .background(Brand.bg.ignoresSafeArea())
        .sheet(item: $selected) { a in
            AwardDetailView(award: a)
        }
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
                        .stroke(Brand.volt.opacity(0.18 - Double(i) * 0.05), lineWidth: 1.5)
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
                            .foregroundColor(Brand.black)
                    )
                    .shadow(color: Brand.volt.opacity(0.5), radius: 24)
                    .scaleEffect(appear ? 1 : 0.5)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appear)
            }
            .frame(height: 260)

            // ---- Title + blurb ----
            Text(award.title)
                .font(BrandFont.display(40)).foregroundColor(.white)
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
                            .font(BrandFont.display(30)).foregroundColor(Brand.volt)
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
            Text("EARNED \(award.earnedAt.formatted(date: .abbreviated, time: .omitted).uppercased())")
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
                        Text("Share it").font(BrandFont.body(15, .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Brand.volt).foregroundColor(Brand.black).clipShape(Capsule())
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
