import SwiftUI
import WatchKit
import Combine

// MARK: - Debug recorder (DEVELOPER TOOL — removed before release)
// The phone (Settings ▸ Apple Watch setup ▸ Motion captures ▸ Record) arms it; the Watch then shows
// one big tile: tap to record, do any reps, tap to stop. No steps, targets or checks — every
// recording goes to the phone as a motion capture (with the camera's track when it's on), counted
// by the same analyser as a workout. Tap again for another recording; Done ends it.
// LIVE session: no tapping at all — once the phone starts it, the Watch records continuously and
// sends what it has every 15 seconds (raw motion + its rep count), so Claude can watch nearly live.
//
// Lives in the Watch app folder (added automatically).

@MainActor
final class WatchDebugRecorder: ObservableObject {
    static let shared = WatchDebugRecorder()

    struct Arm: Equatable {
        var lift: String; var title: String
        var order: String                                // "up" (press, deadlift) · "down" (squat, bench) · "either"
        var live = false; var session = ""
        var analyserOrder: RepAnalyzer.Order { order == "up" ? .upFirst : order == "down" ? .downFirst : .either }
    }

    @Published private(set) var arm: Arm?
    @Published private(set) var phase = "ready"          // ready · countdown · recording · sending
    @Published private(set) var count = 0
    @Published private(set) var countdownEnds: Date?
    @Published private(set) var recStart: Date?
    @Published private(set) var note: String?

    private var task: Task<Void, Never>?
    private var solo = false
    private var finishedSets = 0                         // reps in sets that already closed (rests of 7 s+)
    private var tapped = 0
    // Live session
    private var liveTask: Task<Void, Never>?
    private var seq = 0
    private var finishedReps: [RepMotion] = []
    private var currentReps: [RepMotion] = []
    private var wrist = "left"
    static let chunkSeconds: UInt64 = 15

    private init() {}

    // MARK: From the phone

    func armed(lift: String, title: String, order: String, live: Bool, session: String) {
        let a = Arm(lift: lift, title: title, order: order, live: live, session: session)
        if arm == a { return }                            // the same arm, resent
        if phase == "recording" || phase == "countdown" {
            // Mid-recording: only the lift (and so the counting order) can change.
            if var cur = arm, cur.live, a.live, cur.session == a.session {
                cur.lift = a.lift; cur.title = a.title; cur.order = a.order
                arm = cur
                MotionRecorder.shared.setRepOrder(cur.analyserOrder)
            }
            return
        }
        arm = a
        phase = "ready"
        note = nil
        ensureSession()
        if a.live { go() }                                // live: no tap — it starts on its own
    }

    func ended() {
        task?.cancel(); task = nil
        liveTask?.cancel(); liveTask = nil
        if phase == "recording" {
            if arm?.live == true { sendChunk(final: true) }   // what's left, before closing
            MotionRecorder.shared.endCapture { _ in }
        }
        arm = nil
        phase = "ready"
        countdownEnds = nil
        recStart = nil
        MotionRecorder.shared.endCalibration()
        if solo {
            solo = false
            if WatchState.shared.card == nil, WorkoutSessionManager.shared.isRunning {
                Task { await WorkoutSessionManager.shared.end() }
            }
        }
    }

    // MARK: On the wrist

    func tap() {
        switch phase {
        case "ready": go()
        case "recording":
            if arm?.live == true { done() } else { stop() }   // live: tapping ends the session
        default: break
        }
    }

    /// Done on the Watch: the phone closes its side too.
    func done() {
        WatchState.sendLive(["dbgDone": true])
        ended()
    }

    private func ensureSession() {
        let sessions = WorkoutSessionManager.shared
        guard !sessions.isRunning else { return }
        if WatchState.shared.card == nil {
            solo = true
            sessions.discardOnEnd = true                  // a debug session never goes to Apple Health
        }
        Task { await sessions.start() }
    }

    private func go() {
        guard let a = arm else { return }
        ensureSession()
        note = nil
        phase = "countdown"
        countdownEnds = Date().addingTimeInterval(3)
        MotionRecorder.shared.beginCalibration()          // not a workout set
        MotionRecorder.shared.setRepOrder(a.analyserOrder)
        WatchBuzz.tap()
        task?.cancel()
        task = Task {
            for left in [2, 1] {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.phase == "countdown" else { return }
                WatchBuzz.countdown(left)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // The session must be running (it keeps the app measuring with your wrist down).
            for _ in 0..<20 where !WorkoutSessionManager.shared.isRunning {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, self.phase == "countdown" else { return }
            self.countdownEnds = nil
            guard WorkoutSessionManager.shared.isRunning else {
                self.phase = "ready"
                self.note = "No workout session — close and reopen the Watch app"
                WKInterfaceDevice.current().play(.retry)
                return
            }
            self.recStart = Date()
            self.count = 0; self.finishedSets = 0; self.tapped = 0
            self.finishedReps = []; self.currentReps = []; self.seq = 0
            self.phase = "recording"
            MotionRecorder.shared.beginCapture()
            WatchBuzz.go()
            let device = WKInterfaceDevice.current()
            self.wrist = device.wristLocation == .left ? "left" : "right"
            WatchState.sendLive(["dbgGo": true, "wrist": self.wrist])
            if a.live { self.startLiveLoop() }
        }
    }

    // MARK: Live session — a chunk every 15 seconds

    private func startLiveLoop() {
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.chunkSeconds * 1_000_000_000)
                guard !Task.isCancelled, self.phase == "recording", self.arm?.live == true else { return }
                self.sendChunk(final: false)
            }
        }
    }

    /// Everything since the last chunk: raw motion (packed like a capture), plus every rep counted
    /// so far this session (the phone keeps the newest list).
    private func sendChunk(final: Bool) {
        guard let a = arm else { return }
        seq += 1
        let n = seq, session = a.session, lift = a.lift, wrist = self.wrist
        let build = WatchBuild.tag
        let reps = finishedReps + currentReps
        let repsData = (try? JSONEncoder().encode(reps)) ?? Data()
        MotionRecorder.shared.drainCapture { samples in
            let packed = MotionCapturePack.pack(samples)
            WatchState.sendLive(["dbgChunk": packed.data, "dbgSession": session, "dbgSeq": n,
                                 "dbgStart": packed.startT, "dbgHz": MotionCapturePack.outRate,
                                 "dbgRaw": samples.count, "dbgReps": repsData, "dbgLift": lift,
                                 "dbgWrist": wrist, "dbgBuild": build, "dbgAnalyzer": RepAnalyzer.version,
                                 "dbgFinal": final ? 1 : 0])
        }
    }

    /// Live reps from the analyser (the set in progress).
    func live(_ reps: [RepMotion]) {
        guard phase == "recording", let s = recStart else { return }
        let mine = reps.filter { $0.start >= s.addingTimeInterval(-0.5) }
        currentReps = mine
        let now = mine.count
        count = finishedSets + now
        if count > tapped { tapped = count; WatchBuzz.rep() }
    }

    /// A set closed (7 s without moving) while recording: keep its reps in the running count.
    func setEnded(_ reps: [RepMotion]) {
        guard phase == "recording", let s = recStart else { return }
        let mine = reps.filter { $0.start >= s.addingTimeInterval(-0.5) }
        finishedSets += mine.count
        finishedReps += mine
        currentReps = []
        count = finishedSets
    }

    private func stop() {
        guard let a = arm else { return }
        phase = "sending"
        WKInterfaceDevice.current().play(.stop)
        WatchState.sendLive(["dbgStopped": true])         // the phone stops the camera
        let order = a.analyserOrder
        let build = WatchBuild.tag, title = a.title, lift = a.lift
        MotionRecorder.shared.endCapture { samples in
            guard samples.count >= 150 else {
                Task { @MainActor in WatchDebugRecorder.shared.sent(nil) }
                return
            }
            // The whole recording, analysed at once — what a workout set would have counted.
            let reps = RepAnalyzer.analyze(samples, order: order)
            let packed = MotionCapturePack.pack(samples)
            let repsData = (try? JSONEncoder().encode(reps)) ?? Data()
            WatchState.sendLive(["motionCapture": packed.data, "mcReps": repsData,
                                 "mcTitle": title, "mcLift": lift, "mcKind": "debug", "mcN": 1, "mcOf": 1,
                                 "mcStart": packed.startT, "mcHz": MotionCapturePack.outRate,
                                 "mcBuild": build, "mcAnalyzer": RepAnalyzer.version, "mcRaw": samples.count])
            let n = reps.count
            Task { @MainActor in WatchDebugRecorder.shared.sent(n) }
        }
    }

    private func sent(_ reps: Int?) {
        phase = "ready"
        recStart = nil
        if let reps {
            note = "Sent to the phone · \(reps) rep\(reps == 1 ? "" : "s")"
            WKInterfaceDevice.current().play(.success)
        } else {
            note = "Too short to keep — record again"
            WKInterfaceDevice.current().play(.retry)
        }
    }
}

/// Over everything while the phone has the recorder armed.
struct DebugRecordOverlay: View {
    @ObservedObject private var rec = WatchDebugRecorder.shared
    @EnvironmentObject var state: WatchState
    private let mute = Color(white: 0.56)

    var body: some View {
        if let a = rec.arm {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 7) {
                        VStack(spacing: 1) {
                            Text(a.live ? "DEBUG · LIVE" : "DEBUG · RECORD").font(.system(size: 8.5, weight: .heavy)).tracking(1.2).foregroundColor(mute)
                            Text(a.title).font(.system(size: 16, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in tile(ctx.date) }
                            .onTapGesture { rec.tap() }
                        Text(hint).font(.system(size: 9.5, weight: .bold)).foregroundColor(mute)
                            .multilineTextAlignment(.center)
                        if let n = rec.note {
                            Text(n).font(.system(size: 10.5, weight: .bold)).multilineTextAlignment(.center)
                        }
                        Button { rec.done() } label: {
                            Text("Done").font(.system(size: 11, weight: .semibold)).foregroundColor(mute)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private var hint: String {
        switch rec.phase {
        case "ready": return "Tap to record. Do any reps, then tap to stop."
        case "countdown": return "Get into position…"
        case "recording": return rec.arm?.live == true ? "Live — Claude sees it every 15 s. Tap to end the session." : "Recording — tap to stop"
        default: return "Sending to the phone…"
        }
    }

    @ViewBuilder
    private func tile(_ now: Date) -> some View {
        switch rec.phase {
        case "ready":
            filled(VStack(spacing: 1) {
                Image(systemName: "record.circle").font(.system(size: 26, weight: .bold))
                Text("RECORD").font(.system(size: 8, weight: .heavy)).tracking(1.1).opacity(0.7)
            })
        case "countdown":
            let left = max(0, (rec.countdownEnds ?? now).timeIntervalSince(now))
            outlined(VStack(spacing: 0) {
                Text("GET SET").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(state.accentColor)
                Text("\(max(1, Int(left.rounded(.up))))").font(.system(size: 34, weight: .heavy, design: .rounded))
            })
        case "recording":
            let secs = Int(now.timeIntervalSince(rec.recStart ?? now))
            filled(VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("\(rec.count)").font(.system(size: 32, weight: .heavy, design: .rounded))
                }
                Text(String(format: rec.arm?.live == true ? "LIVE · %d:%02d · TAP TO END" : "REPS · %d:%02d · TAP TO STOP", secs / 60, secs % 60))
                    .font(.system(size: 7.5, weight: .heavy)).tracking(0.8).opacity(0.7).lineLimit(1)
            })
        default:
            outlined(VStack(spacing: 4) {
                ProgressView().tint(state.accentColor)
                Text("SENDING").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(mute)
            })
        }
    }

    private func filled<C: View>(_ content: C) -> some View {
        content.foregroundColor(state.inkColor)
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 18).fill(state.accentColor))
            .padding(.horizontal, 4)
    }

    private func outlined<C: View>(_ content: C) -> some View {
        content
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(state.accentColor.opacity(0.6), lineWidth: 1.5))
            .padding(.horizontal, 4)
    }
}
