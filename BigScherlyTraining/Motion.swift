import SwiftUI

// MARK: - Motion
// Small, reusable animation helpers so screens feel alive without hand-rolling the
// same spring in every view. Adopt incrementally:
//   • `.staggeredAppear(index)` on the top-level children of a screen → a cascade.
//   • `.buttonStyle(PressableStyle())` on tappable cards → a tactile press.
//
// Add this file to the main app target.

/// Fades + rises a view in on appear, offset by its position so a column of
/// elements cascades instead of all popping in at once. Because screens are
/// rebuilt when you navigate to them (MainShell keys content by `activeTab`),
/// this replays on every visit — the entrance choreography, every time.
struct StaggeredAppear: ViewModifier {
    let index: Int
    var baseDelay: Double = 0.04
    var step: Double = 0.06
    var rise: CGFloat = 14

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)
                    .delay(baseDelay + Double(index) * step)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Cascade this view in on appear. Give siblings increasing indices (0, 1, 2 …).
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

/// Press feedback: dips + slightly dims while held, then springs back.
/// Use on tappable cards/buttons: `.buttonStyle(PressableStyle())`.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}
