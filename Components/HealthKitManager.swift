import Foundation
import HealthKit
import Combine

// Reads (never writes) workout + vitals data from Apple Health so a completed
// in-app workout can show what the body actually did, and so trends can be built
// in History. Everything is best-effort: if permission is denied or no matching
// Health workout exists, callers just get nil and show a connect/empty state.
//
// We only READ. No HKWorkoutSession, no writing — this app doesn't track the
// workout itself, it enriches it with data the Watch/phone already recorded.

// A workout's vitals, matched from HealthKit by time window.
struct WorkoutVitals: Codable, Equatable {
    var start: Date
    var end: Date
    var durationMinutes: Int
    var avgHeartRate: Int?
    var peakHeartRate: Int?
    var activeCalories: Int?
    // Sampled HR points across the session, for the sparkline + per-exercise slicing.
    var heartRateSeries: [HeartRateSample]
}

struct HeartRateSample: Codable, Equatable {
    var time: Date
    var bpm: Int
}

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    @Published var isAvailable = HKHealthStore.isHealthDataAvailable()
    @Published var authorizationRequested = false

    // Types we read.
    private var readTypes: Set<HKObjectType> {
        var t = Set<HKObjectType>()
        t.insert(HKObjectType.workoutType())
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { t.insert(hr) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { t.insert(energy) }
        if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) { t.insert(mass) }
        return t
    }

    // Ask for permission. Safe to call repeatedly — HealthKit only shows the sheet
    // the first time. Triggered on first completed-workout open.
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authorizationRequested = true
            return true
        } catch {
            return false
        }
    }

    // MARK: - Workout vitals matched to an in-app workout

    // Find the HealthKit workout closest to the given date and pull its vitals.
    // We look for a workout that overlaps the day; if several exist, the one whose
    // start is nearest the target wins. Returns nil if none found / no permission.
    func vitals(near date: Date) async -> WorkoutVitals? {
        guard isAvailable else { return nil }
        guard let workout = await closestWorkout(to: date) else { return nil }

        async let hr = heartRateStats(start: workout.startDate, end: workout.endDate)
        async let series = heartRateSamples(start: workout.startDate, end: workout.endDate)
        let (hrStats, hrSeries) = await (hr, series)

        // Active energy: use the modern statistics API on iOS 18+, fall back to the
        // (now-deprecated) convenience property on older systems.
        let cals: Double?
        if #available(iOS 18.0, *),
           let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            cals = workout.statistics(for: energyType)?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
        } else {
            cals = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        }
        let mins = Int(workout.duration / 60)

        return WorkoutVitals(
            start: workout.startDate,
            end: workout.endDate,
            durationMinutes: mins,
            avgHeartRate: hrStats?.avg,
            peakHeartRate: hrStats?.peak,
            activeCalories: cals.map { Int($0) },
            heartRateSeries: hrSeries)
    }

    private func closestWorkout(to date: Date) async -> HKWorkout? {
        // Search a ± window around the target date.
        let cal = Calendar.current
        let start = cal.date(byAdding: .hour, value: -18, to: date) ?? date
        let end = cal.date(byAdding: .hour, value: 18, to: date) ?? date
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let workouts = (samples as? [HKWorkout]) ?? []
                let best = workouts.min(by: {
                    abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
                })
                cont.resume(returning: best)
            }
            store.execute(q)
        }
    }

    // MARK: - Heart rate

    private func heartRateStats(start: Date, end: Date) async -> (avg: Int, peak: Int)? {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())

        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: hrType, quantitySamplePredicate: predicate,
                                      options: [.discreteAverage, .discreteMax]) { _, stats, _ in
                guard let stats else { cont.resume(returning: nil); return }
                let avg = stats.averageQuantity()?.doubleValue(for: unit)
                let peak = stats.maximumQuantity()?.doubleValue(for: unit)
                if let avg, let peak {
                    cont.resume(returning: (Int(avg), Int(peak)))
                } else {
                    cont.resume(returning: nil)
                }
            }
            store.execute(q)
        }
    }

    // Down-sampled HR points for the sparkline and per-exercise slicing. We cap the
    // count so the UI + upload stay light (roughly one point per ~30s of session).
    private func heartRateSamples(start: Date, end: Date) async -> [HeartRateSample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: hrType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let qs = (samples as? [HKQuantitySample]) ?? []
                let points = qs.map { HeartRateSample(time: $0.startDate, bpm: Int($0.quantity.doubleValue(for: unit))) }
                cont.resume(returning: Self.downsample(points, maxCount: 120))
            }
            store.execute(q)
        }
    }

    private nonisolated static func downsample(_ points: [HeartRateSample], maxCount: Int) -> [HeartRateSample] {
        guard points.count > maxCount else { return points }
        let stride = Double(points.count) / Double(maxCount)
        var out: [HeartRateSample] = []
        var i = 0.0
        while Int(i) < points.count {
            out.append(points[Int(i)])
            i += stride
        }
        return out
    }

    // MARK: - Bodyweight

    // Most recent bodyweight (lb) logged to Health, if any.
    func latestBodyweightPounds() async -> Double? {
        guard isAvailable,
              let massType = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]

        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: massType, predicate: nil,
                                  limit: 1, sortDescriptors: sort) { _, samples, _ in
                guard let s = (samples as? [HKQuantitySample])?.first else { cont.resume(returning: nil); return }
                cont.resume(returning: s.quantity.doubleValue(for: .pound()))
            }
            store.execute(q)
        }
    }

    // MARK: - Per-exercise HR (slice the series by a set's time window)

    // Given the session's HR series and a start/end window for one exercise,
    // return avg + peak within that window. Used by the History per-exercise view.
    nonisolated static func heartRate(in series: [HeartRateSample], from: Date, to: Date) -> (avg: Int, peak: Int)? {
        let window = series.filter { $0.time >= from && $0.time <= to }
        guard !window.isEmpty else { return nil }
        let bpms = window.map { $0.bpm }
        return (avg: bpms.reduce(0, +) / bpms.count, peak: bpms.max() ?? 0)
    }
}
