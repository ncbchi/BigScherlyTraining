import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: the "Platform" design system (Oct 8, 2026)
//
// Black and volt from the brand. Big Shoulders for numbers and titles, Barlow for everything
// you read, Barlow Semi Condensed for labels. Numbers are the hero; the accent marks the one
// thing that matters on a screen. Dark as designed; light follows the proposal (sidebar stays
// black, the accent only ever a fill with black text on it, "better" shown with a dot).
// The accent follows Settings ▸ Appearance (volt by default), so a Cobalt coach gets Cobalt.
// Synchronized folder (BigScherlyTraining/CoachPad): no target step needed.

enum Pad {
    nonisolated static var isLight: Bool { Palette.current.scheme == .light }

    nonisolated static var page: Color    { isLight ? Color(hex: 0xF3F3F0) : Color(hex: 0x19191C) }
    nonisolated static var surface: Color { isLight ? .white : Color(hex: 0x222226) }
    nonisolated static var raised: Color  { isLight ? Color(hex: 0xE7E7E2) : Color(hex: 0x2C2C31) }
    nonisolated static var well: Color    { isLight ? Color(hex: 0xF0F0EC) : Color(hex: 0x141416) }
    nonisolated static var done: Color    { isLight ? Color(hex: 0xECECE7) : Color(hex: 0x26262A) }
    nonisolated static var liveFill: Color { isLight ? .white : Color(hex: 0x2F3214) }
    nonisolated static var line: Color    { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.07) }
    nonisolated static var line2: Color   { isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.13) }
    nonisolated static var text: Color    { isLight ? Color(hex: 0x141416) : Color(hex: 0xF5F5F2) }
    nonisolated static var mute: Color    { isLight ? Color(hex: 0x5F5F66) : Color(hex: 0xA1A1A8) }
    nonisolated static var faint: Color   { isLight ? Color(hex: 0x8E8E93) : Color(hex: 0x74747C) }
    nonisolated static var orange: Color  { isLight ? Color(hex: 0xB5650B) : Color(hex: 0xF5A23D) }
    nonisolated static var red: Color     { isLight ? Color(hex: 0xC73A3A) : Color(hex: 0xFF6161) }
    nonisolated static let blue = Color(hex: 0x4AA3F0)
    nonisolated static let green = Color(hex: 0x5FD38A)
    nonisolated static let chalk = Color(hex: 0xEEECE5)
    nonisolated static let ink = Color(hex: 0x161616)

    /// The accent as a fill, and what goes on it. (Volt unless the coach picked another accent.)
    nonisolated static var volt: Color   { Palette.current.accent }
    nonisolated static var onVolt: Color { Palette.current.onAccent }
    /// The accent used as text or a line: in light mode that would read olive, so it's ink there.
    nonisolated static var voltText: Color { isLight ? text : Palette.current.accent }

    // The sidebar is black in both themes.
    nonisolated static let rail = Color(hex: 0x010101)
    nonisolated static let railText = Color(hex: 0xF5F5F2)
    nonisolated static let railMute = Color(hex: 0xA1A1A8)
    nonisolated static let railFaint = Color(hex: 0x74747C)
    nonisolated static let railLine = Color.white.opacity(0.07)
    nonisolated static let railLine2 = Color.white.opacity(0.13)
    nonisolated static let railHover = Color(hex: 0x141416)
    nonisolated static let railOn = Color(hex: 0x1C1C1F)
    nonisolated static let railRaised = Color(hex: 0x2C2C31)

    /// Sidebar width (full), icon rail width, and the width under which the sidebar overlays.
    static let sidebarWidth: CGFloat = 232
    static let railWidth: CGFloat = 76
    static let sideBySideMin: CGFloat = 1100
}

enum PadFont {
    static func display(_ size: CGFloat) -> Font { .custom("BigShouldersDisplay-Black", size: size) }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .regular: name = "Barlow-Regular"
        case .semibold: name = "Barlow-SemiBold"
        case .bold, .heavy, .black: name = "Barlow-Bold"
        default: name = "Barlow-Medium"
        }
        return .custom(name, size: size)
    }
    static func cond(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let name: String
        switch weight {
        case .medium, .regular: name = "BarlowSemiCondensed-Medium"
        case .bold, .heavy, .black: name = "BarlowSemiCondensed-Bold"
        default: name = "BarlowSemiCondensed-SemiBold"
        }
        return .custom(name, size: size)
    }
}

// MARK: - Text roles

struct PadLab: View {
    let text: String
    var color: Color = Pad.mute
    var size: CGFloat = 13
    init(_ text: String, color: Color = Pad.mute, size: CGFloat = 13) { self.text = text; self.color = color; self.size = size }
    var body: some View { Text(text).font(PadFont.cond(size)).foregroundColor(color) }
}

/// A number in Big Shoulders with an optional unit after it. Sizes: xl 72, l 44, m 30, s 22.
struct PadNumber: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 30
    var color: Color = Pad.text
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(PadFont.display(size)).foregroundColor(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let unit { Text(unit).font(PadFont.cond(14)).foregroundColor(Pad.mute) }
        }
    }
}

/// A delta line: accent means better, orange means worse. In light mode "better" is a volt dot.
struct PadDelta: View {
    let text: String
    let better: Bool?      // nil = neutral
    var body: some View {
        HStack(spacing: 6) {
            if better == true && Pad.isLight {
                Circle().fill(Pad.volt).overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1)).frame(width: 8, height: 8)
            }
            Text(text).font(PadFont.cond(13)).foregroundColor(color)
        }
    }
    private var color: Color {
        switch better {
        case .some(true): return Pad.voltText
        case .some(false): return Pad.orange
        case .none: return Pad.mute
        }
    }
}

// MARK: - Panels and wells

struct PadPanel<Content: View>: View {
    var title: String? = nil
    var aside: String? = nil
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || aside != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let title { Text(title).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text) }
                    Spacer(minLength: 0)
                    if let aside { Text(aside).font(PadFont.ui(13)).foregroundColor(Pad.mute) }
                }
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pad.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Pad.line, lineWidth: 1))
        .shadow(color: Pad.isLight ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
    }
}

extension View {
    func padWell(_ padding: CGFloat = 14) -> some View {
        self.padding(padding).background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }
    /// Hover highlight for an iPad trackpad; a no-op on touch.
    func padHover() -> some View { self.hoverEffect(.highlight) }
}

// MARK: - Buttons

struct PadButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, quiet }
    var kind: Kind = .outline
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PadFont.ui(small ? 14 : 15, .semibold))
            .foregroundColor(kind == .primary ? Pad.onVolt : (kind == .quiet ? Pad.mute : Pad.text))
            .padding(.horizontal, small ? 13 : 16)
            .frame(minHeight: small ? 36 : 44)
            .background(RoundedRectangle(cornerRadius: small ? 9 : 11).fill(kind == .primary ? Pad.volt : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: small ? 9 : 11).stroke(kind == .outline ? Pad.line2 : Color.clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: small ? 9 : 11))
            .hoverEffect(.highlight)
    }
}

/// Icon-only, 44×44 (36 when small).
struct PadIconButton: View {
    let systemName: String
    let label: String
    var small = false
    var on = false
    var tint: Color = Pad.text
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: small ? 15 : 17, weight: .semibold))
                .foregroundColor(on ? Pad.text : tint)
                .frame(width: small ? 36 : 44, height: small ? 36 : 44)
                .background(RoundedRectangle(cornerRadius: small ? 9 : 11).fill(on ? Pad.raised : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: small ? 9 : 11).stroke(Pad.line2, lineWidth: on ? 0 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// Segmented control: well background, raised selected segment.
struct PadSeg<ID: Hashable>: View {
    let options: [(id: ID, label: String)]
    @Binding var selection: ID
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { o in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.id } } label: {
                    Text(o.label).font(PadFont.ui(14, .semibold))
                        .foregroundColor(selection == o.id ? Pad.text : Pad.mute)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selection == o.id ? Pad.raised : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
    }
}

/// Pill chip (saved replies, filters). Selected = text-coloured fill.
struct PadChip: View {
    let text: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(PadFont.ui(14, .semibold)).lineLimit(1)
                .foregroundColor(on ? (Pad.isLight ? .white : Pad.ink) : Pad.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(on ? Pad.text : Color.clear))
                .overlay(Capsule().stroke(on ? Pad.text : Pad.line2, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Small tag: 22 tall, radius 6, condensed 12.
struct PadTag: View {
    enum Kind { case plain, volt, warn, bad, blue, line }
    let text: String
    var kind: Kind = .plain
    var body: some View {
        Text(text).font(PadFont.cond(12)).lineLimit(1)
            .foregroundColor(fg)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(kind == .line ? Pad.line2 : Color.clear, lineWidth: 1))
    }
    private var fg: Color {
        switch kind {
        case .plain: return Pad.text
        case .volt: return Pad.onVolt
        case .warn: return Pad.orange
        case .bad: return Pad.red
        case .blue: return Pad.blue
        case .line: return Pad.mute
        }
    }
    private var bg: Color {
        switch kind {
        case .plain: return Pad.raised
        case .volt: return Pad.volt
        case .warn: return Pad.orange.opacity(Pad.isLight ? 0.12 : 0.14)
        case .bad: return Pad.red.opacity(0.13)
        case .blue: return Pad.blue.opacity(0.14)
        case .line: return .clear
        }
    }
}

/// An initial in Big Shoulders. The person lifting right now gets a volt avatar.
struct PadAvatar: View {
    let name: String
    var size: CGFloat = 34
    var volt = false
    var dot: Color? = nil
    var onRail = false
    var body: some View {
        Text(name.initials)
            .font(PadFont.display(size * 0.44))
            .foregroundColor(volt ? Pad.onVolt : (onRail ? Pad.railText : Pad.text))
            .frame(width: size, height: size)
            .background(Circle().fill(volt ? Pad.volt : (onRail ? Pad.railRaised : Pad.raised)))
            .overlay(alignment: .bottomTrailing) {
                if let dot {
                    Circle().fill(dot).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Pad.surface, lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 6-tall progress bar. Hero = accent fill, otherwise text colour.
struct PadBar: View {
    let fraction: Double
    var hero = true
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Pad.isLight ? Color(hex: 0xDEDED8) : Pad.raised)
                Capsule().fill(hero ? Pad.volt : Pad.text)
                    .overlay(Capsule().stroke(Color.black.opacity(hero && Pad.isLight ? 0.3 : 0), lineWidth: 1))
                    .frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A KPI tile in a well: label, big number, and a bar or a line under it.
struct PadKPI<Foot: View>: View {
    let label: String
    let value: String
    var unit: String? = nil
    @ViewBuilder var foot: () -> Foot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PadLab(label)
            PadNumber(value: value, unit: unit, size: 44)
            foot()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.well))
    }
}

// MARK: - Inputs

struct PadInputStyle: ViewModifier {
    var multiline = false
    func body(content: Content) -> some View {
        content
            .font(PadFont.ui(15)).foregroundColor(Pad.text)
            .padding(.horizontal, 12).padding(.vertical, multiline ? 11 : 0)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pad.line2, lineWidth: 1))
    }
}
extension View {
    func padInput(multiline: Bool = false) -> some View { modifier(PadInputStyle(multiline: multiline)) }
}

/// A grey block in the real layout while something loads. Never the word "Loading…".
struct PadSkeleton: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(Pad.raised)
            .frame(width: width, height: height)
            .opacity(on ? 0.55 : 1)
            .onAppear {
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

/// Divided rows inside a panel.
struct PadDivided<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
    }
}
struct PadRule: View {
    var body: some View { Rectangle().fill(Pad.line).frame(height: 1) }
}

// MARK: - Toasts (undo, sent, failures). No system alerts.

@MainActor
final class PadToasts: ObservableObject {
    static let shared = PadToasts()
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var action: String? = nil
        var perform: (() -> Void)? = nil
        nonisolated static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }
    @Published var current: Toast?
    private var task: Task<Void, Never>?

    func show(_ text: String, action: String? = nil, perform: (() -> Void)? = nil, seconds: Double = 4) {
        withAnimation(.easeOut(duration: 0.18)) { current = Toast(text: text, action: action, perform: perform) }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.current = nil }
        }
    }
    func dismiss() { task?.cancel(); withAnimation(.easeOut(duration: 0.18)) { current = nil } }
}

struct PadToastHost: View {
    @ObservedObject private var toasts = PadToasts.shared
    var body: some View {
        VStack {
            Spacer()
            if let t = toasts.current {
                HStack(spacing: 14) {
                    Text(t.text).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.isLight ? .white : Pad.ink)
                    if let a = t.action {
                        Button(a) { t.perform?(); toasts.dismiss() }
                            .font(PadFont.ui(14, .bold)).foregroundColor(Pad.isLight ? .white : Pad.ink)
                            .underline()
                    }
                }
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Capsule().fill(Pad.isLight ? Pad.ink : Pad.chalk))
                .shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 8)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(toasts.current != nil)
    }
}

// MARK: - Small helpers

extension Date {
    /// "6:58 pm" / "9:36 am".
    var padClock: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: self)
    }
    /// "Today", "Yesterday", "Mon", "Oct 3" for list stamps.
    var padWhen: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return padClock }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let d = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: Date())).day, d < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
    /// "2 hours ago", "this morning", "5 days ago".
    var padAgo: String {
        let s = Date().timeIntervalSince(self)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 {
            let h = Int(s / 3600)
            return h == 1 ? "an hour ago" : "\(h) hours ago"
        }
        let d = Int(s / 86_400)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }
}

extension Int {
    func plural(_ word: String) -> String { "\(self) \(word)\(self == 1 ? "" : "s")" }
}
