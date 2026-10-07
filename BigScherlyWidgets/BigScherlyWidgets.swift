import WidgetKit
import SwiftUI
import AppIntents
import CoreText

// MARK: - Home & Lock Screen widgets
// Six widgets — Small, Medium, Large, and Lock Screen circle / rectangle / inline — each
// with a menu of what to show (long-press ▸ Edit Widget). They read the snapshot the app
// saves (WidgetSnapshot.swift) and roll over to the next day at midnight on their own.
// Tapping opens the matching screen; Start opens the workout; supplements tick in place.

/// The colours every Home Screen widget draws with, chosen per draw from your theme (sent in
/// the snapshot by the app) and the Home Screen's light/dark look — the same rules as the app:
///   accent       the accent as a FILL (Start, done days, ticks); onAccent = ink or white on it
///   accentText   accent as TEXT/ICONS (dark: readable accent · light: ink)
///   stroke       accent as a LINE (rings, bars, sparkline, today's outline). Light: the real
///                accent — plain grey for pale accents (Volt, Toxic, Ice, Amber) that vanish on white
///   label        section labels (light: the accent on a smoke pill, `pill`)
/// Lock Screen widgets don't use these — iOS draws those in one colour.
nonisolated struct WidgetPalette {
    var light = false, pill = false
    var card = Color(hex6: 0x010101), text = Color.white, mute = Color(hex6: 0x9C9C9F)
    var track = Color.white.opacity(0.12), line = Color.white.opacity(0.10)
    var planned = Color.white.opacity(0.35), rest = Color.white.opacity(0.16)
    var accent = Color(hex6: 0xEDFF3D), onAccent = Color(hex6: 0x111113)
    var accentText = Color(hex6: 0xEDFF3D), stroke = Color(hex6: 0xEDFF3D), label = Color(hex6: 0xEDFF3D)
    var highlight = Color(hex6: 0xEDFF3D).opacity(0.12)
    var blue = Color(hex6: 0x3D9BE0), orange = Color(hex6: 0xF2A03D), orangeText = Color(hex6: 0xF2A03D)

    static func make(_ look: WidgetSnapshot.Look?, light: Bool) -> WidgetPalette {
        let lk = look ?? .volt
        var p = WidgetPalette()
        p.accent = Color(hex6: lk.accent); p.onAccent = Color(hex6: lk.onAccent)
        if light {
            p.light = true; p.pill = true
            p.card = .white; p.text = Color(hex6: 0x111113); p.mute = Color(hex6: 0x6E6E73)
            p.track = Color.black.opacity(0.08); p.line = Color.black.opacity(0.08)
            p.planned = Color.black.opacity(0.30); p.rest = Color.black.opacity(0.16)
            p.accentText = Color(hex6: 0x111113); p.stroke = Color(hex6: lk.lightLine)
            p.label = Color(hex6: lk.lightHeader); p.highlight = Color.black.opacity(0.05)
            p.orange = Color(hex6: 0xD97D0F); p.orangeText = Color(hex6: 0xAC630C)
        } else {
            p.accentText = Color(hex6: lk.darkText); p.stroke = Color(hex6: lk.darkText)
            p.label = Color(hex6: lk.darkText); p.highlight = Color(hex6: lk.accent).opacity(0.12)
        }
        return p
    }
}

private enum W {
    /// Set at the top of every Home Screen widget draw (HomeView), before anything below reads it.
    nonisolated(unsafe) static var p = WidgetPalette()

    static func use(_ look: WidgetSnapshot.Look?, scheme: ColorScheme, mode: WidgetRenderingMode) {
        _ = fontsReady
        let light: Bool
        if mode != .fullColor { light = false }                 // tinted / clear: iOS recolours; draw the dark set
        else if let base = look?.base { light = base == "light" } // your Dark or Light theme
        else { light = scheme == .light }                        // System: follow the Home Screen
        p = WidgetPalette.make(look, light: light)
    }

    static var card: Color { p.card }
    static var text: Color { p.text }
    static var mute: Color { p.mute }
    static var line: Color { p.line }
    static var track: Color { p.track }
    static var planned: Color { p.planned }
    static var rest: Color { p.rest }
    static var accent: Color { p.accent }
    static var onAccent: Color { p.onAccent }
    static var accentText: Color { p.accentText }
    static var stroke: Color { p.stroke }
    static var label: Color { p.label }
    static var highlight: Color { p.highlight }
    static var blue: Color { p.blue }
    static var orange: Color { p.orange }
    static var orangeText: Color { p.orangeText }

    /// Big Shoulders Display Black ships inside the widget too (BigScherlyWidgets folder) and is
    /// registered once per widget process — the app's registration doesn't reach here.
    private static let fontsReady: Bool = {
        if let url = Bundle.main.url(forResource: "BigShouldersDisplay-Black", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()
}

/// The display face for titles and big numbers (falls back to the system font if missing).
private func disp(_ size: CGFloat) -> Font { .custom("BigShouldersDisplay-Black", size: size) }

private extension Color {
    init(hex6 h: UInt32) {
        self.init(.sRGB, red: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255,
                  blue: Double(h & 0xff) / 255, opacity: 1)
    }
}

private func openURL(_ tab: String) -> URL { URL(string: "bigscherly://open?tab=\(tab)")! }
private func sessionURL(_ id: String) -> URL {
    var c = URLComponents(); c.scheme = "bigscherly"; c.host = "session"
    c.queryItems = [URLQueryItem(name: "id", value: id)]
    return c.url ?? openURL("workouts")
}
private func kcalShort(_ k: Int) -> String { k >= 1000 ? String(format: "%.1fk", Double(k) / 1000) : "\(k)" }
private func num(_ x: Double) -> String {
    let v = WidgetShared.finite(x)
    return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
}
/// 0…1, and 0 for NaN/infinity (a NaN width makes an invalid frame).
private func unit(_ f: Double) -> CGFloat { f.isFinite ? CGFloat(max(0, min(f, 1))) : 0 }
private func dayLabel(_ d: Date, now: Date) -> String {
    let cal = WidgetSnapshot.calendar
    if cal.isDate(d, inSameDayAs: now) { return "Today" }
    if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow" }
    return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

// MARK: - What each widget can show (Edit Widget menus)

/// What the Home Screen widget shows. Each option adapts to the size you pick (or resize to).
nonisolated enum HomeKind: String, AppEnum {
    case today, exercises, macros, week, lifts, supplements, checkIn, month, coach
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "View" }
    static var caseDisplayRepresentations: [HomeKind: DisplayRepresentation] {
        [.today: "Today", .exercises: "Today's exercises", .macros: "Macros", .week: "This week & coming up",
         .lifts: "Lifts", .supplements: "Supplements", .checkIn: "Next check-in", .month: "This month",
         .coach: "Coach messages"]
    }

    var small: SmallKind {
        switch self {
        case .today, .exercises: return .today
        case .macros: return .macros
        case .week: return .week
        case .lifts: return .lift
        case .supplements: return .supplements
        case .checkIn: return .checkIn
        case .month: return .month
        case .coach: return .coach
        }
    }
    var medium: MediumKind {
        switch self {
        case .today: return .todayWeek
        case .exercises: return .exercises
        case .macros: return .macrosWeek
        case .week: return .week
        case .lifts: return .lifts
        case .month: return .month
        case .supplements: return .supplements
        case .checkIn: return .checkIn
        case .coach: return .coach
        }
    }
    var large: LargeKind {
        switch self {
        case .today, .supplements, .checkIn, .coach: return .dashboard
        case .exercises, .week: return .training
        case .macros: return .macros
        case .lifts: return .lifts
        case .month: return .progress
        }
    }
}

// The layouts behind each size (not menu options themselves).
nonisolated enum SmallKind { case today, macros, week, lift, supplements, checkIn, month, coach }
nonisolated enum MediumKind { case todayWeek, exercises, lifts, macrosWeek, upcoming, month, week, supplements, checkIn, coach }
nonisolated enum LargeKind { case dashboard, training, lifts, progress, macros }

nonisolated enum CircleKind: String, AppEnum {
    case week, sets, kcal, lift, supplements, checkIn
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "View" }
    static var caseDisplayRepresentations: [CircleKind: DisplayRepresentation] {
        [.week: "Week progress", .sets: "Today's sets", .kcal: "Calorie target", .lift: "A lift's est. 1RM",
         .supplements: "Supplements left", .checkIn: "Days to check-in"]
    }
}

nonisolated enum RectKind: String, AppEnum {
    case today, macros, week, lift, next, checkIn
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "View" }
    static var caseDisplayRepresentations: [RectKind: DisplayRepresentation] {
        [.today: "Today's plan", .macros: "Today's macros", .week: "Week strip", .lift: "Lift trend",
         .next: "Next workout", .checkIn: "Next check-in"]
    }
}

nonisolated enum InlineKind: String, AppEnum {
    case today, kcal, checkIn, week
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "View" }
    static var caseDisplayRepresentations: [InlineKind: DisplayRepresentation] {
        [.today: "Today's workout", .kcal: "Calorie target", .checkIn: "Next check-in", .week: "Week progress"]
    }
}

/// A lift you've trained, for the "A lift" options (listed from the app's latest snapshot).
nonisolated struct LiftEntity: AppEntity {
    var id: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Lift" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
    static var defaultQuery: LiftQuery { LiftQuery() }
}

nonisolated struct LiftQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LiftEntity] { identifiers.map { LiftEntity(id: $0) } }
    func suggestedEntities() async throws -> [LiftEntity] {
        (WidgetShared.load()?.lifts ?? []).map { LiftEntity(id: $0.name) }
    }
}

nonisolated struct HomeConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Big Scherly" }
    static var description: IntentDescription { "Choose what this widget shows. It adapts to any size." }
    @Parameter(title: "Show", default: .today) var kind: HomeKind
    @Parameter(title: "Lift (small size, “Lifts”)") var lift: LiftEntity?
    init() {}
}

nonisolated struct CircleConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Big Scherly" }
    static var description: IntentDescription { "Choose what this widget shows." }
    @Parameter(title: "Show", default: .week) var kind: CircleKind
    @Parameter(title: "Lift (for “A lift”)") var lift: LiftEntity?
    init() {}
}

nonisolated struct RectConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Big Scherly" }
    static var description: IntentDescription { "Choose what this widget shows." }
    @Parameter(title: "Show", default: .today) var kind: RectKind
    @Parameter(title: "Lift (for “Lift trend”)") var lift: LiftEntity?
    init() {}
}

nonisolated struct InlineConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Big Scherly" }
    static var description: IntentDescription { "Choose what this widget shows." }
    @Parameter(title: "Show", default: .today) var kind: InlineKind
    init() {}
}

/// Tick a supplement off right on the widget. Runs in the widget; the app adds it to your
/// log next time it opens.
nonisolated struct TickSupplementIntent: AppIntent {
    static var title: LocalizedStringResource { "Mark supplement taken" }
    static let isDiscoverable = false
    @Parameter(title: "Supplement") var supplementId: String
    init() {}
    init(_ id: String) { supplementId = id }
    func perform() async throws -> some IntentResult {
        WidgetShared.markTaken(supplementId)
        return .result()
    }
}

// MARK: - Timeline: now, then each of the next two midnights

nonisolated struct SnapEntry<C: WidgetConfigurationIntent>: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
    let config: C
    var placeholder = false          // iOS's grey loading skeleton (sample data, redacted)
}

nonisolated struct SnapProvider<C: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapEntry<C> {
        WidgetShared.diag("placeholder", "\(C.self) \(context.family)")     // DIAGNOSTIC
        return SnapEntry(date: Date(), snap: .sample, config: C(), placeholder: true)
    }
    func snapshot(for configuration: C, in context: Context) async -> SnapEntry<C> {
        WidgetShared.diag("snapshot", "\(C.self) \(context.family)\(context.isPreview ? " · gallery" : "")")   // DIAGNOSTIC
        return SnapEntry(date: Date(), snap: context.isPreview ? .sample : (WidgetShared.load() ?? .sample), config: configuration)
    }
    func timeline(for configuration: C, in context: Context) async -> Timeline<SnapEntry<C>> {
        WidgetShared.diag("timeline.start", "\(C.self) \(context.family)")            // DIAGNOSTIC
        let snap = WidgetShared.loadOrExplain()
        let cal = WidgetSnapshot.calendar
        let now = Date()
        let midnight = cal.startOfDay(for: now).addingTimeInterval(86_400)
        let dates = [now, midnight, midnight.addingTimeInterval(86_400)]
        WidgetShared.diag("timeline.done", "\(C.self) \(context.family) · \(snap.state.rawValue)")   // DIAGNOSTIC
        return Timeline(entries: dates.map { SnapEntry(date: $0, snap: snap, config: configuration) },
                        policy: .after(midnight.addingTimeInterval(2 * 86_400)))
    }
}

// MARK: - The six widgets

/// The Home Screen widget: small, medium or large (resize it in place), one "Show" menu.
struct BigScherlyHomeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "bst.home", intent: HomeConfig.self, provider: SnapProvider<HomeConfig>()) { e in
            HomeView(e: e)            // sets the palette, then its own background
        }
        .configurationDisplayName("Big Scherly")
        .description("Today, exercises, macros, your week, lifts, supplements, check-in, this month or coach — any size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HomeView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    let e: SnapEntry<HomeConfig>
    var body: some View {
        let s = e.snap, now = e.date, k = e.config.kind
        let _ = W.use(s.look, scheme: scheme, mode: mode)
        let _ = WidgetShared.diag(e.placeholder ? "drew.placeholder" : "drew.home",
                                  "\(family) · \(k.rawValue) · \(s.state.rawValue)")   // DIAGNOSTIC
        let card = W.card
        Group {
            switch family {
            case .systemMedium: MediumView(s: s, now: now, kind: k.medium)
            case .systemLarge:  LargeView(s: s, now: now, kind: k.large)
            default:            SmallView(s: s, now: now, kind: k.small, lift: e.config.lift?.id)
            }
        }
        .containerBackground(for: .widget) { card }
    }
}

struct BigScherlyCircleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "bst.circle", intent: CircleConfig.self, provider: SnapProvider<CircleConfig>()) { e in
            CircleView(e: e).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Big Scherly")
        .description("Week progress, today's sets, calories, a lift, supplements or check-in.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct BigScherlyRectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "bst.rect", intent: RectConfig.self, provider: SnapProvider<RectConfig>()) { e in
            RectView(e: e).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Big Scherly")
        .description("Today's plan, macros, your week, a lift, what's next or check-in.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct BigScherlyInlineWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "bst.inline", intent: InlineConfig.self, provider: SnapProvider<InlineConfig>()) { e in
            InlineView(e: e).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Big Scherly")
        .description("One line above the clock.")
        .supportedFamilies([.accessoryInline])
    }
}

// MARK: - Building blocks

private struct Label8: View {
    let text: String
    var color: Color = W.label
    var body: some View {
        if W.p.pill {
            Text(text).font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundStyle(color).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 33 / 255, opacity: 0.88)))
                .widgetAccentable()
        } else {
            Text(text).font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(color).lineLimit(1)
                .widgetAccentable()
        }
    }
}

private struct Ring<Inner: View>: View {
    let frac: Double
    var width: CGFloat = 6
    var color: Color = W.stroke
    @ViewBuilder var inner: Inner
    var body: some View {
        ZStack {
            Circle().stroke(W.track, lineWidth: width)
            Circle().trim(from: 0, to: unit(frac))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            inner
        }
    }
}

private struct Bar: View {
    let frac: Double
    var color: Color = W.stroke
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(W.track)
                Capsule().fill(color).frame(width: g.size.width * unit(frac)).widgetAccentable()
            }
        }
        .frame(height: height)
    }
}

private struct Spark: View {
    let values: [Double]
    var color: Color = W.stroke
    var body: some View {
        let values = self.values.filter { $0.isFinite }
        GeometryReader { g in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 0.0001)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: g.size.height * (1 - CGFloat((v - lo) / span)) * 0.9 + g.size.height * 0.05)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .widgetAccentable()
            }
        }
    }
}

/// M T W T F S S — filled = done, outlined = planned/today, orange = missed, dashed = rest.
private struct WeekStrip: View {
    let snap: WidgetSnapshot
    let now: Date
    var size: CGFloat = 16
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(snap.week(of: now).enumerated()), id: \.offset) { i, d in
                let st = d.day.map { snap.status(of: $0, at: now) } ?? .rest
                let isToday = WidgetSnapshot.calendar.isDate(d.date, inSameDayAs: now)
                VStack(spacing: 3) {
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(isToday ? W.text : W.mute)
                    ZStack {
                        switch st {
                        case .done:
                            Circle().fill(W.accent).widgetAccentable()
                            Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(W.onAccent)
                        case .today:
                            Circle().stroke(W.stroke, lineWidth: 2).widgetAccentable()
                        case .planned:
                            Circle().stroke(W.planned, lineWidth: 1.5)
                        case .missed:
                            Circle().stroke(W.orange, lineWidth: 1.5)
                        case .rest:
                            Circle().stroke(W.rest, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                        }
                    }
                    .frame(width: size, height: size)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StartPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill").font(.system(size: 10, weight: .heavy))
            Text("Start").font(.system(size: 12, weight: .heavy))
        }
        .foregroundStyle(W.onAccent)
        .frame(maxWidth: .infinity).frame(height: 28)
        .background(Capsule().fill(W.accent).widgetAccentable())
    }
}

private struct StateMessage: View {
    let snap: WidgetSnapshot
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label8(text: "BIG SCHERLY")
            Text(stateText(snap.state))
                .font(.system(size: compact ? 11 : 13, weight: .bold)).foregroundStyle(W.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(openURL("home"))
    }
}

private func stateText(_ st: WidgetSnapshot.State) -> String {
    switch st {
    case .coach: return "Widgets show client training."
    case .loggedOut: return "Signed out — open Big Scherly to sign in."
    case .waiting: return "Open Big Scherly once to load your data."
    case .notConnected: return "Can't reach the app's data — the widget target needs App Group \(WidgetShared.knownGroups[0]) (or \(WidgetShared.knownGroups[1]))."
    case .client: return ""
    }
}

private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(value).font(disp(22)).foregroundStyle(W.text)
            .lineLimit(1).minimumScaleFactor(0.6)
        Text(label).font(.system(size: 7.5, weight: .heavy)).tracking(0.6).foregroundStyle(W.mute).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Shared blocks used by several sizes

private struct TodayBlock: View {
    let snap: WidgetSnapshot
    let now: Date
    var startLink = true
    var body: some View {
        if let w = snap.day(now)?.workout {
            VStack(alignment: .leading, spacing: 3) {
                Label8(text: w.completed ? "TODAY · DONE" : "TODAY")
                Text(w.title.uppercased()).font(disp(20)).foregroundStyle(W.text).lineLimit(2)
                Text("\(w.exercises.count) exercises · \(w.setsDone)/\(w.setsTotal) sets")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(W.mute).lineLimit(1)
                Spacer(minLength: 4)
                Bar(frac: Double(w.setsDone) / Double(max(w.setsTotal, 1)), height: 6)
                if !w.completed {
                    if startLink { Link(destination: sessionURL(w.id)) { StartPill() } } else { StartPill() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Label8(text: "TODAY")
                Text("REST DAY").font(disp(20)).foregroundStyle(W.text)
                if let n = snap.upcoming(from: now, limit: 1).first {
                    Spacer(minLength: 4)
                    Text("Next: \(n.workout.title)").font(.system(size: 11, weight: .bold)).foregroundStyle(W.text).lineLimit(2)
                    Text(dayLabel(n.date, now: now)).font(.system(size: 10, weight: .semibold)).foregroundStyle(W.accentText)
                }
            }
        }
    }
}

private struct MacroBlock: View {
    let m: WidgetSnapshot.Macros
    var big: CGFloat = 26
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(m.kcal.formatted()).font(disp(big * 1.15)).foregroundStyle(W.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("kcal").font(.system(size: 9, weight: .heavy)).foregroundStyle(W.mute)
            }
            let total = Double(max(m.protein * 4 + m.carbs * 4 + m.fat * 9, 1))
            row("P", m.protein, Double(m.protein * 4) / total, W.stroke)
            row("C", m.carbs, Double(m.carbs * 4) / total, W.blue)
            row("F", m.fat, Double(m.fat * 9) / total, W.orange)
        }
    }
    private func row(_ k: String, _ g: Int, _ share: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Text(k).font(.system(size: 8, weight: .heavy)).foregroundStyle(W.mute).frame(width: 8)
            Bar(frac: share * 1.6, color: c, height: 4)
            Text("\(g)g").font(.system(size: 9, weight: .bold)).foregroundStyle(W.text).frame(width: 34, alignment: .trailing)
        }
    }
}

private struct ExerciseList: View {
    let w: WidgetSnapshot.Workout
    var limit = 5
    var body: some View {
        let cur = w.current?.name
        VStack(spacing: 3) {
            ForEach(w.exercises.prefix(limit)) { ex in
                HStack(spacing: 6) {
                    Text(ex.name).font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(ex.done < ex.total ? W.text : W.mute).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(ex.done)/\(ex.total)").font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(ex.done == ex.total ? W.accentText : (ex.name == cur ? W.text : W.mute))
                    Bar(frac: Double(ex.done) / Double(max(ex.total, 1)), height: 4).frame(width: 40)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(ex.name == cur ? W.highlight : Color.clear))
            }
            if w.exercises.count > limit {
                Text("+\(w.exercises.count - limit) more").font(.system(size: 9, weight: .semibold)).foregroundStyle(W.mute)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            }
        }
    }
}

private struct LiftRow: View {
    let l: WidgetSnapshot.Lift
    let unit: String
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name).font(.system(size: 11.5, weight: .heavy)).foregroundStyle(W.text).lineLimit(1)
                Text((l.speed.map { String(format: "%.2f m/s · ", $0) } ?? "") + "\(l.sessions) sessions")
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(W.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            Spark(values: l.points).frame(width: 60, height: 20)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(num(l.e1rm)) \(unit)").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(W.text)
                Text(change(l.change)).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(l.change >= 0 ? W.accentText : W.orangeText)
            }
            .frame(width: 66, alignment: .trailing)
        }
    }
}

private func change(_ c: Double) -> String { c == 0 ? "steady" : "\(c > 0 ? "▲" : "▼") \(num(abs(c)))" }

// MARK: - Small

private struct SmallView: View {
    let s: WidgetSnapshot
    let now: Date
    let kind: SmallKind
    var lift: String? = nil
    var body: some View {
        if s.state != .client { StateMessage(snap: s) }
        else {
            switch kind {
            case .today:
                if let w = s.day(now)?.workout {
                    VStack(alignment: .leading, spacing: 3) {
                        Label8(text: w.completed ? "TODAY · DONE" : "TODAY")
                        Text(w.title.uppercased()).font(disp(19)).foregroundStyle(W.text).lineLimit(2)
                        Spacer(minLength: 2)
                        HStack(spacing: 8) {
                            Ring(frac: Double(w.setsDone) / Double(max(w.setsTotal, 1))) {
                                Text("\(w.setsDone)/\(w.setsTotal)").font(.system(size: 10, weight: .heavy)).foregroundStyle(W.text)
                            }
                            .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("sets").font(.system(size: 9, weight: .bold)).foregroundStyle(W.mute)
                                Text(w.current?.name ?? "All logged").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(W.text).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 2)
                        if !w.completed { StartPill() }
                    }
                    .widgetURL(w.completed ? openURL("workouts") : sessionURL(w.id))
                } else {
                    TodayBlock(snap: s, now: now, startLink: false).widgetURL(openURL("workouts"))
                }
            case .macros:
                if let m = s.day(now)?.macros {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Label8(text: "MACROS"); Spacer(); Text(m.training ? "Training" : "Rest day").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(W.mute) }
                        Spacer(minLength: 0)
                        MacroBlock(m: m)
                        if let n = m.note { Text(n).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(W.accentText).lineLimit(1) }
                    }
                    .widgetURL(openURL("macros"))
                } else {
                    VStack(alignment: .leading) { Label8(text: "MACROS"); Text("No macro plan for today yet.").font(.system(size: 12, weight: .bold)).foregroundStyle(W.text) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).widgetURL(openURL("macros"))
                }
            case .week:
                let p = s.weekProgress(now)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Label8(text: "THIS WEEK"); Spacer(); Text("\(p.done) of \(p.planned)").font(.system(size: 11, weight: .heavy)).foregroundStyle(W.text) }
                    Spacer(minLength: 0)
                    WeekStrip(snap: s, now: now, size: 17)
                    Spacer(minLength: 0)
                    if let n = s.upcoming(from: now, limit: 1).first {
                        Text("Next: \(n.workout.title)").font(.system(size: 11, weight: .heavy)).foregroundStyle(W.text).lineLimit(1)
                        Text(dayLabel(n.date, now: now)).font(.system(size: 9.5, weight: .bold)).foregroundStyle(W.accentText)
                    } else {
                        Text("Nothing else planned this week").font(.system(size: 10, weight: .bold)).foregroundStyle(W.mute)
                    }
                }
                .widgetURL(openURL("workouts"))
            case .lift:
                if let l = s.lift(named: lift) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label8(text: l.name.uppercased())
                        Text("est. 1RM").font(.system(size: 8.5, weight: .bold)).foregroundStyle(W.mute)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(num(l.e1rm)).font(disp(40)).foregroundStyle(W.text)
                            Text(s.unit).font(.system(size: 10, weight: .heavy)).foregroundStyle(W.mute)
                        }
                        Text("\(change(l.change)) · 8 weeks").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(l.change >= 0 ? W.accentText : W.orangeText)
                        Spark(values: l.points).frame(maxHeight: .infinity)
                    }
                    .widgetURL(openURL("stats"))
                } else {
                    VStack(alignment: .leading) { Label8(text: "LIFT"); Text("Log a lift to see its trend here.").font(.system(size: 12, weight: .bold)).foregroundStyle(W.text) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).widgetURL(openURL("stats"))
                }
            case .supplements:
                let list = s.supplements(at: now)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Label8(text: "SUPPLEMENTS"); Spacer(); Text("\(list.filter { $0.taken }.count)/\(list.count)").font(.system(size: 11, weight: .heavy)).foregroundStyle(W.text) }
                    if list.isEmpty {
                        Text("No supplements set up.").font(.system(size: 11, weight: .bold)).foregroundStyle(W.mute)
                    }
                    ForEach(list.prefix(4)) { sp in
                        Button(intent: TickSupplementIntent(sp.id)) {
                            HStack(spacing: 7) {
                                ZStack {
                                    Circle().fill(sp.taken ? W.accent : Color.clear).widgetAccentable()
                                    Circle().stroke(sp.taken ? W.accent : W.planned, lineWidth: 1.5)
                                    if sp.taken { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(W.onAccent) }
                                }
                                .frame(width: 17, height: 17)
                                Text(sp.name).font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(sp.taken ? W.mute : W.text).strikethrough(sp.taken).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(sp.taken)
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("supplements"))
            case .checkIn:
                VStack(alignment: .leading, spacing: 3) {
                    Label8(text: "CHECK-IN")
                    Spacer(minLength: 0)
                    if let d = s.daysToCheckIn(now) {
                        Text(d > 0 ? "\(d)" : (d == 0 ? "Today" : "\(-d)"))
                            .font(disp(d == 0 ? 34 : 50)).foregroundStyle(d < 0 ? W.orangeText : W.text)
                        Text(d > 0 ? "day\(d == 1 ? "" : "s") to go" : (d == 0 ? "weekly check-in due" : "day\(d == -1 ? "" : "s") overdue"))
                            .font(.system(size: 10, weight: .heavy)).foregroundStyle(d < 0 ? W.orangeText : W.accentText)
                        Spacer(minLength: 0)
                        if let l = s.lastCheckIn { Text("Last: \(l.formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 9, weight: .semibold)).foregroundStyle(W.mute) }
                    } else {
                        Text("Send your first check-in").font(.system(size: 13, weight: .heavy)).foregroundStyle(W.text)
                        Spacer(minLength: 0)
                    }
                }
                .widgetURL(openURL("checkins"))
            case .month:
                VStack(alignment: .leading, spacing: 8) {
                    Label8(text: now.formatted(.dateTime.month(.wide)).uppercased())
                    Spacer(minLength: 0)
                    HStack { stat("\(s.month.sessions)", "SESSIONS"); stat("\(s.month.sets)", "SETS") }
                    HStack { stat(kcalShort(s.month.volume), "\(s.unit.uppercased()) MOVED"); stat("\(s.month.prs)", "PRS") }
                }
                .widgetURL(openURL("stats"))
            case .coach:
                VStack(alignment: .leading, spacing: 3) {
                    Label8(text: "COACH")
                    Spacer(minLength: 0)
                    if s.unreadCoach > 0 {
                        Text("\(s.unreadCoach)").font(disp(50)).foregroundStyle(W.text)
                        Text("new message\(s.unreadCoach == 1 ? "" : "s")").font(.system(size: 10, weight: .heavy)).foregroundStyle(W.accentText)
                    } else {
                        Image(systemName: "checkmark.message.fill").font(.system(size: 26)).foregroundStyle(W.accentText).widgetAccentable()
                        Text("All caught up").font(.system(size: 12, weight: .heavy)).foregroundStyle(W.text)
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("chat"))
            }
        }
    }
}

// MARK: - Medium

private struct MediumView: View {
    let s: WidgetSnapshot
    let now: Date
    let kind: MediumKind
    var body: some View {
        if s.state != .client { StateMessage(snap: s) }
        else {
            switch kind {
            case .todayWeek:
                HStack(spacing: 12) {
                    TodayBlock(snap: s, now: now).frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(W.line).frame(width: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        let p = s.weekProgress(now)
                        HStack { Label8(text: "WEEK"); Spacer(); Text("\(p.done) of \(p.planned)").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(W.text) }
                        WeekStrip(snap: s, now: now, size: 14)
                        Spacer(minLength: 0)
                        if let m = s.day(now)?.macros {
                            HStack { Label8(text: "MACROS"); Spacer(); Text("\(m.kcal.formatted()) kcal").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(W.text) }
                            Text("P \(m.protein) · C \(m.carbs) · F \(m.fat)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(W.mute)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .widgetURL(openURL("workouts"))
            case .exercises:
                if let w = s.day(now)?.workout {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Label8(text: "TODAY · \(w.setsDone)/\(w.setsTotal) SETS")
                                Text(w.title.uppercased()).font(disp(18)).foregroundStyle(W.text).lineLimit(1)
                            }
                            Spacer()
                            if !w.completed { Link(destination: sessionURL(w.id)) { StartPill().frame(width: 74) } }
                        }
                        ExerciseList(w: w, limit: 4)
                        Spacer(minLength: 0)
                    }
                    .widgetURL(openURL("workouts"))
                } else {
                    TodayBlock(snap: s, now: now).widgetURL(openURL("workouts"))
                }
            case .lifts:
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Label8(text: "LIFT TRENDS"); Spacer(); Text("est. 1RM · 8 weeks").font(.system(size: 8.5, weight: .bold)).foregroundStyle(W.mute) }
                    if s.lifts.isEmpty { Text("Log a few lifts to see trends here.").font(.system(size: 12, weight: .bold)).foregroundStyle(W.text) }
                    ForEach(s.lifts.prefix(3)) { l in LiftRow(l: l, unit: s.unit) }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("stats"))
            case .macrosWeek:
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label8(text: s.day(now)?.macros?.training == false ? "TODAY · REST" : "TODAY · TRAINING")
                        if let m = s.day(now)?.macros { MacroBlock(m: m, big: 22) } else { Text("No plan").foregroundStyle(W.mute) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Label8(text: "CALORIES THIS WEEK")
                        let week = s.week(of: now)
                        let maxK = Double(max(week.compactMap { $0.day?.macros?.kcal }.max() ?? 1, 1))
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(Array(week.enumerated()), id: \.offset) { i, d in
                                let m = d.day?.macros
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(m?.training == true ? W.stroke : W.rest)
                                        .frame(height: max(4, 70 * CGFloat(Double(m?.kcal ?? 0) / maxK)))
                                        .widgetAccentable()
                                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.system(size: 8, weight: .heavy))
                                        .foregroundStyle(WidgetSnapshot.calendar.isDate(d.date, inSameDayAs: now) ? W.text : W.mute)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        Text("highlighted = training day").font(.system(size: 8, weight: .semibold)).foregroundStyle(W.mute)
                    }
                    .frame(maxWidth: .infinity)
                }
                .widgetURL(openURL("macros"))
            case .upcoming:
                VStack(alignment: .leading, spacing: 6) {
                    Label8(text: "COMING UP")
                    let next = s.upcoming(from: now, limit: 3)
                    if next.isEmpty { Text("Nothing planned yet.").font(.system(size: 12, weight: .bold)).foregroundStyle(W.text) }
                    ForEach(Array(next.enumerated()), id: \.offset) { _, n in
                        HStack(spacing: 10) {
                            Text(dayLabel(n.date, now: now)).font(.system(size: 10, weight: .heavy)).foregroundStyle(W.accentText)
                                .frame(width: 78, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                            Text(n.workout.title).font(.system(size: 12, weight: .heavy)).foregroundStyle(W.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(n.workout.exercises.count) ex").font(.system(size: 9.5, weight: .bold)).foregroundStyle(W.mute)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("workouts"))
            case .month:
                VStack(alignment: .leading, spacing: 8) {
                    Label8(text: now.formatted(.dateTime.month(.wide)).uppercased())
                    HStack {
                        stat("\(s.month.sessions)", "SESSIONS"); stat("\(s.month.sets)", "SETS")
                        stat(kcalShort(s.month.volume), "\(s.unit.uppercased()) MOVED"); stat("\(s.month.prs)", "PRS")
                    }
                    Spacer(minLength: 0)
                    WeekStrip(snap: s, now: now, size: 15)
                }
                .widgetURL(openURL("stats"))
            case .week:
                VStack(alignment: .leading, spacing: 6) {
                    let p = s.weekProgress(now)
                    HStack { Label8(text: "THIS WEEK"); Spacer(); Text("\(p.done) of \(p.planned) sessions").font(.system(size: 10, weight: .heavy)).foregroundStyle(W.text) }
                    WeekStrip(snap: s, now: now, size: 16)
                    Spacer(minLength: 0)
                    let next = s.upcoming(from: now, limit: 2)
                    if next.isEmpty { Text("Nothing else planned yet").font(.system(size: 11, weight: .bold)).foregroundStyle(W.mute) }
                    ForEach(Array(next.enumerated()), id: \.offset) { _, n in
                        HStack(spacing: 10) {
                            Text(dayLabel(n.date, now: now)).font(.system(size: 10, weight: .heavy)).foregroundStyle(W.accentText)
                                .frame(width: 78, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                            Text(n.workout.title).font(.system(size: 12, weight: .heavy)).foregroundStyle(W.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .widgetURL(openURL("workouts"))
            case .supplements:
                SmallView(s: s, now: now, kind: .supplements)
            case .checkIn:
                SmallView(s: s, now: now, kind: .checkIn)
            case .coach:
                SmallView(s: s, now: now, kind: .coach)
            }
        }
    }
}

// MARK: - Large

private struct LargeView: View {
    let s: WidgetSnapshot
    let now: Date
    let kind: LargeKind
    var body: some View {
        if s.state != .client { StateMessage(snap: s) }
        else {
            switch kind {
            case .dashboard:
                VStack(alignment: .leading, spacing: 8) {
                    todayHeader(s, now)
                    if let w = s.day(now)?.workout { ExerciseList(w: w, limit: 6) }
                    Spacer(minLength: 0)
                    Rectangle().fill(W.line).frame(height: 1)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            let p = s.weekProgress(now)
                            HStack { Label8(text: "WEEK"); Spacer(); Text("\(p.done) of \(p.planned)").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(W.text) }
                            WeekStrip(snap: s, now: now, size: 14)
                        }
                        Rectangle().fill(W.line).frame(width: 1)
                        if let m = s.day(now)?.macros { MacroBlock(m: m, big: 18).frame(width: 128) }
                    }
                    .frame(height: 64)
                    Rectangle().fill(W.line).frame(height: 1)
                    footer(s, now)
                }
                .widgetURL(openURL("home"))
            case .training:
                VStack(alignment: .leading, spacing: 8) {
                    todayHeader(s, now)
                    if let w = s.day(now)?.workout { ExerciseList(w: w, limit: 5) }
                    Rectangle().fill(W.line).frame(height: 1)
                    Label8(text: "COMING UP")
                    ForEach(Array(s.upcoming(from: now, limit: 4).filter { !WidgetSnapshot.calendar.isDate($0.date, inSameDayAs: now) }.prefix(3).enumerated()), id: \.offset) { _, n in
                        HStack(spacing: 8) {
                            Text(dayLabel(n.date, now: now)).font(.system(size: 10, weight: .heavy)).foregroundStyle(W.accentText).frame(width: 82, alignment: .leading)
                            Text(n.workout.title).font(.system(size: 11.5, weight: .heavy)).foregroundStyle(W.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                    WeekStrip(snap: s, now: now, size: 15)
                }
                .widgetURL(openURL("workouts"))
            case .lifts:
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Label8(text: "LIFT TRENDS"); Spacer(); Text("est. 1RM · change over 8 weeks").font(.system(size: 8.5, weight: .bold)).foregroundStyle(W.mute) }
                    if s.lifts.isEmpty { Text("Log a few lifts to see trends here.").font(.system(size: 13, weight: .bold)).foregroundStyle(W.text) }
                    ForEach(s.lifts.prefix(6)) { l in
                        LiftRow(l: l, unit: s.unit)
                        if l.id != s.lifts.prefix(6).last?.id { Rectangle().fill(W.line).frame(height: 1) }
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("stats"))
            case .progress:
                VStack(alignment: .leading, spacing: 8) {
                    Label8(text: now.formatted(.dateTime.month(.wide)).uppercased())
                    HStack {
                        stat("\(s.month.sessions)", "SESSIONS"); stat("\(s.month.sets)", "SETS")
                        stat(kcalShort(s.month.volume), "\(s.unit.uppercased()) MOVED"); stat("\(s.month.prs)", "PRS")
                    }
                    Rectangle().fill(W.line).frame(height: 1)
                    Label8(text: "TOP LIFTS")
                    ForEach(s.lifts.prefix(3)) { l in LiftRow(l: l, unit: s.unit) }
                    Spacer(minLength: 0)
                    Rectangle().fill(W.line).frame(height: 1)
                    footer(s, now)
                }
                .widgetURL(openURL("stats"))
            case .macros:
                VStack(alignment: .leading, spacing: 8) {
                    let today = s.day(now)?.macros
                    Label8(text: today?.training == false ? "MACROS · TODAY · REST DAY" : "MACROS · TODAY · TRAINING DAY")
                    if let m = today {
                        MacroBlock(m: m, big: 30)
                        if let n = m.note { Text(n).font(.system(size: 10, weight: .bold)).foregroundStyle(W.accentText).lineLimit(1) }
                    } else {
                        Text("No macro plan for today yet.").font(.system(size: 13, weight: .bold)).foregroundStyle(W.text)
                    }
                    Rectangle().fill(W.line).frame(height: 1)
                    Label8(text: "THIS WEEK")
                    VStack(spacing: 3) {
                        ForEach(Array(s.week(of: now).enumerated()), id: \.offset) { _, d in
                            let m = d.day?.macros
                            let isToday = WidgetSnapshot.calendar.isDate(d.date, inSameDayAs: now)
                            HStack(spacing: 8) {
                                Text(d.date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10.5, weight: .heavy))
                                    .foregroundStyle(isToday ? W.text : W.mute).frame(width: 30, alignment: .leading)
                                Text(m == nil ? "—" : (m!.training ? "Training" : "Rest"))
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(m?.training == true ? W.onAccent : W.mute)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(m?.training == true ? W.accent : W.track))
                                    .frame(width: 62, alignment: .leading)
                                Text(m.map { "\($0.kcal.formatted()) kcal" } ?? "")
                                    .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(W.text)
                                Spacer(minLength: 4)
                                Text(m.map { "P \($0.protein) · C \($0.carbs) · F \($0.fat)" } ?? "")
                                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(W.mute).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7).fill(isToday ? W.highlight : Color.clear))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .widgetURL(openURL("macros"))
            }
        }
    }

    @ViewBuilder
    private func todayHeader(_ s: WidgetSnapshot, _ now: Date) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Label8(text: "TODAY · \(now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())")
                Text((s.day(now)?.workout?.title ?? "Rest day").uppercased()).font(disp(22)).foregroundStyle(W.text).lineLimit(1)
            }
            Spacer()
            if let w = s.day(now)?.workout, !w.completed {
                Link(destination: sessionURL(w.id)) { StartPill().frame(width: 80) }
            }
        }
    }

    private func footer(_ s: WidgetSnapshot, _ now: Date) -> some View {
        HStack(spacing: 4) {
            item("calendar", s.daysToCheckIn(now).map { $0 > 0 ? "Check-in in \($0)d" : ($0 == 0 ? "Check-in today" : "Check-in overdue") } ?? "No check-ins yet")
            Spacer(minLength: 2)
            item("trophy.fill", s.latest ?? "No awards yet")
            Spacer(minLength: 2)
            item("bubble.left.fill", s.unreadCoach > 0 ? "\(s.unreadCoach) from coach" : "No new messages")
        }
    }

    private func item(_ icon: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(W.accentText).widgetAccentable()
            Text(t).font(.system(size: 9.5, weight: .bold)).foregroundStyle(W.text).lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

// MARK: - Lock Screen: circle

private struct CircleView: View {
    let e: SnapEntry<CircleConfig>
    var body: some View {
        let s = e.snap, now = e.date
        let _ = e.placeholder ? () : WidgetShared.diag("drew.lock", "circle · \(e.config.kind.rawValue)")   // DIAGNOSTIC
        Group {
            if s.state != .client {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "dumbbell.fill") }
            } else {
                switch e.config.kind {
                case .week:
                    let p = s.weekProgress(now)
                    Gauge(value: Double(p.done), in: 0...Double(max(p.planned, 1))) { Text("WEEK") } currentValueLabel: {
                        Text("\(p.done)/\(p.planned)")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                case .sets:
                    let w = s.day(now)?.workout
                    Gauge(value: Double(w?.setsDone ?? 0), in: 0...Double(max(w?.setsTotal ?? 1, 1))) { Text("SETS") } currentValueLabel: {
                        Text(w.map { "\($0.setsDone)" } ?? "Rest")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                case .kcal:
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Text(kcalShort(s.day(now)?.macros?.kcal ?? 0)).font(.system(size: 15, weight: .heavy, design: .rounded))
                            Text(s.day(now)?.macros?.training == true ? "TRAIN" : "KCAL").font(.system(size: 7, weight: .heavy))
                        }
                    }
                case .lift:
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Text(s.lift(named: e.config.lift?.id).map { num($0.e1rm) } ?? "—").font(.system(size: 15, weight: .heavy, design: .rounded))
                            Text("1RM").font(.system(size: 7, weight: .heavy))
                        }
                    }
                case .supplements:
                    let list = s.supplements(at: now)
                    Gauge(value: Double(list.filter { $0.taken }.count), in: 0...Double(max(list.count, 1))) { Text("SUPPS") } currentValueLabel: {
                        Image(systemName: "pills.fill")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                case .checkIn:
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            let d = s.daysToCheckIn(now)
                            Text(d.map { $0 <= 0 ? "Due" : "\($0)d" } ?? "—").font(.system(size: 15, weight: .heavy, design: .rounded))
                            Text("CHECK").font(.system(size: 7, weight: .heavy))
                        }
                    }
                }
            }
        }
        .widgetURL(openURL(e.config.kind == .kcal ? "macros" : e.config.kind == .checkIn ? "checkins"
                           : e.config.kind == .supplements ? "supplements" : e.config.kind == .lift ? "stats" : "workouts"))
    }
}

// MARK: - Lock Screen: rectangle

private struct RectView: View {
    let e: SnapEntry<RectConfig>
    var body: some View {
        let s = e.snap, now = e.date
        let _ = e.placeholder ? () : WidgetShared.diag("drew.lock", "rectangle · \(e.config.kind.rawValue)")   // DIAGNOSTIC
        VStack(alignment: .leading, spacing: 2) {
            if s.state != .client {
                Text("Big Scherly").font(.system(size: 13, weight: .heavy))
                Text(s.state == .notConnected ? "Widget needs the App Group" : s.state == .waiting ? "Open the app to load"
                     : s.state == .coach ? "For client accounts" : "Open the app to sign in").font(.system(size: 11))
            } else {
                switch e.config.kind {
                case .today:
                    if let w = s.day(now)?.workout {
                        Label(w.completed ? "TODAY · DONE" : "TODAY", systemImage: "dumbbell.fill").font(.system(size: 10, weight: .heavy))
                        Text(w.title).font(.system(size: 13, weight: .heavy)).lineLimit(1)
                        HStack(spacing: 6) {
                            ProgressView(value: Double(w.setsDone), total: Double(max(w.setsTotal, 1)))
                            Text("\(w.setsDone)/\(w.setsTotal)").font(.system(size: 10, weight: .heavy))
                        }
                    } else {
                        Label("TODAY", systemImage: "moon.zzz.fill").font(.system(size: 10, weight: .heavy))
                        Text("Rest day").font(.system(size: 13, weight: .heavy))
                        if let n = s.upcoming(from: now, limit: 1).first {
                            Text("Next: \(n.workout.title)").font(.system(size: 11)).lineLimit(1)
                        }
                    }
                case .macros:
                    if let m = s.day(now)?.macros {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(m.kcal.formatted()).font(.system(size: 16, weight: .heavy, design: .rounded))
                            Text(m.training ? "kcal · training" : "kcal · rest").font(.system(size: 10, weight: .bold))
                        }
                        Text("P \(m.protein)g · C \(m.carbs)g · F \(m.fat)g").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    } else {
                        Text("No macro plan today").font(.system(size: 12, weight: .bold))
                    }
                case .week:
                    let p = s.weekProgress(now)
                    Text("THIS WEEK · \(p.done) OF \(p.planned)").font(.system(size: 10, weight: .heavy))
                    HStack(spacing: 0) {
                        ForEach(Array(s.week(of: now).enumerated()), id: \.offset) { i, d in
                            let st = d.day.map { s.status(of: $0, at: now) } ?? .rest
                            VStack(spacing: 2) {
                                Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.system(size: 8, weight: .heavy))
                                Image(systemName: st == .done ? "checkmark.circle.fill" : st == .missed ? "xmark.circle"
                                      : st == .rest ? "circle.dotted" : (st == .today ? "circle.circle" : "circle"))
                                    .font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                case .lift:
                    if let l = s.lift(named: e.config.lift?.id) {
                        Text(l.name.uppercased()).font(.system(size: 10, weight: .heavy)).lineLimit(1)
                        HStack(alignment: .bottom, spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(num(l.e1rm)) \(s.unit)").font(.system(size: 15, weight: .heavy, design: .rounded))
                                Text(change(l.change)).font(.system(size: 9, weight: .heavy))
                            }
                            Spark(values: l.points, color: .white).frame(height: 24)
                        }
                    } else {
                        Text("Log a lift to see it here").font(.system(size: 12, weight: .bold))
                    }
                case .next:
                    if let n = s.upcoming(from: now, limit: 1).first {
                        Text("NEXT · \(dayLabel(n.date, now: now).uppercased())").font(.system(size: 10, weight: .heavy))
                        Text(n.workout.title).font(.system(size: 13, weight: .heavy)).lineLimit(1)
                        Text("\(n.workout.exercises.count) exercises · \(n.workout.setsTotal) sets").font(.system(size: 11)).lineLimit(1)
                    } else {
                        Text("Nothing planned yet").font(.system(size: 12, weight: .bold))
                    }
                case .checkIn:
                    Text("CHECK-IN").font(.system(size: 10, weight: .heavy))
                    if let d = s.daysToCheckIn(now) {
                        Text(d > 0 ? "Due in \(d) day\(d == 1 ? "" : "s")" : (d == 0 ? "Due today" : "Overdue \(-d) day\(d == -1 ? "" : "s")"))
                            .font(.system(size: 14, weight: .heavy))
                        if let l = s.lastCheckIn { Text("Last: \(l.formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 11)) }
                    } else {
                        Text("Send your first one").font(.system(size: 13, weight: .heavy))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(openURL(e.config.kind == .macros ? "macros" : e.config.kind == .checkIn ? "checkins"
                           : e.config.kind == .lift ? "stats" : "workouts"))
    }
}

// MARK: - Lock Screen: inline (above the clock)

private struct InlineView: View {
    let e: SnapEntry<InlineConfig>
    var body: some View {
        let s = e.snap, now = e.date
        let _ = e.placeholder ? () : WidgetShared.diag("drew.lock", "inline · \(e.config.kind.rawValue)")   // DIAGNOSTIC
        Group {
            if s.state != .client {
                Label("Big Scherly", systemImage: "dumbbell.fill")
            } else {
                switch e.config.kind {
                case .today:
                    if let w = s.day(now)?.workout {
                        Label(w.completed ? "Done: \(w.title)" : "Today: \(w.title)", systemImage: "dumbbell.fill")
                    } else {
                        Label("Rest day", systemImage: "moon.zzz.fill")
                    }
                case .kcal:
                    if let m = s.day(now)?.macros {
                        Label("\(m.kcal.formatted()) kcal · \(m.training ? "training" : "rest")", systemImage: "flame.fill")
                    } else {
                        Label("No macro plan today", systemImage: "flame")
                    }
                case .checkIn:
                    if let d = s.daysToCheckIn(now) {
                        Label(d > 0 ? "Check-in in \(d) day\(d == 1 ? "" : "s")" : (d == 0 ? "Check-in today" : "Check-in overdue"),
                              systemImage: "calendar")
                    } else {
                        Label("No check-ins yet", systemImage: "calendar")
                    }
                case .week:
                    let p = s.weekProgress(now)
                    Label("\(p.done) of \(p.planned) sessions this week", systemImage: "checkmark.circle")
                }
            }
        }
        .widgetURL(openURL(e.config.kind == .kcal ? "macros" : e.config.kind == .checkIn ? "checkins" : "workouts"))
    }
}
