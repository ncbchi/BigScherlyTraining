import SwiftUI
import Charts
import UIKit      // selection haptics in DSCarousel

// MARK: - Design system
// The building blocks every screen uses, so the whole app shares one look:
// section headers, stat tiles, chips, buttons, list rows, labelled charts and
// insight cards. Born in Stats; tweak them here and every screen follows.
//
// Target: BigScherlyTraining.

// MARK: Screen + section headers

/// Volt rule + tracked eyebrow, big display title, optional one-line subtitle.
struct DSScreenHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: eyebrow)
            Text(title).font(BrandFont.display(48)).foregroundColor(Brand.text)
                .lineLimit(2).minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle).font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "THIS WEEK  Sep 27 – Oct 3"
struct DSSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(BrandFont.body(12, .bold)).tracking(1.8).headerPill()
            if let subtitle { Text(subtitle).font(BrandFont.body(11)).foregroundColor(Brand.mute) }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Stat tile

struct DSStatTile: View {
    let value: String
    let label: String
    var sub: String? = nil
    var color: Color = Brand.volt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.display(28)).foregroundColor(Brand.readable(color))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(BrandFont.body(8, .bold)).tracking(1).foregroundColor(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub).font(BrandFont.body(10)).foregroundColor(Brand.mute).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: Chip

struct DSChip: View {
    let text: String
    var icon: String? = nil
    var color: Color = Brand.volt
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(BrandFont.body(11, .bold)).lineLimit(1)
        }
        .foregroundColor(filled ? Brand.onVolt : color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(filled ? color : Color.clear))
        .overlay(Capsule().stroke(color.opacity(filled ? 1 : 0.7), lineWidth: 1))
    }
}

// MARK: Buttons

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, dark }
    var kind: Kind = .primary
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(15, .bold)).tracking(0.3)
            .foregroundColor(fg)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .padding(.horizontal, 18)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(stroke, lineWidth: kind == .secondary ? 2 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }

    private var bg: Color {
        switch kind {
        case .primary: return Brand.volt
        case .secondary: return .clear
        case .dark: return Brand.black
        }
    }
    private var fg: Color {
        switch kind {
        case .primary: return Brand.onVolt
        case .secondary, .dark: return Brand.voltText
        }
    }
    private var stroke: Color { kind == .secondary ? Brand.voltText : .clear }
}

/// Round icon-only button (44pt touch target).
struct DSIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var size: CGFloat = 44
    var tint: Color = Brand.text
    var fill: Color = Brand.text.opacity(0.08)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(Brand.readable(tint))
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: List row

struct DSListRow: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var icon: String? = nil
    var iconTint: Color = Brand.volt

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(Brand.readable(iconTint))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.text.opacity(0.06)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(BrandFont.body(11)).foregroundColor(Brand.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text) }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.mute)
        }
        .padding(14)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: Progress bar

struct DSProgressBar: View {
    let fraction: Double
    var height: CGFloat = 8
    var color: Color = Brand.voltLine          // progress reads as a line

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.text.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

// MARK: Top fade (keeps content from colliding with the floating menu button)

extension View {
    func dsTopFade(_ height: CGFloat = 70) -> some View {
        overlay(alignment: .top) {
            LinearGradient(colors: [Brand.bg, Brand.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: height).ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
    }
}

// MARK: - Insight cards

struct InsightCard: Identifiable {
    var id: String
    var icon: String
    var title: String
    var value: String?
    var sentence: String
    var points: [(Date, Double)]
    var color: Color
    var target: StatsSubject?
    var bars: [(name: String, value: Double)] = []
    var chartLabel: String = ""
    var unit: String = ""
    var highlight: Date? = nil
    var list: [InsightListItem] = []
    var listTitle: String? = nil
}

struct InsightListItem: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var detail: String
}

struct InsightCardView: View {
    let card: InsightCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.icon).font(.system(size: 11, weight: .bold)).foregroundColor(Brand.onVolt)
                    .frame(width: 22, height: 22).background(Circle().fill(card.color))
                Text(card.title).font(BrandFont.body(10, .bold)).tracking(1.2).foregroundColor(Brand.readable(card.color))
                Spacer()
                if card.target != nil || card.id == "notes" {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Brand.mute)
                }
            }
            if let v = card.value {
                Text(v).font(BrandFont.display(30)).foregroundColor(Brand.text).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(card.sentence).font(BrandFont.body(12)).foregroundColor(Brand.text.opacity(0.85))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if card.points.count > 1 {
                MiniChart(lines: [MiniChart.Line(name: card.chartLabel, color: card.color, points: card.points)],
                          unit: card.unit, height: card.list.isEmpty ? 120 : 96, highlight: card.highlight)
            } else if !card.bars.isEmpty {
                let maxV = card.bars.map { $0.value }.max() ?? 1
                VStack(spacing: 4) {
                    ForEach(card.bars, id: \.name) { name, v in
                        HStack(spacing: 8) {
                            Text(name).font(BrandFont.body(11)).foregroundColor(Brand.text).frame(width: 82, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                Capsule().fill(card.color.opacity(0.85)).frame(width: max(4, g.size.width * v / maxV))
                            }
                            .frame(height: 8)
                            Text("\(Int(v))").font(BrandFont.body(11, .bold)).foregroundColor(Brand.mute)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    Text("Sets per muscle group").font(BrandFont.body(10)).foregroundColor(Brand.mute)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                }
            }
            if !card.list.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let t = card.listTitle {
                        Text(t).font(BrandFont.body(9, .bold)).tracking(1).foregroundColor(Brand.mute)
                    }
                    ForEach(card.list) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Brand.readable(card.color)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(BrandFont.body(11, .bold)).foregroundColor(Brand.text).lineLimit(1)
                                Text(item.detail).font(BrandFont.body(11)).foregroundColor(Brand.mute)
                                    .lineLimit(card.points.isEmpty ? 3 : 1)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.text.opacity(0.05)))
                    }
                }
            }
        }
        .padding(14)
        .frame(height: 330, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}


// MARK: - Shared pieces

struct StatsWindowPicker: View {
    @Binding var selection: StatsWindow
    var body: some View {
        HStack(spacing: 6) {
            ForEach(StatsWindow.allCases) { w in
                Button { withAnimation(.easeInOut(duration: 0.2)) { selection = w } } label: {
                    Text(w.rawValue)
                        .font(BrandFont.body(12, .bold))
                        .foregroundColor(selection == w ? Brand.onVolt : Brand.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(selection == w ? Brand.volt : Brand.black).clipShape(Capsule())
                        .overlay(Capsule().stroke(selection == w ? Brand.voltLine : Brand.line, lineWidth: 1))
                }
            }
        }
    }
}

struct Sparkline: View {
    let points: [(Date, Double)]
    let color: Color
    var body: some View {
        let vals = points.map { $0.1 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.15, 0.01)
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Date", p.0), yStart: .value("Base", lo - pad), yEnd: .value("Value", p.1))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", p.0), y: .value("Value", p.1))
                    .foregroundStyle(Brand.readableLine(color)).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    }
}



// MARK: - Small labelled chart (dashboard)
// Same idea as the detail chart, sized for a card: y-axis with values, dated
// x-axis, and a legend naming every line and its unit.

enum ChartFormat {
    static func axis(_ v: Double) -> String {
        let a = abs(v)
        if a >= 10_000 { return String(format: "%.0fk", v / 1000) }
        if a >= 1000 { return String(format: "%.1fk", v / 1000) }
        if a >= 20 || v == v.rounded() { return "\(Int(v.rounded()))" }
        if a >= 1 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

struct MiniChart: View {
    struct Line: Identifiable {
        var name: String
        var color: Color
        var points: [(Date, Double)]
        var id: String { name }
    }

    let lines: [Line]
    let unit: String
    var height: CGFloat = 130
    /// Marks this date on the first line with a ring and label (e.g. the PR session).
    var highlight: Date? = nil

    private var yDomain: ClosedRange<Double> {
        let v = lines.flatMap { $0.points.map { $0.1 } }
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let pad = max((hi - lo) * 0.15, abs(hi) * 0.03, 0.02)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(lines) { l in
                    ForEach(Array(l.points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Date", p.0), y: .value(unit, p.1), series: .value("Line", l.name))
                            .foregroundStyle(Brand.readableLine(l.color))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", p.0), y: .value(unit, p.1))
                            .foregroundStyle(Brand.readableLine(l.color)).symbolSize(10)
                    }
                }
                if let h = highlight, let first = lines.first,
                   let p = first.points.min(by: { abs($0.0.timeIntervalSince(h)) < abs($1.0.timeIntervalSince(h)) }) {
                    PointMark(x: .value("Date", p.0), y: .value(unit, p.1))
                        .symbol(.circle).symbolSize(90)
                        .foregroundStyle(Brand.readableLine(first.color).opacity(0.25))
                        .annotation(position: .top, spacing: 2) {
                            Text("PR").font(BrandFont.body(9, .heavy)).foregroundColor(Brand.onVolt)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(first.color))
                        }
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Brand.line)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(ChartFormat.axis(d)) }
                    }
                    .foregroundStyle(Brand.mute)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisTick().foregroundStyle(Brand.line)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Brand.mute)
                }
            }
            .chartLegend(.hidden)
            .frame(height: height)

            HStack(spacing: 12) {
                ForEach(lines) { l in
                    HStack(spacing: 5) {
                        Capsule().fill(l.color).frame(width: 12, height: 3)
                        Text(l.name).font(BrandFont.body(10)).foregroundColor(Brand.mute)
                    }
                }
                Spacer(minLength: 0)
                Text(unit).font(BrandFont.body(10, .bold)).foregroundColor(Brand.mute)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

// MARK: - Carousel picker (pick one of a set)
// Replaces every horizontally-scrolling row of choice chips. The selected option sits in the
// centre, highlighted; its neighbours peek in on both sides, smaller and dimmer. Swipe and
// it snaps the next option to the centre, which selects it (with a light tick); tap a side
// option to bring it over. Dots underneath show how many options there are and which one
// you're on. The most likely option is placed in the middle of the row (the others keep
// their order around it), so there's something to swipe to either way.

struct DSCarousel<ID: Hashable>: View {
    struct Option: Identifiable {
        let id: ID
        let label: String
        var tint: Color = Brand.volt
        var marked: Bool = false             // a small dot, e.g. "has a note"
    }

    let options: [Option]
    @Binding var selection: ID
    /// Put this option in the middle of the row. Leave nil to keep the given order
    /// (e.g. exercises, which follow the workout).
    var likely: ID? = nil
    var itemWidth: CGFloat = 120
    var height: CGFloat = 38
    var accessibilityName: String = "Options"

    @State private var centred: ID?

    private var ordered: [Option] {
        guard let likely, let i = options.firstIndex(where: { $0.id == likely }) else { return options }
        var rest = options
        let l = rest.remove(at: i)
        rest.insert(l, at: rest.count / 2)
        return rest
    }

    var body: some View {
        let items = ordered
        let shown = centred ?? selection
        VStack(spacing: 8) {
            GeometryReader { g in
                let w = g.size.width, iw = itemWidth, step = itemWidth + 8
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { o in
                            Button {
                                withAnimation(.snappy(duration: 0.3)) { centred = o.id }
                            } label: {
                                face(o, on: o.id == shown)
                            }
                            .buttonStyle(.plain)
                            .frame(width: iw, height: height)
                            // Shrink and fade with distance from the centre.
                            .visualEffect { content, proxy in
                                let mid = proxy.frame(in: .scrollView(axis: .horizontal)).midX
                                let d = min(abs(mid - w / 2) / step, 1)
                                return content.scaleEffect(1 - 0.12 * d).opacity(1 - 0.5 * d)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max((w - iw) / 2, 0), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centred, anchor: .center)
            }
            .frame(height: height)

            // Where you are in the set.
            HStack(spacing: 5) {
                ForEach(items) { o in
                    Capsule().fill(o.id == shown ? Brand.volt : Brand.text.opacity(0.22))
                        .frame(width: o.id == shown ? 16 : 6, height: 6)
                }
            }
            .animation(.snappy(duration: 0.25), value: shown)
            .accessibilityHidden(true)
        }
        .onAppear { centred = selection }
        .onChange(of: centred) { _, new in
            guard let new, new != selection else { return }
            selection = new
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: selection) { _, new in
            if centred != new { withAnimation(.snappy(duration: 0.3)) { centred = new } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(items.first { $0.id == selection }?.label ?? "")
        .accessibilityHint("Swipe up or down to change")
        .accessibilityAdjustableAction { dir in
            guard let i = items.firstIndex(where: { $0.id == selection }) else { return }
            switch dir {
            case .increment: if i + 1 < items.count { selection = items[i + 1].id }
            case .decrement: if i > 0 { selection = items[i - 1].id }
            @unknown default: break
            }
        }
    }

    private func face(_ o: Option, on: Bool) -> some View {
        HStack(spacing: 6) {
            Text(o.label).font(BrandFont.body(13, .bold)).lineLimit(1).minimumScaleFactor(0.7)
            if o.marked {
                Circle().fill(on ? Brand.black : o.tint).frame(width: 6, height: 6)
            }
        }
        .foregroundColor(on ? Brand.onVolt : Brand.text)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(on ? o.tint : Brand.black))
        .overlay(Capsule().stroke(on ? o.tint : Brand.line, lineWidth: 1))
        .contentShape(Capsule())
    }
}

