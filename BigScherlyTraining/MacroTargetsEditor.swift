import SwiftUI

// MARK: - A coach sets his own macro targets (Oct 8, 2026)
// Training-day and rest-day targets, written to the next two weeks of his self profile.
// A day counts as training when a workout is planned on it (else Mon/Wed/Fri). Uses the
// same per-day endpoint the coach uses for clients. Synchronized folder: no target step.

struct MacroTargetsEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let clientId: String

    @State private var train = Targets(kcal: "", protein: "", carbs: "", fat: "")
    @State private var rest = Targets(kcal: "", protein: "", carbs: "", fat: "")
    @State private var saving = false
    @State private var failed = false

    struct Targets { var kcal, protein, carbs, fat: String }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DSScreenHeader(eyebrow: "Fuel", title: "My targets",
                                   subtitle: "Applied to the next 14 days. Days with a workout planned use training targets.")
                    card("TRAINING DAY", $train)
                    card("REST DAY", $rest)
                    if failed {
                        Text("Couldn't save every day. Check your connection and try again.")
                            .font(BrandFont.body(12)).foregroundColor(.orange)
                    }
                    Button(action: save) {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(Brand.onVolt) }
                            Label("Save targets", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(saving || !valid)
                    .opacity(valid ? 1 : 0.5)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Macro targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            .tapToDismissKeyboard()
            .keyboardDoneButton()
            .onAppear(perform: prefill)
        }
    }

    private func card(_ title: String, _ t: Binding<Targets>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            HStack(spacing: 8) {
                num("KCAL", t.kcal)
                num("PROTEIN g", t.protein)
            }
            HStack(spacing: 8) {
                num("CARBS g", t.carbs)
                num("FAT g", t.fat)
            }
        }
        .card(padding: 16)
    }

    private func num(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(BrandFont.body(8, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
            TextField("", text: text, prompt: Text("0").foregroundColor(Brand.mute.opacity(0.6)))
                .keyboardType(.numberPad).font(BrandFont.display(24)).foregroundColor(Brand.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
    }

    private func n(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool {
        [train.kcal, train.protein, train.carbs, train.fat, rest.kcal, rest.protein, rest.carbs, rest.fat]
            .allSatisfy { (n($0) ?? -1) >= 0 }
    }

    private func prefill() {
        guard train.kcal.isEmpty else { return }
        if let t = store.macroDays.first(where: { $0.isTrainingDay }) {
            train = Targets(kcal: "\(t.calorieGoal)", protein: "\(t.proteinGoal)", carbs: "\(t.carbGoal)", fat: "\(t.fatGoal)")
        }
        if let r = store.macroDays.first(where: { !$0.isTrainingDay }) {
            rest = Targets(kcal: "\(r.calorieGoal)", protein: "\(r.proteinGoal)", carbs: "\(r.carbGoal)", fat: "\(r.fatGoal)")
        }
    }

    private func save() {
        saving = true; failed = false
        let cal = Calendar.training
        let today = cal.startOfDay(for: Date())
        let planned = Set(store.workouts.map { cal.startOfDay(for: $0.date) })
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let anyPlanned = days.contains { planned.contains($0) }
        let t = train, r = rest
        Task {
            var ok = true
            for d in days {
                // With no workouts planned yet, fall back to Mon / Wed / Fri.
                let wd = cal.component(.weekday, from: d)
                let training = anyPlanned ? planned.contains(d) : [2, 4, 6].contains(wd)
                let x = training ? t : r
                do {
                    try await APIClient.shared.trainerSetMacros(clientId: clientId, day: d, training: training,
                                                                kcal: n(x.kcal) ?? 0, protein: n(x.protein) ?? 0,
                                                                carbs: n(x.carbs) ?? 0, fat: n(x.fat) ?? 0)
                } catch { ok = false }
            }
            await MainActor.run {
                saving = false
                if ok { store.loadAllFromAPI(); dismiss() } else { failed = true }
            }
        }
    }
}
