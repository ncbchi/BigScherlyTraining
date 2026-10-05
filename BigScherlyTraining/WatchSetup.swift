import SwiftUI
import UIKit
import Combine
import AVFoundation
import Vision

// MARK: - Watch setup
// A one-time body setup the first time your Watch joins a workout (hold still · overhead presses ·
// air squats to TRUE depth), and a bar-only setup the first time you squat, bench or deadlift.
// The Watch captures the setup set exactly as it measures any set; here we check the numbers are
// TRUE before accepting them — the deepest squat (hip crease below the knee, held), the bar resting
// on the chest, a full lockout, the bar settled on the floor — and coach the user to redo it if not.
// With the phone propped side-on, the camera confirms squat depth too (on-device, nothing saved).

// MARK: Lifts and their calibration

enum SetupLift: String, Codable, CaseIterable {
    case squat, bench, deadlift

    /// Which lift an exercise name is (barbell versions only, for now).
    static func match(_ name: String) -> SetupLift? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if ["squat", "back squat", "barbell squat", "barbell back squat", "high bar squat", "low bar squat"].contains(n) { return .squat }
        if ["bench", "bench press", "barbell bench", "barbell bench press", "flat bench", "flat bench press"].contains(n) { return .bench }
        if ["deadlift", "conventional deadlift", "barbell deadlift"].contains(n) { return .deadlift }
        return nil
    }

    var title: String { switch self { case .squat: return "Back Squat"; case .bench: return "Bench Press"; case .deadlift: return "Deadlift" } }
    /// The standard, in a few words — used in coach notes.
    var standard: String {
        switch self {
        case .squat: return "true depth"
        case .bench: return "bar on your chest"
        case .deadlift: return "full lockout, back to the floor"
        }
    }
}

struct LiftCalibration: Codable {
    var lift: SetupLift
    /// Bottom to top, metres — your full, true range for this lift (the deepest setup rep).
    var fullTravelM: Double
    /// Empty-bar speed, m/s — anchors the speed-to-load profile.
    var emptyBarMPS: Double
    var cameraVerified: Bool
    var date: Date

    private static let key = "bst_lift_calibrations"

    static func all() -> [SetupLift: LiftCalibration] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LiftCalibration].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.lift, $0) }, uniquingKeysWith: { a, _ in a })
    }
    static func saved(_ lift: SetupLift) -> LiftCalibration? { all()[lift] }
    static func forExercise(_ name: String) -> LiftCalibration? { SetupLift.match(name).flatMap(saved) }

    static func save(_ c: LiftCalibration) {
        var map = all(); map[c.lift] = c
        if let data = try? JSONEncoder().encode(Array(map.values)) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func clearAll() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: The steps

enum SetupMove { case still, press, airSquat, squat, bench, deadlift }

struct SetupStep {
    let move: SetupMove
    let title: String
    let target: Int                 // reps (0 = a hold)
    let cue: String                 // the standard, in the outlined box
    let instruction: String
    let watchTitle: String
    let watchHint: String
    let watchCaps: String
    var isStill: Bool { move == .still }
    var usesCamera: Bool { move == .airSquat || move == .squat }
}

enum SetupRequest: Identifiable, Equatable {
    case body
    case lift(SetupLift)
    var id: String { switch self { case .body: return "body"; case .lift(let l): return l.rawValue } }
}

// MARK: The engine

@MainActor
final class SetupEngine: ObservableObject {
    static let shared = SetupEngine()

    enum Phase: Equatable { case intro, ready, capturing, checking, retry(String), done }

    @Published var request: SetupRequest?
    @Published private(set) var phase: Phase = .intro
    @Published private(set) var stepIndex = 0
    @Published private(set) var liveReps: [RepMotion] = []
    @Published var useCamera = false {
        didSet { useCamera && step?.usesCamera == true ? DepthCamera.shared.start() : DepthCamera.shared.stop() }
    }
    /// Switched the camera check off this session: leave it off.
    private var cameraDeclined = false

    func toggleCamera() {
        useCamera.toggle()
        cameraDeclined = !useCamera
    }
    /// What it learned, in plain words (the done screen).
    @Published private(set) var summary: [(String, String)] = []

    var active: Bool { request != nil }
    /// No Go from the Watch for a while — the card suggests opening the app on the Watch.
    @Published private(set) var watchQuiet = false
    private var resendTask: Task<Void, Never>?
    var steps: [SetupStep] { request.map(Self.steps) ?? [] }
    var step: SetupStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    private static let bodyDoneKey = "bst_setup_body_done"
    private var skipped: Set<String> = []                // "workoutId|body" / "workoutId|squat" — for this workout
    private var workoutId: String?
    private var wrist = "left", crown = "right"
    private var bodyResults: [String: Double] = [:]
    private var bag = Set<AnyCancellable>()

    private init() {
        WatchBridge.shared.$liveRepMotions
            .receive(on: RunLoop.main)
            .sink { [weak self] reps in
                guard let self, self.phase == .capturing, self.step?.isStill == false else { return }
                self.liveReps = reps
            }
            .store(in: &bag)
    }

    static var bodyDone: Bool { UserDefaults.standard.bool(forKey: bodyDoneKey) }

    /// Between sets, with the Watch's session running: the first-time body setup, or a lift's
    /// first-time setup when that lift is next.
    func considerOffering(workout w: Workout) {
        guard request == nil, WatchBridge.shared.watchSessionLive else { return }
        let stage = LiveSessionController.shared.stage
        guard stage == .ready || stage == .done else { return }
        if !Self.bodyDone && !skipped.contains("\(w.id)|body") {
            open(.body, workout: w.id); return
        }
        guard let next = LiveSessionController.nextSet(w)?.0, let lift = SetupLift.match(next.name),
              LiftCalibration.saved(lift) == nil, !skipped.contains("\(w.id)|\(lift.rawValue)") else { return }
        open(.lift(lift), workout: w.id)
    }

    private func open(_ r: SetupRequest, workout: String) {
        workoutId = workout
        stepIndex = 0
        liveReps = []
        bodyResults = [:]
        summary = []
        phase = r == .body ? .intro : .ready
        SetVideoRecorder.shared.stopAll()              // the camera's free for the depth check
        request = r
        if phase == .ready { sendStep() }
    }

    func begin() { phase = .ready; sendStep() }

    /// "Later" / "Skip for now": not again this workout.
    func skip() {
        if let w = workoutId, let r = request { skipped.insert("\(w)|\(r.id)") }
        close()
    }

    func finish() { close() }

    private func close() {
        resendTask?.cancel()
        watchQuiet = false
        useCamera = false
        DepthCamera.shared.stop()
        WatchBridge.shared.sendSetup(["setupEnd": true])
        request = nil
    }

    /// Settings ▸ Redo Watch setup.
    static func resetAll() {
        UserDefaults.standard.set(false, forKey: bodyDoneKey)
        LiftCalibration.clearAll()
    }

    // MARK: The Watch

    /// The Watch (re)opened or came back in reach: send it the step it should be showing.
    func resendIfActive() {
        guard request != nil, step != nil else { return }
        switch phase {
        case .ready, .retry: transmitStep()
        default: break
        }
    }

    /// The step, to the Watch.
    private func transmitStep() {
        guard let s = step else { return }
        WatchBridge.shared.sendSetup(["setup": [
            "title": s.watchTitle, "hint": s.watchHint, "caps": s.watchCaps,
            "kind": s.isStill ? "still" : "reps", "target": s.target,
            "n": stepIndex + 1, "of": steps.count,
            "lift": request.map { r -> String in if case .lift(let l) = r { return l.rawValue } else { return "body" } } ?? "body"
        ] as [String: Any]])
    }

    /// Keep sending it every few seconds until the Watch says Go — a message to the Watch can be
    /// dropped if it isn't reachable at that exact moment.
    private func keepSending() {
        resendTask?.cancel()
        watchQuiet = false
        let index = stepIndex
        resendTask = Task { [weak self] in
            var waited = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                waited += 3
                guard let self, !Task.isCancelled, self.request != nil, self.stepIndex == index else { return }
                switch self.phase {
                case .ready, .retry:
                    self.transmitStep()
                    if waited >= 9 { self.watchQuiet = true }
                default:
                    return
                }
            }
        }
    }

    private func sendStep() {
        guard let s = step else { return }
        liveReps = []
        DepthCamera.shared.resetSighting()
        if s.usesCamera && !cameraDeclined && !useCamera { useCamera = true }      // on by default for squats
        if s.usesCamera, useCamera { DepthCamera.shared.start() } else if !s.usesCamera { DepthCamera.shared.stop() }
        transmitStep()
        keepSending()
    }

    func watchWentGo(wrist w: String?, crown c: String?) {
        resendTask?.cancel()
        watchQuiet = false
        if let w { wrist = w }
        if let c { crown = c }
        liveReps = []
        DepthCamera.shared.resetSighting()
        phase = .capturing
    }

    /// Setup reps as the Watch counts them (sent separately from workout sets).
    func watchLive(_ reps: [RepMotion]) {
        guard phase == .capturing, step?.isStill == false else { return }
        liveReps = reps
    }

    func watchStillDone() {
        guard step?.isStill == true else { return }
        accept()
    }

    func watchCaptured(_ reps: [RepMotion]) {
        guard let s = step, !s.isStill else { return }
        phase = .checking
        liveReps = reps
        if let problem = check(s, reps) {
            WatchBridge.shared.sendSetup(["setupRetry": problem])
            sendStep()                                  // the Watch shows Go again
            phase = .retry(problem)
            return
        }
        record(s, reps)
        accept()
    }

    private func accept() {
        WatchBridge.shared.sendSetup(["setupOK": true])
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            phase = .ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.sendStep() }
        } else {
            complete()
        }
    }

    // MARK: True numbers — what counts, and what to say when it doesn't

    /// nil = good. Otherwise, exactly what to fix.
    private func check(_ s: SetupStep, _ reps: [RepMotion]) -> String? {
        let need = s.move == .press ? 3 : (s.target >= 4 ? 3 : max(3, s.target - 2))
        guard reps.count >= need else {
            return reps.isEmpty ? "The Watch didn't pick up any reps — keep your Watch arm moving with the movement, and go again."
                                : "Only \(reps.count) rep\(reps.count == 1 ? "" : "s") counted — let's do the full set again."
        }
        let maxTravel = reps.map(\.travelM).max() ?? 0
        let short = reps.enumerated().filter { $0.element.travelM < 0.88 * maxTravel }.map { $0.offset + 1 }
        let first = reps[0]

        switch s.move {
        case .press:
            if !short.isEmpty { return "Rep \(short[0]) stopped short — press all the way overhead and back to your shoulders, every rep." }
        case .airSquat, .squat:
            if (first.bottomPauseSec ?? 0) < 1.5 {
                return "Hold still at the bottom of the first rep for two full seconds — at true depth, hip crease below your knee."
            }
            if useCamera, DepthCamera.shared.available, !DepthCamera.shared.sawDepth {
                return "The camera didn't see your hip go below your knee. Go lower — true depth, not comfortable depth."
            }
            if !short.isEmpty { return "Rep \(short[0]) was shallower than your deepest — same true depth every rep." }
        case .bench:
            if (first.bottomPauseSec ?? 0) < 1.5 {
                return "Rest the bar on your chest for two full seconds on the first rep — a real touch, not a hover."
            }
            if let bounce = reps.dropFirst().firstIndex(where: { ($0.bottomPauseSec ?? 0) < 0.25 }) {
                return "Rep \(bounce + 1) bounced — let the bar settle on your chest every rep."
            }
            if !short.isEmpty { return "Rep \(short[0]) didn't reach your chest — full touch, full lockout, every rep." }
        case .deadlift:
            if (first.topPauseSec ?? 0) < 1.5 {
                return "Lock out and hold for two full seconds at the top of the first rep — hips through, shoulders back."
            }
            if let tng = reps.dropFirst().firstIndex(where: { ($0.bottomPauseSec ?? 0) < 0.3 }) {
                return "Rep \(tng + 1) didn't settle — let the bar come to rest on the floor between every rep."
            }
            if !short.isEmpty { return "Rep \(short[0]) was short of lockout — stand all the way up, every rep." }
        case .still:
            break
        }
        return nil
    }

    private func record(_ s: SetupStep, _ reps: [RepMotion]) {
        let maxTravel = reps.map(\.travelM).max() ?? 0
        let speeds = reps.map(\.meanVelocity).sorted()
        let median = speeds.isEmpty ? 0 : speeds[speeds.count / 2]
        switch s.move {
        case .press: bodyResults["press"] = maxTravel
        case .airSquat:
            bodyResults["squat"] = maxTravel
            let paces = reps.map { ($0.eccentricSec ?? 0) + $0.concentricSec }
            bodyResults["pace"] = paces.reduce(0, +) / Double(max(1, paces.count))
        case .squat, .bench, .deadlift:
            guard case .lift(let lift)? = request else { return }
            LiftCalibration.save(LiftCalibration(lift: lift, fullTravelM: maxTravel, emptyBarMPS: median,
                                                 cameraVerified: useCamera && DepthCamera.shared.sawDepth, date: Date()))
            bodyResults["travel"] = maxTravel
            bodyResults["speed"] = median
        case .still: break
        }
    }

    private func complete() {
        let inches = { (m: Double) in StatsUnits.isKg ? String(format: "%.0f cm", m * 100) : String(format: "%.0f in", m * 39.37) }
        switch request {
        case .some(.body):
            UserDefaults.standard.set(true, forKey: Self.bodyDoneKey)
            summary = [("Steadiness", "Clean ✓"),
                       ("Wrist", "\(wrist.capitalized) · crown \(crown)"),
                       ("Pace", String(format: "%.1f s per rep", bodyResults["pace"] ?? 0)),
                       ("Squat range", inches(bodyResults["squat"] ?? 0))]
        case .some(.lift(let lift)):
            summary = [(lift == .squat ? "True depth" : lift == .bench ? "Chest to lockout" : "Floor to lockout", inches(bodyResults["travel"] ?? 0)),
                       ("Empty-bar speed", String(format: "%.2f m/s", bodyResults["speed"] ?? 0))]
            if lift == .squat, useCamera, DepthCamera.shared.sawDepth { summary.append(("Depth", "Camera-checked ✓")) }
        case .none: break
        }
        useCamera = false
        phase = .done
    }

    static func steps(_ r: SetupRequest) -> [SetupStep] {
        switch r {
        case .body:
            return [
                SetupStep(move: .still, title: "Hold still", target: 0,
                          cue: "Arms relaxed at your sides, feet planted.",
                          instruction: "Tap Go on your Watch, then don't move for three seconds while it checks the sensor.",
                          watchTitle: "Hold still", watchHint: "Tap, then stand still", watchCaps: "HOLD STILL"),
                SetupStep(move: .press, title: "Overhead presses", target: 3,
                          cue: "All the way up — arms locked overhead — and all the way back to your shoulders.",
                          instruction: "Empty hands, like pressing a bar: three slow reps, about two seconds each way.",
                          watchTitle: "Overhead presses", watchHint: "Full lockout, back to shoulders", watchCaps: "FULL RANGE"),
                SetupStep(move: .airSquat, title: "Air squats", target: 5,
                          cue: "True depth: hip crease below the top of your knee — and hold the first one for two seconds.",
                          instruction: "Arms straight out in front. This teaches the Watch where your real bottom is — not where it's comfortable.",
                          watchTitle: "Air squats", watchHint: "True depth · hold the first 2 s", watchCaps: "HIP BELOW KNEE"),
            ]
        case .lift(.squat):
            return [SetupStep(move: .squat, title: "Set up your squat", target: 4,
                              cue: "True depth: hip crease below the top of your knee. Not where it's comfortable — where it counts.",
                              instruction: "Just the bar. Unrack and stand tall, then squat to true depth and hold two seconds. Stand up, then three more reps to the same depth.",
                              watchTitle: "Squat setup", watchHint: "Hold at true depth 2 s, then 3 reps", watchCaps: "HIP BELOW KNEE")]
        case .lift(.bench):
            return [SetupStep(move: .bench, title: "Set up your bench", target: 4,
                              cue: "The bar rests on your chest — a real touch, every rep. No bounce, no hover.",
                              instruction: "Just the bar. Lock out, lower until the bar rests on your chest and hold two seconds, press. Then three more, touching every time.",
                              watchTitle: "Bench setup", watchHint: "Rest on chest 2 s, then 3 reps", watchCaps: "BAR ON CHEST")]
        case .lift(.deadlift):
            return [SetupStep(move: .deadlift, title: "Set up your deadlift", target: 4,
                              cue: "Full lockout at the top, and the bar settles on the floor between every rep.",
                              instruction: "Just the bar. Set up, lift to a full lockout and hold two seconds, lower to the floor. Then three more, settling each one.",
                              watchTitle: "Deadlift setup", watchHint: "Hold lockout 2 s, settle every rep", watchCaps: "LOCKED OUT")]
        }
    }
}

// MARK: - Camera depth check (squats): on-device body tracking, nothing recorded or saved

@MainActor
final class DepthCamera: ObservableObject {
    static let shared = DepthCamera()
    enum Status: Equatable { case off, lookingForYou, high, atDepth }

    @Published private(set) var status: Status = .off
    @Published private(set) var sawDepth = false
    let rig = DepthRig()
    private var depthSince: Date?

    var available: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized && status != .off }

    private init() {
        rig.onReading = { reading in
            Task { @MainActor in DepthCamera.shared.apply(reading) }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .lookingForYou
            rig.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in if ok { DepthCamera.shared.start() } else { SetupEngine.shared.useCamera = false } }
            }
        default:
            SetupEngine.shared.useCamera = false
        }
    }

    func stop() { rig.stop(); status = .off; depthSince = nil }

    func resetSighting() { sawDepth = false; depthSince = nil }

    /// nil = no person found; true = hip below knee.
    private func apply(_ reading: Bool?) {
        guard status != .off else { return }
        switch reading {
        case .none: status = .lookingForYou; depthSince = nil
        case .some(false): status = .high; depthSince = nil
        case .some(true):
            status = .atDepth
            if depthSince == nil { depthSince = Date() }
            if let s = depthSince, Date().timeIntervalSince(s) >= 0.4 { sawDepth = true }    // held, not a flicker
        }
    }
}

/// The camera and Vision, on their own queue.
nonisolated final class DepthRig: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bst.depthcheck")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var frame = 0
    var onReading: (@Sendable (Bool?) -> Void)?

    func start() {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720
                if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                if let c = self.output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }  // upright
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frame += 1
        guard frame % 3 == 0, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }   // ~10 a second
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        guard let body = request.results?.first,
              let pts = try? body.recognizedPoints(.all) else { onReading?(nil); return }
        // The side facing the camera (more confident), hip vs knee. Vision's y runs upward.
        func pair(_ hip: VNHumanBodyPoseObservation.JointName, _ knee: VNHumanBodyPoseObservation.JointName) -> (Double, Double, Double)? {
            guard let h = pts[hip], let k = pts[knee], h.confidence > 0.3, k.confidence > 0.3 else { return nil }
            return (Double(h.location.y), Double(k.location.y), Double(h.confidence + k.confidence))
        }
        let sides = [pair(.leftHip, .leftKnee), pair(.rightHip, .rightKnee)].compactMap { $0 }
        guard let best = sides.max(by: { $0.2 < $1.2 }) else { onReading?(nil); return }
        onReading?(best.0 < best.1 - 0.01)          // hip crease below the top of the knee
    }
}

/// The live camera, small, so you can see you're in frame.
struct DepthPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer.cornerRadius = 14
        v.clipsToBounds = true
        v.previewLayer.session = DepthCamera.shared.rig.session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - The card (your theme's background; the elements in your accent)

struct SetupSheet: View {
    @ObservedObject private var engine = SetupEngine.shared
    @ObservedObject private var camera = DepthCamera.shared
    /// The content's height: the card takes only as much of the screen as it needs.
    @State private var contentHeight: CGFloat = 480

    // Theme roles: text and greys from the theme; the accent for the elements (readable on any theme).
    private var accent: Color { Brand.volt }          // fills
    private var accentText: Color { Brand.voltText }  // accent text and icons
    private var accentLine: Color { Brand.voltLine }  // figures, outlines, progress
    private var onAccent: Color { Brand.onVolt }      // text on an accent fill

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch engine.phase {
                case .intro: intro
                case .done: done
                default: stepView
                }
            }
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundColor(Brand.text)
        .background(Brand.bg.ignoresSafeArea())
        .presentationDetents([.height(min(contentHeight, UIScreen.main.bounds.height - 60))])
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: contentHeight)
    }

    // MARK: Intro (body setup only)

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ONE-TIME SETUP").font(BrandFont.body(11, .heavy)).tracking(1.8).foregroundColor(accentText)
            Text("SET UP YOUR WATCH").font(BrandFont.display(34))
            Text("Sixty seconds, three moves. It teaches your Watch how you move — so reps, bar speed and depth read true.")
                .font(BrandFont.body(14, .medium)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(SetupEngine.steps(.body).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 12) {
                    SetupFigure(move: s.move, ink: accentLine, bg: Brand.card, animated: false)
                        .frame(width: 52, height: 66)
                        .background(RoundedRectangle(cornerRadius: 10).fill(accentLine.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(BrandFont.body(15, .heavy))
                        Text(s.target > 0 ? "\(s.target) reps" : "3 seconds").font(BrandFont.body(12, .medium)).foregroundColor(Brand.mute)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
            }
            Text("Each lift gets its own quick setup the first time you do it — with just the bar.")
                .font(BrandFont.body(12, .medium)).foregroundColor(Brand.mute)
            primary("Start") { engine.begin() }
            Button { engine.skip() } label: {
                Text("Later").font(BrandFont.body(14, .bold)).foregroundColor(Brand.mute).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: A step

    @ViewBuilder
    private var stepView: some View {
        if let s = engine.step {
            VStack(alignment: .leading, spacing: 14) {
                header(s)
                Text(s.title.uppercased()).font(BrandFont.display(32)).lineLimit(2).minimumScaleFactor(0.8)
                if case .lift? = engine.request { liftChips(s) }
                ZStack(alignment: .topTrailing) {
                    SetupFigure(move: s.move, ink: accentLine, bg: Brand.card, animated: true)
                        .frame(height: 230).frame(maxWidth: .infinity)
                    if s.usesCamera && engine.useCamera { cameraInset }
                }
                .background(RoundedRectangle(cornerRadius: 22).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.line, lineWidth: 1))
                if s.target > 0 { counter(s) }
                cueBox(s.cue)
                Text(s.instruction).font(BrandFont.body(14, .medium)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                if s.usesCamera { cameraToggle }
                status(s)
                Button { engine.skip() } label: {
                    Text(engine.request == .body ? "Skip setup" : "Skip for now").font(BrandFont.body(14, .bold))
                        .foregroundColor(Brand.mute).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private func header(_ s: SetupStep) -> some View {
        HStack(spacing: 8) {
            if case .lift(let l)? = engine.request {
                Text("FIRST TIME · \(l.title.uppercased())").font(BrandFont.body(11, .heavy)).tracking(1.6).foregroundColor(accentText)
                Spacer()
                Text("Just the bar").font(BrandFont.body(12, .heavy)).foregroundColor(accentText)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().stroke(accentLine, lineWidth: 1.5))
            } else {
                Text("STEP \(engine.stepIndex + 1) OF \(engine.steps.count)").font(BrandFont.body(11, .heavy)).tracking(1.6).foregroundColor(accentText)
                HStack(spacing: 5) {
                    ForEach(0..<engine.steps.count, id: \.self) { i in
                        Capsule().fill(i <= engine.stepIndex ? accentLine : Brand.line).frame(height: 5)
                    }
                }
            }
        }
    }

    /// The lift's phases, following the Watch's reps: the held bottom (or lockout) first, then the reps.
    private func liftChips(_ s: SetupStep) -> some View {
        let labels: [String] = s.move == .deadlift ? ["At the floor", "Lockout hold", "3 reps"]
            : s.move == .bench ? ["Lockout", "On chest", "3 reps"] : ["Top", "True depth", "3 reps"]
        let n = engine.liveReps.count
        let current = engine.phase == .capturing ? (n == 0 ? 1 : 2) : 0
        return HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                Text((i < current ? "✓ " : "") + l).font(BrandFont.body(11.5, .heavy))
                    .foregroundColor(i == current ? onAccent : (i < current ? accentText : Brand.mute))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == current ? accent : (i < current ? accentLine.opacity(0.12) : Brand.card)))
            }
        }
    }

    private func counter(_ s: SetupStep) -> some View {
        let n = engine.liveReps.count
        let shown = s.move == .press || s.move == .airSquat ? n : max(0, n - 1)
        let of = s.move == .press || s.move == .airSquat ? s.target : 3
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(min(shown, of))").font(BrandFont.display(44)).foregroundColor(accentText)
            Text("/ \(of)").font(BrandFont.display(26)).foregroundColor(Brand.mute)
            Spacer()
            Text("REPS").font(BrandFont.body(11, .heavy)).tracking(1.2).foregroundColor(Brand.mute)
        }
        .animation(.spring(response: 0.3), value: n)
    }

    private func cueBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "scope").font(.system(size: 14, weight: .heavy)).foregroundColor(accentText)
            Text(text).font(BrandFont.body(13, .heavy)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(accentLine.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accentLine, lineWidth: 1.5))
    }

    private var cameraToggle: some View {
        Button { engine.toggleCamera() } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.useCamera ? "camera.fill" : "camera").font(.system(size: 14, weight: .heavy))
                    .foregroundColor(accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.useCamera ? "Camera is checking your depth" : "Check my depth with the camera").font(BrandFont.body(13, .heavy))
                    Text("Prop the phone side-on, about 2 m away. Nothing is recorded.").font(BrandFont.body(11, .medium)).foregroundColor(Brand.mute)
                }
                Spacer()
                Image(systemName: engine.useCamera ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .bold))
                    .foregroundColor(engine.useCamera ? accentText : Brand.mute)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(engine.useCamera ? accentLine : Brand.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var cameraInset: some View {
        VStack(spacing: 6) {
            DepthPreview().frame(width: 96, height: 128)
            Text(cameraLabel).font(BrandFont.body(10, .heavy)).tracking(0.8)
                .foregroundColor(camera.status == .atDepth ? onAccent : Brand.text)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(camera.status == .atDepth ? accent : Brand.bg.opacity(0.85)))
        }
        .padding(10)
    }

    private var cameraLabel: String {
        switch camera.status {
        case .off: return "CAMERA OFF"
        case .lookingForYou: return "STEP INTO VIEW"
        case .high: return "GO LOWER"
        case .atDepth: return "AT DEPTH ✓"
        }
    }

    @ViewBuilder
    private func status(_ s: SetupStep) -> some View {
        switch engine.phase {
        case .retry(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 16, weight: .heavy))
                        .foregroundColor(accentText)
                    Text("Let's do that again").font(BrandFont.body(14, .heavy))
                }
                Text(message).font(BrandFont.body(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                watchRow("Tap Go on your Watch when you're set")
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accentLine, lineWidth: 1.5))
        case .capturing:
            watchRow(s.isStill ? "Measuring — hold still…" : "Watching your reps…")
        case .checking:
            watchRow("Checking your numbers…")
        default:
            VStack(alignment: .leading, spacing: 8) {
                watchRow("Tap Go on your Watch — right before you touch the weight")
                if engine.watchQuiet {
                    let build = WatchBridge.shared.watchBuild
                    let stale = build != WatchBridge.expectedWatchBuild
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundColor(accentText)
                        Text(stale
                             ? "Your Watch is running an older build of the app (\(build ?? "before build tags")) — it needs \(WatchBridge.expectedWatchBuild) for setup. Install the latest Watch app, then open it."
                             : "Not seeing Go? Open Big Scherly on your Watch — the step appears as soon as it's open.")
                            .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func watchRow(_ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "applewatch").font(.system(size: 15, weight: .bold)).foregroundColor(accentText)
            Text(text).font(BrandFont.body(13, .bold))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64, weight: .bold)).foregroundColor(accentText)
                .frame(maxWidth: .infinity).padding(.top, 4)
            Text(engine.request == .body ? "YOUR WATCH IS SET UP" : "SETUP DONE")
                .font(BrandFont.display(30)).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Text("Here's what it learned:").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
            VStack(spacing: 0) {
                ForEach(Array(engine.summary.enumerated()), id: \.offset) { _, kv in
                    HStack {
                        Text(kv.0).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.mute)
                        Spacer()
                        Text(kv.1).font(BrandFont.body(14, .heavy))
                    }
                    .padding(.vertical, 12)
                    Rectangle().fill(Brand.line).frame(height: 1)
                }
            }
            Text(engine.request == .body
                 ? "Each lift gets its own quick setup the first time you lift it — with just the bar. Redo this any time in Settings."
                 : "Every rep is measured against this range now — short ones get flagged, so the numbers stay true.")
                .font(BrandFont.body(12, .medium)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            primary("Back to workout") { engine.finish() }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(BrandFont.body(16, .heavy)).foregroundColor(onAccent)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The figures (2D vector, drawn here — same poses as the mockups)

struct SetupFigure: View {
    let move: SetupMove
    let ink: Color
    let bg: Color
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.animation) { ctx in
                Canvas { g, size in draw(g, size, phase(ctx.date)) }
            }
        } else {
            Canvas { g, size in draw(g, size, stillPhase) }
        }
    }

    private var duration: Double {
        switch move { case .still: return 2.4; case .press: return 4; case .airSquat, .squat: return 4.2; case .bench: return 4; case .deadlift: return 4.4 }
    }
    private var stillPhase: Double { move == .press ? 1 : (move == .airSquat || move == .squat) ? 1 : 0 }

    /// 0 = start pose, 1 = the far pose: move there, hold, come back (the hold is where the Watch marks it).
    private func phase(_ d: Date) -> Double {
        let t = d.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
        func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        if t < 0.4 { return ease(t / 0.4) }
        if t < 0.6 { return 1 }
        return 1 - ease((t - 0.6) / 0.4)
    }

    private func draw(_ g: GraphicsContext, _ size: CGSize, _ p: Double) {
        let s = min(size.width / 200, size.height / 280)
        let ox = (size.width - 200 * s) / 2
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: (y + 10) * s) }
        func line(_ a: CGPoint, _ b: CGPoint, _ w: Double, _ c: Color) {
            var path = Path(); path.move(to: a); path.addLine(to: b)
            g.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: w * s, lineCap: .round))
        }
        func poly(_ pts: [CGPoint], _ w: Double, _ c: Color) {
            var path = Path(); path.addLines(pts)
            g.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: w * s, lineCap: .round, lineJoin: .round))
        }
        func dashed(_ y: Double, _ label: String) {
            var path = Path(); path.move(to: P(44, y)); path.addLine(to: P(176, y))
            g.stroke(path, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 2 * s, dash: [5 * s, 6 * s]))
            g.draw(Text(label).font(.system(size: 10 * s, weight: .heavy)).foregroundColor(ink.opacity(0.75)), at: P(176, y - 8), anchor: .trailing)
        }
        func plate(_ c: CGPoint, _ r: Double) {
            let rect = CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)
            g.fill(Path(ellipseIn: rect), with: .color(ink.opacity(0.10)))
            g.stroke(Path(ellipseIn: rect), with: .color(ink), lineWidth: 3.5 * s)
            g.fill(Path(ellipseIn: CGRect(x: c.x - 4 * s, y: c.y - 4 * s, width: 8 * s, height: 8 * s)), with: .color(ink))
        }
        func watchMark(_ c: CGPoint, _ angle: Double) {
            var t = g
            t.translateBy(x: c.x, y: c.y); t.rotate(by: .radians(angle))
            let r = Path(roundedRect: CGRect(x: -7 * s, y: -9 * s, width: 14 * s, height: 18 * s), cornerRadius: 4 * s)
            t.fill(r, with: .color(bg)); t.stroke(r, with: .color(ink), lineWidth: 2.5 * s)
        }
        let body = ink.opacity(0.9), limb = ink
        // the floor
        line(P(30, 258), P(180, 258), 2, ink.opacity(0.4))

        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        func rot(_ a: Double, _ x: Double, _ y: Double) -> (Double, Double) {
            let r = a * .pi / 180
            return (x * cos(r) - y * sin(r), x * sin(r) + y * cos(r))
        }

        if move == .bench {
            // bench + lifter lying; the bar comes to the chest and holds
            let bench = Path(roundedRect: CGRect(x: P(40, 158).x, y: P(40, 158).y, width: 128 * s, height: 12 * s), cornerRadius: 5 * s)
            g.fill(bench, with: .color(ink.opacity(0.35)))
            line(P(60, 170), P(60, 256), 7, ink.opacity(0.35)); line(P(148, 170), P(148, 256), 7, ink.opacity(0.35))
            dashed(136, "CHEST")
            line(P(66, 148), P(130, 148), 20, body)
            g.fill(Path(ellipseIn: CGRect(x: P(35, 129).x, y: P(35, 129).y, width: 30 * s, height: 30 * s)), with: .color(body))
            poly([P(130, 150), P(166, 172), P(176, 250)], 15, body)
            line(P(176, 252), P(194, 252), 10, body)
            let e = (lerp(80, 62), lerp(110, 170)), h = (lerp(84, 88), lerp(72, 136))
            poly([P(78, 146), P(e.0, e.1), P(h.0, h.1)], 12, limb)
            plate(P(h.0, h.1), 22)
            watchMark(P(h.0, h.1 + 2), 0)
            return
        }

        // standing figures: forward kinematics from the hip
        var bx = 0.0, by = 0.0, torso = 0.0, arm = 0.0, thigh = 0.0, shin = 0.0, foot = 0.0
        switch move {
        case .airSquat, .squat:   // TRUE depth: hip below knee
            bx = lerp(0, -20); by = lerp(0, 84); torso = lerp(0, 40)
            thigh = lerp(0, -95.7); shin = lerp(0, 139.3); foot = lerp(0, -43.6)
            arm = lerp(-90, -130)
        case .deadlift:           // starts at the floor, locks out
            let q = 1 - p
            bx = -30 * q; by = 60 * q; torso = 55 * q; arm = -55 * q
            thigh = -82.6 * q; shin = 112.1 * q; foot = -29.5 * q
        default: break
        }
        let hip = (100 + bx, 130 + by)
        func at(_ base: (Double, Double), _ a: Double, _ x: Double, _ y: Double) -> CGPoint {
            let r = rot(a, x, y); return P(base.0 + r.0, base.1 + r.1)
        }
        let knee = at(hip, thigh, 0, 60)
        let kneeW = (Double(knee.x - ox) / s, Double(knee.y) / s - 10)
        let ankle = at(kneeW, thigh + shin, 0, 60)
        let ankleW = (Double(ankle.x - ox) / s, Double(ankle.y) / s - 10)

        if move == .airSquat || move == .squat { dashed(207, "KNEE") }
        if move == .deadlift { dashed(150, "LOCKOUT") }

        // legs
        line(P(hip.0, hip.1), knee, 17, body)
        line(knee, ankle, 15, body)
        line(at(ankleW, thigh + shin + foot, -2, 2), at(ankleW, thigh + shin + foot, 20, 2), 10, body)
        // torso + head
        line(P(hip.0, hip.1), at(hip, torso, 0, -68), 20, body)
        let head = at(hip, torso, 0, -94)
        g.fill(Path(ellipseIn: CGRect(x: head.x - 17 * s, y: head.y - 17 * s, width: 34 * s, height: 34 * s)), with: .color(body))
        let shoulderW: (Double, Double) = { let r = rot(torso, 0, -62); return (hip.0 + r.0, hip.1 + r.1) }()

        switch move {
        case .squat:   // bar on the upper back, hands on the bar
            plate(at(hip, torso, -12, -50), 22)
            poly([at(hip, torso, 0, -56), at(hip, torso, -20, -26), at(hip, torso, -14, -46)], 12, limb)
            watchMark(at(hip, torso, -14, -46), torso * .pi / 180)
        case .press:   // empty-hand overhead press: shoulders to lockout and back
            let e = (lerp(122, 102), lerp(88, 30)), h = (lerp(108, 102), lerp(58, -4))
            poly([P(shoulderW.0, shoulderW.1), P(e.0, e.1), P(h.0, h.1)], 12, limb)
            watchMark(P(h.0, h.1 + 6), 0)
        default:
            let hand = at(shoulderW, torso + arm, 0, 68)
            line(P(shoulderW.0, shoulderW.1), hand, 13, limb)
            watchMark(at(shoulderW, torso + arm, 0, 58), (torso + arm) * .pi / 180)
            if move == .deadlift { plate(hand, 30) }
        }
        // hip marker on squats: it has to drop below the knee line
        if move == .airSquat || move == .squat {
            let c = P(hip.0, hip.1)
            let r = CGRect(x: c.x - 6.5 * s, y: c.y - 6.5 * s, width: 13 * s, height: 13 * s)
            g.fill(Path(ellipseIn: r), with: .color(bg)); g.stroke(Path(ellipseIn: r), with: .color(ink), lineWidth: 3 * s)
        }
        // hold-still: rings pulse at the Watch
        if move == .still {
            let w = P(100, 140)
            let t = Date().timeIntervalSinceReferenceDate
            for k in 0..<3 {
                let f = ((t / 2.4) + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let r = (8 + 26 * f) * s
                g.stroke(Path(ellipseIn: CGRect(x: w.x - r, y: w.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(ink.opacity(0.9 * (1 - f))), lineWidth: 2.2 * s)
            }
        }
    }
}
