import SwiftUI
import UIKit
import Combine

// MARK: - Login Screen
struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var showError = false
    /// "Forgot password?" or "Email me a code" (Oct 10, 2026): both open EmailCodeSheet.
    @State private var codeSheet: EmailCodeSheet.Mode?
    /// 2-step sign-in (server 2.4.0): set when this phone needs an emailed code after the password.
    @State private var mfa: MfaChallenge?
    /// The splash's logo glides into this page's logo at launch (SplashView ▸ LogoDock).
    @ObservedObject private var dock = LogoDock.shared
    @ObservedObject private var theme = ThemeStore.shared
    /// Your accent, readable on black (Volt on a phone that's never had a sign-in).
    private var accent: Color { _ = theme.accent; return LoginLook.palette().accentText }
    /// The fields wait for the logo to land.
    private var shown: Bool { dock.phase != .splash }

    var body: some View {
        ZStack {
            BrandDark.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // The logo alone, in your accent (the login page always stays dark). At launch it's
                // hidden until the splash's logo has glided into this exact spot.
                Image("logoVolt").renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundColor(accent)
                    .frame(height: 150)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { dock.target = g.frame(in: .global); dock.loginUp = true }
                            .onChange(of: g.frame(in: .global)) { _, f in dock.target = f }
                    })
                    .opacity(dock.phase == .done ? 1 : 0)
                    .padding(.bottom, 44)

                VStack(spacing: 14) {
                    styledField("Email", text: $email, secure: false)
                    styledField("Password", text: $password, secure: true)
                    if showError {
                        Text("Check your email and password.")
                            .font(BrandFont.body(13)).foregroundColor(BrandDark.danger)
                    }
                    VoltButton(title: "Log In") {
                        // Both fields empty → offline demo account (App Store review). No network call.
                        if email.trimmingCharacters(in: .whitespaces).isEmpty && password.isEmpty {
                            store.enterDemo()
                            return
                        }
                        if APIConfig.useMock {
                            store.login()          // prototype: any input logs in
                        } else {
                            Task {
                                do {
                                    let outcome = try await APIClient.shared.login(email: email, password: password)
                                    await MainActor.run {
                                        switch outcome {
                                        case .signedIn(let resp): finishLogin(resp, email: email, viaCode: false)
                                        case .needsCode(let ch): mfa = ch
                                        }
                                    }
                                } catch {
                                    await MainActor.run { showError = true }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)

                    // Emailed 6-digit codes: sign in without the password, or reset it.
                    HStack(spacing: 18) {
                        Button("Email me a code") { showError = false; codeSheet = .signIn }
                            .foregroundColor(accent)
                        Text("·").foregroundColor(BrandDark.mute)
                        Button("Forgot password?") { showError = false; codeSheet = .reset }
                            .foregroundColor(BrandDark.mute)
                    }
                    .font(BrandFont.body(14, .semibold))
                    .padding(.top, 2)
                }
                .padding(.horizontal, 32)
                // iPad (Oct 9, 2026): the fields and button sit in a centred column, not edge to edge.
                .frame(maxWidth: 440)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)

                Spacer()

                // Small, unobtrusive demo entry pinned at the bottom. App Review
                // needs a credential-free way into a login-gated app (Guideline 2.1);
                // this keeps it discoverable without competing with the real login.
                // The leave-both-fields-empty path still works as a fallback.
                Button {
                    store.enterDemo()
                } label: {
                    Text("Demo Mode")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundColor(accent)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
                }
                .padding(.bottom, 14)
                .opacity(shown ? 1 : 0)

                Text("LGBTQ+ owned · Since 2024")
                    .font(BrandFont.body(11, .semibold))
                    .tracking(2).foregroundColor(BrandDark.mute)
                    .padding(.bottom, 20)
                    .opacity(shown ? 1 : 0)
            }
        }
        .onDisappear { dock.loginUp = false }
        .tapToDismissKeyboard()
        .sheet(item: $mfa) { ch in
            MfaCodeSheet(challenge: ch) { resp in
                finishLogin(resp, email: email, viaCode: false)
            }
        }
        .sheet(item: $codeSheet) { mode in
            EmailCodeSheet(mode: mode, startEmail: email) { resp, signedInEmail in
                email = signedInEmail
                finishLogin(resp, email: signedInEmail, viaCode: true)
            }
        }
    }

    /// Everything after the server says yes — shared by the password login and the
    /// emailed-code sheet, so both land in exactly the same state.
    @MainActor
    private func finishLogin(_ resp: LoginResponse, email: String, viaCode: Bool) {
        LoginFinish.apply(resp, email: email, viaCode: viaCode, store: store)   // AccountSetupLink.swift
    }

    @ViewBuilder
    func styledField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField("", text: text) } else { TextField("", text: text) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundColor(.white)
        .padding(15)
        .background(BrandDark.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).stroke(BrandDark.line, lineWidth: 1)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).foregroundColor(BrandDark.mute)
                        .padding(.leading, 16).allowsHitTesting(false)
                }
            }
        )
    }
}

// MARK: - Post-login welcome board (Entry B, Oct 9 2026)
// The original headline stack over your accent's bumper plate, turning slowly off the
// top-right, and a slide-to-enter bar in the same gold as the QUEENS outline.
// Follows your theme (Dark · Light · System · Custom). In light, a pale accent (Volt,
// Toxic, Amber…) can't draw lines on the light ground, so the rings go grey and the
// accent shows only as fills — the same rule as Coach HQ.
struct WelcomeBoardView: View {
    // QUEENS and the gold bar's sheen follow the phone's tilt. Held, not observed: only those
    // two small views redraw on each tilt tick, never the whole board (or the slider under your thumb).
    @State private var motion = MotionManager()
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    @Binding var showBoard: Bool

    private var p: Palette { theme.palette(for: scheme) }
    private var light: Bool { p.scheme == .light }
    private var ground: Color { light ? p.bg : BrandDark.black }
    private var ink: Color { light ? p.text : .white }
    /// A pale accent nearly vanishes on the light ground: there it fills, never draws lines.
    private var paleOnLight: Bool {
        light && RGBColor(hex: theme.accent).contrast(RGBColor(hex: 0xF2F2F4)) < 3
    }
    private var lineColor: Color { paleOnLight ? Color(hex: 0x8E8E93) : (light ? p.accent : p.accentText) }

    var body: some View {
        ZStack {
            ground.ignoresSafeArea()

            PlateRings(line: lineColor, fill: p.accent, light: light, pale: paleOnLight)
                .allowsHitTesting(false)

            // Fade the plate out behind the words and the bar
            LinearGradient(stops: [.init(color: ground.opacity(0), location: 0.45),
                                   .init(color: ground, location: 0.72)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Overlay headline — left aligned, fills the width, alternating
            // filled / outlined like the website. Each word auto-shrinks to fit one line.
            VStack(alignment: .leading, spacing: -4) {
                Spacer()
                filledWord("LET'S")
                outlinedWord("GET", color: ink)
                filledWord("BIG")
                outlinedWord("TOGETHER", color: paleOnLight ? ink : lineColor)
                MetallicRainbowText(text: "QUEENS", size: 140, fillWidth: true, motion: motion)
                    // On the light ground a hairline of deep gold keeps the rim's pale highlights edged.
                    .shadow(color: light ? Color(hex: 0x6B4E12).opacity(0.55) : .clear, radius: 0.6)
                Spacer()
                GoldSlideToEnter(light: light, motion: motion) {
                    withAnimation { showBoard = false }
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    // Big, heavy, one line each — shrinks to fit width so TOGETHER never wraps.
    private let headlineSize: CGFloat = 96

    func filledWord(_ w: String) -> some View {
        Text(w)
            .font(BrandFont.welcome(headlineSize))
            .foregroundColor(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    func outlinedWord(_ w: String, color: Color) -> some View {
        StrokeText(text: w, size: headlineSize, color: color)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The plate behind the board
// A bumper plate drawn in hairlines, bleeding off the top-right and turning once every two
// minutes (still when Reduce Motion is on). Laid out for a 390-wide phone and scaled.
private struct PlateRings: View {
    let line: Color
    let fill: Color
    let light: Bool
    let pale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = 0.0

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 390
            let k: Double = light ? (pale ? 1.5 : 1.6) : 1     // heavier lines so they hold on a light ground
            ZStack {
                ring(300, 1.5, 0.16 * k)
                ring(268, 2, min(1, 0.34 * k))
                ring(236, 1, 0.12 * k)
                Circle()
                    .stroke(pale ? fill : line, lineWidth: 22)
                    .opacity(pale ? 0.55 : (light ? 0.08 : 0.10))
                    .frame(width: 396, height: 396)
                ring(150, 1.5, 0.22 * k)
                ring(96, 1, 0.14 * k)
                ring(40, 2, min(1, 0.42 * k))
                Circle()
                    .fill(fill)
                    .opacity(pale ? 1 : (light ? 0.22 : 0.18))
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: 0.125)
                    .stroke(pale ? fill : line, style: StrokeStyle(lineWidth: pale ? 10 : 3, lineCap: .round))
                    .frame(width: 600, height: 600)
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 620, height: 620)
            .rotationEffect(.degrees(spin))
            .scaleEffect(s)
            .position(x: 350 * s, y: 140 * s)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 120).repeatForever(autoreverses: false)) { spin = 360 }
        }
    }

    private func ring(_ r: CGFloat, _ width: CGFloat, _ opacity: Double) -> some View {
        Circle()
            .stroke(line, lineWidth: width)
            .opacity(opacity)
            .frame(width: r * 2, height: r * 2)
    }
}

// MARK: - Slide to enter (gold)
// A brushed-gold bar in the QUEENS outline's gold with a dark knob you push right. The sheen
// rides the same tilt as QUEENS. A tick at each quarter, a heavy thunk when it locks. A tap
// on the bar hops the knob to show how it works; VoiceOver gets a plain "Enter" button.
private struct GoldSlideToEnter: View {
    let light: Bool
    let motion: MotionManager          // passed through to the sheen only
    let action: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var lastQuarter = 0
    @State private var entered = false

    // Soft gold (Oct 11, 2026): each of the QUEENS-outline stops (8A6A1E · E0A83C · FFF3B0) taken 45% of
    // the way from a mid gold (C8973A) — a lot less contrast, so the sparkles carry the shine.
    private static let gold: [Gradient.Stop] = [
        .init(color: Color(hex: 0xAC832D), location: 0),
        .init(color: Color(hex: 0xD39F3B), location: 0.28),
        .init(color: Color(hex: 0xE1C06F), location: 0.5),
        .init(color: Color(hex: 0xD39F3B), location: 0.72),
        .init(color: Color(hex: 0xAC832D), location: 1)
    ]
    private let height: CGFloat = 66
    private let knob: CGFloat = 54
    private let inset: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - knob - inset * 2)
            let progress = dragX / travel
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(stops: Self.gold, startPoint: .topLeading, endPoint: .bottomTrailing))
                GoldSheen(motion: motion, width: geo.size.width, height: height)
                CartoonSparkles(motion: motion)          // under ENTER and the knob
                Text("ENTER")
                    .font(BrandFont.welcome(19))
                    .tracking(6)
                    .foregroundColor(Color(hex: 0x2A1F07))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                    .opacity(max(0, 1 - Double(progress) * 1.4))
                Circle()
                    .fill(light ? Color(hex: 0x111113) : Color(hex: 0x0B0B0C))
                    .frame(width: knob, height: knob)
                    .overlay(
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundColor(Color(hex: 0xFFF3B0))
                    )
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
                    .offset(x: inset + dragX)
                    .gesture(slide(travel))
            }
            .frame(width: geo.size.width, height: height)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0x8A6A1E).opacity(light ? 0.35 : 0), lineWidth: 1))
            .shadow(color: light ? Color(hex: 0x8A6A1E).opacity(0.19) : Color(hex: 0xE0A83C).opacity(0.21),
                    radius: light ? 11 : 13, y: 8)
            .contentShape(Capsule())
            .onTapGesture { nudge() }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Enter")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func slide(_ travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !entered else { return }
                dragX = min(max(0, v.translation.width), travel)
                let q = Int((dragX / travel) * 4)
                if q != lastQuarter, q < 4 {
                    lastQuarter = q
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                guard !entered else { return }
                if dragX >= travel * 0.85 {
                    entered = true
                    withAnimation(.easeOut(duration: 0.15)) { dragX = travel }
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        action()
                    }
                } else {
                    lastQuarter = 0
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragX = 0 }
                }
            }
    }

    private func nudge() {
        guard !entered, dragX == 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { dragX = 28 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragX = 0 }
        }
    }
}

/// The sheen band across the gold (dimmed to 45% with the soft gold, Oct 11, 2026).
private struct GoldSheen: View {
    @ObservedObject var motion: MotionManager
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let tilt = (motion.roll + motion.wave * 0.6) / 1.6          // about -1…1
        LinearGradient(colors: [Color(hex: 0xFFFDE8).opacity(0), Color(hex: 0xFFFDE8).opacity(0.43), Color(hex: 0xFFFDE8).opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: 70, height: height * 1.4)
            .rotationEffect(.degrees(18))
            .offset(x: width * (0.5 + 0.42 * tilt) - 35)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }
}

// MARK: - Cartoon sparkles on the gold bar (Oct 11, 2026)
// Flat cream four-point stars with a chunky ink outline (a few rounded pluses, some with a tiny buddy
// star or a dot). Each pops in with a squash and a bounce, wobbles, then spins out. A new one goes in
// the spot furthest from the others, so they stay spread along the whole bar, up to 9 at a time.
// They only slide when you tilt the phone (no idle sway), at twice the rate of the gold's sheen,
// wrapping round the ends. Off with Reduce Motion.
private struct CartoonSparkles: View {
    let motion: MotionManager                 // read each frame, never observed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var field = SparkleField()

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    // GoldSheen travels width × 0.42 per unit of tilt; the sparkles go 2× that, tilt only.
                    let offset = size.width * 0.42 * SparkleField.speed * CGFloat(motion.roll / 1.6)
                    field.step(now: now, size: size)
                    field.draw(&ctx, now: now, size: size, offset: offset)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private final class SparkleField {
    static let count = 9                       // "More"
    static let speed: CGFloat = 2              // × the gold sheen's rate

    private struct Spark {
        var u: CGFloat, v: CGFloat             // 0…1 along and across the lane
        var born: Double, life: Double
        var r: CGFloat, rot: Double, seed: Double
        var plus: Bool, buddy: Bool, dot: Bool
    }
    private var list: [Spark] = []
    private var nextAt = 0.0

    private static let ink = Color(hex: 0x3A2906)
    private static let cream = Color(hex: 0xFFF6D0)
    private static let paper = Color(hex: 0xFFFDF2)

    private func lane(_ size: CGSize) -> CGRect {
        CGRect(x: 10, y: 14, width: max(1, size.width - 20), height: max(1, size.height - 28))
    }

    func step(now: Double, size: CGSize) {
        list.removeAll { now - $0.born >= $0.life }
        guard list.count < Self.count, now >= nextAt else { return }
        nextAt = now + Double.random(in: 0.12...0.32)
        let l = lane(size)
        // Best of 14 candidates: the one furthest from every sparkle already up.
        var best: (CGFloat, CGFloat)? = nil
        var bestD: CGFloat = -1
        for _ in 0..<14 {
            let u = CGFloat.random(in: 0..<1), v = CGFloat.random(in: 0...1)
            var d = CGFloat.infinity
            for p in list {
                let du = min(abs(u - p.u), 1 - abs(u - p.u)) * l.width, dv = (v - p.v) * l.height
                d = min(d, (du * du + dv * dv).squareRoot())
            }
            if d > bestD { bestD = d; best = (u, v) }
        }
        guard let b = best, bestD > l.width / (CGFloat(Self.count) * 1.5) else { return }
        let big = Double.random(in: 0..<1) < 0.7
        list.append(Spark(u: b.0, v: b.1, born: now, life: .random(in: 1.4...2.2),
                          r: big ? .random(in: 8.5...12) : .random(in: 5.5...7),
                          rot: .random(in: -0.35...0.35), seed: .random(in: 0...6),
                          plus: Double.random(in: 0..<1) < 0.2,
                          buddy: big && Double.random(in: 0..<1) < 0.35,
                          dot: Double.random(in: 0..<1) < 0.3))
    }

    func draw(_ ctx: inout GraphicsContext, now: Double, size: CGSize, offset: CGFloat) {
        let l = lane(size)
        for p in list {
            var px = (p.u * l.width + offset).truncatingRemainder(dividingBy: l.width)
            if px < 0 { px += l.width }
            let edge = min(1, px / 14, (l.width - px) / 14)          // fade at the ends, where they wrap
            guard edge > 0 else { continue }
            let t = (now - p.born) / p.life
            // Pop in with a squash, hold with a wobble, spin out.
            var sc: Double, rot = p.rot, sqX = 1.0, sqY = 1.0
            if t < 0.22 {
                let u = t / 0.22
                sc = 1 + 2.6 * pow(u - 1, 3) + 1.6 * pow(u - 1, 2)
                sqX = 1 + 0.25 * sin(u * .pi); sqY = 1 - 0.2 * sin(u * .pi)
            } else if t < 0.72 {
                sc = 1 + 0.06 * sin((t - 0.22) * 26)
                rot += 0.14 * sin(now * 5 + p.seed)
            } else {
                let u = (t - 0.72) / 0.28
                sc = 1 - u * u; rot += u * 1.2
            }
            guard sc > 0.02 else { continue }
            var c = ctx
            c.opacity = Double(edge)
            c.translateBy(x: l.minX + px, y: l.minY + p.v * l.height)
            c.rotate(by: .radians(rot))
            c.scaleBy(x: CGFloat(sc * sqX), y: CGFloat(sc * sqY))
            let r = p.r
            if p.plus {
                let path = Self.plusPath(r * 0.8)
                c.stroke(path, with: .color(Self.ink), style: Self.inkStyle(r * 0.8))
                c.fill(path, with: .color(Self.paper))
            } else {
                let body = Self.starPath(r, fat: 0.22)
                c.stroke(body, with: .color(Self.ink), style: Self.inkStyle(r))
                c.fill(body, with: .color(Self.cream))
                c.fill(Self.starPath(r * 0.55, fat: 0.22), with: .color(.white))          // inner shine
                var h = c                                                              // highlight
                h.translateBy(x: -r * 0.18, y: -r * 0.38); h.rotate(by: .radians(-0.5))
                h.fill(Path(ellipseIn: CGRect(x: -r * 0.1, y: -r * 0.17, width: r * 0.2, height: r * 0.34)), with: .color(.white))
                if p.buddy {                                                           // a little companion
                    var b = c
                    b.translateBy(x: r * 1.05, y: -r * 0.9); b.rotate(by: .radians(0.3))
                    let small = Self.starPath(r * 0.38, fat: 0.24)
                    b.stroke(small, with: .color(Self.ink), style: Self.inkStyle(r * 0.38))
                    b.fill(small, with: .color(Self.paper))
                }
                if p.dot {
                    let dot = Path(ellipseIn: CGRect(x: -r * 1.35 - r * 0.16, y: r * 0.95 - r * 0.16, width: r * 0.32, height: r * 0.32))
                    c.stroke(dot, with: .color(Self.ink), style: Self.inkStyle(r * 0.5))
                    c.fill(dot, with: .color(Self.paper))
                }
            }
        }
    }

    private static func inkStyle(_ r: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: max(1.6, r * 0.2), lineJoin: .round) }

    /// A fat four-point star: tips at ±r, sides curving in toward the middle.
    private static func starPath(_ r: CGFloat, fat: CGFloat) -> Path {
        let k = r * fat
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
        p.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
        p.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
        p.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
        p.closeSubpath()
        return p
    }

    /// A rounded plus sign.
    private static func plusPath(_ r: CGFloat) -> Path {
        let t = r * 0.42
        var p = Path()
        p.addRoundedRect(in: CGRect(x: -t / 2, y: -r, width: t, height: r * 2), cornerSize: CGSize(width: t / 2, height: t / 2))
        p.addRoundedRect(in: CGRect(x: -r, y: -t / 2, width: r * 2, height: t), cornerSize: CGSize(width: t / 2, height: t / 2))
        return p
    }
}

// MARK: - Flipping tile grid
// A flat grid of photo tiles. Each tile periodically flips (3D rotation) to the
// next photo in the set, on a staggered timer so the board feels alive but calm.
// MARK: - Enter (a standard bar in your theme colour: — ENTER —)

struct EnterCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                line
                Text("ENTER")
                    .font(BrandFont.display(24)).tracking(5)
                    .lineLimit(1).fixedSize()
                    .offset(x: 2.5)                     // tracking adds space after the last letter
                line
            }
            .foregroundColor(Brand.onVolt)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(EnterPress())
        .accessibilityLabel("Enter")
    }

    /// A thin line either side of the word.
    private var line: some View {
        Rectangle().fill(Brand.onVolt).frame(width: 36, height: 1.5)
    }
}

private struct EnterPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct FlippingTileGrid: View {
    let photos: [String]
    private let cols = 3
    private let rows = 5

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let tileW = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let tileH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { c in
                            let index = r * cols + c
                            FlipTile(photos: photos,
                                     startOffset: index,
                                     delay: Double((index * 13) % 17) * 1.1 + 2.0)
                                .frame(width: tileW, height: tileH)
                        }
                    }
                }
            }
        }
    }
}

// A single tile that flips to reveal the next photo on a repeating timer.
struct FlipTile: View {
    let photos: [String]
    let startOffset: Int
    let delay: Double

    @State private var current: Int
    @State private var angle: Double = 0
    @State private var showingFront = true

    init(photos: [String], startOffset: Int, delay: Double) {
        self.photos = photos
        self.startOffset = startOffset
        self.delay = delay
        _current = State(initialValue: startOffset)
    }

    var body: some View {
        tileFace(current)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .onAppear { scheduleFlip() }
    }

    private func tileFace(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(BrandDark.bg)
            .overlay(
                Group {
                    if !photos.isEmpty, UIImage(named: photos[i % photos.count]) != nil {
                        Image(photos[i % photos.count]).resizable().scaledToFill()
                    } else {
                        // fallback tile
                        ZStack {
                            BrandDark.bg
                            Text("#bigscherlytraining")
                                .font(BrandFont.body(8, .bold)).foregroundColor(BrandDark.mute)
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func scheduleFlip() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            flip()
        }
    }

    private func flip() {
        // Rotate 90° (edge-on), swap photo at the midpoint, finish to 0. Gentle/slow.
        withAnimation(.easeIn(duration: 0.5)) { angle = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            current = (current + 1) % max(1, photos.count)
            angle = -90
            withAnimation(.easeOut(duration: 0.5)) { angle = 0 }
            // schedule the next flip after a longer, calmer rest
            let next = Double.random(in: 9.0...16.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + next) { flip() }
        }
    }
}

// MARK: - Stroke (outlined) text helper for GET / TOGETHER
// Hollow white outline: white ring of offset copies with the letter center
// knocked out so the photo board shows through, matching the website's outlined words.

struct StrokeText: View {
    let text: String
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        ZStack {
            // White ring: 8 offset copies form the stroke
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                Text(text)
                    .font(BrandFont.welcome(size))
                    .foregroundColor(color)
                    .offset(x: CGFloat(cos(angle)) * 2.2, y: CGFloat(sin(angle)) * 2.2)
            }
            // Knock out the center so it's hollow (shows the board behind)
            Text(text)
                .font(BrandFont.welcome(size))
                .foregroundColor(.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }
}

// MARK: - The welcome board's face
// The original welcome board asked for the display font by name before the font file was
// bundled, so iOS drew every word (and QUEENS) in its own system face. That look is the
// welcome board. Asking for a name that isn't installed takes exactly the same path, so it
// renders identically now that Big Shoulders is bundled for the rest of the app.
extension BrandFont {
    static func welcome(_ size: CGFloat) -> Font {
        .custom("BST-WelcomeBoard-SystemFace", size: size)
            .weight(.black)
    }
}
