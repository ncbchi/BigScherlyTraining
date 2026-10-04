import Foundation
import Combine

// MARK: - Watch motion records (phone)
// Every SetMotion the Watch sends lands here, keyed by workout + set, and is kept on disk
// (Application Support, file-protected) so Stats works offline, and is uploaded to the
// server (ServerSync) so the coach sees it and a new phone gets it back.

@MainActor
final class SetMotionStore: ObservableObject {
    static let shared = SetMotionStore()

    /// Keyed by "workoutId|setId".
    @Published private(set) var bySet: [String: SetMotion] = [:]

    private static func key(_ workoutId: String, _ setId: String) -> String { "\(workoutId)|\(setId)" }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("set-motion.json")
    }()

    private init() { load() }

    // MARK: Read

    func motion(workoutId: String, setId: String) -> SetMotion? { bySet[Self.key(workoutId, setId)] }

    func motions(forWorkout workoutId: String) -> [SetMotion] {
        bySet.values.filter { $0.workoutId == workoutId }.sorted { $0.start < $1.start }
    }

    func motions(forExercise exerciseName: String) -> [SetMotion] {
        bySet.values.filter { $0.exerciseName == exerciseName }.sorted { $0.start < $1.start }
    }

    var all: [SetMotion] { bySet.values.sorted { $0.start < $1.start } }

    // MARK: Write

    /// A set's motion arrived from the Watch. A newer recording for the same set replaces the old.
    func ingest(_ motion: SetMotion, sync: Bool = true) {
        bySet[Self.key(motion.workoutId, motion.setId)] = motion
        save()
        if sync { ServerSync.shared.mark(.motion(workoutId: motion.workoutId)) }
    }

    /// Wipe on logout so the next person on this phone never sees it.
    func reset() {
        bySet = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SetMotion].self, from: data) else { return }
        bySet = Dictionary(list.map { (Self.key($0.workoutId, $0.setId), $0) },
                           uniquingKeysWith: { a, b in a.end > b.end ? a : b })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(bySet.values)) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
