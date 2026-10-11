import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Stats, the shared parts (Oct 9, 2026)
//
// The client's phone Stats, for the coach: the same raw data (workouts, Watch sensor data, heart
// rate from Apple Health, all already on the server) run through the phone's own StatsEngine, then
// drawn in the iPad design and nested like Clients: Stats › a lift › a session › a set.
// This file: where the data comes from, the drill-down state, the chart, and the findings.
// Synchronized folder: no target step needed.

// MARK: Drill-down state (read by the Clients crumb bar and its esc key)

@MainActor
final class PadStatsNav: ObservableObject {
    static let shared = PadStatsNav()
    @Published var subject: StatsSubject?
    @Published var sessionId: String?
    @Published var setId: String?
    @Published var explore: PadStatsExplore = .exercises
    /// Labels for the crumbs, set by the level that's showing.
    @Published var sessionLabel = ""
    @Published var setLabel = ""
    var clientId: String?

    var depth: Int { setId != nil ? 3 : (sessionId != nil ? 2 : (subject != nil ? 1 : 0)) }

    func pop() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if setId != nil { setId = nil }
            else if sessionId != nil { sessionId = nil }
            else { subject = nil }
        }
    }
    func go(depth d: Int) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if d < 3 { setId = nil }
            if d < 2 { sessionId = nil }
            if d < 1 { subject = nil }
        }
    }
    func reset() { subject = nil; sessionId = nil; setId = nil; sessionLabel = ""; setLabel = "" }

    /// The crumbs after "Stats": (title, depth to go back to).
    var crumbs: [(title: String, depth: Int)] {
        var out: [(title: String, depth: Int)] = []
        if let s = subject { out.append((s.title, 1)) }
        if sessionId != nil { out.append((sessionLabel.isEmpty ? "Session" : sessionLabel, 2)) }
        if setId != nil { out.append((setLabel.isEmpty ? "Set" : setLabel, 3)) }
        return out
    }
}

enum PadStatsExplore: String, CaseIterable, Identifiable {
    case exercises = "Exercises", workouts = "Workouts", sbd = "SBD"
    var id: String { rawValue }
}

// MARK: Everything a level needs, worked out once per change

@MainActor
struct PadStatsContext {
    let facts: PadClientFacts
    let engine: StatsEngine
    let window: StatsWindow
    let sessions: [StatsSession]        // all exercises, in the window, oldest first
    let allTime: [StatsSession]         // all exercises, every session ever
    let vitals: [String: WorkoutVitals]
    let prs: [PersonalRecord]
    let workouts: [Workout]

    var first: String { facts.first }

    static func make(facts: PadClientFacts, window: StatsWindow, vitals: [String: WorkoutVitals], store: AppStore) -> PadStatsContext {
        let data = PadData.shared
        let ws = data.workouts[facts.id] ?? []
        let motions = data.motion[facts.id] ?? []
        var bySet: [String: SetMotion] = [:]
        for m in motions { bySet[m.setId] = m }
        let lookup = bySet
        let source = StatsSource(workouts: ws, isDemo: !store.isLive,
                                 motion: { _, setId in lookup[setId] },
                                 vitals: vitals)
        let engine = StatsEngine(source: source)
        let all = engine.allSessions(window: .all)
        let start = window.start
        let inWindow = start.map { s in all.filter { $0.date >= s } } ?? all
        let prs = ProgressEngine.allPRs(workouts: ws)
        return PadStatsContext(facts: facts, engine: engine, window: window, sessions: inWindow, allTime: all,
                               vitals: vitals, prs: prs, workouts: ws)
    }

    /// Every session of one exercise, oldest first, with heart rate sliced to that lift.
    func sessions(for subject: StatsSubject) -> [StatsSession] { engine.sessions(for: subject, window: window) }

    func session(_ id: String) -> StatsSession? { allTime.first { $0.id == id } }

    var hasMotion: Bool { sessions.contains { $0.hasMotion } }
    var hasHeartRate: Bool { sessions.contains { $0.hr != nil } }

    /// The phone's names for a window ("last 12 weeks").
    var windowLabel: String { window.label }
}

/// Orders sets by load, then reps (for "top set"). A plain function keeps the type checker fast.
func padLighterSet(_ a: SetStat, _ b: SetStat) -> Bool {
    if a.weight != b.weight { return a.weight < b.weight }
    return a.reps < b.reps
}

// MARK: - The chart (lines, dashed lines, points, bars; reference lines; tap a point)

struct PadStatChart: View {
    let series: [StatSeries]
    var references: [StatReference] = []
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 180
    var axis = true
    var highlight: Date? = nil
    var onPick: ((Date) -> Void)? = nil

    private var points: [StatPoint] { series.flatMap { $0.points } }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, sz in draw(ctx, sz) }
                .contentShape(Rectangle())
                .onTapGesture { loc in pick(at: loc, size: size) }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let s = series.first(where: { !$0.points.isEmpty }), let l = s.points.last else { return "No data" }
        return "\(s.name), latest \(format(l.value))"
    }

    private var bounds: (lo: Double, hi: Double, t0: Date, t1: Date)? {
        let pts = points
        guard let t0 = pts.map({ $0.date }).min(), let t1 = pts.map({ $0.date }).max() else { return nil }
        let vals = pts.map { $0.value } + references.map { $0.value }
        var lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let bars = series.contains { $0.style == .bar }
        if bars { lo = min(0, lo) }
        if hi - lo < 0.0001 { hi = lo + 1 }
        let padV = (hi - lo) * 0.08
        return (bars ? lo : lo - padV, hi + padV, t0, t1)
    }

    private var leftPad: CGFloat { axis ? 42 : 4 }
    private let rightPad: CGFloat = 8
    private var bottomPad: CGFloat { axis ? 18 : 4 }

    private func x(_ d: Date, _ b: (lo: Double, hi: Double, t0: Date, t1: Date), _ w: CGFloat) -> CGFloat {
        let span = b.t1.timeIntervalSince(b.t0)
        guard span > 0 else { return leftPad + (w - leftPad - rightPad) / 2 }
        return leftPad + (w - leftPad - rightPad) * CGFloat(d.timeIntervalSince(b.t0) / span)
    }
    private func y(_ v: Double, _ b: (lo: Double, hi: Double, t0: Date, t1: Date), _ h: CGFloat) -> CGFloat {
        4 + (h - 4 - bottomPad) * CGFloat(1 - (v - b.lo) / (b.hi - b.lo))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let b = bounds else {
            ctx.draw(Text("No data in this period").font(PadFont.cond(12)).foregroundColor(Pad.faint),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let w = size.width, h = size.height
        // Grid and axis labels
        for k in 0...2 {
            let v = b.lo + (b.hi - b.lo) * Double(k) / 2
            let yy = y(v, b, h)
            var g = Path(); g.move(to: CGPoint(x: leftPad, y: yy)); g.addLine(to: CGPoint(x: w - rightPad, y: yy))
            ctx.stroke(g, with: .color(Pad.line), lineWidth: 1)
            if axis {
                ctx.draw(Text(format(v)).font(PadFont.cond(10)).foregroundColor(Pad.faint),
                         at: CGPoint(x: leftPad - 6, y: yy), anchor: .trailing)
            }
        }
        if axis {
            let fmt = Date.FormatStyle.dateTime.month(.abbreviated).day()
            ctx.draw(Text(b.t0.formatted(fmt)).font(PadFont.cond(10)).foregroundColor(Pad.faint),
                     at: CGPoint(x: leftPad, y: h - 2), anchor: .bottomLeading)
            if b.t1 > b.t0 {
                ctx.draw(Text(b.t1.formatted(fmt)).font(PadFont.cond(10)).foregroundColor(Pad.faint),
                         at: CGPoint(x: w - rightPad, y: h - 2), anchor: .bottomTrailing)
            }
        }
        // Highlight (the selected session)
        if let hd = highlight, hd >= b.t0, hd <= b.t1 {
            let hx = x(hd, b, w)
            var p = Path(); p.move(to: CGPoint(x: hx, y: 4)); p.addLine(to: CGPoint(x: hx, y: h - bottomPad))
            ctx.stroke(p, with: .color(Pad.line2), lineWidth: 6)
        }
        // Bars first, then lines on top
        let barSeries = series.filter { $0.style == .bar }
        let barCount = max(barSeries.first?.points.count ?? 0, 1)
        let barW = max(3, min(18, (w - leftPad - rightPad) / CGFloat(barCount) * 0.6))
        for (si, s) in barSeries.enumerated() {
            for (i, pt) in s.points.enumerated() {
                let last = si == 0 && i == s.points.count - 1
                let px = x(pt.date, b, w), py = y(pt.value, b, h), base = y(max(b.lo, 0), b, h)
                let r = CGRect(x: px - barW / 2, y: min(py, base), width: barW, height: max(2, abs(base - py)))
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(last ? Pad.volt : Pad.raised))
            }
        }
        for r in references {
            let yy = y(r.value, b, h)
            var p = Path(); p.move(to: CGPoint(x: leftPad, y: yy)); p.addLine(to: CGPoint(x: w - rightPad, y: yy))
            ctx.stroke(p, with: .color(r.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
            ctx.draw(Text(r.label).font(PadFont.cond(10, .bold)).foregroundColor(r.color),
                     at: CGPoint(x: w - rightPad, y: yy - 3), anchor: .bottomTrailing)
        }
        for s in series where s.style != .bar {
            let pts = s.points.map { CGPoint(x: x($0.date, b, w), y: y($0.value, b, h)) }
            if s.style == .points {
                for p in pts { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(s.color)) }
                continue
            }
            guard pts.count >= 1 else { continue }
            var path = Path()
            for (i, p) in pts.enumerated() { if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
            let dashed = s.style == .dashed
            ctx.stroke(path, with: .color(s.color), style: StrokeStyle(lineWidth: dashed ? 1.6 : 2.2, lineCap: .round, lineJoin: .round, dash: dashed ? [5, 4] : []))
            if !dashed, let l = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: l.x - 4, y: l.y - 4, width: 8, height: 8)), with: .color(s.color))
            }
        }
    }

    private func pick(at loc: CGPoint, size: CGSize) {
        guard let onPick, let b = bounds else { return }
        let dates = Array(Set(points.map { $0.date }))
        guard let best = dates.min(by: { abs(x($0, b, size.width) - loc.x) < abs(x($1, b, size.width) - loc.x) }) else { return }
        onPick(best)
    }
}

/// A legend row for a chart's series and reference lines.
struct PadStatLegend: View {
    let series: [StatSeries]
    var references: [StatReference] = []
    var body: some View {
        HStack(spacing: 12) {
            ForEach(series.filter { !$0.points.isEmpty }) { s in
                HStack(spacing: 6) {
                    swatch(s.color, style: s.style)
                    Text(s.name).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
            }
            ForEach(references) { r in
                HStack(spacing: 6) {
                    swatch(r.color, style: .dashed)
                    Text(r.label).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
            }
        }
    }
    @ViewBuilder
    private func swatch(_ c: Color, style: StatSeries.Style) -> some View {
        switch style {
        case .points: Circle().fill(c).frame(width: 7, height: 7)
        case .dashed: HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(c).frame(width: 4, height: 3) } }
        case .bar: RoundedRectangle(cornerRadius: 2).fill(Pad.raised).frame(width: 10, height: 10)
        case .line: Capsule().fill(c).frame(width: 14, height: 3)
        }
    }
}

/// One small chart card: title, the latest value, the change, and the chart.
struct PadStatCard: View {
    let panel: StatPanel
    var height: CGFloat = 70
    var onPick: ((Date) -> Void)? = nil

    private var latest: Double? { panel.primary?.points.last?.value }
    private var firstValue: Double? { panel.primary?.points.first?.value }
    private var changeText: String {
        guard let l = latest, let f = firstValue, (panel.primary?.points.count ?? 0) >= 2 else { return panel.caption ?? "" }
        let d = l - f
        if abs(d) < 0.0001 { return "no change in this period" }
        let sign = d > 0 ? "+" : "−"
        return "\(sign)\(panel.format(abs(d))) in this period"
    }
    private var changeColor: Color {
        guard let l = latest, let f = firstValue, let up = panel.higherIsBetter, abs(l - f) > 0.0001 else { return Pad.mute }
        let better = (l > f) == up
        return better ? Pad.voltText : Pad.orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(panel.title).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                Spacer(minLength: 4)
                if !panel.axisUnit.isEmpty { Text(panel.axisUnit).font(PadFont.cond(11)).foregroundColor(Pad.faint) }
            }
            Text(latest.map { panel.format($0) } ?? "—").font(PadFont.display(24)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(changeText).font(PadFont.cond(12)).foregroundColor(changeColor).lineLimit(1)
            PadStatChart(series: panel.series, references: panel.references, format: panel.format, height: height, axis: false, onPick: onPick)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }
}

/// Findings, two to a row (three on the lift level). No buttons: findings only (Nick, Oct 9).
struct PadFindings: View {
    let notes: [PadNote]
    var columns = 2
    var limit = 4
    @State private var all = false
    var body: some View {
        let shown = all ? notes : Array(notes.prefix(limit))
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: max(1, min(columns, shown.count)))
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(shown) { n in PadNoteCard(note: n).frame(maxHeight: .infinity, alignment: .top) }
            }
            if notes.count > limit {
                Button(all ? "Show fewer" : "\(notes.count - limit) more") { withAnimation(.easeOut(duration: 0.15)) { all.toggle() } }
                    .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
            }
        }
    }
}

/// A tile in the strip of a level (well background, number, sub line).
struct PadStatsTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String = ""
    var subColor: Color = Pad.mute
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PadLab(label, size: 12).lineLimit(1)
            PadNumber(value: value, unit: unit, size: 26)
            Text(sub).font(PadFont.cond(12)).foregroundColor(subColor).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }
}

/// A short horizontal speed bar with the number after it.
struct PadSpeedBar: View {
    let value: Double
    var maxValue: Double = 0.8
    var warn = false
    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(warn ? Pad.orange : Pad.text)
                .frame(width: max(4, CGFloat(min(value / maxValue, 1)) * 90), height: 6)
            Text(String(format: "%.2f", value)).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
        }
        .frame(width: 140, alignment: .leading)
    }
}

/// A tiny trend line for list rows.
struct PadSpark: View {
    let values: [Double]
    var color: Color = Pad.text
    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, let lo = values.min(), let hi0 = values.max() else { return }
            let hi = hi0 > lo ? hi0 : lo + 1
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: 2 + (size.width - 4) * CGFloat(i) / CGFloat(values.count - 1),
                                 y: 2 + (size.height - 4) * CGFloat(1 - (v - lo) / (hi - lo)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
