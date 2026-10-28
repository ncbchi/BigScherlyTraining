import SwiftUI
import Combine

// MARK: - Look first · Pause · Save for later · Reopen · Reset · Copy (Oct 27, 2026)
//
// Canvas row "Workouts — look first, pause, save for later; finished: reopen, reset, copy" (PW1–PW8).
//  • Opening a workout starts nothing: no clock, Watch or Lock Screen card until the first logged set
//    (or Start set). ✕ closes it untouched.
//  • Pause (next to Finish): the clock, rest timer and Watch pause; paused time doesn't count toward
//    the 2½ hours. Left paused 12 hours, it saves itself for later.
//  • Save for later (in the paused card, and first in Finish's confirm when sets are left): closed,
//    sets kept, waiting on Home and the Workouts tab with Resume workout.
//  • A finished workout, swiped left on the Workouts tab: Reopen · Reset · Copy to another day.
// The state lives in LiveSessionController (pause records); the server half is 2.7.4
// (POST /workouts/{id}/reset, /copy). Synchronized folder: no target step.

// MARK: Server calls (2.7.4)

extension APIClient {
    func resetWorkout(id: String, removeAwards: [String]) async throws {
        _ = try await request("/workouts/\(id)/reset", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["removeAwards": removeAwards]))
    }

    /// A blank copy on another day; returns the new workout's id.
    func copyWorkout(id: String, date: Date) async throws -> String {
        struct Reply: Decodable { let id: String }
        let data = try await request("/workouts/\(id)/copy", method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: ["date": ISO8601DateFormatter().string(from: date)]))
        return try decoder.decode(Reply.self, from: data).id
    }
}

// MARK: The workout clock, wherever it shows

/// "Not started" · the running clock (paused time already off it) · the time it was paused at.
struct SessionClockText: View {
    let workout: Workout
    @ObservedObject private var live = LiveSessionController.shared

    var body: some View {
        let _ = live.revision
        switch live.clock(workout) {
        case .notStarted: Text("Not started")
        case .running(let since): Text(since, style: .timer)
        case .paused(let t): Text(Self.format(t))
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: PW1 · Opened to look

struct LookFirstCard: View {
    let workout: Workout

    var body: some View {
        VStack(spacing: 0) {
            LiveStatusBar(workout: workout)
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "eye").font(.system(size: 14, weight: .semibold)).foregroundColor(Brand.mute)
                    .padding(.top, 1)
                Text("Look all you like. The clock, your Watch and the Lock Screen card start when you log your first set.")
                    .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
        .transition(.opacity)
    }
}

// MARK: PW3 · Paused

struct PausedCard: View {
    let workout: Workout
    var onSaveForLater: () -> Void
    @ObservedObject private var live = LiveSessionController.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "pause.fill").font(.system(size: 15, weight: .heavy)).foregroundColor(Brand.voltText)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Brand.text.opacity(0.05)))
                        .overlay(Circle().stroke(Brand.voltLine, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paused").font(BrandFont.display(28)).foregroundColor(Brand.text)
                        Text(subtitle(ctx.date)).font(BrandFont.body(12.5)).foregroundColor(Brand.mute)
                    }
                    Spacer(minLength: 0)
                }
                Text("The clock, the rest timer and your Watch are paused. Paused time doesn't count toward the 2½ hours.")
                    .font(BrandFont.body(13)).foregroundColor(Brand.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { live.resume() }
                    } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    Button { onSaveForLater() } label: { Label("Save for later", systemImage: "bookmark") }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func subtitle(_ now: Date) -> String {
        guard case .paused(let t) = live.clock(workout) else { return "" }
        let since = live.pauses[workout.id]?.pausedAt ?? now
        let mins = max(0, Int(now.timeIntervalSince(since) / 60))
        let paused = mins < 1 ? "just now" : (mins < 60 ? "\(mins) min" : "\(mins / 60) h \(mins % 60) min")
        return "\(SessionClockText.format(t)) so far · paused \(paused)"
    }
}

// MARK: PW7 · Reset asks first

struct ResetWorkoutSheet: View {
    let workout: Workout
    let reset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let logged = workout.exercises.flatMap { $0.sets }.filter { $0.loggedReps != nil }.count
        let day = workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset \(workout.title)?").font(BrandFont.display(30)).foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(logged > 0
                 ? "Clears the \(logged) set\(logged == 1 ? "" : "s") you logged on \(day), with their Watch data. It goes back on your plan as new, on the same day."
                 : "It goes back on your plan as new, on \(day).")
                .font(BrandFont.body(14)).foregroundColor(Brand.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text("Any PR or award from it comes off too. Your coach sees it as not done.")
                .font(BrandFont.body(12.5)).foregroundColor(Brand.mute)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    dismiss()
                    reset()
                } label: {
                    Label("Reset workout", systemImage: "arrow.counterclockwise")
                        .font(BrandFont.body(15, .heavy)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Capsule().fill(Brand.danger))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                Button("Cancel") { dismiss() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.bg.ignoresSafeArea())
    }
}

// MARK: PW8 · Copy a blank to another day

struct CopyWorkoutSheet: View {
    let workout: Workout
    let copy: (Date) -> Void
    @ObservedObject private var store = AppStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pick: Date?
    @State private var page = 0                      // two weeks a page, from this week

    var body: some View {
        let cal = Calendar.training
        let today = cal.startOfDay(for: Date())
        let first = cal.date(byAdding: .day, value: page * 14, to: cal.trainingWeekStart(today)) ?? today
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        let last = days.last ?? first

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy \(workout.title)").font(BrandFont.display(30)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A blank copy: same exercises, sets and targets, nothing logged. This one stays in Completed.")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(rangeText(first, last)).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { page = max(0, page - 1) } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                        .foregroundColor(page == 0 ? Brand.mute.opacity(0.4) : Brand.text)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .disabled(page == 0)
                .accessibilityLabel("Earlier weeks")
                Button { withAnimation(.easeOut(duration: 0.15)) { page = min(26, page + 1) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.text)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel("Later weeks")
            }
            HStack(spacing: 0) {
                ForEach(Calendar.trainingWeekdayLetters.indices, id: \.self) { i in
                    Text(Calendar.trainingWeekdayLetters[i]).font(BrandFont.body(10, .heavy)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(days, id: \.self) { d in
                    let ok = d >= today
                    let chosen = pick.map { cal.isDate($0, inSameDayAs: d) } ?? false
                    let busy = store.workouts.contains { cal.isDate($0.date, inSameDayAs: d) }
                    let isToday = cal.isDate(d, inSameDayAs: today)
                    Button { pick = d; UISelectionFeedbackGenerator().selectionChanged() } label: {
                        VStack(spacing: 3) {
                            Text("\(cal.component(.day, from: d))").font(BrandFont.display(20))
                            Circle().fill(busy ? (chosen ? Brand.onVolt : Brand.mute) : .clear).frame(width: 4, height: 4)
                        }
                        .foregroundColor(chosen ? Brand.onVolt : (ok ? Brand.text : Brand.mute.opacity(0.45)))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(chosen ? Brand.volt : Brand.text.opacity(ok ? 0.06 : 0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isToday && !chosen ? Brand.voltLine : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .accessibilityLabel(d.formatted(date: .complete, time: .omitted) + (busy ? ", has a workout" : ""))
                }
            }
            HStack(spacing: 10) {
                Button {
                    guard let p = pick else { return }
                    dismiss()
                    copy(p)
                } label: {
                    Label(pick.map { "Copy to \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" } ?? "Pick a day",
                          systemImage: "doc.on.doc")
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

    private func rangeText(_ a: Date, _ b: Date) -> String {
        let cal = Calendar.training
        let same = cal.component(.month, from: a) == cal.component(.month, from: b)
        return a.formatted(.dateTime.month(.abbreviated).day()) + " – "
            + (same ? b.formatted(.dateTime.day()) : b.formatted(.dateTime.month(.abbreviated).day()))
    }
}
