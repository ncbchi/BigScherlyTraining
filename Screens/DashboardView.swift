import SwiftUI
import Charts

// MARK: - Home
// The daily hub, top to bottom:
//   greeting → today's workout (hero, one tap to start) → this week →
//   newest PR from Stats → coach's latest message → today's doses →
//   up next → latest announcement.

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"
    @State private var openWorkout: Workout? = nil
    @State private var watchStarting = false

    private let cal = Calendar.training

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                greeting.staggeredAppear(0)
                hero.staggeredAppear(1)
                thisWeek.staggeredAppear(2)
                prCard.staggeredAppear(3)
                coachCard.staggeredAppear(4)
                dosesCard.staggeredAppear(5)
                upNext.staggeredAppear(6)
                announcement.staggeredAppear(7)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .fullScreenCover(item: $openWorkout) { w in WorkoutSessionView(workoutId: w.id) }
        // A widget's Start button: open that workout straight away.
        .onAppear { openFromWidget(store.openSessionId) }
        .onChange(of: store.openSessionId) { _, id in openFromWidget(id) }
        .sheet(item: $store.prToCelebrate) { pr in PRCelebrationView(pr: pr) }
    }

    // MARK: Greeting

    private var greeting: some View {
        let h = cal.component(.hour, from: Date())
        let part = h < 12 ? "GOOD MORNING" : (h < 17 ? "GOOD AFTERNOON" : "GOOD EVENING")
        let first = store.client.name.split(separator: " ").first.map(String.init) ?? store.client.name
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: part)
            Text(first).font(BrandFont.display(48)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
        }
    }

    // MARK: Hero — today's (or the next) workout

    private var heroWorkout: Workout? {
        store.workouts.first { !$0.completed && cal.isDateInToday($0.date) } ?? store.upcomingWorkouts.first
    }
    private var doneToday: Workout? {
        store.workouts.first { $0.completed && cal.isDateInToday($0.date) }
    }

    @ViewBuilder
    private var hero: some View {
        if let w = heroWorkout {
            let isToday = cal.isDateInToday(w.date)
            let sets = w.exercises.reduce(0) { $0 + $1.sets.count }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isToday ? "TODAY" : "NEXT · \(w.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())")
                        .font(BrandFont.body(11, .heavy)).tracking(1.5).foregroundColor(Brand.onVolt)
                    Spacer()
                    if WatchBridge.shared.isWatchReady {
                        DSChip(text: "Watch ready", icon: "applewatch", color: Brand.black)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.title).font(BrandFont.display(34)).foregroundColor(Brand.onVolt)
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text("\(w.exercises.count) exercise\(w.exercises.count == 1 ? "" : "s") · \(sets) sets · about \(estimatedMinutes(w)) min")
                        .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.onVolt.opacity(0.7))
                }
                VStack(spacing: 8) {
                    ForEach(w.exercises) { ex in
                        HStack(spacing: 8) {
                            Text(ex.name).font(BrandFont.body(13, .bold)).foregroundColor(Brand.onVolt).lineLimit(1)
                            Spacer()
                            Text("\(ex.sets.count) × \(ex.sets.first?.targetReps ?? 0)")
                                .font(BrandFont.body(12, .bold)).foregroundColor(Brand.onVolt.opacity(0.65))
                            Text(ex.sets.first.map { $0.targetWeight > 0 ? StatsUnits.weightText($0.targetWeight) : "BW" } ?? "")
                                .font(BrandFont.body(12, .heavy)).foregroundColor(Brand.onVolt)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.onVolt.opacity(0.08)))

                HStack(spacing: 10) {
                    Button {
                        store.activeWorkoutId = w.id
                        openWorkout = w
                    } label: {
                        Label(isToday ? (inProgress(w) ? "Resume workout" : "Start workout") : "Preview workout",
                              systemImage: isToday ? "play.fill" : "eye.fill")
                    }
                    .buttonStyle(DSButtonStyle(kind: .dark))

                    if isToday && WatchBridge.shared.isWatchReady {
                        Button {
                            store.activeWorkoutId = w.id
                            watchStarting = true
                            WatchBridge.shared.startWatchWorkout { _ in watchStarting = false }
                        } label: {
                            Image(systemName: watchStarting ? "hourglass" : "applewatch")
                                .font(.system(size: 19, weight: .semibold)).foregroundColor(Brand.onVolt)
                                .frame(width: 50, height: 50)
                                .overlay(Circle().stroke(Brand.black, lineWidth: 2))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Start the session on Apple Watch")
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22).fill(Brand.volt))
        } else if let d = doneToday {
            VStack(alignment: .leading, spacing: 10) {
                DSChip(text: "Done today", icon: "checkmark", color: Brand.volt, filled: true)
                Text(d.title).font(BrandFont.display(30)).foregroundColor(Brand.text)
                Text("Nice work. See how it stacks up in Stats.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                Button("Open Stats") { store.select(.history) }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
            .card(padding: 18)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing scheduled").font(BrandFont.display(28)).foregroundColor(Brand.text)
                Text("Your coach hasn't posted your next workout yet.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
            }
            .card(padding: 18)
        }
    }

    private func inProgress(_ w: Workout) -> Bool {
        w.exercises.contains { $0.sets.contains { $0.loggedReps != nil } }
    }

    /// Rough session length: ~45 s per set plus prescribed rest, rounded to 5 min.
    private func estimatedMinutes(_ w: Workout) -> Int {
        let secs = w.exercises.reduce(0) { $0 + $1.sets.count * (45 + $1.restSeconds) }
        return max(10, Int((Double(secs) / 60 / 5).rounded()) * 5)
    }

    // MARK: This week

    private var thisWeek: some View {
        let week = cal.dateInterval(of: .weekOfYear, for: Date())
        let start = week?.start ?? Date()
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let inWeek = store.workouts.filter { week?.contains($0.date) ?? false }
        let done = inWeek.filter { $0.completed }
        let sets = done.flatMap { $0.exercises.flatMap { $0.sets } }.filter { $0.loggedReps != nil }.count
        let total = max(inWeek.count, done.count)
        let remaining = total - done.count
        let todayOpen = inWeek.contains { !$0.completed && cal.isDateInToday($0.date) }
        let end = days.last ?? start

        let line: String = {
            if total == 0 { return "Nothing scheduled this week." }
            var t = "\(done.count) of \(total) session\(total == 1 ? "" : "s") done · \(sets) sets"
            if remaining == 0 { t += " · week complete." }
            else if todayOpen { t += remaining == 1 ? " · one to go today." : " · \(remaining) to go, one today." }
            else { t += " · \(remaining) to go." }
            return t
        }()

        return VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "THIS WEEK",
                            subtitle: "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
            Text(line).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    let ws = inWeek.filter { cal.isDate($0.date, inSameDayAs: day) }
                    let trained = ws.contains { $0.completed }
                    let planned = !trained && !ws.isEmpty
                    let isToday = cal.isDateInToday(day)
                    VStack(spacing: 6) {
                        Text(Calendar.trainingWeekdayLetters[i])
                            .font(BrandFont.body(10, .bold)).foregroundColor(isToday ? Brand.text : Brand.mute)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(trained ? Brand.volt : Brand.text.opacity(planned ? 0 : 0.06))
                            if planned {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            }
                            if trained {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundColor(Brand.onVolt)
                            } else {
                                Text("\(cal.component(.day, from: day))")
                                    .font(BrandFont.body(13, isToday ? .heavy : .semibold))
                                    .foregroundColor(planned ? Brand.voltText : Brand.mute)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isToday ? Brand.text : .clear, lineWidth: 1.5).padding(-3))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 6)
            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))

            HStack(spacing: 10) {
                DSStatTile(value: "\(done.count)/\(total)", label: "SESSIONS")
                DSStatTile(value: "\(sets)", label: "SETS")
                DSStatTile(value: "\(store.weekStreak)", label: "WEEK STREAK")
            }
        }
    }

    // MARK: Newest PR (from Stats)

    @ViewBuilder
    private var prCard: some View {
        if let pr = store.personalRecords.max(by: { $0.date < $1.date }) {
            let history = Array(store.history(for: pr.exercise).suffix(12))     // lb, oldest first
            let points: [(Date, Double)] = history.map { ($0.date, StatsUnits.weight($0.estimatedOneRepMax)) }
            let gainLb = (history.last?.estimatedOneRepMax ?? 0) - (history.first?.estimatedOneRepMax ?? 0)
            let weeks = max(1, ((history.last?.date ?? Date()).timeIntervalSince(history.first?.date ?? Date())) / (7 * 86400))
            let since = history.first?.date.formatted(.dateTime.month(.wide)) ?? ""
            VStack(alignment: .leading, spacing: 12) {
                DSSectionHeader(title: "FROM YOUR STATS")
                Button { store.select(.history) } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "trophy.fill").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.onVolt)
                                .frame(width: 26, height: 26).background(Circle().fill(Brand.volt))
                            Text("NEWEST PR").font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(pr.reps) × \(StatsUnits.weightText(pr.weight, unit: false))")
                                .font(BrandFont.display(32)).foregroundColor(Brand.text)
                            Text("\(pr.exercise) · \(pr.date.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute).lineLimit(1)
                        }
                        Group {
                            if history.count > 1, gainLb > 0 {
                                Text("\(StatsUnits.weightText(pr.estimatedOneRepMax)) estimated 1RM — up \(StatsUnits.weightText(gainLb)) since \(since), about \(StatsUnits.weightText(gainLb / weeks)) a week.")
                            } else {
                                Text("\(StatsUnits.weightText(pr.estimatedOneRepMax)) estimated 1RM.")
                            }
                        }
                        .font(BrandFont.body(13)).foregroundColor(Brand.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                        if points.count > 1 {
                            MiniChart(lines: [MiniChart.Line(name: "\(pr.exercise) est. 1RM", color: Brand.volt, points: points)],
                                      unit: StatsUnits.weightLabel, height: 120, highlight: pr.date)
                        }
                    }
                    .card(padding: 16)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: Coach

    @ViewBuilder
    private var coachCard: some View {
        let unread = store.unreadMessages
        let thread = store.chats
            .filter { $0.messages.contains { $0.fromTrainer } }
            .sorted { ($0.unread > 0 ? 1 : 0, $0.lastActivity) > ($1.unread > 0 ? 1 : 0, $1.lastActivity) }
            .first
        if let t = thread, let m = t.messages.last(where: { $0.fromTrainer }) {
            VStack(alignment: .leading, spacing: 12) {
                DSSectionHeader(title: "FROM YOUR COACH")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("BS").font(BrandFont.display(18)).foregroundColor(Brand.onVolt)
                            .frame(width: 40, height: 40).background(Circle().fill(Brand.volt))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coach · \(t.topic)").font(BrandFont.body(13, .bold)).foregroundColor(Brand.text).lineLimit(1)
                            Text(m.timestamp.formatted(.relative(presentation: .named)).capitalized)
                                .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        }
                        Spacer()
                        if unread > 0 { DSChip(text: "\(unread) new", color: Brand.volt, filled: true) }
                    }
                    Text("“\(m.text)”").font(BrandFont.body(14, .medium)).foregroundColor(Brand.text)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { store.select(.chat) } label: { Label("Reply", systemImage: "bubble.left.fill") }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                        Button { store.select(.chat) } label: { Label("Record video", systemImage: "video.fill") }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
                .card(padding: 16)
            }
        }
    }

    // MARK: Today's doses

    private struct DoseItem: Identifiable {
        let supplement: Supplement
        let when: String
        let sortKey: Int
        let taken: Bool
        var id: String { supplement.id }
    }

    private var todaysDoses: [DoseItem] {
        let weekday = cal.component(.weekday, from: Date())
        let trainingToday = store.workouts.contains { cal.isDateInToday($0.date) }
        return store.supplements.filter { $0.isActive }.compactMap { s in
            let t = s.timing
            let when: String; let key: Int
            switch t.kind {
            case .daily:
                let first = (t.times ?? []).min()
                when = first?.display ?? "Today"; key = first?.minutes ?? 600
            case .fixedDays:
                guard (t.days ?? []).contains(where: { $0.rawValue == weekday }) else { return nil }
                let first = (t.times ?? []).min()
                when = first?.display ?? "Today"; key = first?.minutes ?? 600
            case .beforeWorkout:
                guard trainingToday else { return nil }
                when = "before workout"; key = 1000
            case .afterWorkout:
                guard trainingToday else { return nil }
                when = "after workout"; key = 1100
            case .withMeals:
                when = "with meals"; key = 700
            }
            let taken = store.supplementLogs.contains {
                $0.supplementId == s.id && $0.status == .taken && cal.isDateInToday($0.takenAt ?? $0.scheduledFor)
            }
            return DoseItem(supplement: s, when: when, sortKey: key, taken: taken)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    @ViewBuilder
    private var dosesCard: some View {
        let doses = todaysDoses
        if !doses.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DSSectionHeader(title: "TODAY'S DOSES", subtitle: "\(doses.filter { $0.taken }.count) of \(doses.count)")
                VStack(spacing: 12) {
                    ForEach(doses) { d in
                        HStack(spacing: 12) {
                            Button {
                                if !d.taken { withAnimation(.spring(response: 0.3)) { store.confirmSupplement(d.supplement) } }
                            } label: {
                                ZStack {
                                    Circle().fill(d.taken ? Brand.volt : Color.clear).frame(width: 28, height: 28)
                                    Circle().stroke(d.taken ? Brand.voltLine : Brand.line, lineWidth: 1.5).frame(width: 28, height: 28)
                                    if d.taken {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt)
                                    }
                                }
                                .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(d.taken ? "\(d.supplement.name) taken" : "Mark \(d.supplement.name) taken")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.supplement.name).font(BrandFont.body(14, .semibold))
                                    .foregroundColor(d.taken ? Brand.mute : Brand.text)
                                    .strikethrough(d.taken, color: Brand.mute)
                                Text("\(d.supplement.dose.display) · \(d.when)").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 6)
                .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
            }
        }
    }

    // MARK: Up next

    @ViewBuilder
    private var upNext: some View {
        let next = store.upcomingWorkouts.filter { $0.id != heroWorkout?.id }.prefix(3)
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DSSectionHeader(title: "UP NEXT")
                VStack(spacing: 8) {
                    ForEach(Array(next)) { w in
                        Button { openWorkout = w } label: {
                            DSListRow(title: w.title,
                                      subtitle: "\(w.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(w.exercises.count) exercise\(w.exercises.count == 1 ? "" : "s")",
                                      icon: "calendar")
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    // MARK: Announcement

    @ViewBuilder
    private var announcement: some View {
        if let a = store.liveAnnouncements.first {
            Button { store.select(.announcements) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "megaphone.fill").font(.system(size: 13)).foregroundColor(Brand.voltText)
                        Text("ANNOUNCEMENT · \(a.date.formatted(.dateTime.month(.abbreviated).day()).uppercased())")
                            .font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.mute)
                    }
                    Text(a.title).font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
                    Text(a.body).font(BrandFont.body(13)).foregroundColor(Brand.mute).lineSpacing(2)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func openFromWidget(_ id: String?) {
        guard let id, let w = store.workouts.first(where: { $0.id == id }) else { return }
        store.openSessionId = nil
        openWorkout = w
    }
}
