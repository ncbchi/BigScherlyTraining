import SwiftUI

// MARK: - Animated Splash / Loading Screen
// Black background, animated logo lockup, then hands off to login.
// Built so it's visible even if the logo image asset isn't present (text fallback).
struct SplashView: View {
    var onFinished: () -> Void

    @State private var appear = false
    @State private var shimmerX: CGFloat = -1.3
    @State private var glowPulse = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity = 0.0
    @State private var barFill: CGFloat = 0
    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Circle()
                .stroke(BrandDark.volt.opacity(ringOpacity), lineWidth: 3)
                .frame(width: 240, height: 240)
                .scaleEffect(ringScale)

            VStack(spacing: 36) {
                logoBlock
                    .scaleEffect(appear ? 1 : 0.7)
                    .opacity(appear ? 1 : 0)
                    .shadow(color: BrandDark.volt.opacity(glowPulse ? 0.7 : 0.2),
                            radius: glowPulse ? 30 : 8)

                ZStack(alignment: .leading) {
                    Capsule().fill(BrandDark.line).frame(width: 180, height: 5)
                    Capsule().fill(BrandDark.volt).frame(width: 180 * barFill, height: 5)
                }
                .opacity(appear ? 1 : 0)
            }
        }
        .onAppear { run() }
    }

    private var logoBlock: some View {
        Group {
            if UIImage(named: "logoVolt") != nil {
                Image("logoVolt").resizable().scaledToFit()
                    .frame(maxWidth: 300)
                    .overlay(shimmerBand.mask(Image("logoVolt").resizable().scaledToFit().frame(maxWidth: 300)))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(BrandDark.volt)
                        .rotationEffect(.degrees(spin ? 0 : -12))
                    Text("BIG SCHERLY")
                        .font(BrandFont.display(38)).foregroundColor(BrandDark.volt)
                    Text("TRAINING")
                        .font(BrandFont.display(38)).foregroundColor(.white)
                        .overlay(shimmerBand.mask(Text("TRAINING").font(BrandFont.display(38))))
                }
            }
        }
    }

    private var shimmerBand: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.4)
                .offset(x: geo.size.width * shimmerX)
                .blendMode(.screen)
        }
    }

    private func run() {
        withAnimation(.spring(response: 0.8, dampingFraction: 0.55)) { appear = true; spin = true }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { glowPulse = true }

        ringOpacity = 0.6
        withAnimation(.easeOut(duration: 1.3)) { ringScale = 1.6; ringOpacity = 0 }

        withAnimation(.easeInOut(duration: 1.3).delay(0.3)) { shimmerX = 1.3 }
        withAnimation(.easeInOut(duration: 2.2)) { barFill = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            onFinished()
        }
    }
}
