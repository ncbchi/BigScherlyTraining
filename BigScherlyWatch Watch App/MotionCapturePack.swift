import Foundation

// MARK: - Motion capture packing (debug tool, removed before release)
// The Watch keeps every raw 100 Hz sample from Go until hand-over; this squeezes it into a
// message the phone can take: pairs of samples averaged to 50 Hz, four channels (vertical accel,
// two horizontal, rotation) as Int16 thousandths. 60 s → about 24 KB.

nonisolated enum MotionCapturePack {
    static let outRate = 50.0

    /// (packed bytes, time of the first sample). Channels interleaved: av, h1, h2, rot.
    static func pack(_ s: [MotionSample]) -> (data: Data, startT: Double) {
        guard let first = s.first else { return (Data(), 0) }
        var out = [Int16]()
        out.reserveCapacity(s.count / 2 * 4)
        func q(_ v: Double) -> Int16 { Int16(max(-32.7, min(32.7, v)) * 1000) }
        var i = 0
        while i + 1 < s.count {
            let a = s[i], b = s[i + 1]
            out.append(q((a.av + b.av) / 2))
            out.append(q((a.h1 + b.h1) / 2))
            out.append(q((a.h2 + b.h2) / 2))
            out.append(q((a.rot + b.rot) / 2))
            i += 2
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, first.t)
    }

    /// The attitude channels at the same 50 Hz: gravity direction ×10000 (unit vector) and rotation
    /// rate about each axis ×1000 (rad/s), Int16, interleaved gx, gy, gz, rx, ry, rz.
    static func packAttitude(_ s: [MotionSample]) -> Data {
        var out = [Int16]()
        out.reserveCapacity(s.count / 2 * 6)
        func g(_ v: Double) -> Int16 { Int16(max(-1, min(1, v)) * 10000) }
        func r(_ v: Double) -> Int16 { Int16(max(-32.7, min(32.7, v)) * 1000) }
        var i = 0
        while i + 1 < s.count {
            let a = s[i], b = s[i + 1]
            out.append(g((a.gx + b.gx) / 2)); out.append(g((a.gy + b.gy) / 2)); out.append(g((a.gz + b.gz) / 2))
            out.append(r((a.rx + b.rx) / 2)); out.append(r((a.ry + b.ry) / 2)); out.append(r((a.rz + b.rz) / 2))
            i += 2
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
