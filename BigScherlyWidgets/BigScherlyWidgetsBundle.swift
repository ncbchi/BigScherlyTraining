import WidgetKit
import SwiftUI

// The widget extension's entry point: the workout Live Activity, plus the Home and
// Lock Screen widgets (each with its own Edit Widget menu).
@main
struct BigScherlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BigScherlyWidgetsLiveActivity()
        BigScherlyHomeWidget()          // Home Screen: small / medium / large, resizable
        BigScherlyCircleWidget()
        BigScherlyRectWidget()
        BigScherlyInlineWidget()
    }
}
