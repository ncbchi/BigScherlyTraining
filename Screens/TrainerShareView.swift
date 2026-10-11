import SwiftUI

// Coach ▸ Share: the crew card. It's the client Share screen itself (ShareView) — the
// same Studio styles, formats, photo, stickers and share dock, in the app's theme —
// fed the roster's week instead of one lifter's session. Totals only: never a client's
// name or numbers, and never the coach's own PRs or awards.
struct TrainerShareView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ShareView(crew: crew)
            .refreshable { store.loadRoster() }
            .onAppear { if store.roster.isEmpty { store.loadRoster() } }
    }

    private var crew: CrewShare {
        let cal = Calendar.training
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return CrewShare(
            workouts: store.roster.map { $0.workoutsThisWeek }.reduce(0, +),
            athletes: store.roster.count,
            trainedThisWeek: store.roster.filter { $0.workoutsThisWeek > 0 }.count,
            awards: store.recentAwards.filter { cal.isSameTrainingWeek($0.earnedAt, Date()) }.count,
            weekStart: weekStart)
    }
}
