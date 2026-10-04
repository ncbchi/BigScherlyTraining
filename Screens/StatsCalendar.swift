import SwiftUI

// MARK: - Training calendar widget
// A real month/week calendar. Training days are solid volt, planned days dashed,
// missed days marked. Tiny icons for PRs and awards earned that day; a glowing
// border + check for workouts shared to social media. Swipe or use the arrows to
// move between months/weeks; tap a day to see that day's training below.

struct StatsCalendarCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var shareLog = ShareLog.shared
    @Binding var selectedDay: Date

    enum Mode: String, CaseIterable { case month = "Month", week = "Week" }
    @State private var mode: Mode = .month
    @State private var anchor: Date = Date()          // any date inside the visible month/week
    @State private var forward = true

    private let cal = Calendar.training

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TRAINING CALENDAR").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                Spacer()
                HStack(spacing: 0) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { mode = m; anchor = selectedDay } } label: {
                            Text(m.rawValue).font(BrandFont.body(11, .bold))
                                .foregroundColor(mode == m ? Brand.onVolt : Brand.mute)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(mode == m ? Brand.volt : Color.clear).clipShape(Capsule())
                        }
                    }
                }
                .background(Capsule().fill(Brand.text.opacity(0.06)))
            }

            HStack {
                Button { step(-1) } label: { navArrow("chevron.left") }
                Spacer()
                Text(title).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                Spacer()
                Button { step(1) } label: { navArrow("chevron.right") }
            }
            .overlay(alignment: .trailing) {
                if !isCurrentPeriod {
                    Button("Today") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            forward = anchor < Date(); anchor = Date(); selectedDay = cal.startOfDay(for: Date())
                        }
                    }
                    .font(BrandFont.body(11, .bold)).foregroundColor(Brand.voltText)
                    .padding(.trailing, 40)
                }
            }

            HStack(spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, d in
                    Text(d).font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
                }
            }

            grid
                .id(periodKey)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                .padding(.vertical, 3)   // room for the selection ring and share glow
                .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                    if g.translation.width < -50 { step(1) } else if g.translation.width > 50 { step(-1) }
                })

            legend
        }
        .card(padding: 16)
    }

    // MARK: Grid

    private var grid: some View {
        let days = visibleDays
        let rows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r], id: \.self) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let info = dayInfo(day)
        let inPeriod = mode == .week || cal.isDate(day, equalTo: anchor, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let shared = !info.shared.isEmpty
        let height: CGFloat = mode == .week ? 64 : 44

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedDay = cal.startOfDay(for: day) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(info.trained ? Brand.volt : Brand.text.opacity(inPeriod ? 0.05 : 0.02))
                if info.planned && !info.trained {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Brand.voltLine.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                if shared {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Brand.text, lineWidth: 1.5)
                        .shadow(color: Brand.volt, radius: 6)
                        .shadow(color: Brand.volt.opacity(0.8), radius: 3)
                }
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).stroke(Brand.text, lineWidth: 2.5).padding(-2)
                }

                VStack(spacing: 2) {
                    HStack(alignment: .top) {
                        Text("\(cal.component(.day, from: day))")
                            .font(BrandFont.body(12, isToday ? .heavy : .semibold))
                            .foregroundColor(info.trained ? Brand.onVolt : (inPeriod ? Brand.text : Brand.mute.opacity(0.5)))
                            .underline(isToday)
                        Spacer(minLength: 0)
                        if shared {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Brand.onVolt, Brand.text)
                        }
                    }
                    Spacer(minLength: 0)
                    if mode == .week, info.trained, info.sets > 0 {
                        Text("\(info.sets) sets").font(BrandFont.body(8, .bold)).foregroundColor(Brand.onVolt.opacity(0.7))
                    }
                    HStack(spacing: 2) {
                        if info.prs > 0 {
                            Image(systemName: "trophy.fill").font(.system(size: 8))
                        }
                        if let a = info.awardIcon {
                            Image(systemName: a).font(.system(size: 8))
                        }
                        if info.activity {
                            Image(systemName: "figure.run").font(.system(size: 8))
                        }
                        if info.missed {
                            Circle().fill(Color.orange.opacity(0.8)).frame(width: 4, height: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(info.trained ? Brand.onVolt : Brand.voltText)
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(AnyView(RoundedRectangle(cornerRadius: 3).fill(Brand.volt).frame(width: 10, height: 10)), "Trained")
            legendItem(AnyView(RoundedRectangle(cornerRadius: 3)
                .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 10, height: 10)), "Planned")
            legendItem(AnyView(Image(systemName: "trophy.fill").font(.system(size: 9)).foregroundColor(Brand.voltText)), "PR")
            legendItem(AnyView(Image(systemName: "rosette").font(.system(size: 9)).foregroundColor(Brand.voltText)), "Award")
            legendItem(AnyView(Image(systemName: "figure.run").font(.system(size: 9)).foregroundColor(Brand.voltText)), "Extra")
            legendItem(AnyView(Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundColor(Brand.text)), "Shared")
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func legendItem(_ icon: AnyView, _ label: String) -> some View {
        HStack(spacing: 4) { icon; Text(label).font(BrandFont.body(10)).foregroundColor(Brand.mute) }
    }

    private func navArrow(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .bold)).foregroundColor(Brand.text)
            .frame(width: 30, height: 30).background(Circle().fill(Brand.text.opacity(0.08)))
    }

    // MARK: Period math

    private var visibleDays: [Date] {
        switch mode {
        case .week:
            guard let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [] }
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        case .month:
            guard let month = cal.dateInterval(of: .month, for: anchor),
                  let gridStart = cal.dateInterval(of: .weekOfYear, for: month.start)?.start else { return [] }
            let lastDay = cal.date(byAdding: .day, value: -1, to: month.end) ?? month.end
            let gridEnd = cal.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? month.end
            let count = cal.dateComponents([.day], from: gridStart, to: gridEnd).day ?? 35
            return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        }
    }

    private var title: String {
        switch mode {
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            let days = visibleDays
            guard let f = days.first, let l = days.last else { return "" }
            return "\(f.formatted(.dateTime.month(.abbreviated).day())) – \(l.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    private var periodKey: String { "\(mode.rawValue)-\(title)" }

    private var isCurrentPeriod: Bool {
        cal.isDate(anchor, equalTo: Date(), toGranularity: mode == .month ? .month : .weekOfYear)
    }

    private var weekdaySymbols: [String] { Calendar.trainingWeekdayLetters }

    private func step(_ dir: Int) {
        forward = dir > 0
        withAnimation(.easeInOut(duration: 0.25)) {
            anchor = cal.date(byAdding: mode == .month ? .month : .weekOfYear, value: dir, to: anchor) ?? anchor
        }
    }

    // MARK: Day info

    private struct DayInfo {
        var trained = false, planned = false, missed = false, activity = false
        var sets = 0, prs = 0
        var awardIcon: String? = nil
        var shared: [String] = []
    }

    private func dayInfo(_ day: Date) -> DayInfo {
        var info = DayInfo()
        let workouts = store.workouts.filter { cal.isDate($0.date, inSameDayAs: day) }
        let done = workouts.filter { $0.completed }
        info.activity = !MacroPlanStore.shared.activities(on: day).isEmpty
        info.trained = !done.isEmpty || info.activity
        info.sets = done.flatMap { $0.exercises.flatMap { $0.sets } }.filter { $0.loggedReps != nil }.count
        let open = workouts.filter { !$0.completed }
        let past = day < cal.startOfDay(for: Date())
        info.planned = !open.isEmpty && !past
        info.missed = !open.isEmpty && past && done.isEmpty
        info.prs = store.personalRecords.filter { cal.isDate($0.date, inSameDayAs: day) }.count
        info.awardIcon = store.awards.first { cal.isDate($0.earnedAt, inSameDayAs: day) }?.icon
        info.shared = StatsCalendarData.sharedPlatforms(on: day, store: store, log: shareLog)
        return info
    }
}

// MARK: - Shared lookups (calendar + day summary)

@MainActor
enum StatsCalendarData {
    /// Social platforms the day's workout went to. Demo mode shows two sample shares.
    static func sharedPlatforms(on day: Date, store: AppStore, log: ShareLog) -> [String] {
        var p = log.platforms(on: day)
        if store.isDemoMode || APIConfig.useMock {
            let cal = Calendar.training
            let done = store.workouts.filter { $0.completed }.sorted { $0.date > $1.date }
            if let latest = done.first, cal.isDate(latest.date, inSameDayAs: day), !p.contains("Instagram") { p.append("Instagram") }
            if done.count > 4, cal.isDate(done[4].date, inSameDayAs: day), !p.contains("Facebook") { p.append("Facebook") }
        }
        return p
    }
}

// MARK: - The selected day, under the calendar

struct DaySummaryCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var shareLog = ShareLog.shared
    let day: Date
    let open: (String) -> Void          // open full session by workout id

    private let cal = Calendar.training

    var body: some View {
        let engine = StatsEngine(store: store)
        let done = store.workouts.filter { $0.completed && cal.isDate($0.date, inSameDayAs: day) }
        let planned = store.workouts.filter { !$0.completed && cal.isDate($0.date, inSameDayAs: day) }
        let prs = store.personalRecords.filter { cal.isDate($0.date, inSameDayAs: day) }
        let awards = store.awards.filter { cal.isDate($0.earnedAt, inSameDayAs: day) }
        let shared = StatsCalendarData.sharedPlatforms(on: day, store: store, log: shareLog)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                Spacer()
                if cal.isDateInToday(day) {
                    Text("TODAY").font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Brand.volt))
                }
            }

            if done.isEmpty {
                if let p = planned.first {
                    let past = day < cal.startOfDay(for: Date())
                    HStack(spacing: 8) {
                        Image(systemName: past ? "xmark.circle" : "calendar.badge.clock")
                            .foregroundColor(past ? .orange : Brand.voltText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(past ? "Missed · \(p.title)" : "Planned · \(p.title)")
                                .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                            Text(p.exerciseSummary).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(2)
                        }
                    }
                } else {
                    Text("Rest day.").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                }
            }

            ForEach(done) { w in
                if let s = engine.sessions(for: .session(w.id), window: .all).first {
                    sessionSummary(s)
                }
            }

            ForEach(MacroPlanStore.shared.activities(on: day)) { a in
                HStack(spacing: 10) {
                    Image(systemName: "figure.run").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.voltText)
                        .frame(width: 30, height: 30).background(Circle().fill(Brand.text.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(a.type) · \(a.minutes) min").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                        Text([a.reportedKcal.map { "\($0) kcal" }, a.avgHR.map { "avg \($0) bpm" },
                              a.countsAsTraining ? "counted as a training day" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                    Spacer()
                }
            }

            if !prs.isEmpty || !awards.isEmpty || !shared.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(prs) { pr in chip("trophy.fill", "\(pr.exercise) PR · \(pr.reps)×\(StatsUnits.weightText(pr.weight, unit: false))", Brand.volt) }
                        ForEach(awards) { a in chip(a.icon, a.title, Brand.volt) }
                        ForEach(shared, id: \.self) { p in chip("checkmark.circle.fill", "Shared to \(p)", Brand.text) }
                    }
                }
            }

            ForEach(done) { w in
                Button { open(w.id) } label: {
                    HStack {
                        Text(done.count > 1 ? "Open \(w.title)" : "Open full session")
                            .font(BrandFont.body(13, .bold)).foregroundColor(Brand.onVolt)
                        Spacer()
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.onVolt)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Capsule().fill(Brand.volt))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card(padding: 16)
    }

    private func sessionSummary(_ s: StatsSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.title).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.voltText)
            HStack(spacing: 8) {
                stat(StatsUnits.weightText(s.volume), "VOLUME")
                stat("\(s.setCount)", "SETS")
                stat(s.durationMin.map { "\($0)m" } ?? "—", "TIME")
                stat(s.hr.map { "\($0.avg)" } ?? "—", "AVG BPM")
            }
            VStack(spacing: 6) {
                ForEach(s.exercises.sorted { $0.bestE1RM > $1.bestE1RM }.prefix(3)) { ex in
                    let top = ex.sets.max { $0.e1RM < $1.e1RM }
                    HStack {
                        if let l = ex.sbd { Circle().fill(l.color).frame(width: 6, height: 6) }
                        Text(ex.name).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text).lineLimit(1)
                        Spacer()
                        if let t = top {
                            Text("\(t.reps)×\(StatsUnits.weightText(t.weight))").font(BrandFont.body(12, .bold)).foregroundColor(Brand.text)
                        }
                        if let m = ex.motions.first {
                            Text(String(format: "%.2f m/s", m.meanVelocity)).font(BrandFont.body(10)).foregroundColor(Brand.mute)
                        }
                    }
                }
                if s.exercises.count > 3 {
                    Text("+\(s.exercises.count - 3) more").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !s.notes.isEmpty {
                Label("\(s.notes.count) note\(s.notes.count == 1 ? "" : "s") from your data", systemImage: "text.bubble.fill")
                    .font(BrandFont.body(11, .semibold)).foregroundColor(Brand.voltText)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(BrandFont.body(8, .bold)).tracking(0.8).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(BrandFont.body(11, .semibold))
        }
        .foregroundColor(Brand.readable(color))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - One full session (opened from the calendar)

struct StatsSessionView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var shareLog = ShareLog.shared
    let workoutId: String

    var body: some View {
        let engine = StatsEngine(store: store)
        let session = engine.sessions(for: .session(workoutId), window: .all).first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = session {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(BrandFont.display(34)).foregroundColor(Brand.text)
                            .lineLimit(2).minimumScaleFactor(0.6)
                        Text(s.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    let shared = StatsCalendarData.sharedPlatforms(on: s.date, store: store, log: shareLog)
                    if !shared.isEmpty {
                        Label("Shared to \(shared.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                            .font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        tile(StatsUnits.weightText(s.volume), "VOLUME")
                        tile("\(s.setCount)", "SETS")
                        tile(s.avgRPE.map { String(format: "%.1f", $0) } ?? "—", "AVG RPE")
                        tile(s.durationMin.map { "\($0) min" } ?? "—", "DURATION")
                        tile(s.hr.map { "\($0.avg) / \($0.peak)" } ?? "—", "AVG / PEAK BPM")
                        tile(s.calories.map { "\($0)" } ?? "—", "ACTIVE CAL")
                    }
                    SessionDetailBody(session: s, isWorkout: true)
                        .padding(14)
                        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                } else {
                    Text("Nothing logged for this workout.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { _ = await store.loadWorkoutVitals(workoutId: workoutId) }
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BrandFont.body(15, .bold)).foregroundColor(Brand.voltText).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(BrandFont.body(8, .bold)).tracking(0.8).foregroundColor(Brand.mute).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }
}
