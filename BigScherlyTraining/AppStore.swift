import SwiftUI
import Combine

// MARK: - App Store
// Single source of truth for the prototype's in-memory state. In production this
// becomes the layer that calls the API and caches responses.
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var isLoggedIn = false
    @Published var showTray = false
    @Published var mustChangePassword = false    // forces the set-password screen after login
    @Published var isDemoMode = false            // offline demo (App Store review): sample data, no networking

    /// True only when the app should make real API calls: a live build AND a real (non-demo) account.
    var isLive: Bool { !APIConfig.useMock && !isDemoMode }

    init() {
        // Demo Mode survives a restart (iOS may relaunch the app in the background for a
        // Lock Screen tap); otherwise the app would think it's a real account with no login.
        if UserDefaults.standard.bool(forKey: "bst_demoMode") {
            enterDemo()
            isLoggedIn = true
        }
        // Auto-login: if a saved token exists from a previous session, restore it
        // and skip the login screen. The user stays logged in until they log out.
        if !APIConfig.useMock && !isDemoMode {
            APIClient.shared.loadToken()
            if APIClient.shared.authToken != nil {
                // Restore role too, or a trainer would come back into the client shell
                // (and vice-versa) and see the wrong / empty data.
                isTrainer = UserDefaults.standard.bool(forKey: "bst_isTrainer")
                let savedName = UserDefaults.standard.string(forKey: "bst_userName") ?? ""
                trainerName = savedName
                isLoggedIn = true
                if isTrainer {
                    loadRoster()
                } else {
                    // Seed the client's name from the last session so the greeting is
                    // right immediately, before /me refreshes the full profile.
                    if !savedName.isEmpty {
                        client = Client(id: client.id, name: savedName, email: client.email,
                                        startDate: client.startDate, goal: client.goal)
                    }
                    loadAllFromAPI()
                }
            }
        }
        // If any API call reports the session expired, return to the login screen.
        NotificationCenter.default.addObserver(forName: .bstUnauthorized, object: nil, queue: .main) { [weak self] _ in
            self?.logout()
        }

        // Route set edits made on the Watch through the phone's save path.
        WatchBridge.shared.onSetLogged = { [weak self] workoutId, exerciseId, setId, reps, weight, rpe in
            self?.applyWatchSetLog(workoutId: workoutId, exerciseId: exerciseId, setId: setId,
                                   reps: reps, weight: weight, rpe: rpe)
        }
        ServerSync.shared.attach(self)   // v1.1: lets the outbox check live/demo/trainer state
    }

    @Published var client = MockData.client
    @Published var workouts = MockData.workouts
    @Published var macroDays = MockData.macroDays
    @Published var checkIns = MockData.checkIns
    @Published var photos = MockData.photos
    @Published var chats = MockData.chats
    @Published var announcements = MockData.announcements
    @Published var shareStats = MockData.shareStats
    @Published var supplements: [Supplement] = MockData.supplements
    @Published var supplementStacks: [SupplementStack] = MockData.supplementStacks
    @Published var supplementLogs: [SupplementLog] = MockData.supplementLogs

    @Published var activeTab: AppTab = AppTab(rawValue: UserDefaults.standard.string(forKey: "bst_launch_tab") ?? "") ?? .dashboard   // Settings ▸ Open on launch
    /// A workout to open straight into (a widget's Start button); Home presents it.
    @Published var openSessionId: String? = nil
    // Direction of the last tab change, so MainShell can slide the right way.
    @Published private(set) var tabForward = true

    // Login photo board — trainer-curated shots (see conversation note on IG)
    let boardPhotos = ["board1","board2","board3","board4","board5","board6"]

    // Derived
    var upcomingWorkouts: [Workout] {
        workouts.filter { !$0.completed }.sorted { $0.date < $1.date }
    }
    var pastWorkouts: [Workout] {
        workouts.filter { $0.completed }.sorted { $0.date > $1.date }
    }

    // MARK: - Check-ins

    // The most recent submitted check-in before a new one (for week-over-week deltas).
    var lastSubmittedCheckIn: CheckIn? {
        checkIns.filter { $0.status != .draft }.sorted { $0.date > $1.date }.first
    }

    // Look up a field value from the last submitted check-in by question id.
    func lastCheckInValue(questionId: String) -> String? {
        guard let ci = lastSubmittedCheckIn else { return nil }
        // Labels are stored "Label|kind"; match on the leading question id via schema.
        guard let q = CheckInSchema.question(questionId) else { return nil }
        return ci.fields.first { $0.label.hasPrefix(q.label + "|") || $0.id == questionId }?.value
    }

    // Persist a new submitted check-in (optimistic local insert + server sync).
    // Photos are keyed by slot label (Front, Side, …). Photo images attach to the
    // check-in's progress-photo list locally, matching how the Photos tab currently
    // handles images (server photo upload is a separate, not-yet-wired pathway).
    func submitCheckIn(fields: [CheckInField], photos: [String: UIImage] = [:]) {
        // Optimistic local insert so the UI + celebration are instant. The server
        // copy (with uploaded photos) syncs in the background.
        let localCI = CheckIn(id: UUID().uuidString, date: Date(), status: .submitted,
                              photoIDs: [], fields: fields, trainerResponse: nil)
        checkIns.insert(localCI, at: 0)

        guard isLive else {
            // Demo/offline: keep photos local-only for display.
            for slot in photos.keys.sorted() {
                let id = UUID().uuidString
                self.photos.insert(ProgressPhoto(id: id, date: Date(),
                                                 imageName: id, category: slot,
                                                 trainerComment: nil), at: 0)
            }
            return
        }

        Task {
            // 1. Upload each check-in photo, tagged by its slot; collect server ids.
            var serverPhotoIDs: [String] = []
            for slot in photos.keys.sorted() {
                guard let img = photos[slot],
                      let jpeg = img.jpegData(compressionQuality: 0.8) else { continue }
                if let created = try? await APIClient.shared.uploadPhoto(imageData: jpeg, category: slot) {
                    serverPhotoIDs.append(created.id)
                    await MainActor.run { self.photos.insert(created.toModel(), at: 0) }
                }
            }
            // 2. Submit the check-in with the uploaded photo ids so the server links them.
            var ciForServer = localCI
            ciForServer.photoIDs = serverPhotoIDs
            try? await APIClient.shared.submitCheckIn(ciForServer)
        }
    }

    // Compute celebratory "wins" comparing this check-in to the previous one, plus
    // this week's workout stats. Only genuine positives surface — never punishing.
    func computeWins(from newFields: [CheckInField]) -> [CheckInWin] {
        var wins: [CheckInWin] = []
        let prior = checkIns.filter { $0.status != .draft }.sorted { $0.date > $1.date }
        // The just-submitted check-in is at index 0; compare against index 1.
        let previous: CheckIn? = prior.count > 1 ? prior[1] : nil

        func val(_ fields: [CheckInField], _ q: CheckInQuestion) -> Double? {
            guard let raw = fields.first(where: { $0.label.hasPrefix(q.label + "|") })?.value else { return nil }
            return Double(raw)
        }

        // Weight movement toward goal (framed by direction, not judged).
        if let wq = CheckInSchema.question("weight"),
           let now = val(newFields, wq), let prev = previous.flatMap({ val($0.fields, wq) }) {
            let d = now - prev
            if abs(d) >= 0.1 {
                wins.append(CheckInWin(
                    icon: "scalemass.fill",
                    title: "Bodyweight \(d > 0 ? "up" : "down") \(String(format: "%.1f", abs(d))) lb",
                    detail: "Tracked and trending — your coach sees the whole picture."))
            }
        }

        // Scale improvements (sleep, energy, adherence, etc.).
        let celebrateScales = ["sleepQuality": "Better sleep", "energy": "More energy",
                               "nutrition": "Tighter nutrition", "consistency": "More consistent",
                               "motivation": "Higher motivation", "soreness": "Better recovery"]
        for (qid, title) in celebrateScales {
            guard let q = CheckInSchema.question(qid),
                  let now = val(newFields, q), let prev = previous.flatMap({ val($0.fields, q) }),
                  now > prev else { continue }
            wins.append(CheckInWin(
                icon: "arrow.up.heart.fill",
                title: title,
                detail: "Up from \(Int(prev)) to \(Int(now)) out of 10 this week."))
        }

        // Workout stats this week vs last week.
        wins.append(contentsOf: workoutWins())

        // Cap so the card stays punchy.
        return Array(wins.prefix(5))
    }

    // Workout-derived wins: volume, sessions, PRs this week.
    private func workoutWins() -> [CheckInWin] {
        var out: [CheckInWin] = []
        let cal = Calendar.current
        let now = Date()
        func inWeek(_ d: Date, weeksAgo: Int) -> Bool {
            guard let start = cal.date(byAdding: .weekOfYear, value: -weeksAgo,
                                       to: cal.startOfWeek(for: now)) else { return false }
            guard let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return false }
            return d >= start && d < end
        }
        let thisWeek = pastWorkouts.filter { inWeek($0.date, weeksAgo: 0) }
        let lastWeek = pastWorkouts.filter { inWeek($0.date, weeksAgo: 1) }

        // Sessions completed.
        if !thisWeek.isEmpty {
            out.append(CheckInWin(
                icon: "figure.strengthtraining.traditional",
                title: "\(thisWeek.count) session\(thisWeek.count == 1 ? "" : "s") crushed",
                detail: lastWeek.isEmpty ? "Great week of training." :
                    "vs \(lastWeek.count) last week."))
        }

        // Total volume vs last week.
        func vol(_ ws: [Workout]) -> Double {
            ws.flatMap { $0.exercises }.flatMap { $0.sets }.reduce(0) { $0 + $1.volume }
        }
        let tv = vol(thisWeek), lv = vol(lastWeek)
        if tv > 0 && tv > lv && lv > 0 {
            let diff = Int(tv - lv)
            out.append(CheckInWin(
                icon: "chart.line.uptrend.xyaxis",
                title: "Volume up \(diff.formatted()) lb",
                detail: "More total work than last week — that's progress."))
        }

        return out
    }
    var todayMacros: MacroDay? {
        macroDays.first { Calendar.current.isDateInToday($0.date) } ?? macroDays.first
    }
    var unreadMessages: Int { chats.reduce(0) { $0 + $1.unread } }

    // Consecutive-week training streak: count back from this week while each week
    // has at least one completed workout.
    var weekStreak: Int {
        let cal = Calendar.training
        func weekKey(_ d: Date) -> Int {
            cal.component(.weekOfYear, from: d) * 100 + cal.component(.yearForWeekOfYear, from: d)
        }
        let completedWeeks = Set(pastWorkouts.map { weekKey($0.date) })
        var streak = 0
        var cursor = Date()
        // Allow the current week to be "in progress" (not yet trained) without breaking.
        if !completedWeeks.contains(weekKey(cursor)) {
            cursor = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) ?? cursor
        }
        while completedWeeks.contains(weekKey(cursor)) {
            streak += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
            if streak > 260 { break }   // safety cap
        }
        return streak
    }

    // Push a small state snapshot to the Watch (glance + complication).
    func syncToWatch() {
        let next = upcomingWorkouts.first
        let due = upcomingWorkouts.filter { Calendar.current.isDateInToday($0.date) }.count
        let status: String
        if due > 0 { status = "\(due) due today" }
        else { status = weekStreak > 0 ? "On track" : "Let's begin" }

        WatchBridge.shared.sync(WatchPayload(
            streakWeeks: weekStreak,
            trainingStatus: status,
            nextWorkoutTitle: next?.title ?? "No workout scheduled",
            nextWorkoutDate: next?.date,
            unreadMessages: unreadMessages))

        // Also refresh the live workout the Watch should show.
        sendActiveWorkoutToWatch()
    }

    // The workout currently open on the phone (set by WorkoutDetailView). When nil,
    // the Watch falls back to today's / the next workout.
    @Published var activeWorkoutId: String? = nil {
        didSet { sendActiveWorkoutToWatch() }
    }

    // Build the compact Watch payload for whichever workout is "active" and send it.
    func sendActiveWorkoutToWatch() {
        let workout: Workout? = {
            if let id = activeWorkoutId, let w = workouts.first(where: { $0.id == id }) { return w }
            // Fall back to today's workout, else the next upcoming.
            if let today = workouts.first(where: { Calendar.current.isDateInToday($0.date) && !$0.completed }) { return today }
            return upcomingWorkouts.first
        }()

        guard let w = workout else { WatchBridge.shared.sendActiveWorkout(nil); return }
        let payload = WatchWorkout(
            id: w.id, title: w.title,
            exercises: w.exercises.map { ex in
                WatchExercise(id: ex.id, name: ex.name, restSeconds: ex.restSeconds,
                    sets: ex.sets.map { s in
                        WatchSet(id: s.id, targetReps: s.targetReps, targetWeight: s.targetWeight,
                                 loggedReps: s.loggedReps, loggedWeight: s.loggedWeight, rpe: s.rpe)
                    },
                    pauseTarget: PauseTarget.forWatch(ex))     // Settings ▸ Apple Watch ▸ Pause buzz
            })
        WatchBridge.shared.sendActiveWorkout(payload)
    }

    // Apply a set edit that arrived from the Watch, through the same save path a
    // phone edit uses (updates the model, persists, checks PRs, re-syncs the Watch).
    func applyWatchSetLog(workoutId: String, exerciseId: String, setId: String,
                          reps: Int?, weight: Double?, rpe: Double?) {
        guard let wi = workouts.firstIndex(where: { $0.id == workoutId }),
              let ei = workouts[wi].exercises.firstIndex(where: { $0.id == exerciseId }),
              let si = workouts[wi].exercises[ei].sets.firstIndex(where: { $0.id == setId }) else { return }
        if let reps { workouts[wi].exercises[ei].sets[si].loggedReps = reps }
        if let weight { workouts[wi].exercises[ei].sets[si].loggedWeight = weight }
        if let rpe { workouts[wi].exercises[ei].sets[si].rpe = rpe }
        if workouts[wi].exercises[ei].sets[si].loggedAt == nil {
            workouts[wi].exercises[ei].sets[si].loggedAt = Date()
        }
        saveLoggedSets(workoutId: workoutId, exercise: workouts[wi].exercises[ei])
        checkForPRs(in: workouts[wi])
        sendActiveWorkoutToWatch()   // reflect the update back to the wrist
    }
    var liveAnnouncements: [Announcement] {
        announcements.filter { !$0.cleared }.sorted { $0.date > $1.date }
    }

    func login() { withAnimation(.easeOut(duration: 0.4)) { isLoggedIn = true } }

    // MARK: - Supplements
    // Reschedule all reminders from the current protocol + workout history.
    func rescheduleSupplementReminders() {
        SupplementEngine.shared.rescheduleAll(
            supplements: supplements, logs: supplementLogs, workouts: workouts)
    }

    // User confirmed a dose: log it, stop the nagging, decrement stock, sync to server.
    func confirmSupplement(_ s: Supplement) {
        let log = SupplementLog(id: UUID().uuidString, supplementId: s.id,
                                scheduledFor: Date(), takenAt: Date(), status: .taken)
        supplementLogs.append(log)
        SupplementEngine.shared.cancelReminders(for: s.id)
        if let i = supplements.firstIndex(where: { $0.id == s.id }),
           let q = supplements[i].quantityOnHand {
            supplements[i].quantityOnHand = max(0, q - 1)
        }
        guard isLive else { return }
        Task { try? await APIClient.shared.confirmSupplement(id: s.id, takenAt: log.takenAt ?? Date()) }
    }

    // MARK: - Offline demo (App Store review)
    // Entered by leaving BOTH login fields empty and tapping Log In. Loads the
    // bundled sample data and makes no network calls, so a reviewer sees a fully
    // populated app without a real account or a reachable backend.
    func enterDemo() {
        isDemoMode = true
        UserDefaults.standard.set(true, forKey: "bst_demoMode")   // survive a background restart (Live Activity taps)
        mustChangePassword = false
        // Reset to the sample set so the demo is always fully populated, regardless
        // of any prior real-login state that may still be in memory.
        client = MockData.client
        workouts = MacroPlanStore.shared.applyMoves(to: MockData.workouts)
        macroDays = MockData.macroDays
        checkIns = MockData.checkIns
        photos = MockData.photos
        chats = MockData.chats
        announcements = MockData.announcements
        shareStats = MockData.shareStats
        supplements = MockData.supplements
        supplementStacks = MockData.supplementStacks
        supplementLogs = MockData.supplementLogs
        refreshPRs()
        refreshAwards(announce: false)
        syncToWatch()   // push demo state to the Watch too
        login()
    }

    // MARK: - Live data loading
    // Called after login when not in mock mode. Fetches everything from the API and
    // maps it into the published models the screens already use. Falls back silently
    // to whatever is loaded if a call fails, so one bad endpoint doesn't blank the app.
    @Published var isLoading = false

    func loadAllFromAPI() {
        guard isLive else { return }
        isLoading = true
        Task {
            async let prof = try? await APIClient.shared.profile()
            async let stats = try? await APIClient.shared.shareStats()
            async let w = (try? await APIClient.shared.workouts()) ?? []
            async let m = (try? await APIClient.shared.macros()) ?? []
            async let ci = (try? await APIClient.shared.checkins()) ?? []
            async let ph = (try? await APIClient.shared.photos()) ?? []
            async let ch = (try? await APIClient.shared.chats()) ?? []
            async let an = (try? await APIClient.shared.announcements()) ?? []
            async let sp = (try? await APIClient.shared.supplements()) ?? []
            async let ss = (try? await APIClient.shared.supplementStacks()) ?? []
            async let sl = (try? await APIClient.shared.supplementLogs()) ?? []

            // Workouts come as summaries; fetch full detail for each so exercises/sets load
            let summaries = await w
            var fullWorkouts: [Workout] = []
            var apiWorkouts: [APIWorkout] = []
            for s in summaries {
                if let full = try? await APIClient.shared.workout(s.id) {
                    apiWorkouts.append(full)
                    fullWorkouts.append(full.toModel())
                }
            }

            let macros = await m
            let checkins = await ci
            let photos = await ph
            let chatThreads = await ch
            let anns = await an
            let supps = await sp
            let stacks = await ss
            let suppLogs = await sl
            let profile = await prof
            let shareStatsResult = await stats

            await MainActor.run {
                // Replace the placeholder identity with the real signed-in user, so
                // greetings and profile screens show the actual account (not mock).
                if let p = profile {
                    self.client = Client(id: p.id, name: p.name, email: p.email,
                                         startDate: p.startDate, goal: p.goal)
                    // If the account still owes a password change (e.g. force-quit
                    // before finishing), the server is the source of truth — re-enforce.
                    if p.mustChangePassword { self.mustChangePassword = true }
                }
                if let st = shareStatsResult {
                    self.shareStats = ShareStats(totalWeight: st.totalWeight, duration: st.duration,
                                                 setCount: st.setCount, topLift: st.topLift, date: st.date)
                }
                self.workouts = MacroPlanStore.shared.applyMoves(to: Self.keepLocalLogs(server: fullWorkouts, local: self.workouts))
                self.macroDays = macros.map { $0.toModel() }
                self.checkIns = checkins.map { $0.toModel() }
                self.photos = photos.map { $0.toModel() }
                self.chats = chatThreads.map { $0.toModel() }
                self.announcements = anns.map { $0.toModel() }
                // APISupplement/Stack/Log are typealiases of the models, so no mapping.
                self.supplements = supps
                self.supplementStacks = stacks
                self.supplementLogs = suppLogs
                self.isLoading = false
                self.syncToWatch()   // push fresh glance/complication state to the Watch
                // Reminders depend on the freshly-loaded protocol + workout history.
                self.rescheduleSupplementReminders()
                // Build the trophy case from the real logged sets we just pulled.
                self.refreshPRs()
                self.refreshAwards(announce: false)
            }
            // v1.1: restore notes/motion/plan from the server if this phone lacks them,
            // queue anything only on this phone, then send the outbox.
            let me = await MainActor.run { self.client.id }
            await ServerSync.shared.afterLoad(apiWorkouts: apiWorkouts, clientId: me)
        }
    }

    // Load full message history for a chat thread on demand
    func loadMessages(for threadId: String) {
        guard isLive else { return }
        Task {
            if let msgs = try? await APIClient.shared.messages(threadId) {
                await MainActor.run {
                    if let idx = self.chats.firstIndex(where: { $0.id == threadId }) {
                        self.chats[idx].messages = msgs.map { $0.toModel() }
                    }
                }
            }
        }
    }

    // MARK: Exercise history
    // In the prototype this is generated so the table + graph are populated.
    // In production it comes from the API (every logged set is already stored).
    // Real history for a lift, built from the client's actual logged sets.
    // (Previously this fabricated 10 fake sessions — the chart looked great and meant
    // nothing. Now an empty chart honestly means "you haven't logged this lift yet".)
    func history(for exerciseName: String) -> [ExerciseHistorySession] {
        ProgressEngine.history(for: exerciseName, workouts: workouts)
    }

    // MARK: - Personal records
    // Derived from logged sets, throttled so a PR stays meaningful (see ProgressEngine).
    @Published var personalRecords: [PersonalRecord] = []
    @Published var prToCelebrate: PersonalRecord?     // drives the celebration banner
    @Published var lastPRForShare: PersonalRecord?    // surfaced on the Share card

    /// Lifts the trainer wants PR-tracked beyond the standard main lifts.
    var trainerTaggedLifts: Set<String> { [] }

    /// Recompute the trophy case from scratch (after loading, or after logging).
    func refreshPRs() {
        personalRecords = ProgressEngine.allPRs(workouts: workouts,
                                                trainerTagged: trainerTaggedLifts)
        lastPRForShare = personalRecords.max(by: { $0.date < $1.date })
    }

    /// Call when a workout is completed/logged. Detects any *new* PR and, if one
    /// clears the throttle, fires the celebration exactly once.
    func checkForPRs(in workout: Workout) {
        let fresh = ProgressEngine.newPRs(in: workout, allWorkouts: workouts,
                                          existing: personalRecords,
                                          trainerTagged: trainerTaggedLifts)
        if !fresh.isEmpty {
            personalRecords.append(contentsOf: fresh)
            // Celebrate the single best one, not one banner per lift.
            let top = fresh.max(by: { $0.gain < $1.gain })
            prToCelebrate = top
            lastPRForShare = top
        }
        // Awards are evaluated after PRs, since some depend on them (First PR, Triple
        // Crown). If a PR is already celebrating, the award waits its turn — the
        // celebration sheet picks it up when the PR sheet is dismissed.
        refreshAwards()
    }

    /// Push every logged set for an exercise up to the server, so the trainer's
    /// logged-vs-target view reflects what actually happened. No-op in demo/mock.
    /// A reload replaces workouts with the server's copy — but a set just logged on the phone
    /// (say from the Lock Screen) may not have reached the server yet. Keep those.
    static func keepLocalLogs(server: [Workout], local: [Workout]) -> [Workout] {
        let byId = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return server.map { sw in
            guard let lw = byId[sw.id] else { return sw }
            var w = sw
            for ei in w.exercises.indices {
                guard let le = lw.exercises.first(where: { $0.id == w.exercises[ei].id }) else { continue }
                for si in w.exercises[ei].sets.indices where w.exercises[ei].sets[si].loggedReps == nil {
                    if let ls = le.sets.first(where: { $0.id == w.exercises[ei].sets[si].id }), ls.loggedReps != nil {
                        w.exercises[ei].sets[si].loggedReps = ls.loggedReps
                        w.exercises[ei].sets[si].loggedWeight = ls.loggedWeight
                        w.exercises[ei].sets[si].rpe = ls.rpe
                        w.exercises[ei].sets[si].loggedAt = ls.loggedAt
                    }
                }
            }
            return w
        }
    }

    func saveLoggedSets(workoutId: String, exercise: Exercise) {
        guard isLive else { return }
        Task {
            for s in exercise.sets where s.loggedReps != nil || s.loggedWeight != nil || s.rpe != nil {
                try? await APIClient.shared.logSet(
                    workoutId: workoutId, exerciseId: exercise.id, setId: s.id,
                    reps: s.loggedReps, weight: s.loggedWeight, rpe: s.rpe, loggedAt: s.loggedAt)
            }
        }
    }

    // Push HealthKit-derived session vitals to the server so the coach can see
    // what the client's body did during the workout. Best-effort, fire-and-forget.
    func uploadWorkoutVitals(workoutId: String, vitals: WorkoutVitals) {
        guard isLive else { return }
        workoutVitals[workoutId] = vitals   // cache locally too
        Task { try? await APIClient.shared.uploadWorkoutVitals(workoutId: workoutId, vitals: vitals) }
    }

    // Cache of a workout's HealthKit vitals (incl. HR series), keyed by workout id.
    // Feeds the per-exercise (History) and per-set (Workouts) heart-rate slicing.
    @Published var workoutVitals: [String: WorkoutVitals] = [:]

    // Fetch (and cache) a workout's stored health data from the server.
    func loadWorkoutVitals(workoutId: String) async -> WorkoutVitals? {
        if let cached = workoutVitals[workoutId] { return cached }
        guard isLive else { return nil }
        guard let v = try? await APIClient.shared.workoutHealth(workoutId: workoutId) else { return nil }
        await MainActor.run { workoutVitals[workoutId] = v }
        return v
    }

    // MARK: - Awards
    @Published var awards: [Award] = []
    @Published var awardToCelebrate: Award?     // drives the full-screen celebration
    @Published var awardToShare: Award?         // carried into the Share tab

    /// Awards celebrated already, so we never replay one. Persisted.
    @AppStorage("celebratedAwards") private var celebratedRaw = ""
    private var celebrated: Set<String> {
        get { Set(celebratedRaw.split(separator: ",").map(String.init)) }
        set { celebratedRaw = newValue.sorted().joined(separator: ",") }
    }

    /// Recompute the full trophy case from real history, and celebrate anything new.
    /// `announce: false` on first load so a returning client isn't ambushed by a
    /// backlog of confetti for things they earned months ago.
    func refreshAwards(announce: Bool = true) {
        let found = AwardEngine.evaluate(workouts: workouts,
                                         supplements: supplements,
                                         supplementLogs: supplementLogs,
                                         personalRecords: personalRecords)
        let newly = found.filter { !celebrated.contains($0.id) }
        awards = found

        guard announce, let next = newly.first else {
            // Silently mark everything as seen on the initial load.
            if !announce { celebrated = Set(found.map { $0.id }) }
            syncAwardsToServer()   // still push them up — the trainer wants the backlog
            return
        }
        // One celebration at a time; the rest are marked seen and live in the trophy case.
        awardToCelebrate = next
        celebrated = celebrated.union(newly.map { $0.id })
        syncAwardsToServer()
    }

    /// Push awards up so the trainer's console and the client's check-in can show them.
    /// Fire-and-forget: a failed sync must never block the celebration on-device.
    private func syncAwardsToServer() {
        guard isLive, !awards.isEmpty else { return }
        let snapshot = awards
        Task { try? await APIClient.shared.syncAwards(snapshot) }
    }

    // MARK: - Trainer mode
    // Same app, same login screen — the server's role decides which shell renders.
    @Published var isTrainer = false
    @Published var trainerName = ""
    @Published var roster: [RosterItem] = []
    @Published var recentAwards: [RosterAward] = []
    @Published var rosterLoading = false
    @Published var selectedClient: RosterItem?
    @Published var checkInQueue: [QueuedCheckIn] = []

    /// Total unread messages across the roster — drives the Chat tray badge.
    var totalUnread: Int { roster.map { $0.unreadMessages }.reduce(0, +) }
    /// Pending check-ins across the roster — drives the Check-In Queue badge.
    var pendingCheckInCount: Int { roster.map { $0.pendingCheckIns }.reduce(0, +) }

    /// How many people need the trainer to actually do something. Drives the badge.
    var attentionCount: Int { roster.filter { $0.needsAttention }.count }

    // Which trainer section is showing. Mirrors the client app's tray-driven nav
    // instead of a bottom tab bar, for consistency across both experiences.
    @Published var trainerTab: TrainerTab = .today

    /// Roll-up stats for the Insights screen — derived from the roster we already have,
    /// so no extra network round-trip.
    var insights: RosterInsights {
        let n = roster.count
        let trained = roster.filter { $0.daysSinceTrained <= 90 }
        let avg = trained.isEmpty ? 0 : trained.map { $0.daysSinceTrained }.reduce(0, +) / trained.count
        return RosterInsights(
            totalClients: n,
            needingAttention: roster.filter { $0.needsAttention }.count,
            drifting: roster.filter { $0.isDrifting }.count,
            workoutsThisWeek: roster.map { $0.workoutsThisWeek }.reduce(0, +),
            awardsThisWeek: recentAwards.filter {
                Calendar.current.isDate($0.earnedAt, equalTo: Date(), toGranularity: .weekOfYear)
            }.count,
            avgDaysSinceTrained: avg)
    }

    func loadRoster() {
        guard isLive, isTrainer else { return }
        rosterLoading = true
        Task {
            async let r = APIClient.shared.roster()
            async let a = APIClient.shared.recentAwards(days: 30)
            async let q = APIClient.shared.checkInQueue()
            let rows = (try? await r) ?? []
            let awards = (try? await a) ?? []
            let queue = (try? await q) ?? []
            await MainActor.run {
                self.roster = rows
                self.recentAwards = awards
                self.checkInQueue = queue
                self.rosterLoading = false
            }
        }
    }

    func logout() {
        isLoggedIn = false; showTray = false; activeTab = .dashboard
        mustChangePassword = false
        isDemoMode = false
        UserDefaults.standard.removeObject(forKey: "bst_demoMode")
        isTrainer = false
        roster = []; recentAwards = []; selectedClient = nil
        client = MockData.client   // reset identity so no stale name lingers
        UserDefaults.standard.removeObject(forKey: "bst_isTrainer")
        UserDefaults.standard.removeObject(forKey: "bst_userName")
        APIClient.shared.clearToken()   // forget the saved login
        SetMotionStore.shared.reset()   // Watch motion data belongs to whoever was signed in
        ShareLog.shared.reset()         // …and so does the record of what they shared
        WorkoutNoteStore.shared.reset() // …and their workout notes
        MacroPlanStore.shared.reset()   // …and their macro-day changes and logged activities
        ServerSync.shared.reset()       // …and anything still waiting to upload
        CoachData.shared.reset()        // coach: cached client data
        LiveSessionController.shared.endAll()   // close any workout Live Activity
        CongratsLog.shared.reset()
    }

    func clearAnnouncement(_ id: String) {
        if let i = announcements.firstIndex(where: { $0.id == id }) {
            announcements[i].cleared = true
        }
    }
    func select(_ tab: AppTab) {
        // Slide forward when moving down the tab order, back when moving up —
        // gives the app a sense of place instead of an instant swap.
        if tab != activeTab,
           let a = AppTab.allCases.firstIndex(of: activeTab),
           let b = AppTab.allCases.firstIndex(of: tab) {
            tabForward = b > a
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            activeTab = tab
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showTray = false }
    }
}

// MARK: - Navigation tabs (order matches the requested tray layout)
enum AppTab: String, CaseIterable, Identifiable {
    case dashboard   = "Home"
    case workouts    = "Workouts"
    case history     = "Stats"       // was History; case name kept so nothing else changes
    case macros      = "Macros"
    case supplements = "Supplements"
    case awards      = "Awards"
    case checkins    = "Check-Ins"
    case photos      = "Photos"
    case chat        = "Chat"
    case announcements = "Announcements"
    case share       = "Share"
    case settings    = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .workouts: return "dumbbell.fill"
        case .history: return "chart.line.uptrend.xyaxis"
        case .macros: return "chart.bar.fill"
        case .supplements: return "pills.fill"
        case .awards: return "trophy.fill"
        case .checkins: return "checkmark.seal.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .announcements: return "megaphone.fill"
        case .share: return "square.and.arrow.up.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
