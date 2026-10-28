import SwiftUI

// MARK: - PR celebration
// Shown when a logged set earns a personal record that clears the throttle in
// ProgressEngine (main lift, meaningful gain, once per lift per week, not a typo).
// It offers — never forces — a photo share, and can be dismissed.
// Oct 28, 2026: the full treatment (confetti, glowing badge, success buzz) in your accent
// and light / dark mode, like Award unlocked (Celebration.swift).

struct PRCelebrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pr: PersonalRecord

    @State private var contentIn = false

    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5).padding(.top, 10)

            CelebrationBadge(size: 96, box: 200) {
                Image(systemName: "trophy.fill").font(.system(size: 42, weight: .bold))
            }

            VStack(spacing: 10) {
                Text(pr.isFirstEver ? "FIRST RECORD ON THE BOOKS" : "NEW PERSONAL RECORD")
                    .font(BrandFont.body(11, .bold)).tracking(3)
                    .foregroundColor(Brand.voltText)

                Text(pr.isFirstEver ? "First Record" : "New PR")
                    .font(BrandFont.display(40))
                    .foregroundColor(Brand.text)

                Text(pr.exercise.uppercased())
                    .font(BrandFont.body(12, .bold)).tracking(1.5)
                    .foregroundColor(Brand.voltText)

                Text("\(pr.reps) × \(Int(pr.weight)) lb")
                    .font(BrandFont.display(46))
                    .foregroundColor(Brand.voltText)

                VStack(spacing: 4) {
                    Text("\(Int(pr.estimatedOneRepMax)) lb estimated 1RM")
                        .font(BrandFont.body(14)).foregroundColor(Brand.text)
                    if !pr.isFirstEver {
                        Text("+\(Int(pr.gain)) lb on your previous best")
                            .font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                    }
                }
            }
            .opacity(contentIn ? 1 : 0)
            .offset(y: contentIn ? 0 : 14)

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Button {
                    // Hand off to Share with the PR already on the card.
                    store.activeTab = .share
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Share a photo").font(BrandFont.body(15, .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Brand.volt)
                    .clipShape(Capsule())
                    .foregroundColor(Brand.onVolt)
                }

                Button("Not now") { dismiss() }
                    .font(BrandFont.body(14))
                    .foregroundColor(Brand.mute)
                    .padding(.bottom, 8)
            }
            .opacity(contentIn ? 1 : 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Confetti behind everything, falling through the whole card.
            CelebrationConfetti(pieces: 80, loop: true).clipped()
        }
        .background(Brand.bg)
        .onAppear {
            if reduceMotion { contentIn = true; return }
            withAnimation(.easeOut(duration: 0.45).delay(0.3)) { contentIn = true }
        }
    }
}
