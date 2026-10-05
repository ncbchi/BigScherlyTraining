import SwiftUI
import AVFoundation
import Photos
import UIKit
import Combine

// MARK: - Set videos
// With the toggle on, every set films itself with the front camera — from the moment it starts
// to the moment it ends (logged, or the Watch sees you rack it) — and saves to your Camera Roll,
// at 1080p where the camera supports it. It records only while the app is open on the workout
// screen (iOS doesn't allow the camera in the background), so a set started from the Watch or the
// Lock Screen with the phone locked simply isn't filmed. The camera warms up just before a set
// and switches off during rest, so it isn't running the whole workout.

@MainActor
final class SetVideoRecorder: ObservableObject {
    static let shared = SetVideoRecorder()
    private static let key = "bst_set_video"

    /// The card's toggle.
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: key) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if enabled { checkCameraAccess() } else { stopAll() }
        }
    }
    @Published private(set) var recording = false
    @Published private(set) var problem: String?
    /// The workout screen is showing (a set only records then).
    var screenVisible = false

    private let camera = SetCamera()
    private var coolDown: DispatchWorkItem?

    private init() {
        camera.onFinished = { url, usable in
            Task { @MainActor in SetVideoRecorder.shared.finished(url: url, usable: usable) }
        }
    }

    func clearProblem() { problem = nil }

    private var canFilm: Bool {
        enabled && screenVisible && !SetupEngine.shared.active      // the Watch setup uses the camera for depth
            && UIApplication.shared.applicationState == .active
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: The set loop's hooks (LiveSessionController)

    /// A set started: film it.
    func setStarted() {
        if enabled, AVCaptureDevice.authorizationStatus(for: .video) != .authorized { checkCameraAccess() }
        guard canFilm else { return }
        coolDown?.cancel()
        recording = true
        camera.start(to: FileManager.default.temporaryDirectory.appendingPathComponent("set-\(UUID().uuidString).mov"))
    }

    /// The set ended (logged, or the Watch saw it end): stop, and save.
    func setEnded() { camera.stop() }

    /// Just before a set (Start set showing, or the last seconds of rest): have the camera ready,
    /// so recording begins the instant the set does.
    func warm() {
        guard canFilm else { return }
        coolDown?.cancel()
        camera.warm()
    }

    /// Leaving the workout, or the toggle turned off: save anything recording, then switch off.
    func stopAll() {
        coolDown?.cancel()
        camera.stopAll()
    }

    private func checkCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in if !ok { SetVideoRecorder.shared.denied() } }
            }
        default: denied()
        }
    }

    private func denied() {
        enabled = false
        problem = "Camera access is off for Big Scherly. Turn it on in iOS Settings ▸ Big Scherly ▸ Camera to record your sets."
    }

    // MARK: Saving to the Camera Roll

    fileprivate func finished(url: URL, usable: Bool) {
        recording = false
        if usable { save(url) } else { try? FileManager.default.removeItem(at: url) }
        // The camera switches off during rest (it warms up again just before the next set).
        let w = DispatchWorkItem { [camera] in camera.coolDown() }
        coolDown = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func save(_ url: URL) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            problem = "To save set videos, add the Photos permission to Info.plist (Privacy - Photo Library Additions Usage Description)."
            try? FileManager.default.removeItem(at: url)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    SetVideoRecorder.shared.problem = "Photos access is off for Big Scherly. Turn it on in iOS Settings ▸ Big Scherly ▸ Photos to save your set videos."
                }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }, completionHandler: { _, _ in
                try? FileManager.default.removeItem(at: url)
            })
        }
    }
}

/// The front camera itself. Everything here runs on its own queue, off the main thread.
/// Video only for now: capturing sound would take over the phone's audio and could pause your music.
nonisolated final class SetCamera: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "bst.setvideo")
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var configured = false
    private var rotation: AVCaptureDevice.RotationCoordinator?
    var onFinished: (@Sendable (URL, Bool) -> Void)?

    func warm() { queue.async { self.prepare() } }

    func start(to url: URL) {
        queue.async {
            self.prepare()
            guard self.session.isRunning, !self.output.isRecording else { return }
            if let c = self.output.connection(with: .video) {
                let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture ?? 90   // upright, however it's propped
                if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
                if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
            }
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stop() { queue.async { if self.output.isRecording { self.output.stopRecording() } } }

    func stopAll() {
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
            else if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func coolDown() { queue.async { if !self.output.isRecording, self.session.isRunning { self.session.stopRunning() } } }

    /// The front camera at 1080p (where supported), started.
    private func prepare() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
               let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
                rotation = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)
            }
            if session.canAddOutput(output) { session.addOutput(output) }
            output.maxRecordedDuration = CMTime(seconds: 300, preferredTimescale: 600)   // a forgotten set stops at 5 min
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning { session.startRunning() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // An "error" can still leave a good file (hit the 5-minute cap, or the app was put away).
        let usable = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        onFinished?(url, usable)
    }
}

// MARK: - The card's toggle: solid accent with a black camera when on; the inverse when off.

struct SetVideoToggle: View {
    var compact = false
    @ObservedObject private var rec = SetVideoRecorder.shared
    @State private var pulse = false

    var body: some View {
        let d: CGFloat = compact ? 30 : 42
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { rec.enabled.toggle() }
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(rec.enabled ? Brand.volt : Brand.card)
                    .overlay(Circle().stroke(Brand.voltLine, lineWidth: rec.enabled ? 0 : 1.6))
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: d * 0.36, weight: .heavy))
                            .foregroundColor(rec.enabled ? Brand.onVolt : Brand.voltText)
                    )
                    .frame(width: d, height: d)
                if rec.recording {
                    Circle().fill(Color.red)
                        .frame(width: d * 0.3, height: d * 0.3)
                        .overlay(Circle().stroke(Brand.card, lineWidth: 2))
                        .opacity(pulse ? 0.35 : 1)
                        .offset(x: 2, y: -2)
                        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
                        .onDisappear { pulse = false }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rec.enabled ? "Set videos: on" : "Set videos: off")
        .accessibilityHint("Films each set with the front camera and saves it to your Camera Roll")
        .alert(rec.problem ?? "", isPresented: Binding(get: { rec.problem != nil }, set: { if !$0 { rec.clearProblem() } })) {
            Button("OK", role: .cancel) { rec.clearProblem() }
        }
    }
}
