import SwiftUI
import Combine
import CoreBluetooth

// MARK: - Coach HQ on iPad: Live (Oct 10, 2026)
//
// A heads-up display for a session the coach runs in person. The client's phone is the hub (its Watch
// streams to it); the phone relays over Bluetooth to this iPad — no Wi-Fi needed, range is the room.
// Protocol and messages: LiveLink.swift (shared with the phone side).
//
// Flow: the coach opens Live → phones with a workout open show up as "Nearby" → Follow sends this
// iPad's hello → the client taps Allow on their phone (once, if they keep "Always allow") → the
// session streams here: the set, each rep's bar speed against their usual, speed loss, heart rate,
// rest, PR / target watch. The coach pad sends cues (they buzz the phone), rest, start / end / log a
// set, and plan edits (saved to the server, then the phone fetches that workout again).
// Several clients at once: one chip each in the top bar.
//
// Needs (Nick adds in Xcode, not shipped): NSBluetoothAlwaysUsageDescription, and UIBackgroundModes
// `bluetooth-central` (keeps the link through a short lock). Synchronized folder: no target step needed.

// MARK: One phone

struct PadLivePhone: Identifiable {
    enum Link { case connecting, connected, lost }

    let id: UUID
    var hello: LiveHello?
    var workout: LiveWorkoutSnap?
    var state: LiveStateMsg?
    var hr: [PadLiveHR] = []
    var finished: [PadLiveSetDone] = []
    var link: Link = .connecting
    var lastHeard: Date?
    var demo = false            // made up by PadLiveDemo (no phone, no Bluetooth)
    var requestedAt: Date?      // when Follow / Ask again went out ("Asking…" until the phone answers)
    var following = false
    var ended = false
    var lastSetKey = ""
    var readySince: Date?       // the set loop came back to "Start set" (rest over): orange in the top bar after a while
    var changed: [String: String] = [:]     // set id → "WAS 225": sets you changed this session
    var notes: [PadLiveNote] = []           // notes for next time you left this session

    var name: String { hello?.name ?? "Phone nearby" }
    var allowed: Bool { hello?.allowed == true }
    var asking: Bool { hello?.asking == true }
    var clientId: String? { hello?.clientId }
}

/// A note for next time: on the client's next workout with that exercise.
struct PadLiveNote: Identifiable {
    let id = UUID()
    let exercise: String
    let text: String
    let whereTo: String         // "Tuesday · Lower A", or "your private notes on Alex"
}

struct PadLiveHR: Identifiable {
    let at: Date
    let bpm: Int
    var id: Date { at }
}

/// A set that finished while the coach was following.
struct PadLiveSetDone: Identifiable {
    let id: String
    let label: String          // "Back Squat · Set 2"
    let at: Date
    let speeds: [Double]
    let loss: Int?
    let effort: String?
}

// MARK: The iPad's side of the link

@MainActor
final class PadLiveLink: NSObject, ObservableObject {
    static let shared = PadLiveLink()

    @Published var hudOpen = false
    @Published private(set) var phones: [PadLivePhone] = []
    @Published var selected: UUID?
    @Published private(set) var radio = "Starting Bluetooth…"
    @Published private(set) var radioOK = false

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var controls: [UUID: CBCharacteristic] = [:]
    private var deframers: [UUID: LiveLinkProto.Deframer] = [:]
    private var scanning = false

    private override init() { super.init() }

    /// This iPad, as the client's phone remembers it.
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "bst_pad_live_device") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "bst_pad_live_device")
        return id
    }

    var coachName: String {
        let n = AppStore.shared.trainerName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Coach" : n
    }

    /// Clients followed before: followed again as soon as their phone shows up.
    private var autoFollow: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "bst_pad_live_follow") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "bst_pad_live_follow") }
    }

    var following: [PadLivePhone] { phones.filter { $0.following } }
    var nearby: [PadLivePhone] { phones.filter { !$0.following && $0.hello != nil } }
    var current: PadLivePhone? {
        let f = following
        if let s = selected, let p = f.first(where: { $0.id == s }) { return p }
        return f.first
    }

    // MARK: Start / stop

    /// A client to follow as soon as their phone shows up (Today's "Follow live").
    private var wantClient: String?

    func open(follow clientId: String? = nil) {
        hudOpen = true
        if let cid = clientId {
            if let p = phones.first(where: { $0.clientId == cid }) {
                if !p.following { follow(p.id) }
                selected = p.id
            } else {
                wantClient = cid
            }
        }
        start()
    }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            radio = "Bluetooth isn't set up in this build yet (Info.plist: NSBluetoothAlwaysUsageDescription)."
            radioOK = false
            return
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            scan()
        }
    }

    /// Closing Live: stop looking for new phones. Followed sessions stay linked, so reopening is instant.
    func close() {
        hudOpen = false
        if demoRunning { PadLiveDemo.shared.stopAll() }
        central?.stopScan()
        scanning = false
        for p in phones where !p.following { drop(p.id) }
    }

    private func scan() {
        guard let c = central, c.state == .poweredOn, !scanning else { return }
        // Duplicates on: a phone dropped from the list (not followed, out of range) is seen again when it's back.
        c.scanForPeripherals(withServices: [LiveLinkProto.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true
    }

    private func index(_ id: UUID) -> Int? { phones.firstIndex { $0.id == id } }

    // MARK: Following

    func follow(_ id: UUID) {
        guard let i = index(id) else { return }
        phones[i].following = true
        phones[i].ended = false
        phones[i].requestedAt = Date()
        if let cid = phones[i].clientId {
            autoFollow.insert(cid)
            Task { await PadData.shared.loadContext(cid, force: true) }    // their usual bar speed, PRs
        }
        selected = id
        send(LiveCoachHello(deviceId: Self.deviceId, coachName: coachName), to: id)
    }

    /// Ask again (they tapped Not now, or missed it).
    func askAgain(_ id: UUID) {
        if let i = index(id) { phones[i].requestedAt = Date() }
        send(LiveCoachHello(deviceId: Self.deviceId, coachName: coachName), to: id)
    }

    func unfollow(_ id: UUID) {
        guard let i = index(id) else { return }
        if phones[i].demo { PadLiveDemo.shared.remove(id) }
        if let cid = phones[i].clientId { autoFollow.remove(cid) }
        drop(id)
        if selected == id { selected = following.first?.id }
    }

    private func drop(_ id: UUID) {
        if let p = peripherals[id] { central?.cancelPeripheralConnection(p) }
        peripherals[id] = nil
        controls[id] = nil
        deframers[id] = nil
        phones.removeAll { $0.id == id }
    }

    // MARK: Sending

    func command(_ cmd: LiveCommand, to id: UUID) {
        if let i = index(id), phones[i].demo { PadLiveDemo.shared.run(cmd, id); return }
        send(cmd, to: id)
    }

    // MARK: Demo (PadLiveDemo feeds these instead of a phone)

    var demoRunning: Bool { phones.contains { $0.demo } }

    func demoAdd(_ id: UUID, hello: LiveHello, workout: LiveWorkoutSnap, hr: [PadLiveHR], finished: [PadLiveSetDone]) {
        if index(id) == nil { phones.append(PadLivePhone(id: id)) }
        guard let i = index(id) else { return }
        phones[i].demo = true
        phones[i].link = .connected
        phones[i].following = true
        phones[i].hello = hello
        phones[i].workout = workout
        phones[i].hr = hr
        phones[i].finished = finished
        if let f = finished.last { phones[i].lastSetKey = "\(f.label)|\(f.speeds.count)|\(f.speeds.first ?? 0)" }   // take() knows it already
        if selected == nil { selected = id }
    }

    /// Changes kept on the iPad for one followed phone (sets you changed, notes you left).
    func update(_ id: UUID, _ f: (inout PadLivePhone) -> Void) {
        guard let i = index(id) else { return }
        f(&phones[i])
    }

    func demoUpdate(_ id: UUID, workout: LiveWorkoutSnap?, state: LiveStateMsg) {
        guard let i = index(id) else { return }
        if let w = workout { phones[i].workout = w }
        take(state, at: i)
    }


    private func send<T: Encodable>(_ msg: T, to id: UUID) {
        guard let p = peripherals[id], let ch = controls[id], let body = try? LiveLinkProto.encoder.encode(msg) else { return }
        let data = LiveLinkProto.frame(body)
        let size = Swift.max(20, Swift.min(512, p.maximumWriteValueLength(for: .withResponse)))
        var i = 0
        while i < data.count {
            let end = Swift.min(data.count, i + size)
            p.writeValue(data.subdata(in: i..<end), for: ch, type: .withResponse)    // in order, acknowledged
            i = end
        }
    }

    // MARK: Receiving

    private func receive(_ chunk: Data, from id: UUID) {
        var d = deframers[id] ?? LiveLinkProto.Deframer()
        let msgs = d.push(chunk)
        deframers[id] = d
        for m in msgs { handle(m, from: id) }
    }

    private func handle(_ data: Data, from id: UUID) {
        guard let i = index(id),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return }
        phones[i].lastHeard = Date()
        let dec = LiveLinkProto.decoder
        switch t {
        case "hello":
            guard let h = try? dec.decode(LiveHello.self, from: data) else { return }
            // The same client under a new Bluetooth id (the phone's private address rotated): keep one entry.
            var carried = false
            if let old = phones.first(where: { $0.id != id && $0.clientId == h.clientId }) {
                carried = old.following
                if selected == old.id { selected = id }
                drop(old.id)
            }
            guard let j = index(id) else { return }
            let was = phones[j].hello
            phones[j].hello = h
            if h.asking == true || h.allowed { phones[j].requestedAt = nil }
            if !phones[j].following, carried || autoFollow.contains(h.clientId) || wantClient == h.clientId {
                if wantClient == h.clientId { wantClient = nil }
                follow(id)
            }
            if h.allowed, was?.allowed != true { Task { await PadData.shared.loadContext(h.clientId) } }
            if let k = index(id) { phones[k].ended = (h.workoutId == nil) }
        case "workout":
            guard let w = try? dec.decode(LiveWorkoutSnap.self, from: data) else { return }
            if let old = phones[i].workout?.id, old != w.id {          // their next workout: start fresh
                phones[i].state?.lastSet = nil
                phones[i].changed = [:]
                phones[i].finished = []
                phones[i].hr = []
                phones[i].lastSetKey = ""
            }
            phones[i].workout = w
        case "state":
            guard let s = try? dec.decode(LiveStateMsg.self, from: data) else { return }
            take(s, at: i)
        case "bye":
            phones[i].ended = true
        default:
            break
        }
    }

    private func take(_ sIn: LiveStateMsg, at i: Int) {
        // The phone sends the last set's reps only when they change: keep the ones we have.
        var s: LiveStateMsg = sIn
        if s.lastSet == nil { s.lastSet = phones[i].state?.lastSet }
        let was: LiveStage? = phones[i].state?.card.stage
        if s.card.stage == .ready, was != .ready { phones[i].readySince = s.at }
        if s.card.stage != .ready { phones[i].readySince = nil }
        phones[i].state = s
        phones[i].ended = false
        if let b = s.hr, b > 0 {
            let last = phones[i].hr.last
            if last == nil || s.at.timeIntervalSince(last!.at) >= 4 || last!.bpm != b {
                phones[i].hr.append(PadLiveHR(at: s.at, bpm: b))
            }
            let cutoff = Date().addingTimeInterval(-45 * 60)
            if let first = phones[i].hr.first, first.at < cutoff { phones[i].hr.removeAll { $0.at < cutoff } }
        }
        // A set the Watch measured has finished: keep it for the session list.
        let c = s.card
        if let label = c.lastSet, !c.speeds.isEmpty {
            let key = "\(label)|\(c.speeds.count)|\(c.speeds.first ?? 0)"
            if key != phones[i].lastSetKey {
                phones[i].lastSetKey = key
                phones[i].finished.removeAll { $0.label == label }
                phones[i].finished.append(PadLiveSetDone(id: key, label: label, at: s.at, speeds: c.speeds,
                                                         loss: c.speedLoss, effort: c.effort))
            }
        }
    }

    // MARK: Delegate plumbing (main queue: the manager was made with queue nil)

    fileprivate func found(_ p: CBPeripheral) {
        guard peripherals[p.identifier] == nil, let c = central else { return }
        peripherals[p.identifier] = p
        p.delegate = self
        if index(p.identifier) == nil { phones.append(PadLivePhone(id: p.identifier)) }
        c.connect(p, options: nil)
    }

    fileprivate func lost(_ p: CBPeripheral) {
        let id = p.identifier
        controls[id] = nil
        deframers[id] = nil
        guard let i = index(id) else { return }
        if phones[i].following {
            phones[i].link = .lost
            central?.connect(p, options: nil)          // waits as long as it takes; picks up when they're back in range
        } else {
            drop(id)                                    // seen again on the next scan
        }
    }

    fileprivate func radioChanged(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            radioOK = true
            radio = "Looking for phones nearby"
            scanning = false
            if hudOpen { scan() }
            for (_, p) in peripherals where p.state == .disconnected { c.connect(p, options: nil) }
        case .poweredOff:
            radioOK = false; scanning = false
            radio = "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized:
            radioOK = false
            radio = "Bluetooth isn't allowed for Big Scherly. Settings ▸ Privacy ▸ Bluetooth."
        case .unsupported:
            radioOK = false
            radio = "This iPad doesn't support Bluetooth LE."
        default:
            radioOK = false
            radio = "Starting Bluetooth…"
        }
    }

    fileprivate func connected(_ p: CBPeripheral) {
        if let i = index(p.identifier) { phones[i].link = .connecting }
        p.discoverServices([LiveLinkProto.service])
    }

    fileprivate func characteristics(_ p: CBPeripheral, _ s: CBService) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == LiveLinkProto.stateChar { p.setNotifyValue(true, for: ch) }
            if ch.uuid == LiveLinkProto.controlChar { controls[p.identifier] = ch }
        }
    }

    fileprivate func subscribed(_ p: CBPeripheral) {
        guard let i = index(p.identifier) else { return }
        phones[i].link = .connected
        // Back in range after a drop: say hello again (a remembered iPad is let straight back in).
        if phones[i].following { send(LiveCoachHello(deviceId: Self.deviceId, coachName: coachName), to: p.identifier) }
    }

    fileprivate func value(_ p: CBPeripheral, _ data: Data) { receive(data, from: p.identifier) }
}

extension PadLiveLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.radioChanged(central) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { self.found(peripheral) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.connected(peripheral) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.lost(peripheral) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.lost(peripheral) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] where s.uuid == LiveLinkProto.service {
                peripheral.discoverCharacteristics([LiveLinkProto.stateChar, LiveLinkProto.controlChar], for: s)
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.characteristics(peripheral, service) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let on = characteristic.isNotifying && error == nil
        MainActor.assumeIsolated { if on { self.subscribed(peripheral) } }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let d = characteristic.value else { return }
        MainActor.assumeIsolated { self.value(peripheral, d) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated { self.connected(peripheral) }      // the phone rebuilt its service: find it again
    }
}

// MARK: - Maths for the screen

enum PadLiveMath {
    /// Their usual bar speed for this lift near this weight (±7.5%), from earlier sessions' Watch data.
    @MainActor
    static func usualSpeed(clientId: String, exercise: String, weightLb: Double, excluding workoutId: String?) -> Double? {
        if clientId.hasPrefix(PadLiveDemo.prefix) { return PadLiveDemo.usual(exercise) }
        let data = PadData.shared
        let ws = (data.workouts[clientId] ?? []).filter { $0.id != workoutId }
        var weightBySet: [String: Double] = [:]
        for w in ws {
            for e in w.exercises where e.name.lowercased() == exercise.lowercased() {
                for s in e.sets { if let lw = s.loggedWeight { weightBySet[s.id] = lw } }
            }
        }
        let motions = (data.motion[clientId] ?? []).filter { $0.exerciseName.lowercased() == exercise.lowercased() && $0.workoutId != workoutId }
        var near: [Double] = []
        var any: [Double] = []
        for m in motions {
            guard let first = m.reps.first else { continue }
            any.append(first.meanVelocity)
            if weightLb > 0, let lw = weightBySet[m.setId], abs(lw - weightLb) <= weightLb * 0.075 { near.append(first.meanVelocity) }
        }
        let pick: [Double] = near.count >= 2 ? near : (weightLb <= 0 ? any : [])
        guard !pick.isEmpty else { return nil }
        let sorted = pick.sorted()
        return sorted[sorted.count / 2]
    }

    /// Best estimated 1RM for the lift before today.
    @MainActor
    static func bestE1RM(clientId: String, exercise: String, excluding workoutId: String?) -> Double? {
        if clientId.hasPrefix(PadLiveDemo.prefix) { return PadLiveDemo.best(exercise) }
        let ws = (PadData.shared.workouts[clientId] ?? []).filter { $0.id != workoutId }
        let best = ProgressEngine.history(for: exercise, workouts: ws).map { $0.estimatedOneRepMax }.max() ?? 0
        return best > 0 ? best : nil
    }

    static func e1RM(_ lb: Double, _ reps: Int) -> Double { lb * (1 + Double(reps) / 30.0) }

    /// The plan for a set, as written. (SetTarget would look up "you pick" weights in this iPad's own
    /// store — the coach's, not the client's.)
    static func planText(_ s: ExerciseSet) -> String {
        let w: String = SetTarget.weightText(s.targetWeight)
        if let r = s.targetRpe { return s.targetWeight > 0 ? "\(s.targetReps) × \(w) @ \(r.rpeText)" : "\(s.targetReps) @ RPE \(r.rpeText)" }
        if let pct = s.percent { return "\(s.targetReps) × " + SetTarget.percentText(pct) }
        if s.amrap == true { return s.targetWeight > 0 ? "\(s.targetReps)+ × \(w)" : "\(s.targetReps)+ reps" }
        if s.targetWeight <= 0 { return "\(s.targetReps) × BW" }
        return "\(s.targetReps) × \(w)"
    }

    static func clock(_ s: Int) -> String {
        let t = max(0, s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func zoneColor(_ z: Int?) -> Color {
        switch z ?? 0 {
        case 5: return Pad.red
        case 4: return Pad.orange
        case 3: return Pad.volt
        case 2: return Pad.green
        default: return Pad.blue
        }
    }
}

/// Wraps its children onto new lines (cue chips, rest buttons).
struct PadLiveFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW: CGFloat = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Hosts the Live cover for the shell. Its own view, so the shell doesn't redraw with every update
/// from a followed phone (a couple a second) — only this does.
struct PadLiveHost: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var link = PadLiveLink.shared
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(isPresented: $link.hudOpen) { PadLiveView().environmentObject(store) }
    }
}
