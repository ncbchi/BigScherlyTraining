import SwiftUI
import CoreMotion
import CoreText
import Combine

// MARK: - Motion manager (gyroscope / device attitude)
// Drives the metallic sheen on "QUEENS" so the rainbow shifts as the phone tilts.
// Also runs a continuous idle wave so the shimmer is dramatic even when held still.
final class MotionManager: ObservableObject {
    private let manager = CMMotionManager()
    @Published var roll: Double = 0    // -1 ... 1 normalized
    @Published var pitch: Double = 0
    @Published var wave: Double = 0    // continuous 0...1 idle animation driver

    private var timer: Timer?
    private var phase: Double = 0

    /// Radians of tilt needed to reach full (±1) response. SMALLER = MORE sensitive.
    /// 0.7 (original) → 0.467 (+50%) → 0.311 (+50% again, ~2.25× the original).
    private let tiltRange: Double = 0.311

    func start() {
        // Continuous idle wave (always animating, gyro adds to it)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.02
            self.wave = sin(self.phase)          // -1...1 smooth oscillation
        }

        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1/60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            // Amplified tilt response — see `tiltRange` (smaller = more sensitive).
            self?.roll = max(-1, min(1, m.attitude.roll / (self?.tiltRange ?? 0.311)))
            self?.pitch = max(-1, min(1, m.attitude.pitch / (self?.tiltRange ?? 0.311)))
        }
    }
    func stop() {
        manager.stopDeviceMotionUpdates()
        timer?.invalidate(); timer = nil
    }
}

// MARK: - Metallic rainbow text
// Shiny rainbow-metallic fill (two moving sheen bands for extra shimmer) PLUS a
// thin metallic-gold outline whose gold sheen also shifts with the gyroscope.
struct MetallicRainbowText: View {
    let text: String
    let size: CGFloat
    var fillWidth: Bool = false            // scale the whole word up to span the container width
    @ObservedObject var motion: MotionManager

    // Gold stops for the outline shimmer
    private var goldStops: [Color] {
        [Color(hex: 0x8A6A1E), Color(hex: 0xE0A83C), Color(hex: 0xFFF3B0),
         Color(hex: 0xE0A83C), Color(hex: 0x8A6A1E)]
    }

    var body: some View {
        // Combine live tilt with the continuous idle wave so it's always dramatic,
        // and even MORE dramatic when the phone moves.
        let shift = motion.roll + motion.wave * 0.6      // amplified, always moving
        let pShift = motion.pitch + motion.wave * 0.4

        ZStack {
            goldOutline(shift: shift)                      // gold outline tracing every edge
            metallicFill(shift: shift, pShift: pShift)     // metallic rainbow fill on top
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.06), value: shift)   // snappier
        .animation(.easeOut(duration: 0.06), value: pShift)
    }

    // One styled copy of the word. When fillWidth is on it renders at a large nominal
    // size and auto-shrinks UNIFORMLY (no horizontal stretch) to exactly fit the available
    // width — the same trick the other headline words use. Base and mask call this
    // identically, so they always shrink to the same size and stay aligned.
    private func glyphText() -> some View {
        Text(text)
            .font(BrandFont.welcome(fillWidth ? 240 : size))
            .lineLimit(1)
            .minimumScaleFactor(fillWidth ? 0.1 : 1)
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    // Rainbow fill: the whole spectrum TRAVELS with tilt, plus three bright sheen
    // bands sweeping across for an intense liquid-metal shimmer.
    private func metallicFill(shift: Double, pShift: Double) -> some View {
        glyphText()
            .overlay(
                GeometryReader { geo in
                  ZStack {
                    // Static rainbow UNDERLAY — guarantees the letters are ALWAYS fully colored.
                    // Even if the moving gradient below slides an edge past the text at an
                    // extreme tilt, what shows through is rainbow, never bare white.
                    LinearGradient(colors: BrandDark.rainbow, startPoint: .leading, endPoint: .trailing)

                    // Moving rainbow that scrolls the colors across the letters with tilt.
                    LinearGradient(colors: Array(repeating: BrandDark.rainbow, count: 5).flatMap { $0 },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 5)
                        .offset(x: -geo.size.width * 0.5 + geo.size.width * 0.5 * shift)
                        // primary bright sheen — wide, fast, full sweep
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.45)
                                .offset(x: (geo.size.width * 1.1) * shift)
                                .blendMode(.overlay)
                        )
                        // secondary sheen — opposite direction, bright
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.28)
                                .offset(x: (geo.size.width * -0.9) * shift + geo.size.width * 0.4 * pShift)
                                .blendMode(.screen)
                        )
                        // third fast glint driven by pitch axis
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: geo.size.height * 0.4)
                                .offset(y: (geo.size.height * 0.9) * pShift)
                                .blendMode(.overlay)
                        )
                        // polished-metal dark bands (stronger contrast)
                        .overlay(
                            Rectangle()
                                .fill(LinearGradient(colors: [.black.opacity(0.4), .clear, .black.opacity(0.35)],
                                                     startPoint: .top, endPoint: .bottom))
                                .blendMode(.multiply)
                        )
                  }
                }
            )
            .mask(glyphText())
    }

    // A single gold-gradient copy of the text (with gyro glint)
    private func goldGlyph(shift: Double) -> some View {
        glyphText()
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: goldStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(
                            // Bright gold glint — wider band, full-width sweep
                            LinearGradient(colors: [.clear, Color(hex: 0xFFFDE8), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.4)
                                .offset(x: (geo.size.width * 1.1) * shift)
                                .blendMode(.screen)
                        )
                }
            )
            .mask(glyphText())
    }

    // True outline: stamp the gold glyph around a circle so it rims every edge
    // evenly (16 points at a small radius => smooth, no jagged diagonal buildup).
    private func goldOutline(shift: Double) -> some View {
        let r: CGFloat = 2.5   // outline thickness in points
        let steps = 16
        return ZStack {
            ForEach(0..<steps, id: \.self) { i in
                let angle = Double(i) / Double(steps) * 2 * .pi
                goldGlyph(shift: shift)
                    .offset(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r)
            }
        }
        .compositingGroup()
    }
}

// MARK: - Sparkly QUEENS (static: a glittery finish that doesn't move)
// Letters drawn from the Big Shoulders outlines themselves, so the fill and outline are crisp
// and line up exactly: high-contrast rainbow bands with glitter, a gold-banded outline with
// gold glitter.

enum GlyphText {
    static let fontName = "BigShouldersDisplay-Black"
    private static var cache: [String: (path: CGPath, size: CGSize)] = [:]

    /// `text` set at `size`: the letter outlines (top-left at 0,0, y down) and their tight size.
    static func shape(_ text: String, size: CGFloat) -> (path: CGPath, size: CGSize) {
        let key = "\(text)|\(Int((size * 10).rounded()))"
        if let hit = cache[key] { return hit }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var points = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &points)
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                let t = CGAffineTransform(translationX: points[i].x, y: ascent - points[i].y).scaledBy(x: 1, y: -1)
                path.addPath(g, transform: t)
            }
        }
        let box = path.boundingBoxOfPath
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let made = (path.copy(using: &shift) ?? path, box.size)
        cache[key] = made
        return made
    }

    /// The biggest size (up to `maxSize`) at which `text` fits `width`.
    static func fit(_ text: String, width: CGFloat, maxSize: CGFloat, inset: CGFloat = 0) -> CGFloat {
        let w = shape(text, size: 100).size.width
        guard w > 0 else { return maxSize }
        return min(maxSize, (width - inset) / w * 100)
    }

    static func shifted(_ p: CGPath, by d: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: d, y: d)
        return p.copy(using: &t) ?? p
    }
}

private struct GlyphShape: Shape {
    let cg: CGPath
    func path(in rect: CGRect) -> Path { Path(cg) }
}

struct SparkleWord: View {
    let text: String
    let width: CGFloat
    var maxSize: CGFloat = 160
    var outlineWidth: CGFloat = 0.05          // × font size — the original outline weight

    /// Vivid bands with crisp edges: each colour holds, then hands over quickly.
    private static func bands(_ colors: [Color], hold: Double) -> [Gradient.Stop] {
        let n = Double(colors.count)
        var stops: [Gradient.Stop] = []
        for (i, c) in colors.enumerated() {
            stops.append(.init(color: c, location: Double(i) / n))
            stops.append(.init(color: c, location: (Double(i) + hold) / n))
        }
        return stops
    }
    private static let rainbow = bands([Color(hex: 0xFF1744), Color(hex: 0xFF9100), Color(hex: 0xFFEA00), Color(hex: 0x00E676),
                                        Color(hex: 0x00B0FF), Color(hex: 0x651FFF), Color(hex: 0xD500F9)], hold: 0.72)
    private static let gold = bands([Color(hex: 0xB8860B), Color(hex: 0xFFD54A), Color(hex: 0xD99A1E), Color(hex: 0xFFE68A),
                                     Color(hex: 0xC8911A), Color(hex: 0xF2C230), Color(hex: 0xB8860B), Color(hex: 0xFFE68A)], hold: 0.6)

    var body: some View {
        let size = GlyphText.fit(text, width: width, maxSize: maxSize, inset: maxSize * outlineWidth)
        let g = GlyphText.shape(text, size: size)
        let lw = size * outlineWidth
        let box = CGSize(width: g.size.width + lw, height: g.size.height + lw)
        let shape = GlyphShape(cg: GlyphText.shifted(g.path, by: lw / 2))
        let outline = StrokeStyle(lineWidth: lw, lineJoin: .round)
        ZStack(alignment: .topLeading) {
            shape.stroke(LinearGradient(stops: Self.gold, startPoint: .topLeading, endPoint: .bottomTrailing), style: outline)
            StaticGlitter(size: box, count: 900, seed: 7, scale: 0.6, tint: Color(hex: 0xFFF6D6))
                .mask(shape.stroke(style: outline))
            shape.fill(LinearGradient(stops: Self.rainbow, startPoint: .leading, endPoint: .trailing))
            StaticGlitter(size: box, count: 320, seed: 1)
                .mask(shape)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Glitter that sits still: flecks at fixed spots, a few bright, most soft, some four-point stars.
private struct StaticGlitter: View {
    let size: CGSize
    var count = 300
    var seed: UInt64 = 1
    var scale: Double = 1
    var tint: Color = .white

    private struct Fleck { let x: Double, y: Double, glow: Double, r: Double }

    private static var made: [String: [Fleck]] = [:]
    private static func flecks(_ count: Int, _ seed: UInt64) -> [Fleck] {
        let key = "\(count)|\(seed)"
        if let f = made[key] { return f }
        var state: UInt64 = 0x9E3779B97F4A7C15 &+ seed &* 0xBF58476D1CE4E5B9
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let f = (0..<count).map { _ in
            Fleck(x: next(), y: next(), glow: pow(next(), 2.6), r: 0.6 + next() * 1.6)     // mostly soft, a few bright
        }
        made[key] = f
        return f
    }

    var body: some View {
        let flecks = Self.flecks(count, seed)
        Canvas { ctx, sz in
            ctx.blendMode = .plusLighter
            let k = max(1, sz.height / 90)
            for f in flecks {
                let b = 0.18 + 0.82 * f.glow
                let p = CGPoint(x: f.x * sz.width, y: f.y * sz.height)
                let r = f.r * scale * (0.7 + 0.8 * f.glow) * k
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)), with: .color(tint.opacity(b)))
                if f.glow > 0.72 {                                 // the brightest become stars
                    var star = Path()
                    let l = r * 3.0, w = r * 0.3
                    star.move(to: CGPoint(x: p.x, y: p.y - l))
                    star.addLine(to: CGPoint(x: p.x + w, y: p.y - w))
                    star.addLine(to: CGPoint(x: p.x + l, y: p.y))
                    star.addLine(to: CGPoint(x: p.x + w, y: p.y + w))
                    star.addLine(to: CGPoint(x: p.x, y: p.y + l))
                    star.addLine(to: CGPoint(x: p.x - w, y: p.y + w))
                    star.addLine(to: CGPoint(x: p.x - l, y: p.y))
                    star.addLine(to: CGPoint(x: p.x - w, y: p.y - w))
                    star.closeSubpath()
                    ctx.fill(star, with: .color(tint.opacity(b * 0.9)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

