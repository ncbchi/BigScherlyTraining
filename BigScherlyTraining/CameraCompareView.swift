import SwiftUI
import UIKit

// MARK: - Camera vs Watch (DEBUG TOOL — removed before release)
// One capture: the camera's height of the wrist (or hips) against the Watch's, with the reps the
// camera counted next to the reps the Watch counted. The camera is the ground truth.
//
// Target membership: BigScherlyTraining.

struct CameraCompareView: View {
    let capture: MotionCapture
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let cmp = CameraAnalysis.compare(capture)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(capture.title.uppercased()) · \(capture.reps.count) WATCH · \(cmp?.camReps.count ?? capture.cameraCount ?? 0) CAMERA")
                    .font(BrandFont.display(24))
                if let cmp {
                    chartCard(cmp)
                    tiles(cmp)
                    table(cmp)
                    note(cmp)
                } else {
                    Text("No camera track was recorded with this capture. Switch on “Track with the camera” in Motion captures and run a rep step again.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                }
                Button {
                    UIPasteboard.general.string = capture.compactText()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copied = false }
                } label: {
                    Text(copied ? "Copied ✓" : "Copy for Claude").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.onVolt)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Brand.bg.ignoresSafeArea())
        .foregroundColor(Brand.text)
        .navigationTitle("Camera vs Watch")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Chart

    private func chartCard(_ c: CameraComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                legend(dash: false, "Camera")
                legend(dash: true, "Watch (from its sensor)")
                Spacer()
                Text("HEIGHT · CM").font(BrandFont.body(10, .heavy)).tracking(1).foregroundColor(Brand.mute)
            }
            Canvas { g, size in draw(g, size, c) }
                .frame(height: 190)
        }
        .padding(14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func legend(dash: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 3)); p.addLine(to: CGPoint(x: 22, y: 3)) }
                .stroke(dash ? Brand.voltText : Brand.text, style: StrokeStyle(lineWidth: 3, dash: dash ? [6, 3] : []))
                .frame(width: 22, height: 6)
            Text(text).font(BrandFont.body(12, .bold))
        }
    }

    private func draw(_ g: GraphicsContext, _ size: CGSize, _ c: CameraComparison) {
        let t0 = capture.startT
        let tEnd = t0 + capture.seconds
        let span = max(1, tEnd - t0)
        let top = max(10, ((c.camSeries.map(\.cm).max() ?? 10) * 1.1).rounded(.up),
                      ((c.watchSeries.filter { $0.t <= tEnd }.map(\.cm).max() ?? 10) * 1.1).rounded(.up))
        let left: CGFloat = 30, bottom: CGFloat = 18
        let w = size.width - left, h = size.height - bottom
        func X(_ t: Double) -> CGFloat { left + w * CGFloat((t - t0) / span) }
        func Y(_ cm: Double) -> CGFloat { h * (1 - CGFloat(min(top, max(0, cm)) / top)) }
        // grid
        for k in 0...2 {
            let v = top * Double(k) / 2
            var p = Path(); p.move(to: CGPoint(x: left, y: Y(v))); p.addLine(to: CGPoint(x: size.width, y: Y(v)))
            g.stroke(p, with: .color(Brand.line), lineWidth: 1)
            g.draw(Text(String(Int(v.rounded()))).font(.system(size: 10, weight: .bold)).foregroundColor(Brand.mute),
                   at: CGPoint(x: left - 5, y: Y(v)), anchor: .trailing)
        }
        var s = 0.0
        while s <= span {
            g.draw(Text("\(Int(s))s").font(.system(size: 10, weight: .bold)).foregroundColor(Brand.mute),
                   at: CGPoint(x: X(t0 + s), y: size.height - 2), anchor: .bottom)
            s += span > 30 ? 10 : 5
        }
        // rep markers (camera)
        for r in c.camReps {
            var p = Path(); p.move(to: CGPoint(x: X(r.peak), y: 0)); p.addLine(to: CGPoint(x: X(r.peak), y: h))
            g.stroke(p, with: .color(Brand.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            g.draw(Text("\(r.n)").font(.system(size: 10, weight: .heavy)).foregroundColor(Brand.text), at: CGPoint(x: X(r.peak), y: 8))
        }
        func line(_ pts: [(t: Double, cm: Double)], _ color: Color, dash: [CGFloat]) {
            var p = Path()
            var started = false
            for q in pts where q.t >= t0 && q.t <= tEnd {
                let pt = CGPoint(x: X(q.t), y: Y(q.cm))
                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
            }
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: dash))
        }
        line(c.camSeries, Brand.text, dash: [])
        line(c.watchSeries, Brand.voltText, dash: [7, 4])
    }

    // MARK: Tiles + table

    private func tiles(_ c: CameraComparison) -> some View {
        HStack(spacing: 8) {
            tile("COUNT", "\(capture.reps.count) / \(c.camReps.count)", "Watch / camera",
                 hot: capture.reps.count == c.camReps.count)
            tile("TRAVEL", c.travelErrCm.map { String(format: "%+.1f cm", $0) } ?? "—", "Watch avg error")
            tile("PEAK SPEED", c.peakErr.map { String(format: "%+.2f", $0) } ?? "—", "m/s avg error")
        }
    }

    private func tile(_ a: String, _ b: String, _ d: String, hot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a).font(BrandFont.body(10, .heavy)).tracking(1).foregroundColor(Brand.mute)
            Text(b).font(BrandFont.display(24)).foregroundColor(hot ? Brand.voltText : Brand.text).minimumScaleFactor(0.7).lineLimit(1)
            Text(d).font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func table(_ c: CameraComparison) -> some View {
        VStack(spacing: 0) {
            HStack {
                head("REP", 30); head("CAM CM", nil); head("WATCH", nil); head("CAM M/S", nil); head("WATCH", nil); head("", 26)
            }
            .padding(.bottom, 6)
            ForEach(Array(c.pairs.enumerated()), id: \.offset) { i, pr in
                let off = pr.cam == nil || pr.watch == nil
                    || abs((pr.watch?.travelM ?? 0) * 100 - (pr.cam?.travelCm ?? 0)) > max(4, 0.12 * (pr.cam?.travelCm ?? 0))
                Divider().overlay(Brand.line)
                HStack {
                    cell("\(i + 1)", 30, Brand.mute)
                    cell(pr.cam.map { String(format: "%.0f", $0.travelCm) } ?? "—", nil, Brand.text)
                    cell(pr.watch.map { String(format: "%.0f", $0.travelM * 100) } ?? "—", nil, Brand.voltText)
                    cell(pr.cam.map { String(format: "%.2f", $0.peakV) } ?? "—", nil, Brand.text)
                    cell(pr.watch.map { String(format: "%.2f", $0.peakVelocity) } ?? "—", nil, Brand.voltText)
                    Image(systemName: off ? "exclamationmark.triangle.fill" : "checkmark")
                        .font(.system(size: 12, weight: .heavy)).foregroundColor(off ? Brand.text : Brand.voltText).frame(width: 26)
                }
                .padding(.vertical, 9)
            }
        }
        .padding(14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private func head(_ t: String, _ w: CGFloat?) -> some View {
        Text(t).font(BrandFont.body(10, .heavy)).tracking(1).foregroundColor(Brand.mute)
            .frame(width: w, alignment: .leading).frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }

    private func cell(_ t: String, _ w: CGFloat?, _ color: Color) -> some View {
        Text(t).font(BrandFont.body(13, .bold)).foregroundColor(color).monospacedDigit()
            .frame(width: w, alignment: .leading).frame(maxWidth: w == nil ? .infinity : nil, alignment: .leading)
    }

    private func note(_ c: CameraComparison) -> some View {
        let cam = capture.camera
        var parts: [String] = []
        parts.append(String(format: "Clocks lined up by %.2f s (match %.2f%@).", c.lagSec, c.syncR, c.syncR < 0.25 ? " — weak, so not applied" : ""))
        if let cam, !cam.scaleKnown { parts.append("Scale assumed — nobody was measured standing in view, so centimetres are approximate. Stand in frame before Go.") }
        if let cam { parts.append("Camera followed the \(cam.joint). Height used: \(Int(MotionCaptureStore.heightCm)) cm.") }
        return Text(parts.joined(separator: " ")).font(BrandFont.body(12)).foregroundColor(Brand.mute)
            .fixedSize(horizontal: false, vertical: true)
    }
}
