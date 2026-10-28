import SwiftUI
import Combine

// MARK: - Workouts tab, by week (Oct 23, 2026)
//
// Both sections — Completed (above, scroll up) and the plan (where the screen lands) — are grouped
// into Monday–Sunday weeks under month dividers. A week opens into its days; a day drops down its
// workouts. Swipe a planned workout left and Move · Skip · Mark done are revealed underneath on the
// right; a full swipe marks it done. Mark done with sets still unlogged asks how to finish it
// (default: just what was logged).
//
// Server 2.7.2: POST /workouts/{id}/finish {mode: logged|skip} and POST /workouts/{id}/reopen
// (Undo). Moves use the existing /workouts/{id}/move through MacroPlanStore + ServerSync.
// File lives in the synchronized BigScherlyTraining folder — no target step needed.

enum FinishMode: String { case logged, skip }

extension APIClient {
    func finishWorkout(id: String, mode: FinishMode) async throws {
        _ = try await request("/workouts/\(id)/finish", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue]))
    }
    func reopenWorkout(id: String) async throws {
        _ = try await request("/workouts/\(id)/reopen", method: "POST", body: Data("{}".utf8))
    }
}

// MARK: - Actions (local first, then the server; put back if the server says no)

@MainActor
final class WorkoutActions: ObservableObject {
    static let shared = WorkoutActions()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }
    @Published var toast: Toast?

    private var store: AppStore { AppStore.shared }
    private var toastTask: Task<Void, Never>?

    static var spring: Animation { .spring(response: 0.42, dampingFraction: 0.82) }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = Toast(text: text, undo: undo) }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
    }

    /// The workout was already marked finished on this phone (Finish anyway, the 2½-hour auto-end):
    /// tell the server, so it stays finished after the next reload.
    func syncDone(_ id: String) {
        guard store.isLive else { return }
        Task { try? await APIClient.shared.finishWorkout(id: id, mode: .logged) }
    }

    /// Done with the sets that were logged (the rest count as skipped).
    func markDone(_ id: String) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        let was = store.workouts[i]
        closeIfOpen(id)
        withAnimation(Self.spring) {
            store.workouts[i].completed = true
            store.workouts[i].skipped = nil
        }
        store.refreshAwards()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show("\(was.title) marked done", undo: { [weak self] in self?.reopen(id, restoring: was) })
        send(id, restoring: was) { try await APIClient.shared.finishWorkout(id: id, mode: .logged) }
    }

    /// Done, with every unlogged set filled in from the plan.
    func markDoneAsPlanned(_ id: String) {
        guard let wi = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        let was = store.workouts[wi]
        closeIfOpen(id)
        var filled: [(exerciseId: String, set: ExerciseSet)] = []
        withAnimation(Self.spring) {
            for ei in store.workouts[wi].exercises.indices {
                let ex = store.workouts[wi].exercises[ei]
                for si in ex.sets.indices where ex.sets[si].loggedReps == nil {
                    let s = ex.sets[si]
                    var n = s
                    n.loggedReps = max(0, s.targetReps)
                    n.loggedWeight = SetTarget.plannedWeight(s, in: ex)
                        ?? ex.sets.compactMap { $0.loggedWeight }.max()
                        ?? (s.targetWeight > 0 ? s.targetWeight : 0)
                    n.loggedAt = n.loggedAt ?? was.date
                    store.workouts[wi].exercises[ei].sets[si] = n
                    filled.append((ex.id, n))
                }
            }
            store.workouts[wi].completed = true
            store.workouts[wi].skipped = nil
        }
        store.refreshAwards()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show("\(was.title) marked done as planned")
        let toSend = filled
        send(id, restoring: was) {
            for f in toSend {
                try await APIClient.shared.logSet(workoutId: id, exerciseId: f.exerciseId, setId: f.set.id,
                                                  reps: f.set.loggedReps, weight: f.set.loggedWeight,
                                                  rpe: f.set.rpe, loggedAt: f.set.loggedAt)
            }
            try? await APIClient.shared.finishWorkout(id: id, mode: .logged)   // an older server completes it from the sets
        }
    }

    func skip(_ id: String) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }), !store.workouts[i].completed else { return }
        let was = store.workouts[i]
        closeIfOpen(id)
        withAnimation(Self.spring) { store.workouts[i].skipped = true }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        show("\(was.title) skipped", undo: { [weak self] in self?.reopen(id, restoring: was) })
        send(id, restoring: was) { try await APIClient.shared.finishWorkout(id: id, mode: .skip) }
    }

    func move(_ id: String, to day: Date) {
        guard let w = store.workouts.first(where: { $0.id == id }) else { return }
        withAnimation(Self.spring) { MacroPlanStore.shared.moveWorkout(id, to: day, store: store) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show("\(w.title) moved to \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
    }

    // MARK: A finished workout: Reopen · Reset · Copy (Oct 27, 2026)

    /// Reopen: back in progress with its sets, saved for later (paused) so you resume when you're ready.
    /// The time since its last set doesn't count. A skipped one just goes back on the plan.
    func reopenFinished(_ id: String) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        let was = store.workouts[i]
        let sets = was.exercises.flatMap { $0.sets }
        let hasLogged = sets.contains { $0.loggedReps != nil }
        withAnimation(Self.spring) {
            store.workouts[i].completed = false
            store.workouts[i].skipped = nil
        }
        if hasLogged {
            LiveSessionController.shared.markSavedForLater(id, pausedSince: sets.compactMap { $0.loggedAt }.max() ?? Date())
        }
        store.refreshPRs()
        store.refreshAwards(announce: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        show(hasLogged ? "\(was.title) reopened. Resume it from Home." : "\(was.title) is back on your plan.",
             undo: { [weak self] in self?.undoReopen(id, was: was) })
        guard store.isLive else { return }
        Task { @MainActor in
            do { try await APIClient.shared.reopenWorkout(id: id) } catch {
                self.putBack(id, was: was)
                self.show(self.oldServer(error) ? "Couldn't reopen: the server needs the 2.7.2 update."
                                                : "Couldn't reopen. Check your connection and try again.")
            }
        }
    }

    private func undoReopen(_ id: String, was: Workout) {
        dismissToast()
        putBack(id, was: was)
        guard store.isLive else { return }
        Task { try? await APIClient.shared.finishWorkout(id: id, mode: was.completed ? .logged : .skip) }
    }

    private func putBack(_ id: String, was: Workout) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Self.spring) {
            store.workouts[i].completed = was.completed
            store.workouts[i].skipped = was.skipped
        }
        LiveSessionController.shared.clearPause(id)
        store.refreshPRs()
        store.refreshAwards(announce: false)
    }

    /// Reset (after its confirm sheet): every logged set cleared, with its Watch data; back on the plan as
    /// new, on the same day. PRs and awards that came from it come off (on the coach's side too).
    func resetWorkout(_ id: String) {
        guard store.workouts.contains(where: { $0.id == id }) else { return }
        guard store.isLive else { applyReset(id); return }
        Task { @MainActor in
            // What would go: worked out first, so the server can drop the same awards.
            let gone = self.awardsLost(resetting: id)
            do {
                try await APIClient.shared.resetWorkout(id: id, removeAwards: gone)
                self.applyReset(id)
            } catch {
                self.show(self.oldServer(error) ? "Couldn't reset: the server needs the 2.7.4 update."
                                                : "Couldn't reset. Check your connection and try again.")
            }
        }
    }

    private func cleared(_ w: Workout) -> Workout {
        var c = w
        for ei in c.exercises.indices {
            for si in c.exercises[ei].sets.indices {
                c.exercises[ei].sets[si].loggedReps = nil
                c.exercises[ei].sets[si].loggedWeight = nil
                c.exercises[ei].sets[si].rpe = nil
                c.exercises[ei].sets[si].loggedAt = nil
            }
        }
        c.completed = false
        c.skipped = nil
        return c
    }

    /// The award kinds that would disappear if this workout were reset.
    private func awardsLost(resetting id: String) -> [String] {
        let after = store.workouts.map { $0.id == id ? cleared($0) : $0 }
        let prs = ProgressEngine.allPRs(workouts: after, trainerTagged: store.trainerTaggedLifts,
                                        baseline: store.isTrainer ? [:] : BaselineStore.shared.prior)
        let kept = Set(AwardEngine.evaluate(workouts: after, supplements: store.supplements,
                                            supplementLogs: store.supplementLogs, personalRecords: prs,
                                            checkIns: store.checkIns,
                                            wiredUpAt: WiredUp.earnedAt(store.client.id)).map { $0.kind.rawValue })
        return store.awards.map { $0.kind.rawValue }.filter { !kept.contains($0) }
    }

    private func applyReset(_ id: String) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        let title = store.workouts[i].title
        closeIfOpen(id)
        withAnimation(Self.spring) { store.workouts[i] = cleared(store.workouts[i]) }
        LiveSessionController.shared.clearPause(id)
        SetMotionStore.shared.forget(workoutId: id)
        store.refreshPRs()
        store.refreshAwards(announce: false)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        show("\(title) reset. It's back on your plan.")
    }

    /// Copy: a blank copy (same exercises, sets and targets, nothing logged) on another day, at the
    /// original's time of day. The original stays where it is.
    func copyWorkout(_ id: String, to day: Date) {
        guard let w = store.workouts.first(where: { $0.id == id }) else { return }
        let cal = Calendar.training
        let tod = cal.dateComponents([.hour, .minute], from: w.date)
        let when = cal.date(bySettingHour: tod.hour ?? 9, minute: tod.minute ?? 0, second: 0, of: day) ?? day
        let label = when.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard store.isLive else {
            var c = cleared(w)
            c.id = UUID().uuidString
            c.date = when
            for ei in c.exercises.indices {
                c.exercises[ei].id = UUID().uuidString
                c.exercises[ei].clientNotes = ""
                for si in c.exercises[ei].sets.indices { c.exercises[ei].sets[si].id = UUID().uuidString }
            }
            withAnimation(Self.spring) { store.workouts.append(c) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show("Copied \(w.title) to \(label)")
            return
        }
        Task { @MainActor in
            do {
                let newId = try await APIClient.shared.copyWorkout(id: id, date: when)
                let full = try await APIClient.shared.workout(newId)
                if !self.store.workouts.contains(where: { $0.id == newId }) {
                    withAnimation(Self.spring) { self.store.workouts.append(full.toModel()) }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.show("Copied \(w.title) to \(label)")
            } catch {
                self.show(self.oldServer(error) ? "Couldn't copy: the server needs the 2.7.4 update."
                                                : "Couldn't copy. Check your connection and try again.")
            }
        }
    }

    private func oldServer(_ error: Error) -> Bool {
        (error as? APIClient.HTTPStatusError).map { $0.status == 404 || $0.status == 405 } ?? false
    }

    /// Undo: back on the plan as it was.
    func reopen(_ id: String, restoring was: Workout) {
        guard let i = store.workouts.firstIndex(where: { $0.id == id }) else { return }
        dismissToast()
        withAnimation(Self.spring) {
            store.workouts[i].completed = was.completed
            store.workouts[i].skipped = was.skipped
        }
        store.refreshAwards(announce: false)
        guard store.isLive else { return }
        Task { try? await APIClient.shared.reopenWorkout(id: id) }
    }

    /// The finished workout was the one open in the live session: close it there too.
    private func closeIfOpen(_ id: String) {
        if LiveSessionController.shared.workoutId == id { LiveSessionController.shared.end() }
        if store.sessionWorkoutId == id { store.closeSession() }
        if store.activeWorkoutId == id { store.activeWorkoutId = nil }
    }

    private func send(_ id: String, restoring was: Workout, _ op: @escaping () async throws -> Void) {
        guard store.isLive else { return }                      // demo: this phone only
        Task { @MainActor in
            do { try await op() } catch {
                if let i = self.store.workouts.firstIndex(where: { $0.id == id }) {
                    withAnimation(Self.spring) {
                        self.store.workouts[i].completed = was.completed
                        self.store.workouts[i].skipped = was.skipped
                    }
                }
                let old = (error as? APIClient.HTTPStatusError).map { $0.status == 404 || $0.status == 405 } ?? false
                self.show(old ? "Couldn't save: the server needs the 2.7.2 update."
                              : "Couldn't save. Check your connection and try again.")
            }
        }
    }
}

// MARK: - Grouping

struct TrainingDayGroup: Identifiable {
    let day: Date
    var workouts: [Workout]
    var id: Date { day }
}

struct TrainingWeekGroup: Identifiable {
    let start: Date
    var days: [TrainingDayGroup]
    var id: Date { start }
    var workouts: [Workout] { days.flatMap { $0.workouts } }
}

enum WorkoutWeeks {
    static let cal = Calendar.training

    /// Weeks oldest first; days oldest first; a day's workouts by time, then in the plan's order.
    static func group(_ list: [Workout], order: [String: Int]) -> [TrainingWeekGroup] {
        let byDay = Dictionary(grouping: list) { cal.startOfDay(for: $0.date) }
        var weeks: [Date: [TrainingDayGroup]] = [:]
        for (day, ws) in byDay {
            let sorted = ws.sorted { a, b in
                a.date != b.date ? a.date < b.date : (order[a.id] ?? 0) < (order[b.id] ?? 0)
            }
            weeks[cal.trainingWeekStart(day), default: []].append(TrainingDayGroup(day: day, workouts: sorted))
        }
        return weeks.keys.sorted().map { k in TrainingWeekGroup(start: k, days: weeks[k]!.sorted { $0.day < $1.day }) }
    }

    static func title(_ start: Date) -> String {
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        let a = start.formatted(.dateTime.month(.abbreviated).day())
        let b = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(a) – \(b)"
    }

    static func monthLabel(_ start: Date) -> String {
        start.formatted(.dateTime.month(.wide).year()).uppercased()
    }

    static func isThisWeek(_ start: Date) -> Bool { cal.isSameTrainingWeek(start, Date()) }
}

// MARK: - Week card

struct WorkoutWeekCard<DayContent: View>: View {
    let week: TrainingWeekGroup
    let allInWeek: [Workout]                // every workout that week (done ones too) — for the counts and dots
    let open: Bool
    let badge: String?
    let subtitle: String
    let toggle: () -> Void
    @ViewBuilder let days: () -> DayContent

    private var thisWeek: Bool { WorkoutWeeks.isThisWeek(week.start) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if thisWeek || badge != nil {
                            HStack(spacing: 8) {
                                if thisWeek {
                                    Text("THIS WEEK").font(BrandFont.body(10, .heavy)).tracking(1.4)
                                        .foregroundColor(Brand.onVolt)
                                        .padding(.horizontal, 8).frame(height: 20)
                                        .background(Capsule().fill(Brand.volt))
                                }
                                if let badge {
                                    Text(badge).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.voltText)
                                        .padding(.horizontal, 9).frame(height: 22)
                                        .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1.5))
                                }
                            }
                        }
                        Text(WorkoutWeeks.title(week.start)).font(BrandFont.display(27)).foregroundColor(Brand.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(subtitle).font(BrandFont.body(12.5)).foregroundColor(Brand.mute).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    WeekDots(start: week.start, workouts: allInWeek)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .heavy)).foregroundColor(Brand.mute)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 0) {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    days()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(Brand.card))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(thisWeek ? Brand.voltLine : Brand.line, lineWidth: thisWeek ? 1.5 : 1))
        .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
    }
}

/// M T W T F S S, a dot under each training day: filled = all done, half = some, ring = none yet.
private struct WeekDots: View {
    let start: Date
    let workouts: [Workout]

    var body: some View {
        let cal = WorkoutWeeks.cal
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: start) ?? start
                let ws = workouts.filter { cal.isDate($0.date, inSameDayAs: day) }
                let done = ws.filter { $0.completed }.count
                VStack(spacing: 4) {
                    Text(Calendar.trainingWeekdayLetters[i]).font(.system(size: 8.5, weight: .heavy)).foregroundColor(Brand.mute)
                    ZStack {
                        if ws.isEmpty {
                            Color.clear
                        } else if done == ws.count {
                            Circle().fill(Brand.volt)
                        } else if done > 0 {
                            Circle().stroke(Brand.voltLine, lineWidth: 1.6)
                            Circle().trim(from: 0.25, to: 0.75).fill(Brand.volt).rotationEffect(.degrees(0))
                        } else {
                            Circle().stroke(Brand.voltLine, lineWidth: 1.6)
                        }
                    }
                    .frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Day row (drops down its workouts)

struct WorkoutDayRow<Rows: View>: View {
    let day: TrainingDayGroup
    let allThatDay: [Workout]
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        let cal = WorkoutWeeks.cal
        let isToday = cal.isDateInToday(day.day)
        let done = allThatDay.filter { $0.completed }.count
        let allDone = done == allThatDay.count && !allThatDay.isEmpty
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    VStack(spacing: 1) {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(BrandFont.body(10, .heavy)).tracking(1)
                        Text("\(cal.component(.day, from: day.day))").font(BrandFont.display(25))
                    }
                    .foregroundColor(isToday ? Brand.onVolt : Brand.text)
                    .frame(width: 50, height: 54)
                    .background(RoundedRectangle(cornerRadius: 13).fill(isToday ? Brand.volt : Brand.text.opacity(0.06)))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(day.workouts.map(\.title).joined(separator: " · "))
                            .font(BrandFont.body(14.5, .bold)).foregroundColor(Brand.text)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            if allDone {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                            }
                            Text(status(done: done, total: allThatDay.count, isToday: isToday))
                        }
                        .font(BrandFont.body(12, .bold))
                        .foregroundColor(allDone ? Brand.voltText : Brand.mute)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.mute)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 0) {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    rows()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func status(done: Int, total: Int, isToday: Bool) -> String {
        let cal = WorkoutWeeks.cal
        if total == 0 { return "" }
        if done == total { return "\(done) of \(total) done" }
        if done > 0 { return "\(done) of \(total) done" }
        if isToday { return "Today · \(total) workout\(total == 1 ? "" : "s")" }
        if cal.isDateInTomorrow(day.day) { return "Tomorrow · \(total) workout\(total == 1 ? "" : "s")" }
        if day.day < cal.startOfDay(for: Date()) { return "Not done" }
        return "\(total) workout\(total == 1 ? "" : "s")"
    }
}

// MARK: - A workout inside a day

struct PlannedWorkoutRow: View {
    let workout: Workout
    @ObservedObject private var live = LiveSessionController.shared

    var body: some View {
        let sets = workout.exercises.reduce(0) { $0 + $1.sets.count }
        let logged = workout.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        let paused = live.pauses[workout.id] != nil && logged > 0       // saved for later (Oct 27, 2026)
        HStack(spacing: 12) {
            StatusRing(logged: logged, total: sets)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title).font(BrandFont.display(21)).foregroundColor(Brand.text).lineLimit(1)
                Text(paused ? "Paused · \(logged) of \(sets) sets"
                     : workout.exerciseSummary.isEmpty ? "\(sets) sets"
                     : "\(workout.exerciseSummary) · \(sets) sets")
                    .font(BrandFont.body(12, paused ? .bold : .regular)).foregroundColor(paused ? Brand.voltText : Brand.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.text.opacity(0.03))
        .background(Brand.card)
    }
}

struct DoneWorkoutRow: View {
    let workout: Workout
    let prs: Int

    var body: some View {
        let sets = workout.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        let volume = workout.exercises.flatMap { $0.sets }.compactMap { s -> Double? in
            guard let r = s.loggedReps, let w = s.loggedWeight else { return nil }
            return Double(r) * w
        }.reduce(0, +)
        let skipped = workout.skipped == true && !workout.completed
        HStack(spacing: 12) {
            ZStack {
                if skipped {
                    Circle().stroke(Brand.mute.opacity(0.6), lineWidth: 1.6)
                    Image(systemName: "forward.fill").font(.system(size: 9, weight: .heavy)).foregroundColor(Brand.mute)
                } else {
                    Circle().fill(Brand.volt)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(Brand.onVolt)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title).font(BrandFont.body(14, .bold)).foregroundColor(skipped ? Brand.mute : Brand.text).lineLimit(1)
                Text(skipped ? "Skipped" : "\(sets) sets · \(StatsUnits.weightText(volume))")
                    .font(BrandFont.body(11.5)).foregroundColor(Brand.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            if prs > 0 { DSChip(text: prs == 1 ? "PR" : "\(prs) PRs", icon: "trophy.fill") }
            if !skipped {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.mute)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.text.opacity(0.03))
        .background(Brand.card)                        // opaque: it slides over Reopen · Reset · Copy
        .contentShape(Rectangle())
    }
}

/// Empty ring, a partly-filled ring with "1/3", or (all logged) a filled check.
private struct StatusRing: View {
    let logged: Int
    let total: Int
    var body: some View {
        ZStack {
            Circle().stroke(Brand.text.opacity(0.14), lineWidth: 2.5)
            if logged > 0, total > 0 {
                Circle().trim(from: 0, to: CGFloat(logged) / CGFloat(total))
                    .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(logged)/\(total)").font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundColor(Brand.text)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: 26, height: 26)
    }
}

// MARK: - Swipe left: Move · Skip · Mark done, revealed underneath on the right

struct SwipeAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let fill: Color
    let ink: Color
    var stroke: Color = .clear
    let run: () -> Void
}

struct SwipeRevealRow<Content: View>: View {
    let id: String
    @Binding var openId: String?
    let actions: [SwipeAction]               // left to right; the last is the full-swipe action
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var drag: CGFloat = 0
    @State private var passedFull = false
    // Round, icon-only buttons (Nick, Oct 23: board 7's circles, no text).
    private var size: CGFloat { 44 }
    private var gap: CGFloat { 10 }
    private var revealed: CGFloat { CGFloat(actions.count) * size + CGFloat(max(0, actions.count - 1)) * gap + 26 }
    private var base: CGFloat { openId == id ? -revealed : 0 }
    private var offset: CGFloat { min(0, base + drag) }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Underneath: the actions as round, icon-only buttons, uncovered as the card slides
            // left. Past the buttons, the last one (Done) grows: let go = done.
            Rectangle().fill(Brand.text.opacity(0.03)).background(Brand.card)
                .opacity(offset < -1 ? 1 : 0)
            HStack(spacing: gap) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                    let isLast = i == actions.count - 1
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(WorkoutActions.spring) { openId = nil }
                        a.run()
                    } label: {
                        Image(systemName: a.icon).font(.system(size: 16, weight: .bold))
                            .foregroundColor(a.ink)
                            .frame(width: size, height: size)
                            .background(Circle().fill(a.fill))
                            .overlay(Circle().stroke(a.stroke, lineWidth: 1.5))
                            .scaleEffect(isLast && passedFull ? 1.18 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: passedFull)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.title)
                }
            }
            .padding(.trailing, 14)
            .opacity(offset < -1 ? 1 : 0)

            // Gestures before the offset, so the card's touch area slides with it and the
            // buttons it uncovers get their taps (Oct 23: the card was swallowing them).
            content()
                .shadow(color: offset < -1 ? Brand.shadow : .clear, radius: 8, x: 4, y: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    if openId == id { withAnimation(WorkoutActions.spring) { openId = nil } }
                    else if openId != nil { withAnimation(WorkoutActions.spring) { openId = nil } }
                    else { onTap() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                            if openId != id && openId != nil { withAnimation(WorkoutActions.spring) { openId = nil } }
                            var t = v.translation.width
                            let total = base + t
                            if total < -(revealed + 40) {           // rubber band past the buttons
                                let extra = -(revealed + 40) - total
                                t += extra * 0.45
                            }
                            drag = t
                            let full = base + t < -(revealed + 70)
                            if full != passedFull {
                                passedFull = full
                                UIImpactFeedbackGenerator(style: full ? .medium : .light).impactOccurred()
                            }
                        }
                        .onEnded { v in
                            let end = base + drag
                            let fling = v.predictedEndTranslation.width - v.translation.width
                            if passedFull, let last = actions.last {
                                withAnimation(WorkoutActions.spring) { drag = 0; openId = nil }
                                passedFull = false
                                last.run()
                                return
                            }
                            withAnimation(WorkoutActions.spring) {
                                if end + fling * 0.3 < -revealed / 2 { openId = id } else if openId == id { openId = nil }
                                drag = 0
                            }
                            passedFull = false
                        }
                )
                .offset(x: offset)
        }
        .clipped()
    }
}

// MARK: - Mark done: some sets weren't logged

struct MarkDoneSheet: View {
    let workout: Workout
    let done: (_ asPlanned: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var asPlanned = false                // Nick, Oct 23: "Just what I logged" by default

    var body: some View {
        let all = workout.exercises.flatMap { $0.sets }
        let logged = all.filter { $0.loggedReps != nil }.count
        let missing = all.count - logged
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mark \(workout.title) done?").font(BrandFont.display(30)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(logged) of \(all.count) sets logged")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
            }
            option(selected: !asPlanned, title: "Just what I logged",
                   detail: logged == 0
                    ? "Marked done with no sets logged."
                    : "The \(logged) logged set\(logged == 1 ? " stays" : "s stay") as logged. The other \(missing) count\(missing == 1 ? "s" : "") as skipped.") {
                asPlanned = false
            }
            option(selected: asPlanned, title: "All of it, as planned",
                   detail: "The \(missing) missing set\(missing == 1 ? " is" : "s are") filled in as written.") {
                asPlanned = true
            }
            HStack(spacing: 10) {
                Button {
                    dismiss()
                    done(asPlanned)
                } label: { Label("Mark done", systemImage: "checkmark") }
                .buttonStyle(DSButtonStyle(kind: .primary))
                Button("Cancel") { dismiss() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.bg.ignoresSafeArea())
    }

    private func option(selected: Bool, title: String, detail: String, pick: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { pick() } }) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().stroke(selected ? Brand.voltLine : Brand.mute.opacity(0.5), lineWidth: 2)
                    if selected { Circle().fill(Brand.voltLine).padding(5) }
                }
                .frame(width: 20, height: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                    Text(detail).font(BrandFont.body(12.5)).foregroundColor(Brand.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Brand.voltLine : Brand.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Move to another day (within a week of its planned date, not into the past)

struct MoveWorkoutSheet: View {
    let workout: Workout
    let move: (Date) -> Void
    @ObservedObject private var store = AppStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pick: Date?

    var body: some View {
        let cal = WorkoutWeeks.cal
        let original = cal.startOfDay(for: MacroPlanStore.shared.originalDate(of: workout))
        let current = cal.startOfDay(for: workout.date)
        let first = max(cal.startOfDay(for: Date()), cal.date(byAdding: .day, value: -7, to: original) ?? original)
        let last = cal.date(byAdding: .day, value: 7, to: original) ?? original
        let gridStart = cal.trainingWeekStart(first)
        let gridEnd = cal.date(byAdding: .day, value: 6, to: cal.trainingWeekStart(last)) ?? last
        let count = (cal.dateComponents([.day], from: gridStart, to: gridEnd).day ?? 13) + 1
        let days = (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(workout.title)").font(BrandFont.display(30)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Any day within a week of \(original.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), from today on.")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
            }
            HStack(spacing: 0) {
                ForEach(Calendar.trainingWeekdayLetters.indices, id: \.self) { i in
                    Text(Calendar.trainingWeekdayLetters[i]).font(BrandFont.body(10, .heavy)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(days, id: \.self) { d in
                    let ok = d >= first && d <= last && d != current
                    let chosen = pick.map { cal.isDate($0, inSameDayAs: d) } ?? false
                    let busy = store.workouts.contains { $0.id != workout.id && cal.isDate($0.date, inSameDayAs: d) }
                    Button { pick = d; UISelectionFeedbackGenerator().selectionChanged() } label: {
                        VStack(spacing: 3) {
                            Text("\(cal.component(.day, from: d))").font(BrandFont.display(20))
                            Circle().fill(busy ? (chosen ? Brand.onVolt : Brand.mute) : .clear).frame(width: 4, height: 4)
                        }
                        .foregroundColor(chosen ? Brand.onVolt : (ok ? Brand.text : Brand.mute.opacity(0.45)))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(chosen ? Brand.volt : Brand.text.opacity(ok ? 0.06 : 0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(d == current ? Brand.voltLine : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                }
            }
            HStack(spacing: 10) {
                Button {
                    guard let p = pick else { return }
                    dismiss()
                    move(p)
                } label: {
                    Label(pick.map { "Move to \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" } ?? "Pick a day",
                          systemImage: "calendar")
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(pick == nil)
                .opacity(pick == nil ? 0.5 : 1)
                Button("Cancel") { dismiss() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
            }
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.bg.ignoresSafeArea())
    }
}

// MARK: - The note after Mark done / Skip / Move, with Undo

struct WorkoutActionToast: View {
    @ObservedObject private var actions = WorkoutActions.shared
    var body: some View {
        if let t = actions.toast {
            HStack(spacing: 12) {
                Text(t.text).font(BrandFont.body(13.5, .semibold)).foregroundColor(Brand.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let undo = t.undo {
                    Button("Undo") { undo() }.font(BrandFont.body(14, .heavy)).foregroundColor(Brand.voltText)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}
