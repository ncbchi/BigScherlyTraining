import SwiftUI
import WatchKit

// MARK: - The card, on your wrist
// The Watch mirrors the phone's live card — the same data the Lock Screen card draws — in the
// same design language: card black, your theme accent, the same tile (Start set · draining rest
// border · lifting timer · Log), the same seven views. Turn the crown to page through them.
// The tile reacts first to this Watch (a pause hold, a set it saw end, your first rep), then to
// the phone. In the phone's Demo Mode, this is the phone's demo, live.

extension Color {
    init(watchHex h: UInt32) {
        self.init(.sRGB, red: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255,
                  blue: Double(h & 0xff) / 255, opacity: 1)
    }
}

extension WatchState {
    var accentColor: Color { Color(watchHex: accentHex) }
    var inkColor: Color { accentInkWhite ? .white : .black }
}

/// The card's palette (the Watch is always dark).
private enum K {
    static let panel = Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255)
    static let mute = Color(white: 0.56)
    static let dim = Color.white.opacity(0.08)
    static let line = Color.white.opacity(0.10)
    static let red = Color(red: 1, green: 85 / 255, blue: 85 / 255)
    static let orange = Color(red: 242 / 255, green: 160 / 255, blue: 61 / 255)
    static let blue = Color(red: 61 / 255, green: 155 / 255, blue: 224 / 255)
}

private func clock(_ seconds: Int) -> String { String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
private func num(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }

/// The tile's outline, starting at top centre and running clockwise (the Lock Screen card's
/// rest border uses the same path: it drains from there; a pause hold fills from there).
struct TileOutline: Shape {
    var radius: CGFloat = 18
    func path(in r: CGRect) -> Path {
        let rad = min(radius, r.height / 2)
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

// MARK: - Host: the card, the seven views, the workout — one crown-paged stack

struct WatchCardHost: View {
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var session: WorkoutSessionManager

    var body: some View {
        Group {
            if let card = state.card {
                TabView {
                    WatchCardPage(card: card)
                    ForEach(CardData.allCases, id: \.self) { kind in
                        WatchDataPage(kind: kind, card: card)
                    }
                    WatchCardOverview()
                }
                .tabViewStyle(.verticalPage)
                .navigationTitle(card.setsTotal > 0 ? "\(card.setsDone)/\(card.setsTotal)" : "")
            } else {
                waiting
            }
        }
        .onAppear { state.cardVisible = true; state.requestCard() }
        .onDisappear { state.cardVisible = false }
    }

    private var waiting: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "iphone").font(.system(size: 24)).foregroundColor(K.mute)
                Text("Open the workout on your phone").font(.system(size: 15, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("The card appears here as soon as it's open.").font(.system(size: 11)).foregroundColor(K.mute)
                    .multilineTextAlignment(.center)
                if state.activeWorkout != nil {
                    NavigationLink { WatchWorkoutView() } label: {
                        Text("Log sets here instead").font(.system(size: 13, weight: .bold)).foregroundColor(state.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - The card page

private enum Tile: Equatable {
    case ready
    case lifting(Date)
    case log(reps: Int, detail: String)
    case resting(Date, Date)
    case hold(Date, Double, Bool)
    case done
}

struct WatchCardPage: View {
    let card: WatchCard
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var motion: MotionRecorder
    @EnvironmentObject var session: WorkoutSessionManager
    @State private var editing = false
    /// Always On (wrist down, session running): a quieter card, updated once a second.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        TimelineView(.periodic(from: .now, by: dimmed ? 1 : 0.5)) { ctx in
            let now = currentTile(at: ctx.date)
            VStack(spacing: 5) {
                if state.cardDemo {
                    Text("DEMO MODE").font(.system(size: 7.5, weight: .heavy)).tracking(1.4).foregroundColor(state.accentColor)
                }
                CardHeader(card: card, upNext: isResting(now), accent: state.accentColor)
                CardTileView(tile: now, now: ctx.date, accent: state.accentColor, ink: state.inkColor, dimmed: dimmed)
                    .onTapGesture { tap(now) }
                if !dimmed { below(now) }                   // buttons can't be tapped while dimmed
                if showsFooter(now) { CardFooter(card: card, hr: session.heartRate ?? card.hr) }
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $editing) { editor }
    }

    /// The Watch's own signals first (instant), then the phone's card.
    private func currentTile(at now: Date) -> Tile {
        if let start = motion.pauseStart, motion.pauseTarget > 0 {
            return .hold(start, motion.pauseTarget, motion.pauseReached)
        }
        if let d = state.presentedDetection {
            return .log(reps: d.reps.count, detail: String(format: "%d reps · %.2f m/s avg", d.reps.count, d.meanVelocity))
        }
        if card.stage == "lifting" && card.logNeeded {
            return .log(reps: card.dReps, detail: "\(card.dReps) reps — tap to confirm")
        }
        if motion.liveRepCount != nil { return .lifting(card.setStart ?? now) }
        switch card.stage {
        case "resting":
            if let a = card.restStart, let b = card.restEnd, b > now { return .resting(a, b) }
            return .ready
        case "lifting": return .lifting(card.setStart ?? now)
        case "done": return .done
        default: return .ready
        }
    }

    private func isResting(_ t: Tile) -> Bool { if case .resting = t { return true }; return false }
    private func showsFooter(_ t: Tile) -> Bool {
        switch t { case .lifting, .resting: return false; default: return true }
    }

    private func tap(_ t: Tile) {
        switch t {
        case .ready: state.cardStartSet()
        case .log: editing = true
        default: break
        }
    }

    @ViewBuilder
    private func below(_ t: Tile) -> some View {
        switch t {
        case .ready:
            if state.cardDemo {
                Text("mirroring your phone · tap Start set").font(.system(size: 9, weight: .bold)).foregroundColor(K.mute)
            } else if session.isRunning {
                Text("or just lift — the Watch starts it").font(.system(size: 9, weight: .bold)).foregroundColor(K.mute)
            } else {
                Button { Task { await session.start() } } label: {
                    Label("Track with Watch", systemImage: "waveform.path").font(.system(size: 11, weight: .heavy))
                        .foregroundColor(state.accentColor).frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(Capsule().fill(K.panel))
                }
                .buttonStyle(.plain).padding(.horizontal, 14)
            }
        case .lifting:
            VStack(spacing: 5) {
                LiveRepsRow(speeds: state.liveSpeeds.isEmpty ? state.cardLiveSpeeds : state.liveSpeeds,
                            accent: state.accentColor)
                pill("✓ Log set", filled: true) { editing = true }
            }
        case .log:
            if let d = state.presentedDetection {
                Button { state.discardDetection(d) } label: {
                    Text("Not a set").font(.system(size: 11, weight: .semibold)).foregroundColor(K.mute)
                }
                .buttonStyle(.plain)
            }
        case .resting:
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    pill("+30 s", filled: false) { state.cardAddRest() }
                    pill("Skip", filled: false) { state.cardSkipRest() }
                }
                if let note = state.cardNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundColor(state.accentColor)
                        Text(note).font(.system(size: 10.5, weight: .bold)).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(K.panel))
                    .padding(.horizontal, 4)
                }
            }
        case .hold:
            EmptyView()
        case .done:
            Text("Finish in the app, or end the session at the bottom.").font(.system(size: 10, weight: .semibold))
                .foregroundColor(K.mute).multilineTextAlignment(.center).padding(.horizontal, 10)
        }
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .heavy))
                .foregroundColor(filled ? state.inkColor : state.accentColor)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(Capsule().fill(filled ? state.accentColor : K.panel))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, filled ? 14 : 0)
    }

    /// Log: pre-filled from what the Watch counted, the phone's editor, or the plan.
    private var editor: some View {
        let d = state.presentedDetection
        let live = state.liveSpeeds.isEmpty ? state.cardLiveSpeeds : state.liveSpeeds
        let reps: Int = d?.reps.count ?? (card.logNeeded ? card.dReps : (live.isEmpty ? card.goalReps : live.count))
        let weight: Double = card.logNeeded && card.dWeight > 0 ? card.dWeight : card.goalWeight
        let rpe: Double = card.logNeeded ? card.dRPE : card.nextRPE
        let counted: String? = d.map { String(format: "Watch counted %d · %.2f m/s", $0.reps.count, $0.meanVelocity) }
        let n = state.setToLog()?.2 ?? card.setNumber
        return WatchCrownEditor(title: "\(card.exercise) · Set \(n)", counted: counted, unit: card.unit,
                                step: state.weightStep, accent: state.accentColor, ink: state.inkColor,
                                reps: Double(reps), weight: weight, rpe: rpe) { r, w, e in
            state.cardLog(reps: r, weight: w, rpe: e)
        }
    }
}

private struct CardHeader: View {
    let card: WatchCard
    let upNext: Bool
    let accent: Color
    var body: some View {
        VStack(spacing: 1) {
            Text(card.exercise).font(.system(size: 15, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            Text(card.stage == "done" ? "ALL SETS DONE" : "SET \(card.setNumber) OF \(card.setCount)" + (upNext ? " · UP NEXT" : ""))
                .font(.system(size: 8.5, weight: .heavy)).tracking(1.2).foregroundColor(K.mute).lineLimit(1)
            if card.stage != "done" {
                Text(card.goalWeight > 0 ? "\(card.goalReps) × \(num(card.goalWeight)) \(card.unit)" : "\(card.goalReps) reps")
                    .font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(accent).monospacedDigit()
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
    }
}

private struct CardTileView: View {
    let tile: Tile
    let now: Date
    let accent: Color
    let ink: Color
    var dimmed = false
    private let h: CGFloat = 74

    var body: some View {
        Group {
            switch tile {
            case .ready:
                filled(VStack(spacing: 2) {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .heavy))
                    Text("Start set").font(.system(size: 17, weight: .heavy))
                })
            case .lifting(let start):
                VStack(spacing: 0) {
                    Text("LIFTING").font(.system(size: 8.5, weight: .heavy)).tracking(1.2).foregroundColor(accent)
                    Text(clock(Int(now.timeIntervalSince(start)))).font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity).frame(height: h)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent, lineWidth: 1.5))
            case .log(_, let detail):
                filled(VStack(spacing: 1) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy))
                    Text("Log set").font(.system(size: 17, weight: .heavy))
                    Text(detail).font(.system(size: 9.5, weight: .bold)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.7)
                })
            case .resting(let a, let b):
                let total = max(1, b.timeIntervalSince(a))
                let left = max(0, b.timeIntervalSince(now))
                border(fraction: left / total, content: VStack(spacing: 0) {
                    Text(clock(Int(left.rounded(.up)))).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("REST").font(.system(size: 8.5, weight: .heavy)).tracking(1.6).foregroundColor(accent)
                })
            case .hold(let start, let target, let reached):
                let held = now.timeIntervalSince(start)
                if reached || held >= target {
                    filled(VStack(spacing: 0) {
                        Text("GO").font(.system(size: 32, weight: .black))
                        Text(String(format: "%.1f s held ✓", target)).font(.system(size: 10, weight: .heavy))
                    })
                } else {
                    border(fraction: held / target, content: VStack(spacing: 0) {
                        Text("HOLD").font(.system(size: 8.5, weight: .heavy)).tracking(1.6).foregroundColor(K.mute)
                        Text(String(format: "%.1f", held)).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text(String(format: "of %.1f s", target)).font(.system(size: 9.5, weight: .bold)).foregroundColor(K.mute)
                    })
                }
            case .done:
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 26)).foregroundColor(accent)
                    Text("All sets done").font(.system(size: 13, weight: .heavy))
                }
                .frame(maxWidth: .infinity).frame(height: h)
                .background(RoundedRectangle(cornerRadius: 18).fill(K.panel))
            }
        }
        .padding(.horizontal, 12)
    }

    /// A filled accent tile — outlined instead when dimmed (Always On avoids large bright areas).
    private func filled<C: View>(_ content: C) -> some View {
        content.foregroundColor(dimmed ? accent : ink)
            .frame(maxWidth: .infinity).frame(height: h)
            .background(RoundedRectangle(cornerRadius: 18).fill(dimmed ? Color.black : accent))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(dimmed ? accent.opacity(0.8) : .clear, lineWidth: 1.5))
    }

    private func border<C: View>(fraction: Double, content: C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.black)
            TileOutline().stroke(K.dim, lineWidth: 4).padding(2)
            TileOutline().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(dimmed ? accent.opacity(0.8) : accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).padding(2)
            content
        }
        .frame(maxWidth: .infinity).frame(height: h)
    }
}

/// Reps as they arrive: the count, a bar per rep, the last rep's speed.
private struct LiveRepsRow: View {
    let speeds: [Double]
    let accent: Color
    var body: some View {
        let top = max(0.3, speeds.max() ?? 0.3)
        HStack(spacing: 6) {
            Text("\(speeds.count)").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(accent)
            Text("REPS").font(.system(size: 8, weight: .heavy)).tracking(1.2).foregroundColor(K.mute)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(speeds.suffix(8).enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 8, height: max(3, 16 * v / top))
                }
            }
            .frame(height: 16, alignment: .bottom)
            Spacer(minLength: 0)
            if let last = speeds.last {
                Text(String(format: "%.2f", last)).font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("m/s").font(.system(size: 9, weight: .bold)).foregroundColor(K.mute)
            }
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: speeds.count)
    }
}

private struct CardFooter: View {
    let card: WatchCard
    let hr: Int?
    var body: some View {
        HStack(spacing: 4) {
            if let hr {
                Image(systemName: "heart.fill").font(.system(size: 9)).foregroundColor(K.red)
                Text("\(hr)").font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("·").foregroundColor(K.mute)
            }
            Image(systemName: "stopwatch").font(.system(size: 9)).foregroundColor(K.mute)
            Text(card.startedAt, style: .timer).font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundColor(K.mute)
            Text("total").font(.system(size: 10, weight: .bold)).foregroundColor(K.mute)
        }
        .lineLimit(1)
    }
}

// MARK: - Log a set: the crown turns the field marked with the crown

struct WatchCrownEditor: View {
    let title: String
    let counted: String?
    let unit: String
    let step: Double
    let accent: Color
    let ink: Color
    let onSave: (Int, Double, Double) -> Void
    @State private var reps: Double
    @State private var weight: Double
    @State private var rpe: Double
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    enum Field: Hashable { case reps, weight, rpe }

    init(title: String, counted: String?, unit: String, step: Double, accent: Color, ink: Color,
         reps: Double, weight: Double, rpe: Double, onSave: @escaping (Int, Double, Double) -> Void) {
        self.title = title; self.counted = counted; self.unit = unit; self.step = step
        self.accent = accent; self.ink = ink; self.onSave = onSave
        _reps = State(initialValue: reps)
        _weight = State(initialValue: weight)
        _rpe = State(initialValue: rpe)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 5) {
                VStack(spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                    if let counted { Text(counted).font(.system(size: 9, weight: .semibold)).foregroundColor(K.mute) }
                }
                field(.reps, "REPS", value: $reps, range: 0...50, by: 1, text: "\(Int(reps))")
                field(.weight, "WEIGHT · \(unit.uppercased())", value: $weight, range: 0...max(1000, weight + 200), by: step, text: num(weight))
                field(.rpe, "RPE", value: $rpe, range: 5...10, by: 0.5, text: num(rpe))
                Button {
                    onSave(Int(reps.rounded()), weight, rpe)
                    dismiss()
                } label: {
                    Text("✓ Save set").font(.system(size: 13, weight: .heavy)).foregroundColor(ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 30).padding(.leading, 8)
            }
        }
        .onAppear { focus = .reps }          // the Watch pre-fills reps: the likeliest fix
    }

    /// A field: − and + straddle its edges; the crown indicator sits beside it, on the crown's side.
    private func field(_ f: Field, _ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                       by: Double, text: String) -> some View {
        let on = focus == f
        return HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(on ? Color.black : K.panel)
                RoundedRectangle(cornerRadius: 12).stroke(on ? accent : .clear, lineWidth: 1.6)
                VStack(spacing: 0) {
                    Text(label).font(.system(size: 7.5, weight: .heavy)).tracking(1.1).foregroundColor(K.mute)
                    Text(text).font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundColor(on ? accent : .white)
                }
                HStack {
                    stepButton("minus") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - by); focus = f }
                        .offset(x: -9)
                    Spacer()
                    stepButton("plus") { value.wrappedValue = min(range.upperBound, value.wrappedValue + by); focus = f }
                        .offset(x: 9)
                }
            }
            .frame(height: 40)
            .contentShape(Rectangle())
            .focusable(true)
            .focused($focus, equals: f)
            .focusEffectDisabled()                 // our own marker instead of the system ring
            .digitalCrownRotation(value, from: range.lowerBound, through: range.upperBound, by: by,
                                  sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onTapGesture { focus = f }
            Group {
                if on { CrownGlyph(color: accent) }
                else { Circle().fill(K.mute.opacity(0.75)).frame(width: 6, height: 6) }
            }
            .frame(width: 22)
            .padding(.leading, 11)
        }
        .padding(.leading, 10)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .heavy))
                .frame(width: 24, height: 24).background(Circle().fill(Color(white: 0.17)))
        }
        .buttonStyle(.plain)
    }
}

/// The Digital Crown, side-on (ridged), with a turn arrow — marks the field the crown is turning.
struct CrownGlyph: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 18, size.height / 20)
            ctx.fill(Path(roundedRect: CGRect(x: 8 * s, y: 3 * s, width: 8 * s, height: 14 * s), cornerRadius: 2.2 * s), with: .color(color))
            for y in [6.5, 10.0, 13.5] {
                var l = Path(); l.move(to: CGPoint(x: 8 * s, y: y * s)); l.addLine(to: CGPoint(x: 16 * s, y: y * s))
                ctx.stroke(l, with: .color(.black.opacity(0.5)), lineWidth: 1.3 * s)
            }
            ctx.fill(Path(roundedRect: CGRect(x: 4.5 * s, y: 7.5 * s, width: 3.5 * s, height: 5 * s), cornerRadius: s), with: .color(color))
            var arc = Path()
            arc.addArc(center: CGPoint(x: 9.5 * s, y: 10 * s), radius: 7 * s, startAngle: .degrees(-130), endAngle: .degrees(130), clockwise: true)
            ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            var head = Path()
            head.move(to: CGPoint(x: 2.6 * s, y: 13.4 * s)); head.addLine(to: CGPoint(x: 4.9 * s, y: 15.7 * s)); head.addLine(to: CGPoint(x: 7.2 * s, y: 14 * s))
            ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 20)
    }
}

// MARK: - The seven views (the Lock Screen card's, in its order and icons)

enum CardData: String, CaseIterable, Hashable {
    case heartRate, speed, travel, tempo, pause, sets, session
    var title: String {
        switch self {
        case .heartRate: return "HEART RATE"
        case .speed: return "BAR SPEED"
        case .travel: return "BAR TRAVEL"
        case .tempo: return "TEMPO"
        case .pause: return "PAUSE"
        case .sets: return "SETS"
        case .session: return "SESSION"
        }
    }
    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .travel: return "arrow.up.and.down"
        case .tempo: return "metronome"
        case .pause: return "pause"
        case .sets: return "list.bullet"
        case .session: return "flag.checkered"
        }
    }
}

struct WatchDataPage: View {
    let kind: CardData
    let card: WatchCard
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var session: WorkoutSessionManager
    @EnvironmentObject var motion: MotionRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            iconRow
            Text(subtitle).font(.system(size: 8, weight: .heavy)).tracking(1.2).foregroundColor(K.mute).lineLimit(1)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private var accent: Color { state.accentColor }

    private var iconRow: some View {
        HStack(spacing: 2) {
            ForEach(CardData.allCases, id: \.self) { k in
                Image(systemName: k.icon).font(.system(size: 9, weight: .bold))
                    .foregroundColor(k == kind ? state.inkColor : K.mute)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(k == kind ? accent : .clear))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if kind.isSensorView, let last = card.lastSet { return "\(kind.title) · \(last.uppercased())" }
        if kind == .sets { return "SETS · \(card.exercise.uppercased())" }
        return kind.title
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .heartRate: hrView
        case .speed: speedView
        case .travel: barsView(card.travel, unit: card.travelUnit, stat: card.travelConsistency.map { "Consistency \($0)%" })
        case .tempo: tempoView
        case .pause: pauseView
        case .sets: setsView
        case .session: sessionView
        }
    }

    private var empty: some View {
        Text("After your first set").font(.system(size: 12, weight: .semibold)).foregroundColor(K.mute)
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var hrView: some View {
        let hr = session.heartRate ?? card.hr
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(hr.map { "\($0)" } ?? "--").font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("bpm").font(.system(size: 10, weight: .bold)).foregroundColor(K.mute)
                Spacer()
                if let z = card.hrZone { Text("ZONE \(z)").font(.system(size: 8, weight: .heavy)).tracking(1.2).foregroundColor(z >= 4 ? K.red : K.orange) }
            }
            HRSpark(points: card.hrSpark, maxHR: card.hrMax)
                .frame(height: 56)
            HStack {
                if let p = card.hrPct { Text("\(p)% of max").font(.system(size: 9.5, weight: .bold)).foregroundColor(K.mute) }
                Spacer()
                if let pk = card.hrPeak { Text("Peak \(pk)").font(.system(size: 9.5, weight: .bold)).foregroundColor(K.mute) }
            }
        }
    }

    private var liftingNow: Bool { motion.liveRepCount != nil || card.stage == "lifting" }

    private var speedView: some View {
        let live = state.liveSpeeds.isEmpty ? state.cardLiveSpeeds : state.liveSpeeds
        let speeds = liftingNow && !live.isEmpty ? live : card.speeds
        let peak = card.peakSpeed ?? speeds.max()
        return VStack(alignment: .leading, spacing: 5) {
            if speeds.isEmpty { empty } else {
                RepBars(values: speeds, accent: accent, target: nil).frame(height: 70)
                HStack {
                    stat("PEAK", peak.map { String(format: "%.2f m/s", $0) } ?? "–")
                    Spacer()
                    stat("LOSS", card.speedLoss.map { "\($0)%" } ?? "–", color: (card.speedLoss ?? 0) >= 20 ? K.orange : .white)
                    Spacer()
                    stat("EFFORT", card.effort ?? "–")
                }
            }
        }
    }

    private func barsView(_ values: [Double], unit: String, stat statText: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if values.isEmpty { empty } else {
                RepBars(values: values, accent: accent, target: nil).frame(height: 70)
                HStack {
                    stat("AVG", String(format: "%.1f %@", values.reduce(0, +) / Double(values.count), unit))
                    Spacer()
                    if let statText { Text(statText).font(.system(size: 10, weight: .bold)).foregroundColor(K.mute) }
                }
            }
        }
    }

    private var tempoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = card.tempo {
                Text(t).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("lower · pause · lift · top").font(.system(size: 9.5, weight: .bold)).foregroundColor(K.mute)
                HStack {
                    if !card.ecc.isEmpty { stat("LOWER", String(format: "%.1f s", card.ecc.reduce(0, +) / Double(card.ecc.count))) }
                    Spacer()
                    if !card.con.isEmpty { stat("LIFT", String(format: "%.1f s", card.con.reduce(0, +) / Double(card.con.count))) }
                }
            } else { empty }
        }
    }

    private var pauseView: some View {
        VStack(alignment: .leading, spacing: 5) {
            if card.pause.isEmpty { empty } else {
                RepBars(values: card.pause, accent: accent, target: card.pauseTarget).frame(height: 70)
                HStack {
                    stat("AVG", card.pauseAvg.map { String(format: "%.1f s", $0) } ?? "–")
                    Spacer()
                    if let t = card.pauseTarget { stat("TARGET", String(format: "%.1f s", t)) }
                }
            }
        }
    }

    private var setsView: some View {
        VStack(spacing: 4) {
            ForEach(card.rows, id: \.self) { r in
                HStack(spacing: 7) {
                    Circle().fill(r.reps != nil ? accent : .clear)
                        .overlay(Circle().stroke(r.reps != nil ? accent : (r.current ? accent : K.dim), lineWidth: 2))
                        .overlay(r.reps != nil ? Image(systemName: "checkmark").font(.system(size: 7, weight: .black)).foregroundColor(state.inkColor) : nil)
                        .frame(width: 15, height: 15)
                    Text("Set \(r.n)").font(.system(size: 12, weight: .bold)).foregroundColor(r.reps != nil ? K.mute : .white)
                    Spacer()
                    if let reps = r.reps {
                        Text("\(reps)×\(num(r.weight ?? r.tWeight))" + (r.rpe.map { " @\(num($0))" } ?? ""))
                            .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(accent)
                    } else {
                        Text("\(r.tReps)×\(num(r.tWeight))").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(K.mute)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(K.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(r.current && r.reps == nil ? accent : .clear, lineWidth: 1.4))
            }
        }
    }

    private var sessionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stat("EXERCISES", "\(card.exDone)/\(card.exTotal)")
                Spacer()
                stat("SETS", "\(card.setsDone)/\(card.setsTotal)")
            }
            stat("VOLUME", "\(card.volume.formatted()) \(card.unit)")
            if let next = card.upNext {
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT").font(.system(size: 7.5, weight: .heavy)).tracking(1.2).foregroundColor(accent)
                    Text(next).font(.system(size: 12, weight: .bold)).lineLimit(2)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 7, weight: .heavy)).tracking(1).foregroundColor(K.mute)
            Text(value).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(color).monospacedDigit()
        }
    }
}

private extension CardData {
    var isSensorView: Bool { self == .speed || self == .travel || self == .tempo || self == .pause }
}

/// A bar per rep (the last rep softer), with an optional target line.
private struct RepBars: View {
    let values: [Double]
    let accent: Color
    let target: Double?
    var body: some View {
        GeometryReader { g in
            let top = max(values.max() ?? 1, target ?? 0) * 1.1
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(values.suffix(8).enumerated()), id: \.offset) { i, v in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4).fill(accent)
                                .opacity(i == min(values.count, 8) - 1 ? 0.55 : 1)
                                .frame(height: max(3, (g.size.height - 12) * v / top))
                            Text("\(i + 1)").font(.system(size: 8, weight: .bold)).foregroundColor(K.mute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if let target {
                    Rectangle().fill(Color.white.opacity(0.6))
                        .frame(height: 1)
                        .offset(y: -(12 + (g.size.height - 12) * target / top))
                }
            }
        }
    }
}

/// Heart rate over the last few minutes, with zone lines.
private struct HRSpark: View {
    let points: [Int]
    let maxHR: Int?
    var body: some View {
        GeometryReader { g in
            let lo = Double((points.min() ?? 90) - 10)
            let hi = Double(max((points.max() ?? 160) + 10, Int(Double(maxHR ?? 190) * 0.82)))
            let y = { (v: Double) in g.size.height * (1 - (v - lo) / max(1, hi - lo)) }
            ZStack {
                if let m = maxHR {
                    ForEach([(0.7, K.blue), (0.8, K.orange)], id: \.0) { z in
                        Path { p in
                            let yy = y(Double(m) * z.0)
                            p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: g.size.width, y: yy))
                        }
                        .stroke(z.1.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                if points.count > 1 {
                    Path { p in
                        for (i, v) in points.enumerated() {
                            let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(points.count - 1), y: y(Double(v)))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(K.red, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - The workout (last page): every exercise, the one you're on, End & Save

struct WatchCardOverview: View {
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var session: WorkoutSessionManager
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if let w = state.activeWorkout {
                    let total = w.exercises.reduce(0) { $0 + $1.sets.count }
                    let done = w.exercises.reduce(0) { $0 + $1.sets.filter { $0.loggedReps != nil }.count }
                    Text(w.title).font(.system(size: 15, weight: .heavy)).lineLimit(2)
                    HStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(K.dim)
                                Capsule().fill(state.accentColor).frame(width: max(4, g.size.width * CGFloat(done) / CGFloat(max(1, total))))
                            }
                        }
                        .frame(height: 5)
                        Text("\(done)/\(total)").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(state.accentColor)
                    }
                    let nowId = w.exercises.first { $0.sets.contains { $0.loggedReps == nil } }?.id
                    ForEach(w.exercises) { ex in
                        NavigationLink { WatchExerciseView(exerciseId: ex.id) } label: { row(ex, now: ex.id == nowId) }
                            .buttonStyle(.plain)
                    }
                    if session.isRunning {
                        Button(role: .destructive) { confirmEnd = true } label: {
                            Label("End & Save", systemImage: "stop.fill").font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .confirmationDialog("End this session?", isPresented: $confirmEnd) {
            Button("End & Save", role: .destructive) { Task { await session.end() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("It's saved to Apple Health as a strength workout.")
        }
    }

    private func row(_ ex: WatchExercise, now: Bool) -> some View {
        let done = ex.sets.filter { $0.loggedReps != nil }.count
        let frac = ex.sets.isEmpty ? 0 : CGFloat(done) / CGFloat(ex.sets.count)
        let goal = ex.sets.first.map { "\($0.targetReps)×\(num($0.targetWeight))" } ?? ""
        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(K.dim, lineWidth: 2.6)
                if done > 0 {
                    Circle().trim(from: 0, to: frac).stroke(state.accentColor, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(ex.name).font(.system(size: 13, weight: .heavy)).lineLimit(1)
                Text("\(done)/\(ex.sets.count) · \(goal)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(K.mute)
            }
            Spacer(minLength: 0)
            if now { Text("NOW").font(.system(size: 7.5, weight: .heavy)).tracking(1.2).foregroundColor(state.accentColor) }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(K.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(now ? state.accentColor : .clear, lineWidth: 1.4))
    }
}
