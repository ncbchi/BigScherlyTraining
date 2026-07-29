import SwiftUI

// MARK: - Award celebration
// A full-screen moment, not a banner. Badge springs in with an overshoot, rings pulse,
// rays turn slowly, confetti falls. Honours Reduce Motion (no confetti/rays, simple fade).

struct AwardCelebrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let award: Award

    @State private var badgeIn = false
    @State private var contentIn = false
    @State private var ringPulse = false
    @State private var rayAngle: Double = 0

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            if !reduceMotion {
                ConfettiLayer()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                // Badge + rays + pulsing rings
                ZStack {
                    // Ambient glow
                    Circle()
                        .fill(Brand.volt)
                        .frame(width: 230, height: 230)
                        .blur(radius: 70)
                        .opacity(0.28)

                    if !reduceMotion {
                        // Expanding shockwave rings (the celebratory pulse)
                        ForEach(0..<2, id: \.self) { i in
                            Circle()
                                .stroke(Brand.volt, lineWidth: 2)
                                .frame(width: 120, height: 120)
                                .scaleEffect(ringPulse ? 2.0 : 0.7)
                                .opacity(ringPulse ? 0 : 0.55)
                                .animation(
                                    .easeOut(duration: 2.4)
                                        .repeatForever(autoreverses: false)
                                        .delay(Double(i) * 1.2),
                                    value: ringPulse)
                        }

                        // Slowly turning sunburst
                        RaysView()
                            .stroke(Brand.volt.opacity(0.35), lineWidth: 2.5)
                            .frame(width: 250, height: 250)
                            .rotationEffect(.degrees(rayAngle))

                        // Static concentric rings for depth
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .stroke(Brand.volt.opacity(0.16 - Double(i) * 0.045), lineWidth: 1.5)
                                .frame(width: 150 + CGFloat(i) * 46, height: 150 + CGFloat(i) * 46)
                        }
                    }

                    Circle()
                        .fill(Brand.volt)
                        .frame(width: 128, height: 128)
                        .overlay(
                            Image(systemName: award.icon)
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(Brand.black)
                        )
                        .shadow(color: Brand.volt.opacity(0.5), radius: 24)
                        .scaleEffect(badgeIn ? 1 : 0.01)
                        .rotationEffect(.degrees(badgeIn ? 0 : -25))
                }
                .frame(height: 260)

                Text("AWARD UNLOCKED")
                    .font(BrandFont.body(11, .bold)).tracking(3)
                    .foregroundColor(Brand.volt)
                    .padding(.bottom, 10)
                    .opacity(contentIn ? 1 : 0)
                    .offset(y: contentIn ? 0 : 16)

                Text(award.title)
                    .font(BrandFont.display(44))
                    .foregroundColor(.white)
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
                    ForEach(Array(award.stats.enumerated()), id: \.element.id) { i, s in
                        VStack(spacing: 4) {
                            Text(s.value)
                                .font(BrandFont.display(28)).foregroundColor(Brand.volt)
                                .minimumScaleFactor(0.5).lineLimit(1)
                            Text(s.label)
                                .font(BrandFont.body(9, .bold)).tracking(1.3)
                                .foregroundColor(Brand.mute)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Brand.black)
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
                            HStack {
                                Image(systemName: "camera.fill")
                                Text("Share it").font(BrandFont.body(15, .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Brand.volt)
                            .clipShape(Capsule())
                            .foregroundColor(Brand.black)
                        }
                    } else {
                        Button {
                            store.activeTab = .awards
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "trophy.fill")
                                Text("View awards").font(BrandFont.body(15, .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Brand.volt)
                            .clipShape(Capsule())
                            .foregroundColor(Brand.black)
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
            if reduceMotion {
                badgeIn = true; contentIn = true
                return
            }
            // Overshoot-and-settle: the pop is most of why this feels good.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) { badgeIn = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) { contentIn = true }
            ringPulse = true
            withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
                rayAngle = 360
            }
            // Haptic timed to the badge landing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

// Sunburst behind the badge.
private struct RaysView: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let inner = rect.width * 0.30
        let outer = rect.width * 0.50
        for i in 0..<12 {
            let a = Double(i) * (.pi * 2 / 12)
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
        }
        return p
    }
}

// Falling confetti — plenty of it.
private struct ConfettiLayer: View {
    // A proper storm. Rectangles are cheap to draw, so this stays smooth on device.
    private let pieces = 160

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<pieces, id: \.self) { i in
                    ConfettiPiece(index: i, size: geo.size)
                }
            }
        }
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let size: CGSize
    @State private var fall = false

    // Deterministic per-piece values so nothing re-randomises on redraw.
    private var seed: Double { Double((index &* 2654435761) % 1000) / 1000 }
    private var seed2: Double { Double((index &* 40503) % 997) / 997 }
    private var x: CGFloat { CGFloat(seed) * size.width }
    private var delay: Double { seed2 * 1.6 }
    private var duration: Double { 2.0 + seed * 1.6 }
    private var drift: CGFloat { CGFloat(seed2 - 0.5) * 90 }
    private var w: CGFloat { 5 + CGFloat(seed2) * 4 }
    private var h: CGFloat { 9 + CGFloat(seed) * 7 }
    private var color: Color {
        switch index % 3 {
        case 0:  return Brand.volt
        case 1:  return .white
        default: return Brand.volt.opacity(0.75)
        }
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: w, height: h)
            .position(x: fall ? x + drift : x, y: fall ? size.height + 60 : -60)
            .rotationEffect(.degrees(fall ? 540 + seed * 360 : 0))
            .opacity(fall ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: duration)
                    .repeatForever(autoreverses: false)
                    .delay(delay)) {
                        fall = true
                    }
            }
    }
}
