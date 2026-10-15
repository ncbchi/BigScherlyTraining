import SwiftUI
import Combine

// MARK: - The login page's colours
// The splash and the login page are always dark. Both use your accent, made readable on black
// (Settings ▸ Appearance; it stays on this phone after you sign out). A phone that's never had a
// sign-in has no accent saved, so it's Volt.
enum LoginLook {
    @MainActor static func palette() -> Palette {
        Palette.make(scheme: .dark, accent: ThemeStore.shared.accent, trueBlack: true, highContrast: false)
    }
}

// MARK: - Logo hand-off (splash → login)
// The login page reports where its logo sits. At the end of the splash the splash's logo glides and
// shrinks into exactly that spot while the fields fade in, then the login page's own logo takes over.
// Already signed in (no login page under the splash): the splash just fades, as before.
@MainActor
final class LogoDock: ObservableObject {
    static let shared = LogoDock()
    enum Phase { case splash, docking, done }
    @Published var phase: Phase = .splash
    /// The login logo's frame on screen, while the login page is up.
    var target: CGRect = .zero
    var loginUp = false
}

// MARK: - Animated Splash / Loading Screen
// Black background, animated logo lockup, then hands off to login.
// Built so it's visible even if the logo image asset isn't present (text fallback).
struct SplashView: View {
    var onFinished: () -> Void

    @ObservedObject private var dock = LogoDock.shared
    @State private var appear = false
    @State private var shimmerX: CGFloat = -1.3
    @State private var glowPulse = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity = 0.0
    @State private var barFill: CGFloat = 0
    @State private var spin = false

    // The hand-off
    @State private var logoFrame: CGRect = .zero      // the splash logo on screen
    @State private var docking = false
    @State private var dockOffset: CGSize = .zero
    @State private var dockScale: CGFloat = 1

    private var accent: Color { LoginLook.palette().accentText }

    var body: some View {
        ZStack {
            Color.black.opacity(docking ? 0 : 1).ignoresSafeArea()

            Circle()
                .stroke(accent.opacity(ringOpacity), lineWidth: 3)
                .frame(width: 240, height: 240)
                .scaleEffect(ringScale)

            VStack(spacing: 36) {
                logoBlock
                    .scaleEffect(appear ? 1 : 0.7)
                    .opacity(appear ? 1 : 0)
                    .shadow(color: accent.opacity(docking ? 0 : (glowPulse ? 0.7 : 0.2)),
                            radius: glowPulse ? 30 : 8)
                    .scaleEffect(dockScale)
                    .offset(dockOffset)

                ZStack(alignment: .leading) {
                    Capsule().fill(BrandDark.line).frame(width: 180, height: 5)
                    Capsule().fill(accent).frame(width: 180 * barFill, height: 5)
                }
                .opacity(appear && !docking ? 1 : 0)
            }
        }
        .allowsHitTesting(!docking)
        .onAppear { run() }
    }

    private var logoBlock: some View {
        Group {
            if UIImage(named: "logoVolt") != nil {
                // The logo is one colour on transparent, so it takes your accent cleanly.
                Image("logoVolt").renderingMode(.template).resizable().scaledToFit()
                    .foregroundColor(accent)
                    .frame(maxWidth: 300)
                    .overlay(shimmerBand.mask(Image("logoVolt").resizable().scaledToFit().frame(maxWidth: 300)))
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { logoFrame = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in if !docking { logoFrame = f } }
                    })
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(accent)
                        .rotationEffect(.degrees(spin ? 0 : -12))
                    Text("BIG SCHERLY")
                        .font(BrandFont.display(38)).foregroundColor(accent)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { handOff() }
    }

    /// Glide into the login page's logo, or (signed in already) just fade.
    private func handOff() {
        let t = dock.target, s = logoFrame
        guard dock.loginUp, t.height > 1, s.height > 1 else {
            dock.phase = .done
            onFinished()
            return
        }
        let move = 0.75
        withAnimation(.spring(response: move, dampingFraction: 0.86)) {
            docking = true
            dockScale = t.height / s.height
            dockOffset = CGSize(width: t.midX - s.midX, height: t.midY - s.midY)
            dock.phase = .docking                         // the login fields fade in under it
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + move + 0.05) {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { dock.phase = .done }    // the login page's own logo, in the same spot
            onFinished()
        }
    }
}
