import SwiftUI
import UIKit
import AVFoundation
import Photos

// MARK: - Getting a share card out of the app (Oct 9, 2026)
// Stills come straight from ImageRenderer. When the card has GIFs or animated stickers it
// can also go out as a short looping video: each frame is the card rendered at that moment
// (StickerClock pins the time), written to an H.264 .mp4.
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

enum ShareVideo {
    static let seconds: Double = 3
    static let fps = 24

    /// Writes `seconds` of frames to a temporary .mp4. `frame(t)` returns the card at time t
    /// (pixel size `size`, which must be even on both sides).
    static func write(size: CGSize, seconds: Double = ShareVideo.seconds, fps: Int = ShareVideo.fps,
                      frame: (Double) -> CGImage?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bst-share-\(UUID().uuidString).mp4")
        let w = Int(size.width), h = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 4_000_000) }
            guard let cg = frame(Double(i) / Double(fps)), let pool = adaptor.pixelBufferPool else { continue }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: space, bitmapInfo: info) {
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            await Task.yield()     // keep the progress spinner turning
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }
        return url
    }
}

enum SharePhotos {
    /// Adds the card to Photos (add-only permission). Returns false if it couldn't.
    static func save(image: UIImage?, video: URL?) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if let video {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                } else if let image {
                    _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
            return true
        } catch {
            return false
        }
    }
}
