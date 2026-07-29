import SwiftUI

// MARK: - Brand Theme
// Colors sampled directly from the Big Scherly Training website
enum Brand {
    static let volt   = Color(hex: 0xEDFF3D)   // signature neon
    static let bg     = Color(hex: 0x1F1F21)   // charcoal body
    static let black  = Color(hex: 0x010101)   // card black
    static let white  = Color.white
    static let mute   = Color(hex: 0x9C9C9F)
    static let line   = Color.white.opacity(0.14)
    static let danger = Color(hex: 0xFF5A5A)

    // Rainbow metallic stops for the "QUEENS" shimmer
    static let rainbow: [Color] = [
        Color(hex: 0xE63946), Color(hex: 0xF2A03D), Color(hex: 0xE9D948),
        Color(hex: 0x3FA35B), Color(hex: 0x3D6FE0), Color(hex: 0x8A4FBF),
        Color(hex: 0xE63946)
    ]
}

// MARK: - Typography
// "Big Shoulders Display" is the display face on the site. Add the .ttf to the
// project and register in Info.plist; falls back to a heavy system font if absent.
enum BrandFont {
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
            .background(Brand.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Brand.volt).frame(width: 26, height: 3)
            Text(text.uppercased())
                .font(BrandFont.body(12, .bold))
                .tracking(2)
                .foregroundColor(Brand.volt)
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
                .foregroundColor(filled ? Brand.black : Brand.volt)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(filled ? Brand.volt : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Brand.volt, lineWidth: 2))
        }
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardStyle(padding: padding)) }
}

// MARK: - Color hex helper
extension Color {
    init(hex: UInt, alpha: Double = 1) {
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
                    .foregroundColor(Brand.volt)
            }
        }
    }
}
