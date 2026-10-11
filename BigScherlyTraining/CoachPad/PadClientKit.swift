import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: the parts every client section shares (Oct 9, 2026)
//
// Every section reads the same way: a headline strip (3–4 numbers that answer "how is this
// going?"), a noticing line (only when there's something real), the tools top right, and the
// work area using the full width. Plus a quick-message sheet and the coach's lift goals.
// Synchronized folder: no target step needed.

struct PadStat: Identifiable {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String = ""
    var warn = false
    var good = false
    var id: String { label }
}

/// Headline strip on the left, tools on the right, the noticing line under both.
struct PadSectionTop<Tools: View>: View {
    let stats: [PadStat]
    var notices: [PadInsights.Notice] = []
    @ViewBuilder var tools: () -> Tools

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(stats) { s in tile(s) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                Spacer(minLength: 8)
                HStack(spacing: 8) { tools() }
            }
            if !notices.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(notices.prefix(3)) { n in
                        PadNoticeRow(notice: n)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
    }

    private func tile(_ s: PadStat) -> some View {
        let subColor: Color = s.warn ? Pad.orange : (s.good ? Pad.voltText : Pad.mute)
        return VStack(alignment: .leading, spacing: 2) {
            PadLab(s.label, size: 12).lineLimit(1)
            PadNumber(value: s.value, unit: s.unit, size: 26, color: s.warn ? Pad.orange : Pad.text)
            PadLab(s.sub, color: subColor, size: 12).lineLimit(1)
        }
        .frame(minWidth: 120, maxWidth: 180, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }
}

/// A titled panel in a section's work area.
struct PadPane<Content: View>: View {
    let title: String
    var aside: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer(minLength: 6)
                if let aside { PadLab(aside, color: Pad.faint, size: 12) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }
}

/// An empty or "nothing yet" line inside a pane.
struct PadEmptyLine: View {
    let text: String
    var body: some View {
        Text(text).font(PadFont.ui(14)).foregroundColor(Pad.mute).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

// MARK: - Quick message (shout-outs, nudges, photo requests)

struct PadQuickMessage: Identifiable {
    let id = UUID()
    let clientId: String
    let clientName: String
    let title: String
    let text: String
}

struct PadQuickMessageSheet: View {
    let message: PadQuickMessage
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(message.title).font(PadFont.display(28)).foregroundColor(Pad.text)
                Spacer()
                Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute).keyboardShortcut(.cancelAction)
            }
            PadLab("Goes to \(message.clientName.firstName)’s latest conversation.")
            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 140).padInput(multiline: true)
            if failed { Text("Couldn’t send. Check your connection and try again.").font(PadFont.ui(13)).foregroundColor(Pad.orange) }
            HStack {
                Spacer()
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) { if sending { ProgressView().tint(Pad.onVolt) }; Text("Send") }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .onAppear { text = message.text }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true; failed = false
        Task {
            do {
                try await CoachMessenger.send(t, to: message.clientId)
                await MainActor.run {
                    sending = false
                    PadToasts.shared.show("Sent to \(message.clientName.firstName)")
                    dismiss()
                }
            } catch {
                await MainActor.run { sending = false; failed = true }
            }
        }
    }
}

// MARK: - Lift goals (kept on the server with the coach's settings, key "clientLiftGoals")

struct PadLiftGoal: Codable, Hashable {
    var lift: String
    var target: Double      // e1RM, lb
    var by: String          // yyyy-MM-dd
}

@MainActor
final class PadLiftGoals: ObservableObject {
    static let shared = PadLiftGoals()
    static let key = "clientLiftGoals"
    @Published private(set) var goals: [String: [PadLiftGoal]] = [:]
    private var loaded = false

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.training.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let d = UserDefaults.standard.data(forKey: "bst_pad_lift_goals"),
           let g = try? JSONDecoder().decode([String: [PadLiftGoal]].self, from: d) { goals = g }
    }

    func load(store: AppStore) async {
        guard store.isLive, !loaded else { return }
        loaded = true
        guard let s = try? await APIClient.shared.trainerSetting(Self.key), let json = s.json,
              let g = try? JSONDecoder().decode([String: [PadLiftGoal]].self, from: Data(json.utf8)) else { return }
        goals = g
        cache()
    }

    func goal(_ clientId: String, lift: String) -> PadLiftGoal? { goals[clientId]?.first { $0.lift == lift } }

    func set(_ goal: PadLiftGoal?, lift: String, clientId: String, store: AppStore) {
        var list = (goals[clientId] ?? []).filter { $0.lift != lift }
        if let goal { list.append(goal) }
        goals[clientId] = list.isEmpty ? nil : list
        cache()
        guard store.isLive, let data = try? JSONEncoder().encode(goals), let json = String(data: data, encoding: .utf8) else { return }
        Task { _ = try? await APIClient.shared.saveTrainerSetting(Self.key, json: json) }
    }

    private func cache() {
        if let d = try? JSONEncoder().encode(goals) { UserDefaults.standard.set(d, forKey: "bst_pad_lift_goals") }
    }
}

// MARK: - Small helpers

extension Double {
    /// "1.2" / "12" — one decimal only when it matters.
    var padShort: String { self == rounded() ? "\(Int(self))" : String(format: "%.1f", self) }
}

enum PadDay {
    static var cal: Calendar { Calendar.training }
    static func short(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
    static func weekdayShort(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    static func daysAgo(_ d: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0 }
    static func agoText(_ d: Date) -> String {
        let n = daysAgo(d)
        return n == 0 ? "today" : (n == 1 ? "yesterday" : "\(n) days ago")
    }
}

/// A line chart for a few points, with an optional dashed goal/target line.
struct PadLineChart: View {
    let points: [Double]
    var goal: Double? = nil
    var color: Color = Pad.text
    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2 else { return }
            var all = points
            if let goal { all.append(goal) }
            let mn = all.min() ?? 0, mx = all.max() ?? 1
            let rng = max(mx - mn, 0.5)
            func y(_ v: Double) -> CGFloat { 3 + (size.height - 6) * (1 - CGFloat((v - mn) / rng)) }
            if let goal {
                var g = Path()
                g.move(to: CGPoint(x: 0, y: y(goal))); g.addLine(to: CGPoint(x: size.width, y: y(goal)))
                ctx.stroke(g, with: .color(Pad.voltText.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            }
            var p = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(points.count - 1), y: y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let last = CGPoint(x: size.width, y: y(points.last!))
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(Pad.volt))
        }
        .accessibilityHidden(true)
    }
}

/// Simple vertical bars; the last one in the accent colour.
struct PadBars: View {
    let values: [Double]
    var labels: [String] = []
    var height: CGFloat = 60
    var body: some View {
        let mx = max(values.max() ?? 1, 0.0001)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == values.count - 1 ? Pad.volt : Pad.raised)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, height * CGFloat(v / mx)))
                }
            }
            .frame(height: height, alignment: .bottom)
            if !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                        Text(l).font(PadFont.cond(10)).foregroundColor(Pad.faint).frame(maxWidth: .infinity).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
