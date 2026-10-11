import SwiftUI
import UIKit

// MARK: - Cards take only as much of the screen as they need (Oct 9, 2026)
// Every card-style sheet sizes itself to what's in it; if that's taller than the screen it
// stops just short of the top and scrolls. Full-screen views (chat threads, workout detail,
// editors, settings pages) don't use these.
//
//   ScrollView / Form / List { … }.sheetFitsScrollContent()   — put it straight on the scroll view
//   SomeCard().sheetFitsContent()                             — a card with no scroll view
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

enum SheetFit {
    /// The tallest a card gets: the screen less a little room at the top.
    static func clamp(_ h: CGFloat) -> CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 844
        return max(160, min(h, screen - 60))
    }
    /// Nothing extra: iOS adds the home-indicator strip under a custom-height card itself
    /// (adding it here too left an empty band under every card).
    static let homeStrip: CGFloat = 0

    /// The home-indicator strip at the bottom of the screen.
    static var bottomInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? scene?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}

extension View {
    /// On a sheet's ScrollView (or Form/List): the sheet is as tall as the scroll content.
    func sheetFitsScrollContent() -> some View { modifier(FitScrollSheet()) }
    /// On a card with no scroll view: the sheet is as tall as the card.
    func sheetFitsContent() -> some View { modifier(FitFixedSheet()) }
}

private struct FitScrollSheet: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.basedOnSize)
            // Content plus the title bar above it (iOS adds the home-indicator strip itself).
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.top
            } action: { _, h in
                height = h
            }
            .presentationDetents([.height(SheetFit.clamp(height > 0 ? height : 480))])
    }
}

private struct FitFixedSheet: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)          // spacers collapse to their minimum
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Brand.bg.ignoresSafeArea())                 // the strip under the card matches it
            .presentationDetents([.height(SheetFit.clamp(height > 0 ? height + SheetFit.homeStrip : 360))])
    }
}
