import SwiftUI
import UIKit

// MARK: - Celebrations, shared pieces (Oct 28, 2026)
// Award unlocked, New PR and Check-in complete all use these: falling confetti and a
// glowing accent badge with pulsing rings and slowly turning rays. Everything follows the
// accent you picked and light / dark mode (Brand.*). Reduce Motion: no confetti, rays or
// pulse; the badge simply appears.

/// Falling confetti in your accent and the text colour. `loop` keeps it falling (award);
/// otherwise each piece falls once (PR sheet, check-in).
struct CelebrationConfetti: View {
    var pieces = 160
    var loop = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<pieces, id: \.self) { i in
                        CelebrationConfettiPiece(index: i, size: geo.size, loop: loop)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CelebrationConfettiPiece: View {
    let index: Int
    let size: CGSize
    let loop: Bool
    @State private var fall = false

    // Deterministic per piece, so nothing re-randomises on a redraw.
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
        case 1:  return Brand.text.opacity(0.75)
        default: return Brand.volt.opacity(0.7)
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
                let a = Animation.easeIn(duration: duration).delay(delay)
                withAnimation(loop ? a.repeatForever(autoreverses: false) : a) { fall = true }
            }
    }
}

/// The glowing accent badge: ambient glow, two expanding shockwave rings, a slowly turning
/// sunburst and three still rings, with the icon on a solid accent circle that springs in.
/// Plays the success haptic as it lands.
struct CelebrationBadge<Icon: View>: View {
    var size: CGFloat = 128              // the solid circle
    var box: CGFloat = 260               // the whole thing, rays included
    var haptic = true
    @ViewBuilder var icon: () -> Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var badgeIn = false
    @State private var ringPulse = false
    @State private var rayAngle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.volt)
                .frame(width: box * 0.88, height: box * 0.88)
                .blur(radius: box * 0.27)
                .opacity(scheme == .dark ? 0.28 : 0.22)

            if !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(Brand.volt, lineWidth: 2)
                        .frame(width: size * 0.94, height: size * 0.94)
                        .scaleEffect(ringPulse ? 2.0 : 0.7)
                        .opacity(ringPulse ? 0 : 0.55)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 1.2),
                                   value: ringPulse)
                }
                CelebrationRays()
                    .stroke(Brand.volt.opacity(0.4), lineWidth: 2.5)
                    .frame(width: box * 0.96, height: box * 0.96)
                    .rotationEffect(.degrees(rayAngle))
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Brand.volt.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                        .frame(width: size * 1.17 + CGFloat(i) * size * 0.36,
                               height: size * 1.17 + CGFloat(i) * size * 0.36)
                }
            }

            Circle()
                .fill(Brand.volt)
                .frame(width: size, height: size)
                .overlay(icon().foregroundColor(Brand.onVolt))
                .shadow(color: Brand.volt.opacity(0.5), radius: 24)
                .scaleEffect(badgeIn ? 1 : 0.01)
                .rotationEffect(.degrees(badgeIn ? 0 : -25))
        }
        .frame(width: box, height: box)
        .onAppear {
            if reduceMotion { badgeIn = true; return }
            // Overshoot-and-settle: the pop is most of why this feels good.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) { badgeIn = true }
            ringPulse = true
            withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) { rayAngle = 360 }
            if haptic {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }
}

/// Sunburst behind the badge.
struct CelebrationRays: Shape {
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
