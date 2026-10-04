import Foundation
import Combine
import WidgetKit

// MARK: - Keeps the Home & Lock Screen widgets current
// Builds the widget snapshot from your data and saves it to the shared App Group whenever
// something changes (a set logged, macros adjusted, a supplement ticked…), then asks iOS to
// redraw the widgets. Also adds supplements ticked on a widget to your log, and opens the
// right screen when a widget is tapped. Target membership: BigScherlyTraining only.

@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()
    private weak var store: AppStore?
    private var bag = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?

    private init() {}

    func attach(_ store: AppStore) {
        self.store = store
        let changes: [AnyPublisher<Void, Never>] = [
            store.$workouts.map { _ in () }.eraseToAnyPublisher(),
            store.$macroDays.map { _ in () }.eraseToAnyPublisher(),
            store.$supplements.map { _ in () }.eraseToAnyPublisher(),
            store.$supplementLogs.map { _ in () }.eraseToAnyPublisher(),
            store.$checkIns.map { _ in () }.eraseToAnyPublisher(),
            store.$chats.map { _ in () }.eraseToAnyPublisher(),
            store.$awards.map { _ in () }.eraseToAnyPublisher(),
            store.$isLoggedIn.map { _ in () }.eraseToAnyPublisher(),
            store.$isTrainer.map { _ in () }.eraseToAnyPublisher(),
            MacroPlanStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.refreshSoon() }
            .store(in: &bag)
        refreshSoon()
    }

    /// Coalesced: many changes in a row → one save and one redraw.
    func refreshSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard let store else { return }
        WidgetShared.save(build(store))
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Supplements ticked on a widget → your log

    func mergeWidgetTicks() {
        guard let store else { return }
        let ticks = WidgetShared.pendingTicks()
        guard !ticks.isEmpty else { return }
        let cal = Calendar.current
        for (id, at) in ticks where cal.isDateInToday(at) {
            guard let s = store.supplements.first(where: { $0.id == id }) else { continue }
            let already = store.supplementLogs.contains {
                $0.supplementId == id && $0.status == .taken && cal.isDateInToday($0.takenAt ?? .distantPast)
            }
            if !already { store.confirmSupplement(s) }
        }
        WidgetShared.clearPendingTicks()
        refreshSoon()
    }

    // MARK: Taps on a widget → the right screen
    //   bigscherly://session?id=…   start / resume that workout
    //   bigscherly://open?tab=macros|workouts|stats|supplements|checkins|chat|awards

    func handle(_ url: URL) {
        guard let store, url.scheme == "bigscherly", store.isLoggedIn, !store.isTrainer else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in q.first { $0.name == name }?.value }
        switch url.host {
        case "session":
            if let id = value("id"), store.workouts.contains(where: { $0.id == id }) {
                store.activeTab = .dashboard
                store.openSessionId = id
            }
        case "open":
            let tabs: [String: AppTab] = ["home": .dashboard, "workouts": .workouts, "stats": .history, "macros": .macros,
                                          "supplements": .supplements, "checkins": .checkins, "chat": .chat, "awards": .awards]
            if let t = value("tab").flatMap({ tabs[$0] }) { store.activeTab = t }
        default:
            break
        }
    }

    // MARK: Building the snapshot

    private func build(_ store: AppStore) -> WidgetSnapshot {
        guard store.isLoggedIn else { return .loggedOut }
        if store.isTrainer { return WidgetSnapshot(generatedAt: Date(), state: .coach) }

        let cal = WidgetSnapshot.calendar
        var snap = WidgetSnapshot(generatedAt: Date(), state: .client, unit: StatsUnits.weightLabel)

        // Two weeks of days from this Monday: the workout and that day's macro targets.
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        for i in 0..<14 {
            guard let date = cal.date(byAdding: .day, value: i, to: monday) else { continue }
            let w = store.workouts.first { cal.isDate($0.date, inSameDayAs: date) }
            let workout = w.map { w in
                WidgetSnapshot.Workout(id: w.id, title: w.title,
                                       exercises: w.exercises.map {
                                           WidgetSnapshot.Ex(name: $0.name, done: $0.sets.filter { $0.loggedReps != nil }.count,
                                                             total: $0.sets.count)
                                       },
                                       completed: w.completed)
            }
            var macros: WidgetSnapshot.Macros? = nil
            if let md = store.macroDays.first(where: { cal.isDate($0.date, inSameDayAs: date) }) {
                let t = MacroPlanStore.shared.targets(for: md, plan: store.macroDays, workouts: store.workouts)
                macros = .init(kcal: t.calories, protein: t.protein, carbs: t.carbs, fat: t.fat,
                               training: t.isTraining, note: t.reason)
            }
            snap.days.append(.init(date: date, workout: workout, macros: macros))
        }

        // Lifts: best estimated 1RM per session, most recently trained first.
        let sessions = StatsEngine(store: store).allSessions(window: .all)
        var byName: [String: [(Date, ExerciseStat)]] = [:]
        for s in sessions { for e in s.exercises { byName[e.name, default: []].append((s.date, e)) } }
        let eightWeeksAgo = cal.date(byAdding: .day, value: -56, to: Date()) ?? Date()
        snap.lifts = byName.compactMap { name, list -> WidgetSnapshot.Lift? in
            let sorted = list.sorted { $0.0 < $1.0 }.filter { $0.1.bestE1RM > 0 }
            guard let last = sorted.last else { return nil }
            let values = sorted.map { StatsUnits.weight($0.1.bestE1RM) }
            let baseline = sorted.first { $0.0 >= eightWeeksAgo }.map { StatsUnits.weight($0.1.bestE1RM) } ?? values.first ?? 0
            let reps = last.1.reps
            let speed = reps.isEmpty ? nil : reps.map { $0.meanVelocity }.reduce(0, +) / Double(reps.count)
            return .init(name: name, e1rm: values.last ?? 0, change: (values.last ?? 0) - baseline,
                         points: Array(values.suffix(12)), sessions: sorted.count, last: last.0, speed: speed)
        }
        .sorted { $0.last != $1.last ? $0.last > $1.last : $0.sessions > $1.sessions }
        .prefix(12).map { $0 }

        // This month: sessions, sets, volume, PRs (a session that beat that lift's previous best).
        let monthStart = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        var best: [String: Double] = [:]
        for s in sessions {
            let inMonth = s.date >= monthStart
            if inMonth {
                snap.month.sessions += 1
                snap.month.sets += s.setCount
                snap.month.volume += Int(StatsUnits.weight(s.volume).rounded())
            }
            for e in s.exercises {
                let prior = best[e.name] ?? 0
                if inMonth && prior > 0 && e.bestE1RM > prior { snap.month.prs += 1 }
                best[e.name] = max(prior, e.bestE1RM)
            }
        }

        // Supplements, with today's ticks.
        snap.supplements = store.supplements
            .filter { s in (s.cycleEnd ?? .distantFuture) >= Date() && (s.cycleStart ?? .distantPast) <= Date() }
            .map { s in
                WidgetSnapshot.Supp(id: s.id, name: s.name, timing: s.timing.summary,
                                    taken: store.supplementLogs.contains {
                                        $0.supplementId == s.id && $0.status == .taken
                                            && Calendar.current.isDateInToday($0.takenAt ?? .distantPast)
                                    })
            }

        snap.lastCheckIn = store.checkIns.filter { $0.status != .draft }.map { $0.date }.max()
        if let a = store.awards.max(by: { $0.earnedAt < $1.earnedAt }) {
            snap.latest = a.title
            snap.latestDate = a.earnedAt
        }
        snap.unreadCoach = store.unreadMessages
        return snap
    }
}
