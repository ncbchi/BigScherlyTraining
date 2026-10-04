import SwiftUI

private let volt = Color(red: 0xED/255, green: 0xFF/255, blue: 0x3D/255)

// MARK: - "Set detected" confirm sheet
// Pops up after the wrist notices a set. One tap logs it to the suggested set
// (pre-filled with the detected reps); or pick a different set; or throw it away.

struct WatchDetectedSetView: View {
    @EnvironmentObject var state: WatchState
    let detection: DetectedSet

    private var exercise: WatchExercise? {
        guard let id = detection.suggestedExerciseId else { return nil }
        return state.activeWorkout?.exercises.first(where: { $0.id == id })
    }
    private var setNumber: Int? {
        guard let ex = exercise, let sid = detection.suggestedSetId,
              let i = ex.sets.firstIndex(where: { $0.id == sid }) else { return nil }
        return i + 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    VStack(spacing: 2) {
                        Text("SET DETECTED")
                            .font(.system(size: 10, weight: .black)).tracking(1.5).foregroundColor(volt)
                        Text("\(detection.reps.count) rep\(detection.reps.count == 1 ? "" : "s")")
                            .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text(String(format: "%.2f m/s avg · %.0f in deep",
                                    detection.meanVelocity, detection.averageTravelM * 39.37))
                            .font(.system(size: 11)).foregroundColor(.gray)
                    }

                    if let ex = exercise, let sid = detection.suggestedSetId, let n = setNumber {
                        VStack(spacing: 2) {
                            Text(ex.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                .multilineTextAlignment(.center).lineLimit(2)
                            Text("Set \(n)").font(.system(size: 12)).foregroundColor(.gray)
                            if detection.confident {
                                Label("Right after your rest", systemImage: "timer")
                                    .font(.system(size: 10, weight: .semibold)).foregroundColor(volt)
                            }
                        }
                        NavigationLink {
                            WatchSetLogView(exerciseId: ex.id, setId: sid, setNumber: n,
                                            detection: detection,
                                            onLogged: { state.presentedDetection = nil })
                        } label: {
                            Text("Log It")
                                .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(Capsule().fill(volt))
                        }
                        .buttonStyle(.plain)
                    }

                    NavigationLink {
                        WatchPickSetView(detection: detection)
                    } label: {
                        Text(exercise == nil ? "Choose Set" : "Different Set")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        state.discardDetection(detection)
                    } label: {
                        Text("Not a Set").font(.system(size: 13)).foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// Every exercise, then its sets (unlogged first), to attach the detection elsewhere.
struct WatchPickSetView: View {
    @EnvironmentObject var state: WatchState
    let detection: DetectedSet

    var body: some View {
        List {
            ForEach(state.activeWorkout?.exercises ?? []) { ex in
                Section(ex.name) {
                    ForEach(Array(ex.sets.enumerated()), id: \.element.id) { i, set in
                        NavigationLink {
                            WatchSetLogView(exerciseId: ex.id, setId: set.id, setNumber: i + 1,
                                            detection: detection,
                                            onLogged: { state.presentedDetection = nil })
                        } label: {
                            HStack {
                                Text("Set \(i + 1)").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                if set.loggedReps != nil {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundColor(volt)
                                } else {
                                    Text("\(set.targetReps)×\(Int(set.targetWeight))")
                                        .font(.system(size: 12, design: .rounded)).foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Which set?")
    }
}
