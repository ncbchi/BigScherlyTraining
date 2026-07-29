import AVFoundation
import UIKit

// MARK: - Video compression
//
// Compresses a chat video ON THE DEVICE before it's ever uploaded, so we never
// push a raw 100MB+ clip to the server. Output is ~540p, trimmed to a hard
// 120-second cap, optimized for streaming. A typical phone clip drops from tens
// of megabytes to a few.
//
// If you later want even smaller files (HEVC at a pinned bitrate), swap the
// AVAssetExportSession below for an AVAssetReader/AVAssetWriter pipeline — the
// call site here doesn't change.
enum VideoCompressor {

    static let maxDuration: Double = 120     // seconds — hard cap

    struct Output {
        let url: URL             // compressed file in the temporary directory
        let thumbnail: UIImage?  // poster frame for the chat bubble
        let duration: Double     // seconds, after trimming
        let sizeBytes: Int
    }

    enum CompressionError: LocalizedError {
        case noExportSession
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noExportSession: return "Couldn't prepare the video for compression."
            case .exportFailed(let m): return "Video compression failed: \(m)"
            }
        }
    }

    /// Compress to 540p and trim to the first 120 seconds. Safe to call from a Task.
    static func compress(_ sourceURL: URL) async throws -> Output {
        let asset = AVURLAsset(url: sourceURL)

        // Trim to the first 120s if the clip is longer.
        let fullDuration = try await asset.load(.duration)
        let cap = CMTime(seconds: maxDuration, preferredTimescale: 600)
        let end = CMTimeMinimum(fullDuration, cap)
        let range = CMTimeRange(start: .zero, end: end)

        // 540p preset (960x540 bounding box, keeps aspect ratio for portrait clips).
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPreset960x540) else {
            throw CompressionError.noExportSession
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bst_video_\(UUID().uuidString).mp4")
        export.timeRange = range
        export.shouldOptimizeForNetworkUse = true

        // iOS 18+ async export — throws on failure, so there's no status/error
        // polling and nothing non-Sendable captured in a completion closure.
        do {
            try await export.export(to: outURL, as: .mp4)
        } catch {
            throw CompressionError.exportFailed(error.localizedDescription)
        }

        let thumb = try? await thumbnail(for: asset)
        let size = (try? Data(contentsOf: outURL, options: .mappedIfSafe).count) ?? 0
        return Output(url: outURL,
                      thumbnail: thumb,
                      duration: CMTimeGetSeconds(end),
                      sizeBytes: size)
    }

    /// Poster frame near the start of the clip, for the chat bubble preview.
    static func thumbnail(for asset: AVAsset) async throws -> UIImage {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cg = try await gen.image(at: time).image
        return UIImage(cgImage: cg)
    }
}
