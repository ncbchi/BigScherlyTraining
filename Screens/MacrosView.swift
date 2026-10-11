import SwiftUI
import UIKit
import Charts

// MARK: - Macros
// Swipe left/right to change day. The Monday–Sunday strip pulls down into a full
// calendar. Each day shows its targets as a ring; the client can move a training day
// within the same week (the workout moves too), log an extra activity to make a day a
// training day, and optionally add burned calories (fine-tuned) to the target.

struct MacrosView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var plan = MacroPlanStore.shared
    @State private var selectedDate: Date = Calendar.training.startOfDay(for: Date())
    @State private var forward = true
    @State private var copied = false
    @State private var trackerDay: MacroDay? = nil
    @State private var showCalendar = false
    @State private var editingTargets = false      // coach: his own targets
    @State private var activitySheet: ActivityTarget? = nil
    @State private var moveSheet: MoveRequest? = nil
    @State private var sessionBurn: Workout? = nil

    struct ActivityTarget: Identifiable { let id = UUID(); let day: Date; let existing: ExtraActivity? }
    struct MoveRequest: Identifiable { let id = UUID(); let day: Date; let makingTraining: Bool }

    private let cal = Calendar.training
    private let proteinColor = Brand.volt
    private let carbColor = Color(hex: 0x3D9BE0)
    private let fatColor = Color(hex: 0xF2A03D)

    private var planDays: [MacroDay] { store.macroDays.sorted { $0.date < $1.date } }
    private func macro(on d: Date) -> MacroDay? { planDays.first { cal.isDate($0.date, inSameDayAs: d) } }
    private func targets(_ m: MacroDay) -> EffectiveTargets { plan.targets(for: m, plan: planDays, workouts: store.workouts) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "Fuel", title: "Macros",
                               subtitle: store.isTrainer ? "Your targets. Swipe to change day." : "Your targets, set by your coach. Swipe to change day.")
                if store.isTrainer, store.selfClientId != nil {
                    Button { editingTargets = true } label: { Label("Set my targets", systemImage: "slider.horizontal.3") }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                weekStrip

                Group {
                    if let m = macro(on: selectedDate) {
                        let t = targets(m)
                        VStack(alignment: .leading, spacing: 18) {
                            ringCard(m, t)
                            HStack(spacing: 10) {
                                DSStatTile(value: "\(t.protein) g", label: "PROTEIN", color: proteinColor)
                                DSStatTile(value: "\(t.carbs) g", label: "CARBS", color: carbColor)
                                DSStatTile(value: "\(t.fat) g", label: "FAT", color: fatColor)
                            }
                            adjustCard(m, t)
                            weekCard
                            logCard(m, t)
                        }
                    } else {
                        noPlanCard
                    }
                }
                .id(plan.dayKey(selectedDate))
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            })
        .sheet(isPresented: $editingTargets) {
            if let me = store.selfClientId { MacroTargetsEditor(clientId: me) }
        }
        .sheet(item: $trackerDay) { d in TrackerPickerSheet(day: d) }
        .sheet(isPresented: $showCalendar) {
            MacroCalendarTray(selected: selectedDate) { d in
                forward = d > selectedDate
                withAnimation(.easeInOut(duration: 0.25)) { selectedDate = cal.startOfDay(for: d) }
                showCalendar = false
            }
            .sheetFitsContent()
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $activitySheet) { a in ActivityLogSheet(day: a.day, existing: a.existing) }
        .sheet(item: $moveSheet) { r in
            MoveTrainingDaySheet(day: r.day, makingTraining: r.makingTraining)
        }
        .sheet(item: $sessionBurn) { w in
            SessionBurnSheet(workout: w, reportedKcal: sessionKcal(w) ?? 0, minutes: sessionMinutes(w))
        }
    }

    private func step(_ dir: Int) {
        guard let d = cal.date(byAdding: .day, value: dir, to: selectedDate) else { return }
        forward = dir > 0
        withAnimation(.easeInOut(duration: 0.25)) { selectedDate = d }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Week strip (Mon–Sun) + pull-down calendar

    private var weekStrip: some View {
        let days = cal.trainingWeek(selectedDate)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let m = macro(on: d)
                    let on = cal.isDate(d, inSameDayAs: selectedDate)
                    let training = m.map { plan.isTraining($0) } ?? false
                    let hasActivity = !plan.activities(on: d).isEmpty
                    Button {
                        forward = d > selectedDate
                        withAnimation(.easeInOut(duration: 0.25)) { selectedDate = d }
                    } label: {
                        VStack(spacing: 3) {
                            Text(Calendar.trainingWeekdayLetters[i]).font(BrandFont.body(10, .heavy))
                            Text("\(cal.component(.day, from: d))").font(BrandFont.display(20))
                                .underline(cal.isDateInToday(d))
                            ZStack {
                                if hasActivity {
                                    Image(systemName: "figure.run").font(.system(size: 8, weight: .bold))
                                } else {
                                    Circle().fill(training ? (on ? Brand.black : Brand.volt) : Color.clear)
                                        .overlay(Circle().stroke(on ? Brand.onVolt : Brand.mute, lineWidth: training || m == nil ? 0 : 1))
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .frame(height: 9)
                        }
                        .foregroundColor(on ? Brand.onVolt : (m == nil ? Brand.mute.opacity(0.5) : Brand.text))
                        .frame(maxWidth: .infinity).frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Brand.voltLine : Brand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted))\(m == nil ? ", no targets" : (training ? ", training day" : ", rest day"))")
                }
            }
            Button { showCalendar = true } label: {
                HStack(spacing: 6) {
                    Capsule().fill(Brand.mute.opacity(0.6)).frame(width: 28, height: 4)
                    Text(selectedDate.formatted(.dateTime.month(.wide).year())).font(BrandFont.body(11, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Brand.mute)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full calendar")
        }
        .gesture(DragGesture(minimumDistance: 15).onEnded { v in
            if v.translation.height > 30, abs(v.translation.height) > abs(v.translation.width) { showCalendar = true }
        })
    }

    // MARK: Ring

    private struct Slice: Identifiable { let name: String; let grams: Int; let kcal: Int; let color: Color; var id: String { name } }

    private func ringCard(_ m: MacroDay, _ t: EffectiveTargets) -> some View {
        let parts = [Slice(name: "Protein", grams: t.protein, kcal: t.protein * 4, color: proteinColor),
                     Slice(name: "Carbs", grams: t.carbs, kcal: t.carbs * 4, color: carbColor),
                     Slice(name: "Fat", grams: t.fat, kcal: t.fat * 9, color: fatColor)]
        let total = max(1, parts.map { $0.kcal }.reduce(0, +))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(cal.isDateInToday(m.date) ? "TODAY" : m.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    DSChip(text: t.isTraining ? "Training day" : "Rest day",
                           icon: t.isTraining ? "bolt.fill" : "moon.fill", color: Brand.volt, filled: t.isTraining)
                    if let r = t.reason { Text(r).font(BrandFont.body(10)).foregroundColor(Brand.mute) }
                }
            }
            HStack(spacing: 18) {
                ZStack {
                    Chart(parts) { p in
                        SectorMark(angle: .value("kcal", p.kcal), innerRadius: .ratio(0.72), angularInset: 2)
                            .foregroundStyle(Brand.readableLine(p.color)).cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 0) {
                        Text(t.calories.formatted()).font(BrandFont.display(30)).foregroundColor(Brand.text)
                        Text("KCAL GOAL").font(BrandFont.body(9, .bold)).tracking(1.2).foregroundColor(Brand.mute)
                        if t.addedKcal > 0 {
                            Text("+\(t.addedKcal) burned").font(BrandFont.body(9, .bold)).foregroundColor(Brand.voltText)
                        }
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(t.calories) calorie goal: \(t.protein) grams protein, \(t.carbs) grams carbs, \(t.fat) grams fat")

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(parts) { p in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(p.color).frame(width: 10, height: 10).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                                Text("\(p.grams) g · \(Int((Double(p.kcal) / Double(total) * 100).rounded()))% of kcal")
                                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if t.addedKcal > 0 {
                Text("Includes \(t.addedKcal) kcal you chose to add from training — added as carbs.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        .card(padding: 16)
    }

    // MARK: Adjust this day

    private func completedWorkout(on d: Date) -> Workout? {
        store.workouts.first { $0.completed && cal.isDate($0.date, inSameDayAs: d) }
    }
    private func sessionKcal(_ w: Workout) -> Int? {
        if store.isDemoMode || APIConfig.useMock { return DemoMotion.session(workoutId: w.id).calories }
        return store.workoutVitals[w.id]?.activeCalories
    }
    private func sessionMinutes(_ w: Workout) -> Int {
        if store.isDemoMode || APIConfig.useMock { return DemoMotion.session(workoutId: w.id).minutes }
        return store.workoutVitals[w.id]?.durationMinutes ?? 60
    }

    @ViewBuilder
    private func adjustCard(_ m: MacroDay, _ t: EffectiveTargets) -> some View {
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: m.date)
        let planned = plan.plannedTraining(m)
        let hasOpenWorkout = store.workouts.contains { !$0.completed && cal.isDate($0.date, inSameDayAs: day) }
        let canMove = day >= today && (planned ? (hasOpenWorkout || completedWorkout(on: day) == nil) : true)
        let acts = plan.activities(on: day)
        let done = completedWorkout(on: day)

        VStack(alignment: .leading, spacing: 10) {
            Text("ADJUST THIS DAY").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()

            if canMove {
                Button { moveSheet = MoveRequest(day: day, makingTraining: !planned) } label: {
                    DSListRow(title: planned ? "Move this training day" : "Make this a training day",
                              subtitle: planned ? "Swap with a rest day this week — the workout moves too"
                                                : "Swap with a training day this week — its workout moves here",
                              icon: "arrow.left.arrow.right")
                }
                .buttonStyle(PressableStyle())
            }

            if day <= today {
                Button { activitySheet = ActivityTarget(day: day, existing: nil) } label: {
                    DSListRow(title: "Log an extra activity",
                              subtitle: "A run, ride, class… it can make today a training day", icon: "figure.run")
                }
                .buttonStyle(PressableStyle())
            }

            ForEach(acts) { a in
                Button { activitySheet = ActivityTarget(day: day, existing: a) } label: {
                    DSListRow(title: "\(a.type) · \(a.minutes) min",
                              subtitle: [a.reportedKcal.map { "\($0) kcal" },
                                         a.addToTarget ? "added \(a.adjustedKcal ?? 0) to target" : nil,
                                         a.countsAsTraining ? "training day" : "kept rest-day macros"]
                                .compactMap { $0 }.joined(separator: " · "),
                              icon: "checkmark.circle.fill")
                }
                .buttonStyle(PressableStyle())
            }

            if let w = done, let k = sessionKcal(w), k > 0 {
                let burn = plan.sessionBurns[w.id]
                Button { sessionBurn = w } label: {
                    DSListRow(title: burn == nil ? "Add session calories to target" : "Session calories added",
                              subtitle: burn == nil ? "\(w.title) · Watch says \(k) kcal"
                                                    : "\(burn!.adjustedKcal) kcal (\(String(format: "%+.0f%%", burn!.adjustPct * 100)) from the Watch's \(k))",
                              icon: "flame.fill")
                }
                .buttonStyle(PressableStyle())
            }

            if day < today && acts.isEmpty && done == nil {
                Text("Past days can't be moved, but you can still log something you did.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        .card(padding: 16)
    }

    // MARK: Week plan (Mon–Sun of the selected week)

    private var weekCard: some View {
        let days = cal.trainingWeek(selectedDate)
        let rows: [(date: Date, kcal: Int, training: Bool)] = days.compactMap { d in
            guard let m = macro(on: d) else { return nil }
            let t = targets(m)
            return (d, t.calories, t.isTraining)
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THIS WEEK").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                Text("\(rows.filter { $0.training }.count) training · \(rows.filter { !$0.training }.count) rest")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            Chart {
                ForEach(rows, id: \.date) { r in
                    BarMark(x: .value("Day", r.date, unit: .day), y: .value("kcal", r.kcal), width: .ratio(0.6))
                        .foregroundStyle(r.training ? Brand.voltLine : carbColor)
                        .opacity(cal.isDate(r.date, inSameDayAs: selectedDate) ? 1 : 0.55)
                        .cornerRadius(4)
                }
            }
            .chartXScale(domain: (days.first ?? Date())...(cal.date(byAdding: .day, value: 1, to: days.last ?? Date()) ?? Date()))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Brand.line)
                    AxisValueLabel { if let n = v.as(Double.self) { Text(ChartFormat.axis(n)) } }.foregroundStyle(Brand.mute)
                }
            }
            .chartXAxis {
                AxisMarks(values: days) { v in
                    AxisValueLabel(centered: true) {
                        if let d = v.as(Date.self), let i = days.firstIndex(where: { cal.isDate($0, inSameDayAs: d) }) {
                            Text(Calendar.trainingWeekdayLetters[i])
                        }
                    }
                    .foregroundStyle(Brand.mute)
                }
            }
            .frame(height: 160)
            HStack(spacing: 14) {
                legend(Brand.volt, "Training day")
                legend(carbColor, "Rest day")
                Spacer(minLength: 0)
                Text("kcal").font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
            }
            if let line = differenceLine {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundColor(Brand.voltText).padding(.top, 2)
                    Text(line).font(BrandFont.body(12, .medium)).foregroundColor(Brand.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(padding: 16)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(BrandFont.body(10)).foregroundColor(Brand.mute)
        }
    }

    /// "Training days get +400 kcal, all from carbs (+100 g)."
    private var differenceLine: String? {
        guard let t = plan.typical(training: true, in: planDays), let r = plan.typical(training: false, in: planDays),
              t.calorieGoal != r.calorieGoal else { return nil }
        let dk = t.calorieGoal - r.calorieGoal
        let dp = t.proteinGoal - r.proteinGoal, dc = t.carbGoal - r.carbGoal, df = t.fatGoal - r.fatGoal
        var parts: [String] = []
        if dp != 0 { parts.append("\(dp > 0 ? "+" : "−")\(abs(dp)) g protein") }
        if dc != 0 { parts.append("\(dc > 0 ? "+" : "−")\(abs(dc)) g carbs") }
        if df != 0 { parts.append("\(df > 0 ? "+" : "−")\(abs(df)) g fat") }
        let kcal = "\(dk > 0 ? "+" : "−")\(abs(dk).formatted()) kcal"
        if dp == 0 && df == 0 && dc != 0 { return "Training days get \(kcal), all from carbs (\(dc > 0 ? "+" : "−")\(abs(dc)) g)." }
        return "Training days get \(kcal): " + parts.joined(separator: ", ") + "."
    }

    private var noPlanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
            Text(planDays.isEmpty ? (store.isTrainer ? "No targets yet — tap Set my targets above."
                                                     : "Your coach hasn't set your daily targets yet. They'll appear here.")
                                  : "No targets set for this day yet.")
                .font(BrandFont.body(13)).foregroundColor(Brand.mute)
            if cal.startOfDay(for: selectedDate) <= cal.startOfDay(for: Date()) {
                Button { activitySheet = ActivityTarget(day: cal.startOfDay(for: selectedDate), existing: nil) } label: {
                    Label("Log an extra activity", systemImage: "figure.run")
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    // MARK: Log

    private func logCard(_ m: MacroDay, _ t: EffectiveTargets) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG WITH").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            Button {
                UIPasteboard.general.string = """
                Big Scherly Training — \(t.isTraining ? "Training Day" : "Rest Day")
                Calories: \(t.calories)
                Protein: \(t.protein)g
                Carbs: \(t.carbs)g
                Fat: \(t.fat)g
                """
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
            } label: {
                Label(copied ? "Copied" : "Copy these goals", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(DSButtonStyle(kind: .primary))
            HStack(spacing: 8) {
                ForEach(TrackerApp.allCases, id: \.self) { app in
                    Button { open(app) } label: { Text(app.rawValue).lineLimit(1).minimumScaleFactor(0.7) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            Button("More options") { trackerDay = m }
                .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
        }
        .card(padding: 16)
    }

    private func open(_ app: TrackerApp) {
        guard let url = URL(string: app.urlScheme) else { return }
        UIApplication.shared.open(url) { ok in
            if !ok, let storeURL = URL(string: app.appStoreURL) { UIApplication.shared.open(storeURL) }
        }
    }
}

// MARK: - Pick the day to swap with (same week only)

struct MoveTrainingDaySheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var plan = MacroPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    let day: Date
    let makingTraining: Bool      // true: pull a training day here; false: push this one elsewhere

    private let cal = Calendar.training

    private var candidates: [(date: Date, workout: Workout?)] {
        let today = cal.startOfDay(for: Date())
        return cal.trainingWeek(day).compactMap { d in
            guard d >= today, !cal.isDate(d, inSameDayAs: day),
                  let m = store.macroDays.first(where: { cal.isDate($0.date, inSameDayAs: d) }) else { return nil }
            let training = plan.plannedTraining(m)
            let open = store.workouts.first { !$0.completed && cal.isDate($0.date, inSameDayAs: d) }
            if makingTraining {
                // Pull from a training day that hasn't been done yet.
                guard training, store.workouts.first(where: { $0.completed && cal.isDate($0.date, inSameDayAs: d) }) == nil else { return nil }
                return (d, open)
            } else {
                guard !training else { return nil }
                return (d, nil)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(makingTraining
                     ? "Pick the training day to swap with. Its workout and macros move to \(day.formatted(.dateTime.weekday(.wide)))."
                     : "Pick a rest day this week. Your workout and training-day macros move there.")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
                if candidates.isEmpty {
                    Text("No days left this week to swap with. Training days can only move within the same Monday–Sunday week.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(candidates, id: \.date) { c in
                    Button {
                        try? plan.moveTrainingDay(from: makingTraining ? c.date : day,
                                                  to: makingTraining ? day : c.date, store: store)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } label: {
                        DSListRow(title: c.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                  subtitle: c.workout?.title ?? (makingTraining ? "Training day" : "Rest day"),
                                  icon: makingTraining ? "bolt.fill" : "moon.fill")
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(makingTraining ? "Make it a training day" : "Move training day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
        }
    }
}

// MARK: - Full calendar tray (pulls down from the week strip)

struct MacroCalendarTray: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var plan = MacroPlanStore.shared
    let selected: Date
    let pick: (Date) -> Void

    @State private var month: Date = Date()
    private let cal = Calendar.training

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                DSIconButton(systemName: "chevron.left", accessibilityLabel: "Previous month", size: 36) {
                    month = cal.date(byAdding: .month, value: -1, to: month) ?? month
                }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
                Spacer()
                DSIconButton(systemName: "chevron.right", accessibilityLabel: "Next month", size: 36) {
                    month = cal.date(byAdding: .month, value: 1, to: month) ?? month
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(Calendar.trainingWeekdayLetters.enumerated()), id: \.offset) { _, l in
                    Text(l).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
                }
            }
            let days = monthGrid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
                    let m = store.macroDays.first { cal.isDate($0.date, inSameDayAs: d) }
                    let training = m.map { plan.isTraining($0) } ?? false
                    let on = cal.isDate(d, inSameDayAs: selected)
                    Button { pick(d) } label: {
                        VStack(spacing: 2) {
                            Text("\(cal.component(.day, from: d))").font(BrandFont.body(13, cal.isDateInToday(d) ? .heavy : .semibold))
                                .underline(cal.isDateInToday(d))
                            if !plan.activities(on: d).isEmpty {
                                Image(systemName: "figure.run").font(.system(size: 7, weight: .bold))
                            } else if m != nil {
                                Circle().fill(training ? Brand.volt : Color.clear)
                                    .overlay(Circle().stroke(Brand.mute, lineWidth: training ? 0 : 1))
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .foregroundColor(on ? Brand.onVolt : (inMonth ? Brand.text : Brand.mute.opacity(0.4)))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Brand.volt : (training ? Brand.volt.opacity(0.12) : Brand.text.opacity(0.04))))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 4) { Circle().fill(Brand.volt).frame(width: 6, height: 6); Text("Training") }
                HStack(spacing: 4) { Circle().stroke(Brand.mute, lineWidth: 1).frame(width: 6, height: 6); Text("Rest") }
                HStack(spacing: 4) { Image(systemName: "figure.run").font(.system(size: 9)); Text("Extra activity") }
                Spacer()
                Button("Today") { pick(Date()) }.font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
            }
            .font(BrandFont.body(10)).foregroundColor(Brand.mute)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Brand.bg.ignoresSafeArea())
        .onAppear { month = selected }
    }

    private var monthGrid: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let start = cal.trainingWeekStart(interval.start)
        let lastDay = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let end = cal.date(byAdding: .day, value: 7, to: cal.trainingWeekStart(lastDay)) ?? interval.end
        let count = cal.dateComponents([.day], from: start, to: end).day ?? 35
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

// MARK: - Copy / Share macros + open tracker
// Shows the exact numbers in a copyable card, a Copy button, an iOS Share button,
// and quick-open buttons for common trackers. Tracker-agnostic — works with any app.
struct TrackerPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    let day: MacroDay
    @State private var copied = false

    // The formatted goals string clients paste into any tracker
    private var macroText: String {
        let type = day.isTrainingDay ? "Training Day" : "Rest Day"
        return """
        Big Scherly Training — \(type)
        Calories: \(day.calorieGoal)
        Protein: \(day.proteinGoal)g
        Carbs: \(day.carbGoal)g
        Fat: \(day.fatGoal)g
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Copy your goals and paste them into any food tracker, or open one below.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    // The copyable goal card
                    VStack(alignment: .leading, spacing: 12) {
                        Text(day.isTrainingDay ? "TRAINING DAY" : "REST DAY")
                            .font(BrandFont.body(10, .bold)).tracking(1.5).headerPill()
                        goalRow("Calories", "\(day.calorieGoal)")
                        goalRow("Protein", "\(day.proteinGoal)g")
                        goalRow("Carbs", "\(day.carbGoal)g")
                        goalRow("Fat", "\(day.fatGoal)g")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1))

                    // Copy + Share
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = macroText
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
                        } label: {
                            HStack {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "COPIED" : "COPY")
                            }
                            .font(BrandFont.body(13, .bold)).tracking(0.5)
                            .foregroundColor(Brand.onVolt)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Brand.volt).clipShape(Capsule())
                        }

                        ShareLink(item: macroText) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("SHARE")
                            }
                            .font(BrandFont.body(13, .bold)).tracking(0.5)
                            .foregroundColor(Brand.voltText)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 2))
                        }
                    }

                    // Quick-open a tracker (optional convenience)
                    Text("OPEN A TRACKER").font(BrandFont.body(10, .bold)).tracking(1.5)
                        .foregroundColor(Brand.mute).padding(.top, 6)
                    ForEach(TrackerApp.allCases, id: \.self) { app in
                        Button {
                            if let url = URL(string: app.urlScheme) {
                                UIApplication.shared.open(url) { success in
                                    if !success, let store = URL(string: app.appStoreURL) {
                                        UIApplication.shared.open(store)   // fall back to App Store
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.forward.app.fill").foregroundColor(Brand.voltText)
                                Text(app.rawValue).font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(Brand.mute)
                            }
                            .card()
                        }
                    }

                    Text("Tip: paste your goals into the tracker's macro-goal settings once — you only need to update when your coach changes them.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute).padding(.top, 4)
                }
                .padding(20)
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Macro Goals")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.voltText) } }
        }
    }

    private func goalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.body(15)).foregroundColor(Brand.mute)
            Spacer()
            Text(value).font(BrandFont.display(24)).foregroundColor(Brand.text)
        }
    }
}
