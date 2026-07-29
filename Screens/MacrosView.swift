import SwiftUI
import UIKit

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

                if store.macroDays.isEmpty {
                    EmptyState(icon: "fork.knife",
                               title: "No macro targets yet",
                               message: "Your coach hasn't set your daily targets yet. They'll appear here.")
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
        .overlay(isToday ? RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 2) : nil)
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
                    Capsule().fill(Brand.bg).frame(height: 10)
                    Capsule().fill(color).frame(width: geo.size.width * (Double(grams)/total), height: 10)
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
                            .font(BrandFont.body(10, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        goalRow("Calories", "\(day.calorieGoal)")
                        goalRow("Protein", "\(day.proteinGoal)g")
                        goalRow("Carbs", "\(day.carbGoal)g")
                        goalRow("Fat", "\(day.fatGoal)g")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 1))

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
                            .foregroundColor(Brand.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Brand.volt).clipShape(Capsule())
                        }

                        ShareLink(item: macroText) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("SHARE")
                            }
                            .font(BrandFont.body(13, .bold)).tracking(0.5)
                            .foregroundColor(Brand.volt)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.volt, lineWidth: 2))
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
                                Image(systemName: "arrow.up.forward.app.fill").foregroundColor(Brand.volt)
                                Text(app.rawValue).font(BrandFont.body(16, .semibold)).foregroundColor(.white)
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
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Macro Goals")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundColor(Brand.volt) } }
        }
    }

    private func goalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.body(15)).foregroundColor(Brand.mute)
            Spacer()
            Text(value).font(BrandFont.display(24)).foregroundColor(.white)
        }
    }
}
