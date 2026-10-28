import SwiftUI

// MARK: - Award celebration
// A full-screen moment, not a banner. Badge springs in with an overshoot, rings pulse,
// rays turn slowly, confetti falls. Honours Reduce Motion (no confetti/rays, simple fade).
// Oct 28, 2026: your accent and light / dark mode (was always yellow on dark). The badge
// and confetti are shared with New PR and Check-in complete (Celebration.swift).

struct AwardCelebrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let award: Award

    @State private var contentIn = false

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            CelebrationConfetti(pieces: 160, loop: true)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                CelebrationBadge(size: 128, box: 260) {
                    Image(systemName: award.icon).font(.system(size: 56, weight: .bold))
                }
                .frame(height: 260)

                Text("AWARD UNLOCKED · \(award.kind.cheer.uppercased())")
                    .font(BrandFont.body(11, .bold)).tracking(3)
                    .foregroundColor(Brand.voltText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .opacity(contentIn ? 1 : 0)
                    .offset(y: contentIn ? 0 : 16)

                Text(award.title)
                    .font(BrandFont.display(44))
                    .foregroundColor(Brand.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.horizontal, 24)
                    .opacity(contentIn ? 1 : 0)
                    .offset(y: contentIn ? 0 : 16)

                Text(award.blurb)
                    .font(BrandFont.body(14))
                    .foregroundColor(Brand.mute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
                    .opacity(contentIn ? 1 : 0)
                    .offset(y: contentIn ? 0 : 16)

                // Proof — the concrete numbers behind the award, as bold cards.
                HStack(spacing: 10) {
                    ForEach(Array(award.stats.enumerated()), id: \.element.id) { _, s in
                        VStack(spacing: 4) {
                            Text(s.value)
                                .font(BrandFont.display(28)).foregroundColor(Brand.voltText)
                                .minimumScaleFactor(0.5).lineLimit(1)
                            Text(s.label)
                                .font(BrandFont.body(9, .bold)).tracking(1.3)
                                .foregroundColor(Brand.mute)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Brand.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .opacity(contentIn ? 1 : 0)
                .offset(y: contentIn ? 0 : 16)

                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    // Non-shareable awards (dose streak) get a private acknowledgement
                    // instead of a share button — see the privacy rule in Awards.swift.
                    if award.isShareable {
                        Button {
                            store.awardToShare = award
                            store.activeTab = .share
                            dismiss()
                        } label: {
                            primaryLabel("Show it off", icon: "camera.fill")
                        }
                    } else {
                        Button {
                            store.activeTab = .awards
                            dismiss()
                        } label: {
                            primaryLabel("View awards", icon: "trophy.fill")
                        }
                    }

                    Button("Not now") { dismiss() }
                        .font(BrandFont.body(14))
                        .foregroundColor(Brand.mute)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
                .opacity(contentIn ? 1 : 0)
            }
        }
        .onAppear {
            if reduceMotion { contentIn = true; return }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) { contentIn = true }
        }
    }

    private func primaryLabel(_ text: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).font(BrandFont.body(15, .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Brand.volt)
        .clipShape(Capsule())
        .foregroundColor(Brand.onVolt)
    }
}
