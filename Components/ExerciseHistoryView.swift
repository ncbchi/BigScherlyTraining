import SwiftUI
import Charts

// MARK: - Exercise History (reusable)
// Shows a dual-line progress chart (estimated 1RM + average working weight)
// and a table of past sessions: date, weight, reps, effort (RPE).
// Used inline on the exercise detail page AND in the History drawer tab.
struct ExerciseHistoryView: View {
    @EnvironmentObject var store: AppStore
    let exerciseName: String

    private var sessions: [ExerciseHistorySession] { store.history(for: exerciseName) }

    // Per-exercise heart-rate summary for the EFFORT card. Uses real sliced data
    // when available (averaged across sessions), else mock in demo mode.
    private var exerciseHR: (avg: Int, peak: Int)? {
        guard !sessions.isEmpty else { return nil }
        let points = hrTrend
        if !points.isEmpty {
            let avg = points.map { $0.avg }.reduce(0, +) / points.count
            let peak = points.map { $0.peak }.max() ?? 0
            return (avg: avg, peak: peak)
        }
        return nil
    }

    // Per-session HR points (date, avg, peak) for the across-sessions chart.
    struct HRPoint: Identifiable { let id: String; let date: Date; let avg: Int; let peak: Int }
    private var hrTrend: [HRPoint] {
        let ordered = sessions.sorted { $0.date < $1.date }

        // Real path: for each session (id == workout id), slice that workout's stored
        // HR series to this exercise's set-time window.
        let real: [HRPoint] = ordered.compactMap { s in
            guard let vitals = store.workoutVitals[s.id],
                  vitals.heartRateSeries.count > 1 else { return nil }
            let window = exerciseWindow(workoutId: s.id, vitals: vitals)
            guard let hr = HealthKitManager.heartRate(in: vitals.heartRateSeries,
                                                      from: window.from, to: window.to) else { return nil }
            return HRPoint(id: s.id, date: s.date, avg: hr.avg, peak: hr.peak)
        }
        if !real.isEmpty { return real }

        // Demo / fallback.
        guard store.isDemoMode || APIConfig.useMock else { return [] }
        return ordered.enumerated().map { i, s in
            let hr = MockData.sessionHR(exerciseName: exerciseName, sessionId: s.id, index: i, total: ordered.count)
            return HRPoint(id: s.id, date: s.date, avg: hr.avg, peak: hr.peak)
        }
    }

    // The time window during which THIS exercise was performed in a given workout,
    // from the earliest to latest logged-set timestamp of that exercise.
    private func exerciseWindow(workoutId: String, vitals: WorkoutVitals) -> (from: Date, to: Date) {
        if let w = store.workouts.first(where: { $0.id == workoutId }),
           let ex = w.exercises.first(where: { $0.name == exerciseName }) {
            let stamps = ex.sets.compactMap { $0.loggedAt }.sorted()
            if let first = stamps.first, let last = stamps.last {
                // Pad the start back ~90s so the first set's ramp is included.
                return (from: first.addingTimeInterval(-90), to: last)
            }
        }
        return (from: vitals.start, to: vitals.end)
    }

    private var hrChart: some View {
        Chart {
            ForEach(hrTrend) { p in
                LineMark(x: .value("Date", p.date), y: .value("Peak", p.peak),
                         series: .value("Metric", "Peak"))
                    .foregroundStyle(Brand.voltLine).symbol(Circle()).symbolSize(28)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(hrTrend) { p in
                LineMark(x: .value("Date", p.date), y: .value("Avg", p.avg),
                         series: .value("Metric", "Avg"))
                    .foregroundStyle(Color(hex: 0x3D9BE0)).symbol(Circle()).symbolSize(28)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale(["Peak": Brand.voltLine, "Avg": Color(hex: 0x3D9BE0)])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(Brand.mute)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel().foregroundStyle(Brand.mute)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Effort (heart rate during this lift)
            if let hr = exerciseHR {
                Text("EFFORT").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                HStack(spacing: 10) {
                    effortStat("\(hr.avg)", "AVG BPM", "heart.fill")
                    effortStat("\(hr.peak)", "PEAK BPM", "bolt.heart.fill")
                    effortStat(zoneLabel(hr.avg), "TYPICAL ZONE", "waveform.path.ecg")
                }
                Text("Heart rate recorded while training \(exerciseName.lowercased()).")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }

            // Heart-rate trend across sessions (avg + peak by date)
            if hrTrend.count > 1 {
                Text("HEART RATE OVER TIME").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                hrChart.frame(height: 180)
                HStack(spacing: 20) {
                    legendDot(Brand.volt, "Peak BPM")
                    legendDot(Color(hex: 0x3D9BE0), "Avg BPM")
                    Spacer()
                }
            }

            // Progress chart
            if sessions.count > 1 {
                Text("PROGRESS").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                chart
                    .frame(height: 200)
                legend
            }

            // Session table
            Text("SESSION HISTORY").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            historyTable
        }
        .task {
            // Load stored HealthKit vitals for each session so the HR trend + EFFORT
            // card can slice real data. Cached in the store, so this is cheap on reopen.
            for s in sessions {
                _ = await store.loadWorkoutVitals(workoutId: s.id)
            }
        }
    }

    private func effortStat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundColor(Brand.voltText).font(.system(size: 15))
            Text(value).font(BrandFont.display(22)).foregroundColor(Brand.text).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(BrandFont.body(8, .bold)).tracking(0.5).foregroundColor(Brand.mute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
    }

    // Rough effort zone from average BPM.
    private func zoneLabel(_ bpm: Int) -> String {
        switch bpm {
        case ..<115: return "Easy"
        case 115..<140: return "Moderate"
        case 140..<160: return "Hard"
        default: return "Max"
        }
    }

    // MARK: Chart (dual line: 1RM + avg weight)
    private var chart: some View {
        Chart {
            ForEach(sessions) { s in
                LineMark(
                    x: .value("Date", s.date),
                    y: .value("Est. 1RM", s.estimatedOneRepMax),
                    series: .value("Metric", "Est. 1RM")
                )
                .foregroundStyle(Brand.voltText)
                .symbol(Circle()).symbolSize(28)
                .interpolationMethod(.catmullRom)
            }
            ForEach(sessions) { s in
                LineMark(
                    x: .value("Date", s.date),
                    y: .value("Avg Weight", s.avgWeight),
                    series: .value("Metric", "Avg Weight")
                )
                .foregroundStyle(Color(hex: 0x3D9BE0))
                .symbol(Circle()).symbolSize(28)
                .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale([
            "Est. 1RM": Brand.volt,
            "Avg Weight": Color(hex: 0x3D9BE0)
        ])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(Brand.mute)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Brand.line)
                AxisValueLabel().foregroundStyle(Brand.mute)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 20) {
            legendDot(Brand.volt, "Est. 1RM")
            legendDot(Color(hex: 0x3D9BE0), "Avg Weight")
            Spacer()
            if let first = sessions.first, let last = sessions.last {
                let gain = Int(last.estimatedOneRepMax - first.estimatedOneRepMax)
                if gain > 0 {
                    Text("+\(gain) lb 1RM").font(BrandFont.body(12, .bold)).foregroundColor(Brand.voltText)
                }
            }
        }
    }
    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text(label).font(BrandFont.body(12, .medium)).foregroundColor(Brand.mute)
        }
    }

    // MARK: Table
    private var historyTable: some View {
        VStack(spacing: 0) {
            // header row
            HStack {
                cell("DATE", .leading, weight: .bold, color: Brand.mute)
                cell("SETS", .leading, weight: .bold, color: Brand.mute)
                cell("TOP", .trailing, weight: .bold, color: Brand.mute)
                cell("RPE", .trailing, weight: .bold, color: Brand.mute).frame(width: 46)
            }
            .padding(.vertical, 8)
            Rectangle().fill(Brand.line).frame(height: 1)

            ForEach(sessions.reversed()) { s in
                HStack {
                    cell(dateLabel(s.date), .leading)
                    cell(s.setSummary, .leading, color: Brand.mute)
                    cell("\(Int(s.topWeight))", .trailing, weight: .bold)
                    cell(s.avgRpe > 0 ? String(format: "%.0f", s.avgRpe) : "—", .trailing, color: Brand.volt).frame(width: 46)
                }
                .padding(.vertical, 10)
                Rectangle().fill(Brand.line.opacity(0.5)).frame(height: 1)
            }
        }
        .card()
    }

    private func cell(_ t: String, _ align: Alignment, weight: Font.Weight = .medium, color: Color = Brand.text) -> some View {
        Text(t)
            .font(BrandFont.body(13, weight))
            .foregroundColor(Brand.readable(color))
            .frame(maxWidth: .infinity, alignment: align)
    }
    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
}
