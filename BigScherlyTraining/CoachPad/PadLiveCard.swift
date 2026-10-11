import SwiftUI
import Charts

// MARK: - Coach HQ on iPad: Live · the client's own card (Oct 10, 2026)
//
// What the client sees on their workout screen, drawn at iPad size from what their phone sends:
// the status bar, the metric windows (bar speed, heart rate, tempo, coach notes, sets, session),
// the set card with its big tile (Start set · rest draining · lifting timer · Log set) and the
// same pills. Same colours and type as the phone (Brand, not the iPad's Pad palette).
// The coach's layer is drawn on top in volt: their usual bar speed (dashed), the zone-4 line,
// "Changed by you" under a set. The tile and pills work: they run on the client's phone.
// Synchronized folder: no target step needed.

// MARK: Everything a window needs, worked out once per redraw

struct PadLiveCtx {
    let phone: PadLivePhone
    let state: LiveStateMsg
    let workout: Workout?

    var card: WorkoutActivityAttributes.ContentState { state.card }
    var lifting: Bool { card.stage == .lifting && !card.logNeeded }
    /// In a set: lifting, or done and waiting to be logged (the windows still show this set).
    var inSet: Bool { card.stage == .lifting }
    var clientId: String { phone.clientId ?? "" }
    var firstName: String { phone.name.firstName }

    /// The set in progress, rep by rep (the Watch's reps since it started).
    var currentReps: [RepMotion] {
        guard let start = card.setStart else { return state.liveReps }
        return state.liveReps.filter { $0.start >= start.addingTimeInterval(-5) }
    }
    /// What the windows show: the set in progress while lifting, otherwise the last set with Watch data.
    var shownReps: [RepMotion] { inSet ? currentReps : (state.lastSet?.reps ?? []) }
    var shownSpeeds: [Double] {
        let r = shownReps
        if !r.isEmpty { return r.map { $0.meanVelocity } }
        return inSet ? [] : card.speeds
    }
    var lastLabel: String {
        if lifting { return "LIVE" }
        if inSet { return "\(card.exercise) · Set \(card.setNumber)" }
        if let l = state.lastSet, let w = workout, let ex = w.exercises.first(where: { $0.id == l.exerciseId }) {
            return "\(ex.name) · Set \(l.setNumber)"
        }
        return card.lastSet ?? ""
    }

    /// The goal weight on the card, in lb (the card is in the client's units).
    var goalLb: Double { card.unit == "kg" ? card.goalWeight / 0.45359237 : card.goalWeight }

    var usual: Double? {
        PadLiveMath.usualSpeed(clientId: clientId, exercise: card.exercise, weightLb: goalLb, excluding: workout?.id)
    }

    /// Unlogged sets in order: (exercise, set, number in the exercise).
    var unlogged: [(Exercise, ExerciseSet, Int)] {
        var out: [(Exercise, ExerciseSet, Int)] = []
        for e in workout?.exercises ?? [] {
            for (i, s) in e.sets.enumerated() where s.loggedReps == nil { out.append((e, s, i + 1)) }
        }
        return out
    }
    /// The set on the card: the one being lifted, or up next.
    var cardSet: (Exercise, ExerciseSet, Int)? { unlogged.first }
    /// The set the coach adjusts: the one after the set being lifted, otherwise the one up next.
    var nextSet: (Exercise, ExerciseSet, Int)? {
        let u = unlogged
        if card.stage == .lifting { return u.count > 1 ? u[1] : nil }
        return u.first
    }

    /// The phone's coach notes for the last set (same rules as on the client's card).
    var notes: [CoachNote] {
        guard let l = state.lastSet, let w = workout,
              let ex = w.exercises.first(where: { $0.id == l.exerciseId }),
              let set = ex.sets.first(where: { $0.id == l.setId }) else { return [] }
        let m = SetMotion(id: l.setId, workoutId: w.id, exerciseId: ex.id, setId: set.id, exerciseName: ex.name,
                          start: l.reps.first?.start ?? Date(), end: l.reps.last?.end ?? Date(), reps: l.reps,
                          autoDetected: true, analyzerVersion: 0)
        let history: [Workout] = (PadData.shared.workouts[clientId] ?? []).filter { $0.id != w.id } + [w]
        return CoachNotes.make(exercise: ex, set: set, motion: m, pauseTarget: PauseTarget.target(ex), workouts: history)
    }

    static func make(_ p: PadLivePhone) -> PadLiveCtx? {
        guard let s = p.state else { return nil }
        return PadLiveCtx(phone: p, state: s, workout: p.workout?.toModel())
    }
}

// MARK: Metrics

enum PadLiveMetric: String, CaseIterable, Identifiable {
    case speed, heart, tempo, notes, sets, session
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "Bar speed"
        case .heart: return "Heart rate"
        case .tempo: return "Tempo"
        case .notes: return "Coach notes"
        case .sets: return "Sets"
        case .session: return "Session"
        }
    }
    var icon: String {
        switch self {
        case .speed: return "gauge.with.dots.needle.67percent"
        case .heart: return "heart.fill"
        case .tempo: return "metronome.fill"
        case .notes: return "sparkles"
        case .sets: return "list.bullet"
        case .session: return "sum"
        }
    }

    static func list(_ raw: String, count: Int) -> [PadLiveMetric] {
        var m: [PadLiveMetric] = []
        for r in raw.split(separator: ",") { if let x = PadLiveMetric(rawValue: String(r)), !m.contains(x) { m.append(x) } }
        for x in allCases where m.count < count && !m.contains(x) { m.append(x) }
        return Array(m.prefix(count))
    }
}

private let orange = Color(hex: 0xF2A03D)
private let blue = Color(hex: 0x3D9BE0)
private let axisFont = Font.system(size: 9, weight: .semibold)

struct PadLiveMetricHeader: View {
    let metric: PadLiveMetric
    var right: String = ""
    var live = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: metric.icon).font(.system(size: 11, weight: .bold)).foregroundColor(Brand.voltText)
            Text(metric.title.uppercased()).font(BrandFont.body(10, .heavy)).tracking(1.3).foregroundColor(Brand.mute)
            Spacer(minLength: 4)
            if live {
                HStack(spacing: 5) {
                    Circle().fill(Brand.danger).frame(width: 6, height: 6)
                    Text("LIVE").font(BrandFont.body(9, .heavy)).tracking(1.2).foregroundColor(Brand.danger)
                }
            } else if !right.isEmpty {
                Text(right).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute).lineLimit(1)
            }
        }
    }
}

/// One window of the card: a metric, and its dots underneath (tap one to change what it shows).
struct PadLiveWindow: View {
    let ctx: PadLiveCtx
    let metric: PadLiveMetric
    let options: [PadLiveMetric]
    let pick: (PadLiveMetric) -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.leading, 16).padding(.trailing, 18).padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            HStack(spacing: 0) {
                ForEach(options) { m in
                    Button { withAnimation(.easeOut(duration: 0.15)) { pick(m) } } label: {
                        Capsule().fill(m == metric ? Brand.voltLine : Brand.mute.opacity(0.45))
                            .frame(width: m == metric ? 16 : 6, height: 6)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(m.title)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder private var content: some View {
        switch metric {
        case .speed: PadLiveSpeed(ctx: ctx)
        case .heart: PadLiveHeart(ctx: ctx)
        case .tempo: PadLiveTempo(ctx: ctx)
        case .notes: PadLiveNotesMetric(ctx: ctx)
        case .sets: PadLiveSetsMetric(ctx: ctx)
        case .session: PadLiveSessionMetric(ctx: ctx)
        }
    }
}

private struct PadLiveEmpty: View {
    let metric: PadLiveMetric
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PadLiveMetricHeader(metric: metric)
            Spacer(minLength: 0)
            Text(text).font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Bar speed (with their usual, dashed)

struct PadLiveSpeed: View {
    let ctx: PadLiveCtx
    private struct Bar: Identifiable { let id: Int; let rep: String; let v: Double; let slow: Bool }

    var body: some View {
        let vals: [Double] = ctx.shownSpeeds
        let planned: Int = ctx.lifting ? max(ctx.card.goalReps, vals.count) : vals.count
        let target: Int = max(planned, 1)
        let best: Double = vals.prefix(2).max() ?? 0
        let bars: [Bar] = vals.enumerated().map { Bar(id: $0.offset, rep: "\($0.offset + 1)", v: $0.element, slow: best > 0 && $0.element < best * 0.8) }
        let usual: Double? = ctx.usual
        let top: Double = max(0.6, max(vals.max() ?? 0.5, usual ?? 0) * 1.2)
        let loss: Double? = CoachNotes.speedLoss(vals)
        let lossColor: Color = (loss ?? 0) >= 20 ? orange : Brand.mute
        if vals.isEmpty && !ctx.lifting {
            PadLiveEmpty(metric: .speed, text: "Bar speed fills in here once \(ctx.firstName) lifts with the Watch on.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                PadLiveMetricHeader(metric: .speed, right: ctx.lastLabel, live: ctx.lifting)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(vals.last.map { String(format: "%.2f", $0) } ?? "—").font(BrandFont.display(44)).foregroundColor(Brand.text).monospacedDigit()
                    Text(ctx.lifting ? (vals.isEmpty ? "m/s · waiting for rep 1" : "m/s · this rep") : "m/s · last rep")
                        .font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                    Spacer()
                    if let loss { Text("Loss \(Int(loss))%").font(BrandFont.body(12, .heavy)).foregroundColor(lossColor) }
                }
                if bars.isEmpty {
                    Spacer(minLength: 0)
                    Text("Waiting for rep 1…").font(BrandFont.body(12)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    Chart {
                        ForEach(bars) { b in
                            BarMark(x: .value("Rep", b.rep), y: .value("m/s", b.v), width: .ratio(0.55))
                                .foregroundStyle(b.slow ? orange : Brand.voltLine)
                                .cornerRadius(5)
                                .annotation(position: .top, spacing: 2) {
                                    Text(String(format: "%.2f", b.v)).font(.system(size: 9, weight: .bold)).foregroundColor(Brand.mute)
                                }
                        }
                        if let u = usual {
                            RuleMark(y: .value("Usual", u))
                                .foregroundStyle(Brand.voltLine)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                    Text("THEIR USUAL · \(String(format: "%.2f", u))").font(.system(size: 9, weight: .heavy))
                                        .foregroundColor(Brand.voltText)
                                        .padding(.horizontal, 4).background(Brand.card)
                                }
                        }
                    }
                    .chartXScale(domain: (1...target).map { "\($0)" })
                    .chartYScale(domain: 0...top)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Brand.line)
                            AxisValueLabel().font(axisFont).foregroundStyle(Brand.mute)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in AxisValueLabel().font(axisFont).foregroundStyle(Brand.mute) }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: vals)
                }
            }
        }
    }
}

// MARK: Heart rate (with the zone-4 line)

struct PadLiveHeart: View {
    let ctx: PadLiveCtx
    private struct Pt: Identifiable { let id: Double; let x: Double; let bpm: Int }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { tl in
            chart(now: tl.date)
        }
    }

    @ViewBuilder private func chart(now: Date) -> some View {
        let cutoff: Date = now.addingTimeInterval(-600)
        let pts: [Pt] = ctx.phone.hr.filter { $0.at >= cutoff }.map { Pt(id: $0.at.timeIntervalSinceReferenceDate, x: $0.at.timeIntervalSince(now) / 60, bpm: $0.bpm) }
        let bpm: Int? = ctx.state.hr ?? ctx.card.hr
        let peak: Int = ctx.phone.hr.map { $0.bpm }.max() ?? bpm ?? 0
        let maxHR: Int = ctx.card.hrMax ?? 190
        let z4: Int = Int((Double(maxHR) * 0.8).rounded())
        let floorV: Int = max(40, (pts.map { $0.bpm }.min() ?? 60) - 10)
        let ceilV: Int = max(max(100, peak + 8), z4 + 6)
        let zoneText: String = ctx.card.hrZone.map { "Zone \($0)" + (ctx.card.hrPct.map { " · \($0)%" } ?? "") } ?? ""
        if bpm == nil && pts.isEmpty {
            PadLiveEmpty(metric: .heart, text: "Heart rate comes from \(ctx.firstName)'s Apple Watch.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                PadLiveMetricHeader(metric: .heart, right: peak > 0 ? "PEAK \(peak)" : "")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(bpm.map { "\($0)" } ?? "—").font(BrandFont.display(44)).foregroundColor(Brand.text).monospacedDigit()
                    Text("bpm").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                    Spacer()
                    Text(zoneText).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                }
                if pts.count < 2 {
                    Text("Building the heart-rate trend…").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Chart {
                        ForEach(pts) { p in
                            AreaMark(x: .value("Minutes", p.x), yStart: .value("Floor", floorV), yEnd: .value("bpm", p.bpm))
                                .foregroundStyle(LinearGradient(colors: [Brand.danger.opacity(0.28), Brand.danger.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Minutes", p.x), y: .value("bpm", p.bpm))
                                .foregroundStyle(Brand.danger).lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.monotone)
                        }
                        RuleMark(y: .value("Zone 4", z4))
                            .foregroundStyle(Brand.voltLine.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text("ZONE 4 · \(z4)").font(.system(size: 9, weight: .heavy)).foregroundColor(Brand.voltText)
                            }
                    }
                    .chartXScale(domain: -10.0...0.0)
                    .chartYScale(domain: floorV...ceilV)
                    .chartXAxis {
                        AxisMarks(values: [-10.0, -8.0, -6.0, -4.0, -2.0, 0.0]) { v in
                            AxisValueLabel {
                                if let m = v.as(Double.self) { Text(m == 0 ? "now" : "\(Int(m))m").font(axisFont).foregroundColor(Brand.mute) }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Brand.line)
                            AxisValueLabel().font(axisFont).foregroundStyle(Brand.mute)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Tempo (lower · pause · lift)

struct PadLiveTempo: View {
    let ctx: PadLiveCtx
    var body: some View {
        let reps: [RepMotion] = ctx.shownReps
        if reps.isEmpty {
            PadLiveEmpty(metric: .tempo, text: "Lowering, pause and lifting time for each rep, from the Watch.")
        } else {
            let ecc: Double = avg(reps.compactMap { $0.eccentricSec })
            let pause: Double = avg(reps.compactMap { $0.bottomPauseSec })
            let con: Double = avg(reps.map { $0.concentricSec })
            let big: String = String(format: "%.1f–%.1f–%.1f", ecc, pause, con)
            let longest: Double = reps.map { ($0.eccentricSec ?? 0) + ($0.bottomPauseSec ?? 0) + $0.concentricSec }.max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                PadLiveMetricHeader(metric: .tempo, right: ctx.lastLabel, live: ctx.lifting)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(big).font(BrandFont.display(34)).foregroundColor(Brand.text).monospacedDigit()
                    Text("lower · pause · lift").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                }
                ForEach(reps.suffix(6)) { r in row(r, longest: longest) }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    legend("lower", blue); legend("pause", orange); legend("lift", Brand.voltLine)
                }
            }
        }
    }

    private func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    private func row(_ r: RepMotion, longest: Double) -> some View {
        let e: Double = r.eccentricSec ?? 0
        let p: Double = r.bottomPauseSec ?? 0
        let c: Double = r.concentricSec
        let total: Double = e + p + c
        return HStack(spacing: 8) {
            Text("rep \(r.index)").font(.system(size: 9, weight: .semibold)).foregroundColor(Brand.mute).frame(width: 32, alignment: .leading)
            GeometryReader { g in
                let w: CGFloat = g.size.width * CGFloat(total / max(longest, 0.1))
                HStack(spacing: 0) {
                    Rectangle().fill(blue).frame(width: w * CGFloat(e / max(total, 0.01)))
                    Rectangle().fill(orange).frame(width: w * CGFloat(p / max(total, 0.01)))
                    Rectangle().fill(Brand.voltLine).frame(width: w * CGFloat(c / max(total, 0.01)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            Text(String(format: "%.1fs", total)).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Brand.text).frame(width: 36, alignment: .trailing)
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 9, weight: .semibold)).foregroundColor(Brand.mute)
        }
    }
}

// MARK: Coach notes (the phone's, for the last set)

struct PadLiveNotesMetric: View {
    let ctx: PadLiveCtx
    var body: some View {
        let notes: [CoachNote] = ctx.notes
        let reps: [RepMotion] = ctx.state.lastSet?.reps ?? []
        if notes.isEmpty && reps.isEmpty {
            PadLiveEmpty(metric: .notes, text: "The notes \(ctx.firstName) sees after each set (tempo, pause, bar speed, depth) show here too.")
        } else {
            let v: [Double] = reps.map { $0.meanVelocity }
            let avgV: String = v.isEmpty ? "—" : String(format: "%.2f", v.reduce(0, +) / Double(v.count))
            let lossV: Double? = CoachNotes.speedLoss(v)
            let lossT: String = lossV.map { "−\(Int($0))%" } ?? "—"
            VStack(alignment: .leading, spacing: 8) {
                PadLiveMetricHeader(metric: .notes, right: ctx.state.lastSet == nil ? "" : (ctx.lifting ? "Last set" : ctx.lastLabel))
                if !reps.isEmpty {
                    HStack(spacing: 8) {
                        summary("\(reps.count)", "REPS", Brand.text)
                        summary(avgV, "AVG M/S", Brand.text)
                        summary(lossT, "SPEED LOSS", (lossV ?? 0) >= 20 ? orange : Brand.text)
                    }
                }
                ForEach(notes.prefix(3)) { n in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: n.icon).font(.system(size: 12, weight: .bold)).foregroundColor(n.color)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(n.color.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.title).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.8)
                            Text(n.detail).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(BrandFont.body(18, .heavy)).foregroundColor(c)
            Text(l).font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: Sets (this exercise) and Session

struct PadLiveSetsMetric: View {
    let ctx: PadLiveCtx
    var body: some View {
        let ex: Exercise? = ctx.workout?.exercises.first { $0.name == ctx.card.exercise }
        VStack(alignment: .leading, spacing: 6) {
            PadLiveMetricHeader(metric: .sets, right: ctx.card.exercise)
            if let ex {
                ForEach(Array(ex.sets.enumerated()), id: \.element.id) { i, s in
                    let isCur: Bool = ctx.cardSet?.1.id == s.id
                    let logged: String? = loggedText(s)
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(BrandFont.body(11, .heavy))
                            .foregroundColor(logged != nil ? Brand.onVolt : (isCur ? Brand.danger : Brand.mute))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(logged != nil ? Brand.volt : Color.clear))
                            .overlay(Circle().stroke(isCur ? Brand.danger : Brand.line, lineWidth: logged != nil ? 0 : 1.5))
                        Text(logged ?? PadLiveMath.planText(s)).font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundColor(logged != nil ? Brand.text : Brand.mute)
                        Spacer()
                        if let was = ctx.phone.changed[s.id] {
                            Text("CHANGED · \(was)").font(BrandFont.body(9, .heavy)).foregroundColor(Brand.voltText)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func loggedText(_ s: ExerciseSet) -> String? {
        guard let r = s.loggedReps else { return nil }
        let lw: Double = s.loggedWeight ?? 0
        let w: String = lw > 0 ? SetTarget.weightText(lw) : "BW"
        let rpe: String = s.rpe.map { " · RPE " + $0.rpeText } ?? ""
        return "\(r) × " + w + rpe
    }
}

struct PadLiveSessionMetric: View {
    let ctx: PadLiveCtx
    var body: some View {
        let c = ctx.card
        let peak: Int = ctx.phone.hr.map { $0.bpm }.max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            PadLiveMetricHeader(metric: .session)
            HStack(spacing: 8) {
                tile("\(c.setsDone)/\(c.setsTotal)", "SETS")
                tile("\(c.exDone)/\(c.exTotal)", "EXERCISES")
            }
            HStack(spacing: 8) {
                tile(c.volume > 0 ? "\(c.volume)" : "—", "VOLUME · \(c.unit.uppercased())")
                tile(peak > 0 ? "\(peak)" : "—", "PEAK BPM")
            }
            Spacer(minLength: 0)
        }
    }
    private func tile(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BrandFont.display(28)).foregroundColor(Brand.text)
            Text(l).font(BrandFont.body(8.5, .heavy)).tracking(0.8).foregroundColor(Brand.mute)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: - Status bar

struct PadLiveStatusBar: View {
    let ctx: PadLiveCtx
    var body: some View {
        let c = ctx.card
        let bpm: Int? = ctx.state.hr ?? c.hr
        HStack(spacing: 6) {
            Circle().fill(ctx.state.watchLive ? Brand.danger : Brand.mute.opacity(0.5)).frame(width: 7, height: 7)
            Text(ctx.state.elapsedSince, style: .timer).font(BrandFont.body(13, .heavy)).monospacedDigit().foregroundColor(Brand.text)
            Text("· \(c.setsDone)/\(c.setsTotal) sets").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            Spacer(minLength: 4)
            if ctx.state.watchLive {
                Image(systemName: "applewatch").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.voltText)
            }
            if let bpm {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(Brand.danger)
                    Text("\(bpm)").font(BrandFont.body(13, .heavy)).monospacedDigit().foregroundColor(Brand.text)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The set card (the big tile: it runs on their phone)

struct PadLiveSetCard: View {
    let ctx: PadLiveCtx
    var compact = false                       // the pinned bar in the top bar
    let send: (LiveCommand) -> Void

    private var tile: CGSize { compact ? CGSize(width: 66, height: 44) : CGSize(width: 128, height: 92) }

    var body: some View {
        let c = ctx.card
        switch c.stage {
        case .resting:
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in resting(now: tl.date) }
        case .lifting:
            if c.logNeeded { logging } else { lifting }
        case .ready:
            ready
        case .done:
            finished
        }
    }

    private var setOf: String { "SET \(ctx.card.setNumber) OF \(ctx.card.setCount)" }
    private var goal: String { ctx.card.goalText ?? "\(ctx.card.goalReps) × \(ctx.card.goalWeight.rpeText) \(ctx.card.unit)" }
    private var changedNote: String? { ctx.cardSet.flatMap { ctx.phone.changed[$0.1.id] } }

    private var ready: some View {
        row(tile: {
                Button { send(LiveCommand(t: "startSet")) } label: {
                    filled(icon: "play.fill", label: compact ? nil : "Start set \(ctx.card.setNumber)")
                }
                .buttonStyle(.plain)
            },
            title: ctx.card.exercise, kicker: setOf, kickerColor: Brand.mute, value: goal, valueColor: Brand.voltText) {
            if let was = changedNote { changed(was) }
        }
    }

    private func resting(now: Date) -> some View {
        let end: Date = ctx.card.restEnd ?? now
        let left: Double = max(0, end.timeIntervalSince(now))
        let total: Double = max(1, end.timeIntervalSince(ctx.card.restStart ?? now))
        let frac: Double = min(1, left / total)
        let r: Int = Int(ceil(left))
        let clock: String = String(format: "%d:%02d", r / 60, r % 60)
        return row(tile: { restTile(frac: frac, clock: clock) },
                   title: ctx.card.exercise, kicker: "UP NEXT · " + setOf, kickerColor: Brand.mute, value: goal, valueColor: Brand.voltText) {
            if let was = changedNote { changed(was) }
            pill("+30s", filled: false) { send(LiveCommand(t: "addRest", seconds: 30)) }
            pill("Skip", filled: true) { send(LiveCommand(t: "skipRest")) }
        }
    }

    private var lifting: some View {
        let reps: [RepMotion] = ctx.currentReps
        let loss: Double? = CoachNotes.speedLoss(reps.map { $0.meanVelocity })
        let value: String = reps.isEmpty ? "Waiting for rep 1" : "\(reps.count) of \(ctx.card.goalReps) reps"
        return row(tile: { liftTile },
                   title: ctx.card.exercise, kicker: setOf + " · LIFTING", kickerColor: Brand.danger, value: value, valueColor: Brand.text) {
            if let loss, reps.count >= 2 {
                Text("Speed −\(Int(loss))%").font(BrandFont.body(12, .heavy))
                    .foregroundColor(loss >= 20 ? orange : Brand.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(Capsule().stroke(Brand.line, lineWidth: 1.5))
            }
            pill("End set", filled: false, coach: true) { send(LiveCommand(t: "endSet")) }
        }
    }

    private var logging: some View {
        let c = ctx.card
        let w: String = c.dWeight > 0 ? "\(c.dWeight.rpeText) \(c.unit)" : "BW"
        let value: String = "\(c.dReps) × \(w)" + (compact ? "" : " · RPE \(c.dRPE.rpeText)~")
        return row(tile: {
                Button { send(LiveCommand(t: "logSet")) } label: { filled(icon: "checkmark", label: compact ? nil : "Log set") }
                    .buttonStyle(.plain)
            },
            title: c.exercise, kicker: "SET \(c.editSet) DONE" + (c.doneByWatch == false ? "" : " · FROM THE WATCH"),
            kickerColor: Brand.mute, value: value, valueColor: Brand.text) {
            if !compact, let why = c.rpeWhy {
                Text(why).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.mute).lineLimit(1)
            }
        }
    }

    private var finished: some View {
        row(tile: {
                RoundedRectangle(cornerRadius: 16).fill(Brand.text.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark.seal.fill").font(.system(size: compact ? 18 : 28)).foregroundColor(Brand.voltText))
            },
            title: "All sets logged", kicker: "NICE WORK", kickerColor: Brand.mute, value: "\(ctx.card.setsDone) sets", valueColor: Brand.text) { EmptyView() }
    }

    // MARK: Building blocks (the phone's)

    private func row<T: View, A: View>(@ViewBuilder tile t: () -> T, title: String, kicker: String, kickerColor: Color,
                                       value: String, valueColor: Color, @ViewBuilder accessory: () -> A) -> some View {
        HStack(alignment: .center, spacing: compact ? 10 : 14) {
            t().frame(width: tile.width, height: tile.height)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: compact ? 1 : 3) {
                Text(title).font(BrandFont.body(compact ? 13 : 18, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.75)
                Text(kicker).font(BrandFont.body(compact ? 8 : 9.5, .heavy)).tracking(1.1).foregroundColor(kickerColor).lineLimit(1).minimumScaleFactor(0.75)
                Text(value).font(.system(size: compact ? 14 : 24, weight: .heavy, design: .rounded))
                    .foregroundColor(valueColor).lineLimit(1).minimumScaleFactor(0.7)
                if !compact {
                    HStack(spacing: 6) { accessory() }.padding(.top, 6)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }

    private func filled(icon: String, label: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: compact ? 16 : 26, weight: .heavy))
            if let label { Text(label).font(.system(size: 13, weight: .heavy)) }
        }
        .foregroundColor(Brand.onVolt)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Brand.volt))
        .contentShape(Rectangle())
    }

    private func restTile(frac: Double, clock: String) -> some View {
        let r: CGFloat = compact ? 12 : 16
        let w: CGFloat = compact ? 4 : 6
        return ZStack {
            RoundedRectangle(cornerRadius: r).fill(Brand.text.opacity(0.05))
            PadLiveTopCentreRect(radius: r).stroke(Brand.text.opacity(0.10), lineWidth: w).padding(w / 2)
            PadLiveTopCentreRect(radius: r).trim(from: 1 - frac, to: 1)
                .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .padding(w / 2)
                .animation(.linear(duration: 0.25), value: frac)
            VStack(spacing: 0) {
                if !compact { Text("REST").font(BrandFont.body(8, .heavy)).tracking(1.2).foregroundColor(Brand.mute) }
                Text(clock).font(.system(size: compact ? 15 : 28, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(Brand.text)
            }
        }
    }

    private var liftTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Brand.text.opacity(0.05))
            RoundedRectangle(cornerRadius: compact ? 12 : 16).stroke(Brand.voltLine, lineWidth: 1.5)
            VStack(spacing: 1) {
                if !compact {
                    Text("SET \(ctx.card.setNumber) · LIFTING").font(BrandFont.body(8, .heavy)).tracking(0.8).foregroundColor(Brand.voltText)
                }
                if let since = ctx.card.setStart {
                    Text(since, style: .timer).font(.system(size: compact ? 15 : 28, weight: .heavy, design: .rounded))
                        .monospacedDigit().foregroundColor(Brand.text)
                }
            }
        }
    }

    private func changed(_ was: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil").font(.system(size: 9, weight: .heavy))
            Text("CHANGED BY YOU · " + was).font(BrandFont.body(9, .heavy)).tracking(0.8).lineLimit(1)
        }
        .foregroundColor(Brand.voltText)
    }

    private func pill(_ t: String, filled: Bool, coach: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(BrandFont.body(12, .heavy))
                .foregroundColor(filled ? Brand.onVolt : (coach ? Brand.voltText : Brand.text))
                .padding(.horizontal, 13).frame(height: 30)
                .background(Capsule().fill(filled ? Brand.volt : Color.clear))
                .overlay(Capsule().stroke(filled ? Color.clear : (coach ? Brand.voltLine.opacity(0.6) : Brand.line), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// A rounded rectangle whose outline starts and ends at the top centre, clockwise (the rest border drains like the phone's).
struct PadLiveTopCentreRect: Shape {
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        let rad = min(radius, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.minY + rad), radius: rad, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - The exercise strip (their exercise cards, small)

struct PadLiveExerciseStrip: View {
    let ctx: PadLiveCtx
    var only: Bool = false                    // just the exercise on the card (side by side)

    var body: some View {
        let exs: [Exercise] = ctx.workout?.exercises ?? []
        let curId: String? = ctx.cardSet?.0.id
        if only {
            if let e = exs.first(where: { $0.id == curId }) {
                card(e, index: (exs.firstIndex { $0.id == e.id } ?? 0) + 1, total: exs.count, current: true)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(exs.enumerated()), id: \.element.id) { i, e in
                        card(e, index: i + 1, total: exs.count, current: e.id == curId).frame(width: 270)
                    }
                }
            }
        }
    }

    private func card(_ e: Exercise, index: Int, total: Int, current: Bool) -> some View {
        let kicker: String = "\(index) OF \(total)" + (e.muscleGroup.isEmpty ? "" : " · \(e.muscleGroup.uppercased())")
        let first: ExerciseSet? = e.sets.first
        let summary: String = first.map { "\(e.sets.count) × " + PadLiveMath.planText($0) } ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Text(kicker).font(BrandFont.body(9, .bold)).tracking(1.2).foregroundColor(current ? Brand.voltText : Brand.mute)
            Text(e.name).font(BrandFont.display(22)).foregroundColor(Brand.text).lineLimit(1)
            Text(summary).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
            HStack(spacing: 5) {
                ForEach(e.sets) { s in chip(s, current: ctx.cardSet?.1.id == s.id) }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(current ? Brand.voltLine.opacity(0.55) : Brand.line, lineWidth: 1))
    }

    private func chip(_ s: ExerciseSet, current: Bool) -> some View {
        let logged: Bool = s.loggedReps != nil
        let w: Double = logged ? (s.loggedWeight ?? 0) : s.targetWeight
        let reps: Int = s.loggedReps ?? s.targetReps
        let text: String = current && ctx.lifting ? "lifting" : "\(reps)×" + (w > 0 ? SetTarget.weightText(w, unit: false) : "BW")
        let changed: Bool = ctx.phone.changed[s.id] != nil
        let fg: Color = logged ? Brand.onVolt : (changed ? Brand.voltText : (current ? Brand.text : Brand.mute))
        let stroke: Color = logged ? Color.clear : (current ? Brand.danger : (changed ? Brand.voltLine : Brand.line))
        return Text(text).font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundColor(fg)
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(logged ? Brand.volt : Color.clear))
            .overlay(Capsule().stroke(stroke, lineWidth: 1.5))
    }
}

// MARK: - Card chrome

extension View {
    /// The phone's card: black, 22 pt corners, a hairline, a soft shadow.
    func padLiveCard(_ radius: CGFloat = 22, highlight: Color? = nil) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(Brand.card))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(highlight ?? Brand.line, lineWidth: highlight == nil ? 1 : 1.5))
            .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
    }
}
