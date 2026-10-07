import SwiftUI
import Charts

// MARK: - Home
// The daily hub, top to bottom:
//   greeting → today's workout (hero, one tap to start) → this week (pick a day) →
//   today's doses → coach's latest message → newest PR from Stats.
//   (A new announcement pulls up from the bottom — see NewAnnouncementSheet.)

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_units") private var units = "lb"
    @State private var watchStarting = false
    @State private var selectedDay = Calendar.training.startOfDay(for: Date())
    @State private var renderDay = Calendar.training.startOfDay(for: Date())
    @State private var dayCardOpen = false
    @State private var showMonth = false
    @State private var showActivity = false
    @State private var openDoneGroups: Set<String> = []

    private let cal = Calendar.training

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                greeting.staggeredAppear(0)
                hero.staggeredAppear(1)
                thisWeek.staggeredAppear(2)
                dosesCard.staggeredAppear(3)
                coachCard.staggeredAppear(4)
                prCard.staggeredAppear(5)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        // A widget's Start button: open that workout straight away.
        .onAppear { openFromWidget(store.openSessionId) }
        .onChange(of: store.openSessionId) { _, id in openFromWidget(id) }
        .sheet(item: Binding(get: { (store.sessionWorkoutId == nil || store.sessionMinimized) ? store.prToCelebrate : nil },
                             set: { store.prToCelebrate = $0 })) { pr in PRCelebrationView(pr: pr) }
        .sheet(isPresented: $showMonth) {
            HomeCalendarTray(selected: selectedDay,
                             pick: { d in selectDay(d); showMonth = false },
                             close: { showMonth = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showActivity) { ActivityLogSheet(day: renderDay) }
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
                        store.openSession(w.id)
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

    // MARK: This week — pick a day

    /// The workout to show for a day: the finished one if there is one, else the planned one.
    private func workout(on day: Date) -> Workout? {
        let ws = store.workouts.filter { cal.isDate($0.date, inSameDayAs: day) }
        return ws.first { $0.completed } ?? ws.first
    }

    private func selectDay(_ d: Date) {
        let day = cal.startOfDay(for: d)
        let isToday = cal.isDateInToday(day)
        // renderDay keeps drawing the old day while the card rolls shut, so it
        // doesn't blank out mid-animation.
        if !isToday { renderDay = day }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) {
            selectedDay = day
            dayCardOpen = !isToday
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var thisWeek: some View {
        let days = cal.trainingWeek(selectedDay)
        let start = days.first ?? selectedDay
        let end = days.last ?? selectedDay
        let inWeek = store.workouts.filter { w in days.contains { cal.isDate($0, inSameDayAs: w.date) } }
        let done = inWeek.filter { $0.completed }
        let sets = done.flatMap { $0.exercises.flatMap { $0.sets } }.filter { $0.loggedReps != nil }.count
        let total = max(inWeek.count, done.count)
        let remaining = total - done.count
        let isThisWeek = cal.isSameTrainingWeek(Date(), selectedDay)
        let todayOpen = isThisWeek && inWeek.contains { !$0.completed && cal.isDateInToday($0.date) }

        let line: String = {
            if total == 0 { return "Nothing scheduled this week." }
            var t = "\(done.count) of \(total) session\(total == 1 ? "" : "s") done · \(sets) sets"
            if remaining == 0 { t += " · week complete." }
            else if todayOpen { t += remaining == 1 ? " · one to go today." : " · \(remaining) to go, one today." }
            else { t += " · \(remaining) to go." }
            return t
        }()

        return VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: isThisWeek ? "THIS WEEK" : "WEEK OF",
                            subtitle: "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
            Text(line).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    dayTile(i, day)
                }
            }

            Button { showMonth = true } label: {
                HStack(spacing: 6) {
                    Capsule().fill(Brand.mute.opacity(0.6)).frame(width: 28, height: 4)
                    Text(selectedDay.formatted(.dateTime.month(.wide).year())).font(BrandFont.body(11, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Brand.mute)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open month calendar")
            // Pull-down lives on the handle alone. Anywhere else on the card
            // belongs to the scroll view, so Home scrolls without snagging.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { v in
                        if v.translation.height > 24, abs(v.translation.height) > abs(v.translation.width) * 2 {
                            showMonth = true
                        }
                    }
            )

            dayReveal
        }
        .card(padding: 16)
    }

    private func dayTile(_ i: Int, _ day: Date) -> some View {
        let w = workout(on: day)
        let trained = w?.completed ?? false
        let planned = w != nil && !trained
        let on = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        return Button { selectDay(day) } label: {
            VStack(spacing: 3) {
                Text(Calendar.trainingWeekdayLetters[i]).font(BrandFont.body(10, .heavy))
                Text("\(cal.component(.day, from: day))").font(BrandFont.display(21))
                    .underline(isToday)
                ZStack {
                    if trained {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                            .foregroundColor(on ? Brand.onVolt : Brand.volt)
                    } else if planned {
                        Circle().fill(on ? Brand.onVolt : Brand.volt).frame(width: 6, height: 6)
                    } else {
                        Circle().stroke(on ? Brand.onVolt : Brand.mute, lineWidth: 1).frame(width: 6, height: 6).opacity(0.7)
                    }
                }
                .frame(height: 11)
            }
            .foregroundColor(on ? Brand.onVolt : (w == nil ? Brand.mute : Brand.text))
            .frame(maxWidth: .infinity).frame(height: 68)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Brand.black))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Brand.voltLine : Brand.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))\(trained ? ", workout done" : (planned ? ", workout planned" : ", rest day"))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Selected day — opens out of the bottom of the week card
    // The content is inserted inside a clipped container: the container grows from
    // nothing while the content slides down into it, so its lower edge tracks the
    // card's growing bottom edge and it unrolls out of the card. Nothing shows when
    // today is selected — the hero is today's.

    private var dayReveal: some View {
        VStack(spacing: 0) {
            if dayCardOpen {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    selectedDayCard
                }
                .padding(.top, 2)
                .transition(.move(edge: .top))
            }
        }
        // The clip has 2pt of slack on the sides and bottom, then the layout is pulled
        // back in: the Preview button's stroke sits on its edge and was being shaved.
        .padding(.horizontal, 2).padding(.bottom, 2)
        .clipped()
        .padding(.horizontal, -2).padding(.bottom, -2)
    }

    @ViewBuilder
    private var selectedDayCard: some View {
        if let w = workout(on: renderDay) {
            if w.completed { doneDayCard(w) } else { plannedDayCard(w) }
        } else {
            restDayCard
        }
    }

    private var dayEyebrow: String {
        "\(renderDay.formatted(.dateTime.weekday(.wide))) · \(renderDay.formatted(.dateTime.month(.abbreviated).day()))".uppercased()
    }

    private func dayHeader(_ chip: DSChip) -> some View {
        HStack(spacing: 8) {
            Text(dayEyebrow).font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
            Spacer(minLength: 0)
            chip
        }
    }

    private func relativeChip() -> DSChip {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: renderDay)).day ?? 0
        if n < 0 { return DSChip(text: "Missed", color: Brand.mute) }
        return DSChip(text: n == 1 ? "Tomorrow" : "In \(n) days")
    }

    private func exerciseRows(_ w: Workout, logged: Bool) -> some View {
        let shown = Array(w.exercises.prefix(4))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, ex in
                let top = logged
                    ? (ex.sets.compactMap { $0.loggedWeight }.max() ?? ex.sets.first?.targetWeight ?? 0)
                    : (ex.sets.first?.targetWeight ?? 0)
                HStack(spacing: 8) {
                    Text(ex.name).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text).lineLimit(1)
                    Spacer()
                    Text("\(ex.sets.count) × \(ex.sets.first?.targetReps ?? 0)")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    Text(top > 0 ? StatsUnits.weightText(top) : "BW")
                        .font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.vertical, 9)
                if i < shown.count - 1 { Rectangle().fill(Brand.line).frame(height: 1) }
            }
            if w.exercises.count > shown.count {
                Text("+ \(w.exercises.count - shown.count) more")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }

    private func plannedDayCard(_ w: Workout) -> some View {
        let sets = w.exercises.reduce(0) { $0 + $1.sets.count }
        return VStack(alignment: .leading, spacing: 10) {
            dayHeader(relativeChip())
            Text(w.title).font(BrandFont.display(30)).foregroundColor(Brand.text)
                .lineLimit(2).minimumScaleFactor(0.7)
            Text("\(w.exercises.count) exercise\(w.exercises.count == 1 ? "" : "s") · \(sets) sets · about \(estimatedMinutes(w)) min")
                .font(BrandFont.body(13)).foregroundColor(Brand.mute)
            exerciseRows(w, logged: false)
            Button {
                store.openSession(w.id)
            } label: { Label("Preview workout", systemImage: "eye.fill") }
                .buttonStyle(DSButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionMinutes(_ w: Workout) -> Int {
        if store.isDemoMode || APIConfig.useMock { return DemoMotion.session(workoutId: w.id).minutes }
        return store.workoutVitals[w.id]?.durationMinutes ?? 60
    }

    private func doneDayCard(_ w: Workout) -> some View {
        let all = w.exercises.flatMap { $0.sets }
        let loggedSets = all.filter { $0.loggedReps != nil }.count
        let volume = all.reduce(0) { $0 + $1.volume }
        let pr = store.personalRecords.filter { cal.isDate($0.date, inSameDayAs: w.date) }
            .max(by: { $0.estimatedOneRepMax < $1.estimatedOneRepMax })
        return VStack(alignment: .leading, spacing: 10) {
            dayHeader(DSChip(text: "Done", icon: "checkmark", color: Brand.volt, filled: true))
            Text(w.title).font(BrandFont.display(30)).foregroundColor(Brand.text)
                .lineLimit(2).minimumScaleFactor(0.7)
            HStack(spacing: 8) {
                DSStatTile(value: "\(sessionMinutes(w))", label: "MIN")
                DSStatTile(value: "\(loggedSets)/\(all.count)", label: "SETS")
                DSStatTile(value: StatsUnits.weightText(volume, unit: false), label: "\(StatsUnits.weightLabel.uppercased()) VOLUME")
            }
            if let pr {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill").font(.system(size: 16)).foregroundColor(Brand.volt)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New PR · \(pr.exercise)").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                        Text("\(pr.reps) × \(StatsUnits.weightText(pr.weight))").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.volt.opacity(0.35), lineWidth: 1))
            }
            exerciseRows(w, logged: true)
            Button { store.select(.history) } label: { Text("Open in Stats") }
                .buttonStyle(DSButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restDayCard: some View {
        let kcal = store.macroDays.first { cal.isDate($0.date, inSameDayAs: renderDay) }?.calorieGoal
        let next = store.upcomingWorkouts.first { $0.date > renderDay && !cal.isDate($0.date, inSameDayAs: renderDay) }
        return VStack(alignment: .leading, spacing: 10) {
            dayHeader(DSChip(text: "Rest day", icon: "moon.fill", color: Brand.mute))
            HStack(spacing: 14) {
                Image(systemName: "moon.fill").font(.system(size: 20)).foregroundColor(Brand.volt)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Brand.text.opacity(0.06)))
                    .overlay(Circle().stroke(Brand.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rest day").font(BrandFont.display(30)).foregroundColor(Brand.text)
                    Text(kcal.map { "Nothing scheduled. Macros switch to your rest-day targets: \($0.formatted()) kcal." } ?? "Nothing scheduled.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let next {
                Button {
                    selectDay(next.date)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NEXT UP · \(next.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())")
                                .font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                            Text(next.title).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.mute)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.text.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            Button { showActivity = true } label: { Label("Log an activity", systemImage: "plus") }
                .buttonStyle(DSButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Today's doses — stacked by time of day, tap anywhere on a row to take it

    private struct DoseItem: Identifiable {
        let supplement: Supplement
        let when: String
        let sortKey: Int
        let taken: Bool
        let isClock: Bool
        var id: String { supplement.id }
    }

    private struct DoseGroup: Identifiable {
        let title: String
        let doses: [DoseItem]
        var id: String { title }
        var takenCount: Int { doses.filter { $0.taken }.count }
        var complete: Bool { takenCount == doses.count }
    }

    private var todaysDoses: [DoseItem] {
        let weekday = cal.component(.weekday, from: Date())
        let trainingToday = store.workouts.contains { cal.isDateInToday($0.date) }
        return store.supplements.filter { $0.isActive }.compactMap { s in
            let t = s.timing
            let when: String; let key: Int; var clock = false
            switch t.kind {
            case .daily:
                let first = (t.times ?? []).min()
                when = first?.display ?? "Today"; key = first?.minutes ?? 600; clock = first != nil
            case .fixedDays:
                guard (t.days ?? []).contains(where: { $0.rawValue == weekday }) else { return nil }
                let first = (t.times ?? []).min()
                when = first?.display ?? "Today"; key = first?.minutes ?? 600; clock = first != nil
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
            return DoseItem(supplement: s, when: when, sortKey: key, taken: taken, isClock: clock)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    private func doseGroups(_ doses: [DoseItem]) -> [DoseGroup] {
        let parts: [(String, (DoseItem) -> Bool)] = [
            ("MORNING", { $0.sortKey < 720 }),
            ("AFTERNOON", { $0.sortKey >= 720 && $0.sortKey < 1020 }),
            ("EVENING", { $0.sortKey >= 1020 }),
        ]
        return parts.compactMap { title, test in
            let g = doses.filter(test)
            return g.isEmpty ? nil : DoseGroup(title: title, doses: g)
        }
    }

    private func doseSubtitle(left: Int, next: DoseItem?) -> String {
        guard let next else { return "All done for today" }
        let tail = next.isClock ? "next at \(next.when)" : "next \(next.when)"
        return "\(left) to go · \(tail)"
    }

    private func take(_ d: DoseItem) {
        guard !d.taken else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3)) { store.confirmSupplement(d.supplement) }
    }

    @ViewBuilder
    private var dosesCard: some View {
        let doses = todaysDoses
        if !doses.isEmpty {
            let groups = doseGroups(doses)
            let taken = doses.filter { $0.taken }.count
            let next = doses.first { !$0.taken }
            let activeId = groups.first { !$0.complete }?.id
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Brand.text.opacity(0.10), lineWidth: 6)
                        Circle().trim(from: 0, to: CGFloat(taken) / CGFloat(doses.count))
                            .stroke(Brand.volt, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(taken)/\(doses.count)").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TODAY'S DOSES").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
                        Text(doseSubtitle(left: doses.count - taken, next: next))
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    Spacer(minLength: 0)
                }
                ForEach(groups) { g in
                    doseGroupView(g, active: g.id == activeId, nextId: next?.id)
                }
            }
            .card(padding: 16)
        }
    }

    @ViewBuilder
    private func doseGroupView(_ g: DoseGroup, active: Bool, nextId: String?) -> some View {
        if g.complete && !openDoneGroups.contains(g.id) {
            // Finished stack: one tappable summary row.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { _ = openDoneGroups.insert(g.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Brand.onVolt)
                        .frame(width: 24, height: 24).background(Circle().fill(Brand.volt))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.title.capitalized).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                        Text(g.doses.map { $0.supplement.name }.joined(separator: " · "))
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Brand.mute)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.volt.opacity(0.32), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(g.title.capitalized) doses, \(g.takenCount) of \(g.doses.count) taken")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(g.title).font(BrandFont.body(11, .heavy)).tracking(1.8)
                        .foregroundColor(active ? Brand.voltText : Brand.mute)
                    Spacer(minLength: 0)
                    Text("\(g.takenCount) of \(g.doses.count)").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                ForEach(Array(g.doses.enumerated()), id: \.element.id) { i, d in
                    doseRow(d, isNext: d.id == nextId)
                    if i < g.doses.count - 1 { Rectangle().fill(Brand.line).frame(height: 1) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(active ? Brand.volt.opacity(0.04) : Brand.text.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(active ? Brand.voltLine : Brand.line, lineWidth: active ? 1.5 : 1))
            .opacity(active || g.complete ? 1 : 0.9)
        }
    }

    /// The whole row is the button — not just the circle.
    private func doseRow(_ d: DoseItem, isNext: Bool) -> some View {
        Button { take(d) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.supplement.name).font(BrandFont.body(15, .heavy))
                        .foregroundColor(d.taken ? Brand.mute : Brand.text)
                        .strikethrough(d.taken, color: Brand.mute)
                    Text("\(d.supplement.dose.display) · \(d.when)").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().fill(d.taken ? Brand.volt : Color.clear).frame(width: 28, height: 28)
                    Circle().stroke(d.taken ? Brand.voltLine : (isNext ? Brand.voltLine : Brand.mute), lineWidth: 2).frame(width: 28, height: 28)
                    if d.taken {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundColor(Brand.onVolt)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.taken ? "\(d.supplement.name) taken" : "Mark \(d.supplement.name) taken")
    }

    private func openFromWidget(_ id: String?) {
        guard let id, store.workouts.contains(where: { $0.id == id }) else { return }
        store.openSessionId = nil
        store.openSession(id)
    }
}

// MARK: - Month calendar (opens from the week card's handle)

struct HomeCalendarTray: View {
    @EnvironmentObject var store: AppStore
    let selected: Date
    let pick: (Date) -> Void
    let close: () -> Void

    @State private var month: Date = Date()
    private let cal = Calendar.training

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                DSIconButton(systemName: "chevron.left", accessibilityLabel: "Previous month", size: 36) {
                    month = cal.date(byAdding: .month, value: -1, to: month) ?? month
                }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(BrandFont.display(26)).foregroundColor(Brand.text)
                Spacer()
                DSIconButton(systemName: "chevron.right", accessibilityLabel: "Next month", size: 36) {
                    month = cal.date(byAdding: .month, value: 1, to: month) ?? month
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(Calendar.trainingWeekdayLetters.enumerated()), id: \.offset) { _, l in
                    Text(l).font(BrandFont.body(10, .heavy)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(monthGrid, id: \.self) { d in cell(d) }
            }
            HStack(spacing: 12) {
                Button { pick(Date()) } label: { DSChip(text: "Today", icon: "calendar") }.buttonStyle(.plain)
                HStack(spacing: 4) { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(Brand.volt); Text("Done") }
                HStack(spacing: 4) { Circle().stroke(Brand.volt, lineWidth: 1.5).frame(width: 6, height: 6); Text("Planned") }
                Spacer()
                Button("Close") { close() }.font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Capsule().fill(Brand.text.opacity(0.08)))
            }
            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Brand.bg.ignoresSafeArea())
        .onAppear { month = selected }
    }

    private func cell(_ d: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
        let ws = store.workouts.filter { cal.isDate($0.date, inSameDayAs: d) }
        let done = ws.contains { $0.completed }
        let planned = !done && !ws.isEmpty
        let on = cal.isDate(d, inSameDayAs: selected)
        let today = cal.isDateInToday(d)
        return Button { pick(d) } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: d))").font(BrandFont.display(19))
                ZStack {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(on ? Brand.onVolt : Brand.volt)
                    } else if planned {
                        Circle().stroke(on ? Brand.onVolt : Brand.volt, lineWidth: 1.5).frame(width: 6, height: 6)
                    }
                }
                .frame(height: 10)
            }
            .foregroundColor(on ? Brand.onVolt : (inMonth ? Brand.text : Brand.mute.opacity(0.45)))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Brand.volt : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(today && !on ? Brand.volt : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted))\(done ? ", workout done" : (planned ? ", workout planned" : ""))")
    }

    private var monthGrid: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let start = cal.trainingWeekStart(interval.start)
        let lastDay = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let end = cal.date(byAdding: .day, value: 7, to: cal.trainingWeekStart(lastDay)) ?? interval.end
        let count = cal.dateComponents([.day], from: start, to: end).day ?? 35
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}
