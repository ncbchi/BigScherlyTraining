import SwiftUI

// MARK: - Calendar moves + view as client (Oct 8, 2026)
//
// • Coach Today: "Moved sessions" — clients' moves (and yours) from the last 7 days.
// • Client screen ▸ eye button: a read-only preview of what that client sees in the app today,
//   fetched with a 30-minute view-only token (the server refuses any change made with it, and
//   reading their chat doesn't mark your messages read). The week calendar with drag-to-move
//   lives in Coach HQ on the web; moving one session from here is the workout's Edit ▸ Day.
// Synchronized folder: no target step needed.

struct APIWorkoutMoved: Decodable, Identifiable {
    let id: String
    let clientId: String
    let clientName: String
    let title: String
    let from: Date
    let to: Date
    let movedBy: String
    let movedAt: Date
}

struct APIViewAs: Decodable {
    let token: String
    let clientId: String
    let name: String
    let expiresAt: Date
}

extension APIClient {
    func recentMoves(days: Int = 7) async throws -> [APIWorkoutMoved] { try await get("/admin/moves?days=\(days)") }
    func viewAsToken(clientId: String) async throws -> APIViewAs {
        try decoder.decode(APIViewAs.self, from: try await request("/admin/clients/\(clientId)/view-as", method: "POST"))
    }
    /// GET with a specific token (the view-as token), bypassing the normal token routing.
    func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var req = URLRequest(url: URL(string: APIConfig.baseURL)!.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError(message: "Couldn't load \(path)") }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: Today ▸ Moved sessions

struct MovedSessionsSection: View {
    @EnvironmentObject var store: AppStore
    @State private var moves: [APIWorkoutMoved] = []
    var reloadKey: Int = 0

    var body: some View {
        Group {
            if !moves.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "MOVED SESSIONS", subtitle: "last 7 days")
                    ForEach(moves.prefix(5)) { m in
                        Button {
                            if let c = store.roster.first(where: { $0.id == m.clientId }) { store.selectedClient = c }
                        } label: { row(m) }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
        .task(id: reloadKey) { moves = (try? await APIClient.shared.recentMoves()) ?? moves }
    }

    private func row(_ m: APIWorkoutMoved) -> some View {
        let f = m.from.formatted(.dateTime.weekday(.abbreviated).day())
        let t = m.to.formatted(.dateTime.weekday(.abbreviated).day())
        return HStack(spacing: 12) {
            CoachAvatar(name: m.clientName, size: 40, highlighted: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(m.clientName) · \(m.title)").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                Text("\(f) → \(t)").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                Text(m.movedBy == "coach" ? "You moved it" : "They moved it · \(m.movedAt.formatted(.relative(presentation: .named)))")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            Spacer()
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .padding(14).background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: View as client

struct ClientPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    let clientName: String
    @State private var loading = true
    @State private var failed = false
    @State private var next: APIWorkout?
    @State private var isToday = false
    @State private var week: [APIWorkoutSummary] = []
    @State private var supps: [Supplement] = []
    @State private var macro: APIMacroDay?
    @State private var unread = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.fill")
                        Text("Viewing as \(clientName) · read only").font(BrandFont.body(12, .bold))
                    }
                    .foregroundColor(Brand.voltText)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: 1))

                    if loading {
                        ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 40)
                    } else if failed {
                        Text("Couldn't load their view. Try again.").font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    } else {
                        Text("TODAY · \(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())")
                            .font(BrandFont.body(10, .heavy)).tracking(1.4).foregroundColor(Brand.voltText)
                        Text(isToday ? (next?.title ?? "") : (next == nil ? "Nothing scheduled" : "Rest day"))
                            .font(BrandFont.display(38)).foregroundColor(Brand.text)
                        if let w = next { workoutCard(w) }
                        if let m = macro { macroCard(m) }
                        if !supps.isEmpty { suppCard }
                        card("THIS WEEK") {
                            if week.isEmpty { Text("Nothing else this week.").font(BrandFont.body(13)).foregroundColor(Brand.mute) }
                            ForEach(week, id: \.id) { w in
                                line("\(w.scheduledDate.formatted(.dateTime.weekday(.abbreviated))) · \(w.title)", w.exerciseSummary)
                            }
                        }
                        card("CHAT") {
                            Text(unread > 0 ? "\(unread) message\(unread == 1 ? "" : "s") from you they haven't read yet" : "They've read everything you sent")
                                .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        }
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("\(clientName.split(separator: " ").first.map(String.init) ?? clientName)'s app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundColor(Brand.voltText) } }
            .task { await load() }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BrandFont.body(9, .heavy)).tracking(1.2).foregroundColor(Brand.voltText)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func line(_ left: String, _ right: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(left).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
            Spacer(minLength: 10)
            Text(right).font(BrandFont.body(11)).foregroundColor(Brand.mute).multilineTextAlignment(.trailing)
        }
    }

    private func workoutCard(_ w: APIWorkout) -> some View {
        let model = w.toModel()
        let sets = model.exercises.reduce(0) { $0 + $1.sets.count }
        let label = isToday ? "TODAY'S WORKOUT" : "NEXT · \(w.scheduledDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())"
        return card(label) {
            Text(w.title).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
            Text("\(model.exercises.count) exercises · \(sets) sets").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            ForEach(model.exercises) { ex in
                line(ex.name, ex.sets.prefix(3).map { SetTarget.text($0, in: ex) }.joined(separator: " · ") + (ex.sets.count > 3 ? " …" : ""))
            }
        }
    }

    private func macroCard(_ m: APIMacroDay) -> some View {
        card("MACROS TODAY · \(m.isTrainingDay ? "TRAINING" : "REST") DAY") {
            HStack {
                macroCell("\(m.calorieGoal)", "kcal"); macroCell("\(m.proteinGoal)g", "protein")
                macroCell("\(m.carbGoal)g", "carbs"); macroCell("\(m.fatGoal)g", "fat")
            }
        }
    }

    private func macroCell(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(BrandFont.display(20)).foregroundColor(Brand.text)
            Text(l).font(BrandFont.body(10)).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity)
    }

    private var suppCard: some View {
        card("SUPPLEMENTS TODAY") {
            ForEach(supps) { s in line(s.name, "\(s.dose.display) · \(s.timing.summary)") }
        }
    }

    private func load() async {
        do {
            let v = try await APIClient.shared.viewAsToken(clientId: clientId)
            let all: [APIWorkoutSummary] = try await APIClient.shared.get("/workouts", token: v.token)
            let cal = Calendar.training
            let today = cal.startOfDay(for: Date())
            let upcoming = all.filter { !$0.completed && $0.scheduledDate >= today }.sorted { $0.scheduledDate < $1.scheduledDate }
            if let first = upcoming.first {
                isToday = cal.isDateInToday(first.scheduledDate)
                next = try? await APIClient.shared.get("/workouts/\(first.id)", token: v.token)
            }
            week = upcoming.filter { $0.scheduledDate < today.addingTimeInterval(7 * 86_400) }
            let allSupps: [Supplement] = (try? await APIClient.shared.get("/supplements", token: v.token)) ?? []
            let dow = cal.component(.weekday, from: Date())
            supps = allSupps.filter { s in
                guard s.isActive else { return false }
                return s.timing.kind != .fixedDays || (s.timing.days ?? []).contains { $0.rawValue == dow }
            }
            let macros: [APIMacroDay] = (try? await APIClient.shared.get("/macros", token: v.token)) ?? []
            macro = macros.first { cal.isDateInToday($0.date) }
            let chats: [APIChatThread] = (try? await APIClient.shared.get("/chats", token: v.token)) ?? []
            unread = chats.reduce(0) { $0 + $1.unread }
            loading = false
        } catch {
            loading = false; failed = true
        }
    }
}
