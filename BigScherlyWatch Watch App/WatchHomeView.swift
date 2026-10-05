import SwiftUI
import Combine

private let card = Color.white.opacity(0.07)

// The Watch glance: streak/status, next workout, unread messages, and — when a rest
// timer is running — a live countdown ring you can cancel from the wrist.
struct WatchHomeView: View {
    @EnvironmentObject var state: WatchState
    /// Your theme accent (from the phone), and the text colour that reads on it.
    private var volt: Color { state.accentColor }
    private var ink: Color { state.inkColor }
    @State private var now = Date()
    @State private var path: [String] = []
    @State private var lastAutoNavId: String? = nil
    @State private var appeared = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var totalSets: Int {
        state.activeWorkout?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
    }
    private var doneSets: Int {
        state.activeWorkout?.exercises.reduce(0) {
            $0 + $1.sets.filter { $0.loggedReps != nil }.count
        } ?? 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 10) {
                    if state.restEndDate != nil { restCard.transition(.scale.combined(with: .opacity)) }

                    if let workout = state.activeWorkout {
                        Button { path = [workout.id] } label: { heroCard(workout) }
                            .buttonStyle(.plain)
                    }

                    streakCard
                    nextWorkoutCard
                    if state.unreadMessages > 0 { messagesCard }
                    Text("Watch app \(WatchBuild.tag)")             // so an out-of-date Watch is obvious
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(Color(white: 0.4))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 6)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
            .navigationDestination(for: String.self) { _ in WatchCardHost() }      // the card, on your wrist
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) { appeared = true }
                if let id = state.activeWorkout?.id, path.isEmpty {
                    lastAutoNavId = id; path = [id]
                }
            }
            .onReceive(tick) { date in
                now = date
                if state.restEndDate != nil, state.restRemaining <= 0 {
                    withAnimation { state.restEndDate = nil }
                }
            }
            .onChange(of: state.activeWorkout?.id) { _, newId in
                if let id = newId {
                    if id != lastAutoNavId { lastAutoNavId = id; path = [id] }
                } else {
                    lastAutoNavId = nil
                    path = []
                }
            }
        }
    }

    // MARK: Hero — the primary action, with live session progress.

    private func heroCard(_ workout: WatchWorkout) -> some View {
        let frac = totalSets > 0 ? CGFloat(doneSets) / CGFloat(totalSets) : 0
        let started = doneSets > 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(ink)
                Text(started ? "CONTINUE" : "START")
                    .font(.system(size: 9, weight: .black)).tracking(1.4)
                    .foregroundColor(ink.opacity(0.75))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black)).foregroundColor(ink.opacity(0.55))
            }
            Text(workout.title)
                .font(.system(size: 16, weight: .bold)).foregroundColor(ink)
                .lineLimit(2).multilineTextAlignment(.leading)

            if totalSets > 0 {
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.opacity(0.22))
                            Capsule().fill(ink)
                                .frame(width: max(frac > 0 ? 4 : 0, g.size.width * frac))
                        }
                    }
                    .frame(height: 5)
                    Text("\(doneSets)/\(totalSets)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundColor(ink.opacity(0.8)).monospacedDigit()
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [volt, volt.opacity(0.80)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    // MARK: Rest

    private var restCard: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.13), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: state.restProgress)
                    .stroke(
                        AngularGradient(colors: [volt.opacity(0.55), volt],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: state.restProgress)
                VStack(spacing: -1) {
                    Text(timeString(state.restRemaining))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white).monospacedDigit()
                    Text("REST").font(.system(size: 8, weight: .black)).tracking(1.6)
                        .foregroundColor(volt)
                }
            }
            .frame(width: 92, height: 92)

            Button { state.cancelRest() } label: {
                Text("Skip")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(volt).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    // MARK: Cards

    private var streakCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(volt.opacity(0.14)).frame(width: 36, height: 36)
                Image(systemName: "flame.fill").foregroundColor(volt).font(.system(size: 17))
            }
            VStack(alignment: .leading, spacing: 0) {
                if state.streakWeeks > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(state.streakWeeks)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text("WK")
                            .font(.system(size: 10, weight: .black)).foregroundColor(.gray)
                    }
                } else {
                    Text("Let's begin")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                }
                Text(state.trainingStatus)
                    .font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var nextWorkoutCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(volt).frame(width: 12, height: 2)
                Text("NEXT UP")
                    .font(.system(size: 8, weight: .black)).tracking(1.4).foregroundColor(volt)
            }
            Text(state.nextWorkoutTitle)
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .lineLimit(2)
            if let date = state.nextWorkoutDate {
                Text(dateLabel(date)).font(.system(size: 11)).foregroundColor(.gray)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var messagesCard: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(volt).font(.system(size: 17))
                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2)
            }
            Text("\(state.unreadMessages) new message\(state.unreadMessages == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    // MARK: Helpers

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'Today'" : "EEE, MMM d"
        return f.string(from: d)
    }
}
