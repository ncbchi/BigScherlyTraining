import SwiftUI
import Combine
import PhotosUI
import HealthKit

// MARK: - New user Home (Oct 26, 2026)
// Day one shouldn't be empty. Every card here is either the client's own data or something useful
// to do, and each one retires on its own when real data replaces it (see the handoff, NH0–NH3):
//
//   Welcome greeting   first workout completed
//   Coach welcome      the coach has sent a message (then Home's normal coach card takes over)
//   Ghost hero         any workout ever exists
//   Start here         6 of 6, swiped away, or 21 days (folds to one line once a workout exists)
//   Open week          anything planned that week
//   Starting point     a PR on every entered lift, or 6 weeks
//   First wins         all three earned, or 6 weeks
//   Example chart      the first real Stats history
//
// Real client accounts only: never in Demo Mode or mock builds, never for coaches.
// Server 2.7.3: GET/PUT /me/baseline, GET /me/welcome. Older servers: the starting point stays on
// this phone (and goes up once the server has it), and the welcome text falls back to the default.

// MARK: - The starting point (baseline)

struct BaselineLift: Codable, Equatable, Hashable {
    var exercise: String
    var weightLb: Double
    var reps: Int
    var e1RM: Double { ProgressEngine.oneRepMax(weight: weightLb, reps: reps) }
}

struct Baseline: Codable, Equatable {
    var bodyweightLb: Double?
    var lifts: [BaselineLift]
    var at: Date

    func lift(_ name: String) -> BaselineLift? { lifts.first { $0.exercise == name } }
    var isEmpty: Bool { bodyweightLb == nil && lifts.isEmpty }
}

/// The three lifts the sheet asks for, by the names the rest of the app (PRs, Stats) uses.
enum StartLift: String, CaseIterable, Identifiable {
    case squat = "Back Squat", bench = "Bench Press", deadlift = "Deadlift"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .squat: return "Squat"
        case .bench: return "Bench"
        case .deadlift: return "Deadlift"
        }
    }
}

struct BaselineReply: Decodable { let baseline: Baseline? }

/// GET /me/welcome (server 2.7.3).
struct WelcomeInfo: Decodable, Equatable {
    struct Latest: Decodable, Equatable {
        let threadId: String
        let topic: String
        let category: String?
        let text: String
        let kind: String?
        let at: Date
        let isRead: Bool
    }
    let text: String
    let custom: Bool
    let coachHasMessaged: Bool
    let latest: Latest?
    let coachName: String?
}

extension APIClient {
    func baseline() async throws -> Baseline? {
        let r: BaselineReply = try await get("/me/baseline")
        return r.baseline
    }

    func saveBaseline(_ b: Baseline) async throws -> Baseline? {
        var body: [String: Any] = [
            "lifts": b.lifts.map { l -> [String: Any] in ["exercise": l.exercise, "weightLb": l.weightLb, "reps": l.reps] },
            "at": ISO8601DateFormatter().string(from: b.at)
        ]
        if let bw = b.bodyweightLb { body["bodyweightLb"] = bw }
        let data = try await request("/me/baseline", method: "PUT", body: try JSONSerialization.data(withJSONObject: body))
        return try decoder.decode(BaselineReply.self, from: data).baseline
    }

    func welcomeInfo() async throws -> WelcomeInfo { try await get("/me/welcome") }

    /// POST /chats — the client starts a thread on the server (returns its id).
    func createChat(topic: String, category: String) async throws -> String {
        struct Reply: Decodable { let id: String }
        let r: Reply = try await post("/chats", body: ["topic": topic, "category": category])
        return r.id
    }

    /// Coach: a client's starting point.
    func trainerBaseline(clientId: String) async throws -> Baseline? {
        let r: BaselineReply = try await get("/admin/clients/\(clientId)/baseline")
        return r.baseline
    }
}

/// The signed-in client's starting point and the coach's welcome, cached per account on this phone.
final class BaselineStore: ObservableObject {
    static let shared = BaselineStore()

    @Published private(set) var baseline: Baseline?
    @Published private(set) var welcome: WelcomeInfo?
    /// The first full load from the server has finished (Home waits for it before awarding anything).
    @Published private(set) var loaded = false
    @Published var saveNote: String?

    private var account = ""
    private struct Cached: Codable { var baseline: Baseline; var pending: Bool }

    private func key(_ a: String) -> String { "bst_baseline_" + a }

    /// Called from AppStore when the account's data has loaded.
    func refresh(_ store: AppStore) {
        guard store.isLive, !store.isTrainer else { return }
        let id = store.client.id
        if id != account {
            account = id
            welcome = nil
            loaded = false
            let cached = readCache(id)
            baseline = cached?.baseline
        }
        Task {
            async let b = try? await APIClient.shared.baseline()
            async let w = try? await APIClient.shared.welcomeInfo()
            let server = await b
            let info = await w
            await MainActor.run {
                guard self.account == id else { return }
                if let info { self.welcome = info }
                let cached = self.readCache(id)
                if let server {
                    // The server's copy wins unless this phone has a newer one still waiting to go up.
                    if let c = cached, c.pending, c.baseline.at >= server.at {
                        self.baseline = c.baseline
                        Task { await self.upload(c.baseline, account: id) }
                    } else {
                        self.baseline = server
                        self.writeCache(id, Cached(baseline: server, pending: false))
                    }
                } else if let c = cached, c.pending {
                    Task { await self.upload(c.baseline, account: id) }
                }
                self.loaded = true
                store.refreshPRs()
                store.refreshAwards(announce: false)
            }
        }
    }

    func save(_ b: Baseline?, store: AppStore) {
        let id = store.client.id
        account = id
        guard let b, !b.isEmpty else {
            baseline = nil
            UserDefaults.standard.removeObject(forKey: key(id))
            if store.isLive {
                Task { _ = try? await APIClient.shared.request("/me/baseline", method: "DELETE") }
            }
            store.refreshPRs()
            return
        }
        baseline = b
        writeCache(id, Cached(baseline: b, pending: store.isLive))
        store.refreshPRs()
        if let bw = b.bodyweightLb { HealthKitManager.shared.saveBodyweightIfAllowed(lb: bw, at: b.at) }
        guard store.isLive else { return }
        Task { await upload(b, account: id) }
    }

    private func upload(_ b: Baseline, account id: String) async {
        do {
            let saved = try await APIClient.shared.saveBaseline(b)
            await MainActor.run {
                if let saved { self.writeCache(id, Cached(baseline: saved, pending: false)) }
                self.saveNote = nil
            }
        } catch let e as APIClient.HTTPStatusError where e.status == 404 || e.status == 405 {
            await MainActor.run { self.saveNote = "Saved on this phone. Your coach sees it once the server has the 2.7.3 update." }
        } catch {
            await MainActor.run { self.saveNote = "Saved on this phone. It goes to your coach next time you're online." }
        }
    }

    func reset() {
        account = ""
        baseline = nil
        welcome = nil
        loaded = false
        saveNote = nil
    }

    private func readCache(_ id: String) -> Cached? {
        guard let d = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: d)
    }
    private func writeCache(_ id: String, _ c: Cached) {
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: key(id)) }
    }

    /// For PR detection: each entered lift's est. 1RM (lb) and the day it was entered. A PR on or
    /// after that day must beat it; workouts from before it aren't affected.
    var prior: [String: (date: Date, e1RM: Double)] {
        guard let b = baseline else { return [:] }
        var out: [String: (date: Date, e1RM: Double)] = [:]
        for l in b.lifts where l.e1RM > 0 { out[l.exercise] = (Calendar.training.startOfDay(for: b.at), l.e1RM) }
        return out
    }
}

// MARK: - Health: bodyweight out, connection state

extension HealthKitManager {
    /// Writes the starting bodyweight to Apple Health, only if this app is already allowed to save
    /// body mass there. Never asks.
    func saveBodyweightIfAllowed(lb: Double, at date: Date) {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }
        let hk = HKHealthStore()
        guard hk.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let q = HKQuantity(unit: .pound(), doubleValue: lb)
        let sample = HKQuantitySample(type: type, quantity: q, start: date, end: date)
        hk.save(sample) { _, _ in }
    }

    /// The Health row of Start here: done once the permission sheet has been answered.
    static func healthConnected() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return true }   // nothing to connect (iPad)
        return !(await QuickStartTour.healthNeedsAsking())
    }
}

// MARK: - Which day-one cards show

enum DayOne {
    /// Real client accounts only.
    /// Waits for the account's first load, so the cards never flash over placeholder data.
    static func eligible(_ s: AppStore) -> Bool { s.isLive && !s.isTrainer && BaselineStore.shared.loaded }

    /// Day 1: the account's start date, or — while they've never finished a workout — the day
    /// this phone first saw the account, if that's later (a coach may have added them weeks ago).
    static func anchor(_ s: AppStore) -> Date {
        let cal = Calendar.training
        let key = "bst_dayone_seen_" + s.client.id
        let seen: Date = {
            if let d = UserDefaults.standard.object(forKey: key) as? Date { return d }
            let now = Date()
            if !s.client.id.isEmpty { UserDefaults.standard.set(now, forKey: key) }
            return now
        }()
        let now = Date()
        let start = s.client.startDate
        var a = start > now ? seen : start
        if !s.workouts.contains(where: { $0.completed }) { a = max(a, seen) }
        return cal.startOfDay(for: min(a, now))
    }

    static func dayNumber(_ s: AppStore) -> Int {
        let cal = Calendar.training
        let n = cal.dateComponents([.day], from: anchor(s), to: cal.startOfDay(for: Date())).day ?? 0
        return max(1, n + 1)
    }

    static func within(_ days: Int, _ s: AppStore) -> Bool { dayNumber(s) <= days }

    static func anyCompleted(_ s: AppStore) -> Bool { s.workouts.contains { $0.completed } }
    static func hasLoggedHistory(_ s: AppStore) -> Bool {
        s.workouts.contains { $0.completed && $0.exercises.contains { $0.sets.contains { $0.loggedReps != nil } } }
    }

    static func showsWelcomeGreeting(_ s: AppStore) -> Bool { eligible(s) && !anyCompleted(s) && within(42, s) }
    static func showsGhostHero(_ s: AppStore) -> Bool { eligible(s) && s.workouts.isEmpty }
    static func showsOpenWeek(_ s: AppStore) -> Bool { eligible(s) && within(42, s) }
    static func showsExample(_ s: AppStore) -> Bool {
        eligible(s) && s.personalRecords.isEmpty && !hasLoggedHistory(s) && within(42, s)
    }

    static func coachHasMessaged(_ s: AppStore) -> Bool {
        if let w = BaselineStore.shared.welcome { return w.coachHasMessaged }
        return s.chats.contains { $0.unread > 0 || $0.messages.contains { $0.fromTrainer } }
    }
    static func showsCoachWelcome(_ s: AppStore) -> Bool { eligible(s) && !coachHasMessaged(s) && within(21, s) }

    static func welcomeText(_ s: AppStore) -> String {
        if let w = BaselineStore.shared.welcome, !w.text.isEmpty { return w.text }
        let first = s.client.name.split(separator: " ").first.map(String.init) ?? ""
        return "Welcome in\(first.isEmpty ? "" : ", " + first). I'm building your first block now. Tell me what you're training for and any injuries I should know about."
    }

    /// Starting point: until every entered lift has a PR on or after the day it was entered, or 6 weeks.
    static func showsStartingPoint(_ s: AppStore) -> Bool {
        guard eligible(s), within(42, s) else { return false }
        guard let b = BaselineStore.shared.baseline, !b.lifts.isEmpty else { return true }
        let from = Calendar.training.startOfDay(for: b.at)
        let beaten = b.lifts.filter { l in s.personalRecords.contains { $0.exercise == l.exercise && $0.date >= from } }
        return beaten.count < b.lifts.count
    }

    static func showsFirstWins(_ s: AppStore) -> Bool {
        guard eligible(s), within(42, s) else { return false }
        let kinds = Set(s.awards.map { $0.kind })
        return !(kinds.contains(.firstSession) && kinds.contains(.checkedIn) && kinds.contains(.wiredUp))
    }
}

// MARK: - Wired Up (Watch + Health), earned once per account

enum WiredUp {
    private static func key(_ id: String) -> String { "bst_award_wiredup_" + id }

    static func earnedAt(_ accountId: String) -> Date? {
        UserDefaults.standard.object(forKey: key(accountId)) as? Date
    }

    /// Checks the two halves; the first time both are true, records the date and lets awards celebrate.
    static func check(_ s: AppStore) async {
        guard s.isLive, !s.isTrainer, BaselineStore.shared.loaded,
              !s.client.id.isEmpty, earnedAt(s.client.id) == nil else { return }
        let watch = WatchBridge.shared.isWatchReady
        let health = await HealthKitManager.healthConnected()
        guard watch && health else { return }
        await MainActor.run {
            UserDefaults.standard.set(Date(), forKey: key(s.client.id))
            // New clients get the celebration; anyone already training just finds it in Awards.
            s.refreshAwards(announce: DayOne.within(42, s))
        }
    }
}

// MARK: - Opening a chat thread from Home

final class ChatOpener: ObservableObject {
    static let shared = ChatOpener()
    struct Request: Equatable { let threadId: String; let video: Bool; let n: Int }
    @Published var request: Request?
    private var n = 0

    func open(_ threadId: String, video: Bool = false, store: AppStore) {
        n += 1
        request = Request(threadId: threadId, video: video, n: n)
        store.select(.chat)
    }

    /// Reply / Record video on the coach's welcome: a General thread on the server (reusing one
    /// that's already there), then Chat opens on it.
    func openWelcomeThread(video: Bool, store: AppStore) {
        if let t = store.chats.first(where: { $0.topic == "Welcome" }) {
            open(t.id, video: video, store: store)
            return
        }
        Task {
            var id = UUID().uuidString
            if store.isLive, let made = try? await APIClient.shared.createChat(topic: "Welcome", category: ChatCategory.general.rawValue) {
                id = made
            }
            await MainActor.run {
                if !store.chats.contains(where: { $0.id == id }) {
                    store.chats.insert(ChatThread(id: id, topic: "Welcome", category: .general, messages: [], lastActivity: Date()), at: 0)
                }
                self.open(id, video: video, store: store)
            }
        }
    }
}

// MARK: - Shared bits

private let openGrey = Color(hex: 0x8E8E93)

private struct DashedBox: View {
    var radius: CGFloat = 12
    var color: Color = openGrey
    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
    }
}

private struct SmallPillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(13, .bold))
            .foregroundColor(Brand.voltText)
            .padding(.horizontal, 14).frame(minHeight: 32)
            .background(Capsule().fill(Brand.volt.opacity(0.12)))
            .overlay(Capsule().stroke(Brand.voltLine.opacity(0.7), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .fixedSize()
    }
}

// MARK: - From your coach (welcome)

struct CoachWelcomeCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var base = BaselineStore.shared

    var body: some View {
        let coach = (base.welcome?.coachName).flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 12) {
            DSSectionHeader(title: "FROM YOUR COACH")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(initials(coach)).font(BrandFont.display(18)).foregroundColor(Brand.onVolt)
                        .frame(width: 40, height: 40).background(Circle().fill(Brand.volt))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coach.map { "\($0) · your coach" } ?? "Your coach").font(BrandFont.body(13, .bold))
                            .foregroundColor(Brand.text).lineLimit(1)
                        Text("Big Scherly Training").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                    Spacer(minLength: 0)
                }
                Text("“\(DayOne.welcomeText(store))”").font(BrandFont.body(14, .medium)).foregroundColor(Brand.text)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { ChatOpener.shared.openWelcomeThread(video: false, store: store) } label: {
                        Label("Reply", systemImage: "bubble.left.fill")
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    Button { ChatOpener.shared.openWelcomeThread(video: true, store: store) } label: {
                        Label("Record video", systemImage: "video.fill")
                    }
                    .buttonStyle(DSButtonStyle(kind: .dark))
                    .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                }
            }
            .card(padding: 16)
        }
    }

    private func initials(_ name: String?) -> String {
        guard let n = name, let c = n.first else { return "BS" }
        return String(c).uppercased()
    }
}

// MARK: - Ghost hero: where the first workout lands

struct GhostHeroCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("YOUR FIRST WORKOUT").font(BrandFont.body(11, .heavy)).tracking(1.5).foregroundColor(Brand.voltText)
                Spacer()
                Text("Coming soon").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Lands right here").font(BrandFont.display(34)).foregroundColor(Brand.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("When your coach posts it, it shows here with your sets and weights. Want a feel for it first?")
                    .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array([120.0, 150.0, 110.0].enumerated()), id: \.offset) { i, w in
                    VStack(spacing: 0) {
                        Rectangle().fill(Brand.voltLine.opacity(0.25)).frame(height: 1)
                        HStack {
                            Capsule().fill(Brand.voltLine.opacity(0.22)).frame(width: w, height: 8)
                            Spacer()
                            Capsule().fill(Brand.voltLine.opacity(0.22)).frame(width: 36, height: 8)
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Button { QuickStartTour.shared.startPractice() } label: {
                    Label("Try a practice set", systemImage: "play.fill")
                }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: false))
                .tourTarget("home.start")
                Text("Nothing gets logged").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(Brand.volt.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.voltLine.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

// MARK: - Start here

struct StartHereItem: Identifiable {
    enum Kind: String { case tour, watch, health, start, checkIn, photo }
    let kind: Kind
    let title: String
    let icon: String
    let button: String
    let done: Bool
    var id: String { kind.rawValue }
}

/// What Start here knows that SwiftUI can't observe on its own (Watch and Health).
final class StartHereState: ObservableObject {
    static let shared = StartHereState()
    @Published var watchReady = WatchBridge.shared.isWatchReady
    @Published var healthDone = false
    @Published var showStartingPoint = false
    @Published var showCheckIn = false
    @Published var showList = false

    func refresh(_ store: AppStore) {
        watchReady = WatchBridge.shared.isWatchReady
        Task {
            let h = await HealthKitManager.healthConnected()
            await MainActor.run { self.healthDone = h }
            await WiredUp.check(store)
        }
    }

    /// From the folded line's sheet, another sheet can only come up once that one has gone.
    private func afterList(_ open: @escaping () -> Void) {
        if showList {
            showList = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open() }
        } else {
            open()
        }
    }

    private func key(_ id: String) -> String { "bst_starthere_" + id }
    func dismissed(_ s: AppStore) -> Bool { UserDefaults.standard.bool(forKey: key(s.client.id)) }
    func dismiss(_ s: AppStore) {
        UserDefaults.standard.set(true, forKey: key(s.client.id))
        objectWillChange.send()
    }

    func items(_ s: AppStore) -> [StartHereItem] {
        let tour = QuickStartTour.shared.status
        return [
            StartHereItem(kind: .tour, title: "Take the 2-minute tour", icon: "map", button: "Start",
                          done: tour == "done" || tour == "skipped"),
            StartHereItem(kind: .watch, title: "Pair your Apple Watch", icon: "applewatch", button: "Pair", done: watchReady),
            StartHereItem(kind: .health, title: "Connect Apple Health", icon: "heart", button: "Connect", done: healthDone),
            StartHereItem(kind: .start, title: "Set your starting point", icon: "flag", button: "Add",
                          done: BaselineStore.shared.baseline != nil),
            StartHereItem(kind: .checkIn, title: "Do your first check-in", icon: "list.clipboard", button: "Start",
                          done: !s.checkIns.isEmpty),
            StartHereItem(kind: .photo, title: "Add a progress photo", icon: "camera", button: "Add", done: !s.photos.isEmpty)
        ]
    }

    func shows(_ s: AppStore) -> Bool {
        guard DayOne.eligible(s), DayOne.within(21, s), !dismissed(s) else { return false }
        return items(s).contains { !$0.done }
    }

    func run(_ k: StartHereItem.Kind, _ s: AppStore) {
        switch k {
        case .tour:
            showList = false
            QuickStartTour.shared.start(resume: QuickStartTour.shared.canResume)
        case .watch:
            if let u = URL(string: "itms-watchs://"), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
            } else {
                showList = false
                s.select(.settings)
            }
        case .health:
            Task {
                _ = await HealthKitManager.shared.requestAuthorization()
                await MainActor.run { self.refresh(s) }
            }
        case .start:
            afterList { self.showStartingPoint = true }
        case .checkIn:
            afterList { self.showCheckIn = true }
        case .photo:
            break   // the row's button is a PhotosPicker
        }
    }
}

/// The ring + rows (also the sheet behind the folded line).
struct StartHereList: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var state = StartHereState.shared
    @ObservedObject private var base = BaselineStore.shared
    @ObservedObject private var tour = QuickStartTour.shared
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        let _ = tour.revision
        let items = state.items(store)
        let done = items.filter { $0.done }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                StartHereRing(done: done, total: items.count, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("START HERE").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
                    Text("A few things so day one counts").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            ForEach(items) { it in
                Rectangle().fill(Brand.line).frame(height: 1)
                row(it)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            uploading = true
            Task {
                await ProgressPhotoAdd.add(item, store: store)
                await MainActor.run { uploading = false; pickedPhoto = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ it: StartHereItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if it.done {
                    Circle().fill(Brand.volt)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(Brand.onVolt)
                } else {
                    Circle().stroke(Brand.text.opacity(0.35), lineWidth: 1)
                    Image(systemName: it.icon).font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.text)
                }
            }
            .frame(width: 26, height: 26)
            Text(it.title).font(BrandFont.body(15, it.done ? .semibold : .bold))
                .foregroundColor(it.done ? Brand.mute : Brand.text)
                .strikethrough(it.done, color: Brand.mute)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            if !it.done {
                if it.kind == .photo {
                    PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                        Text(uploading ? "Adding…" : it.button)
                    }
                    .buttonStyle(SmallPillButton())
                    .disabled(uploading)
                } else {
                    Button(it.button) { state.run(it.kind, store) }
                        .buttonStyle(SmallPillButton())
                }
            }
        }
        .frame(minHeight: 52)
    }
}

struct StartHereRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 52
    var body: some View {
        ZStack {
            Circle().stroke(Brand.text.opacity(0.10), lineWidth: size > 40 ? 6 : 4)
            Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(Brand.voltLine, style: StrokeStyle(lineWidth: size > 40 ? 6 : 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if size > 40 {
                Text("\(done)/\(total)").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: done)
    }
}

/// Home's Start here card: the full list on day one, one line once a workout exists. Swipe it away.
struct StartHereCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var state = StartHereState.shared
    @ObservedObject private var tour = QuickStartTour.shared
    @State private var drag: CGFloat = 0

    var body: some View {
        let _ = tour.revision
        let folded = !store.workouts.isEmpty
        Group {
            if folded { foldedLine } else { StartHereList().card(padding: 16) }
        }
        .offset(x: drag)
        .opacity(1 - Double(min(abs(drag), 220) / 300))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5, v.translation.width < 0 else { return }
                    drag = v.translation.width
                }
                .onEnded { v in
                    if v.translation.width < -120 && abs(v.translation.width) > abs(v.translation.height) * 1.5 {
                        withAnimation(.easeOut(duration: 0.22)) { drag = -500 }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { state.dismiss(store) }
                            drag = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                    }
                }
        )
        .accessibilityAction(named: "Hide Start here") { state.dismiss(store) }
    }

    private var foldedLine: some View {
        let items = state.items(store)
        let done = items.filter { $0.done }.count
        let next = items.first { !$0.done }
        return Button { state.showList = true } label: {
            HStack(spacing: 12) {
                StartHereRing(done: done, total: items.count, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start here · \(done) of \(items.count)").font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                    if let next {
                        Text("Next: " + next.title.prefix(1).lowercased() + next.title.dropFirst())
                            .font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18).fill(Brand.black))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Adds one progress photo (same path as Photos ▸ Add photo).
enum ProgressPhotoAdd {
    static func add(_ item: PhotosPickerItem, store: AppStore) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) else { return }
        let jpeg = ui.jpegData(compressionQuality: 0.8) ?? data
        if store.isLive, let created = try? await APIClient.shared.uploadPhoto(imageData: jpeg, category: "New") {
            await MainActor.run { store.photos.insert(created.toModel(), at: 0) }
            return
        }
        let id = UUID().uuidString
        await MainActor.run {
            store.photos.insert(ProgressPhoto(id: id, date: Date(), imageName: id, category: "New", trainerComment: nil), at: 0)
        }
    }
}

// MARK: - Your starting point (card)

struct StartingPointCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var base = BaselineStore.shared
    @ObservedObject private var state = StartHereState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR STARTING POINT").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
                Spacer()
                if let b = base.baseline {
                    Text(b.at.formatted(.dateTime.month(.abbreviated).day())).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
            }
            if let b = base.baseline {
                filled(b)
            } else {
                Text("Know your best lifts? Add them and Stats starts today, not a month from now.")
                    .font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(StartLift.allCases) { l in addTile(l.short.uppercased()) }
                    addTile("BODY WT")
                }
                Text("Skip any you're not sure of. Your coach sees these.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
        }
        .card(padding: 16)
    }

    private func addTile(_ label: String) -> some View {
        Button { state.showStartingPoint = true } label: {
            VStack(spacing: 6) {
                Text(label).font(BrandFont.body(10, .heavy)).tracking(1).foregroundColor(Brand.mute)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                Text("+ Add").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.voltText)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .padding(.horizontal, 4)
            .background(DashedBox(radius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Add \(label.lowercased())")
    }

    private func filled(_ b: Baseline) -> some View {
        let from = Calendar.training.startOfDay(for: b.at)
        let hasLifts = !b.lifts.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Button { state.showStartingPoint = true } label: {
                HStack(spacing: 8) {
                    ForEach(StartLift.allCases) { l in
                        if let lift = b.lift(l.rawValue) {
                            numberTile(l.short.uppercased(), StatsUnits.weightText(lift.e1RM, unit: false), "est. 1RM",
                                       beaten: store.personalRecords.contains { $0.exercise == l.rawValue && $0.date >= from })
                        }
                    }
                    if let bw = b.bodyweightLb {
                        numberTile("BODY WT", StatsUnits.weightText(bw, unit: false), StatsUnits.weightLabel, beaten: false)
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("Edit your starting point")
            Text(!hasLifts ? "Add a lift any time: tap the tile." : "Beat these and it shows up as a PR.")
                .font(BrandFont.body(12)).foregroundColor(Brand.mute)
            if let note = base.saveNote {
                Text(note).font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
    }

    private func numberTile(_ label: String, _ value: String, _ unit: String, beaten: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(BrandFont.body(10, .heavy)).tracking(1).foregroundColor(Brand.mute).lineLimit(1)
                if beaten { Image(systemName: "trophy.fill").font(.system(size: 9)).foregroundColor(Brand.voltText) }
            }
            Text(value).font(BrandFont.display(26)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(BrandFont.body(10)).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: - NH2: the starting point sheet

struct StartingPointSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bst_units") private var units = "lb"

    @State private var bodyweight = ""
    @State private var weights: [String: String] = [:]
    @State private var reps: [String: String] = [:]
    @State private var healthBW: Double? = nil
    @State private var problem: String? = nil
    @FocusState private var focus: String?

    private var isKg: Bool { units == "kg" }
    private func toLb(_ v: Double) -> Double { isKg ? v / 0.45359237 : v }
    private func fromLb(_ lb: Double) -> Double { isKg ? lb * 0.45359237 : lb }
    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private func show(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text("Your starting point").font(BrandFont.display(30)).foregroundColor(Brand.text)
                    Spacer()
                    DSIconButton(systemName: "xmark", accessibilityLabel: "Close", size: 36) { dismiss() }
                }
                Text("Your best recent set of each. We work out the rest. Leave any blank.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("BODYWEIGHT").font(BrandFont.body(11, .heavy)).tracking(1.5).foregroundColor(Brand.mute)
                    HStack(spacing: 10) {
                        field($bodyweight, id: "bw", placeholder: healthBW.map { show(fromLb($0).rounded()) } ?? "", wide: true)
                        Text(isKg ? "kg" : "lb").font(BrandFont.body(14, .bold)).foregroundColor(Brand.mute)
                    }
                }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("BEST SET").frame(maxWidth: .infinity, alignment: .leading)
                        Text(isKg ? "KG" : "LB").frame(width: 76)
                        Text("").frame(width: 10)
                        Text("REPS").frame(width: 50)
                        Text("EST. 1RM").frame(width: 74, alignment: .trailing)
                    }
                    .font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                    .padding(.bottom, 8)
                    ForEach(StartLift.allCases) { l in
                        Rectangle().fill(Brand.line).frame(height: 1)
                        liftRow(l)
                    }
                }

                if let problem {
                    Text(problem).font(BrandFont.body(13, .semibold)).foregroundColor(Brand.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button { save() } label: { Text("Save starting point") }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .padding(.top, 4)
                Text("Shows in Stats as “Starting point · \(Date().formatted(.dateTime.month(.abbreviated).day()))”. Your coach sees it too.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg.ignoresSafeArea())
        .tapToDismissKeyboard()
        .onAppear(perform: prefill)
        .task {
            if BaselineStore.shared.baseline?.bodyweightLb == nil {
                healthBW = await HealthKitManager.shared.latestBodyweightPounds()
            }
        }
    }

    private func field(_ text: Binding<String>, id: String, placeholder: String = "", wide: Bool = false, decimals: Bool = true) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Brand.mute.opacity(0.6)))
            .keyboardType(decimals ? .decimalPad : .numberPad)
            .focused($focus, equals: id)
            .multilineTextAlignment(wide ? .leading : .center)
            .font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
            .padding(.horizontal, 12).frame(height: 46)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == id ? Brand.voltLine : Brand.line, lineWidth: focus == id ? 1.5 : 1))
    }

    private func liftRow(_ l: StartLift) -> some View {
        let w = Binding(get: { weights[l.rawValue] ?? "" }, set: { weights[l.rawValue] = $0 })
        let r = Binding(get: { reps[l.rawValue] ?? "" }, set: { reps[l.rawValue] = $0 })
        let e: Double? = {
            guard let wv = num(w.wrappedValue), wv > 0, let rv = Int(r.wrappedValue), rv > 0 else { return nil }
            return ProgressEngine.oneRepMax(weight: toLb(wv), reps: rv)
        }()
        return HStack(spacing: 8) {
            Text(l.short).font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            field(w, id: l.rawValue + ".w").frame(width: 76)
            Text("×").font(BrandFont.body(13)).foregroundColor(Brand.mute).frame(width: 10)
            field(r, id: l.rawValue + ".r", decimals: false).frame(width: 50)
            Text(e.map { "≈ " + StatsUnits.weightText($0) } ?? "—")
                .font(BrandFont.body(13, .heavy)).foregroundColor(e == nil ? Brand.mute : Brand.voltText)
                .frame(width: 74, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: e)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func prefill() {
        guard let b = BaselineStore.shared.baseline else { return }
        if let bw = b.bodyweightLb { bodyweight = show((fromLb(bw) * 10).rounded() / 10) }
        for l in b.lifts {
            weights[l.exercise] = show((fromLb(l.weightLb) * 10).rounded() / 10)
            reps[l.exercise] = String(l.reps)
        }
    }

    private func save() {
        problem = nil
        var bwLb: Double? = nil
        let bwText = bodyweight.trimmingCharacters(in: .whitespaces)
        if !bwText.isEmpty {
            guard let v = num(bwText), toLb(v) >= 50, toLb(v) <= 1000 else {
                problem = "Bodyweight looks off. Check the number and the unit."
                return
            }
            bwLb = (toLb(v) * 100).rounded() / 100
        }
        var lifts: [BaselineLift] = []
        for l in StartLift.allCases {
            let wt = (weights[l.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            let rp = (reps[l.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            if wt.isEmpty && rp.isEmpty { continue }
            guard let wv = num(wt), wv > 0, toLb(wv) <= 2000 else { problem = "\(l.short): check the weight."; return }
            guard let rv = Int(rp), rv >= 1, rv <= 30 else { problem = "\(l.short): reps go from 1 to 30."; return }
            lifts.append(BaselineLift(exercise: l.rawValue, weightLb: (toLb(wv) * 100).rounded() / 100, reps: rv))
        }
        let previous = BaselineStore.shared.baseline
        let b = Baseline(bodyweightLb: bwLb, lifts: lifts, at: previous?.at ?? Date())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        BaselineStore.shared.save(b.isEmpty ? nil : b, store: store)
        dismiss()
    }
}

// MARK: - First wins

struct FirstWinsCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var state = StartHereState.shared

    var body: some View {
        let kinds = Set(store.awards.map { $0.kind })
        let left = [AwardKind.firstSession, .checkedIn, .wiredUp].filter { !kinds.contains($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("FIRST WINS").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
                Spacer()
                Text(left == 0 ? "All unlocked" : "\(left) to unlock").font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            Button { store.select(.awards) } label: {
                HStack(spacing: 8) {
                    tile(.firstSession, earned: kinds.contains(.firstSession),
                         progress: kinds.contains(.firstSession) ? 1 : 0, sub: kinds.contains(.firstSession) ? "Earned" : "0 of 1")
                    tile(.checkedIn, earned: kinds.contains(.checkedIn),
                         progress: kinds.contains(.checkedIn) ? 1 : 0, sub: kinds.contains(.checkedIn) ? "Earned" : "0 of 1")
                    let halves = (state.watchReady ? 1 : 0) + (state.healthDone ? 1 : 0)
                    tile(.wiredUp, earned: kinds.contains(.wiredUp),
                         progress: kinds.contains(.wiredUp) ? 1 : Double(halves) / 2,
                         sub: kinds.contains(.wiredUp) ? "Earned" : "Watch\(state.watchReady ? " ✓" : "") · Health\(state.healthDone ? " ✓" : "")")
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("Opens Awards")
        }
        .card(padding: 16)
    }

    private func tile(_ k: AwardKind, earned: Bool, progress: Double, sub: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(earned ? Brand.volt : Color.clear)
                Circle().stroke(earned ? Brand.voltLine : Brand.text.opacity(0.35), lineWidth: 1.2)
                Image(systemName: k.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundColor(earned ? Brand.onVolt : Brand.text)
            }
            .frame(width: 40, height: 40)
            Text(k.title).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.text.opacity(0.12))
                    Capsule().fill(Brand.voltLine).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 4)
            Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.text.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(earned ? Brand.voltLine.opacity(0.6) : Brand.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(k.title), \(earned ? "earned" : sub)")
    }
}

// MARK: - Your numbers (the one EXAMPLE)

struct ExampleNumbersCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR NUMBERS").font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
            Text("EXAMPLE").font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(openGrey)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(openGrey, lineWidth: 1))
            ExampleLine()
                .stroke(openGrey, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 4]))
                .frame(height: 64)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                .accessibilityHidden(true)
            Text("Every set you log draws this line: estimated 1RM, bar speed and depth from your Watch.")
                .font(BrandFont.body(13)).foregroundColor(Brand.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your numbers. An example chart: every set you log draws this line.")
    }
}

private struct ExampleLine: Shape {
    func path(in r: CGRect) -> Path {
        let ys: [CGFloat] = [0.92, 0.88, 0.86, 0.70, 0.66, 0.52, 0.47, 0.36, 0.22, 0.18, 0.10]
        var p = Path()
        for (i, y) in ys.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(ys.count - 1), y: r.minY + r.height * y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Coach: a client's starting point (iPhone + iPad)

final class CoachBaselines: ObservableObject {
    static let shared = CoachBaselines()
    /// nil = not loaded; .some(nil) = none.
    @Published private(set) var byClient: [String: Baseline?] = [:]

    func load(_ clientId: String, force: Bool = false) {
        guard AppStore.shared.isLive, force || byClient[clientId] == nil else { return }
        Task {
            let b = try? await APIClient.shared.trainerBaseline(clientId: clientId)
            await MainActor.run { self.byClient[clientId] = .some(b) }
        }
    }

    func baseline(_ clientId: String) -> Baseline? { byClient[clientId].flatMap { $0 } }
    func reset() { byClient = [:] }

    /// "Squat 253 · Bench 180 · Body wt 182 lb"
    static func summary(_ b: Baseline) -> String {
        var parts: [String] = StartLift.allCases.compactMap { l in
            b.lift(l.rawValue).map { "\(l.short) \(StatsUnits.weightText($0.e1RM, unit: false))" }
        }
        if let bw = b.bodyweightLb { parts.append("Body wt \(StatsUnits.weightText(bw))") }
        return parts.joined(separator: " · ")
    }
    static func detail(_ b: Baseline) -> String {
        let sets = StartLift.allCases.compactMap { l in
            b.lift(l.rawValue).map { "\(l.short) \(StatsUnits.weightText($0.weightLb, unit: false))×\($0.reps)" }
        }
        let lead = "Entered \(b.at.formatted(.dateTime.month(.abbreviated).day()))."
        return sets.isEmpty ? lead : lead + " Best sets: " + sets.joined(separator: ", ") + ". Est. 1RM shown; PRs must beat it."
    }
}

/// iPhone coach: the strip under a client's numbers.
struct CoachStartingPointStrip: View {
    let clientId: String
    @ObservedObject private var cache = CoachBaselines.shared

    var body: some View {
        Group {
            if let b = cache.baseline(clientId) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flag.fill").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.voltText)
                        .frame(width: 26, height: 26).background(Circle().fill(Brand.volt.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STARTING POINT · \(b.at.formatted(.dateTime.month(.abbreviated).day()).uppercased())")
                            .font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
                        Text(CoachBaselines.summary(b)).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { cache.load(clientId) }
    }
}

/// iPad coach: a tile on the client's Overview.
struct PadStartingPointTile: View {
    let clientId: String
    @ObservedObject private var cache = CoachBaselines.shared

    var body: some View {
        Group {
            if let b = cache.baseline(clientId) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "flag").font(.system(size: 12, weight: .semibold))
                        Text("Starting point · \(b.at.formatted(.dateTime.month(.abbreviated).day()))").font(PadFont.cond(13)).lineLimit(1)
                    }
                    .foregroundColor(Pad.mute)
                    Text(CoachBaselines.summary(b)).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(CoachBaselines.detail(b)).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                        .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { cache.load(clientId) }
    }
}

// MARK: - Coach: the welcome message (Settings ▸ Coaching)

struct WelcomeMessageEditor: View {
    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var note: String? = nil
    @FocusState private var focused: Bool

    static let fallback = "Welcome in, {first}. I'm building your first block now. Tell me what you're training for and any injuries I should know about."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sent as your first message when a new client finishes setting up their account, in a “Welcome” thread. {first} becomes their first name. Leave it empty to use the standard one.")
                .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $text, prompt: Text(Self.fallback).foregroundColor(Brand.mute.opacity(0.7)), axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
                .font(BrandFont.body(14)).foregroundColor(Brand.text)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Brand.voltLine : Brand.line, lineWidth: 1))
                .disabled(!loaded)
            HStack(spacing: 10) {
                Button(saving ? "Saving…" : "Save welcome message") { save() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
                    .disabled(!loaded || saving)
                if let note { Text(note).font(BrandFont.body(12)).foregroundColor(Brand.mute) }
            }
        }
        .task {
            guard AppStore.shared.isLive else { loaded = true; return }
            if let s = try? await APIClient.shared.trainerSetting("welcomeMessage"), let json = s.json,
               let d = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
                if let dict = obj as? [String: Any], let t = dict["text"] as? String { text = t }
                else if let t = obj as? String { text = t }
            }
            loaded = true
        }
    }

    private func save() {
        guard AppStore.shared.isLive else { note = "Saved."; return }
        saving = true
        note = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String = {
            if t.isEmpty { return "" }
            let d = try? JSONSerialization.data(withJSONObject: ["text": t])
            return d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }()
        Task {
            do {
                _ = try await APIClient.shared.saveTrainerSetting("welcomeMessage", json: json)
                await MainActor.run { saving = false; note = t.isEmpty ? "Using the standard one." : "Saved." }
            } catch {
                await MainActor.run { saving = false; note = "Couldn't save. The server needs the 2.7.3 update." }
            }
        }
    }
}

struct WelcomeMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { WelcomeMessageEditor().padding(20) }
                .background(Brand.bg.ignoresSafeArea())
                .navigationTitle("Welcome message")
                .navigationBarTitleDisplayMode(.inline)
                .tapToDismissKeyboard()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(Brand.voltText) }
                }
        }
    }
}

// MARK: - Stats: the starting point series (drawn as a hollow dot, see StatsDetailView)

extension StatSeries {
    static let startingPointPrefix = "Starting point"
    var isStartingPoint: Bool { name.hasPrefix(Self.startingPointPrefix) }
}
