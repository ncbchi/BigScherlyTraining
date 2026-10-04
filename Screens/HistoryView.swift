import SwiftUI

// MARK: - History tab (browse mode)
// Pick any exercise you've trained and see its full history + progress graph.
// Reuses the same ExerciseHistoryView shown inline on the workout page.
struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: String?

    // All distinct exercises the client has trained (from workouts)
    private var exercises: [String] {
        let names = store.workouts.flatMap { $0.exercises.map { $0.name } }
        return Array(Set(names)).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Track Your Progress")
                Text("History").font(BrandFont.display(48)).foregroundColor(Brand.text)
                Text("Pick a lift to see every session and your strength trend over time.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                // ---- Personal records (trophy case) ----
                if !store.personalRecords.isEmpty {
                    let prs = store.personalRecords.sorted { $0.date > $1.date }
                    HStack {
                        Image(systemName: "trophy.fill").foregroundColor(Brand.voltText)
                        Text("PERSONAL RECORDS").font(BrandFont.body(12, .bold))
                            .tracking(1.5).headerPill()
                        Spacer()
                        Text("\(prs.count)").font(BrandFont.body(12, .bold)).foregroundColor(Brand.mute)
                    }
                    .padding(.top, 6)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(prs.prefix(8)) { pr in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pr.exercise.uppercased())
                                        .font(BrandFont.body(10, .bold)).tracking(1)
                                        .foregroundColor(Brand.mute).lineLimit(1)
                                    Text("\(pr.reps)×\(Int(pr.weight))")
                                        .font(BrandFont.display(26)).foregroundColor(Brand.voltText)
                                    Text("\(Int(pr.estimatedOneRepMax)) lb 1RM")
                                        .font(BrandFont.body(11)).foregroundColor(Brand.text)
                                    Text(pr.isFirstEver ? "First record" : "+\(Int(pr.gain)) lb")
                                        .font(BrandFont.body(10, .bold)).foregroundColor(Brand.voltText)
                                }
                                .padding(14)
                                .frame(width: 140, alignment: .leading)
                                .background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1))
                            }
                        }
                    }
                }

                // ---- Strength trends across every lift ----
                let trends = ProgressEngine.trends(workouts: store.workouts)
                if !trends.isEmpty {
                    Text("STRENGTH TREND").font(BrandFont.body(12, .bold))
                        .tracking(1.5).headerPill().padding(.top, 10)
                    VStack(spacing: 0) {
                        ForEach(trends) { t in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.exercise).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                                    Text("\(t.sessions) session\(t.sessions == 1 ? "" : "s")")
                                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int(t.current)) lb").font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                                    if t.change != 0 {
                                        Text("\(t.change > 0 ? "+" : "")\(Int(t.change)) lb")
                                            .font(BrandFont.body(11, .bold))
                                            .foregroundColor(t.change > 0 ? Brand.voltText : Brand.mute)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            Divider().overlay(Brand.line)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Brand.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                }

                // Exercise picker chips
                let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(exercises, id: \.self) { name in
                        Button {
                            withAnimation { selected = (selected == name) ? nil : name }
                        } label: {
                            HStack {
                                Image(systemName: "dumbbell.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(selected == name ? Brand.onVolt : Brand.voltText)
                                Text(name).font(BrandFont.body(13, .semibold))
                                    .foregroundColor(selected == name ? Brand.onVolt : Brand.text)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(selected == name ? Brand.volt : Brand.black).clipShape(Capsule())
                            .overlay(Capsule().stroke(selected == name ? Brand.voltLine : Brand.line, lineWidth: 1))
                        }
                    }
                }

                // Selected exercise history
                if let name = selected {
                    Text(name.uppercased())
                        .font(BrandFont.display(28)).foregroundColor(Brand.text)
                        .padding(.top, 12)
                    ExerciseHistoryView(exerciseName: name)
                } else {
                    Text("Select a lift above to view its history.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}
