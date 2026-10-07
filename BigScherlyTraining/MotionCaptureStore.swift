import Foundation
import SwiftUI
import Combine
import UIKit

// MARK: - Motion captures (DEBUG TOOL — removed before release)
// The Watch records every raw sample between Go and hand-over during setup and sends it here with
// its own rep count. The phone adds its verdict (accepted / what was wrong), keeps the last dozen,
// and turns any of them into compact pasteable text (25 Hz) — so the counting can be replayed and
// tuned off the wrist. Later the camera's own count joins each capture (cameraCount).
//
// Target membership: BigScherlyTraining.

nonisolated struct MotionCapture: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var lift: String
    var kind: String            // still · reps
    var step: Int
    var of: Int
    var startT: Double          // time of the first sample (seconds since 1970)
    var hz: Double              // 50 — pairs of 100 Hz samples averaged
    var rawCount: Int           // samples the Watch recorded at 100 Hz
    var build: String
    var analyzer: Int
    var diag: String?           // the still check's numbers
    var samples: Data           // Int16 × 4 interleaved (av, h1, h2, rot), thousandths
    var reps: [RepMotion]       // what the Watch counted
    var verdict: String?        // what the phone decided
    var cameraCount: Int?       // the camera's own count
    var camera: CameraTrack?    // the camera's track of the wrist (or hips), when tracking was on

    var count: Int { samples.count / 8 }
    var seconds: Double { hz > 0 ? Double(count) / hz : 0 }

    func raw(_ channel: Int, _ i: Int) -> Int { value(channel, i) }

    private func value(_ channel: Int, _ i: Int) -> Int {
        let off = (i * 4 + channel) * 2
        guard off + 2 <= samples.count else { return 0 }
        let raw = samples.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: Int16.self) }
        return Int(Int16(littleEndian: raw))
    }

    /// Compact text for pasting: a header, the Watch's reps, then the samples at 25 Hz as whole
    /// hundredths (row k = k/25 s after the first sample).
    func compactText() -> String {
        var out: [String] = []
        out.append("BST-CAP v1 | \(title) | lift=\(lift) | \(kind) | step \(step)/\(of) | \(ISO8601DateFormatter().string(from: date))")
        var line2 = "watchBuild=\(build) analyzer=\(analyzer) | watchReps=\(reps.count) | phone=\(verdict ?? "n/a") | raw=\(rawCount)@100Hz"
        if let cameraCount { line2 += " | cameraReps=\(cameraCount)" }
        out.append(line2)
        if let diag { out.append("still: \(diag)") }
        if !reps.isEmpty {
            out.append("reps (seconds from the first sample): n,start,end,ecc,bottomPause,con,topPause,travelCm,meanV,peakV,driftCm")
            for r in reps {
                func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
                out.append([String(r.index), f(r.start.timeIntervalSince1970 - startT), f(r.end.timeIntervalSince1970 - startT),
                            f(r.eccentricSec), f(r.bottomPauseSec), f(r.concentricSec), f(r.topPauseSec),
                            String(format: "%.1f", r.travelM * 100), f(r.meanVelocity), f(r.peakVelocity),
                            String(format: "%.1f", r.driftM * 100)].joined(separator: ","))
            }
        }
        if let cam = camera, let cmp = CameraAnalysis.compare(self) {
            out.append("camera: joint=\(cam.joint) side=\(cam.side) work=\(cam.work) cmPerUnit=\(String(format: "%.1f", cam.cmPerUnit)) scale=\(cam.ruler ?? (cam.scaleKnown ? "measured" : "assumed")) | camReps=\(cmp.camReps.count) | clockLag=\(String(format: "%.2f", cmp.lagSec))s syncR=\(String(format: "%.2f", cmp.syncR))")
            if !cmp.camReps.isEmpty {
                out.append("camera reps (seconds from the first sample): n,start,peak,end,travelCm,meanV,peakV")
                for r in cmp.camReps {
                    out.append(String(format: "%d,%.2f,%.2f,%.2f,%.1f,%.2f,%.2f", r.n, r.start - startT, r.peak - startT, r.end - startT, r.travelCm, r.meanV, r.peakV))
                }
            }
            // Squats: how close the hip came to the knee in each rep — what the depth check judges.
            if cam.joint == "hip", let k = cam.k, k.count == cam.t.count, !cmp.camReps.isEmpty {
                var parts: [String] = []
                for r in cmp.camReps {
                    var lowest: Double?
                    for i in cam.t.indices where k[i] >= 0 {
                        let t = cam.t[i] - cmp.lagSec
                        guard t >= r.start, t <= r.end else { continue }
                        let gap = (cam.y[i] - k[i]) * cam.cmPerUnit
                        lowest = min(lowest ?? gap, gap)
                    }
                    parts.append(lowest.map { String(format: "%+.1f", $0) } ?? "-")
                }
                out.append("depth: lowest hip minus knee per camera rep, cm (below 0 = hip under knee; passes under +"
                           + String(format: "%.1f", DepthRig.depthMargin * cam.cmPerUnit) + "): " + parts.joined(separator: ","))
            }
            out.append("camera height at 10 Hz, cm above its lowest point: t(s from the first sample),cm")
            var last = -1.0
            for s in cmp.camSeries where s.t - startT >= 0 && s.t - startT - last >= 0.0999 {
                out.append(String(format: "%.1f,%.1f", s.t - startT, s.cm)); last = s.t - startT
            }
        }
        out.append("samples fs=25 unit=0.01 cols=av,h1,h2,rot (av up+ m/s², h1/h2 m/s², rot rad/s)")
        var k = 0
        while k * 2 + 1 < count {
            var cols: [String] = []
            for ch in 0..<4 {
                let centi = Double(value(ch, k * 2) + value(ch, k * 2 + 1)) / 20.0
                cols.append(String(Int(centi.rounded())))
            }
            out.append(cols.joined(separator: ","))
            k += 1
        }
        return out.joined(separator: "\n")
    }
}

@MainActor
final class MotionCaptureStore: ObservableObject {
    static let shared = MotionCaptureStore()
    static let keep = 40

    @Published private(set) var captures: [MotionCapture] = []
    private var pending: (text: String, at: Date)?
    private var pendingCamera: (track: CameraTrack, at: Date)?
    private let dir: URL

    // Debug settings (Settings ▸ Apple Watch setup ▸ Motion captures)
    static let trackKey = "bst_cam_track", heightKey = "bst_cam_height_cm"
    /// Track the wrist (or hips) with the camera during setup steps and pair it with the Watch's capture.
    static var cameraTracking: Bool {
        get { UserDefaults.standard.object(forKey: trackKey) as? Bool ?? true }      // on by default while we're tuning
        set { UserDefaults.standard.set(newValue, forKey: trackKey) }
    }
    /// Your height — the camera's ruler.
    static var heightCm: Double {
        get { let v = UserDefaults.standard.double(forKey: heightKey); return v >= 120 && v <= 230 ? v : 178 }
        set { UserDefaults.standard.set(newValue, forKey: heightKey) }
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("MotionCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    /// A capture from the Watch (the message's own keys).
    func ingest(_ m: [String: Any]) {
        guard let samples = m["motionCapture"] as? Data, !samples.isEmpty else { return }
        let reps = ((m["mcReps"] as? Data).flatMap { try? JSONDecoder().decode([RepMotion].self, from: $0) }) ?? []
        var c = MotionCapture(title: m["mcTitle"] as? String ?? "Setup",
                              lift: m["mcLift"] as? String ?? "body",
                              kind: m["mcKind"] as? String ?? "reps",
                              step: m["mcN"] as? Int ?? 1, of: m["mcOf"] as? Int ?? 1,
                              startT: m["mcStart"] as? Double ?? 0, hz: m["mcHz"] as? Double ?? 50,
                              rawCount: m["mcRaw"] as? Int ?? 0,
                              build: m["mcBuild"] as? String ?? "?", analyzer: m["mcAnalyzer"] as? Int ?? 0,
                              diag: m["mcDiag"] as? String, samples: samples, reps: reps,
                              verdict: nil, cameraCount: nil, camera: nil)
        // The phone's verdict usually lands just before the capture does.
        if let p = pending, Date().timeIntervalSince(p.at) < 30 { c.verdict = p.text; pending = nil }
        if let p = pendingCamera, Date().timeIntervalSince(p.at) < 30 {
            c.camera = p.track; c.cameraCount = CameraAnalysis.reps(p.track).count; pendingCamera = nil
        }
        captures.insert(c, at: 0)
        save(c)
        while captures.count > Self.keep {
            let old = captures.removeLast()
            try? FileManager.default.removeItem(at: url(old.id))
        }
        print("[Capture] \(c.title): \(c.count) samples, watch counted \(reps.count)")
    }

    /// What the phone decided about the step just captured ("accepted", or what was wrong).
    func noteVerdict(_ text: String) {
        if let i = captures.indices.first, captures[i].verdict == nil,
           Date().timeIntervalSince(captures[i].date) < 30 {
            captures[i].verdict = text
            save(captures[i])
            pending = nil
        } else {
            pending = (text, Date())
        }
    }

    /// The camera's track for the step just captured (it lands before or after the Watch's capture).
    func attachCamera(_ track: CameraTrack) {
        guard !track.isEmpty else { return }
        if let i = captures.indices.first, captures[i].camera == nil, Date().timeIntervalSince(captures[i].date) < 30 {
            captures[i].camera = track
            captures[i].cameraCount = CameraAnalysis.reps(track).count
            save(captures[i])
            pendingCamera = nil
        } else {
            pendingCamera = (track, Date())
        }
    }

    func delete(_ id: UUID) {
        captures.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(id))
    }

    func deleteAll() {
        for c in captures { try? FileManager.default.removeItem(at: url(c.id)) }
        captures = []
    }

    private func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    private func save(_ c: MotionCapture) {
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url(c.id), options: .atomic) }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        captures = files.compactMap { try? JSONDecoder().decode(MotionCapture.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}
