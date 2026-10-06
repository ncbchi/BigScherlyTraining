import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Workout Live Activity (Lock Screen + Dynamic Island)
// Left pane (centred): the set loop — rest border → Start set → lifting → Log set.
// Right pane: seven data views, picked with the icon row or the ‹ › arrows.
// iOS redraws the card by itself at its stale date (rest ends → Start set; the
// Watch-opened log editor closes after 10 s), so it stays right even with the app asleep.

/// Your theme accent on the card (Settings ▸ Appearance). Set from the update before drawing.
private enum LiveTheme {
    nonisolated(unsafe) static var accent = Color(red: 237 / 255, green: 1, blue: 61 / 255)
    nonisolated(unsafe) static var onAccent = Color.black
    nonisolated static func set(_ s: WorkoutActivityAttributes.ContentState) {
        let h = s.accent ?? 0xEDFF3D
        accent = Color(.sRGB, red: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255,
                       blue: Double(h & 0xff) / 255, opacity: 1)
        onAccent = (s.accentInkWhite ?? false) ? .white : .black
    }
}

private enum C {
    nonisolated static var volt: Color { LiveTheme.accent }
    nonisolated static var onVolt: Color { LiveTheme.onAccent }
    static let card = Color(red: 1 / 255, green: 1 / 255, blue: 1 / 255)
    static let panel = Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255)
    static let mute = Color(white: 0.56)
    static let line = Color(white: 1, opacity: 0.10)
    static let dim = Color(white: 1, opacity: 0.08)
    static let blue = Color(red: 61 / 255, green: 155 / 255, blue: 224 / 255)
    static let orange = Color(red: 242 / 255, green: 160 / 255, blue: 61 / 255)
    static let red = Color(red: 1, green: 85 / 255, blue: 85 / 255)
}

private typealias S = WorkoutActivityAttributes.ContentState

/// What to draw, after iOS's stale-date redraw.
private struct Shown {
    var s: S
    var stale: Bool
    var card: CGSize = .zero        // the card's inner size (for instant previews)
    var frozen = false              // a preview: timers shown still, not counting
    var isPreview = false           // drawn inside another control's preview: no live controls
    /// Rest ended while the app slept → show Start set.
    var stage: LiveStage { s.stage == .resting && stale ? .ready : s.stage }
    /// The Watch-opened editor closes itself at the stale date.
    var editing: Bool { s.editing && !(s.editorAuto && stale) }

    func sized(_ size: CGSize) -> Shown { var c = self; c.card = size; return c }
    func asPreview() -> Shown { var c = self; c.isPreview = true; return c }

    // What the card will look like right after each control — drawn the instant it's
    // tapped, until the app's real update replaces it (they match, so the swap is invisible).
    func afterStartSet() -> Shown {
        var c = self; c.stale = false; c.frozen = true
        c.s.stage = .lifting; c.s.setStart = nil; c.s.logNeeded = false; c.s.restStart = nil; c.s.restEnd = nil
        return c
    }
    func afterSkip() -> Shown {
        var c = self; c.stale = false
        c.s.stage = .ready; c.s.restStart = nil; c.s.restEnd = nil
        return c
    }
    func afterOpenEditor() -> Shown {
        var c = self; c.stale = false
        c.s.editing = true; c.s.editorAuto = false; c.s.editorUntil = nil
        c.s.dReps = s.nextReps; c.s.dWeight = s.nextWeight; c.s.dRPE = s.nextRPE; c.s.editSet = s.setNumber
        return c
    }
    func afterCancel() -> Shown {
        var c = self; c.stale = false; c.s.editing = false; c.s.editorAuto = false
        return c
    }
    func afterSave() -> Shown {
        var c = self; c.stale = false; c.frozen = true
        c.s.editing = false; c.s.editorAuto = false
        c.s.logNeeded = false; c.s.setStart = nil
        if c.s.setNumber < c.s.setCount { c.s.setNumber += 1 }
        if s.restSeconds > 0 {
            // A rest that hasn't started yet shows a full border and the full time, still.
            let a = Date().addingTimeInterval(365 * 86_400)
            c.s.stage = .resting; c.s.restStart = a; c.s.restEnd = a.addingTimeInterval(TimeInterval(s.restSeconds))
        } else {
            c.s.stage = .ready
        }
        c.s.view = s.afterSaveView
        c.s.afterSet = s.afterSaveView.isSensor
        return c
    }
}

/// A control that shows its result the instant it's tapped. It's an on/off switch (iOS
/// redraws those immediately, before the app runs) that is always off between taps; its
/// "on" look draws `preview` over the card, positioned in card coordinates.
private struct InstantStyle<Face: View, Preview: View>: ToggleStyle {
    let face: (Bool) -> Face
    let preview: () -> Preview

    func makeBody(configuration: Configuration) -> some View {
        face(configuration.isOn)
            .overlay(alignment: .topLeading) {
                if configuration.isOn {
                    GeometryReader { g in
                        let f = g.frame(in: .named("card"))
                        preview().offset(x: -f.minX, y: -f.minY)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// A control that previews its result instantly. Inside another control's preview it's drawn
/// as a plain picture instead: iOS pre-draws every switch's "on" look, and previews within
/// previews would otherwise chain round the set loop forever.
@ViewBuilder
private func instant<I: AppIntent, F: View, P: View>(_ intent: I, _ x: Shown,
                                                     face: @escaping (Bool) -> F,
                                                     result: @escaping () -> P) -> some View {
    if x.isPreview {
        face(false)
    } else {
        Toggle(isOn: false, intent: intent) { EmptyView() }
            .toggleStyle(InstantStyle(face: face, preview: result))
    }
}

/// Replacement panes drawn over the card for an instant preview (card coordinates).
private struct CardPreview: View {
    let card: CGSize
    var left: Shown? = nil
    var right: Shown? = nil
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let l = left {
                LeftPane(x: l.asPreview()).frame(width: 104, height: card.height).background(C.card)
            }
            if let r = right {
                RightPanel(x: r.asPreview())
                    .frame(width: max(card.width - 114, 0), height: card.height)
                    .background(C.card)
                    .offset(x: 114)
            }
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
    }
}

struct BigScherlyWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            let _ = LiveTheme.set(context.state)
            LiveCard(x: Shown(s: context.state, stale: context.isStale))
                .activityBackgroundTint(C.card)
                .activitySystemActionForegroundColor(C.volt)
        } dynamicIsland: { context in
            LiveTheme.set(context.state)
            let x = Shown(s: context.state, stale: context.isStale)
            return DynamicIsland {
                // Expanded (long-press): the same two panes as the Lock Screen, full width.
                DynamicIslandExpandedRegion(.bottom) {
                    GeometryReader { g in
                        HStack(spacing: 10) {
                            LeftPane(x: x.sized(g.size)).frame(width: 104)
                            RightPanel(x: x.sized(g.size))
                        }
                        .coordinateSpace(name: "card")
                    }
                    .frame(height: 136)
                }
            } compactLeading: {
                CompactLeading(x: x)
            } compactTrailing: {
                if let hr = x.s.hr {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill").font(.system(size: 10))
                        Text("\(hr)").font(.system(size: 13, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(C.red)
                } else {
                    Text("\(x.s.setNumber)/\(x.s.setCount)").font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(C.volt)
                }
            } minimal: {
                if x.stage == .resting, let a = x.s.restStart, let b = x.s.restEnd {
                    ProgressView(timerInterval: a...b, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.circular).tint(C.volt)
                } else {
                    Image(systemName: x.stage == .ready ? "play.fill" : "dumbbell.fill").foregroundStyle(C.volt)
                }
            }
            .keylineTint(C.volt)
        }
    }
}

private struct CompactLeading: View {
    let x: Shown
    var body: some View {
        Group {
            switch x.stage {
            case .resting:
                if let a = x.s.restStart, let b = x.s.restEnd {
                    Text(timerInterval: a...b, countsDown: true).foregroundStyle(C.volt)
                }
            case .lifting:
                if let st = x.s.setStart { Text(st, style: .timer).foregroundStyle(.white) }
            case .ready:
                Text("Set \(x.s.setNumber)").foregroundStyle(C.volt)
            case .done:
                Text(x.s.startedAt, style: .timer).foregroundStyle(.white)
            }
        }
        .font(.system(size: 14, weight: .heavy, design: .rounded)).monospacedDigit()
        .frame(maxWidth: 52)
    }
}

private func num(_ v: Double, _ d: Int = 1) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.\(d)f", v)
}

private func goal(_ s: S) -> String {
    s.goalWeight > 0 ? "\(s.goalReps) × \(num(s.goalWeight)) \(s.unit)" : "\(s.goalReps) reps"
}

private func pill(_ t: String, filled: Bool, height: CGFloat = 22) -> some View {
    Text(t).font(.system(size: 10, weight: .heavy))
        .foregroundStyle(filled ? C.onVolt : C.volt)
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity).frame(height: height)
        .background(Capsule().fill(filled ? C.volt : Color.clear))
        .overlay(Capsule().stroke(C.volt, lineWidth: filled ? 0 : 1))
}

// MARK: - Lock Screen card

private struct LiveCard: View {
    let x: Shown
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 10) {
                LeftPane(x: x.sized(g.size)).frame(width: 104)
                RightPanel(x: x.sized(g.size))
            }
            .coordinateSpace(name: "card")
        }
        .padding(12)
        .frame(height: 160)
    }
}

// MARK: - Left pane (centred): exercise, the set loop, total time

private struct LeftPane: View {
    let x: Shown
    private var s: S { x.s }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 1) {
                Text(s.exercise).font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(x.stage == .done ? "ALL SETS DONE" : "SET \(s.setNumber) OF \(s.setCount)")
                    .font(.system(size: 7.5, weight: .heavy)).tracking(0.8).foregroundStyle(C.mute)
                Text(goal(s)).font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(C.volt).lineLimit(1).minimumScaleFactor(0.65)
            }
            stage
            (Text(Image(systemName: "stopwatch")) + Text(" ") + Text(s.startedAt, style: .timer) + Text(" total"))
                .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(C.mute)
                .multilineTextAlignment(.center).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var stage: some View {
        switch x.stage {
        case .resting:
            if let a = s.restStart, let b = s.restEnd {
                VStack(spacing: 4) {
                    RestBorder(start: a, end: b)
                    HStack(spacing: 4) {
                        instant(LiveRestPlus30Intent(), x,
                                face: { on in pill(on ? "✓ +30s" : "+30s", filled: on, height: 20) },
                                result: { EmptyView() })
                        instant(LiveSkipRestIntent(), x,
                                face: { on in pill("Skip", filled: on, height: 20) },
                                result: { CardPreview(card: x.card, left: x.afterSkip()) })
                    }
                }
            }
        case .ready:
            VStack(spacing: 4) {
                instant(LiveStartSetIntent(), x, face: { _ in
                        VStack(spacing: 2) {
                            Image(systemName: "play.fill").font(.system(size: 14, weight: .heavy))
                            Text("Start set \(s.setNumber)").font(.system(size: 12, weight: .heavy))
                        }
                        .foregroundStyle(C.onVolt)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill(C.volt))
                }, result: { CardPreview(card: x.card, left: x.afterStartSet()) })
                Text("or just lift — the Watch starts it").font(.system(size: 7, weight: .bold)).foregroundStyle(C.mute)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(height: 20)
            }
        case .lifting:
            VStack(spacing: 4) {
                VStack(spacing: 0) {
                    Text(s.logNeeded ? "SET \(s.setNumber) DONE" : "SET \(s.setNumber) · LIFTING")
                        .font(.system(size: 7, weight: .heavy)).tracking(0.8).foregroundStyle(C.volt)
                    if x.frozen && !s.logNeeded {
                        Text("0:00").font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit().foregroundStyle(.white)
                    } else if let st = s.setStart, !s.logNeeded {
                        Text(st, style: .timer).font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit().foregroundStyle(.white)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.volt, lineWidth: 1.5))
                instant(LiveLogOpenIntent(), x,
                        face: { _ in pill("✓ Log set", filled: true, height: 20) },
                        result: { CardPreview(card: x.card, right: x.afterOpenEditor()) })
            }
        case .done:
            VStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 26)).foregroundStyle(C.volt)
                    .frame(height: 52)
                Text("Finish in the app").font(.system(size: 8, weight: .bold)).foregroundStyle(C.mute).frame(height: 20)
            }
        }
    }
}

/// The rest "button": black fill, thick volt border with fully rounded corners. The volt
/// shrinks around the outline clockwise from top centre, leaving grey behind, until the
/// last of it disappears at top centre, left side.
///
/// How: the outline is cut into 17 slices (three per corner). Each slice holds one of
/// iOS's timer bars — drawn wider and longer than the slice, then clipped to exactly that
/// slice — and each bar drains during its own part of the rest. The whole set is then
/// clipped to the rounded outline, so the edges are perfectly smooth and the slices meet
/// cleanly. A grey outline underneath keeps the shape whole as the volt goes.
private struct RestBorder: View {
    let start: Date
    let end: Date
    private let w: CGFloat = 104
    private let h: CGFloat = 52
    private let radius: CGFloat = 14
    private let line: CGFloat = 5
    private let overhang: CGFloat = 8          // bar length past each end of its slice (hides its rounded ends)

    private struct Piece {
        let a: CGPoint                          // slice start (clockwise)
        let b: CGPoint                          // slice end
        let region: [CGPoint]                   // the slice's area, a little beyond the outline on both sides
        var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
    }

    private var pieces: [Piece] {
        let inset = line / 2
        let left = inset, right = w - inset, top = inset, bottom = h - inset
        let r = radius - inset
        let reach = line * 2                    // how far each slice region extends either side of the centre line
        var out: [Piece] = []
        func straight(_ a: CGPoint, _ b: CGPoint) {
            let len = hypot(b.x - a.x, b.y - a.y)
            let nx = -(b.y - a.y) / len * reach, ny = (b.x - a.x) / len * reach
            out.append(Piece(a: a, b: b, region: [CGPoint(x: a.x - nx, y: a.y - ny), CGPoint(x: b.x - nx, y: b.y - ny),
                                                 CGPoint(x: b.x + nx, y: b.y + ny), CGPoint(x: a.x + nx, y: a.y + ny)]))
        }
        // Screen y points down, so increasing angles go clockwise. 3 slices per corner, each a
        // wedge from the corner's centre — neighbouring slices share their cut lines exactly.
        func corner(_ cx: CGFloat, _ cy: CGFloat, from a0: Double) {
            let far = (r + reach) / r
            for k in 0..<3 {
                let t0 = (a0 + Double(k) * 30) * .pi / 180, t1 = (a0 + Double(k + 1) * 30) * .pi / 180
                let a = CGPoint(x: cx + r * CGFloat(cos(t0)), y: cy + r * CGFloat(sin(t0)))
                let b = CGPoint(x: cx + r * CGFloat(cos(t1)), y: cy + r * CGFloat(sin(t1)))
                let c = CGPoint(x: cx, y: cy)
                out.append(Piece(a: a, b: b, region: [c, CGPoint(x: cx + (a.x - cx) * far, y: cy + (a.y - cy) * far),
                                                         CGPoint(x: cx + (b.x - cx) * far, y: cy + (b.y - cy) * far)]))
            }
        }
        straight(CGPoint(x: w / 2, y: top), CGPoint(x: right - r, y: top))
        corner(right - r, top + r, from: -90)
        straight(CGPoint(x: right, y: top + r), CGPoint(x: right, y: bottom - r))
        corner(right - r, bottom - r, from: 0)
        straight(CGPoint(x: right - r, y: bottom), CGPoint(x: left + r, y: bottom))
        corner(left + r, bottom - r, from: 90)
        straight(CGPoint(x: left, y: bottom - r), CGPoint(x: left, y: top + r))
        corner(left + r, top + r, from: 180)
        straight(CGPoint(x: left + r, y: top), CGPoint(x: w / 2, y: top))
        return out
    }

    var body: some View {
        let ps = pieces
        let perimeter = ps.reduce(0) { $0 + $1.length }
        let total = max(end.timeIntervalSince(start), 1)
        // Slice boundaries in time, in order around the outline.
        let cuts: [Date] = [start] + ps.indices.map { i in
            start.addingTimeInterval(total * Double(ps[...i].reduce(0) { $0 + $1.length } / perimeter))
        }
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color.black)
            // Grey outline: the shape that stays.
            RoundedRectangle(cornerRadius: radius).inset(by: line / 2)
                .stroke(Color(white: 0.30), lineWidth: line)
            ZStack {
                ForEach(ps.indices, id: \.self) { i in
                    bar(ps[i], from: cuts[i], to: cuts[i + 1])
                }
            }
            .frame(width: w, height: h)
            .mask {
                RoundedRectangle(cornerRadius: radius).inset(by: line / 2).stroke(lineWidth: line)
            }
            VStack(spacing: 0) {
                Text(timerInterval: start...end, countsDown: true)
                    .font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                Text("REST").font(.system(size: 7, weight: .heavy)).tracking(1).foregroundStyle(C.mute)
            }
            .frame(width: w - 16)
        }
        .frame(width: w, height: h)
    }

    /// One slice's bar: longer than the slice by `overhang` at each end (timed so the drain
    /// crosses the visible slice exactly during its part of the rest), clipped to the slice.
    private func bar(_ p: Piece, from: Date, to: Date) -> some View {
        let l = max(p.length, 0.5)
        let slice = max(to.timeIntervalSince(from), 0.05)
        let lead = slice * Double(overhang / l)
        // The bar's volt sits at its leading edge, so point leading at the slice's end:
        // the volt then retreats toward the end as the grey grows from the start.
        let angle = atan2(p.a.y - p.b.y, p.a.x - p.b.x)
        return ProgressView(timerInterval: from.addingTimeInterval(-lead)...to.addingTimeInterval(lead), countsDown: true) {
            EmptyView()
        } currentValueLabel: { EmptyView() }
        .progressViewStyle(.linear)
        .tint(C.volt)
        .frame(width: l + 2 * overhang)
        .scaleEffect(x: 1, y: 3.5)                       // much thicker than the outline; the clip trims it
        .rotationEffect(.radians(Double(angle)))
        .position(x: (p.a.x + p.b.x) / 2, y: (p.a.y + p.b.y) / 2)
        .mask {
            Path { path in
                path.addLines(p.region)
                path.closeSubpath()
            }
        }
    }
}

// MARK: - Right pane: icon row, ‹ view ›, or the log editor

private struct RightPane: View {
    let x: Shown
    private var s: S { x.s }

    var body: some View {
        if x.editing {
            LogEditor(x: x)
        } else {
            // The data on top, the selector along the bottom. Each icon is an on/off switch
            // whose "on" look draws its view over the data area — iOS shows that the moment
            // it's tapped, before the app's update arrives.
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let rowH: CGFloat = 22, gap: CGFloat = 4
                let dataH = max(h - rowH - gap, 0)
                let n = CGFloat(LiveView.allCases.count)
                let spacing = max((w - n * rowH) / (n - 1), 0)
                ZStack(alignment: .topLeading) {
                    ViewContent(s: s, view: s.view)
                        .frame(width: w, height: dataH, alignment: .topLeading)
                    HStack(spacing: spacing) {
                        ForEach(Array(LiveView.allCases.enumerated()), id: \.offset) { i, v in
                            selector(v, style: ViewSwitchStyle(view: v, s: s, slotX: CGFloat(i) * (rowH + spacing),
                                                                width: w, dataH: dataH, gap: gap))
                        }
                    }
                    .frame(width: w, height: rowH)
                    .offset(y: dataH + gap)
                }
            }
        }
    }

    /// One icon of the selector: always a switch (always "off" between taps). A view with no data
    /// yet is dimmed but still tappable — it shows what's coming (sensor views fill in rep by rep).
    @ViewBuilder
    private func selector(_ v: LiveView, style: ViewSwitchStyle) -> some View {
        if x.isPreview {
            style.icon(lit: s.view == v, enabled: s.available.contains(v))
        } else {
            switch v {
            case .heartRate: Toggle(isOn: false, intent: LiveSelectHeartRateIntent()) { EmptyView() }.toggleStyle(style)
            case .speed:     Toggle(isOn: false, intent: LiveSelectSpeedIntent()) { EmptyView() }.toggleStyle(style)
            case .travel:    Toggle(isOn: false, intent: LiveSelectTravelIntent()) { EmptyView() }.toggleStyle(style)
            case .tempo:     Toggle(isOn: false, intent: LiveSelectTempoIntent()) { EmptyView() }.toggleStyle(style)
            case .pause:     Toggle(isOn: false, intent: LiveSelectPauseIntent()) { EmptyView() }.toggleStyle(style)
            case .sets:      Toggle(isOn: false, intent: LiveSelectSetsIntent()) { EmptyView() }.toggleStyle(style)
            case .session:   Toggle(isOn: false, intent: LiveSelectSessionIntent()) { EmptyView() }.toggleStyle(style)
            }
        }
    }
}

/// A selector icon. Off: just the icon (filled volt if it's the view on screen). On — which
/// only happens in the instant after a tap, before the app's update — it also draws its
/// view's content over the data area, so the switch looks immediate.
private struct ViewSwitchStyle: ToggleStyle {
    let view: LiveView
    let s: S
    let slotX: CGFloat          // this icon's left edge within the pane
    let width: CGFloat          // the pane's width
    let dataH: CGFloat          // the data area's height (above the selector)
    let gap: CGFloat

    func icon(lit: Bool, enabled: Bool = true) -> some View {
        Image(systemName: view.icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(lit ? C.onVolt : (enabled ? C.mute : C.mute.opacity(0.3)))
            .frame(width: 22, height: 22)
            .background(Circle().fill(lit ? C.volt : Color.clear))
    }

    func makeBody(configuration: Configuration) -> some View {
        let current = s.view == view
        return icon(lit: configuration.isOn || current, enabled: s.available.contains(view))
            .overlay(alignment: .topLeading) {
                if configuration.isOn && !current {
                    ViewContent(s: s, view: view)
                        .frame(width: width, height: dataH, alignment: .topLeading)
                        .background(C.panel)
                        .offset(x: -slotX, y: -(dataH + gap))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Title + the view's data, sized to the data area. Used for the view on screen and for each
/// selector's instant preview, so the handover from preview to the app's update is seamless.
private struct ViewContent: View {
    let s: S
    let view: LiveView
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(view.title).font(.system(size: 8, weight: .heavy)).tracking(1.2).foregroundStyle(C.volt)
                if s.afterSet && view == s.view {
                    Text("AFTER SET").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(C.onVolt)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(C.volt))
                } else if s.liveSet == true && view.isSensor && s.available.contains(view) {
                    Text("LIVE").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(C.onVolt)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(C.volt))
                }
            }
            if s.available.contains(view) {
                ViewBody(s: s, view: view)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // No data yet: say what's coming (instead of a blank, or a dead button).
                Text(view.isSensor ? "Fills in rep by rep as you lift with your Watch."
                                   : "Appears once your Watch is tracking.")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(C.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// The right pane on its panel, outlined in a thin volt line.
private struct RightPanel: View {
    let x: Shown
    var body: some View {
        RightPane(x: x)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14).fill(C.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.volt, lineWidth: 1))
    }
}

// MARK: - The seven views

private struct ViewBody: View {
    let s: S
    var view: LiveView? = nil       // nil = the view in the state

    var body: some View {
        switch view ?? s.view {
        case .heartRate: heartRate
        case .speed:     bars(s.speeds, format: { String(format: "%.2f", $0) }, color: C.volt,
                              footer: "M/S" + ([s.speedLoss.map { " · −\($0)%" }, s.effort.map { " · \($0)" }].compactMap { $0 }.joined()))
        case .travel:    bars(s.travel, format: { num($0) }, color: C.blue,
                              footer: s.travelUnit.uppercased()
                                + (s.travel.isEmpty ? "" : " · avg \(num(s.travel.reduce(0, +) / Double(s.travel.count)))")
                                + (s.travelConsistency.map { " · \($0)% consistent" } ?? ""))
        case .tempo:     tempo
        case .pause:     pause
        case .sets:      sets
        case .session:   session
        }
    }

    private func footer(_ t: String) -> some View {
        Text(t).font(.system(size: 8, weight: .bold)).foregroundStyle(C.mute).lineLimit(1).minimumScaleFactor(0.7)
    }

    /// Heart rate: the graph is the view. Number + zone in a slim row above, the last
    /// five minutes across the full width with faint zone lines, "−5 min … now" below.
    private var heartRate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(s.hr.map(String.init) ?? "—").font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white).monospacedDigit()
                Text("BPM").font(.system(size: 7, weight: .heavy)).foregroundStyle(C.mute)
                if let z = s.hrZone, let p = s.hrPct {
                    Text("Z\(z) · \(p)%").font(.system(size: 9, weight: .heavy)).foregroundStyle(C.red)
                }
                Spacer(minLength: 0)
                if let pk = s.hrPeak {
                    Text("PEAK \(pk)").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(C.mute)
                }
            }
            HRGraph(values: s.hrSpark.map(Double.init), maxHR: s.hrMax.map(Double.init))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("−5 min"); Spacer(minLength: 0); Text("now")
            }
            .font(.system(size: 6.5, weight: .bold)).foregroundStyle(C.mute)
            .padding(.trailing, 12)                     // ends where the line ends, left of the zone labels
        }
    }

    private func bars(_ values: [Double], format: @escaping (Double) -> String, color: Color, footer f: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let mx = max(values.max() ?? 1, 0.0001)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 1) {
                        Text(format(v)).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        RoundedRectangle(cornerRadius: 2).fill(color.opacity(i == values.count - 1 ? 1 : 0.7))
                            .frame(height: max(3, 32 * CGFloat(v / mx)))
                        Text("\(i + 1)").font(.system(size: 6.5, weight: .semibold)).foregroundStyle(C.mute)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            footer(f)
        }
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 3) {
            let totals = s.ecc.indices.map { s.ecc[$0] + s.pause[$0] + s.con[$0] + s.top[$0] }
            let mx = max(totals.max() ?? 1, 0.1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(s.ecc.indices, id: \.self) { i in
                    VStack(spacing: 0) {
                        seg(s.top[i], mx, C.mute); seg(s.con[i], mx, C.volt)
                        seg(s.pause[i], mx, C.orange); seg(s.ecc[i], mx, C.blue)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            HStack(spacing: 5) {
                key("Down", C.blue); key("Pause", C.orange); key("Up", C.volt); key("Top", C.mute)
                Spacer(minLength: 0)
                if let t = s.tempo { Text(t).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
            }
        }
    }

    private func seg(_ v: Double, _ mx: Double, _ c: Color) -> some View {
        Rectangle().fill(c).frame(height: 40 * CGFloat(v / mx))
    }

    private func key(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 5, height: 5)
            Text(t).font(.system(size: 6.5)).foregroundStyle(C.mute)
        }
    }

    private var pause: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(s.pauseAvg.map { String(format: "%.1fs", $0) } ?? "—")
                    .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 0) {
                    Text("avg pause").font(.system(size: 8, weight: .bold)).foregroundStyle(C.mute)
                    if let t = s.pauseTarget { Text("target \(num(t))s").font(.system(size: 8, weight: .bold)).foregroundStyle(C.volt) }
                }
            }
            HStack(spacing: 3) {
                ForEach(Array(s.pause.enumerated()), id: \.offset) { _, p in
                    let hit = s.pauseTarget.map { p >= $0 - 0.2 } ?? (p > 0)
                    VStack(spacing: 2) {
                        Circle().fill(hit ? C.volt : C.orange).frame(width: 10, height: 10)
                        Text(String(format: "%.1f", p)).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let l = s.lastSet { footer(l) }
        }
    }

    private var sets: some View {
        VStack(spacing: 2) {
            ForEach(s.rows, id: \.n) { r in
                HStack(spacing: 5) {
                    Text("\(r.n)").font(.system(size: 8, weight: .heavy)).foregroundStyle(C.mute).frame(width: 8)
                    Text("\(r.tReps) × \(num(r.tWeight))").font(.system(size: 9)).foregroundStyle(C.mute)
                    Spacer(minLength: 2)
                    if let reps = r.reps {
                        Text("\(reps) × \(num(r.weight ?? r.tWeight))").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        Text(r.rpe.map { "@\(num($0))" } ?? "").font(.system(size: 8, weight: .heavy)).foregroundStyle(C.volt)
                            .frame(width: 22, alignment: .trailing)
                    } else {
                        Text(r.current ? "NOW" : "—").font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(r.current ? C.volt : C.mute)
                    }
                }
                .padding(.horizontal, 5).frame(height: 13)
                .background(RoundedRectangle(cornerRadius: 4).fill(r.current ? C.volt.opacity(0.14) : Color.clear))
            }
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                stat("\(s.exDone)/\(s.exTotal)", "EXERCISES")
                stat("\(s.setsDone)/\(s.setsTotal)", "SETS")
                stat(s.volume >= 10000 ? String(format: "%.1fk", Double(s.volume) / 1000) : "\(s.volume)", "\(s.unit.uppercased()) MOVED")
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(C.dim)
                    Capsule().fill(C.volt).frame(width: g.size.width * CGFloat(s.setsTotal > 0 ? Double(s.setsDone) / Double(s.setsTotal) : 0))
                }
            }
            .frame(height: 5)
            if let u = s.upNext { Text("Up next: \(u)").font(.system(size: 9, weight: .heavy)).foregroundStyle(C.volt).lineLimit(1) }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.system(size: 6.5, weight: .heavy)).tracking(0.4).foregroundStyle(C.mute).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Heart-rate graph: filled area under a line, faint lines at the zone boundaries (60/70/
/// 80/90% of max) that fall inside the visible range, the latest reading marked.
private struct HRGraph: View {
    let values: [Double]
    let maxHR: Double?
    private let gutter: CGFloat = 12          // right-hand column for the zone labels

    var body: some View {
        GeometryReader { g in
            if values.count >= 2, let lo0 = values.min(), let hi0 = values.max() {
                let lo = lo0 - 6, hi = hi0 + 6
                let span = max(hi - lo, 1)
                let plotW = g.size.width - gutter
                let pt: (Int, Double) -> CGPoint = { i, v in
                    CGPoint(x: plotW * CGFloat(i) / CGFloat(values.count - 1),
                            y: g.size.height * (1 - CGFloat((v - lo) / span)))
                }
                ZStack(alignment: .topLeading) {
                    // Zone boundaries in range (labels in a narrow column on the right,
                    // always inside the graph so they never reach the header above)
                    if let m = maxHR {
                        ForEach([0.6, 0.7, 0.8, 0.9], id: \.self) { f in
                            let bpm = m * f
                            if bpm > lo && bpm < hi {
                                let y = g.size.height * (1 - CGFloat((bpm - lo) / span))
                                Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width - gutter, y: y)) }
                                    .stroke(C.mute.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                                Text("Z\(Int(f * 10) - 4)").font(.system(size: 6, weight: .heavy)).foregroundStyle(C.mute.opacity(0.8))
                                    .position(x: g.size.width - gutter / 2, y: min(max(y, 4), g.size.height - 4))
                            }
                        }
                    }
                    // Area
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height))
                        for (i, v) in values.enumerated() { p.addLine(to: pt(i, v)) }
                        p.addLine(to: CGPoint(x: plotW, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [C.red.opacity(0.35), C.red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    // Line
                    Path { p in
                        for (i, v) in values.enumerated() {
                            if i == 0 { p.move(to: pt(i, v)) } else { p.addLine(to: pt(i, v)) }
                        }
                    }
                    .stroke(C.red, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    // Latest reading
                    let last = pt(values.count - 1, values[values.count - 1])
                    Circle().fill(C.red).frame(width: 5, height: 5).position(last)
                }
            } else {
                // Not enough readings yet: a flat baseline, so the space still reads as a graph.
                ZStack {
                    Path { p in p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2)) }
                        .stroke(C.red.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    Text("Collecting heart rate…").font(.system(size: 7.5, weight: .bold)).foregroundStyle(C.mute)
                        .padding(.horizontal, 4).background(C.panel)
                }
            }
        }
    }
}

// MARK: - Log a set: Reps · Weight · RPE, each with −/+ straddling the field's edges

private struct LogEditor: View {
    let x: Shown
    private var s: S { x.s }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("LOG SET \(s.editSet)").font(.system(size: 8, weight: .heavy)).tracking(1.2).foregroundStyle(C.volt)
                Spacer(minLength: 0)
                if s.editorAuto, let u = s.editorUntil, u > Date() {
                    (Text("closes in ") + Text(timerInterval: Date()...u, countsDown: true))
                        .font(.system(size: 8, weight: .bold)).monospacedDigit().foregroundStyle(C.mute)
                }
            }
            HStack(spacing: 3) {
                field("REPS", "\(s.dReps)", minus: LiveRepsDownIntent(), plus: LiveRepsUpIntent())
                field(s.unit.uppercased(), num(s.dWeight), minus: LiveWeightDownIntent(), plus: LiveWeightUpIntent())
                field("RPE", num(s.dRPE), minus: LiveRPEDownIntent(), plus: LiveRPEUpIntent())
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                instant(LiveLogCancelIntent(), x,
                        face: { on in pill("Cancel", filled: on) },
                        result: { CardPreview(card: x.card, right: x.afterCancel()) })
                instant(LiveLogCommitIntent(), x,
                        face: { _ in pill("✓ Save set \(s.editSet)", filled: true) },
                        result: { CardPreview(card: x.card, left: x.afterSave(), right: x.afterSave()) })
            }
        }
    }

    /// 70 wide: a 50-wide value box with 20-wide −/+ centred on its edges, leaving ~30 of
    /// clear space for the number (enough for "275" or "102.5").
    private func field<M: AppIntent, P: AppIntent>(_ label: String, _ value: String, minus: M, plus: P) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 7, weight: .heavy)).tracking(1).foregroundStyle(C.mute)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(C.dim)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.line, lineWidth: 1))
                    .frame(width: 50, height: 32)
                Text(value).font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).frame(width: 30)
                HStack(spacing: 0) {
                    stepper("minus", minus)
                    Spacer(minLength: 0)
                    stepper("plus", plus)
                }
                .frame(width: 70)
            }
            .frame(width: 70, height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepper<I: AppIntent>(_ icon: String, _ intent: I) -> some View {
        Button(intent: intent) {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(C.onVolt)
                .frame(width: 20, height: 20).background(Circle().fill(C.volt))
        }
        .buttonStyle(.plain)
    }
}
