import Foundation

// MARK: - Effort estimate → suggested calorie adjustment
// Watch calorie numbers are an estimate, and for lifting they can be well off. This
// looks at everything else we know about the session — heart rate against your own
// max, how hard you rated it, and (for lifting) bar-speed fatigue and how dense the
// session was — and compares that effort with how hard the Watch's calorie number
// implies you worked. The gap becomes a suggested adjustment within ±20%, in 5% steps.
//
// It's a transparent rule of thumb, not a lab measurement, and it says so in the UI.

struct EffortSignals {
    var minutes: Double
    var reportedKcal: Double
    var avgHR: Int? = nil
    var maxHR: Int? = nil           // your highest recorded heart rate (proxy for max)
    var rpe: Double? = nil          // 1–10
    var velocityLossPct: Double? = nil
    var setsPerMinute: Double? = nil
    var bodyweightKg: Double? = nil
}

struct EffortEstimate {
    var effort: Double              // 0…1 from your signals
    var watchIntensity: Double      // 0…1 implied by the Watch's calories
    var suggestedPct: Double        // −0.20…+0.20
    var reasons: [String]
    var signalCount: Int

    var effortLabel: String {
        switch effort {
        case ..<0.3: return "Light"
        case ..<0.55: return "Moderate"
        case ..<0.8: return "Hard"
        default: return "Very hard"
        }
    }
}

enum EffortEstimator {
    static let range = -0.20...0.20

    static func estimate(_ s: EffortSignals) -> EffortEstimate {
        var parts: [(value: Double, weight: Double)] = []
        var reasons: [String] = []

        if let hr = s.avgHR, hr > 0 {
            let maxHR = Double(s.maxHR ?? 185)
            let pct = Double(hr) / maxHR
            parts.append((clamp((pct - 0.5) / 0.4), 0.45))
            reasons.append("heart rate averaged \(Int((pct * 100).rounded()))% of your max")
        }
        if let rpe = s.rpe, rpe > 0 {
            parts.append((clamp((rpe - 3) / 7), 0.35))
            reasons.append(String(format: "you rated it %.0f/10", rpe))
        }
        var strength: [Double] = []
        if let loss = s.velocityLossPct {
            strength.append(clamp(loss / 35))
            reasons.append("bar speed dropped \(Int(loss.rounded()))% per set on average")
        }
        if let d = s.setsPerMinute, d > 0 {
            strength.append(clamp(d / 0.25))
        }
        if !strength.isEmpty {
            parts.append((strength.reduce(0, +) / Double(strength.count), 0.20))
        }

        let totalWeight = parts.map { $0.weight }.reduce(0, +)
        let effort = totalWeight > 0 ? parts.map { $0.value * $0.weight }.reduce(0, +) / totalWeight : 0.5

        // How hard the Watch's number implies you worked: kcal per kg per hour ≈ METs.
        let kg = s.bodyweightKg ?? 80
        let mets = s.minutes > 0 ? s.reportedKcal / kg / (s.minutes / 60) : 0
        let watchIntensity = clamp((mets - 3) / 7)

        // No independent signals → no suggestion.
        var suggested = 0.0
        if !parts.isEmpty {
            let raw = (effort - watchIntensity) * 0.4
            suggested = (raw / 0.05).rounded() * 0.05
            suggested = min(range.upperBound, max(range.lowerBound, suggested))
        }
        return EffortEstimate(effort: effort, watchIntensity: watchIntensity, suggestedPct: suggested,
                              reasons: reasons, signalCount: parts.count)
    }

    /// One sentence explaining the suggestion.
    static func explanation(_ e: EffortEstimate) -> String {
        guard e.signalCount > 0 else {
            return "Not enough other data to second-guess the Watch, so we've left it as reported."
        }
        let why = e.reasons.prefix(2).joined(separator: " and ")
        let what = e.suggestedPct == 0 ? "matches the Watch's number, so we've left it as reported"
            : (e.suggestedPct > 0 ? "points to a harder session than the Watch's number suggests"
                                  : "points to an easier session than the Watch's number suggests")
        return "Your \(why.isEmpty ? "data" : why) — that \(what)."
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
