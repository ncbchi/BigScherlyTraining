import SwiftUI
import UIKit
import Combine

// MARK: - Plate calculator (Oct 9, 2026 · chat "3.4 - UI & UX")
// Tools ▸ Plate calculator, and the little barbell on the active set card (barbell lifts and
// plate-loaded machines). One card, both ways round: tap plates to build a total, or type a
// total to see the plates. "My Gym" says which bar and plates you have.
//
// HARD RULE: the heaviest plate goes on first, nearest the middle of the bar. Every load here is
// kept heaviest → lightest from the inside out, and every drawing draws it that way.
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).
// Mockups: canvas rows "Plate calculator" (PC1–PC7).

// MARK: - Plates (competition colours)

nonisolated struct PlateKind: Hashable {
    let weight: Double                  // in your units (lb or kg)
    let base: UInt, light: UInt, dark: UInt
    let darkInk: Bool                   // the number printed on it in ink (yellow, white, chrome)
    let size: CGFloat                   // diameter as a share of a full-size plate
    let thick: CGFloat                  // thickness, drawing units

    var baseColor: Color { Color(hex: base) }
    var lightColor: Color { Color(hex: light) }
    var darkColor: Color { Color(hex: dark) }
    var ink: Color { darkInk ? Color(hex: 0x2A2A2A) : .white }
    /// White and chrome need a darker edge to show on a light card.
    var edgeColor: Color { (base == 0xECECE8 || base == 0xC8CDD4) ? Color(hex: 0x8E8E93) : Color(hex: dark) }
    var label: String { PlateMath.text(weight) }

    /// Heaviest first. lb: 55 red · 45 blue · 35 yellow · 25 green · 10 white · 5 black · 2.5 chrome.
    /// kg: 25 · 20 · 15 · 10 · 5 · 2.5 · 1.25 in the same colours.
    static func all(kg: Bool) -> [PlateKind] {
        let w: [Double] = kg ? [25, 20, 15, 10, 5, 2.5, 1.25] : [55, 45, 35, 25, 10, 5, 2.5]
        let c: [(UInt, UInt, UInt, Bool)] = [
            (0xD62839, 0xF0606B, 0x8A1220, false), (0x1D5BD6, 0x5A8EF2, 0x0E327C, false),
            (0xF2C12E, 0xFFDF73, 0x9C760B, true),  (0x1C9A57, 0x48C985, 0x0B5A31, false),
            (0xECECE8, 0xFFFFFF, 0xA3A39C, true),  (0x2A2A2E, 0x4A4A50, 0x0C0C0E, false),
            (0xC8CDD4, 0xF4F6F9, 0x7A818B, true)
        ]
        let size: [CGFloat] = [1, 1, 0.9, 0.74, 0.52, 0.42, 0.36]
        let thick: [CGFloat] = [30, 26, 22, 18, 13, 10, 8]
        return (0..<7).map { i in
            PlateKind(weight: w[i], base: c[i].0, light: c[i].1, dark: c[i].2, darkInk: c[i].3, size: size[i], thick: thick[i])
        }
    }
}

// MARK: - My Gym (saved on this phone)

nonisolated struct GymBar: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var lb: Double
    var kg: Double
}

nonisolated struct GymMachine: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var startLb: Double            // the sled / carriage, before any plates
    var sides: Int                 // 2 = loads both sides; 1 = one sleeve (landmine, T-bar)
    var keywords: [String]         // exercise names containing any of these use this machine
}

nonisolated struct GymSettings: Codable {
    var barId = "barbell"
    var bars: [GymBar] = GymSettings.defaultBars
    var pairsLb: [String: Int] = ["55": 0, "45": 8, "35": 2, "25": 4, "10": 4, "5": 4, "2.5": 2]
    var pairsKg: [String: Int] = ["25": 4, "20": 4, "15": 2, "10": 2, "5": 2, "2.5": 2, "1.25": 2]
    var countCollars = false
    var collarPairLb: Double = 5
    var collarPairKg: Double = 5
    var machines: [GymMachine] = GymSettings.defaultMachines

    static let defaultBars: [GymBar] = [
        GymBar(id: "barbell", name: "Barbell", lb: 45, kg: 20),
        GymBar(id: "womens", name: "Women's bar", lb: 35, kg: 15),
        GymBar(id: "trap", name: "Trap bar", lb: 55, kg: 25),
        GymBar(id: "ssb", name: "Safety squat bar", lb: 65, kg: 30),
        GymBar(id: "ez", name: "EZ curl bar", lb: 25, kg: 10)
    ]
    /// Sled weights start at 0: every gym's machines differ, so you set yours in My Gym.
    static let defaultMachines: [GymMachine] = [
        GymMachine(id: "legpress", name: "Leg press", startLb: 0, sides: 2, keywords: ["leg press"]),
        GymMachine(id: "hack", name: "Hack squat", startLb: 0, sides: 2, keywords: ["hack squat"]),
        GymMachine(id: "pendulum", name: "Pendulum squat", startLb: 0, sides: 2, keywords: ["pendulum"]),
        GymMachine(id: "belt", name: "Belt squat", startLb: 0, sides: 2, keywords: ["belt squat"]),
        GymMachine(id: "smith", name: "Smith machine", startLb: 0, sides: 2, keywords: ["smith"]),
        GymMachine(id: "tbar", name: "T-bar row", startLb: 0, sides: 1, keywords: ["t-bar", "t bar"]),
        GymMachine(id: "landmine", name: "Landmine", startLb: 0, sides: 1, keywords: ["landmine"])
    ]
}

/// What the maths works from: the bar or sled, collars, and the plates you have.
nonisolated struct PlateSetup {
    var start: Double              // bar or sled, your units
    var sides: Int
    var collars: Double            // both collars together, your units (0 = not counted)
    var kinds: [PlateKind]         // heaviest first
    var counts: [Int]              // how many of each can go on ONE side
    var startName: String          // "Barbell" · "Leg press sled"
}

@MainActor
final class GymEquipment: ObservableObject {
    static let shared = GymEquipment()
    @Published var settings: GymSettings { didSet { save() } }
    private static let key = "bst_gym_v1"

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(GymSettings.self, from: d) {
            settings = s
        } else {
            settings = GymSettings()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var isKg: Bool { StatsUnits.isKg }
    var unit: String { isKg ? "kg" : "lb" }
    var kinds: [PlateKind] { PlateKind.all(kg: isKg) }

    func pairs(of w: Double) -> Int { (isKg ? settings.pairsKg : settings.pairsLb)[PlateMath.key(w)] ?? 0 }
    func setPairs(_ n: Int, of w: Double) {
        let k = PlateMath.key(w), v = max(0, min(20, n))
        if isKg { settings.pairsKg[k] = v } else { settings.pairsLb[k] = v }
    }

    func bar(_ id: String?) -> GymBar {
        settings.bars.first { $0.id == (id ?? settings.barId) } ?? GymSettings.defaultBars[0]
    }
    func weight(of bar: GymBar) -> Double { isKg ? bar.kg : bar.lb }
    func shown(lb: Double) -> Double { isKg ? lb * 0.45359237 : lb }
    func lb(shown: Double) -> Double { isKg ? shown / 0.45359237 : shown }

    /// The bar (or sled) for this lift, with your plates.
    func setup(for lift: PlateLift?, barId: String? = nil) -> PlateSetup {
        let ks = kinds
        var start: Double, sides = 2, name: String
        switch lift {
        case .machine(let m)?:
            let mm = settings.machines.first { $0.id == m.id } ?? m
            start = shown(lb: mm.startLb); sides = mm.sides; name = "\(mm.name) sled"
            if mm.sides == 1 { name = mm.name }
        case .barbell(let liftBar)?:
            let b = bar(barId ?? liftBar)
            start = weight(of: b); name = b.name
        case nil:
            let b = bar(barId)
            start = weight(of: b); name = b.name
        }
        // One sleeve can take every plate you own; two sides take a pair each.
        let counts = ks.map { sides == 1 ? pairs(of: $0.weight) * 2 : pairs(of: $0.weight) }
        let collars = (settings.countCollars && sides == 2) ? (isKg ? settings.collarPairKg : settings.collarPairLb) : 0
        return PlateSetup(start: start, sides: sides, collars: collars, kinds: ks, counts: counts, startName: name)
    }

    /// What the set-card barbell shows: the exact load, else the nearest below, else the empty bar.
    func iconPlates(lift: PlateLift, total: Double?) -> [PlateKind] {
        guard let total else { return [] }
        let s = setup(for: lift)
        let w = PlateMath.solve(total, s) ?? PlateMath.nearest(total, s).below.flatMap { PlateMath.solve($0, s) } ?? []
        return w.compactMap { x in s.kinds.first { $0.weight == x } }
    }
}

// MARK: - Which lifts get the barbell

nonisolated enum PlateLift: Hashable {
    case barbell(barId: String?)   // nil = your usual bar
    case machine(GymMachine)

    var machine: GymMachine? { if case .machine(let m) = self { return m } else { return nil } }

    /// Barbell lifts and plate-loaded machines; nothing for dumbbells, cables or pin stacks.
    @MainActor static func of(_ exerciseName: String) -> PlateLift? {
        let n = " " + exerciseName.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        // Your machines first (Leg press, Hack squat… and any you've added).
        for m in GymEquipment.shared.settings.machines {
            let words = m.keywords + [m.name.lowercased()]
            if words.contains(where: { !$0.isEmpty && n.contains($0.replacingOccurrences(of: "-", with: " ")) }) { return .machine(m) }
        }
        let never = ["dumbbell", " db ", "kettlebell", " kb ", "cable", " band", "goblet", "machine", "bodyweight",
                     "body weight", "assisted", "pistol", "jump squat", "air squat", "sissy", "wall sit", "pull up",
                     "chin up", "push up", " dip"]
        if never.contains(where: { n.contains($0) }) { return nil }
        if n.contains("split squat") && !n.contains("barbell") { return nil }
        if n.contains("trap bar") || n.contains("hex bar") { return .barbell(barId: "trap") }
        if n.contains("safety squat") || n.contains(" ssb ") { return .barbell(barId: "ssb") }
        if n.contains(" ez ") || n.contains("ez bar") || n.contains("ez curl") { return .barbell(barId: "ez") }
        let barbell = ["barbell", " bb ", "squat", "bench press", "deadlift", "overhead press", " ohp ", "military press",
                       "push press", "pendlay", "bent over row", "romanian", " rdl ", "good morning", "hip thrust",
                       "power clean", "hang clean", " clean ", "snatch", " jerk", "rack pull", "floor press", "zercher",
                       "thruster", "sumo"]
        return barbell.contains(where: { n.contains($0) }) ? .barbell(barId: nil) : nil
    }
}

// MARK: - The maths

nonisolated enum PlateMath {
    static func key(_ w: Double) -> String { String(format: "%g", w) }
    static func text(_ w: Double) -> String {
        let v = (w * 100).rounded() / 100
        return v == v.rounded() ? String(Int(v)) : key(v)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }

    static func total(_ perSide: [Double], _ s: PlateSetup) -> Double {
        s.start + s.collars + Double(s.sides) * perSide.reduce(0, +)
    }

    /// Exactly `total` with the plates you have, heaviest first (innermost first). Nil if it can't be made.
    static func solve(_ total: Double, _ s: PlateSetup) -> [Double]? {
        let per = (total - s.start - s.collars) / Double(s.sides)
        if per < -0.001 { return nil }
        let target = Int((per * 100).rounded())
        if abs(Double(target) / 100 - per) > 0.001 { return nil }
        if target == 0 { return [] }
        // Work in the smallest common step (2.5 lb / 1.25 kg), remembering dead ends, so even a
        // weight that can't be made answers instantly.
        let ws = s.kinds.map { Int(($0.weight * 100).rounded()) }
        let g = ws.reduce(0) { gcd($0, $1) }
        guard g > 0, target % g == 0 else { return nil }
        let u = ws.map { $0 / g }
        var out: [Int] = []
        var dead = Set<Int>()
        func fill(_ i: Int, _ rem: Int) -> Bool {
            if rem == 0 { return true }
            if i >= u.count || dead.contains(i * 1_000_000 + rem) { return false }
            var n = min(s.counts[i], rem / u[i])
            while n >= 0 {
                out.append(contentsOf: Array(repeating: ws[i], count: n))
                if fill(i + 1, rem - n * u[i]) { return true }
                out.removeLast(n)
                n -= 1
            }
            dead.insert(i * 1_000_000 + rem)
            return false
        }
        guard fill(0, target / g) else { return nil }
        return out.map { Double($0) / 100 }.sorted(by: >)
    }

    /// The nearest loadable weights either side of one that can't be made.
    static func nearest(_ total: Double, _ s: PlateSetup) -> (below: Double?, above: Double?) {
        let have = zip(s.kinds, s.counts).filter { $0.1 > 0 }.map { $0.0.weight }
        let base = s.start + s.collars
        guard let small = have.min() else { return (total > base ? base : nil, nil) }
        let step = small * Double(s.sides)
        let most = zip(s.kinds, s.counts).reduce(0) { $0 + $1.0.weight * Double($1.1) } * Double(s.sides) + base
        var below: Double? = nil, above: Double? = nil
        var t = base + ((total - base) / step).rounded(.down) * step
        while t >= base - 0.001 {
            if t < total - 0.001, solve(t, s) != nil { below = t; break }
            t -= step
        }
        t = max(base, base + ((total - base) / step).rounded(.up) * step)
        while t <= most + 0.001 {
            if t > total + 0.001, solve(t, s) != nil { above = t; break }
            t += step
        }
        return (below, above)
    }
}

// MARK: - Opening it (from the menu or a set)

struct PlateCalcRequest: Identifiable {
    let id = UUID()
    var exerciseName: String? = nil
    var setLabel: String? = nil            // "Set 1 of 4"
    var useFor: String? = nil              // "Set 1" — the button says "Use 285 lb for Set 1"
    var startTotal: Double? = nil          // your units
    var lift: PlateLift? = nil
    var onUse: ((Double) -> Void)? = nil   // hands back the total, in your units
}

@MainActor
final class PlateCalc: ObservableObject {
    static let shared = PlateCalc()
    @Published var request: PlateCalcRequest?
    func open(_ r: PlateCalcRequest? = nil) { request = r ?? PlateCalcRequest() }
}

extension View {
    /// Put once near the root: shows the calculator whenever something opens it.
    func plateCalculatorHost() -> some View { modifier(PlateCalcHost()) }
}

private struct PlateCalcHost: ViewModifier {
    @ObservedObject private var calc = PlateCalc.shared
    func body(content: Content) -> some View {
        content.sheet(item: $calc.request) { r in
            PlateCalculatorView(request: r)
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - The calculator card

struct PlateCalculatorView: View {
    let request: PlateCalcRequest
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gym = GymEquipment.shared

    @State private var barId: String? = nil       // nil = My Gym's bar (or the lift's own)
    @State private var plates: [Double] = []      // one side, heaviest first
    @State private var typed = ""
    @State private var below: Double? = nil       // set when the typed weight can't be made
    @State private var above: Double? = nil
    @State private var cantMake: String? = nil
    @State private var showGym = false
    @State private var appeared = false
    @State private var contentHeight: CGFloat = 0     // the card is only as tall as what's in it
    @FocusState private var totalFocused: Bool

    private var setup: PlateSetup {
        if case .barbell(let liftBar)? = request.lift { return gym.setup(for: .barbell(barId: barId ?? liftBar)) }
        if request.lift == nil { return gym.setup(for: nil, barId: barId) }
        return gym.setup(for: request.lift)
    }
    private var total: Double { PlateMath.total(plates, setup) }
    private var isMachine: Bool { request.lift?.machine != nil }
    private var light: Bool { Palette.current.scheme == .light }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let name = request.exerciseName { contextChip(name) }
                    totalRow
                    if cantMake != nil { warning }
                    stage
                    perSide
                    tray
                    actions
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showGym) { MyGymView() }
        }
        // Only as tall as the card; My Gym (a longer page) opens to full height.
        .presentationDetents([showGym ? .large : .height(SheetFit.clamp(contentHeight > 0 ? contentHeight + SheetFit.homeStrip : 640))])
        .onAppear(perform: start)
        .onChange(of: typed) { _, t in if totalFocused { aim(at: t) } }
        .onChange(of: totalFocused) { _, f in if !f, cantMake == nil { typed = PlateMath.text(total) } }
        .onChange(of: barId) { _, _ in aim(at: typed) }
        .onChange(of: gym.settings.pairsLb) { _, _ in aim(at: typed) }
        .onChange(of: gym.settings.pairsKg) { _, _ in aim(at: typed) }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("Plate Calculator").font(BrandFont.display(30)).foregroundColor(Brand.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Brand.card))
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
            }
            .accessibilityLabel("Close")
        }
    }

    private func contextChip(_ name: String) -> some View {
        HStack(spacing: 7) {
            PlateMenuGlyph(bar: Brand.voltText).frame(width: 16, height: 14)
            Text([name, request.setLabel].compactMap { $0 }.joined(separator: " · "))
                .font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
        }
        .padding(.horizontal, 11).frame(height: 28)
        .background(Capsule().fill(Brand.volt.opacity(0.14)))
        .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1))
    }

    private var totalRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL").font(BrandFont.body(11, .heavy)).tracking(1.8).foregroundColor(Brand.mute)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0", text: $typed)
                        .keyboardType(.decimalPad)
                        .focused($totalFocused)
                        .font(BrandFont.display(64)).foregroundColor(Brand.text)
                        .fixedSize()
                        .accessibilityLabel("Total weight")
                    Text(gym.unit).font(BrandFont.display(24)).foregroundColor(Brand.mute)
                }
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(totalFocused ? Brand.voltLine : Brand.line).frame(height: 2)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 6) {
                barChip
                Text(sideText).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            }
            .padding(.bottom, 6)
        }
    }

    private var sideText: String {
        let per = plates.reduce(0, +)
        if setup.sides == 1 { return "\(PlateMath.text(per)) \(gym.unit) on the sleeve" }
        return "\(PlateMath.text(per)) \(gym.unit) a side"
    }

    @ViewBuilder private var barChip: some View {
        let s = setup
        let label = HStack(spacing: 6) {
            Text("\(s.startName) · \(PlateMath.text(s.start)) \(gym.unit)")
                .font(BrandFont.body(12.5, .bold)).foregroundColor(Brand.text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.mute)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(Brand.card))
        .overlay(Capsule().stroke(Brand.line, lineWidth: 1))

        if isMachine {
            Button { showGym = true } label: { label }.buttonStyle(.plain)
        } else {
            Menu {
                ForEach(gym.settings.bars) { b in
                    Button { barId = b.id } label: {
                        Text("\(b.name) · \(PlateMath.text(gym.weight(of: b))) \(gym.unit)")
                    }
                }
                Divider()
                Button { showGym = true } label: { Label("My Gym…", systemImage: "slider.horizontal.3") }
            } label: { label }
        }
    }

    private var warning: some View {
        HStack(spacing: 10) {
            Text(cantMake ?? "").font(BrandFont.body(12.5, .semibold))
                .foregroundColor(light ? Color(hex: 0x8A4B00) : Color(hex: 0xFFB35C))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ForEach([below, above].compactMap { $0 }, id: \.self) { w in
                let shown = plates.isEmpty ? false : abs(total - w) < 0.001
                Button { pick(w) } label: {
                    Text(PlateMath.text(w)).font(BrandFont.display(18))
                        .foregroundColor(shown ? Brand.onVolt : Brand.text)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Capsule().fill(shown ? Brand.volt : Brand.card))
                        .overlay(Capsule().stroke(shown ? Color.clear : Brand.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(light ? Color(hex: 0xFFF4E5) : Color(hex: 0x2A1F0E)))
    }

    private var stage: some View {
        let kinds = plates.compactMap { w in setup.kinds.first { $0.weight == w } }
        let stageBg = light ? Color(hex: 0xEEEFF2) : Color(hex: 0x0B0B0C)
        return PlateSleeve3D(plates: kinds, collar: !plates.isEmpty, stage: stageBg)
            .frame(height: 250)
            .frame(maxWidth: .infinity)
            .background(
                RadialGradient(colors: light ? [.white, Color(hex: 0xEEEFF2)] : [Color(hex: 0x1C1C20), Color(hex: 0x0B0B0C)],
                               center: UnitPoint(x: 0.6, y: 0.4), startRadius: 10, endRadius: 320)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: plates)
            .accessibilityElement()
            .accessibilityLabel(plates.isEmpty ? "Empty bar" :
                "Each side, inside out: " + plates.map { PlateMath.text($0) }.joined(separator: ", "))
    }

    private var perSide: some View {
        let counts = Dictionary(grouping: plates, by: { $0 }).mapValues(\.count)
        let order = setup.kinds.filter { counts[$0.weight] != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(setup.sides == 1 ? "ON THE SLEEVE" : "PER SIDE").font(BrandFont.body(11, .heavy)).tracking(1.8).headerPill()
                if order.isEmpty {
                    Text("Empty \(isMachine ? "sled" : "bar")").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
                }
                ForEach(order, id: \.weight) { k in
                    HStack(spacing: 7) {
                        Circle().fill(k.baseColor).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(k.edgeColor.opacity(0.6), lineWidth: 1))
                        Text(k.label).font(BrandFont.display(17)).foregroundColor(Brand.text)
                        Text("× \(counts[k.weight] ?? 0)").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                    }
                    .padding(.leading, 8).padding(.trailing, 12).frame(height: 32)
                    .background(Capsule().fill(Brand.card))
                    .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                }
            }
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(setup.sides == 1 ? "TAP TO ADD A PLATE" : "TAP TO ADD A PAIR · HOLD TO TAKE ONE OFF")
                .font(BrandFont.body(11, .heavy)).tracking(1.8).foregroundColor(Brand.mute)
            HStack(spacing: 0) {
                ForEach(Array(setup.kinds.enumerated()), id: \.offset) { i, k in
                    let on = plates.filter { $0 == k.weight }.count
                    let left = setup.counts[i] - on
                    PlateToken(kind: k, count: on, enabled: left > 0)
                        .onTapGesture { add(k, left: left) }
                        .onLongPressGesture(minimumDuration: 0.35) { remove(k) }
                        .accessibilityElement()
                        .accessibilityLabel("\(k.label) \(gym.unit) plate, \(on) on each side")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { add(k, left: left) }
                        .accessibilityAction(named: "Take one off") { remove(k) }
                    if i < setup.kinds.count - 1 { Spacer(minLength: 2) }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if !plates.isEmpty {
                Button("Clear") { clear() }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
            Button { finish() } label: { Text(primaryTitle) }
                .buttonStyle(DSButtonStyle(kind: .primary))
        }
        .padding(.top, 2)
    }

    private var changed: Bool {
        guard request.onUse != nil else { return false }
        guard let s = request.startTotal else { return true }
        return abs(s - total) > 0.001
    }
    private var primaryTitle: String {
        changed ? "Use \(PlateMath.text(total)) \(gym.unit)\(request.useFor.map { " for \($0)" } ?? "")" : "Done"
    }

    // MARK: Behaviour

    private func start() {
        guard !appeared else { return }
        appeared = true
        if let t = request.startTotal {
            typed = PlateMath.text(t)
            aim(at: typed)
            if cantMake == nil { typed = PlateMath.text(total) }
        } else {
            typed = PlateMath.text(total)
        }
    }

    /// Typed a total: show its plates, or the nearest weights you can actually load.
    private func aim(at text: String) {
        guard let t = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            cantMake = nil; below = nil; above = nil
            return
        }
        let s = setup
        if let p = PlateMath.solve(t, s) {
            plates = p
            cantMake = nil; below = nil; above = nil
            return
        }
        let n = PlateMath.nearest(t, s)
        below = n.below; above = n.above
        let base = s.start + s.collars
        cantMake = t < base
            ? "The \(isMachine ? "sled" : "bar") alone is \(PlateMath.text(base)) \(gym.unit)."
            : "\(PlateMath.text(t)) can't be loaded with your plates."
        // Show the closer one on the bar.
        let pickW: Double? = {
            switch (n.below, n.above) {
            case let (b?, a?): return (t - b) <= (a - t) ? b : a
            case let (b?, nil): return b
            case let (nil, a?): return a
            default: return nil
            }
        }()
        plates = pickW.flatMap { PlateMath.solve($0, s) } ?? []
    }

    private func pick(_ w: Double) {
        plates = PlateMath.solve(w, setup) ?? plates
        cantMake = nil; below = nil; above = nil
        typed = PlateMath.text(total)
        totalFocused = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func add(_ k: PlateKind, left: Int) {
        guard left > 0 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        plates.append(k.weight)
        plates.sort(by: >)                     // heaviest stays innermost
        settle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func remove(_ k: PlateKind) {
        guard let i = plates.lastIndex(of: k.weight) else { return }
        plates.remove(at: i)
        settle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func clear() {
        plates = []
        settle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func settle() {
        cantMake = nil; below = nil; above = nil
        totalFocused = false
        typed = PlateMath.text(total)
    }

    private func finish() {
        if changed { request.onUse?(total) }
        dismiss()
    }
}

// MARK: - A plate in the tray

private struct PlateToken: View {
    let kind: PlateKind
    let count: Int
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [kind.lightColor, kind.baseColor, kind.darkColor],
                                         center: UnitPoint(x: 0.34, y: 0.3), startRadius: 1, endRadius: 30))
            Circle().stroke(Color.black.opacity(0.18), lineWidth: 1).padding(7)
            Circle().stroke(kind.edgeColor.opacity(0.5), lineWidth: 1)
            Text(kind.label).font(BrandFont.display(kind.weight < 10 ? 13 : 15)).foregroundColor(kind.ink)
        }
        .frame(width: 44, height: 44)
        .opacity(enabled || count > 0 ? 1 : 0.35)
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)").font(BrandFont.body(10, .heavy)).foregroundColor(Brand.onVolt)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Brand.volt))
                    .offset(x: 5, y: -5)
            }
        }
        .contentShape(Circle())
    }
}

// MARK: - The set-card barbell (same size and ring as the set number, mirrored)
// A flat, straight-on bar in your accent with this set's plates in competition colours.

struct PlateBarIcon: View {
    let plates: [PlateKind]                 // one side, heaviest first (innermost first)

    var body: some View {
        Canvas { ctx, size in
            let pw: CGFloat = 2.0, gap: CGFloat = 0.45, end: CGFloat = 1.5
            let side = CGFloat(plates.count) * (pw + gap)
            let grip = max(6, 11 - end - side)          // the open middle of the bar
            let half = grip + side + end
            let w = max(24, 2 * half + 1)
            let k = size.width / w
            let cx = size.width / 2, cy = size.height / 2
            var bar = Path()
            bar.move(to: CGPoint(x: cx - half * k, y: cy))
            bar.addLine(to: CGPoint(x: cx + half * k, y: cy))
            ctx.stroke(bar, with: .color(Brand.voltLine), style: StrokeStyle(lineWidth: max(1.4, 2 * k), lineCap: .round))
            for sgn: CGFloat in [-1, 1] {
                var x = grip
                for p in plates {
                    let h = 12 * p.size * k
                    let r = CGRect(x: sgn > 0 ? cx + x * k : cx - (x + pw) * k, y: cy - h / 2, width: pw * k, height: h)
                    let path = Path(roundedRect: r, cornerRadius: 0.9 * k)
                    ctx.fill(path, with: .color(p.baseColor))
                    ctx.stroke(path, with: .color(p.edgeColor), lineWidth: 0.4 * k)
                    x += pw + gap
                }
            }
        }
        .frame(width: 21, height: 21)
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(Brand.voltLine, lineWidth: 2))
        .contentShape(Circle())
    }
}

// MARK: - The menu row's icon (Tools ▸ Plate calculator)

struct PlateMenuGlyph: View {
    static let symbol = "bst.platecalculator"
    var bar: Color

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 24, cy = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 1 * k, y: cy)); line.addLine(to: CGPoint(x: 23 * k, y: cy))
            ctx.stroke(line, with: .color(bar), style: StrokeStyle(lineWidth: 2 * k, lineCap: .round))
            // One colour, like every other menu icon. Heaviest (tallest) plate inside, by the grip.
            let plates: [(CGFloat, CGFloat, CGFloat)] = [(4.9, 2.8, 14), (2.6, 1.9, 9),
                                                         (16.3, 2.8, 14), (19.5, 1.9, 9)]
            for (x, w, h) in plates {
                let r = CGRect(x: x * k, y: cy - h * k / 2, width: w * k, height: h * k)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1 * k), with: .color(bar))
            }
        }
        .frame(width: 20, height: 17)
    }
}

// MARK: - The angled 3D sleeve
// One side of the bar from a little in front: knurled shaft, the bar's collar, the plates at their
// real relative sizes (heaviest innermost), a lock collar and the bare end of the sleeve.

struct PlateSleeve3D: View {
    let plates: [PlateKind]
    let collar: Bool
    let stage: Color

    private let rMax: CGFloat = 104, k: CGFloat = 0.30

    var body: some View {
        Canvas { ctx, size in
            // Layout along the bar (drawing units, the bar's axis at y = 0)
            let sh0: CGFloat = -150, sh1: CGFloat = 40, rShaft: CGFloat = 7.5
            let s0 = sh1, s1 = sh1 + 14, rShoulder: CGFloat = 21, rSleeve: CGFloat = 12.5
            var x = s1 + 2
            var geo: [(xa: CGFloat, xb: CGFloat, r: CGFloat, p: PlateKind)] = []
            for p in plates {
                let th = p.thick * 1.25
                geo.append((x, x + th, rMax * p.size, p))
                x += th
            }
            let xc0 = x, xc1 = x + (collar && !plates.isEmpty ? 15 : 0)
            let xEnd = max(xc1 + 64, s1 + 150)
            let minX = sh0 + 40, maxX = xEnd + 24
            let minY = -rMax - 34, maxY = rMax + 44
            let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))

            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: .degrees(-8))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)

            // Floor shadow
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 9 * scale))
                l.fill(Path(ellipseIn: CGRect(x: s0 - 20, y: rMax + 5, width: xEnd - s0 + 40, height: 22)),
                       with: .color(.black.opacity(0.22)))
            }
            // Shaft, knurled, fading out to the left
            cylinder(&ctx, sh0, sh1, rShaft, [0xF1F3F6, 0xA9AFB8, 0x4D535C])
            ctx.drawLayer { l in
                l.clip(to: Path(CGRect(x: sh0, y: -rShaft, width: sh1 - 8 - sh0, height: rShaft * 2)))
                var hatch = Path()
                var hx = sh0 - 20
                while hx < sh1 { hatch.move(to: CGPoint(x: hx, y: -rShaft)); hatch.addLine(to: CGPoint(x: hx + rShaft * 2, y: rShaft)); hx += 3.2 }
                l.stroke(hatch, with: .color(Color(hex: 0x2C3036).opacity(0.5)), lineWidth: 0.7)
            }
            ctx.fill(Path(CGRect(x: sh0 - 10, y: -rShaft - 2, width: 122, height: rShaft * 2 + 4)),
                     with: .linearGradient(Gradient(colors: [stage, stage.opacity(0)]),
                                           startPoint: CGPoint(x: sh0, y: 0), endPoint: CGPoint(x: sh0 + 120, y: 0)))
            // The bar's own collar
            cylinder(&ctx, s0, s1, rShoulder, [0xE9ECF0, 0x9AA1AB, 0x3F454E])
            face(&ctx, s1, rShoulder, fill: Color(hex: 0xC5CAD1), stroke: Color(hex: 0x5B626C))
            if plates.isEmpty { cylinder(&ctx, s1, xEnd, rSleeve, [0xFAFBFC, 0xB9BFC7, 0x5B626C]) }

            // Plates, inside out
            for (i, g) in geo.enumerated() {
                let p = g.p
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [.init(color: p.lightColor, location: 0), .init(color: p.baseColor, location: 0.38),
                                     .init(color: p.darkColor, location: 1)]),
                    startPoint: CGPoint(x: 0, y: -g.r), endPoint: CGPoint(x: 0, y: g.r))
                rim(&ctx, g.xa, g.xb, g.r, shading)
                var hi = Path(); hi.move(to: CGPoint(x: g.xa + 1, y: -g.r + 1.2)); hi.addLine(to: CGPoint(x: g.xb, y: -g.r + 1.2))
                ctx.stroke(hi, with: .color(.white.opacity(0.35)), lineWidth: 1.2)
                let rx = g.r * k
                let faceRect = CGRect(x: g.xb - rx, y: -g.r, width: rx * 2, height: g.r * 2)
                ctx.fill(Path(ellipseIn: faceRect), with: .linearGradient(
                    Gradient(stops: [.init(color: p.darkColor, location: 0), .init(color: p.baseColor, location: 0.42),
                                     .init(color: p.lightColor, location: 0.78), .init(color: p.baseColor, location: 1)]),
                    startPoint: CGPoint(x: g.xb - rx, y: 0), endPoint: CGPoint(x: g.xb + rx, y: 0)))
                ctx.stroke(Path(ellipseIn: faceRect), with: .color(p.edgeColor), lineWidth: 0.8)
                let lip = faceRect.insetBy(dx: rx * 0.14, dy: g.r * 0.14)
                ctx.stroke(Path(ellipseIn: lip), with: .color(p.darkColor.opacity(0.45)), lineWidth: 1.4)
                ctx.stroke(Path(ellipseIn: lip.offsetBy(dx: 0.6, dy: 0)), with: .color(p.lightColor.opacity(0.35)), lineWidth: 0.8)
                let hub = rSleeve * 1.9
                face(&ctx, g.xb, hub, fill: Color(hex: 0xC9CED5), stroke: Color(hex: 0x6B727C))
                // The weight, printed on the face where it shows
                let next = i + 1 < geo.count ? geo[i + 1].r : 0
                if g.r - next >= 18 {
                    let ty = -(g.r + max(next, hub)) / 2
                    ctx.drawLayer { l in
                        l.translateBy(x: g.xb + rx * 0.06, y: ty)
                        l.scaleBy(x: 0.42, y: 1)
                        l.draw(Text(p.label).font(BrandFont.display(max(11, g.r * 0.16))).foregroundColor(p.ink.opacity(0.9)),
                               at: .zero, anchor: .center)
                    }
                }
            }
            if !plates.isEmpty {
                if collar {
                    cylinder(&ctx, xc0, xc1, 19, [0xD9DDE2, 0x6E747D, 0x24282E])
                    face(&ctx, xc1, 19, fill: Color(hex: 0x8A9099), stroke: Color(hex: 0x2A2F36))
                    ctx.fill(Path(roundedRect: CGRect(x: xc0 + 3, y: -30, width: 8, height: 12), cornerRadius: 2.5),
                             with: .color(Color(hex: 0x2E333A)))
                }
                cylinder(&ctx, xc1, xEnd, rSleeve, [0xFAFBFC, 0xB9BFC7, 0x5B626C])
            }
            face(&ctx, xEnd, rSleeve, fill: Color(hex: 0xE4E7EB), stroke: Color(hex: 0x5B626C))
            let inner = CGRect(x: xEnd - rSleeve * k * 0.55, y: -rSleeve * 0.55, width: rSleeve * k * 1.1, height: rSleeve * 1.1)
            ctx.stroke(Path(ellipseIn: inner), with: .color(Color(hex: 0x8C939C)), lineWidth: 0.6)
        }
    }

    /// A steel cylinder from xa to xb (light on top, dark underneath).
    private func cylinder(_ ctx: inout GraphicsContext, _ xa: CGFloat, _ xb: CGFloat, _ r: CGFloat, _ c: [UInt]) {
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: Color(hex: c[0]), location: 0), .init(color: Color(hex: c[1]), location: 0.38),
                             .init(color: Color(hex: c[2]), location: 1)]),
            startPoint: CGPoint(x: 0, y: -r), endPoint: CGPoint(x: 0, y: r))
        rim(&ctx, xa, xb, r, shading)
    }

    /// The side of a disc or tube: its outline is the near half of each end plus the straight run between.
    private func rim(_ ctx: inout GraphicsContext, _ xa: CGFloat, _ xb: CGFloat, _ r: CGFloat, _ shading: GraphicsContext.Shading) {
        let rx = r * k
        ctx.fill(Path(CGRect(x: xa, y: -r, width: max(0, xb - xa), height: r * 2)), with: shading)
        ctx.fill(Path(ellipseIn: CGRect(x: xa - rx, y: -r, width: rx * 2, height: r * 2)), with: shading)
        ctx.fill(Path(ellipseIn: CGRect(x: xb - rx, y: -r, width: rx * 2, height: r * 2)), with: shading)
    }

    private func face(_ ctx: inout GraphicsContext, _ x: CGFloat, _ r: CGFloat, fill: Color, stroke: Color) {
        let rect = CGRect(x: x - r * k, y: -r, width: r * k * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(fill))
        ctx.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 0.6)
    }
}

// MARK: - My Gym

struct MyGymView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gym = GymEquipment.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.text)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Brand.card))
                            .overlay(Circle().stroke(Brand.line, lineWidth: 1))
                    }
                    .accessibilityLabel("Back")
                    Text("My Gym").font(BrandFont.display(30)).foregroundColor(Brand.text)
                }

                group("BAR") {
                    ForEach(Array(gym.settings.bars.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { divider }
                        Button { gym.settings.barId = b.id } label: {
                            HStack(spacing: 12) {
                                radio(gym.settings.barId == b.id)
                                Text(b.name).font(BrandFont.body(14.5, .bold)).foregroundColor(Brand.text)
                                Spacer()
                                Text("\(PlateMath.text(gym.weight(of: b))) \(gym.unit)")
                                    .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                group("PLATES") {
                    ForEach(Array(gym.kinds.enumerated()), id: \.offset) { i, k in
                        if i > 0 { divider }
                        let n = gym.pairs(of: k.weight)
                        HStack(spacing: 12) {
                            Circle().fill(RadialGradient(colors: [k.lightColor, k.baseColor, k.darkColor],
                                                         center: UnitPoint(x: 0.34, y: 0.3), startRadius: 1, endRadius: 18))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(k.edgeColor.opacity(0.5), lineWidth: 1))
                                .opacity(n > 0 ? 1 : 0.35)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(k.label).font(BrandFont.display(20)).foregroundColor(n > 0 ? Brand.text : Brand.mute)
                                Text(gym.unit).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                            Text(n > 0 ? "pairs" : "none").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            stepper(n) { gym.setPairs($0, of: k.weight) }
                        }
                        .padding(.horizontal, 14).frame(minHeight: 48)
                    }
                }

                group("COLLARS") {
                    Toggle(isOn: $gym.settings.countCollars) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Count collars in the total").font(BrandFont.body(14.5, .bold)).foregroundColor(Brand.text)
                            Text("\(PlateMath.text(gym.isKg ? gym.settings.collarPairKg : gym.settings.collarPairLb)) \(gym.unit) a pair")
                                .font(BrandFont.body(11.5)).foregroundColor(Brand.mute)
                        }
                    }
                    .tint(Brand.volt)
                    .padding(.horizontal, 14).frame(minHeight: 52)
                }

                group("MACHINES") {
                    ForEach(Array(gym.settings.machines.enumerated()), id: \.element.id) { i, m in
                        if i > 0 { divider }
                        machineRow(m)
                    }
                    divider
                    Button {
                        gym.settings.machines.append(GymMachine(id: UUID().uuidString, name: "New machine", startLb: 0, sides: 2, keywords: []))
                    } label: {
                        Label("Add a machine", systemImage: "plus").font(BrandFont.body(14, .bold)).foregroundColor(Brand.voltText)
                            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                Text("Your plates and bar live on this phone. lb or kg follows Settings.")
                    .font(BrandFont.body(11.5)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private func machineRow(_ m: GymMachine) -> some View {
        let id = m.id
        func index() -> Int? { gym.settings.machines.firstIndex { $0.id == id } }
        let name = Binding<String>(
            get: { index().map { gym.settings.machines[$0].name } ?? "" },
            set: { t in if let j = index() { gym.settings.machines[j].name = t } })
        let sled = Binding<String>(
            get: { index().map { PlateMath.text(gym.shown(lb: gym.settings.machines[$0].startLb)) } ?? "" },
            set: { t in
                guard let v = Double(t.replacingOccurrences(of: ",", with: ".")), let j = index() else { return }
                gym.settings.machines[j].startLb = gym.lb(shown: v)
            })
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                TextField("Machine", text: name)
                    .font(BrandFont.body(14.5, .bold)).foregroundColor(Brand.text)
                Text(m.sides == 1 ? "One sleeve" : "Loads both sides").font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            Spacer(minLength: 6)
            Text("Sled").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            TextField("0", text: sled)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(BrandFont.display(18)).foregroundColor(Brand.text)
                .frame(width: 56)
                .padding(.horizontal, 6).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.bg))
            Text(gym.unit).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
            Button {
                gym.settings.machines.removeAll { $0.id == m.id }
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 16, weight: .semibold)).foregroundColor(Brand.mute)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(m.name)")
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 52)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(BrandFont.body(11, .heavy)).tracking(1.8).headerPill().padding(.leading, 2)
            VStack(spacing: 0) { rows() }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
        }
    }

    private var divider: some View { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 14) }

    private func radio(_ on: Bool) -> some View {
        ZStack {
            Circle().stroke(on ? Brand.voltLine : Brand.line, lineWidth: 2).frame(width: 22, height: 22)
            if on { Circle().fill(Brand.voltText).frame(width: 10, height: 10) }
        }
    }

    private func stepper(_ n: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { set(n - 1); UISelectionFeedbackGenerator().selectionChanged() } label: {
                Image(systemName: "minus").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 32)
            }
            .disabled(n == 0)
            Text("\(n)").font(BrandFont.display(18)).frame(minWidth: 22)
            Button { set(n + 1); UISelectionFeedbackGenerator().selectionChanged() } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 32)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(n > 0 ? Brand.text : Brand.mute)
        .background(Capsule().fill(Brand.bg))
        .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
    }
}
