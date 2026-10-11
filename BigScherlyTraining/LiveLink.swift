import Foundation
import CoreBluetooth
import Combine
import UserNotifications
import SwiftUI

// MARK: - Live link: the client's phone → the coach's iPad, in the room (Oct 10, 2026)
//
// The coach's iPad is a heads-up display for a session they're running in person. The phone is the
// hub (the Watch already streams to it); this relays what it has — the live card's state, the reps
// as they land, heart rate, the plan — to the iPad over Bluetooth, and takes the coach's moves
// back (a cue, rest, start/end set, reload the plan after the coach changed it).
//
// Why Bluetooth and not Wi-Fi: during a workout the phone is in a pocket, screen off. iOS suspends
// the app within seconds, and a Wi-Fi socket dies with it. With the `bluetooth-peripheral`
// background mode iOS keeps the app running for as long as a central is connected — and no
// network is needed at all, which suits a gym. Range is the room.
//
// Needs two Info.plist keys (Nick adds them in Xcode; this file refuses to start without the first):
//   NSBluetoothAlwaysUsageDescription  — "Big Scherly Training shows your live session on your coach's iPad when you train together."
//   UIBackgroundModes                  — add `bluetooth-peripheral` (the phone), `bluetooth-central` (the iPad)
//
// Framing: every message is 4 bytes big-endian length + JSON, split into chunks the size the link
// allows. Same file is compiled for the iPad (CoachPad reads these models and the deframer).
// Lives in the app folder (added automatically).

nonisolated enum LiveLinkProto {
    static let service = CBUUID(string: "B5721A10-5C8E-4B3A-9F1E-2C0D6A7E4B01")
    static let stateChar = CBUUID(string: "B5721A11-5C8E-4B3A-9F1E-2C0D6A7E4B01")     // phone → iPad, notify
    static let controlChar = CBUUID(string: "B5721A12-5C8E-4B3A-9F1E-2C0D6A7E4B01")   // iPad → phone, write
    static let version = 1

    static func frame(_ body: Data) -> Data {
        var n = UInt32(body.count).bigEndian
        var d = Data(bytes: &n, count: 4)
        d.append(body)
        return d
    }

    /// Collects chunks into whole messages.
    struct Deframer {
        private var buf = Data()
        mutating func push(_ chunk: Data) -> [Data] {
            buf.append(chunk)
            var out: [Data] = []
            while buf.count >= 4 {
                // Data's indices needn't start at 0 (a slice keeps its parent's): always work from startIndex,
                // and re-base what's left to a fresh Data.
                let s = buf.startIndex
                let n = Int(buf[s..<(s + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard n < 2_000_000 else { buf = Data(); break }
                guard buf.count >= 4 + n else { break }
                out.append(Data(buf[(s + 4)..<(s + 4 + n)]))
                buf = buf.count == 4 + n ? Data() : Data(buf[(s + 4 + n)...])
            }
            return out
        }
        mutating func reset() { buf = Data() }
    }

    // Milliseconds, not ISO 8601 (which drops fractions: the rest countdown would be up to a second off).
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }
}

// MARK: Messages

/// What the phone says first, and whenever the plan changes.
nonisolated struct LiveHello: Codable {
    var t = "hello"
    var version = LiveLinkProto.version
    var clientId: String
    var name: String
    var allowed: Bool            // false while the client hasn't allowed this iPad yet
    var asking: Bool? = nil      // true: the Allow / Not now card is up on the phone right now
    var workoutId: String?
}

/// The coach's iPad introducing itself.
nonisolated struct LiveCoachHello: Codable {
    var t = "coach"
    var deviceId: String         // the iPad, remembered once allowed
    var coachName: String
}

/// The plan, as the phone has it (logged values included).
nonisolated struct LiveWorkoutSnap: Codable {
    var t = "workout"
    var id: String
    var title: String
    var date: Date
    var completed: Bool
    var exercises: [LiveExerciseSnap]

    @MainActor init(_ w: Workout) {
        id = w.id; title = w.title; date = w.date; completed = w.completed
        exercises = w.exercises.map { LiveExerciseSnap($0) }
    }
}

nonisolated struct LiveExerciseSnap: Codable, Identifiable {
    var id: String
    var name: String
    var muscleGroup: String
    var description: String
    var coachNotes: String
    var clientNotes: String
    var restSeconds: Int
    var sets: [LiveSetSnap]
    @MainActor init(_ e: Exercise) {
        id = e.id; name = e.name; muscleGroup = e.muscleGroup; description = e.description; coachNotes = e.coachNotes
        clientNotes = e.clientNotes; restSeconds = e.restSeconds
        sets = e.sets.map { LiveSetSnap($0) }
    }
}

nonisolated struct LiveSetSnap: Codable, Identifiable {
    var id: String
    var targetReps: Int
    var targetWeight: Double
    var targetRpe: Double?
    var percent: Double?
    var amrap: Bool?
    var loggedReps: Int?
    var loggedWeight: Double?
    var rpe: Double?
    var loggedAt: Date?
    @MainActor init(_ s: ExerciseSet) {
        id = s.id; targetReps = s.targetReps; targetWeight = s.targetWeight; targetRpe = s.targetRpe; percent = s.percent
        amrap = s.amrap; loggedReps = s.loggedReps; loggedWeight = s.loggedWeight; rpe = s.rpe; loggedAt = s.loggedAt
    }
}

/// The live picture, about once a second while something's happening: the Lock Screen card's state
/// (already built by the session controller), plus the reps of the set in progress and the heart rate.
nonisolated struct LiveStateMsg: Codable {
    var t = "state"
    var at: Date
    var card: WorkoutActivityAttributes.ContentState
    var liveReps: [RepMotion]
    var hr: Int?
    var watchLive: Bool
    var elapsedSince: Date
    var lastSet: LiveLastSet? = nil      // the latest set with Watch data, rep by rep (the Coach notes window)
}

/// The latest set the Watch measured: which set, and its reps.
nonisolated struct LiveLastSet: Codable {
    var exerciseId: String
    var setId: String
    var setNumber: Int
    var reps: [RepMotion]
}

/// The coach's moves. One struct, so the phone can ignore kinds it doesn't know.
nonisolated struct LiveCommand: Codable {
    var t: String                // cue · rest · addRest · skipRest · startSet · endSet · logSet · reload · ping
    var text: String? = nil
    var seconds: Int? = nil
}

nonisolated struct LiveBye: Codable { var t = "bye" }

extension LiveWorkoutSnap {
    /// Back into the app's own model, so the iPad can use the same set texts (SetTarget) as everywhere else.
    @MainActor func toModel() -> Workout {
        Workout(id: id, title: title, date: date, exercises: exercises.map { e in
            Exercise(id: e.id, name: e.name, muscleGroup: e.muscleGroup, description: e.description, coachNotes: e.coachNotes,
                     sets: e.sets.map { st in
                         ExerciseSet(id: st.id, targetReps: st.targetReps, targetWeight: st.targetWeight,
                                     loggedReps: st.loggedReps, loggedWeight: st.loggedWeight, rpe: st.rpe, loggedAt: st.loggedAt,
                                     targetRpe: st.targetRpe, percent: st.percent, amrap: st.amrap)
                     },
                     clientNotes: e.clientNotes, restSeconds: e.restSeconds)
        }, completed: completed)
    }
}

// MARK: The phone's side

@MainActor
final class LiveLink: NSObject, ObservableObject {
    static let shared = LiveLink()

    @Published private(set) var state = "Off"
    @Published private(set) var connected = false
    @Published private(set) var coachName = ""
    /// Sets the coach changed from the iPad this session: set id → "WAS 225 LB" (the set card says so).
    @Published private(set) var changed: [String: String] = [:]
    private var originals: [String: ExerciseSet] = [:]     // a changed set as it was, so an Undo clears the label
    private var lastSetKey = ""                             // the last set's reps go to the iPad only when they change
    private var statesSinceLastSet = 0
    /// A coach's iPad asking to watch; the workout screen shows Allow / Not now.
    @Published var pendingCoach: LiveCoachHello?
    /// The latest cue from the coach, shown as a banner on the workout screen.
    @Published var cue: (text: String, at: Date)?

    private var manager: CBPeripheralManager?
    private var stateChar: CBMutableCharacteristic?
    private var central: CBCentral?
    private var allowedDevice: String?
    private var deframer = LiveLinkProto.Deframer()
    private struct Outgoing { var chunks: [Data]; var isState: Bool; var sent = 0 }
    private var queue: [Outgoing] = []       // messages waiting for the link to be ready
    private var subs = Set<AnyCancellable>()
    private var stateTask: Task<Void, Never>?
    private var advertising = false
    private var lastSnap: Data?

    private override init() { super.init() }

    /// Allowed coaches, by iPad id (set once the client taps Allow and keeps it).
    private var rememberedDevices: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "bst_live_coach_devices") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "bst_live_coach_devices") }
    }
    /// Settings ▸ Coach ▸ Show my sessions on the coach's iPad (on by default).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "bst_live_coach") as? Bool ?? true }

    /// Starts advertising while a workout is open. Safe to call often.
    func start() {
        guard Self.enabled else { state = "Off"; return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            state = "Needs the Bluetooth permission text in Info.plist"
            return
        }
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            observe()
        }
        advertiseIfNeeded()
    }

    /// The workout closed. The iPad stays subscribed (the next workout reaches it with no new handshake);
    /// it's told this one's over.
    func stop() {
        changed = [:]
        originals = [:]
        lastSetKey = ""
        manager?.stopAdvertising()
        advertising = false
        stateTask?.cancel(); stateTask = nil
        if central != nil { sendHello(); send(LiveBye()) }      // workoutId is nil now: the iPad marks it ended
        state = connected ? "Coach's iPad connected" : "Off"
    }

    private func observe() {
        let live = LiveSessionController.shared
        live.$workoutId.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.advertiseIfNeeded(); self?.sendHello(); self?.sendSnapshot(force: true); self?.scheduleState(now: true) }
            .store(in: &subs)
        live.$revision.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleState(now: false) }
            .store(in: &subs)
        WatchBridge.shared.$liveRepMotions.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleState(now: true) }
            .store(in: &subs)
        WatchBridge.shared.$liveHeartRate.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleState(now: false) }
            .store(in: &subs)
        AppStore.shared.$workouts.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendSnapshot() }
            .store(in: &subs)
    }

    private func advertiseIfNeeded() {
        guard let m = manager, m.state == .poweredOn else { return }
        let wantsOn = LiveSessionController.shared.workoutId != nil && Self.enabled
        if wantsOn && !advertising {
            m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [LiveLinkProto.service],
                                CBAdvertisementDataLocalNameKey: "BST"])
            advertising = true
            if !connected { state = "Visible to your coach's iPad" }
        } else if !wantsOn && advertising {
            m.stopAdvertising()
            advertising = false
            if !connected { state = "Off" }
        }
    }

    // MARK: Consent

    func allow(_ coach: LiveCoachHello, remember: Bool) {
        if remember { rememberedDevices.insert(coach.deviceId) }
        allowedDevice = coach.deviceId
        coachName = coach.coachName
        pendingCoach = nil
        state = "\(coach.coachName) is watching"
        sendHello()
        sendSnapshot(force: true)
        lastSetKey = ""                                     // the new iPad gets the last set's reps too
        scheduleState(now: true)
    }

    func deny(_ coach: LiveCoachHello) {
        pendingCoach = nil
        allowedDevice = nil
        coachName = ""
        state = "Coach's iPad connected"
        sendHello()
    }

    func forgetCoaches() { rememberedDevices = []; allowedDevice = nil }

    private var allowed: Bool { allowedDevice != nil }
    /// Streaming to the coach's iPad right now (the client allowed it).
    var isAllowed: Bool { allowedDevice != nil && connected }

    // MARK: Sending

    private func send<T: Encodable>(_ msg: T, isState: Bool = false) {
        guard central != nil, let body = try? LiveLinkProto.encoder.encode(msg) else { return }
        enqueue(LiveLinkProto.frame(body), isState: isState)
    }

    private func enqueue(_ data: Data, isState: Bool = false) {
        guard let c = central else { return }
        let size = Swift.max(20, c.maximumUpdateValueLength)
        var chunks: [Data] = []
        var i = 0
        while i < data.count {
            let end = Swift.min(data.count, i + size)
            chunks.append(data.subdata(in: i..<end))
            i = end
        }
        // A newer picture replaces older ones still waiting (never one already part-sent): the iPad
        // gets the latest, not a backlog.
        if isState { queue.removeAll { $0.isState && $0.sent == 0 } }
        queue.append(Outgoing(chunks: chunks, isState: isState))
        drain()
    }

    private func drain() {
        guard let m = manager, let ch = stateChar, let c = central else { queue.removeAll(); return }
        while !queue.isEmpty {
            if queue[0].sent >= queue[0].chunks.count { queue.removeFirst(); continue }
            let chunk = queue[0].chunks[queue[0].sent]
            if m.updateValue(chunk, for: ch, onSubscribedCentrals: [c]) { queue[0].sent += 1 } else { break }   // resumes in peripheralManagerIsReady
        }
    }

    private func sendHello() {
        let store = AppStore.shared
        send(LiveHello(clientId: store.client.id, name: store.client.name, allowed: allowed,
                       asking: pendingCoach != nil, workoutId: LiveSessionController.shared.workoutId))
    }

    private func sendSnapshot(force: Bool = false) {
        guard allowed, let wid = LiveSessionController.shared.workoutId,
              let w = AppStore.shared.workouts.first(where: { $0.id == wid }),
              let body = try? LiveLinkProto.encoder.encode(LiveWorkoutSnap(w)) else { return }
        if !force, body == lastSnap { return }
        lastSnap = body
        enqueue(LiveLinkProto.frame(body))
    }

    /// The live picture, coalesced to about 2 a second (a rep landing goes now).
    private func scheduleState(now: Bool) {
        guard allowed, central != nil else { return }
        if !now, stateTask != nil { return }
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled, let self else { return }
            self.stateTask = nil
            self.sendState()
        }
    }

    private func sendState() {
        guard allowed, let card = LiveSessionController.shared.cardStateForLink() else { return }
        let wb = WatchBridge.shared
        let live = LiveSessionController.shared
        var last: LiveLastSet? = nil
        if let wid = live.workoutId, let w = AppStore.shared.workouts.first(where: { $0.id == wid }), let m = live.lastSetMotion(w) {
            // Only when it changed (or every 20th update, in case one went missing): it's a few KB.
            let key: String = "\(m.1.id)|\(m.3.reps.count)"
            statesSinceLastSet += 1
            if key != lastSetKey || statesSinceLastSet >= 20 {
                last = LiveLastSet(exerciseId: m.0.id, setId: m.1.id, setNumber: m.2, reps: m.3.reps)
                lastSetKey = key
                statesSinceLastSet = 0
            }
        }
        send(LiveStateMsg(at: Date(), card: card, liveReps: wb.liveRepMotions, hr: wb.liveHeartRate,
                          watchLive: wb.watchSessionLive, elapsedSince: live.elapsedSinceForLink(), lastSet: last),
             isState: true)
    }

    // MARK: Receiving

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["t"] as? String else { return }
        switch t {
        case "coach":
            guard let hello = try? LiveLinkProto.decoder.decode(LiveCoachHello.self, from: data) else { return }
            if rememberedDevices.contains(hello.deviceId) || allowedDevice == hello.deviceId {
                allow(hello, remember: false)
            } else {
                pendingCoach = hello
                coachName = hello.coachName
                state = "\(hello.coachName) wants to watch"
                sendHello()
                askOnLockScreen(hello)
            }
        default:
            guard allowed, let cmd = try? LiveLinkProto.decoder.decode(LiveCommand.self, from: data) else { return }
            run(cmd)
        }
    }

    private func run(_ cmd: LiveCommand) {
        let live = LiveSessionController.shared
        switch cmd.t {
        case "cue":
            guard let text = cmd.text, !text.isEmpty else { return }
            cue = (text, Date())
            notifyCue(text)
            live.touchFromLink()
        case "rest": live.startRest(max(10, cmd.seconds ?? 90))                 // rest this long, from now
        case "addRest": Task { await live.handle(.rest(seconds: cmd.seconds ?? 30)) }   // more on the running rest
        case "skipRest": Task { await live.handle(.rest(seconds: 0)) }
        case "startSet": Task { await live.handle(.startSet) }
        case "endSet": Task { await live.handle(.log("end")) }
        case "logSet": Task { await live.handle(.log("commit")) }              // the filled-in set (Watch's reps)
        case "reload": reloadWorkout()
        case "ping": scheduleState(now: true)
        default: break
        }
    }

    /// The coach changed the plan on the iPad: fetch this one workout again. Anything logged here that
    /// the server doesn't have yet is kept (the server copy wins for everything the coach can change).
    private func reloadWorkout() {
        guard let wid = LiveSessionController.shared.workoutId, AppStore.shared.isLive else { return }
        Task { @MainActor in
            guard let full = try? await APIClient.shared.workout(wid) else { return }
            var fresh = full.toModel()
            let store = AppStore.shared
            guard let i = store.workouts.firstIndex(where: { $0.id == wid }) else { return }
            let old = store.workouts[i]
            var logged: [String: ExerciseSet] = [:]
            var before: [String: ExerciseSet] = [:]
            for e in old.exercises { for st in e.sets { before[st.id] = st; if st.loggedReps != nil { logged[st.id] = st } } }
            // What the coach changed, for "Coach changed it · was 225" on the set card (and cleared by an Undo).
            for e in fresh.exercises {
                for st in e.sets where st.loggedReps == nil {
                    guard let b = before[st.id] else { continue }
                    let first: ExerciseSet = originals[st.id] ?? b
                    let same: Bool = first.targetReps == st.targetReps && abs(first.targetWeight - st.targetWeight) < 0.01
                        && first.percent == st.percent && first.amrap == st.amrap && first.targetRpe == st.targetRpe
                    if same {
                        changed[st.id] = nil; originals[st.id] = nil
                    } else if changed[st.id] == nil {
                        originals[st.id] = b
                        changed[st.id] = "WAS " + SetTarget.text(b, in: e).uppercased()
                    }
                }
            }
            for ei in fresh.exercises.indices {
                for si in fresh.exercises[ei].sets.indices {
                    let id = fresh.exercises[ei].sets[si].id
                    guard fresh.exercises[ei].sets[si].loggedReps == nil, let l = logged[id] else { continue }
                    fresh.exercises[ei].sets[si].loggedReps = l.loggedReps
                    fresh.exercises[ei].sets[si].loggedWeight = l.loggedWeight
                    fresh.exercises[ei].sets[si].rpe = l.rpe
                    fresh.exercises[ei].sets[si].loggedAt = l.loggedAt
                }
            }
            fresh.completed = old.completed || fresh.completed
            store.workouts[i] = fresh
            LiveSessionController.shared.planChangedFromLink()
            cue = ("Plan updated — check your next set.", Date())
        }
    }

    /// A cue while the phone's in a pocket: a notification, so it buzzes and shows on the Lock Screen.
    private func notifyCue(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = coachName.isEmpty ? "Coach" : coachName
        c.body = text
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bst-cue-" + UUID().uuidString, content: c, trigger: nil))
    }

    private func askOnLockScreen(_ hello: LiveCoachHello) {
        let c = UNMutableNotificationContent()
        c.title = "\(hello.coachName)'s iPad wants to watch this session"
        c.body = "Open the workout to allow it."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bst-live-ask", content: c, trigger: nil))
    }
}

extension LiveLink: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                let ch = CBMutableCharacteristic(type: LiveLinkProto.stateChar, properties: [.notify], value: nil, permissions: [.readable])
                let ctl = CBMutableCharacteristic(type: LiveLinkProto.controlChar, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
                let svc = CBMutableService(type: LiveLinkProto.service, primary: true)
                svc.characteristics = [ch, ctl]
                self.stateChar = ch
                peripheral.removeAllServices()
                peripheral.add(svc)
                self.advertiseIfNeeded()
            case .poweredOff: self.state = "Bluetooth is off"; self.advertising = false; self.connected = false
            case .unauthorized: self.state = "Bluetooth isn't allowed for the app"
            default: break
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            if self.central?.identifier != central.identifier {        // a different iPad: its own consent
                self.allowedDevice = nil; self.pendingCoach = nil; self.lastSnap = nil
            }
            self.central = central
            self.connected = true
            self.deframer.reset()
            self.queue.removeAll()
            self.state = "Coach's iPad connected"
            self.sendHello()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            guard self.central?.identifier == central.identifier else { return }   // another iPad's leaving
            self.central = nil
            self.connected = false
            self.allowedDevice = nil
            self.pendingCoach = nil
            self.queue.removeAll()
            self.state = self.advertising ? "Visible to your coach's iPad" : "Off"
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in self.drain() }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        var chunks: [(UUID, Data)] = []
        for r in requests where r.characteristic.uuid == LiveLinkProto.controlChar {
            if let v = r.value { chunks.append((r.central.identifier, v)) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        // Delivered on the main queue (the manager was made with queue nil): handled in order, now.
        // Only the subscribed iPad's writes count.
        MainActor.assumeIsolated {
            for (id, c) in chunks where id == self.central?.identifier {
                for msg in self.deframer.push(c) { self.handle(msg) }
            }
        }
    }
}

// MARK: - On the workout screen (the client's phone)

/// Under the workout title: the coach's iPad asking to watch (Allow / Not now), the link's state
/// once it's up, and the coach's latest cue.
struct LiveLinkBanner: View {
    @ObservedObject private var link = LiveLink.shared
    @State private var remember = true
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coach = link.pendingCoach { ask(coach) }
            if let cue = link.cue, now.timeIntervalSince(cue.at) < 180 { cueCard(cue.text) }
            if link.isAllowed, link.pendingCoach == nil, !link.coachName.isEmpty { livePill }
        }
        .onReceive(tick) { t in
            now = t
            if let c = link.cue, t.timeIntervalSince(c.at) >= 180 { link.cue = nil }   // a cue fades after 3 minutes
        }
        .onChange(of: link.cue?.at) { _, _ in now = Date() }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: link.pendingCoach?.deviceId)
    }

    private func ask(_ coach: LiveCoachHello) -> some View {
        let title: String = "\(coach.coachName)'s iPad wants to follow this session"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "ipad.landscape").font(.system(size: 15, weight: .semibold)).foregroundColor(Brand.voltText)
                Text(title).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
            }
            Text("Your sets, reps, bar speed and heart rate show on their screen while you train together. Nothing leaves the room — it's Bluetooth, phone to iPad.")
                .font(BrandFont.body(13)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $remember) {
                Text("Always allow this iPad").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
            }
            .tint(Brand.volt)
            HStack(spacing: 10) {
                Button { link.deny(coach) } label: {
                    Text("Not now").font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                }
                Button { link.allow(coach, remember: remember) } label: {
                    Text("Allow").font(BrandFont.body(14, .bold)).foregroundColor(Brand.onVolt)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1))
    }

    private func cueCard(_ text: String) -> some View {
        let from: String = link.coachName.isEmpty ? "COACH" : link.coachName.uppercased()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "megaphone.fill").font(.system(size: 14, weight: .semibold)).foregroundColor(Brand.onVolt)
                .frame(width: 30, height: 30).background(Circle().fill(Brand.volt))
            VStack(alignment: .leading, spacing: 3) {
                Text(from).font(BrandFont.body(11, .bold)).tracking(1.2).foregroundColor(Brand.mute)
                Text(text).font(BrandFont.body(17, .bold)).foregroundColor(Brand.text).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { link.cue = nil } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.mute).padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss cue")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine, lineWidth: 1))
    }

    private var livePill: some View {
        let label: String = "Live on \(link.coachName)'s iPad"
        return HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text(label).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
        }
    }
}
