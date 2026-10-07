import SwiftUI
import Combine
import CoreText

// MARK: - Brand Theme
// Every colour the app draws comes from the current Palette, which follows the theme you
// pick in Settings ▸ Appearance (Dark · Light · System · Custom). Roles, not raw colours:
//   volt      the accent as a FILL — buttons, selected chips, toggles, big highlights
//   voltText  the accent as TEXT / ICONS (readable: black in light mode)
//   voltLine  the accent as a LINE — rings, chart lines, progress, selection outlines
//             (light mode: the original accent colour)
//   headerPill()  section headers: accent text; in light mode on a smoke-grey pill
//   onVolt    text and icons drawn ON a volt fill (black, or white on dark accents)
//   bg / card / text / mute / line   page, card surface, primary & secondary text, hairlines
// Legacy names kept so older code still reads naturally: `black` = card surface,
// `white` = primary text.
enum Brand {
    nonisolated static var volt: Color     { Palette.current.accent }
    nonisolated static var voltText: Color { Palette.current.accentText }
    nonisolated static var onVolt: Color   { Palette.current.onAccent }
    nonisolated static var voltLine: Color { Palette.current.accentLine }
    nonisolated static var headerText: Color { Palette.current.headerText }
    nonisolated static var bg: Color       { Palette.current.bg }
    nonisolated static var card: Color     { Palette.current.card }
    nonisolated static var black: Color    { Palette.current.card }
    nonisolated static var text: Color     { Palette.current.text }
    nonisolated static var white: Color    { Palette.current.text }
    nonisolated static var mute: Color     { Palette.current.mute }
    nonisolated static var line: Color     { Palette.current.line }
    nonisolated static var shadow: Color   { Palette.current.shadow }
    /// For a colour drawn as text or a line: the accent fill becomes its readable text shade
    /// (deep in light mode); any other colour passes through.
    nonisolated static func readable(_ c: Color) -> Color { c == Palette.current.accent ? Palette.current.accentText : c }
    /// The same, for a colour drawn as a line (ring, chart line, outline).
    nonisolated static func readableLine(_ c: Color) -> Color { c == Palette.current.accent ? Palette.current.accentLine : c }
    static let danger = Color(hex: 0xFF5A5A)

    // Rainbow metallic stops for the "QUEENS" shimmer
    static let rainbow: [Color] = [
        Color(hex: 0xE63946), Color(hex: 0xF2A03D), Color(hex: 0xE9D948),
        Color(hex: 0x3FA35B), Color(hex: 0x3D6FE0), Color(hex: 0x8A4FBF),
        Color(hex: 0xE63946)
    ]
}

/// The original dark brand colours, fixed. For screens that always stay dark whatever the
/// theme: the splash and login, photo and camera views, celebrations, and share cards
/// (those are images that leave the app).
enum BrandDark {
    static let volt   = Color(hex: 0xEDFF3D)
    static let bg     = Color(hex: 0x1F1F21)
    static let black  = Color(hex: 0x010101)
    static let card   = Color(hex: 0x010101)
    static let white  = Color.white
    static let text   = Color.white
    static let mute   = Color(hex: 0x9C9C9F)
    static let line   = Color.white.opacity(0.14)
    static let danger = Color(hex: 0xFF5A5A)
    static let onVolt = Color(hex: 0x010101)
    static let voltText = Color(hex: 0xEDFF3D)
    static let rainbow: [Color] = Brand.rainbow
}

// MARK: - Colour maths (readability rules)

/// An sRGB colour with the bits the theme needs: luminance, contrast, HSL tweaks.
nonisolated struct RGBColor: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255; g = Double((hex >> 8) & 0xff) / 255; b = Double(hex & 0xff) / 255
    }
    var hex: UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// WCAG relative luminance.
    var luminance: Double {
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }
    func contrast(_ o: RGBColor) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGBColor {
        guard s > 0 else { return RGBColor(r: l, g: l, b: l) }
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0; if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        return RGBColor(r: hue(p, q, h + 1.0 / 3), g: hue(p, q, h), b: hue(p, q, h - 1.0 / 3))
    }

    static let white = RGBColor(hex: 0xFFFFFF)
    static let ink = RGBColor(hex: 0x111113)

    /// Darkened until it reads as text on white (light mode).
    func readableOnLight(_ bg: RGBColor = .white) -> RGBColor {
        let (h, s, l) = hsl
        var L = min(l, 0.45)
        while L > 0.05 {
            let c = RGBColor.hsl(h, s, L)
            if c.contrast(bg) >= 4.6 { return c }
            L -= 0.01
        }
        return .ink
    }
    /// Lightened until it reads as text on a dark background (dark mode).
    func readableOnDark(_ bg: RGBColor) -> RGBColor {
        if contrast(bg) >= 4.6 { return self }
        let (h, s, l) = hsl
        var L = l
        while L < 0.95 {
            let c = RGBColor.hsl(h, s, L)
            if c.contrast(bg) >= 4.6 { return c }
            L += 0.01
        }
        return .white
    }
    /// Black or white, whichever reads better on this colour.
    var textOn: RGBColor { RGBColor.ink.contrast(self) >= RGBColor.white.contrast(self) ? .ink : .white }
}

// MARK: - Palette (the colours in use right now)

nonisolated struct Palette {
    var scheme: ColorScheme
    var accent: Color, accentText: Color, onAccent: Color, accentLine: Color, headerText: Color
    var bg: Color, card: Color, text: Color, mute: Color, line: Color, shadow: Color

    static func make(scheme: ColorScheme, accent hex: UInt32, trueBlack: Bool, highContrast: Bool) -> Palette {
        let acc = RGBColor(hex: hex)
        if scheme == .light {
            let bg = RGBColor(hex: 0xF2F2F4)
            // Light: accent text and icons go black; lines keep the real accent; headers sit
            // on a smoke pill (HeaderPill) with the accent readable on it.
            return Palette(scheme: .light,
                           accent: acc.color, accentText: RGBColor.ink.color, onAccent: acc.textOn.color,
                           accentLine: acc.color, headerText: acc.readableOnDark(RGBColor(hex: 0x39393B)).color,
                           bg: bg.color, card: .white, text: RGBColor.ink.color,
                           mute: Color(hex: highContrast ? 0x4A4A4F : 0x6E6E73),
                           line: Color.black.opacity(highContrast ? 0.24 : 0.08),
                           shadow: Color.black.opacity(0.07))
        }
        let bg = RGBColor(hex: trueBlack ? 0x000000 : 0x1F1F21)
        let text = acc.readableOnDark(bg).color
        return Palette(scheme: .dark,
                       accent: acc.color, accentText: text, onAccent: acc.textOn.color,
                       accentLine: text, headerText: text,
                       bg: bg.color, card: Color(hex: trueBlack ? 0x0E0E10 : 0x010101), text: .white,
                       mute: Color(hex: highContrast ? 0xC4C4C8 : 0x9C9C9F),
                       line: Color.white.opacity(highContrast ? 0.32 : 0.14),
                       shadow: .clear)
    }

    /// Set by ThemeHost before every redraw of the app. (Read everywhere through Brand.)
    nonisolated(unsafe) static var current = Palette.make(scheme: .dark, accent: 0xEDFF3D, trueBlack: false, highContrast: false)
}

// MARK: - Theme settings

enum ThemeChoice: String, CaseIterable, Identifiable {
    case dark, light, system, custom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "iphone"
        case .custom: return "paintpalette.fill"
        }
    }
}

struct AccentOption: Identifiable, Hashable {
    let name: String
    let hex: UInt32
    var id: UInt32 { hex }
}

enum ThemeBase: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Your theme: one of the three standard looks, or your own Custom one (remembered even
/// when you switch back to a standard look).
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let volt: UInt32 = 0xEDFF3D
    static let accents: [AccentOption] = [
        AccentOption(name: "Volt", hex: 0xEDFF3D), AccentOption(name: "Toxic", hex: 0x00FF85),
        AccentOption(name: "Ice", hex: 0x00E5FF), AccentOption(name: "Cobalt", hex: 0x2F6BFF),
        AccentOption(name: "Violet", hex: 0x9B3DFF), AccentOption(name: "Hot Pink", hex: 0xFF2E93),
        AccentOption(name: "Red", hex: 0xFF2424), AccentOption(name: "Ember", hex: 0xFF5A1F),
        AccentOption(name: "Amber", hex: 0xFFB300),
    ]

    private let d = UserDefaults.standard
    @Published var choice: ThemeChoice { didSet { d.set(choice.rawValue, forKey: "bst_theme_choice"); scheduleIcon() } }
    @Published var customBase: ThemeBase { didSet { d.set(customBase.rawValue, forKey: "bst_theme_base"); scheduleIcon() } }
    @Published var customAccent: UInt32 { didSet { d.set(Int(customAccent), forKey: "bst_theme_accent"); scheduleIcon() } }
    @Published var trueBlack: Bool { didSet { d.set(trueBlack, forKey: "bst_theme_trueblack") } }
    @Published var highContrast: Bool { didSet { d.set(highContrast, forKey: "bst_theme_contrast") } }

    private init() {
        let ud = UserDefaults.standard      // (not self.d — nothing on self can be read until everything's set)
        choice = ThemeChoice(rawValue: ud.string(forKey: "bst_theme_choice") ?? "") ?? .dark
        customBase = ThemeBase(rawValue: ud.string(forKey: "bst_theme_base") ?? "") ?? .dark
        let a = ud.integer(forKey: "bst_theme_accent")
        customAccent = a > 0 ? UInt32(a) : ThemeStore.volt
        trueBlack = ud.bool(forKey: "bst_theme_trueblack")
        highContrast = ud.bool(forKey: "bst_theme_contrast")
    }

    private var base: ThemeBase {
        switch choice {
        case .dark: return .dark
        case .light: return .light
        case .system: return .system
        case .custom: return customBase
        }
    }
    var accent: UInt32 { choice == .custom ? customAccent : ThemeStore.volt }

    /// nil = follow the iPhone's setting.
    var forcedScheme: ColorScheme? {
        switch base {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func palette(for system: ColorScheme) -> Palette {
        let custom = choice == .custom
        return Palette.make(scheme: forcedScheme ?? system, accent: accent,
                            trueBlack: custom && trueBlack, highContrast: custom && highContrast)
    }

    /// Changes whenever anything that affects colours changes.
    func signature(_ system: ColorScheme) -> String {
        "\(choice.rawValue)|\(customBase.rawValue)|\(customAccent)|\(trueBlack)|\(highContrast)|\(forcedScheme ?? system)"
    }

    /// The menu's Appearance row: Dark → Light → System → Custom → Dark.
    func cycle() {
        let all = ThemeChoice.allCases
        choice = all[((all.firstIndex(of: choice) ?? 0) + 1) % all.count]
    }

    func accentName(_ hex: UInt32) -> String { ThemeStore.accents.first { $0.hex == hex }?.name ?? "Custom" }

    // MARK: The app icon follows your accent and your light/dark choice
    // One ready-made icon per preset and background (Assets: AppIcon-Red, AppIcon-Red-Light,
    // AppIcon-Volt-Light…; dark Volt is the main icon). "System" follows the iPhone's setting.
    // iOS shows its own short "icon changed" notice whenever an app switches its icon.

    private var iconTask: Task<Void, Never>?

    /// Wait a moment first, so cycling through themes doesn't flash a notice for each one.
    func scheduleIcon() {
        iconTask?.cancel()
        iconTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyAppIcon()
        }
    }

    func applyAppIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        // Palette.current is what's drawing right now: your choice, or the iPhone's for System.
        let name = ThemeStore.iconName(for: accent, light: Palette.current.scheme == .light)
        guard app.alternateIconName != name else { return }
        app.setAlternateIconName(name) { _ in }
    }

    static func iconName(for hex: UInt32, light: Bool) -> String? {
        let base = iconBase(for: hex)                       // nil = Volt
        switch (base, light) {
        case (nil, false): return nil                       // the main icon: Volt on black
        case (nil, true): return "AppIcon-Volt-Light"
        case (let n?, false): return "AppIcon-" + n
        case (let n?, true): return "AppIcon-" + n + "-Light"
        }
    }

    private static func iconBase(for hex: UInt32) -> String? {
        let named: [UInt32: String] = [0x00FF85: "Toxic", 0x00E5FF: "Ice", 0x2F6BFF: "Cobalt", 0x9B3DFF: "Violet",
                                       0xFF2E93: "HotPink", 0xFF2424: "Red", 0xFF5A1F: "Ember", 0xFFB300: "Amber"]
        if hex == volt { return nil }
        if let n = named[hex] { return n }
        // A custom colour: the nearest preset by hue (greys keep Volt).
        let c = RGBColor(hex: hex).hsl
        guard c.s > 0.25 else { return nil }
        var best: (hex: UInt32, d: Double) = (volt, 9)
        for a in accents {
            let h = RGBColor(hex: a.hex).hsl.h
            let d = min(abs(h - c.h), 1 - abs(h - c.h))
            if d < best.d { best = (a.hex, d) }
        }
        return named[best.hex]
    }
}

/// Wraps the whole app: sets the palette for the current theme (and the iPhone's light/dark
/// setting, for System) before anything below draws. The main app re-keys itself on
/// theme.signature (see RootView) so it redraws once when the theme changes.
struct ThemeHost<Content: View>: View {
    @ObservedObject private var theme = ThemeStore.shared
    @ViewBuilder var content: () -> Content
    var body: some View {
        SchemeReader { scheme in
            let _ = (Palette.current = theme.palette(for: scheme))
            content()
                .onChange(of: scheme) { _, _ in theme.scheduleIcon() }   // System: the iPhone flipped light/dark
        }
        .preferredColorScheme(theme.forcedScheme)
        .task {                                   // once a launch: make sure the icon matches your accent
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            theme.applyAppIcon()
        }
    }
}

private struct SchemeReader<C: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: (ColorScheme) -> C
    var body: some View { content(scheme) }
}

// MARK: - Typography
// "Big Shoulders Display" is the display face on the site. Add the .ttf to the
// project and register in Info.plist; falls back to a heavy system font if absent.
enum BrandFont {
    /// Big Shoulders Display Black ships in the app (BigScherlyTraining/Fonts). Registered at
    /// launch, so no Info.plist entry is needed. Call once, before anything draws.
    static func registerFonts() {
        for name in ["BigShouldersDisplay-Black"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func display(_ size: CGFloat) -> Font {
        .custom("BigShouldersDisplay-Black", size: size)
            .weight(.black)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Reusable modifiers
struct CardStyle: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
            .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
    }
}

/// Section headers. Dark: accent text. Light: the accent on a translucent smoke-grey pill.
struct HeaderPill: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if Palette.current.scheme == .light {
            content
                .foregroundColor(Brand.headerText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 33 / 255, opacity: 0.88)))
        } else {
            content.foregroundColor(Brand.headerText)
        }
    }
}

extension View {
    func headerPill() -> some View { modifier(HeaderPill()) }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if Palette.current.scheme != .light {
                Rectangle().fill(Brand.voltLine).frame(width: 26, height: 3)
            }
            Text(text.uppercased())
                .font(BrandFont.body(12, .bold))
                .tracking(2)
                .headerPill()
        }
    }
}

struct VoltButton: View {
    let title: String
    var filled: Bool = true
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(BrandFont.body(14, .bold))
                .tracking(1.5)
                .foregroundColor(filled ? Brand.onVolt : Brand.voltText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(filled ? Brand.volt : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(filled ? Brand.volt : Brand.voltText, lineWidth: 2))
        }
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardStyle(padding: padding)) }
}

// MARK: - Color hex helper
extension Color {
    nonisolated init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

// MARK: - Keyboard dismissal
// Two complementary tools, applied per-screen (not at the app root — a root-level
// keyboard toolbar forces a whole-hierarchy layout pass that caused a multi-second
// delay, and doesn't cross into child NavigationStacks):
//
//   .tapToDismissKeyboard()      — tap anywhere off a field to close the keyboard
//   .keyboardDoneButton()        — a single Done button on the keyboard toolbar
//
// hideKeyboard() resigns whatever is first responder, so it dismisses any field
// (text, editor, number pad) regardless of which view it lives in.

func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    // Background tap that closes the keyboard. Uses a simultaneous gesture so it
    // rides alongside buttons, list rows, and scrolling instead of swallowing taps.
    func tapToDismissKeyboard() -> some View {
        self.simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
    }

    // A single Done button pinned above the keyboard. Apply ONCE per screen — never
    // inside a repeated row, or you get one button per row.
    func keyboardDoneButton() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .font(BrandFont.body(16, .semibold))
                    .foregroundColor(Brand.voltText)
            }
        }
    }
}
