import SwiftUI
import UIKit
import Combine

// MARK: - Debug recorder, phone side (DEVELOPER TOOL — removed before release)
// Settings ▸ Apple Watch setup ▸ Motion captures ▸ Record. Pick the lift and arm it: the Watch shows
// a Record tile (tap, do reps, tap to stop — as many recordings as you like). The camera follows your
// wrist (hips on squats) while the Watch records, and each recording lands in Motion captures.
// "Share all" sends every capture as one text file (AirDrop it to the Mac).
//
// Lives in the app folder (added automatically).

@MainActor
final class PhoneDebugRecorder: ObservableObject {
    static let shared = PhoneDebugRecorder()

    enum Lift: String, CaseIterable, Identifiable {
        case press, airSquat, squat, bench, deadlift
        var id: String { rawValue }
        var title: String {
            switch self {
            case .press: return "Overhead press"
            case .airSquat: return "Air squat"
            case .squat: return "Squat"
            case .bench: return "Bench press"
            case .deadlift: return "Deadlift"
            }
        }
        /// Lifts first, then lowers (press, deadlift) — or the other way round.
        var upFirst: Bool { self == .press || self == .deadlift }
        /// What the camera follows: hips for squats, the wrist otherwise.
        var move: SetupMove {
            switch self {
            case .press: return .press
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
        if armed && !recording { sendArm() }
    }

    private func sendArm() {
        WatchBridge.shared.sendEvent(["dbgArm": ["lift": lift.rawValue, "title": lift.title,
                                                 "upFirst": lift.upFirst ? 1 : 0] as [String: Any]])
    }

    func end(fromWatch: Bool = false) {
        guard armed else { return }
        armed = false
        recording = false
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
            .disabled(rec.recording)
            if rec.armed && tracking {
                DepthPreview()
                    .frame(height: 180)
                    .overlay(alignment: .bottomLeading) {
                        Text(camera.poseSeen ? "You're in view" : "Step into view, side-on")
                            .font(BrandFont.body(11, .heavy)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(8)
                    }
            }
            if tracking { ruler }
            Button {
                if rec.armed { rec.end() } else { rec.arm() }
            } label: {
                Text(rec.armed ? "Stop recording mode" : "Arm the Watch")
                    .font(BrandFont.body(15, .heavy))
                    .foregroundColor(rec.armed ? Brand.voltText : Brand.onVolt)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(rec.armed ? Color.clear : Brand.volt))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: rec.armed ? 1.5 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
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
