import SwiftUI
import UIKit
import ImageIO

// MARK: - GIFs and GIF stickers for the Share editor (Oct 9, 2026)
// GIPHY is the only provider: Google shut Tenor's API to outside apps on June 30, 2026.
// Everything goes through `ShareGifProvider`, so another source can slot in later.
// GIPHY's terms: "Powered by GIPHY" wherever results show (both trays do).
//
// GIFs play by picking a frame for the current time (see StickerClock), so the same view
// animates in the editor and renders any single frame for the still image or the video.
//
// Target membership: BigScherlyTraining (automatic: it's in the app folder).

nonisolated struct ShareGif: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var preview: URL        // small, for the tray grid
    var full: URL           // what goes on the card
    var aspect: CGFloat     // width ÷ height
    var isSticker: Bool     // transparent sticker vs. a rectangular GIF
}

enum ShareGifKind { case gifs, stickers }

protocol ShareGifProvider {
    var attribution: String { get }
    /// Everything: trending when `query` is empty, otherwise a search. `offset` pages on.
    func search(_ query: String, _ kind: ShareGifKind, offset: Int) async throws -> [ShareGif]
}

final class GiphyProvider: ShareGifProvider {
    static let shared = GiphyProvider()
    private static let apiKey = "vyVlPEV5hB1mIjPe6zto76f4vowH9alw"
    /// All of GIPHY up to PG-13 (their default for apps).
    private static let rating = "pg-13"
    static let pageSize = 36
    let attribution = "Powered by GIPHY"

    func search(_ query: String, _ kind: ShareGifKind, offset: Int) async throws -> [ShareGif] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var extra = ["offset": "\(offset)"]
        if !q.isEmpty { extra["q"] = q }
        return try await fetch(kind, endpoint: q.isEmpty ? "trending" : "search", extra: extra)
    }

    private func fetch(_ kind: ShareGifKind, endpoint: String, extra: [String: String]) async throws -> [ShareGif] {
        let base = "https://api.giphy.com/v1/\(kind == .gifs ? "gifs" : "stickers")/\(endpoint)"
        guard var c = URLComponents(string: base) else { return [] }
        var q = [URLQueryItem(name: "api_key", value: Self.apiKey),
                 URLQueryItem(name: "limit", value: "\(Self.pageSize)"),
                 URLQueryItem(name: "rating", value: Self.rating),
                 URLQueryItem(name: "lang", value: "en")]
        for (k, v) in extra { q.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = q
        guard let url = c.url else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(GiphyResponse.self, from: data)
        return decoded.data.compactMap { $0.toGif(sticker: kind == .stickers) }
    }
}

nonisolated struct GiphyResponse: Decodable, Sendable {
    let data: [GiphyObject]
}

nonisolated struct GiphyObject: Decodable, Sendable {
    let id: String
    let title: String?
    let images: [String: GiphyRendition]

    func toGif(sticker: Bool) -> ShareGif? {
        // Tray: the 200-wide rendition as WebP (a fraction of the GIF's size, decodes faster).
        let small = images["fixed_width"] ?? images["fixed_width_small"]
        let big = images["downsized"] ?? images["fixed_width"] ?? images["original"]
        guard let p = small?.webpLink ?? small?.link, let b = big, let f = b.link else { return nil }
        let w = Double(b.width ?? "") ?? 200
        let h = Double(b.height ?? "") ?? 200
        return ShareGif(id: id, title: title ?? "", preview: p, full: f,
                        aspect: CGFloat(h > 0 ? w / h : 1), isSticker: sticker)
    }
}

nonisolated struct GiphyRendition: Decodable, Sendable {
    let url: String?
    let webp: String?
    let width: String?
    let height: String?
    var link: URL? { url.flatMap { URL(string: $0) } }
    var webpLink: URL? { webp.flatMap { URL(string: $0) } }
}

// MARK: - Decoded frames

nonisolated final class GifFrames: @unchecked Sendable {
    let images: [UIImage]
    let ends: [Double]        // cumulative end time of each frame
    let total: Double
    let cost: Int
    /// The whole loop as one animated image: UIImageView plays it on the GPU, so a screen
    /// full of GIFs costs the app nothing per frame.
    let animated: UIImage?

    init(images: [UIImage], delays: [Double], cost: Int) {
        self.images = images
        var t = 0.0
        var e: [Double] = []
        for d in delays { t += d; e.append(t) }
        self.ends = e
        self.total = max(t, 0.05)
        self.cost = cost
        if images.count > 1 {
            // UIImage animations use one frame length, so each frame repeats for its share
            // of 20 ms ticks (references only: no extra pixels).
            var seq: [UIImage] = []
            for (img, d) in zip(images, delays) {
                seq.append(contentsOf: Array(repeating: img, count: max(1, Int((d / 0.02).rounded()))))
            }
            self.animated = UIImage.animatedImage(with: seq, duration: Double(seq.count) * 0.02)
        } else {
            self.animated = images.first
        }
    }

    func frame(at time: Double) -> UIImage {
        guard images.count > 1 else { return images.first ?? UIImage() }
        let x = time.truncatingRemainder(dividingBy: total)
        let t = x < 0 ? x + total : x
        for (i, end) in ends.enumerated() where t < end { return images[i] }
        return images[images.count - 1]
    }
}

nonisolated enum GifDecoder {
    /// Frames scaled down to `maxPixel` on the long side, at most `maxFrames` of them
    /// (skipped frames hand their time to the one kept, so the loop keeps its speed).
    static func decode(_ data: Data, maxPixel: Int, maxFrames: Int) -> GifFrames? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        let step = max(1, Int((Double(n) / Double(max(1, maxFrames))).rounded(.up)))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        var images: [UIImage] = []
        var delays: [Double] = []
        var cost = 0
        var i = 0
        while i < n {
            var d = 0.0
            for k in i..<min(i + step, n) { d += delay(src, k) }
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                images.append(UIImage(cgImage: cg))
                delays.append(d)
                cost += cg.bytesPerRow * cg.height
            }
            i += step
        }
        guard !images.isEmpty else { return nil }
        return GifFrames(images: images, delays: delays, cost: cost)
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dict = (props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            ?? (props[kCGImagePropertyWebPDictionary] as? [CFString: Any])
        guard let g = dict else { return 0.1 }
        let unclamped = (g[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (g[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? 0
        let clamped = (g[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (g[kCGImagePropertyWebPDelayTime] as? Double) ?? 0
        let d = unclamped > 0.011 ? unclamped : clamped
        return d > 0.011 ? d : 0.1
    }
}

// MARK: - Cache

final class GifStore {
    static let shared = GifStore()
    private let cache = NSCache<NSString, GifFrames>()
    private var inflight: [String: Task<GifFrames?, Never>] = [:]

    private init() { cache.totalCostLimit = 140 * 1024 * 1024 }

    private static func key(_ url: URL, _ px: Int, _ frames: Int) -> String { "\(url.absoluteString)#\(px)#\(frames)" }

    /// Already decoded (synchronous, so a render picks it up straight away).
    func cached(_ url: URL, maxPixel: Int, maxFrames: Int) -> GifFrames? {
        cache.object(forKey: Self.key(url, maxPixel, maxFrames) as NSString)
    }

    // At most 4 downloads/decodes at once, so a tray full of GIFs never floods the phone.
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if running < 4 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    func load(_ url: URL, maxPixel: Int, maxFrames: Int) async -> GifFrames? {
        let k = Self.key(url, maxPixel, maxFrames)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let running = inflight[k] { return await running.value }
        await acquire()
        // Scrolled away while waiting: don't spend the slot on it.
        if Task.isCancelled { release(); return nil }
        if let hit = cache.object(forKey: k as NSString) { release(); return hit }
        if let running = inflight[k] { release(); return await running.value }
        defer { release() }
        let task = Task<GifFrames?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                GifDecoder.decode(data, maxPixel: maxPixel, maxFrames: maxFrames)
            }.value
        }
        inflight[k] = task
        let result = await task.value
        inflight[k] = nil
        if let result { cache.setObject(result, forKey: k as NSString, cost: result.cost) }
        return result
    }
}

// MARK: - Time for animated stickers
// In the editor stickers follow the clock; for the still and each video frame the
// export pins the time through the environment.

private struct ShareStickerTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }

extension EnvironmentValues {
    var shareStickerTime: Double? {
        get { self[ShareStickerTimeKey.self] }
        set { self[ShareStickerTimeKey.self] = newValue }
    }
}

struct StickerClock<Content: View>: View {
    @Environment(\.shareStickerTime) private var pinned
    private let content: (Double) -> Content

    init(@ViewBuilder _ content: @escaping (Double) -> Content) {
        self.content = content
    }

    var body: some View {
        if let pinned {
            content(pinned)
        } else {
            TimelineView(.animation) { ctx in
                content(ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

// MARK: - A playing GIF
// Live: a UIImageView playing the animated image (no SwiftUI work per frame).
// Export: the exact frame for the pinned time.

struct ShareGifImage: View {
    /// Sizes for a GIF placed on the card (the export preloads at the same size).
    static let cardPixel = 420
    static let cardFrames = 40
    static let trayPixel = 170
    static let trayFrames = 18

    let url: URL
    var maxPixel: Int = ShareGifImage.trayPixel
    var maxFrames: Int = ShareGifImage.trayFrames
    @Environment(\.shareStickerTime) private var pinned
    @State private var frames: GifFrames?

    var body: some View {
        let f = frames ?? GifStore.shared.cached(url, maxPixel: maxPixel, maxFrames: maxFrames)
        Group {
            if let f, let t = pinned {
                Image(uiImage: f.frame(at: t)).resizable()
            } else if let f, let a = f.animated {
                AnimatedImageView(image: a)
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        }
        .task(id: url) {
            if frames == nil {
                frames = await GifStore.shared.load(url, maxPixel: maxPixel, maxFrames: maxFrames)
            }
        }
    }
}

private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = image
        v.startAnimating()
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image }
        if !v.isAnimating { v.startAnimating() }
    }

    /// Take whatever size SwiftUI gives (the caller sets the aspect ratio and width).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? 100)
    }
}
