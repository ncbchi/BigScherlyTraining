import SwiftUI

// MARK: - PR celebration
// Shown when a logged set earns a personal record that clears the throttle in
// ProgressEngine (main lift, meaningful gain, once per lift per week, not a typo).
// It offers — never forces — a photo share, and can be dismissed.

struct PRCelebrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let pr: PersonalRecord

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5).padding(.top, 10)

            Image(systemName: "trophy.fill")
                .font(.system(size: 44))
                .foregroundColor(Brand.volt)
                .padding(.top, 6)

            Text(pr.isFirstEver ? "First Record" : "New PR")
                .font(BrandFont.display(38))
                .foregroundColor(.white)

            Text(pr.exercise.uppercased())
                .font(BrandFont.body(12, .bold)).tracking(1.5)
                .foregroundColor(Brand.volt)

            Text("\(pr.reps) × \(Int(pr.weight)) lb")
                .font(BrandFont.display(46))
                .foregroundColor(Brand.volt)

            VStack(spacing: 4) {
                Text("\(Int(pr.estimatedOneRepMax)) lb estimated 1RM")
                    .font(BrandFont.body(14)).foregroundColor(.white)
                if !pr.isFirstEver {
                    Text("+\(Int(pr.gain)) lb on your previous best")
                        .font(BrandFont.body(13, .bold)).foregroundColor(Brand.volt)
                }
            }

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
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .foregroundColor(Brand.black)
                }

                Button("Not now") { dismiss() }
                    .font(BrandFont.body(14))
                    .foregroundColor(Brand.mute)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
    }
}
