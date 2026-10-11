import SwiftUI
import UIKit
import Combine

// MARK: - Debug recorder, phone side (DEVELOPER TOOL — removed before release)
// Settings ▸ Apple Watch setup ▸ Motion captures ▸ Record. Pick the lift and arm it: the Watch shows
// a Record tile (tap, do reps, tap to stop — as many recordings as you like). The camera follows your
// wrist (hips on squats) while the Watch records, and each recording lands in Motion captures.
// "Share all" sends every capture as one text file (AirDrop it to the Mac).
// LIVE session: the Watch records continuously and sends a chunk every 15 s; the phone adds the
// camera's joints (and the plate) and rewrites one "LIVE …" file in the auto-save folder each time,
// so Claude can follow the session nearly live from the Mac.
//
// Lives in the app folder (added automatically).

@MainActor
final class PhoneDebugRecorder: ObservableObject {
    static let shared = PhoneDebugRecorder()

    enum Lift: String, CaseIterable, Identifiable {
        case any, press, airSquat, squat, bench, deadlift
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "Anything (free)"
            case .press: return "Overhead press"
            case .airSquat: return "Air squat"
            case .squat: return "Squat"
            case .bench: return "Bench press"
            case .deadlift: return "Deadlift"
            }
        }
        /// Lifts first, then lowers (press, deadlift) — or the other way round.
        var upFirst: Bool { self == .press || self == .deadlift }
        /// For the Watch's counting: "up" first, "down" first, or either (anything goes).
        var order: String { self == .any ? "either" : upFirst ? "up" : "down" }
        /// What the camera follows: hips for squats, the wrist otherwise.
        var move: SetupMove {
            switch self {
            case .any, .press: return .press
            case .airSquat: return .airSquat
            case .squat: return .squat
            case .bench: return .bench
            case .deadlift: return .deadlift
            }
        }
    }

    @Published var lift: Lift = .press
    @Published private(set) var armed = false
    @Published private(set) var recording = false
    @Published private(set) var recordings = 0
    // Live session
    @Published private(set) var live: LiveSession?
    @Published private(set) var liveSaved: Date?
    @Published private(set) var liveNote: String?
    private var liveClosing: Task<Void, Never>?

    private init() {}

    func arm() {
        armed = true
        recording = false
        UIApplication.shared.isIdleTimerDisabled = true            // the screen stays on while armed
        if !WatchBridge.shared.watchSessionLive, WatchBridge.shared.watchAppAvailable {
            WatchBridge.shared.startWatchWorkout { _ in }           // opens the Watch app
        }
        if MotionCaptureStore.cameraTracking { DepthCamera.shared.start() }
        sendArm()
    }

    /// A different lift while armed: the Watch switches too (between recordings).
    func pick(_ l: Lift) {
        lift = l
        if armed && (!recording || live != nil) { sendArm() }   // live: switch lifts any time
    }

    private func sendArm() {
        var arm: [String: Any] = ["lift": lift.rawValue, "title": lift.title,
                                  "upFirst": lift.upFirst ? 1 : 0, "order": lift.order]
        if let s = live { arm["live"] = 1; arm["session"] = s.id }
        WatchBridge.shared.sendEvent(["dbgArm": arm])
    }

    /// Start a live session: the Watch records on its own (no tapping) and a chunk lands every 15 s.
    func goLive() {
        if live != nil {
            if armed { return }                             // already running
            closeLive()                                     // the last one was still closing: close it now
        }
        if armed { end() }                                  // armed for single recordings: switch to live
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        live = LiveSession(id: f.string(from: Date()))
        liveSaved = nil
        liveNote = MotionCaptureStore.shared.folderName == nil ? "Choose a folder under Auto-save so Claude can see it" : nil
        liveClosing?.cancel(); liveClosing = nil
        MacLink.shared.start()                              // find the Mac now, not at the first chunk
        arm()
        // The camera logs from now — not only once the Watch's Go arrives.
        if MotionCaptureStore.cameraTracking { DepthCamera.shared.startLiveLog() }
    }

    func end(fromWatch: Bool = false) {
        guard armed else { return }
        armed = false
        recording = false
        if live != nil {
            // Wait (briefly) for the Watch's last chunk, then close the file.
            liveClosing = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self.closeLive()
            }
        }
        DepthCamera.shared.cancelRecording()
        if !SetupEngine.shared.active { DepthCamera.shared.stop() }
        if !fromWatch { WatchBridge.shared.sendEvent(["dbgEnd": true]) }
        let keepAwake = UserDefaults.standard.object(forKey: "bst_keep_awake") as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = SetVideoRecorder.shared.screenVisible && keepAwake
    }

    // MARK: From the Watch

    func watchWentGo(wrist: String?) {
        guard armed else { return }
        recording = true
        if let s = live {
            s.wrist = wrist ?? s.wrist
            if MotionCaptureStore.cameraTracking { DepthCamera.shared.start(); DepthCamera.shared.startLiveLog() }
            return
        }
        if MotionCaptureStore.cameraTracking {
            DepthCamera.shared.start()
            // With a plate marked, the camera follows the bar end and measures against the plate.
            DepthCamera.shared.startRecording(move: lift.move, side: wrist ?? "left", usePlate: true)
        }
    }

    func watchStopped() {
        guard recording else { return }
        recording = false
        recordings += 1
        if let track = DepthCamera.shared.stopRecording() { MotionCaptureStore.shared.attachCamera(track) }
    }

    // MARK: Live session

    /// The Watch's next 15 seconds.
    func liveChunk(_ m: [String: Any]) {
        guard let s = live, (m["dbgSession"] as? String) == s.id, let data = m["dbgChunk"] as? Data else { return }
        let seq = m["dbgSeq"] as? Int ?? 0
        guard seq > s.lastSeq else { return }                // a resend
        s.lastSeq = seq
        if !data.isEmpty {
            s.chunks.append(.init(start: m["dbgStart"] as? Double ?? 0, hz: m["dbgHz"] as? Double ?? 50, data: data))
        }
        if let rd = m["dbgReps"] as? Data, let reps = try? JSONDecoder().decode([RepMotion].self, from: rd) { s.reps = reps }
        s.lift = m["dbgLift"] as? String ?? s.lift
        s.wrist = m["dbgWrist"] as? String ?? s.wrist
        s.build = m["dbgBuild"] as? String ?? s.build
        s.analyzer = m["dbgAnalyzer"] as? Int ?? s.analyzer
        writeLive(s)
        if (m["dbgFinal"] as? Int ?? 0) == 1 { closeLive() }
    }

    private func writeLive(_ s: LiveSession) {
        let text = s.text(poses: DepthCamera.shared.livePoses, plates: DepthCamera.shared.livePlates)
        MacLink.shared.send(name: "LIVE \(s.id).txt", text: text)     // Wi-Fi to the Mac: about a second
        if MotionCaptureStore.shared.writeFile(named: "LIVE \(s.id).txt", text: text) {
            liveSaved = Date()
            liveNote = nil
        } else {
            liveNote = "Not saved — choose a folder under Auto-save"
        }
    }

    private func closeLive() {
        liveClosing?.cancel(); liveClosing = nil
        if let s = live { s.ended = true; writeLive(s) }
        DepthCamera.shared.stopLiveLog()
        if !armed, !SetupEngine.shared.active { DepthCamera.shared.stop() }
        live = nil
    }

    // MARK: Share all

    /// Every capture in one text file, newest first — for AirDrop to the Mac (or attach in the chat).
    static func exportFile() -> URL? {
        let caps = MotionCaptureStore.shared.captures
        guard !caps.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let stamp = f.string(from: Date())
        var text = "BST-CAPTURES v1 | \(caps.count) captures | exported \(Date().formatted(.iso8601))\n"
        for c in caps {
            text += "\n===== CAPTURE \(c.id.uuidString.prefix(8)) =====\n"
            text += c.compactText()
            text += "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bst-captures-\(stamp).txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

/// A live session as it builds up: the Watch's chunks, its latest rep list, and how to write it all out.
@MainActor
final class LiveSession {
    struct Chunk { var start: Double; var hz: Double; var data: Data }
    let id: String
    let started = Date()
    var chunks: [Chunk] = []
    var reps: [RepMotion] = []
    var lastSeq = 0
    var lift = "any", wrist = "left", build = "?", analyzer = 0
    var ended = false

    init(id: String) { self.id = id }

    /// One file, rewritten every chunk. Times are seconds from t0 (the first Watch sample); camera
    /// heights are Vision units (0…1 of the frame, up positive) ×1000, -1 = not seen.
    func text(poses: [LivePose], plates: [LivePlate]) -> String {
        let t0 = chunks.first?.start ?? started.timeIntervalSince1970
        var out: [String] = []
        let iso = ISO8601DateFormatter()
        out.append("BST-LIVE v1 | session \(id) | updated \(iso.string(from: Date()))\(ended ? " | ENDED" : "") | watchBuild=\(build) analyzer=\(analyzer) | lift=\(lift) | wrist=\(wrist)")
        let cam = DepthCamera.shared
        let ruler = cam.plateLocked ? String(format: "plate %.1f cm", PlateRuler.diameterCm) : "height \(Int(MotionCaptureStore.heightCm)) cm (rough)"
        out.append(String(format: "t0=%.3f (s since 1970) | chunks=%d | watch reps=%d | camera pose frames=%d plate frames=%d | ruler=%@",
                          t0, chunks.count, reps.count, poses.count, plates.count, ruler))
        out.append(cam.liveCheck)
        out.append("watch reps (live analyser, s from t0): n,start,end,ecc,bottomPause,con,topPause,travelCm,meanV,peakV")
        for (i, r) in reps.enumerated() {
            func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
            out.append([String(i + 1), f(r.start.timeIntervalSince1970 - t0), f(r.end.timeIntervalSince1970 - t0),
                        f(r.eccentricSec), f(r.bottomPauseSec), f(r.concentricSec), f(r.topPauseSec),
                        String(format: "%.1f", r.travelM * 100), f(r.meanVelocity), f(r.peakVelocity)].joined(separator: ","))
        }
        out.append("camera pose (s from t0; y ×1000): t,wristL,wristR,hipL,hipR,kneeL,kneeR,nose,ankleL,ankleR")
        for p in poses where p.t >= t0 - 5 {
            out.append(String(format: "%.2f,", p.t - t0) + p.ys.map { String($0) }.joined(separator: ","))
        }
        out.append("camera plate (s from t0): t,y×1000,h×1000,conf×100")
        for p in plates where p.t >= t0 - 5 {
            out.append(String(format: "%.2f,%d,%d,%d", p.t - t0, p.y, p.h, p.c))
        }
        out.append("watch samples fs=25 unit=0.01 (s from t0): t,av,h1,h2,rot (av up+ m/s², h1/h2 m/s², rot rad/s)")
        for c in chunks {
            let count = c.data.count / 8                      // Int16 × 4 channels
            c.data.withUnsafeBytes { raw in
                let v = raw.bindMemory(to: Int16.self)
                var k = 0
                while k * 2 + 1 < count {
                    var cols: [String] = []
                    for ch in 0..<4 {
                        let a = Int(v[(k * 2) * 4 + ch]), b = Int(v[(k * 2 + 1) * 4 + ch])
                        cols.append(String(Int((Double(a + b) / 20.0).rounded())))
                    }
                    let t = c.start + (Double(k * 2) + 1) / c.hz - t0
                    out.append(String(format: "%.2f,", t) + cols.joined(separator: ","))
                    k += 1
                }
            }
        }
        return out.joined(separator: "\n")
    }
}

/// The share sheet (AirDrop, Files, Messages…).
struct CaptureShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// The Record card at the top of Motion captures.
struct DebugRecordPanel: View {
    @ObservedObject private var rec = PhoneDebugRecorder.shared
    @ObservedObject private var camera = DepthCamera.shared
    @AppStorage(MotionCaptureStore.trackKey) private var tracking = true
    @ObservedObject private var mac = MacLink.shared
    @State private var marking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Record").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                Spacer()
                if rec.recording {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("RECORDING").font(BrandFont.body(11, .heavy)).foregroundColor(Brand.text)
                    }
                } else if rec.armed {
                    Text("Ready on your Watch").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                }
            }
            Text("No setup steps or checks: arm it, then on the Watch tap to record, do any reps, tap to stop. Each recording shows up below.")
                .font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            Picker("Lift", selection: Binding(get: { rec.lift }, set: { rec.pick($0) })) {
                ForEach(PhoneDebugRecorder.Lift.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Brand.voltText)
            .disabled(rec.recording && rec.live == nil)
            if rec.armed && tracking {
                DepthPreview()
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)        // portrait, the shape the camera sees
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        Text(camera.poseSeen ? "You're in view" : "Step into view, side-on")
                            .font(BrandFont.body(11, .heavy)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(8)
                    }
            }
            if tracking { ruler }
            liveControls
            if rec.live == nil {
            Button {
                if rec.armed { rec.end() } else { rec.arm() }
            } label: {
                Text(rec.armed ? "Stop recording mode" : "Arm the Watch (tap to record each set)")
                    .font(BrandFont.body(15, .heavy))
                    .foregroundColor(rec.armed ? Brand.voltText : Brand.onVolt)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(rec.armed ? Color.clear : Brand.volt))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: rec.armed ? 1.5 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            }
            if rec.recordings > 0 {
                Text("\(rec.recordings) recording\(rec.recordings == 1 ? "" : "s") this time")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
        }
        .padding(14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .sheet(isPresented: $marking) { PlateMarkSheet() }
    }

    /// Live session: Claude follows along from the Mac, a chunk every 15 seconds.
    @ViewBuilder private var liveControls: some View {
        if let s = rec.live {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = Int(ctx.date.timeIntervalSince(s.started))
                        Text(String(format: "LIVE · %d:%02d", secs / 60, secs % 60)).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                    }
                    Spacer()
                    if let t = rec.liveSaved {
                        Text("Saved \(t.formatted(.dateTime.hour().minute().second()))").font(BrandFont.body(11)).foregroundColor(Brand.voltText)
                    }
                }
                if let n = rec.liveNote { Text(n).font(BrandFont.body(12, .semibold)).foregroundColor(Brand.text) }
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer").font(.system(size: 11, weight: .bold))
                    Text("Mac: \(mac.state)").font(BrandFont.body(11, .semibold)).lineLimit(2)
                    Spacer()
                    if let t = mac.lastSent {
                        Text(t.formatted(.dateTime.hour().minute().second())).font(BrandFont.body(11))
                    }
                }
                .foregroundColor(mac.lastSent == nil ? Brand.mute : Brand.voltText)
                Text("Do whatever you like — change the lift above when you switch, so the Watch counts the right way round.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                Button { rec.end() } label: {
                    Text("End live session").font(BrandFont.body(15, .heavy)).foregroundColor(Brand.voltText)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button { rec.goLive() } label: {
                VStack(spacing: 2) {
                    Text("Start live session").font(BrandFont.body(15, .heavy))
                    Text("Claude watches nearly live · no tapping").font(BrandFont.body(11)).opacity(0.75)
                }
                .foregroundColor(Brand.onVolt)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    /// The camera's ruler: a plate of known size, or (without one) your height.
    @ViewBuilder private var ruler: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ruler").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                Spacer()
                if camera.plateLocked {
                    let lost = camera.plateLostSince.map { Date().timeIntervalSince($0) > 1 } ?? false
                    Text(lost ? "Plate lost — mark it again" : String(format: "Plate %.1f cm · following it", PlateRuler.diameterCm))
                        .font(BrandFont.body(12, .semibold)).foregroundColor(lost ? Brand.text : Brand.voltText)
                } else {
                    Text("Your height (rough)").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                }
            }
            Text(camera.plateLocked
                 ? "Recordings follow the bar end and measure it against the plate — true centimetres."
                 : "With a loaded bar, mark the end plate: the camera then follows the bar itself and measures in true centimetres.")
                .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { marking = true } label: {
                    Text(camera.plateLocked ? "Mark again" : "Mark the plate").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.voltText)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(rec.recording)
                if camera.plateLocked {
                    Button { camera.clearPlate() } label: {
                        Text("No plate").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                    }
                    .buttonStyle(.plain)
                    .disabled(rec.recording)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Draw a box around the plate on what the camera sees — that box (and the plate's real size) is the
/// ruler, and the camera follows it from then on.
struct PlateMarkSheet: View {
    @ObservedObject private var camera = DepthCamera.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart: CGPoint?
    @State private var box: CGRect?                    // Vision coordinates (0…1, origin bottom-left)
    @State private var plateCm = PlateRuler.diameterCm

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Set the loaded bar where the camera sees the end plate side-on (the plate facing the phone). Then draw a box tightly around the plate — edge to edge.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                    if let img = camera.snapshot {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay(GeometryReader { g in
                                ZStack(alignment: .topLeading) {
                                    Color.clear.contentShape(Rectangle())
                                    if let b = box {
                                        let r = CGRect(x: b.minX * g.size.width, y: (1 - b.maxY) * g.size.height,
                                                       width: b.width * g.size.width, height: b.height * g.size.height)
                                        Rectangle().stroke(Brand.volt, lineWidth: 3)
                                            .frame(width: r.width, height: r.height)
                                            .offset(x: r.minX, y: r.minY)
                                    }
                                }
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        let a = dragStart ?? v.startLocation
                                        dragStart = a
                                        let w = max(1, g.size.width), h = max(1, g.size.height)
                                        let x0 = min(max(min(a.x, v.location.x), 0), w), x1 = min(max(max(a.x, v.location.x), 0), w)
                                        let y0 = min(max(min(a.y, v.location.y), 0), h), y1 = min(max(max(a.y, v.location.y), 0), h)
                                        box = CGRect(x: x0 / w, y: 1 - y1 / h, width: (x1 - x0) / w, height: (y1 - y0) / h)
                                    }
                                    .onEnded { _ in dragStart = nil })
                            })
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Starting the camera…").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    Stepper(value: $plateCm, in: 20...50, step: 0.5) {
                        Text(String(format: "Plate diameter — %.1f cm", plateCm)).font(BrandFont.body(15)).foregroundColor(Brand.text)
                    }
                    Text("Standard 20 kg / 45 lb plates (bumper or competition): 45 cm. Iron 45s: about 44.5.")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    Button {
                        guard let b = box, b.width > 0.02, b.height > 0.02 else { return }
                        PlateRuler.diameterCm = plateCm
                        camera.lockPlate(b)
                        dismiss()
                    } label: {
                        Text("Use this plate").font(BrandFont.body(15, .heavy)).foregroundColor(Brand.onVolt)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled((box?.height ?? 0) <= 0.02)
                    .opacity((box?.height ?? 0) > 0.02 ? 1 : 0.4)
                }
                .padding(16)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Mark the plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .onAppear { camera.beginMarking() }
            .onDisappear { camera.endMarking() }
        }
    }
}
