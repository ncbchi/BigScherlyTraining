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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Progress chart
            if sessions.count > 1 {
                Text("PROGRESS").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                chart
                    .frame(height: 200)
                legend
            }

            // Session table
            Text("SESSION HISTORY").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
            historyTable
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
                .foregroundStyle(Brand.volt)
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
                    Text("+\(gain) lb 1RM").font(BrandFont.body(12, .bold)).foregroundColor(Brand.volt)
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

    private func cell(_ t: String, _ align: Alignment, weight: Font.Weight = .medium, color: Color = .white) -> some View {
        Text(t)
            .font(BrandFont.body(13, weight))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: align)
    }
    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
}
