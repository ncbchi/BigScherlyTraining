import Foundation
import HealthKit

// MARK: - Activities recorded in Apple Health
// Workouts on a given day from Apple Health (Watch, Strava, etc.), with calories and
// heart rate — so an extra run can be logged in one tap. Our own lifting sessions
// are left out (those already live in Workouts). Read-only.

struct HealthActivity: Identifiable, Equatable {
    var id: String
    var type: String
    var start: Date
    var minutes: Int
    var kcal: Int?
    var avgHR: Int?
    var peakHR: Int?
}

enum HealthActivityReader {
    private static let store = HKHealthStore()

    static func activities(on day: Date, demo: Bool) async -> [HealthActivity] {
        if demo { return demoActivities(on: day) }
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        _ = await HealthKitManager.shared.requestAuthorization()
        let cal = Calendar.training
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred, limit: 20,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        var out: [HealthActivity] = []
        for w in workouts {
            if w.sourceRevision.source.bundleIdentifier.hasPrefix("com.bigscherlytraining") { continue }
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let hr = await heartRate(from: w.startDate, to: w.endDate)
            out.append(HealthActivity(id: w.uuid.uuidString, type: name(w.workoutActivityType), start: w.startDate,
                                      minutes: Int((w.duration / 60).rounded()), kcal: kcal.map { Int($0.rounded()) },
                                      avgHR: hr?.avg, peakHR: hr?.peak))
        }
        return out
    }

    /// Highest heart rate in the last 90 days — a stand-in for your max.
    static func observedMaxHR(demo: Bool) async -> Int? {
        if demo { return 186 }
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let end = Date(), start = end.addingTimeInterval(-90 * 86400)
        return await heartRate(from: start, to: end)?.peak
    }

    static func heartRate(from: Date, to: Date) async -> (avg: Int, peak: Int)? {
        let type = HKQuantityType(.heartRate)
        let pred = HKQuery.predicateForSamples(withStart: from, end: to)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred,
                                      options: [.discreteAverage, .discreteMax]) { _, stats, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                guard let avg = stats?.averageQuantity()?.doubleValue(for: unit),
                      let peak = stats?.maximumQuantity()?.doubleValue(for: unit) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: (Int(avg.rounded()), Int(peak.rounded())))
            }
            store.execute(q)
        }
    }

    private static func name(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Ride"
        case .hiking: return "Hike"
        case .swimming: return "Swim"
        case .rowing: return "Row"
        case .elliptical: return "Elliptical"
        case .stairClimbing, .stairs: return "Stairs"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
        case .crossTraining, .mixedCardio: return "Cross-training"
        case .soccer, .basketball, .tennis, .pickleball, .volleyball, .americanFootball: return "Sport"
        default: return "Workout"
        }
    }

    // Demo mode: a believable run on training-free days so the flow can be seen.
    private static func demoActivities(on day: Date) -> [HealthActivity] {
        let cal = Calendar.training
        guard cal.startOfDay(for: day) <= cal.startOfDay(for: Date()) else { return [] }
        let start = cal.date(bySettingHour: 7, minute: 10, second: 0, of: day) ?? day
        return [HealthActivity(id: "demo-run-\(MacroPlanStore.shared.dayKey(day))", type: "Run", start: start,
                               minutes: 34, kcal: 312, avgHR: 151, peakHR: 172),
                HealthActivity(id: "demo-walk-\(MacroPlanStore.shared.dayKey(day))", type: "Walk",
                               start: start.addingTimeInterval(9 * 3600), minutes: 14, kcal: 58, avgHR: 98, peakHR: 112)]
    }
}
