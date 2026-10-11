import SwiftUI
import AVFoundation
import UIKit

// MARK: - Share camera
// A live camera inside the share card: the viewfinder sits exactly where the
// photo goes, with the stats, logo, scrim and volt border drawn on top, so what
// you frame is what gets posted. Shutter → freeze frame → Retake or Use Photo.

struct ShareCameraView: View {
    let format: ShareFormat
    /// The card's overlay (stats, logo, border) with a clear photo area.
    let chrome: AnyView
    var onFinish: (UIImage?) -> Void

    @State private var camera = CameraSession()
    @State private var captured: UIImage? = nil
    @State private var capturing = false
    @State private var flash = false

    var body: some View {
        GeometryReader { geo in
            // Fit the card in the screen, leaving room for the controls.
            let maxW = geo.size.width - 32
            let maxH = geo.size.height - 190
            let s = min(maxW / format.layoutWidth, maxH / format.layoutHeight)
            let cw = format.layoutWidth * s
            let ch = format.layoutHeight * s

            VStack(spacing: 0) {
                HStack {
                    Button { camera.stop(); onFinish(nil) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    Spacer()
                    Text(format.rawValue.uppercased())
                        .font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(BrandDark.volt)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer(minLength: 8)

                ZStack {
                    // Photo area = the whole card, edge to edge (the Share editor's card is full-bleed).
                    Group {
                        if let img = captured {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            CameraPreview(session: camera.session)
                        }
                    }
                    .frame(width: cw, height: ch)
                    .clipShape(RoundedRectangle(cornerRadius: 18 * s))

                    // Stats, logo, scrim and border — the real card, composed at its
                    // canonical size and scaled, exactly like the Share screen preview.
                    chrome
                        .frame(width: format.layoutWidth, height: format.layoutHeight)
                        .scaleEffect(s)
                        .frame(width: cw, height: ch)
                        .allowsHitTesting(false)

                    if flash {
                        RoundedRectangle(cornerRadius: 18 * s).fill(Color.white)
                            .frame(width: cw, height: ch)
                    }
                }
                .frame(width: cw, height: ch)

                Spacer(minLength: 8)

                controls.padding(.bottom, 24)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .statusBarHidden()
    }

    @ViewBuilder
    private var controls: some View {
        if let img = captured {
            HStack(spacing: 14) {
                Button { captured = nil } label: {
                    Text("RETAKE")
                        .font(BrandFont.body(14, .bold)).tracking(1.5).foregroundColor(BrandDark.volt)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .overlay(Capsule().stroke(BrandDark.volt, lineWidth: 2))
                }
                Button { camera.stop(); onFinish(img) } label: {
                    Text("USE PHOTO")
                        .font(BrandFont.body(14, .bold)).tracking(1.5).foregroundColor(BrandDark.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Capsule().fill(BrandDark.volt))
                }
            }
            .padding(.horizontal, 24)
        } else {
            HStack {
                Color.clear.frame(width: 52, height: 52)
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(capturing ? BrandDark.mute : Color.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(capturing)
                Spacer()
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private func shoot() {
        capturing = true
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.2)) { flash = false }
        }
        camera.capture { image in
            capturing = false
            if let image { captured = image }
        }
    }
}

// MARK: - Live preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90   // portrait
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill   // same crop the card uses (scaledToFill)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Capture session (runs on its own queue)

nonisolated final class CameraSession: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "bst.camera.session")
    private var input: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var completion: (@MainActor (UIImage?) -> Void)?

    func start() {
        queue.async {
            if self.input == nil { self.configure(self.position) }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flip() {
        queue.async {
            self.configure(self.position == .back ? .front : .back)
        }
    }

    /// Delivers the photo (or nil) on the main thread.
    func capture(_ done: @escaping @MainActor (UIImage?) -> Void) {
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            self.completion = done
            self.applyConnectionSettings()
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func configure(_ pos: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }
        if let old = input { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
            position = pos
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)   // put the previous camera back
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        applyConnectionSettings()
    }

    /// Portrait, and mirrored on the front camera so the photo matches the preview.
    private func applyConnectionSettings() {
        guard let c = output.connection(with: .video) else { return }
        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = (position == .front)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(image) }
    }
}
