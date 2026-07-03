import SwiftUI
import CoreMotion
import Combine

// MARK: - Motion manager (gyroscope / device attitude)
// Drives the metallic sheen on "QUEENS" so the rainbow shifts as the phone tilts.
final class MotionManager: ObservableObject {
    private let manager = CMMotionManager()
    @Published var roll: Double = 0    // -1 ... 1 normalized
    @Published var pitch: Double = 0

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1/30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let m = motion else { return }
            // clamp to a comfortable range
            self?.roll = max(-1, min(1, m.attitude.roll / 1.2))
            self?.pitch = max(-1, min(1, m.attitude.pitch / 1.2))
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - Metallic rainbow text
// Shiny rainbow-metallic fill (two moving sheen bands for extra shimmer) PLUS a
// thin metallic-gold outline whose gold sheen also shifts with the gyroscope.
struct MetallicRainbowText: View {
    let text: String
    let size: CGFloat
    @ObservedObject var motion: MotionManager

    // Gold stops for the outline shimmer
    private var goldStops: [Color] {
        [Color(hex: 0x8A6A1E), Color(hex: 0xE0A83C), Color(hex: 0xFFF3B0),
         Color(hex: 0xE0A83C), Color(hex: 0x8A6A1E)]
    }

    var body: some View {
        let shift = motion.roll        // -1 ... 1
        let pShift = motion.pitch      // second axis for extra life

        ZStack {
            // 1) Thin metallic-gold outline (gyro-reactive gold sheen)
            goldOutline(shift: shift)

            // 2) Metallic rainbow fill
            metallicFill(shift: shift, pShift: pShift)
        }
        .animation(.easeOut(duration: 0.12), value: shift)
        .animation(.easeOut(duration: 0.12), value: pShift)
    }

    // Rainbow fill with two crossing sheen bands => more metallic
    private func metallicFill(shift: Double, pShift: Double) -> some View {
        Text(text)
            .font(BrandFont.display(size))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: Brand.rainbow, startPoint: .leading, endPoint: .trailing)
                        // primary bright sheen (moves with roll)
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.30)
                                .offset(x: (geo.size.width * 0.65) * shift)
                                .blendMode(.overlay)
                        )
                        // secondary softer sheen (moves opposite for shimmer)
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.18)
                                .offset(x: (geo.size.width * -0.5) * shift + geo.size.width * 0.2 * pShift)
                                .blendMode(.screen)
                        )
                        // subtle dark bands to read as polished metal
                        .overlay(
                            LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.2)],
                                           startPoint: .top, endPoint: .bottom)
                                .blendMode(.multiply)
                        )
                }
            )
            .mask(Text(text).font(BrandFont.display(size)))
    }

    // Thin gold outline that shimmers with the gyroscope
    private func goldOutline(shift: Double) -> some View {
        let stroke = Text(text).font(BrandFont.display(size))
        return GeometryReader { geo in
            LinearGradient(colors: goldStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(
                    // moving bright gold glint
                    LinearGradient(colors: [.clear, Color(hex: 0xFFF8D0).opacity(0.9), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.25)
                        .offset(x: (geo.size.width * 0.6) * shift)
                        .blendMode(.screen)
                )
        }
        // Turn the filled gold text into a thin OUTLINE by subtracting an inset copy
        .mask(
            stroke
                .overlay(
                    stroke.blendMode(.destinationOut)
                        .scaleEffect(0.965)   // inner cut => leaves a thin rim
                )
                .compositingGroup()
        )
    }
}
