import SwiftUI
import Charts

// MARK: - Phone ▸ a client ▸ Macros (Oct 15, 2026)
//
// Canvas "Macros · 1 — A client's Macros tab" and "· 2 — New targets, and from a check-in". The iPad's
// client Macros (PadClientMacros) on the phone: two weeks of targets with activity bumps, bodyweight from
// check-ins and the nutrition / hunger scores (charts with both axes labelled), and New targets: training
// and rest days, presets from their latest bodyweight, a start day, 2 or 4 weeks. Training days follow
// their planned sessions. The check-in review gets the same Macros line the iPad has (CheckInMacrosBox).
// Writes one day at a time through /admin/clients/{id}/macros, as the iPad and the web do.
// Synchronized folder: no target step needed.

// MARK: Writing targets

enum ClientMacroWriter {
    struct Targets { var protein: Int; var carbs: Int; var fat: Int; var kcal: Int { protein * 4 + carbs * 4 + fat * 9 } }

    /// The days this client has a session planned, from their workouts.
    static func trainingDays(clientId: String) async -> Set<Date> {
        let cal = Calendar.training
        let ws = (try? await APIClient.shared.trainerWorkouts(clientId: clientId)) ?? []
        return Set(ws.map { cal.startOfDay(for: $0.scheduledDate) })
    }

    /// Writes `days` days from `start`. Returns how many didn't save.
    static func write(clientId: String, start: Date, days: Int, training: Targets, rest: Targets, trainingDays: Set<Date>) async -> Int {
        let cal = Calendar.training
        let first = cal.startOfDay(for: start)
        var bad = 0
        for i in 0..<days {
            let d = cal.date(byAdding: .day, value: i, to: first) ?? first
            let isTraining = trainingDays.contains(cal.startOfDay(for: d))
            let t = isTraining ? training : rest
            do {
                try await APIClient.shared.trainerSetMacros(clientId: clientId, day: d, training: isTraining,
                                                            kcal: t.kcal, protein: t.protein, carbs: t.carbs, fat: t.fat)
            } catch { bad += 1 }
        }
        return bad
    }

    /// The client's macro days, read through a short view-as token (the coach route doesn't list them).
    static func load(clientId: String) async throws -> [APIMacroDay] {
        let v = try await APIClient.shared.viewAsToken(clientId: clientId)
        let ds: [APIMacroDay] = try await APIClient.shared.get("/macros", token: v.token)
        return ds
    }
}

// MARK: The tab

/// One dot on a chart.
struct MacroChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct CoachClientMacrosView: View {
    let client: RosterItem
    @ObservedObject private var coach = CoachData.shared
    @State private var days: [APIMacroDay] = []
    @State private var plan: APIPlanAdjustments?
    @State private var training: Set<Date> = []
    @State private var loading = true
    @State private var failed = false
    @State private var tP = ""
    @State private var tC = ""
    @State private var tF = ""
    @State private var rP = ""
    @State private var rC = ""
    @State private var rF = ""
    @State private var start = Calendar.training.date(byAdding: .day, value: 1, to: Calendar.training.startOfDay(for: Date())) ?? Date()
    @State private var length = 14
    @State private var saving = false
    @State private var note: String?

    private var cal: Calendar { Calendar.training }
    private var first: String { client.name.firstName }
    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.training; f.timeZone = Calendar.training.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tiles
                ForEach(notices, id: \.self) { n in
                    Text(n).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
                }
                grid
                bodyweightCard
                scoresCard
                editor
            }
            .padding(.horizontal, 16).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Loading

    private func load() async {
        do {
            days = try await ClientMacroWriter.load(clientId: client.id)
            failed = false
            prefill()
        } catch {
            failed = true
        }
        loading = false
        async let p = try? await APIClient.shared.trainerClientPlan(clientId: client.id)
        async let t = ClientMacroWriter.trainingDays(clientId: client.id)
        plan = await p
        training = await t
        await coach.loadCheckIns(client.id)
    }

    private func prefill() {
        let upcoming = days.filter { $0.date >= cal.startOfDay(for: Date()) }.sorted { $0.date < $1.date }
        if tP.isEmpty, let t = upcoming.first(where: { $0.isTrainingDay }) ?? days.last(where: { $0.isTrainingDay }) {
            tP = "\(t.proteinGoal)"; tC = "\(t.carbGoal)"; tF = "\(t.fatGoal)"
        }
        if rP.isEmpty, let r = upcoming.first(where: { !$0.isTrainingDay }) ?? days.last(where: { !$0.isTrainingDay }) {
            rP = "\(r.proteinGoal)"; rC = "\(r.carbGoal)"; rF = "\(r.fatGoal)"
        }
    }

    private func day(_ d: Date) -> APIMacroDay? { days.first { cal.isDate($0.date, inSameDayAs: d) } }

    /// Activity the client logged with "add to my target": the kcal added that day.
    private func bump(_ d: Date) -> Int? {
        guard let p = plan else { return nil }
        let key = Self.dayKey.string(from: d)
        var kcal: Int = 0
        for a in p.activities where a.day == key && a.addToTarget {
            kcal += Int((Double(a.reportedKcal ?? 0) * (1 + a.adjustPct)).rounded())
        }
        return kcal > 0 ? kcal : nil
    }

    private var checkIns: [APICheckIn] {
        (coach.checkIns[client.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }
    }

    private func scores(_ word: String) -> [(Date, Double)] {
        checkIns.suffix(8).compactMap { c in
            c.fields.first { $0.cleanLabel.lowercased().contains(word) }.flatMap { Double($0.value) }.map { (c.date, $0) }
        }
    }

    private var bodyweights: [(Date, Double)] {
        let since = cal.date(byAdding: .day, value: -35, to: Date()) ?? Date()
        return checkIns.filter { $0.date >= since }.compactMap { c in PadInsights.bodyweight(c).map { (c.date, $0) } }
    }

    /// lb per week over the last ~5 weeks of check-ins.
    private var weightRate: Double? {
        let bw = bodyweights
        guard bw.count >= 2, let a = bw.first, let b = bw.last else { return nil }
        let wks = max(b.0.timeIntervalSince(a.0) / (7 * 86_400), 1)
        return (b.1 - a.1) / wks
    }

    private var avgKcal: Int? {
        let since = cal.date(byAdding: .day, value: -28, to: Date()) ?? Date()
        let ks = days.filter { $0.date >= since && $0.date <= Date() }.map { $0.calorieGoal }
        return ks.isEmpty ? nil : ks.reduce(0, +) / ks.count
    }

    // MARK: Top

    private var tiles: some View {
        let today = day(Date())
        let w: Double? = weightRate.map { StatsUnits.weight($0) }
        let hunger = scores("hunger")
        let nutrition = scores("nutrition")
        return HStack(spacing: 8) {
            DSStatTile(value: today.map { "\($0.calorieGoal)" } ?? "—", label: "TODAY",
                       sub: today.map { ($0.isTrainingDay ? "training" : "rest") + " · \($0.proteinGoal) g P" } ?? (loading ? "" : "no target"), color: Brand.text)
            DSStatTile(value: w.map { ($0 >= 0 ? "+" : "−") + String(format: "%.1f", abs($0)) } ?? "—", label: "BODYWEIGHT",
                       sub: w == nil ? "needs 2 check-ins" : "\(StatsUnits.weightLabel)/wk" + (avgKcal.map { " · ~\($0)" } ?? ""))
            if let h = hunger.last {
                DSStatTile(value: "\(Int(h.1))/10", label: "HUNGER", sub: hunger.count >= 2 ? "was \(Int(hunger[hunger.count - 2].1))" : "latest",
                           color: h.1 >= 7 ? .orange : Brand.text)
            } else if let n = nutrition.last {
                DSStatTile(value: "\(Int(n.1))/10", label: "NUTRITION", sub: nutrition.count >= 2 ? "was \(Int(nutrition[nutrition.count - 2].1))" : "latest",
                           color: n.1 <= 5 ? .orange : Brand.text)
            }
        }
    }

    private var notices: [String] {
        var out: [String] = []
        if let r = weightRate, let k = avgKcal {
            let w = StatsUnits.weight(r)
            let verb: String = abs(w) < 0.15 ? "Holding steady" : (w < 0 ? "Losing " : "Gaining ") + String(format: "%.1f", abs(w)) + " " + StatsUnits.weightLabel + " a week"
            out.append("\(verb) on about \(k) kcal. Does that match \(first)'s goal?")
        }
        let h = scores("hunger").map { $0.1 }
        if h.count >= 3, h[h.count - 1] - h[h.count - 3] >= 2 {
            out.append("Hunger is climbing: \(Int(h[h.count - 3])) → \(Int(h[h.count - 1])) over 3 check-ins. More protein or fibre, or a small carb bump on training days.")
        }
        return out
    }

    // MARK: Two weeks

    private var grid: some View {
        let s = cal.startOfWeek(for: Date())
        let ds = (0..<14).map { cal.date(byAdding: .day, value: $0, to: s) ?? s }
        let today = cal.startOfDay(for: Date())
        let gap: Date? = ds.first { $0 >= today && day($0) == nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THIS WEEK AND NEXT").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                Text("kcal · P·C·F g").font(BrandFont.body(10)).foregroundColor(Brand.mute)
            }
            if loading { ProgressView().tint(Brand.volt).frame(maxWidth: .infinity, minHeight: 80) }
            else if failed { Text("Couldn't load \(first)'s macros. Pull down to try again.").font(BrandFont.body(13)).foregroundColor(.orange) }
            else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(ds, id: \.self) { d in cell(d) }
                }
                if let gap {
                    Text("Nothing set from \(gap.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).")
                        .font(BrandFont.body(11, .semibold)).foregroundColor(.orange)
                }
            }
        }
        .card(padding: 12)
    }

    private func cell(_ d: Date) -> some View {
        let m = day(d)
        let isToday = cal.isDateInToday(d)
        let b = bump(d)
        let past = d < cal.startOfDay(for: Date())
        return VStack(spacing: 2) {
            Text(isToday ? "Today" : d.formatted(.dateTime.weekday(.abbreviated))).font(BrandFont.body(9, .heavy))
                .foregroundColor(isToday ? Brand.text : Brand.mute).lineLimit(1)
            Text(d.formatted(.dateTime.day())).font(BrandFont.body(8)).foregroundColor(Brand.mute)
            if let m {
                Text(m.isTrainingDay ? "TRAIN" : "REST").font(BrandFont.body(7.5, .heavy)).foregroundColor(m.isTrainingDay ? Brand.voltText : Brand.mute)
                Text("\(m.calorieGoal + (b ?? 0))").font(BrandFont.display(16)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(m.proteinGoal)·\(m.carbGoal)·\(m.fatGoal)").font(BrandFont.body(7.5)).foregroundColor(Brand.mute).lineLimit(1).minimumScaleFactor(0.6)
                if let b { Text("+\(b)").font(BrandFont.body(8, .heavy)).foregroundColor(Brand.voltText) }
            } else {
                Text("—").font(BrandFont.display(16)).foregroundColor(Brand.mute)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 9).fill(Brand.text.opacity(isToday ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isToday ? Brand.voltLine : Color.clear, lineWidth: 1.5))
        .opacity(past ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Charts (two labelled axes)

    private var bodyweightCard: some View {
        let bw: [MacroChartPoint] = bodyweights.map { MacroChartPoint(date: $0.0, value: StatsUnits.weight($0.1)) }
        let lo = (bw.map { $0.value }.min() ?? 0) - 1, hi = (bw.map { $0.value }.max() ?? 1) + 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("BODYWEIGHT · 5 WEEKS OF CHECK-INS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            if bw.count >= 2 {
                Chart {
                    ForEach(bw) { p in
                        LineMark(x: .value("Check-in date", p.date), y: .value("Bodyweight", p.value))
                            .foregroundStyle(Brand.voltLine).lineStyle(StrokeStyle(lineWidth: 2.2))
                        PointMark(x: .value("Check-in date", p.date), y: .value("Bodyweight", p.value))
                            .foregroundStyle(Brand.voltLine).symbolSize(30)
                    }
                }
                .chartYScale(domain: lo...hi)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxisLabel("Check-in date", alignment: .center)
                .chartYAxisLabel("Bodyweight (\(StatsUnits.weightLabel))", position: .leading)
                .frame(height: 170)
            } else {
                Text("Needs two check-ins with bodyweight.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
            }
        }
        .card(padding: 12)
    }

    @ViewBuilder private var scoresCard: some View {
        let n: [MacroChartPoint] = scores("nutrition").map { MacroChartPoint(date: $0.0, value: $0.1) }
        let h: [MacroChartPoint] = scores("hunger").map { MacroChartPoint(date: $0.0, value: $0.1) }
        if n.count >= 2 || h.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                Text("CHECK-IN SCORES · LAST 8").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Chart {
                    ForEach(n) { p in
                        LineMark(x: .value("Check-in date", p.date), y: .value("Score", p.value), series: .value("Score", "Nutrition"))
                            .foregroundStyle(by: .value("Score", "Nutrition"))
                    }
                    ForEach(h) { p in
                        LineMark(x: .value("Check-in date", p.date), y: .value("Score", p.value), series: .value("Score", "Hunger"))
                            .foregroundStyle(by: .value("Score", "Hunger"))
                    }
                }
                .chartForegroundStyleScale(["Nutrition": Brand.voltLine, "Hunger": Color.orange])
                .chartYScale(domain: 0...10)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 5, 10]) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxisLabel("Check-in date", alignment: .center)
                .chartYAxisLabel("Score (out of 10)", position: .leading)
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 150)
            }
            .card(padding: 12)
        }
    }

    // MARK: New targets

    private func kcal(_ p: String, _ c: String, _ f: String) -> Int? {
        guard let p = Int(p), let c = Int(c), let f = Int(f) else { return nil }
        return p * 4 + c * 4 + f * 9
    }

    private var trainingWeekdays: String {
        let cal = self.cal
        let next = training.filter { $0 >= cal.startOfDay(for: Date()) }
        let wds = Set(next.map { (cal.component(.weekday, from: $0) + 5) % 7 })   // Monday = 0
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return wds.sorted().map { names[$0] }.joined(separator: ", ")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("NEW TARGETS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                Menu {
                    Button("Cut") { preset(12) }
                    Button("Maintain") { preset(14) }
                    Button("Build") { preset(16) }
                } label: {
                    Label("Preset", systemImage: "wand.and.stars").font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                }
            }
            row("Training days", $tP, $tC, $tF)
            row("Rest days", $rP, $rC, $rF)
            Text("Presets use their latest bodyweight: protein 1 g/lb, fat 0.35 g/lb, carbs fill the rest. Rest days carry 25% fewer carbs.")
                .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Starts").font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                Spacer(minLength: 4)
                DatePicker("Starts", selection: $start, in: cal.startOfDay(for: Date())..., displayedComponents: .date)
                    .labelsHidden().tint(Brand.voltText)
            }
            HStack(spacing: 10) {
                Text("For").font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                Spacer(minLength: 4)
                Picker("For", selection: $length) {
                    Text("2 weeks").tag(14)
                    Text("4 weeks").tag(28)
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)
            }
            if let note { Text(note).font(BrandFont.body(12, .bold)).foregroundColor(note.hasPrefix("Couldn") ? .orange : Brand.voltText) }
            Button { save() } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView().tint(Brand.onVolt) }
                    Label("Set targets for \(first)", systemImage: "checkmark")
                }
            }
            .buttonStyle(DSButtonStyle(kind: .primary))
            .disabled(saving || kcal(tP, tC, tF) == nil || kcal(rP, rC, rF) == nil)
            .opacity(kcal(tP, tC, tF) == nil || kcal(rP, rC, rF) == nil ? 0.5 : 1)
            Text(trainingWeekdays.isEmpty ? "Training days follow \(first)'s planned sessions. None are planned yet, so every day uses rest-day targets."
                                          : "Training days follow \(first)'s planned sessions (\(trainingWeekdays)).")
                .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 16)
    }

    private func row(_ label: String, _ p: Binding<String>, _ c: Binding<String>, _ f: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                Spacer()
                Text(kcal(p.wrappedValue, c.wrappedValue, f.wrappedValue).map { "\($0) kcal" } ?? "").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
            }
            HStack(spacing: 6) { field("P", p); field("C", c); field("F", f) }
        }
    }

    private func field(_ l: String, _ b: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField("0", text: b).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .font(BrandFont.display(20)).foregroundColor(Brand.text)
            Text("g \(l)").font(BrandFont.body(10, .heavy)).foregroundColor(Brand.mute)
        }
        .padding(.horizontal, 10).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.text.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(l == "P" ? "Protein" : (l == "C" ? "Carbs" : "Fat")) grams")
    }

    private func preset(_ kcalPerLb: Double) {
        let lb = bodyweights.last?.1 ?? checkIns.compactMap { PadInsights.bodyweight($0) }.last ?? 170
        let p = Int(lb.rounded()), f = Int((lb * 0.35).rounded())
        let total = lb * kcalPerLb
        let c = max(Int(((total - Double(p * 4 + f * 9)) / 4).rounded()), 50)
        tP = "\(p)"; tF = "\(f)"; tC = "\(c)"
        rP = "\(p)"; rF = "\(f)"; rC = "\(Int((Double(c) * 0.75).rounded()))"
    }

    private func save() {
        guard let tp = Int(tP), let tc = Int(tC), let tf = Int(tF), let rp = Int(rP), let rc = Int(rC), let rf = Int(rF) else { return }
        saving = true; note = nil
        let id = client.id, from = start, n = length, train = training
        Task {
            let bad = await ClientMacroWriter.write(clientId: id, start: from, days: n,
                                                    training: .init(protein: tp, carbs: tc, fat: tf),
                                                    rest: .init(protein: rp, carbs: rc, fat: rf), trainingDays: train)
            if let ds = try? await ClientMacroWriter.load(clientId: id) { days = ds }
            saving = false
            note = bad == 0 ? "New targets for \(first) from \(from.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())). 👑"
                            : "Couldn't save \(bad) day\(bad == 1 ? "" : "s"). Try again."
            if bad == 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}

// MARK: - Check-in review ▸ Macros (same as the iPad's reply)

/// One line with today's targets; tap to change them along with the reply. Blank keeps their targets.
struct CheckInMacrosBox: View {
    let clientId: String
    @Binding var protein: String
    @Binding var carbs: String
    @Binding var fat: String
    @State private var open = false
    @State private var current: String?

    var filled: Bool { !protein.isEmpty || !carbs.isEmpty || !fat.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie").font(.system(size: 15, weight: .semibold)).foregroundColor(Brand.text)
                    Text("Macros").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                    Text(summary).font(BrandFont.body(12, .bold)).foregroundColor(filled ? Brand.voltText : Brand.mute).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
                }
                .padding(.horizontal, 12).frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the macro fields" : "Change their macros with this reply")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) { field("PROTEIN", $protein); field("CARBS", $carbs); field("FAT", $fat) }
                    Text(filled ? "Starts tomorrow, for 14 days. Calories follow (4 · 4 · 9)." : "Leave blank to keep their targets.")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.05)))
        .task { await loadCurrent() }
    }

    private var summary: String {
        guard filled else { return current ?? "keep as they are" }
        return "New: \(protein.isEmpty ? "–" : protein) P · \(carbs.isEmpty ? "–" : carbs) C · \(fat.isEmpty ? "–" : fat) F"
    }

    private func field(_ label: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(BrandFont.body(8, .heavy)).tracking(1).foregroundColor(Brand.mute)
            TextField("g", text: b).keyboardType(.numberPad).font(BrandFont.display(20)).foregroundColor(Brand.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Brand.text.opacity(0.07)))
    }

    private func loadCurrent() async {
        guard current == nil, let ds = try? await ClientMacroWriter.load(clientId: clientId) else { return }
        let cal = Calendar.training
        guard let t = ds.first(where: { cal.isDateInToday($0.date) }) ?? ds.max(by: { $0.date < $1.date }) else { return }
        current = "\(t.proteinGoal) P · \(t.carbGoal) C · \(t.fatGoal) F"
    }

    /// Called after the reply goes: writes 14 days from tomorrow when all three are filled.
    static func apply(clientId: String, protein: String, carbs: String, fat: String) async {
        guard let p = Int(protein), let c = Int(carbs), let f = Int(fat) else { return }
        let cal = Calendar.training
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let t = ClientMacroWriter.Targets(protein: p, carbs: c, fat: f)
        let train = await ClientMacroWriter.trainingDays(clientId: clientId)
        _ = await ClientMacroWriter.write(clientId: clientId, start: tomorrow, days: 14, training: t, rest: t, trainingDays: train)
    }
}
