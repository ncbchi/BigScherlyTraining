import SwiftUI

// MARK: - Macros — daily goals with bar graph + tracker deep-link
struct MacrosView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedDay: MacroDay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Nutrition")
                Text("Macros").font(BrandFont.display(48)).foregroundColor(.white)
                Text("Your daily targets, set by coach. Tap a day to log food in your tracker.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute).padding(.bottom, 4)

                ForEach(store.macroDays) { day in
                    macroCard(day)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .sheet(item: $selectedDay) { day in
            TrackerPickerSheet(day: day)
        }
    }

    func macroCard(_ day: MacroDay) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(day.date)).font(BrandFont.display(22)).foregroundColor(.white)
                    Text(day.isTrainingDay ? "TRAINING DAY" : "REST DAY")
                        .font(BrandFont.body(10, .bold)).tracking(1)
                        .foregroundColor(day.isTrainingDay ? Brand.black : Brand.volt)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(day.isTrainingDay ? Brand.volt : Color.clear)
                        .overlay(day.isTrainingDay ? nil : Capsule().stroke(Brand.volt, lineWidth: 1))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(day.calorieGoal)").font(BrandFont.display(30)).foregroundColor(Brand.volt)
                    Text("KCAL GOAL").font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                }
            }

            // Macro bars (proportional to grams)
            let total = Double(day.proteinGoal + day.carbGoal + day.fatGoal)
            VStack(spacing: 10) {
                macroBar("Protein", day.proteinGoal, total, Brand.volt)
                macroBar("Carbs", day.carbGoal, total, Color(hex: 0x3D9BE0))
                macroBar("Fat", day.fatGoal, total, Color(hex: 0xF2A03D))
            }

            if isToday {
                VoltButton(title: "Log Food →") { selectedDay = day }
            } else {
                Button { selectedDay = day } label: {
                    Text("Log Food →").font(BrandFont.body(13, .bold)).foregroundColor(Brand.volt)
                }
            }
        }
        .card()
        .overlay(isToday ? Rectangle().stroke(Brand.volt, lineWidth: 2) : nil)
    }

    func macroBar(_ label: String, _ grams: Int, _ total: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased()).font(BrandFont.body(11, .bold)).tracking(1).foregroundColor(.white)
                Spacer()
                Text("\(grams)g").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.bg).frame(height: 10)
                    Rectangle().fill(color).frame(width: geo.size.width * (Double(grams)/total), height: 10)
                }
            }
            .frame(height: 10)
        }
    }

    func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f.string(from: d)
    }
}

// MARK: - Tracker picker (deep-links out to MFP / Cronometer / Lose It!)
struct TrackerPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    let day: MacroDay

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Open your food tracker to log this day. Your macro goals stay here in the app.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute).padding(.bottom, 8)

                ForEach(TrackerApp.allCases, id: \.self) { app in
                    Button {
                        // In production: UIApplication.shared.open(URL(string: app.urlScheme)!)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.forward.app.fill").foregroundColor(Brand.volt)
                            Text(app.rawValue).font(BrandFont.body(16, .semibold)).foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(Brand.mute)
                        }
                        .card()
                    }
                }
                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Log Food")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }
}
