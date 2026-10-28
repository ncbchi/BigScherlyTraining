import SwiftUI
import AVFoundation
import Combine

// MARK: - Gym session (DEVELOPER TOOL — removed before release)
// A calibration block run entirely on the phone: no Mac, nobody watching live. Pick a block, prop the
// phone side-on, tap Start. The phone talks you through every part out loud (what to do, Go, rest,
// what's next), checks the camera can see you, counts your reps on camera, and moves on when you tap
// the Watch — or by itself once you've stood still for 8 seconds after your reps (free training:
// only the Watch tap). At the end it
// writes ONE file to the Auto-save folder ("GYM …"), with the Watch at its full 50 Hz, for Claude
// to review afterwards. Every cue also goes to the Watch: it buzzes and shows what to do now
// (Go, the rest countdown, what's next), so you don't need to look at or hear the phone. Nothing is written to iCloud during the session (a private checkpoint
// on the phone covers a crash; it's recovered the next time you open Motion captures).
//
// Lives in the app folder (added automatically).

struct GymPart: Identifiable {
    let id: String
    let name: String
    let say: String
    let reps: Int                       // 0 = a non-rep part (timed, 20 s); -1 = free set
}

struct GymBlock: Identifiable {
    let id: String
    let title: String
    let lift: PhoneDebugRecorder.Lift
    let setup: String
    let parts: [GymPart]
    var free: Bool { parts.isEmpty }

    static let all: [GymBlock] = [press, bench, deadlift, free]

    static let press = GymBlock(id: "A", title: "Overhead press", lift: .press,
        setup: "Stand side-on to the camera, whole body in view.", parts: [
        GymPart(id: "A1", name: "Normal ×5", say: "Five normal reps, your usual speed.", reps: 5),
        GymPart(id: "A2", name: "Fast ×5", say: "Five fast reps. Drive them up hard.", reps: 5),
        GymPart(id: "A3", name: "Slow ×5", say: "Five slow reps. Four seconds up, four seconds down.", reps: 5),
        GymPart(id: "A4", name: "Holds ×4", say: "Four reps. Hold each one at the top for two seconds.", reps: 4),
        GymPart(id: "A5", name: "Half reps ×5", say: "Five half reps. Only the top half of the press.", reps: 5),
        GymPart(id: "A6", name: "3, pause, 3", say: "Three reps, stand still for three seconds, then three more.", reps: 6),
        GymPart(id: "A7", name: "Fading ×8", say: "Eight reps, getting slower each time, like the end of a hard set.", reps: 8),
        GymPart(id: "A8", name: "Not reps", say: "Not reps. For twenty seconds, adjust your grip, roll your shoulders, shift your feet. No pressing.", reps: 0),
    ])

    static let bench = GymBlock(id: "C", title: "Bench press", lift: .bench,
        setup: "Lie down and get set before you start. Phone on the floor about two metres away, tilted up at you.", parts: [
        GymPart(id: "C1", name: "Normal ×5", say: "Five normal reps, your usual speed.", reps: 5),
        GymPart(id: "C2", name: "Fast ×5", say: "Five fast reps.", reps: 5),
        GymPart(id: "C3", name: "Slow ×4", say: "Four slow reps. Four seconds down, four seconds up.", reps: 4),
        GymPart(id: "C4", name: "Chest pauses ×4", say: "Four reps. Pause two seconds on your chest each time.", reps: 4),
        GymPart(id: "C5", name: "Half reps ×5", say: "Five half reps. Only the top half.", reps: 5),
        GymPart(id: "C6", name: "Touch and go ×5", say: "Five touch and go reps. Quick turnaround at the chest.", reps: 5),
        GymPart(id: "C7", name: "3, pause, 3", say: "Three reps, hold still at the top for three seconds, then three more.", reps: 6),
        GymPart(id: "C8", name: "Fading ×8", say: "Eight reps, getting slower each time.", reps: 8),
        GymPart(id: "C9", name: "Not reps", say: "Not reps. For twenty seconds, adjust your grip and shift on the bench. No pressing.", reps: 0),
    ])

    static let deadlift = GymBlock(id: "D", title: "Deadlift", lift: .deadlift,
        setup: "Stand side-on to the camera, whole body in view.", parts: [
        GymPart(id: "D1", name: "Normal ×5", say: "Five normal reps. Settle each one on the floor.", reps: 5),
        GymPart(id: "D2", name: "Fast ×5", say: "Five fast reps.", reps: 5),
        GymPart(id: "D3", name: "Slow ×4", say: "Four slow reps. Four seconds up, four seconds down.", reps: 4),
        GymPart(id: "D4", name: "Holds ×3", say: "Three reps. Hold the lockout for three seconds each time.", reps: 3),
        GymPart(id: "D5", name: "Rack pulls ×5", say: "Five rack pulls. From just below the knee, top half only.", reps: 5),
        GymPart(id: "D6", name: "Touch and go ×5", say: "Five touch and go reps. Tap the floor and go.", reps: 5),
        GymPart(id: "D7", name: "3, pause, 3", say: "Three reps, stand still at the top for three seconds, then three more.", reps: 6),
        GymPart(id: "D8", name: "Fading ×8", say: "Eight reps, getting slower each time.", reps: 8),
        GymPart(id: "D9", name: "Not reps", say: "Not reps. For twenty seconds, walk around and pick something up off the floor. No lifting the bar.", reps: 0),
    ])

    static let free = GymBlock(id: "F", title: "Free training", lift: .any,
        setup: "Train as normal. Tap the Watch after each set.", parts: [])
}

/// One part as it happened. Times are wall-clock seconds since 1970.
struct GymPartLog {
    var n: Int
    var id: String
    var name: String
    var expected: Int
    var go: Double
    var end: Double
    var endedBy: String               // watch · still · timed · phone · skipped
    var cameraReps: Int               // -1 = no camera
    var inFramePct: Int               // -1 = no camera
    var redone = false
}

@MainActor
final class GymCoach: ObservableObject {
    static let shared = GymCoach()

    enum Phase: Equatable { case idle, waitingWatch, framing, go, rest(until: Date), finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var block: GymBlock?
    @Published private(set) var index = 0
    @Published private(set) var inFrame = false
    @Published private(set) var cameraReps = 0
    @Published private(set) var partStarted: Date?
    @Published private(set) var log: [GymPartLog] = []
    @Published private(set) var lastSaid = ""
    @Published var selected: String = GymBlock.deadlift.id

    static let stillSeconds = 8.0
    static let restSeconds = 15.0
    static let timedSeconds = 20.0

    private let voice = AVSpeechSynthesizer()
    private var loop: Task<Void, Never>?
    private var phaseSince = Date()
    private var framedSince: Date?
    private var lostSince: Date?
    private var warnedLost = false
    private var cursor = 0                        // first camera frame of this part
    private var framesIn = 0, framesAll = 0
    private var countedDown = false
    private var announcedFrame = false
    private var lastNag = Date.distantPast
    private var lastResult = ""                   // "Camera saw 5" — shown on the Watch during the rest

    private init() {}

    var running: Bool { phase != .idle }
    var camera: Bool { MotionCaptureStore.cameraTracking }

    /// The part in progress (or next, during a rest).
    var part: GymPart? {
        guard let b = block else { return nil }
        if b.free { return GymPart(id: "S\(index + 1)", name: "Set \(index + 1)", say: "", reps: -1) }
        return index < b.parts.count ? b.parts[index] : nil
    }

    // MARK: Controls

    func start() {
        guard !running, let b = GymBlock.all.first(where: { $0.id == selected }) else { return }
        block = b
        index = 0
        log = []
        lastResult = ""
        cameraReps = 0
        partStarted = nil
        framedSince = nil
        announcedFrame = false
        lastNag = Date()
        let rec = PhoneDebugRecorder.shared
        rec.pick(b.lift)
        rec.goLive(gym: b)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt,
                                                         options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        enter(.waitingWatch)
        say("\(b.title). Starting the Watch. \(b.setup)")
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.tick()
            }
        }
    }

    /// Tapped on the Watch (its own clock).
    func watchMarked(t: Double) {
        switch phase {
        case .go: endPart(by: "watch", at: t)
        case .framing: beginPart()                        // in view or not: start now
        default: break                                    // (a late tap during a rest is ignored)
        }
    }

    /// The phone's Done button.
    func phoneDone() {
        switch phase {
        case .go: endPart(by: "phone", at: Date().timeIntervalSince1970)
        case .rest, .framing, .waitingWatch: beginPart()
        default: break
        }
    }

    /// Do it again: the part in progress starts over, or (during a rest) the part just finished
    /// is done again — it stays in the file, marked redone.
    func redo() {
        guard let b = block, !b.free, running, phase != .finishing else { return }
        if phase == .go, index < b.parts.count {
            partStarted = nil
            restThen("Starting that one over. \(b.parts[index].say)", seconds: 8)
            return
        }
        guard let last = log.indices.last, !log[last].redone,
              let i = b.parts.firstIndex(where: { $0.id == log[last].id }) else { return }
        log[last].redone = true
        index = i
        pushParts()
        restThen("Again. \(b.parts[i].say)", seconds: 10)
    }

    func skip() {
        guard let b = block, running, phase != .finishing else { return }
        if phase == .go {
            endPart(by: "skipped", at: Date().timeIntervalSince1970)
        } else if !b.free, index + 1 < b.parts.count {
            index += 1
            restThen("Skipping. Next: \(b.parts[index].say)")
        } else {
            finish()
        }
    }

    /// End the whole session now (keeps everything so far).
    func stop() {
        guard running, phase != .finishing else { return }
        if phase == .go { endPart(by: "phone", at: Date().timeIntervalSince1970, advance: false) }
        finish()
    }

    // MARK: The loop

    private func tick() {
        let rec = PhoneDebugRecorder.shared
        let now = Date()
        // The session closed underneath us (Done on the Watch, or it ended).
        if phase != .finishing, phase != .idle, !rec.armed {
            if phase == .go { endPart(by: "watch", at: now.timeIntervalSince1970, advance: false) }
            finish(fromWatch: true)
        }
        if camera { updateFrame(now) }
        switch phase {
        case .idle:
            break
        case .waitingWatch:
            if rec.recording {
                if camera {
                    enter(.framing)
                    say(block?.lift == .bench ? "Watch is recording. Get on the bench where the camera can see you."
                                              : "Watch is recording. Get into position, side-on, where the camera sees your whole body.")
                } else {
                    restThen(firstLine, seconds: 8)
                }
            } else if now.timeIntervalSince(phaseSince) > 25, now.timeIntervalSince(lastNag) > 20 {
                lastNag = now
                say("Still waiting for the Watch. Open the Big Scherly app on your Watch.")
            }
        case .framing:
            if let f = framedSince, now.timeIntervalSince(f) >= 2 {
                restThen("I can see you. " + firstLine, seconds: block?.free == true ? 4 : 10)
            } else if now.timeIntervalSince(phaseSince) > 30, !announcedFrame {
                announcedFrame = true
                say("I can't see your wrist and hips yet. Check the phone, or tap Done on it to start anyway.")
            }
        case .go:
            guard let p = part, let started = partStarted else { break }
            let poses = partPoses()
            if camera {
                cameraReps = Self.countReps(poses, wrist: wristIndex(poses), downFirst: block?.lift == .bench)
                framesAll += 1; if inFrame { framesIn += 1 }
                if !inFrame {
                    if lostSince == nil { lostSince = now }
                    if let l = lostSince, now.timeIntervalSince(l) > 3, !warnedLost {
                        warnedLost = true
                        say("I lost you on camera.")
                    }
                } else { lostSince = nil }
            }
            if p.reps == 0 {
                if now.timeIntervalSince(started) >= Self.timedSeconds { endPart(by: "timed", at: now.timeIntervalSince1970) }
            } else if camera, block?.free == false, cameraReps >= 1, now.timeIntervalSince(started) > Self.stillSeconds + 2,
                      Self.stillFor(poses, wrist: wristIndex(poses), seconds: Self.stillSeconds, now: now.timeIntervalSince1970) {
                endPart(by: "still", at: now.timeIntervalSince1970 - Self.stillSeconds)
            }
        case .rest(let until):
            let left = until.timeIntervalSince(now)
            if left <= 3.2, !countedDown {
                countedDown = true
                say("Three. Two. One.")
            }
            if left <= 0 { beginPart() }
        case .finishing:
            if rec.live == nil {
                enter(.idle)
                loop?.cancel(); loop = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private var firstLine: String {
        guard let b = block else { return "" }
        if b.free { return "Train as normal. Tap the Watch after each set." }
        return "First, \(b.parts[0].say)"
    }

    // MARK: Parts

    private func beginPart() {
        guard part != nil else { finish(); return }
        partStarted = Date()
        cursor = DepthCamera.shared.livePoses.count
        cameraReps = 0
        framesIn = 0; framesAll = 0
        lostSince = nil; warnedLost = false
        enter(.go)
        if block?.free == true { return }               // free training: no Go, sets start when you do
        say("Go.")
    }

    private func endPart(by: String, at t: Double, advance: Bool = true) {
        guard phase == .go, let p = part, let b = block else { return }
        let started = partStarted?.timeIntervalSince1970 ?? t
        let entry = GymPartLog(n: log.count + 1, id: p.id, name: p.name, expected: p.reps, go: started, end: max(t, started),
                               endedBy: by, cameraReps: camera ? cameraReps : -1,
                               inFramePct: camera && framesAll > 0 ? framesIn * 100 / framesAll : -1)
        log.append(entry)
        pushParts()
        partStarted = nil
        guard advance else { return }
        index += 1
        let seen = camera && p.reps != 0 ? "Camera saw \(cameraReps). " : ""
        lastResult = camera && p.reps != 0 ? "Camera saw \(cameraReps)" : ""
        if b.free {
            say("Set \(index) logged. \(seen)")
            beginPart()
            return
        }
        guard index < b.parts.count else {
            say("Got it. \(seen)That's the block.")
            finish()
            return
        }
        restThen("Got it. \(seen)Rest, arms still. Next: \(b.parts[index].say)")
    }

    private func restThen(_ line: String, seconds: Double = GymCoach.restSeconds) {
        countedDown = false
        enter(.rest(until: Date().addingTimeInterval(seconds)))
        say(line)
    }

    private func finish(fromWatch: Bool = false) {
        guard phase != .finishing, phase != .idle else { return }
        pushParts()
        enter(.finishing)
        say("Saving the file. Nice work.")
        if !fromWatch { PhoneDebugRecorder.shared.end() }
    }

    private func pushParts() { PhoneDebugRecorder.shared.live?.parts = log }

    private func enter(_ p: Phase) { phase = p; phaseSince = Date(); sendCue() }

    /// What the Watch shows (and buzzes for): the phase, the part, and the rest's end.
    private func sendCue() {
        guard let b = block else { return }
        var c: [String: Any] = ["block": b.title, "of": b.parts.count, "n": index + 1, "last": lastResult]
        if let p = part { c["id"] = p.id; c["name"] = p.name; c["say"] = p.say.isEmpty ? b.setup : p.say }
        switch phase {
        case .idle: return
        case .waitingWatch: c["phase"] = "wait"; c["say"] = b.setup
        case .framing:
            c["phase"] = "frame"
            c["say"] = b.lift == .bench ? "Get on the bench where the phone's camera can see you."
                                        : "Stand side-on where the phone's camera sees your whole body."
        case .go: c["phase"] = "go"
        case .rest(let until): c["phase"] = "rest"; c["until"] = until.timeIntervalSince1970
        case .finishing: c["phase"] = "done"; c["say"] = "Saving the file."
        }
        WatchBridge.shared.sendEvent(["dbgCue": c])
    }

    private func say(_ s: String) {
        lastSaid = s
        let u = AVSpeechUtterance(string: s)
        u.rate = 0.5
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        voice.speak(u)
    }

    // MARK: Camera

    private func partPoses() -> ArraySlice<LivePose> {
        let all = DepthCamera.shared.livePoses
        return all[min(cursor, all.count)...]
    }

    /// The Watch's wrist in the camera's list (0 left, 1 right) — or the other one if that's the one it sees.
    private func wristIndex<C: Collection>(_ poses: C) -> Int where C.Element == LivePose {
        let mine = PhoneDebugRecorder.shared.live?.wrist == "right" ? 1 : 0
        guard poses.count > 20 else { return mine }
        let seenMine = poses.filter { $0.ys[mine] >= 0 }.count
        let seenOther = poses.filter { $0.ys[1 - mine] >= 0 }.count
        return seenMine * 2 >= seenOther ? mine : 1 - mine
    }

    private func updateFrame(_ now: Date) {
        let all = DepthCamera.shared.livePoses
        let t = now.timeIntervalSince1970
        var recent: [LivePose] = []
        var i = all.count - 1
        while i >= 0, all[i].t > t - 1.5 { recent.append(all[i]); i -= 1 }
        let w = wristIndex(recent)
        let good = recent.filter { $0.ys[w] >= 0 && ($0.ys[2] >= 0 || $0.ys[3] >= 0) }.count
        let ok = recent.count >= 5 && good * 2 >= recent.count
        if ok != inFrame { inFrame = ok }
        if ok { if framedSince == nil { framedSince = now } } else { framedSince = nil }
    }

    /// Up-strokes (or down-strokes for bench) of the wrist on camera, with a band of 35–65 % of its range.
    static func countReps<C: Collection>(_ poses: C, wrist: Int, downFirst: Bool) -> Int where C.Element == LivePose {
        var ys: [Double] = []
        ys.reserveCapacity(poses.count)
        for p in poses where p.ys[wrist] >= 0 { ys.append(Double(p.ys[wrist])) }
        guard ys.count >= 15 else { return 0 }
        var sm: [Double] = []                           // 5-frame moving average
        sm.reserveCapacity(ys.count)
        var acc = 0.0
        for (i, v) in ys.enumerated() {
            acc += v
            if i >= 5 { acc -= ys[i - 5] }
            sm.append(acc / Double(min(i + 1, 5)))
        }
        let sorted = sm.sorted()
        let lo = sorted[sorted.count * 5 / 100], hi = sorted[sorted.count * 95 / 100]
        let range = hi - lo
        guard range >= 30 else { return 0 }              // ×1000 units: 3 % of the frame
        let low = lo + range * 0.35, high = lo + range * 0.65
        var n = 0
        var state = 0                                   // -1 below the band, +1 above
        for v in sm {
            if v < low {
                if state == 1 && downFirst { n += 1 }
                state = -1
            } else if v > high {
                if state == -1 && !downFirst { n += 1 }
                state = 1
            }
        }
        return n
    }

    /// The wrist has barely moved for `seconds` (and the camera saw it most of that time).
    static func stillFor<C: Collection>(_ poses: C, wrist: Int, seconds: Double, now: Double) -> Bool where C.Element == LivePose {
        var lo = Int.max, hi = Int.min, seen = 0, all = 0
        for p in poses where p.t >= now - seconds {
            all += 1
            let y = p.ys[wrist]
            guard y >= 0 else { continue }
            seen += 1
            lo = min(lo, y); hi = max(hi, y)
        }
        return all >= 20 && seen * 2 >= all && hi - lo <= 20
    }
}

// MARK: - The card

struct GymSessionCard: View {
    @ObservedObject private var coach = GymCoach.shared
    @ObservedObject private var rec = PhoneDebugRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gym session").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                Spacer()
                if coach.running {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(coach.block?.title.uppercased() ?? "").font(BrandFont.body(11, .heavy)).foregroundColor(Brand.text)
                    }
                }
            }
            if coach.running { running } else { idle }
        }
        .padding(14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    @ViewBuilder private var idle: some View {
        Text("No laptop needed. The phone talks you through the block, counts on camera, and saves one file to Auto-save at the end. Tap the Watch when you finish each part.")
            .font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
        Picker("Block", selection: $coach.selected) {
            ForEach(GymBlock.all) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.segmented)
        if let b = GymBlock.all.first(where: { $0.id == coach.selected }) {
            if b.free {
                Text("Any lifts, any rest. Tap the Watch after each set; tap Done on the Watch when you finish.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.text).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(b.parts) { p in
                        HStack(spacing: 8) {
                            Text(p.id).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.mute).frame(width: 24, alignment: .leading)
                            Text(p.name).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text)
                        }
                    }
                }
                Text("15-second rests between parts · about \(b.parts.count * 45 / 60 + 2) min")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        if let f = rec.gymFile {
            Text(f).font(BrandFont.body(11, .semibold)).foregroundColor(Brand.voltText).fixedSize(horizontal: false, vertical: true)
        }
        if let url = rec.gymLocalCopy {
            ShareLink(item: url) {
                Text("Share the file").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.voltText)
            }
        }
        Button { coach.start() } label: {
            Text("Start").font(BrandFont.body(15, .heavy)).foregroundColor(Brand.onVolt)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(rec.live != nil)
    }

    @ViewBuilder private var running: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                Text(status(ctx.date)).font(BrandFont.body(12, .heavy)).foregroundColor(Brand.voltText)
                if let p = coach.part {
                    Text("\(p.id) · \(p.name)").font(BrandFont.body(22, .heavy)).foregroundColor(Brand.text)
                    if !p.say.isEmpty {
                        Text(p.say).font(BrandFont.body(13)).foregroundColor(Brand.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if coach.camera {
            HStack(spacing: 6) {
                Circle().fill(coach.inFrame ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(coach.inFrame ? "Camera sees you" : "Camera can't see your wrist and hips")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text)
                Spacer()
                if coach.phase == .go, coach.part?.reps != 0 {
                    Text("Camera reps \(coach.cameraReps)").font(BrandFont.body(12, .heavy)).foregroundColor(Brand.text)
                }
            }
        }
        if !coach.lastSaid.isEmpty {
            Text("“\(coach.lastSaid)”").font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            pill("Done", filled: true) { coach.phoneDone() }
            if coach.block?.free == false { pill("Redo") { coach.redo() } }
            pill("Skip") { coach.skip() }
            pill("End") { coach.stop() }
        }
        .disabled(coach.phase == .finishing)
        if !coach.log.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(coach.log.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 8) {
                        Text(l.id).font(BrandFont.body(11, .heavy)).foregroundColor(Brand.mute).frame(width: 24, alignment: .leading)
                        Text(l.name).font(BrandFont.body(12, .semibold)).foregroundColor(l.redone ? Brand.mute : Brand.text)
                            .strikethrough(l.redone)
                        Spacer()
                        Text(detail(l)).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                }
            }
        }
    }

    private func detail(_ l: GymPartLog) -> String {
        let cam = l.cameraReps >= 0 && l.expected != 0 ? "camera \(l.cameraReps)" : ""
        let by: String
        switch l.endedBy {
        case "watch": by = "Watch tap"
        case "still": by = "you stopped"
        case "timed": by = "timed"
        case "phone": by = "phone"
        default: by = "skipped"
        }
        return [cam, by].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func status(_ now: Date) -> String {
        switch coach.phase {
        case .idle: return ""
        case .waitingWatch: return "WAITING FOR THE WATCH…"
        case .framing: return "GET INTO VIEW"
        case .go:
            let s = Int(now.timeIntervalSince(coach.partStarted ?? now))
            if coach.block?.free == true { return String(format: "SET %d · %d:%02d · TAP THE WATCH WHEN DONE", coach.index + 1, s / 60, s % 60) }
            return String(format: "GO · %d:%02d · TAP THE WATCH WHEN DONE", s / 60, s % 60)
        case .rest(let until):
            return "REST · \(max(0, Int(until.timeIntervalSince(now).rounded(.up)))) · NEXT UP"
        case .finishing: return "SAVING THE FILE…"
        }
    }

    private func pill(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(BrandFont.body(13, .heavy))
                .foregroundColor(filled ? Brand.onVolt : Brand.voltText)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(filled ? Brand.volt : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.voltLine, lineWidth: filled ? 0 : 1.5))
        }
        .buttonStyle(.plain)
    }
}
