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
                Text("History").font(BrandFont.display(48)).foregroundColor(.white)
                Text("Pick a lift to see every session and your strength trend over time.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

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
                                    .foregroundColor(selected == name ? Brand.black : Brand.volt)
                                Text(name).font(BrandFont.body(13, .semibold))
                                    .foregroundColor(selected == name ? Brand.black : .white)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(selected == name ? Brand.volt : Brand.black)
                            .overlay(Rectangle().stroke(selected == name ? Brand.volt : Brand.line, lineWidth: 1))
                        }
                    }
                }

                // Selected exercise history
                if let name = selected {
                    Text(name.uppercased())
                        .font(BrandFont.display(28)).foregroundColor(.white)
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
