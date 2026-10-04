import SwiftUI

// MARK: - Fine-tune burned calories
// A gentle heads-up that Watch calorie numbers are estimates, a slider from −20% to
// +20% of the reported number, and a suggested setting worked out from your heart
// rate, effort rating and (for lifting) bar-speed data — already selected.

struct BurnAdjustCard: View {
    let reportedKcal: Int
    let estimate: EffortEstimate
    @Binding var pct: Double

    private var adjusted: Int { Int((Double(reportedKcal) * (1 + pct)).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundColor(Brand.mute).padding(.top, 1)
                Text("Watch calorie numbers are estimates, and for lifting they can be off by a fair bit. Fine-tune it if you like.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(adjusted.formatted()) kcal").font(BrandFont.display(30)).foregroundColor(Brand.text).monospacedDigit()
                Text(pct == 0 ? "as reported" : String(format: "%@%.0f%%", pct > 0 ? "+" : "−", abs(pct) * 100))
                    .font(BrandFont.body(12, .bold)).foregroundColor(pct == 0 ? Brand.mute : Brand.voltText)
                Spacer()
                Text("Watch: \(reportedKcal.formatted())").font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }

            Slider(value: $pct, in: EffortEstimator.range, step: 0.05)
                .tint(Brand.volt)
                .accessibilityValue(String(format: "%.0f percent, %d calories", pct * 100, adjusted))

            // Scale with the suggestion marked.
            GeometryReader { g in
                let x = g.size.width * (estimate.suggestedPct + 0.2) / 0.4
                ZStack(alignment: .topLeading) {
                    HStack {
                        Text("−20%"); Spacer(); Text("as reported"); Spacer(); Text("+20%")
                    }
                    .font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute)
                    if estimate.signalCount > 0 {
                        VStack(spacing: 1) {
                            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7))
                            Text("SUGGESTED").font(BrandFont.body(8, .heavy)).tracking(0.8)
                        }
                        .foregroundColor(Brand.voltText)
                        .fixedSize()
                        .position(x: min(max(x, 30), g.size.width - 30), y: 26)
                    }
                }
            }
            .frame(height: 36)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("ESTIMATED EFFORT").font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    DSChip(text: estimate.effortLabel, color: Brand.volt)
                    Spacer()
                    if pct != estimate.suggestedPct {
                        Button("Use suggestion") { withAnimation { pct = estimate.suggestedPct } }
                            .font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText)
                    }
                }
                Text(EffortEstimator.explanation(estimate))
                    .font(BrandFont.body(12)).foregroundColor(Brand.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.text.opacity(0.04)))
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: - Log an extra activity

struct ActivityLogSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let day: Date
    var existing: ExtraActivity? = nil

    @State private var healthItems: [HealthActivity] = []
    @State private var loadingHealth = true
    @State private var pickedHealthId: String? = nil
    @State private var type = "Run"
    @State private var minutesText = ""
    @State private var kcalText = ""
    @State private var rpe: Int? = nil
    @State private var addToTarget = false
    @State private var pct: Double = 0
    @State private var maxHR: Int? = nil
    @State private var bodyweightKg: Double? = nil
    @State private var showLightPrompt = false
    @State private var didSetSuggestion = false

    private let types = ["Run", "Walk", "Ride", "Hike", "Swim", "Class", "Sport", "Other"]

    /// The type you log most often (Walk if you haven't logged anything yet).
    private var likelyType: String {
        let counts = Dictionary(grouping: MacroPlanStore.shared.activities.map(\.type), by: { $0 }).mapValues(\.count)
        return counts.filter { types.contains($0.key) }.max { $0.value < $1.value }?.key ?? "Walk"
    }
    private let minMinutes = 20, minKcal = 150

    private var picked: HealthActivity? { healthItems.first { $0.id == pickedHealthId } }
    private var minutes: Int { Int(minutesText) ?? picked?.minutes ?? 0 }
    private var kcal: Int? { Int(kcalText) ?? picked?.kcal }

    private var estimate: EffortEstimate {
        EffortEstimator.estimate(EffortSignals(minutes: Double(max(minutes, 1)), reportedKcal: Double(kcal ?? 0),
                                               avgHR: picked?.avgHR, maxHR: maxHR,
                                               rpe: rpe.map(Double.init), bodyweightKg: bodyweightKg))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Did something extra? Log it and this day can switch to your training-day macros.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .fixedSize(horizontal: false, vertical: true)

                    healthSection

                    DSSectionHeader(title: picked == nil ? "OR ENTER IT YOURSELF" : "DETAILS")
                    DSCarousel(options: types.map { DSCarousel<String>.Option(id: $0, label: $0) }, selection: $type,
                               likely: likelyType, itemWidth: 96, accessibilityName: "Activity type")
                    HStack(spacing: 10) {
                        numberField("MINUTES", $minutesText, placeholder: picked.map { "\($0.minutes)" } ?? "30")
                        numberField("CALORIES", $kcalText, placeholder: picked?.kcal.map { "\($0)" } ?? "optional")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HOW HARD WAS IT?").font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                        HStack(spacing: 4) {
                            ForEach(1...10, id: \.self) { n in
                                Button { rpe = (rpe == n ? nil : n) } label: {
                                    Text("\(n)").font(BrandFont.body(13, .bold))
                                        .foregroundColor(rpe == n ? Brand.onVolt : Brand.text)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(rpe == n ? Brand.volt : Brand.black))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Effort \(n) of 10")
                            }
                        }
                    }

                    if let k = kcal, k > 0 {
                        Toggle(isOn: $addToTarget.animation()) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add the calories I burned to today's target")
                                    .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                                Text("Off: the day just switches to your training-day macros.")
                                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                        }
                        .tint(Brand.volt)
                        if addToTarget {
                            BurnAdjustCard(reportedKcal: k, estimate: estimate, pct: $pct)
                        }
                    }

                    Button { save(checkLight: true) } label: {
                        Label(existing == nil ? "Log activity" : "Save changes", systemImage: "checkmark")
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(minutes <= 0)
                    .opacity(minutes <= 0 ? 0.5 : 1)

                    if existing != nil {
                        Button("Remove this activity", role: .destructive) {
                            if let e = existing { MacroPlanStore.shared.removeActivity(e.id) }
                            dismiss()
                        }
                        .font(BrandFont.body(13, .semibold)).frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) }
            }
            .alert("A lighter one — nice!", isPresented: $showLightPrompt) {
                Button("Count it as a training day") { save(checkLight: false, countsAsTraining: true) }
                Button("Log it, keep rest-day macros") { save(checkLight: false, countsAsTraining: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every bit of movement counts. Just a friendly heads-up: training-day macros are built for harder sessions (around \(minMinutes)+ minutes or \(minKcal)+ calories). Want to count this one anyway?")
            }
            .task { await load() }
            .onChange(of: estimate.suggestedPct) { _, s in
                // Pre-select the suggestion once (and again if the inputs change before you touch it).
                if !didSetSuggestion || pct == 0 { pct = s }
            }
            .onChange(of: addToTarget) { _, on in
                if on && !didSetSuggestion { pct = estimate.suggestedPct; didSetSuggestion = true }
            }
        }
    }

    // MARK: Health list

    @ViewBuilder
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSSectionHeader(title: "FROM APPLE HEALTH")
            if loadingHealth {
                HStack(spacing: 8) { ProgressView().tint(Brand.volt); Text("Checking Apple Health…").font(BrandFont.body(12)).foregroundColor(Brand.mute) }
            } else if healthItems.isEmpty {
                Text("Nothing recorded in Apple Health this day.").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            } else {
                ForEach(healthItems) { h in
                    let on = pickedHealthId == h.id
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { pick(on ? nil : h) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20)).foregroundColor(on ? Brand.voltText : Brand.mute)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(h.type) · \(h.start.formatted(date: .omitted, time: .shortened))")
                                    .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                                Text([ "\(h.minutes) min", h.kcal.map { "\($0) kcal" }, h.avgHR.map { "avg \($0) bpm" } ]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Brand.voltLine : Brand.line, lineWidth: on ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func numberField(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Brand.mute.opacity(0.6)))
                .keyboardType(.numberPad)
                .font(BrandFont.display(24)).foregroundColor(Brand.text).multilineTextAlignment(.center)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func pick(_ h: HealthActivity?) {
        pickedHealthId = h?.id
        if let h {
            type = ["Run", "Walk", "Ride", "Hike", "Swim"].contains(h.type) ? h.type : (h.type == "Sport" ? "Sport" : "Other")
            minutesText = "\(h.minutes)"
            kcalText = h.kcal.map { "\($0)" } ?? ""
        }
    }

    private func load() async {
        let demo = store.isDemoMode || APIConfig.useMock
        if existing == nil { type = likelyType }       // open on the most likely type
        if let e = existing {
            type = e.type; minutesText = "\(e.minutes)"; kcalText = e.reportedKcal.map { "\($0)" } ?? ""
            rpe = e.rpe; addToTarget = e.addToTarget; pct = e.adjustPct; didSetSuggestion = true
        }
        healthItems = await HealthActivityReader.activities(on: day, demo: demo)
        if let e = existing, let hid = e.healthId { pickedHealthId = hid }
        loadingHealth = false
        maxHR = await HealthActivityReader.observedMaxHR(demo: demo)
        if demo { bodyweightKg = 165 * 0.45359237 }
        else if let lb = await HealthKitManager.shared.latestBodyweightPounds() { bodyweightKg = lb * 0.45359237 }
    }

    private func save(checkLight: Bool, countsAsTraining: Bool = true) {
        let light = minutes < minMinutes && (kcal ?? 0) < minKcal
        if checkLight && light { showLightPrompt = true; return }
        var a = existing ?? ExtraActivity(day: Calendar.training.startOfDay(for: day), type: type, minutes: minutes)
        a.day = Calendar.training.startOfDay(for: day)
        a.start = picked?.start
        a.type = type
        a.minutes = minutes
        a.reportedKcal = kcal
        a.addToTarget = addToTarget && (kcal ?? 0) > 0
        a.adjustPct = a.addToTarget ? pct : 0
        a.countsAsTraining = light ? countsAsTraining : true
        a.fromHealth = picked != nil
        a.healthId = picked?.id
        a.avgHR = picked?.avgHR
        a.peakHR = picked?.peakHR
        a.rpe = rpe
        MacroPlanStore.shared.addActivity(a)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - Add a lifting session's calories to the day

struct SessionBurnSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let workout: Workout
    let reportedKcal: Int
    let minutes: Int

    @State private var pct: Double = 0
    @State private var estimate: EffortEstimate? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add the calories from \(workout.title) to this day's target?")
                        .font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let e = estimate {
                        BurnAdjustCard(reportedKcal: reportedKcal, estimate: e, pct: $pct)
                    } else {
                        ProgressView().tint(Brand.volt).frame(maxWidth: .infinity)
                    }
                    Button {
                        MacroPlanStore.shared.setSessionBurn(workoutId: workout.id,
                            SessionBurn(reportedKcal: reportedKcal, adjustPct: pct, day: workout.date))
                        dismiss()
                    } label: { Label("Add to today's target", systemImage: "plus") }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    if MacroPlanStore.shared.sessionBurns[workout.id] != nil {
                        Button("Remove from target", role: .destructive) {
                            MacroPlanStore.shared.setSessionBurn(workoutId: workout.id, nil)
                            dismiss()
                        }
                        .font(BrandFont.body(13, .semibold)).frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Session calories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            .task { await build() }
        }
    }

    /// Lifting signals: average set RPE, bar-speed loss, set density, heart rate.
    private func build() async {
        let demo = store.isDemoMode || APIConfig.useMock
        let session = StatsEngine(store: store).sessions(for: .session(workout.id), window: .all).first
        let rpes = workout.exercises.flatMap { $0.sets }.compactMap { $0.rpe }
        let losses = session?.motions.compactMap { $0.velocityLossPct } ?? []
        let sets = workout.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        let maxHR = await HealthActivityReader.observedMaxHR(demo: demo)
        var kg: Double? = demo ? 165 * 0.45359237 : nil
        if !demo, let lb = await HealthKitManager.shared.latestBodyweightPounds() { kg = lb * 0.45359237 }
        let e = EffortEstimator.estimate(EffortSignals(
            minutes: Double(max(minutes, 1)), reportedKcal: Double(reportedKcal),
            avgHR: session?.hr?.avg, maxHR: maxHR,
            rpe: rpes.isEmpty ? nil : Double(rpes.reduce(0, +)) / Double(rpes.count),
            velocityLossPct: losses.isEmpty ? nil : losses.reduce(0, +) / Double(losses.count),
            setsPerMinute: minutes > 0 ? Double(sets) / Double(minutes) : nil,
            bodyweightKg: kg))
        estimate = e
        pct = MacroPlanStore.shared.sessionBurns[workout.id]?.adjustPct ?? e.suggestedPct
    }
}
