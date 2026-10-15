import SwiftUI

// MARK: - Coach HQ on iPad: Check-in review (Oct 8, 2026)
//
// Queue | review | your reply. Replying opens the next waiting check-in straight away.
// Synchronized folder: no target step needed.

struct PadCheckInsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var nav = PadNav.shared
    @Environment(\.padSideBySide) private var sideBySide
    @State private var selectedId: String?
    @State private var replySheet = false

    struct Entry: Identifiable {
        let checkIn: APICheckIn
        let clientId: String
        let clientName: String
        var id: String { checkIn.id }
    }

    private var waiting: [Entry] {
        store.checkInQueue.sorted { $0.checkIn.date < $1.checkIn.date }.map { Entry(checkIn: $0.checkIn, clientId: $0.clientId, clientName: $0.clientName) }
    }
    private var answered: [Entry] {
        let since = Calendar.training.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.roster.flatMap { c in
            (coach.checkIns[c.id] ?? []).filter { $0.status != "draft" && $0.date >= since && !($0.trainerResponse ?? "").isEmpty }
                .map { Entry(checkIn: $0, clientId: c.id, clientName: c.name) }
        }
        .filter { e in !waiting.contains { $0.id == e.id } }
        .sorted { $0.checkIn.date > $1.checkIn.date }
    }
    private var all: [Entry] { waiting + answered }
    private var current: Entry? {
        if let e = all.first(where: { $0.id == selectedId }) { return e }
        // A previous check-in opened from "Last week's" that isn't in either list.
        for c in store.roster {
            if let ci = (coach.checkIns[c.id] ?? []).first(where: { $0.id == selectedId }) {
                return Entry(checkIn: ci, clientId: c.id, clientName: c.name)
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Check-ins", subtitle: subtitle) {
                HStack(spacing: 14) {
                    PadLab("With a keyboard:", color: Pad.faint)
                    key("⌃J", "next"); key("⌃K", "previous"); key("⌘↵", "reply and next")
                }
            }
            PadRule()
            HStack(spacing: 0) {
                queue.frame(width: 248)
                Rectangle().fill(Pad.line).frame(width: 1)
                if let e = current {
                    PadCheckInReview(entry: e, showReplyButton: !sideBySide, onOpen: { selectedId = $0 }, onReply: { replySheet = true })
                        .id(e.id)
                    if sideBySide {
                        Rectangle().fill(Pad.line).frame(width: 1)
                        PadReplyPane(entry: e, nextName: nextAfter(e)?.clientName.firstName, onSent: { advance(from: e) })
                            .id(e.id)
                            .frame(width: 340)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text(store.rosterLoading && store.checkInQueue.isEmpty ? "" : "Queue’s empty").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                        Text("No check-ins waiting for a reply.").font(PadFont.ui(14)).foregroundColor(Pad.mute)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .background(keys)
        .sheet(isPresented: $replySheet) {
            if let e = current {
                PadReplyPane(entry: e, nextName: nextAfter(e)?.clientName.firstName, asSheet: true, onSent: { replySheet = false; advance(from: e) })
                    .presentationDetents([.large])
            }
        }
        .task {
            for c in store.roster { await coach.loadCheckIns(c.id) }
            consumeNav()
            if selectedId == nil { selectedId = waiting.first?.id ?? answered.first?.id }
        }
        .onChange(of: nav.checkInId) { _, _ in consumeNav() }
        .onChange(of: store.checkInQueue.map { $0.id }) { _, _ in
            if selectedId == nil || current == nil { selectedId = waiting.first?.id ?? answered.first?.id }
        }
    }

    private func consumeNav() {
        if let id = nav.checkInId { selectedId = id; nav.checkInId = nil }
    }

    private var subtitle: String {
        if waiting.isEmpty { return "Nothing waiting. \(answered.count.plural("check-in")) answered this week." }
        let oldest = waiting.first!.checkIn.date
        return "\(waiting.count) waiting. Oldest sent \(oldest.padAgo)."
    }

    private func key(_ k: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(PadFont.cond(11)).foregroundColor(Pad.mute).padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Pad.line2, lineWidth: 1))
            Text(what).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
    }

    private func nextAfter(_ e: Entry) -> Entry? {
        let w = waiting
        guard let i = w.firstIndex(where: { $0.id == e.id }) else { return w.first }
        return i + 1 < w.count ? w[i + 1] : nil
    }

    private func advance(from e: Entry) {
        let next = nextAfter(e)
        store.loadRoster()
        Task { await coach.loadCheckIns(e.clientId, force: true) }
        PadToasts.shared.show("Replied to \(e.clientName.firstName)")
        if let n = next { selectedId = n.id } else { selectedId = nil }
    }

    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PadLab("Waiting").padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
                if waiting.isEmpty {
                    Text(store.rosterLoading && !data.hasLoaded ? "" : "Nobody").font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(.horizontal, 10).padding(.bottom, 6)
                }
                ForEach(waiting) { e in queueRow(e, dim: false) }
                if !answered.isEmpty {
                    PadLab("Answered this week").padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                    ForEach(answered) { e in queueRow(e, dim: true) }
                }
            }
            .padding(8)
        }
    }

    private func queueRow(_ e: Entry, dim: Bool) -> some View {
        let on = e.id == selectedId
        let flagged = PadCheckInReview.flaggedLine(e.checkIn) != nil
        return Button { selectedId = e.id } label: {
            HStack(spacing: 12) {
                PadAvatar(name: e.clientName, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.clientName).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(dim ? "Sent \(e.checkIn.date.formatted(.dateTime.weekday(.wide))) · replied" : "\(weekLabel(e.clientId))\(e.checkIn.date.padAgo)")
                        .font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if flagged && !dim { PadTag(text: "Flagged", kind: .warn) }
            }
            .padding(.horizontal, 10).frame(minHeight: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Pad.surface : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Pad.line2 : Color.clear, lineWidth: 1))
            .opacity(dim && !on ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func weekLabel(_ clientId: String) -> String {
        if let a = data.assignments.first(where: { $0.clientId == clientId && $0.status.lowercased() != "ended" }), a.currentWeek > 0 {
            return "Week \(a.currentWeek) · "
        }
        return ""
    }

    private var keys: some View {
        Group {
            Button("Next check-in") { step(1) }.keyboardShortcut("j", modifiers: .control)
            Button("Previous check-in") { step(-1) }.keyboardShortcut("k", modifiers: .control)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
    private func step(_ d: Int) {
        let list = all
        guard !list.isEmpty else { return }
        guard let i = list.firstIndex(where: { $0.id == selectedId }) else { selectedId = list.first?.id; return }
        selectedId = list[min(max(i + d, 0), list.count - 1)].id
    }
}

// MARK: - The review

struct PadCheckInReview: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var data = PadData.shared
    @Environment(\.padSideBySide) private var sideBySide
    let entry: PadCheckInsView.Entry
    var showReplyButton = false
    var onOpen: (String) -> Void
    var onReply: () -> Void
    @State private var photos: [APIPhoto] = []
    @State private var compare = false

    private var cal: Calendar { Calendar.training }
    private var ci: APICheckIn { entry.checkIn }
    private var history: [APICheckIn] { (coach.checkIns[entry.clientId] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date } }
    private var previous: APICheckIn? { history.last { $0.date < ci.date && $0.id != ci.id } }

    static let flagWords = ["pain", "hurt", "injur", "tight", "sore", "ache", "tweak", "pinch", "strain"]
    static func flaggedLine(_ ci: APICheckIn) -> String? {
        ci.fields.first { f in Double(f.value) == nil && flagWords.contains { f.value.lowercased().contains($0) } }?.value
    }
    static func isFlagged(_ f: APICheckInField) -> Bool {
        Double(f.value) == nil && flagWords.contains { f.value.lowercased().contains($0) }
    }

    struct Metric: Identifiable {
        let id: String; let label: String; let now: Double; let prev: Double?; let unit: String; let better: Bool?; let isWeight: Bool
    }

    private var metrics: [Metric] {
        ci.fields.sorted { $0.fieldOrder < $1.fieldOrder }.compactMap { f in
            guard let v = Double(f.value) else { return nil }
            let q = CheckInSchema.questions.first { $0.label == f.cleanLabel }
            let isWeight = q?.id == "weight" || f.cleanLabel.lowercased().contains("weight")
            let conv: (Double) -> Double = { isWeight ? StatsUnits.weight($0) : $0 }
            let prev = previous?.fields.first { $0.cleanLabel == f.cleanLabel }.flatMap { Double($0.value) }
            let isScale = q?.kind == .scale || (!isWeight && v <= 10 && v == v.rounded())
            return Metric(id: f.id, label: shortLabel(f.cleanLabel), now: conv(v), prev: prev.map(conv),
                          unit: isWeight ? StatsUnits.weightLabel : (isScale ? "/10" : (q?.unit ?? "")),
                          better: isWeight ? nil : (q?.higherIsBetter ?? true), isWeight: isWeight)
        }
    }

    private func shortLabel(_ l: String) -> String {
        let map = ["Nutrition adherence": "Nutrition", "Workout consistency": "Consistency", "Sleep quality": "Sleep",
                   "Energy / fatigue": "Energy", "Stress load": "Stress", "Soreness / recovery": "Recovery",
                   "Cravings / hunger": "Hunger", "Motivation / mood": "Mood"]
        return map[l] ?? l
    }

    private var words: [APICheckInField] {
        ci.fields.sorted { $0.fieldOrder < $1.fieldOrder }.filter { Double($0.value) == nil && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricGrid
                trendWell
                if !words.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(words, id: \.id) { f in
                            PadRule()
                            HStack(alignment: .top, spacing: 16) {
                                Text(f.cleanLabel).font(PadFont.ui(14)).foregroundColor(Pad.mute).frame(width: 150, alignment: .leading)
                                HStack(alignment: .top, spacing: 8) {
                                    if Self.isFlagged(f) { PadTag(text: "Flagged", kind: .warn) }
                                    Text(f.value).font(PadFont.ui(15)).foregroundColor(Pad.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
                photoSection
                if let r = ci.trainerResponse, !r.isEmpty, !sideBySide {
                    VStack(alignment: .leading, spacing: 6) {
                        PadLab("Your reply")
                        Text(r).font(PadFont.ui(15)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padWell()
                }
            }
            .padding(20)
        }
        .task {
            await coach.loadCheckIns(entry.clientId)
            await data.loadContext(entry.clientId)
            photos = (try? await APIClient.shared.trainerPhotos(clientId: entry.clientId)) ?? []
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PadAvatar(name: entry.clientName, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.clientName).font(PadFont.display(30)).foregroundColor(Pad.text).lineLimit(1)
                Text(headerLine).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let p = previous {
                Button("Last check-in") { onOpen(p.id) }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            if showReplyButton {
                Button((ci.trainerResponse ?? "").isEmpty ? "Reply" : "Your reply") { onReply() }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
            }
        }
    }

    private var headerLine: String {
        var bits: [String] = []
        if let a = data.assignments.first(where: { $0.clientId == entry.clientId && $0.status.lowercased() != "ended" }), a.currentWeek > 0 {
            bits.append("Week \(a.currentWeek) of \(a.programName)")
        }
        bits.append(CheckInSchema.custom == nil ? "standard form" : "your form")
        bits.append("sent \(cal.isDateInToday(ci.date) ? ci.date.padClock : ci.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        return bits.joined(separator: " · ")
    }

    private var metricGrid: some View {
        let ms = metrics
        let cols = sideBySide ? min(6, max(ms.count, 1)) : 3
        return Group {
            if !ms.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                    ForEach(ms) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            PadLab(m.label).lineLimit(1)
                            PadNumber(value: fmt(m.now), unit: m.unit, size: 30)
                            PadDelta(text: deltaText(m), better: deltaBetter(m))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padWell(12)
                    }
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }
    private func deltaText(_ m: Metric) -> String {
        guard let p = m.prev else { return "first one" }
        let d = m.now - p
        if d == 0 { return "same" }
        return (d > 0 ? "+" : "−") + fmt(abs(d)) + (m.isWeight ? " \(StatsUnits.weightLabel)" : "")
    }
    private func deltaBetter(_ m: Metric) -> Bool? {
        guard let p = m.prev, let good = m.better, m.now != p else { return nil }
        return (m.now > p) == good
    }

    private var trendWell: some View {
        let weights: [(Date, Double)] = history.compactMap { h in
            guard let f = h.fields.first(where: { $0.cleanLabel.lowercased().contains("weight") }), let v = Double(f.value) else { return nil }
            return (h.date, StatsUnits.weight(v))
        }.filter { $0.0 >= (cal.date(byAdding: .weekOfYear, value: -8, to: ci.date) ?? ci.date) && $0.0 <= ci.date }
        let start = cal.startOfWeek(for: ci.date)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? ci.date
        let ss = data.sessions(client: RosterItem.stub(entry.clientId, entry.clientName)).filter { $0.day >= start && $0.day < end }
        let done = ss.filter { $0.isDone }
        let rpes = done.compactMap { $0.avgRPE }
        let prs = data.prsThisWeek(clientId: entry.clientId).filter { $0.date >= start && $0.date < end }
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                PadLab("Bodyweight, 8 weeks")
                if weights.count >= 2 {
                    PadSparkline(points: weights.map { $0.1 }, from: weights.first!.0, to: weights.last!.0)
                        .frame(height: 80)
                        .accessibilityLabel("Bodyweight from \(fmt(weights.first!.1)) to \(fmt(weights.last!.1)) over 8 weeks")
                } else {
                    Text("Needs two check-ins with bodyweight.").font(PadFont.ui(13)).foregroundColor(Pad.faint).frame(height: 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                PadLab("Training this week")
                Text("\(done.count) of \(ss.count.plural("session"))").font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                if let pr = prs.first { PadLab("\(pr.exercise) PR · \(StatsUnits.weightText(pr.estimatedOneRepMax, unit: false)) e1RM") }
                if !rpes.isEmpty { PadLab("Average RPE \((rpes.reduce(0, +) / Double(rpes.count)).rpeText)") }
            }
            .frame(width: 190, alignment: .leading)
        }
        .padWell()
    }

    @ViewBuilder
    private var photoSection: some View {
        let mine = photos.filter { ci.photoIds.contains($0.id) || cal.isDate($0.date, inSameDayAs: ci.date) }
        let order = ["Front", "Side", "Back"]
        let sorted = mine.sorted { (order.firstIndex(of: $0.category) ?? 99, $0.category) < (order.firstIndex(of: $1.category) ?? 99, $1.category) }
        let earlier = photos.filter { $0.date < cal.startOfDay(for: ci.date) }
        let earliestDay = earlier.map { $0.date }.min()
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Progress photos").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                    Spacer()
                    if let d = earliestDay {
                        PadSeg(options: [(id: false, label: "This week"), (id: true, label: "Beside \(d.formatted(.dateTime.month(.abbreviated).day()))")], selection: $compare)
                    }
                }
                HStack(spacing: 10) { ForEach(sorted, id: \.id) { p in photoTile(p) } }
                if compare, let d = earliestDay {
                    let old = earlier.filter { cal.isDate($0.date, inSameDayAs: d) }
                        .sorted { (order.firstIndex(of: $0.category) ?? 99) < (order.firstIndex(of: $1.category) ?? 99) }
                    HStack(spacing: 10) { ForEach(old, id: \.id) { p in photoTile(p) } }
                }
            }
        }
    }

    private func photoTile(_ p: APIPhoto) -> some View {
        PhotoFill(photo: p.toModel(), url: APIClient.shared.trainerPhotoURL(photoId: p.id))
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottom) {
                HStack {
                    Text(p.category).font(PadFont.cond(12, .bold)); Spacer()
                    Text(p.date.formatted(.dateTime.month(.abbreviated).day())).font(PadFont.cond(12))
                }
                .foregroundColor(.white).padding(10)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("\(p.category) photo, \(p.date.formatted(date: .abbreviated, time: .omitted))")
    }
}

extension RosterItem {
    /// A roster row by id and name only, for look-ups that just need those two.
    static func stub(_ id: String, _ name: String) -> RosterItem {
        RosterItem(id: id, name: name, goal: "", unreadMessages: 0, pendingCheckIns: 0, missedWorkouts: 0,
                   workoutsThisWeek: 0, daysSinceTrained: 0, recentAwards: 0, attentionScore: 0)
    }
}

/// A text-coloured line with an accent dot on the latest point, plus the two end dates.
struct PadSparkline: View {
    let points: [Double]
    let from: Date
    let to: Date
    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let mn = points.min() ?? 0, mx = points.max() ?? 1
                let rng = max(mx - mn, 0.5)
                let w = size.width, h = size.height - 6
                func pt(_ i: Int) -> CGPoint {
                    CGPoint(x: 6 + (w - 12) * CGFloat(i) / CGFloat(max(points.count - 1, 1)),
                            y: 3 + h * (1 - CGFloat((points[i] - mn) / rng)))
                }
                var grid = Path()
                for f in [0.25, 0.75] { grid.move(to: CGPoint(x: 0, y: 3 + h * f)); grid.addLine(to: CGPoint(x: w, y: 3 + h * f)) }
                ctx.stroke(grid, with: .color(Pad.line), lineWidth: 1)
                var p = Path()
                for i in points.indices { if i == 0 { p.move(to: pt(i)) } else { p.addLine(to: pt(i)) } }
                ctx.stroke(p, with: .color(Pad.text), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let last = pt(points.count - 1)
                let dot = Path(ellipseIn: CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9))
                ctx.fill(dot, with: .color(Pad.volt))
                if Pad.isLight { ctx.stroke(dot, with: .color(Pad.text), lineWidth: 1.5) }
            }
            HStack {
                PadLab(from.formatted(.dateTime.month(.abbreviated).day()), color: Pad.faint, size: 11)
                Spacer()
                PadLab(Calendar.current.isDateInToday(to) ? "Today" : to.formatted(.dateTime.month(.abbreviated).day()), color: Pad.faint, size: 11)
            }
        }
    }
}

// MARK: - Your reply

struct PadReplyPane: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var data = PadData.shared
    let entry: PadCheckInsView.Entry
    var nextName: String? = nil
    var asSheet = false
    var onSent: () -> Void

    @State private var text = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var sending = false
    @State private var failed: String?
    @State private var recording = false
    @State private var macrosOpen = false
    @FocusState private var focused: Bool

    private var cal: Calendar { Calendar.training }
    private var ci: APICheckIn { entry.checkIn }
    private var alreadyAnswered: Bool { !(ci.trainerResponse ?? "").isEmpty }
    private var macrosFilled: Bool { !(protein.isEmpty && carbs.isEmpty && fat.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(alreadyAnswered ? "Your reply" : "Reply to \(entry.clientName.firstName)").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                Spacer()
                if asSheet { PadIconButton(systemName: "xmark", label: "Close", small: true) { dismiss() } }
                else { PadLab("⌘↵ sends", color: Pad.faint) }
            }
            .padding(.horizontal, 18).frame(height: 56)
            PadRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if alreadyAnswered {
                        Text(ci.trainerResponse ?? "").font(PadFont.ui(15)).foregroundColor(Pad.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padWell()
                        PadLab("Sent \(ci.date.formatted(.dateTime.weekday(.wide)))’s check-in a reply. To say more, message them in the Inbox.")
                    } else {
                        // Review 1 (Oct 9): the box grows with the reply; saved replies sit on one line with
                        // the rest under "All"; macros fold into one row until you want to change them.
                        TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 168).focused($focused).padInput(multiline: true)
                        savedReplyRow
                        macrosRow
                        if let failed { Text(failed).font(PadFont.ui(13)).foregroundColor(Pad.orange) }
                        HStack(spacing: 8) {
                            PadIconButton(systemName: "mic.fill", label: "Send a voice note to \(entry.clientName.firstName)’s chat") { recording = true }
                            Button {
                                send()
                            } label: {
                                HStack(spacing: 8) {
                                    if sending { ProgressView().tint(Pad.onVolt) }
                                    Text(nextName.map { "Send and open \($0)’s" } ?? "Send and mark reviewed")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PadButtonStyle(kind: .primary))
                            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                    }
                    before
                }
                .padding(18)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .sheet(isPresented: $recording) {
            VoiceNoteSheet(title: "Voice note to \(entry.clientName.firstName)") { url, secs, transcript in
                let threads = try await APIClient.shared.trainerChats(clientId: entry.clientId)
                let t: APIChatThread
                if let x = threads.max(by: { $0.lastActivity < $1.lastActivity }) { t = x }
                else { t = try await APIClient.shared.trainerCreateChat(clientId: entry.clientId, topic: "Check-in", category: ChatCategory.general.rawValue) }
                try await APIClient.shared.sendVoiceNote(threadId: t.id, fileURL: url, seconds: secs, transcript: transcript, asCoach: true)
                await MainActor.run { PadToasts.shared.show("Voice note sent to \(entry.clientName.firstName)") }
            }
        }
    }

    private func use(_ r: String) { text = text.isEmpty ? r : text + " " + r; focused = true }

    private var savedReplyRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(store.savedReplies, id: \.self) { r in PadChip(text: r) { use(r) } } }
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            Menu {
                ForEach(store.savedReplies, id: \.self) { r in Button(r) { use(r) } }
            } label: {
                HStack(spacing: 4) { Text("All"); Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                    .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
            }
            .accessibilityLabel("All saved replies")
        }
        .frame(height: 36)
    }

    /// Today's targets on one line; tap to change them with this reply.
    private var macrosRow: some View {
        let today = currentMacros
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { macrosOpen.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie").font(.system(size: 15, weight: .medium)).foregroundColor(Pad.text)
                    Text("Macros").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    Text(macrosSummary(today))
                        .font(PadFont.cond(13)).foregroundColor(macrosFilled ? Pad.voltText : Pad.mute).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(macrosOpen ? "Done" : "Change").font(PadFont.cond(12)).foregroundColor(Pad.faint)
                    Image(systemName: macrosOpen ? "chevron.up" : "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(Pad.faint)
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if macrosOpen {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) { macroField("Protein", $protein); macroField("Carbs", $carbs); macroField("Fat", $fat) }
                    PadLab(macrosFilled ? "Starts tomorrow, for 14 days. Calories follow (4 · 4 · 9)." : "Leave blank to keep their targets.")
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
        .task { await loadMacros() }
    }

    @State private var currentMacros: String?
    private func macrosSummary(_ today: String?) -> String {
        guard macrosFilled else { return today ?? "keep as they are" }
        let p = protein.isEmpty ? "–" : protein, c = carbs.isEmpty ? "–" : carbs, f = fat.isEmpty ? "–" : fat
        return "New: \(p) P · \(c) C · \(f) F"
    }
    private func loadMacros() async {
        guard currentMacros == nil, let v = try? await APIClient.shared.viewAsToken(clientId: entry.clientId),
              let ds: [APIMacroDay] = try? await APIClient.shared.get("/macros", token: v.token),
              let t = ds.first(where: { cal.isDateInToday($0.date) }) ?? ds.max(by: { $0.date < $1.date }) else { return }
        currentMacros = "\(t.proteinGoal) P · \(t.carbGoal) C · \(t.fatGoal) F"
    }

    private func macroField(_ label: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PadLab(label)
            TextField("g", text: b).keyboardType(.numberPad).padInput()
        }
    }

    private var before: some View {
        let lines = beforeLines
        return VStack(alignment: .leading, spacing: 0) {
            Text("Before you reply").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text).padding(.bottom, 8)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                if i > 0 { PadRule() }
                Text(l).font(PadFont.ui(14)).foregroundColor(Pad.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 9)
            }
        }
        .padding(.top, 6)
    }

    private var beforeLines: [String] {
        var out: [String] = []
        let history = (coach.checkIns[entry.clientId] ?? []).filter { $0.status != "draft" && $0.id != ci.id && $0.date < ci.date }
        if let flagged = PadCheckInReview.flaggedLine(ci) {
            let words = PadCheckInReview.flagWords.filter { flagged.lowercased().contains($0) }
            let earlier = history.filter { h in h.fields.contains { f in Double(f.value) == nil && words.contains { f.value.lowercased().contains($0) } } }
                .sorted { $0.date > $1.date }
            if let e = earlier.first {
                out.append("Something like this came up \(earlier.count == 1 ? "once" : "\(earlier.count) times") before, last on \(e.date.formatted(.dateTime.month(.abbreviated).day())).")
            } else if !history.isEmpty {
                out.append("First time anything like this has come up in \(history.count.plural("check-in")).")
            }
        }
        // Bar speed this week on the main lifts.
        let start = cal.startOfWeek(for: ci.date)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? ci.date
        let motions = (data.motion[entry.clientId] ?? []).filter { $0.start >= start && $0.start < end && !$0.reps.isEmpty }
        for lift in ["Back Squat", "Bench Press", "Deadlift"] {
            let ms = motions.filter { $0.exerciseName == lift }
            guard ms.count >= 2 else { continue }
            let vs = ms.map { $0.meanVelocity }
            let mean = vs.reduce(0, +) / Double(vs.count)
            let grind = ms.contains { $0.grindRepCount > 0 }
            out.append("\(lift.replacingOccurrences(of: "Back ", with: "")) bar speed \(grind ? "dipped to" : "held near") \(String(format: "%.2f", grind ? (vs.min() ?? mean) : mean)) m/s across \(ms.count) sets. \(grind ? "There was a grind." : "Nothing was a grind.")")
        }
        let today = cal.startOfDay(for: Date())
        if let n = data.sessions(client: RosterItem.stub(entry.clientId, entry.clientName)).filter({ !$0.isDone && $0.day >= today }).min(by: { $0.day < $1.day }) {
            out.append("Next session is \(cal.isDateInToday(n.day) ? "today" : n.day.formatted(.dateTime.weekday(.wide))) · \(n.title).")
        }
        if out.isEmpty { out.append("Nothing stands out. No flags, and no Watch data this week.") }
        return out
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true; failed = nil
        let p = Int(protein), c = Int(carbs), f = Int(fat)
        Task {
            do {
                try await APIClient.shared.trainerRespondCheckIn(checkInId: ci.id, response: t)
                if macrosFilled, let p, let c, let f {
                    let kcal = p * 4 + c * 4 + f * 9
                    let sessions = data.sessions(client: RosterItem.stub(entry.clientId, entry.clientName))
                    for i in 1...14 {
                        let day = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: Date())) ?? Date()
                        let training = sessions.contains { cal.isDate($0.day, inSameDayAs: day) }
                        try? await APIClient.shared.trainerSetMacros(clientId: entry.clientId, day: day, training: training, kcal: kcal, protein: p, carbs: c, fat: f)
                    }
                }
                await MainActor.run {
                    sending = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSent()
                }
            } catch {
                await MainActor.run {
                    sending = false
                    failed = "Couldn’t send. Check your connection and try again."
                }
            }
        }
    }
}

/// Chips that wrap onto as many lines as they need.
struct PadFlowChips: View {
    let items: [String]
    let pick: (String) -> Void
    var body: some View {
        var x: CGFloat = 0, y: CGFloat = 0
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    PadChip(text: item) { pick(item) }
                        .padding(.trailing, 6).padding(.bottom, 6)
                        .alignmentGuide(.leading) { d in
                            if abs(x - d.width) > g.size.width { x = 0; y -= d.height }
                            let r = x
                            if i == items.count - 1 { x = 0 } else { x -= d.width }
                            return r
                        }
                        .alignmentGuide(.top) { _ in
                            let r = y
                            if i == items.count - 1 { y = 0 }
                            return r
                        }
                }
            }
        }
        .frame(height: CGFloat(max(1, (items.count + 1) / 2)) * 42)
    }
}
