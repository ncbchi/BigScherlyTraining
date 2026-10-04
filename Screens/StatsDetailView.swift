import SwiftUI
import Charts

// MARK: - Stats detail (exercise, workout type, or SBD)
// One metric at a time: pick it from the menu, read the summary + one sentence,
// study one properly-labelled chart, then scan the sessions underneath. Tap a
// session to expand it; tap a set with Watch data to see every rep.

struct StatsDetailView: View {
    @EnvironmentObject var store: AppStore
    /// What's shown — an exercise, a workout type, the big three, or one session. Tap the
    /// title to switch to any other lift you've done.
    @State private var subject: StatsSubject
    /// Set by the coach app to show one client's data; nil = your own.
    var source: StatsSource? = nil

    init(subject: StatsSubject, source: StatsSource? = nil) {
        _subject = State(initialValue: subject)
        self.source = source
    }

    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_stats_window") private var windowRaw = StatsWindow.w12.rawValue
    @AppStorage("bst_stats_metric") private var metricId = "strength"
    @AppStorage("bst_dots_category") private var dotsCategory = ""     // "", "womens", "mens"

    @State private var rawSelection: Date? = nil
    @State private var expanded: Set<String> = []
    @State private var bodyweightLb: Double? = nil
    @State private var choosingMetric = false
    @State private var choosingLift = false
    /// Selections stay after you lift your finger (✕ in the readout clears them).
    @State private var pinnedDate: Date? = nil
    /// The expanded session whose reps the chart shows (nil = the timeline).
    @State private var focused: String? = nil
    @State private var rawRep: Double? = nil
    @State private var pinnedRep: Double? = nil

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .w12 }
    private var isSBD: Bool { if case .sbd = subject { return true } else { return false } }

    var body: some View {
        let engine = source.map { StatsEngine(source: $0) } ?? StatsEngine(store: store)
        let sessions = engine.sessions(for: subject, window: window)
        let panels = engine.panels(for: subject, sessions: sessions,
                                   categories: Set(StatCategory.allCases), sensors: Set(SensorMetric.allCases),
                                   bodyweightLb: bodyweightLb,
                                   womensDOTS: dotsCategory.isEmpty ? nil : dotsCategory == "womens")
            .filter { $0.hasData }
        let panel = panels.first { $0.id == metricId } ?? panels.first

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Button { choosingLift = true } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Text(subject.title).font(BrandFont.display(36)).foregroundColor(Brand.text)
                                .lineLimit(2).minimumScaleFactor(0.6).multilineTextAlignment(.leading)
                            Image(systemName: "chevron.down").font(.system(size: 13, weight: .heavy))
                                .foregroundColor(Brand.onVolt)
                                .frame(width: 26, height: 26).background(Circle().fill(Brand.volt))
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(subject.title). Switch lift")
                    Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(window.label)")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }

                StatsWindowPicker(selection: Binding(get: { window }, set: { windowRaw = $0.rawValue }))

                if isSBD && dotsCategory.isEmpty { dotsSetup }

                if sessions.isEmpty {
                    Text("Nothing logged for this in the \(window.label).")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let panel {
                    metricButton(current: panel)
                    SummaryStrip(panel: panel)
                    if let fid = focused, let fs = sessions.first(where: { $0.id == fid }) {
                        SessionChartCard(chart: sessionChart(fs, panel: panel, engine: engine),
                                         rawSelection: $rawRep, pinned: $pinnedRep) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expanded.remove(fid)
                                focused = nil
                            }
                        }
                    } else {
                        ChartCard(panel: panel, domain: timeDomain(sessions), rawSelection: $rawSelection,
                                  pinned: $pinnedDate, highlight: nil)
                    }
                    if let line = headline(panel) {
                        Text(line).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let c = panel.caption {
                        Text(c).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                    if panel.category == .sensor && !sessions.contains(where: { $0.hasMotion }) {
                        Text("No Watch data yet. Start a session on your Watch and it'll show up here.")
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }

                    Text("SESSIONS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                        .padding(.top, 8)
                    VStack(spacing: 8) {
                        ForEach(Array(sessions.reversed().enumerated()), id: \.element.id) { i, s in
                            let ordered = Array(sessions.reversed())
                            let prev = i + 1 < ordered.count ? ordered[i + 1] : nil
                            SessionRow(session: s, previous: prev, subject: subject, panel: panel,
                                       expanded: expanded.contains(s.id)) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    if expanded.contains(s.id) {
                                        expanded.remove(s.id)
                                        // Back to the timeline, or to another session that's still open.
                                        if focused == s.id { focused = ordered.first { expanded.contains($0.id) }?.id }
                                    } else {
                                        expanded.insert(s.id)
                                        focused = s.id       // the chart shows this session's reps
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingMetric) {
            MetricChooser(panels: panels, current: panel?.id ?? metricId) { id in
                metricId = id
                rawSelection = nil; pinnedDate = nil; rawRep = nil; pinnedRep = nil
                choosingMetric = false
            }
        }
        .sheet(isPresented: $choosingLift) {
            LiftChooser(lifts: liftList(engine), current: subject) { name in
                subject = .exercise(name)
                rawSelection = nil; pinnedDate = nil; rawRep = nil; pinnedRep = nil
                expanded = []
                focused = nil
                choosingLift = false
            }
        }
        .onChange(of: windowRaw) { _, _ in pinnedDate = nil }
        .onChange(of: focused) { _, _ in rawRep = nil; pinnedRep = nil }
        .task(id: "\(window.rawValue)|\(subject.id)") {
            if source == nil { for s in sessions { _ = await store.loadWorkoutVitals(workoutId: s.id) } }
            if isSBD && bodyweightLb == nil {
                if let src = source { bodyweightLb = src.bodyweightLb }
                else if store.isDemoMode || APIConfig.useMock { bodyweightLb = 165 }
                else { bodyweightLb = await HealthKitManager.shared.latestBodyweightPounds() }
            }
        }
    }

    // MARK: Metric picker

    /// The current metric; tap to see every metric at once (a sheet, not a menu — a long menu
    /// hides its lower options, and its closing animation blurs this card's outline).
    private func metricButton(current: StatPanel) -> some View {
        Button { choosingMetric = true } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(current.category)).font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Brand.onVolt)
                    .frame(width: 30, height: 30).background(Circle().fill(Brand.volt))
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.category.rawValue.uppercased())
                        .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    Text(current.title).font(BrandFont.body(17, .bold)).foregroundColor(Brand.text)
                }
                Spacer()
                Text("Change").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                Image(systemName: "square.grid.2x2").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Brand.voltText)
            }
            .padding(12)
            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    /// One session in detail, for the current metric: every rep (Watch metrics), every set
    /// (logged metrics), or heart rate across the session.
    private func sessionChart(_ s: StatsSession, panel: StatPanel, engine: StatsEngine) -> SessionChart {
        let multi = s.exercises.count > 1
        let unit = StatsUnits.depthLabel
        let w: (Double) -> String = { "\(Int($0.rounded())) \(StatsUnits.weightLabel)" }

        // Every rep with Watch data, grouped by set.
        func perRep(_ title: String, _ unitLabel: String, _ fmt: @escaping (Double) -> String,
                    _ series: [(String, Color, (RepMotion) -> Double?)]) -> SessionChart {
            var pts: [SessionChart.Point] = []; var groups: [SessionChart.Group] = []
            var x = 0.0, g = 0
            for ex in s.exercises {
                for set in ex.sets {
                    guard let m = set.motion, !m.reps.isEmpty else { continue }
                    groups.append(.init(x: x, label: multi ? "\(ex.name.prefix(3)) S\(set.number)" : "S\(set.number)"))
                    for r in m.reps {
                        for (si, sr) in series.enumerated() {
                            if let v = sr.2(r) {
                                pts.append(.init(id: pts.count, x: x, value: v, series: si, group: g,
                                                 label: (multi ? "\(ex.name) · " : "") + "Set \(set.number) · Rep \(r.index)"))
                            }
                        }
                        x += 1
                    }
                    g += 1
                }
            }
            return SessionChart(kind: .reps, title: "Every rep", date: s.date, unit: unitLabel, format: fmt,
                                seriesNames: series.map { $0.0 }, seriesColors: series.map { $0.1 },
                                points: pts, groups: groups,
                                emptyText: "No Watch data for this session.")
        }
        // Every set.
        func perSet(_ title: String, _ unitLabel: String, _ fmt: @escaping (Double) -> String,
                    _ value: (SetStat) -> Double?) -> SessionChart {
            var pts: [SessionChart.Point] = []; var groups: [SessionChart.Group] = []
            var x = 0.0
            for (ei, ex) in s.exercises.enumerated() {
                if multi { groups.append(.init(x: x, label: String(ex.name.prefix(10)))) }
                for set in ex.sets {
                    if let v = value(set) {
                        pts.append(.init(id: pts.count, x: x, value: v, series: 0, group: multi ? ei : Int(x),
                                         label: (multi ? "\(ex.name) · " : "") + "Set \(set.number)"))
                        if !multi { groups.append(.init(x: x, label: "S\(set.number)")) }
                        x += 1
                    }
                }
            }
            return SessionChart(kind: .sets, title: title, date: s.date, unit: unitLabel, format: fmt,
                                seriesNames: [panel.title], seriesColors: [Brand.volt],
                                points: pts, groups: groups,
                                emptyText: "Nothing recorded for this in this session.")
        }

        switch panel.id {
        case "hr", "duration", "calories":
            let v = engine.source.vitals[s.id]
            let start = v?.start ?? s.date
            let pts = (v?.heartRateSeries ?? []).enumerated().map { i, h in
                SessionChart.Point(id: i, x: h.time.timeIntervalSince(start) / 60, value: Double(h.bpm), series: 0, group: 0,
                                   label: "\(Int((h.time.timeIntervalSince(start) / 60).rounded())) min in")
            }
            // Mark where each set was logged.
            var groups: [SessionChart.Group] = []
            for ex in s.exercises { for set in ex.sets {
                if let t = set.loggedAt, t >= start { groups.append(.init(x: t.timeIntervalSince(start) / 60, label: "S\(set.number)")) }
            } }
            return SessionChart(kind: .time, title: "Heart rate through the session", date: s.date, unit: "bpm",
                                format: { "\(Int($0.rounded())) bpm" }, seriesNames: ["Heart rate"],
                                seriesColors: [Color(hex: 0xFF5555)], points: pts, groups: groups,
                                emptyText: "No heart-rate samples for this session.")
        case "s-speed":
            return perRep("Every rep", "m/s", { StatsUnits.velocityText($0) }, [("Bar speed", Brand.volt, { $0.meanVelocity })])
        case "s-depth":
            return perRep("Every rep", unit, { String(format: "%.1f %@", $0, unit) }, [("Depth", Color(hex: 0x3D9BE0), { StatsUnits.depth($0.travelM) })])
        case "s-pause":
            return perRep("Every rep", "sec", { StatsUnits.secondsText($0) }, [("Bottom pause", Color(hex: 0xF2A03D), { $0.bottomPauseSec })])
        case "s-tempo":
            return perRep("Every rep", "sec", { StatsUnits.secondsText($0) },
                          [("Lowering", Color(hex: 0x3D9BE0), { $0.eccentricSec }), ("Lifting", Brand.volt, { $0.concentricSec })])
        case "s-stick":
            return perRep("Every rep", "% up", { "\(Int($0.rounded()))% up" }, [("Sticking point", Brand.volt, { $0.stickingPoint.map { $0 * 100 } })])
        case "s-drift":
            return perRep("Every rep", unit, { String(format: "%.1f %@", $0, unit) }, [("Bar drift", Brand.volt, { StatsUnits.depth($0.driftM) })])
        case "s-grind":
            return perRep("Every rep", "sec", { StatsUnits.secondsText($0) }, [("Lifting time", Brand.volt, { $0.concentricSec })])
        case "s-loss":
            return perSet("Every set", "%", { "\(Int($0.rounded()))%" }) { $0.motion?.velocityLossPct }
        case "s-tut":
            return perSet("Every set", "sec", { "\(Int($0.rounded()))s" }) { $0.motion?.timeUnderTensionSec }
        case "s-consist":
            return perSet("Every set", "%", { "\(Int($0.rounded()))%" }) { $0.motion?.travelConsistencyPct }
        case "s-reps":
            return perSet("Every set", "reps", { "\(Int($0)) reps" }) { $0.motion.map { Double($0.repCount) } }
        case "volume":
            return perSet("Every set", StatsUnits.weightLabel, w) { StatsUnits.weight($0.volume) }
        case "rpe":
            return perSet("Every set", "RPE", { "RPE " + $0.rpeText }) { $0.rpe }
        case "sets":
            return perSet("Every set", "reps", { "\(Int($0)) reps" }) { Double($0.reps) }
        default:   // Estimated 1RM, Strength, SBD total, DOTS
            return perSet("Every set · est. 1RM", StatsUnits.weightLabel, w) { StatsUnits.weight($0.e1RM) }
        }
    }

    /// Every lift you've done (or this client has), most recent first.
    private func liftList(_ engine: StatsEngine) -> [LiftChooser.Lift] {
        let all = engine.allSessions(window: .all)
        let byName = Dictionary(grouping: all.flatMap { s in s.exercises.map { (s.date, $0) } }, by: { $0.1.name })
        return byName.map { name, e in
            LiftChooser.Lift(name: name, sessions: e.count, last: e.map { $0.0 }.max() ?? .distantPast,
                             sensor: e.contains { $0.1.hasMotion })
        }
        .sorted { $0.last > $1.last }
    }

    private func icon(_ c: StatCategory) -> String {
        switch c {
        case .weight: return "scalemass.fill"
        case .heartRate: return "heart.fill"
        case .sensor: return "applewatch"
        }
    }

    // MARK: Headline

    /// One plain-language sentence describing the primary line over the window.
    private func headline(_ p: StatPanel) -> String? {
        guard let s = p.primary, let first = s.points.first, let last = s.points.last, s.points.count >= 2 else { return nil }
        let change = last.value - first.value
        let since = first.date.formatted(.dateTime.month(.abbreviated).day())
        let lead = p.series.count > 1 && s.name != "Value" ? s.name : p.title
        let mag = abs(change)
        let tiny = mag < max(abs(first.value) * 0.01, 0.005)
        if tiny { return "\(lead) has held steady since \(since)." }
        let dir = change > 0 ? "up" : "down"
        var text = "\(lead) \(dir) \(p.format(mag)) since \(since)"
        let weeks = last.date.timeIntervalSince(first.date) / (7 * 86400)
        if p.axisUnit == StatsUnits.weightLabel, weeks >= 2, p.id != "volume" {
            text += String(format: " — about %@ a week", p.format(mag / weeks))
        }
        if let good = p.higherIsBetter {
            let improving = (change > 0) == good
            text += improving ? "." : ". Worth a look."
        } else {
            text += "."
        }
        return text
    }

    // MARK: DOTS setup

    private var dotsSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOTS compares strength across bodyweights. Which scoring table should it use?")
                .font(BrandFont.body(12)).foregroundColor(Brand.text)
            HStack(spacing: 8) {
                ForEach([(key: "womens", label: "Women's"), (key: "mens", label: "Men's")], id: \.key) { key, label in
                    Button { dotsCategory = key } label: {
                        Text(label).font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
                    }
                }
            }
            if bodyweightLb == nil {
                Text("DOTS also needs a bodyweight in Apple Health.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        .card(padding: 14)
    }

    private func timeDomain(_ sessions: [StatsSession]) -> ClosedRange<Date> {
        let end = Date().addingTimeInterval(2 * 86400)
        var start = window.start ?? sessions.first?.date ?? end.addingTimeInterval(-28 * 86400)
        if window == .all, let first = sessions.first?.date { start = first }
        start = start.addingTimeInterval(-2 * 86400)
        return start...max(end, start.addingTimeInterval(86400))
    }
}

// MARK: - Current · Change · Best

struct SummaryStrip: View {
    let panel: StatPanel

    var body: some View {
        let pts = panel.primary?.points ?? []
        let current = pts.last?.value
        let change = (pts.count >= 2) ? (pts.last!.value - pts.first!.value) : nil
        let best: Double? = {
            let v = pts.map { $0.value }
            return panel.higherIsBetter == false ? v.min() : v.max()
        }()
        HStack(spacing: 8) {
            cell("CURRENT", current.map(panel.format) ?? "—", Brand.text)
            cell("CHANGE", change.map { ($0 >= 0 ? "+" : "−") + panel.format(abs($0)) } ?? "—", changeColor(change))
            cell(panel.higherIsBetter == nil ? "HIGHEST" : "BEST", best.map(panel.format) ?? "—", Brand.volt)
        }
    }

    private func changeColor(_ c: Double?) -> Color {
        guard let c, c != 0, let good = panel.higherIsBetter else { return Brand.text }
        return (c > 0) == good ? Brand.volt : .orange
    }

    private func cell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
            Text(value).font(BrandFont.body(16, .bold)).foregroundColor(Brand.readable(color))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: - The chart

struct ChartCard: View {
    let panel: StatPanel
    let domain: ClosedRange<Date>
    @Binding var rawSelection: Date?
    /// The last session you touched — stays after you lift your finger.
    @Binding var pinned: Date?
    /// Date of an expanded session row, marked on the chart.
    let highlight: Date?

    private var allDates: [Date] { panel.series.flatMap { $0.points.map { $0.date } } }

    /// Nearest plotted date to the finger — or, once the finger lifts, the last one touched.
    private var selected: Date? {
        if let d = rawSelection { return nearest(d) }
        if let p = pinned, allDates.contains(p) { return p }
        return nil
    }

    private func nearest(_ d: Date) -> Date? {
        allDates.min { abs($0.timeIntervalSince(d)) < abs($1.timeIntervalSince(d)) }
    }

    private var yDomain: ClosedRange<Double> {
        let vals = panel.series.flatMap { $0.points.map { $0.value } } + panel.references.map { $0.value }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        if panel.usesBars { return 0...max(hi * 1.15, 1) }
        let pad = max((hi - lo) * 0.18, abs(hi) * 0.04, 0.02)
        return (lo - pad)...(hi + pad)
    }

    private var barWidth: CGFloat {
        let n = max(1, panel.series.first { $0.style == .bar }?.points.count ?? 1)
        return max(5, min(18, 240 / CGFloat(n)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout

            Chart {
                ForEach(panel.references) { r in
                    RuleMark(y: .value(r.label, r.value))
                        .foregroundStyle(Brand.readableLine(r.color).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("\(r.label) \(panel.format(r.value))")
                                .font(BrandFont.body(9, .bold)).foregroundColor(Brand.readable(r.color))
                        }
                }
                // One loop per mark type (no if/else inside the chart: that form of chart
                // content is only guaranteed on iOS 27, and the app supports iOS 18.6+).
                ForEach(panel.series.filter { $0.style == .bar }) { s in
                    ForEach(s.points) { p in
                        BarMark(x: .value("Date", p.date), y: .value(s.name, p.value), width: .fixed(barWidth))
                            .foregroundStyle(Brand.readableLine(s.color).opacity(selected == nil || selected == p.date ? 0.9 : 0.35))
                            .cornerRadius(3)
                    }
                }
                ForEach(panel.series.filter { $0.style == .points }) { s in
                    ForEach(s.points) { p in
                        PointMark(x: .value("Date", p.date), y: .value(s.name, p.value))
                            .foregroundStyle(Brand.readableLine(s.color)).symbolSize(26)
                    }
                }
                ForEach(panel.series.filter { $0.style != .bar && $0.style != .points }) { s in
                    ForEach(s.points) { p in
                        LineMark(x: .value("Date", p.date), y: .value(s.name, p.value),
                                 series: .value("Series", s.name))
                            .foregroundStyle(Brand.readableLine(s.color))
                            .lineStyle(StrokeStyle(lineWidth: s.style == .dashed ? 1.6 : 2.4,
                                                   dash: s.style == .dashed ? [5, 4] : []))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(panel.series.filter { $0.style == .line }) { s in
                    ForEach(s.points) { p in
                        PointMark(x: .value("Date", p.date), y: .value(s.name, p.value))
                            .foregroundStyle(Brand.readableLine(s.color)).symbolSize(18)
                    }
                }
                if let h = highlight, selected == nil {
                    RuleMark(x: .value("Session", h)).foregroundStyle(Brand.voltLine.opacity(0.5))
                }
                if let d = selected {
                    RuleMark(x: .value("Selected", d))
                        .foregroundStyle(Brand.text.opacity(0.45))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Brand.line)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(axisText(d)) }
                    }
                    .foregroundStyle(Brand.mute)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Brand.line.opacity(0.5))
                    AxisTick().foregroundStyle(Brand.line)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Brand.mute)
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $rawSelection)
            .onChange(of: rawSelection) { _, d in
                if let d, let n = nearest(d) { pinned = n }
            }
            // Start on the most recent session; again whenever the metric, window or lift
            // changes (those clear the pin). After ✕ it stays clear until one of them does.
            .task(id: "\(panel.id)|\(allDates.count)|\(domain.lowerBound.timeIntervalSince1970)") {
                if pinned == nil || !allDates.contains(pinned!) { pinned = allDates.max() }
            }
            .frame(height: 240)

            legend
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private var legend: some View {
        let items = panel.series.filter { !$0.points.isEmpty }
        return HStack(spacing: 14) {
            ForEach(items) { s in
                HStack(spacing: 5) {
                    legendSwatch(s)
                    Text(s.name == "Value" ? panel.title : s.name)
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1).minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private func legendSwatch(_ s: StatSeries) -> some View {
        switch s.style {
        case .bar: RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 10, height: 10)
        case .points: Circle().fill(s.color).frame(width: 8, height: 8)
        case .dashed:
            HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(s.color).frame(width: 4, height: 2) } }
        case .line: Capsule().fill(s.color).frame(width: 14, height: 3)
        }
    }

    /// The strip at the top of the card: the unit normally; while a finger is on the chart, that
    /// session's date and values. Fixed height, so the chart never jumps and nothing is cut off.
    private var readout: some View {
        Group {
            if let d = selected {
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()).uppercased())
                        .font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    HStack(spacing: 12) {
                        ForEach(panel.series) { s in
                            if let p = s.points.first(where: { $0.date == d }) {
                                HStack(spacing: 5) {
                                    Circle().fill(s.color).frame(width: 7, height: 7)
                                    Text(panel.format(p.value)).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                                    if panel.series.count > 1 {
                                        Text(s.name).font(BrandFont.body(10)).foregroundColor(Brand.mute)
                                    }
                                }
                            }
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if rawSelection == nil {
                        Button { withAnimation(.easeOut(duration: 0.15)) { pinned = nil } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundColor(Brand.mute)
                        }
                        .accessibilityLabel("Clear selection")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(panel.axisUnit.uppercased()).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    Text("Touch the chart to see a session · open one below to see every rep").font(BrandFont.body(11))
                        .foregroundColor(Brand.mute.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func axisText(_ v: Double) -> String {
        let a = abs(v)
        if a >= 10_000 { return String(format: "%.0fk", v / 1000) }
        if a >= 1000 { return String(format: "%.1fk", v / 1000) }
        if a >= 20 || v == v.rounded() { return "\(Int(v.rounded()))" }
        if a >= 1 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - One session in detail (every rep, every set, or heart rate through it)

struct SessionChart {
    enum Kind { case reps, sets, time }
    struct Point: Identifiable {
        let id: Int
        let x: Double            // rep / set position, or minutes into the session
        let value: Double
        let series: Int          // index into seriesNames / seriesColors
        let group: Int           // set (alternating shade)
        let label: String        // "Set 2 · Rep 3"
    }
    struct Group { let x: Double; let label: String }   // where each set starts (axis labels / markers)

    var kind: Kind
    var title: String
    var date: Date
    var unit: String
    var format: (Double) -> String
    var seriesNames: [String]
    var seriesColors: [Color]
    var points: [Point]
    var groups: [Group]
    var emptyText: String
}

struct SessionChartCard: View {
    let chart: SessionChart
    @Binding var rawSelection: Double?
    @Binding var pinned: Double?
    let close: () -> Void

    private var xs: [Double] { Array(Set(chart.points.map { $0.x })).sorted() }

    private func nearest(_ v: Double) -> Double? { xs.min { abs($0 - v) < abs($1 - v) } }

    private var selected: Double? {
        if let v = rawSelection { return nearest(v) }
        if let p = pinned, xs.contains(p) { return p }
        return nil
    }

    private var yMax: Double { max(chart.points.map { $0.value }.max() ?? 1, 0.001) }

    /// x-axis: where each set starts (reps/sets), or every few minutes (heart rate).
    private var xTicks: [Double] {
        if chart.kind != .time { return chart.groups.map { $0.x } }
        let end = max(xs.last ?? 1, 1)
        let step = end > 60 ? 15.0 : end > 30 ? 10.0 : 5.0
        return Array(stride(from: 0, through: end, by: step))
    }

    private func tickLabel(_ x: Double) -> String {
        if chart.kind == .time { return "\(Int(x))m" }
        return chart.groups.first { $0.x == x }?.label ?? ""
    }

    private var barWidth: CGFloat { max(4, min(18, 260 / CGFloat(max(xs.count, 1)))) }
    private var stackedMax: Double {
        // Tempo stacks two values per rep.
        Dictionary(grouping: chart.points, by: { $0.x }).values.map { $0.map { $0.value }.reduce(0, +) }.max() ?? yMax
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if chart.points.isEmpty {
                Text(chart.emptyText).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                // No if/else inside the chart or its axes (that form is only guaranteed on iOS 27);
                // each mark type loops over its own list, empty when it doesn't apply.
                let timePts = chart.kind == .time ? chart.points : []
                let barPts = chart.kind == .time ? [] : chart.points
                let markers = chart.kind == .time ? chart.groups : []
                Chart {
                    ForEach(timePts) { p in
                        AreaMark(x: .value("Minutes", p.x), y: .value("bpm", p.value))
                            .foregroundStyle(LinearGradient(colors: [chart.seriesColors[0].opacity(0.35), chart.seriesColors[0].opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(timePts) { p in
                        LineMark(x: .value("Minutes", p.x), y: .value("bpm", p.value))
                            .foregroundStyle(Brand.readableLine(chart.seriesColors[0])).lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(Array(markers.enumerated()), id: \.offset) { _, g in
                        RuleMark(x: .value("Set", g.x))
                            .foregroundStyle(Brand.voltLine.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    ForEach(barPts) { p in
                        BarMark(x: .value("Position", p.x), y: .value(chart.seriesNames[p.series], p.value), width: .fixed(barWidth))
                            .foregroundStyle(Brand.readableLine(chart.seriesColors[p.series])
                                .opacity(selected == nil || selected == p.x ? (p.group % 2 == 0 ? 1 : 0.62) : 0.28))
                            .cornerRadius(2)
                    }
                    if let x = selected {
                        RuleMark(x: .value("Selected", x)).foregroundStyle(Brand.text.opacity(0.45))
                    }
                }
                .chartXScale(domain: chart.kind == .time
                             ? 0...max(xs.last ?? 1, 1)
                             : -0.6...(Double(max(xs.count, 1)) - 0.4))
                .chartYScale(domain: chart.kind == .time
                             ? ((chart.points.map { $0.value }.min() ?? 0) - 6)...(yMax + 6)
                             : 0...(stackedMax * 1.15))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Brand.line)
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(d >= 20 || d == d.rounded() ? "\(Int(d.rounded()))" : String(format: d >= 1 ? "%.1f" : "%.2f", d)) }
                        }
                        .foregroundStyle(Brand.mute)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: xTicks) { v in
                        AxisGridLine().foregroundStyle(Brand.line.opacity(chart.kind == .time ? 0.5 : 0))
                        AxisTick().foregroundStyle(Brand.line)
                        AxisValueLabel {
                            if let x = v.as(Double.self) { Text(tickLabel(x)) }
                        }
                        .foregroundStyle(Brand.mute)
                    }
                }
                .chartLegend(.hidden)
                .chartXSelection(value: $rawSelection)
                .onChange(of: rawSelection) { _, v in
                    if let v, let n = nearest(v) { pinned = n }
                }
                // Start on the last rep (or set, or the end of the session).
                .task(id: "\(chart.date.timeIntervalSince1970)|\(chart.title)|\(chart.unit)|\(chart.points.count)") {
                    if pinned == nil || !xs.contains(pinned!) { pinned = xs.last }
                }
                .frame(height: 240)

                if chart.seriesNames.count > 1 {
                    HStack(spacing: 14) {
                        ForEach(Array(chart.seriesNames.enumerated()), id: \.offset) { i, n in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(chart.seriesColors[i]).frame(width: 10, height: 10)
                                Text(n).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine.opacity(0.55), lineWidth: 1))
    }

    /// "SAT, SEP 5 · EVERY REP", the touched rep's values (kept after you let go), and a way back.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(chart.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(chart.title)".uppercased())
                    .font(BrandFont.body(9, .bold)).tracking(1).headerPill().lineLimit(1)
                if let x = selected {
                    let at = chart.points.filter { $0.x == x }
                    HStack(spacing: 10) {
                        Text(at.first?.label ?? "").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
                        ForEach(at) { p in
                            HStack(spacing: 4) {
                                Circle().fill(Brand.readable(chart.seriesColors[p.series])).frame(width: 7, height: 7)
                                Text(chart.format(p.value)).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                            }
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(chart.kind == .time ? "Touch the chart to see a moment" : "Touch a bar to see it")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute.opacity(0.7))
                }
            }
            Spacer(minLength: 4)
            if selected != nil && rawSelection == nil {
                Button { withAnimation(.easeOut(duration: 0.15)) { pinned = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundColor(Brand.mute)
                }
                .accessibilityLabel("Clear selection")
            }
            Button(action: close) {
                Label("All sessions", systemImage: "xmark").labelStyle(.titleAndIcon)
                    .font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText)
                    .padding(.horizontal, 10).frame(height: 26)
                    .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
            }
            .accessibilityLabel("Back to all sessions")
        }
        .frame(minHeight: 34, alignment: .top)
    }
}

// MARK: - A session row (collapsed: one number; expanded: everything)

struct SessionRow: View {
    let session: StatsSession
    let previous: StatsSession?
    let subject: StatsSubject
    let panel: StatPanel
    let expanded: Bool
    let toggle: () -> Void

    private var isWorkout: Bool { if case .workout = subject { return true } else { return false } }

    private func value(_ s: StatsSession?) -> Double? {
        guard let s, let series = panel.primary else { return nil }
        return series.points.first { $0.date == s.date }?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                        Text(isWorkout ? "\(session.setCount) sets" : session.title)
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(value(session).map(panel.format) ?? "—")
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                        if let v = value(session), let p = value(previous), v != p {
                            let up = v > p
                            let good = panel.higherIsBetter.map { up == $0 }
                            Text("\(up ? "▲" : "▼") \(panel.format(abs(v - p)))")
                                .font(BrandFont.body(10, .bold))
                                .foregroundColor(good == nil ? Brand.mute : (good! ? Brand.voltText : .orange))
                        }
                    }
                    if !session.notes.isEmpty {
                        Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundColor(Brand.voltText)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(Brand.line).padding(.horizontal, 14)
                SessionDetailBody(session: session, isWorkout: isWorkout)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(expanded ? Brand.voltLine.opacity(0.6) : Brand.line, lineWidth: 1))
    }
}

// MARK: - Everything about one session

struct SessionDetailBody: View {
    let session: StatsSession
    let isWorkout: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label(StatsUnits.weightText(session.volume), systemImage: "scalemass.fill")
                if let hr = session.hr { Label("\(hr.avg) avg · \(hr.peak) peak", systemImage: "heart.fill") }
                if let m = session.durationMin { Label("\(m)m", systemImage: "clock") }
            }
            .font(BrandFont.body(11, .semibold)).foregroundColor(Color(hex: 0x3D9BE0))
            .lineLimit(1).minimumScaleFactor(0.7)

            ForEach(session.exercises) { ex in exerciseBlock(ex) }

            if !session.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.notes) { n in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: n.icon).font(.system(size: 11)).foregroundColor(Brand.voltText).frame(width: 14)
                            Text(n.text).font(BrandFont.body(11)).foregroundColor(Brand.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .background(Brand.volt.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func exerciseBlock(_ ex: ExerciseStat) -> some View {
        let sensor = ex.hasMotion
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let l = ex.sbd { Circle().fill(l.color).frame(width: 7, height: 7) }
                Text(ex.name).font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                Spacer()
                Text("e1RM \(StatsUnits.weightText(ex.bestE1RM))").font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText)
            }
            HStack(spacing: 4) {
                col("SET", 26, .leading); col("LOAD", nil, .leading); col("REPS", 32, .trailing); col("RPE", 28, .trailing)
                if sensor { col("M/S", 40, .trailing); col("LOSS", 36, .trailing); col("", 14, .trailing) }
            }
            .font(BrandFont.body(8, .bold)).tracking(0.6).foregroundColor(Brand.mute)

            ForEach(ex.sets) { st in
                if sensor, st.motion != nil {
                    NavigationLink {
                        RepDetailView(setStat: st, exerciseName: ex.name, date: session.date)
                    } label: { setRow(st, sensor: true, link: true) }
                    .buttonStyle(.plain)
                } else {
                    setRow(st, sensor: sensor, link: false)
                }
            }
            if sensor {
                Text("Tap a set to see every rep.").font(BrandFont.body(10)).foregroundColor(Brand.mute)
            }
        }
    }

    private func setRow(_ st: SetStat, sensor: Bool, link: Bool) -> some View {
        HStack(spacing: 4) {
            col("\(st.number)", 26, .leading).foregroundColor(Brand.mute)
            col(StatsUnits.weightText(st.weight), nil, .leading).foregroundColor(Brand.text)
            col("\(st.reps)", 32, .trailing).foregroundColor(Brand.text)
            col(st.rpe.map { $0.rpeText } ?? "—", 28, .trailing).foregroundColor(Brand.voltText)
            if sensor {
                if let m = st.motion {
                    col(String(format: "%.2f", m.meanVelocity), 40, .trailing).foregroundColor(Brand.text)
                    col(m.velocityLossPct.map { "\(Int($0.rounded()))%" } ?? "—", 36, .trailing).foregroundColor(Brand.text)
                } else {
                    col("—", 40, .trailing).foregroundColor(Brand.mute)
                    col("", 36, .trailing)
                }
                Group {
                    if link {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(Brand.mute)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, height: 12, alignment: .trailing)
            }
        }
        .font(BrandFont.body(12, .semibold))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func col(_ t: String, _ width: CGFloat?, _ align: Alignment) -> some View {
        Group {
            if let width { Text(t).frame(width: width, alignment: align) }
            else { Text(t).frame(maxWidth: .infinity, alignment: align) }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }
}

// MARK: - One set, rep by rep ("lift" level)

struct RepDetailView: View {
    let setStat: SetStat
    let exerciseName: String
    let date: Date

    private var motion: SetMotion? { setStat.motion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(exerciseName) · Set \(setStat.number)").font(BrandFont.display(30)).foregroundColor(Brand.text)
                        .lineLimit(2).minimumScaleFactor(0.6)
                    Text("\(date.formatted(date: .abbreviated, time: .omitted)) · \(setStat.reps) × \(StatsUnits.weightText(setStat.weight))\(setStat.rpe.map { " · RPE \($0.rpeText)" } ?? "")")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }

                if let m = motion {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        tile(StatsUnits.velocityText(m.meanVelocity), "AVG SPEED")
                        tile(StatsUnits.velocityText(m.peakVelocity), "PEAK SPEED")
                        tile(m.velocityLossPct.map { "\(Int($0.rounded()))%" } ?? "—", "SPEED LOSS")
                        tile(StatsUnits.depthText(m.averageTravelM), "AVG DEPTH")
                        tile(m.travelConsistencyPct.map { "\(Int($0.rounded()))%" } ?? "—", "CONSISTENCY")
                        tile("\(Int(m.timeUnderTensionSec.rounded()))s", "UNDER TENSION")
                    }

                    chartCard("BAR SPEED PER REP", caption: "Bars = average on the way up, dots = peak") {
                        Chart {
                            ForEach(m.reps) { r in
                                BarMark(x: .value("Rep", "\(r.index)"), y: .value("Avg", r.meanVelocity))
                                    .foregroundStyle(r.isGrind ? Color.orange : Brand.voltLine).cornerRadius(3)
                                PointMark(x: .value("Rep", "\(r.index)"), y: .value("Peak", r.peakVelocity))
                                    .foregroundStyle(Brand.text).symbolSize(18)
                            }
                        }
                    }

                    chartCard("DEPTH PER REP", caption: nil) {
                        Chart {
                            ForEach(m.reps) { r in
                                BarMark(x: .value("Rep", "\(r.index)"), y: .value("Depth", StatsUnits.depth(r.travelM)))
                                    .foregroundStyle(Color(hex: 0x3D9BE0)).cornerRadius(3)
                            }
                        }
                    }

                    chartCard("TEMPO PER REP", caption: "Lowering · pause at the bottom · lifting") {
                        Chart {
                            ForEach(m.reps) { r in
                                BarMark(x: .value("Rep", "\(r.index)"), y: .value("Seconds", r.eccentricSec ?? 0))
                                    .foregroundStyle(by: .value("Phase", "Lowering"))
                                BarMark(x: .value("Rep", "\(r.index)"), y: .value("Seconds", r.bottomPauseSec ?? 0))
                                    .foregroundStyle(by: .value("Phase", "Pause"))
                                BarMark(x: .value("Rep", "\(r.index)"), y: .value("Seconds", r.concentricSec))
                                    .foregroundStyle(by: .value("Phase", "Lifting"))
                            }
                        }
                        .chartForegroundStyleScale(["Lowering": Color(hex: 0x3D9BE0), "Pause": Brand.text, "Lifting": Brand.voltLine])
                        .chartLegend(position: .bottom, alignment: .leading)
                    }

                    repTable(m)
                } else {
                    Text("No Watch data for this set.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BrandFont.body(15, .bold)).foregroundColor(Brand.voltText).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(BrandFont.body(8, .bold)).tracking(0.8).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }

    private func chartCard<C: View>(_ title: String, caption: String?, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
            chart()
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Brand.line)
                        AxisValueLabel().foregroundStyle(Brand.mute)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(Brand.mute) }
                }
                .frame(height: 130)
            if let caption { Text(caption).font(BrandFont.body(10)).foregroundColor(Brand.mute) }
        }
        .padding(12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
    }

    private func repTable(_ m: SetMotion) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                cell("REP", 30, .leading); cell("SPEED", nil, .trailing); cell("DEPTH", nil, .trailing)
                cell("DOWN", nil, .trailing); cell("PAUSE", nil, .trailing); cell("UP", nil, .trailing)
            }
            .font(BrandFont.body(8, .bold)).tracking(0.6).foregroundColor(Brand.mute)
            .padding(.bottom, 6)
            ForEach(m.reps) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        cell("\(r.index)", 30, .leading).foregroundColor(Brand.mute)
                        cell(String(format: "%.2f", r.meanVelocity), nil, .trailing).foregroundColor(r.isGrind ? .orange : Brand.text)
                        cell(String(format: "%.1f", StatsUnits.depth(r.travelM)), nil, .trailing)
                        cell(r.eccentricSec.map { String(format: "%.1fs", $0) } ?? "—", nil, .trailing)
                        cell(r.bottomPauseSec.map { String(format: "%.2fs", $0) } ?? "—", nil, .trailing)
                        cell(String(format: "%.1fs", r.concentricSec), nil, .trailing)
                    }
                    .foregroundColor(Brand.text)
                    HStack(spacing: 6) {
                        Text(pauseLabel(r.pauseStyle)).foregroundColor(r.pauseStyle == .paused ? Brand.voltText : Brand.mute)
                        if let sp = r.stickingPoint { Text("· slowest \(Int(sp * 100))% up").foregroundColor(Brand.mute) }
                        if r.isGrind { Text("· grind").foregroundColor(.orange) }
                    }
                    .font(BrandFont.body(10)).padding(.leading, 34)
                }
                .font(BrandFont.body(12, .semibold))
                .padding(.vertical, 7)
                Divider().overlay(Brand.line)
            }
            Text("Depth in \(StatsUnits.depthLabel), speed in m/s.")
                .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        .padding(12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
    }

    private func pauseLabel(_ p: PauseStyle) -> String {
        switch p {
        case .none: return "No pause before (first pull)"
        case .touchAndGo: return "Touch-and-go"
        case .brief: return "Brief pause"
        case .paused: return "Paused"
        }
    }

    private func cell(_ t: String, _ width: CGFloat?, _ align: Alignment) -> some View {
        Group {
            if let width { Text(t).frame(width: width, alignment: align) }
            else { Text(t).frame(maxWidth: .infinity, alignment: align) }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }
}

// MARK: - Choose a metric (every option visible at once)

private struct MetricChooser: View {
    let panels: [StatPanel]
    let current: String
    let pick: (String) -> Void

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a metric").font(BrandFont.display(28)).foregroundColor(Brand.text)
                    Text("\(panels.count) for this lift").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                ForEach(StatCategory.allCases) { cat in
                    let inCat = panels.filter { $0.category == cat }
                    if !inCat.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            DSSectionHeader(title: cat.rawValue.uppercased())
                            LazyVGrid(columns: cols, spacing: 10) {
                                ForEach(inCat) { p in
                                    let on = p.id == current
                                    Button { pick(p.id) } label: {
                                        HStack(spacing: 8) {
                                            Text(p.title).font(BrandFont.body(14, .bold))
                                                .foregroundColor(on ? Brand.onVolt : Brand.text)
                                                .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt) }
                                        }
                                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 52)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(on ? Brand.volt : Brand.black))
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Brand.voltLine : Brand.line, lineWidth: 1))
                                    }
                                    .buttonStyle(PressableStyle())
                                    .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bg.ignoresSafeArea())
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Brand.bg)
    }
}

// MARK: - Choose a lift (any exercise you've done)

struct LiftChooser: View {
    struct Lift: Identifiable {
        var id: String { name }
        let name: String
        let sessions: Int
        let last: Date
        let sensor: Bool
    }
    let lifts: [Lift]
    let current: StatsSubject
    let pick: (String) -> Void
    @State private var query = ""

    private var shown: [Lift] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? lifts : lifts.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a lift").font(BrandFont.display(28)).foregroundColor(Brand.text)
                    Text("\(lifts.count) you've done · most recent first").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.mute)
                    TextField("", text: $query, prompt: Text("Search lifts").foregroundColor(Brand.mute))
                        .foregroundColor(Brand.text).autocorrectionDisabled()
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))

                if shown.isEmpty {
                    Text("No lifts match “\(query)”.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }
                VStack(spacing: 8) {
                    ForEach(shown) { l in
                        let on = current == .exercise(l.name)
                        Button { pick(l.name) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.name).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                    Text("\(l.sessions) session\(l.sessions == 1 ? "" : "s") · last \(l.last.formatted(.dateTime.month(.abbreviated).day()))")
                                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                                }
                                Spacer(minLength: 6)
                                if l.sensor {
                                    Image(systemName: "applewatch").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.voltText)
                                        .accessibilityLabel("Has Watch data")
                                }
                                if on {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(Brand.voltText)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Brand.voltLine : Brand.line, lineWidth: 1))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Brand.bg)
    }
}

