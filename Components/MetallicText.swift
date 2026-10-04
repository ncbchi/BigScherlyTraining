import SwiftUI
import CoreMotion
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
            .font(BrandFont.display(fillWidth ? 240 : size))
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
