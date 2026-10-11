import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Today (Oct 8, 2026)
//
// The day as a timeline (live from their Watches), what needs the coach, and this week's
// numbers. Two columns side by side; stacked with Needs you first when the sidebar overlays.
// Synchronized folder: no target step needed.

/// Where a "Needs you" action lands: the next screen opens straight onto this.
@MainActor
final class PadNav: ObservableObject {
    static let shared = PadNav()
    @Published var checkInId: String?
    @Published var inboxClientId: String?
    @Published var inboxThreadId: String?
    /// Open this client in the Clients workspace (and optionally a section of theirs).
    @Published var clientId: String?
    @Published var clientSection: PadClientSection?
}

struct PadTodayView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @Environment(\.padSideBySide) private var sideBySide
    @Environment(\.padNewWorkout) private var newWorkout
    @Environment(\.padBroadcast) private var broadcast
    @Environment(\.padGo) private var go
    @State private var compose: CoachCompose?
    @State private var noteFor: PadSession?
    @State private var tick = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var cal: Calendar { Calendar.training }
    private var todaySessions: [PadSession] {
        data.sessions(for: store.roster).filter { cal.isDateInToday($0.day) }.sorted { $0.placeMinute < $1.placeMinute }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()), subtitle: summary) {
                    Button("Message everyone") { broadcast() }.buttonStyle(PadButtonStyle(kind: .outline))
                    Button { newWorkout() } label: { Label("New workout", systemImage: "plus") }.buttonStyle(PadButtonStyle(kind: .primary))
                }
                if sideBySide {
                    HStack(alignment: .top, spacing: 18) {
                        dayPanel
                        VStack(spacing: 18) { needsPanel; weekPanel }.frame(width: 440)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28)
                } else {
                    VStack(spacing: 18) { needsPanel; dayPanel; weekPanel }
                        .padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { store.loadRoster(); await data.refresh(roster: store.roster) }
        .onReceive(clock) { tick = $0 }
        .sheet(item: $compose) { c in
            CoachComposeSheet(title: c.title, subtitle: c.subtitle, clientId: c.clientId, starters: c.starters, initial: c.initial) {
                if let w = c.winId { CongratsLog.shared.mark(w) }
                PadToasts.shared.show("Sent")
            }
        }
        .sheet(item: $noteFor) { s in
            CoachComposeSheet(title: "Note to \(s.clientName.firstName)", subtitle: "\(s.title) · \(s.currentExercise ?? "lifting now")",
                              clientId: s.clientId,
                              starters: ["Looking fast — keep that bar speed.", "Brace harder on the next set.", "Great work, finish strong."]) {
                PadToasts.shared.show("Sent to \(s.clientName.firstName)")
            }
        }
    }

    // MARK: Summary

    private static let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
    private func word(_ n: Int) -> String { n < Self.words.count ? Self.words[n] : "\(n)" }

    private var summary: String {
        if !data.hasLoaded && store.roster.isEmpty { return "Loading your day…" }
        let n = todaySessions.count
        let needs = needsRows.count
        let live = todaySessions.filter { $0.isLive }.count
        var s = "\(word(n)) session\(n == 1 ? "" : "s") today."
        if live > 0 { s += " \(word(live)) \(live == 1 ? "person is" : "people are") lifting now." }
        if needs > 0 { s += " \(word(needs)) \(needs == 1 ? "thing needs" : "things need") you." } else if n > 0 { s += " Nothing's waiting on you." }
        return s
    }

    // MARK: The day

    private struct HourRow: Identifiable {
        let id: Int           // first hour of the row
        let hours: Int        // > 1 = a collapsed stretch
        let sessions: [PadSession]
        var label: String {
            let h = id % 24
            if h == 0 { return "Midnight" }
            if h == 12 { return "Noon" }
            return h < 12 ? "\(h) am" : "\(h - 12) pm"
        }
        var gapLabel: String {
            func t(_ h: Int) -> String { h == 12 ? "noon" : (h < 12 ? "\(h) am" : "\(h - 12) pm") }
            return hours == 1 ? "\(t(id)) · nothing planned" : "\(t(id)) to \(t(id + hours)) · nothing planned"
        }
    }

    private var rows: [HourRow] {
        let ss = todaySessions
        let hoursWithSessions = Set(ss.map { $0.placeMinute / 60 })
        let nowHour = cal.component(.hour, from: tick)
        let lo = min(6, hoursWithSessions.min() ?? 6, nowHour)
        let hi = max(19, (hoursWithSessions.max() ?? 18) + 1, nowHour + 1)
        var out: [HourRow] = []
        var h = lo
        while h <= hi {
            if hoursWithSessions.contains(h) || h == nowHour {
                out.append(HourRow(id: h, hours: 1, sessions: ss.filter { $0.placeMinute / 60 == h }))
                h += 1
            } else {
                var n = 1
                while h + n <= hi && !hoursWithSessions.contains(h + n) && h + n != nowHour { n += 1 }
                if n >= 2 { out.append(HourRow(id: h, hours: n, sessions: [])) }
                else { out.append(HourRow(id: h, hours: 1, sessions: [])) }
                h += n
            }
        }
        return out
    }

    private var dayPanel: some View {
        PadPanel(title: "The day", aside: todaySessions.contains { $0.isLive } ? "Live from their Watches" : "From their logged sets") {
            if !data.hasLoaded {
                VStack(spacing: 10) { ForEach(0..<5, id: \.self) { _ in PadSkeleton(height: 60) } }
            } else if todaySessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No sessions today").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                    Text("Nobody has anything planned for today.").font(PadFont.ui(14)).foregroundColor(Pad.mute)
                    HStack(spacing: 8) {
                        Button("Open calendar") { go(.calendar) }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        Button("Plan a workout") { newWorkout() }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
                    }
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { r in hourRow(r) }
                }
            }
        }
    }

    private func hourRow(_ r: HourRow) -> some View {
        let nowHour = cal.component(.hour, from: tick)
        let isNow = r.hours == 1 && r.id == nowHour
        let minute = CGFloat(cal.component(.minute, from: tick)) / 60
        return HStack(alignment: .top, spacing: 0) {
            Text(r.hours > 1 ? "" : r.label).font(PadFont.cond(13)).foregroundColor(Pad.faint)
                .frame(width: 52, alignment: .leading).padding(.top, 3)
            ZStack(alignment: .topLeading) {
                if r.hours > 1 {
                    Text(r.gapLabel).font(PadFont.cond(13)).foregroundColor(Pad.faint).padding(.leading, 10)
                        .frame(height: 34, alignment: .center)
                } else {
                    VStack(spacing: 6) {
                        ForEach(r.sessions) { s in sessionBlock(s) }
                    }
                    .padding(.leading, 10).padding(.top, r.sessions.isEmpty ? 0 : 7).padding(.bottom, r.sessions.isEmpty ? 0 : 7)
                    .frame(minHeight: 74, alignment: .top)
                }
                if isNow {
                    nowLine.offset(y: 74 * minute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .top) { PadRule() }
    }

    private var nowLine: some View {
        HStack(spacing: 0) {
            Text(tick.padClock.replacingOccurrences(of: " am", with: "").replacingOccurrences(of: " pm", with: ""))
                .font(PadFont.cond(13, .bold)).foregroundColor(Pad.isLight ? Pad.onVolt : Pad.volt)
                .padding(.horizontal, Pad.isLight ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: 5).fill(Pad.isLight ? Pad.volt : Color.clear))
                .frame(width: 52, alignment: .leading).offset(x: -52)
            Circle().fill(Pad.isLight ? Pad.text : Pad.volt).frame(width: 10, height: 10).offset(x: -5)
            Rectangle().fill(Pad.isLight ? Pad.text : Pad.volt).frame(height: 2)
        }
        .frame(height: 10)
        .offset(y: -5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sessionBlock(_ s: PadSession) -> some View {
        let pr = data.prsThisWeek(clientId: s.clientId).first { cal.isDate($0.date, inSameDayAs: s.day) }
        Button { store.selectedClient = store.roster.first { $0.id == s.clientId } } label: {
            if s.isLive {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        PadAvatar(name: s.clientName, size: 34, volt: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.clientName) is lifting now").font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                            Text([s.currentExercise, "set \(min(s.setsLogged + 1, max(s.setsTotal, 1))) of \(s.setsTotal)", s.currentSetText].compactMap { $0 }.joined(separator: " · "))
                                .font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let id = s.currentSetId, let v = data.velocity(clientId: s.clientId, setId: id) {
                            PadNumber(value: String(format: "%.2f", v), unit: "m/s", size: 22)
                        }
                    }
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            ForEach(0..<max(s.setsTotal, 1), id: \.self) { i in
                                Capsule().fill(i < s.setsLogged ? Pad.volt : (i == s.setsLogged ? Pad.volt.opacity(Pad.isLight ? 1 : 0.45) : (Pad.isLight ? Color(hex: 0xDEDED8) : Pad.raised)))
                                    .overlay(Capsule().stroke(Color.black.opacity(Pad.isLight && i <= s.setsLogged ? 0.3 : 0), lineWidth: 1))
                                    .frame(height: 6)
                            }
                        }
                        .accessibilityLabel("Set \(s.setsLogged + 1) of \(s.setsTotal)")
                        Button("Send a note") { noteFor = s }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Pad.liveFill))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.isLight ? Pad.text : Pad.volt, lineWidth: Pad.isLight ? 2 : 1.5))
            } else {
                HStack(spacing: 12) {
                    PadAvatar(name: s.clientName, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.clientName).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        Text(subline(s)).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if s.isDone {
                        if let pr {
                            PadTag(text: "PR", kind: .volt)
                            PadNumber(value: StatsUnits.weightText(pr.estimatedOneRepMax, unit: false), unit: "e1RM", size: 22)
                        } else if let r = s.avgRPE {
                            PadTag(text: "Avg RPE \(r.rpeText)")
                        }
                    } else if s.movedFrom != nil {
                        PadTag(text: "Moved", kind: .warn)
                    } else {
                        PadTag(text: s.programLabel == nil ? "Planned" : "Program", kind: .line)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(s.isDone ? Pad.done : Pad.raised))
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(s.clientName), \(s.title), \(s.isLive ? "lifting now" : (s.isDone ? "done" : "planned"))")
    }

    private func subline(_ s: PadSession) -> String {
        var parts = [s.title]
        if s.isDone {
            if let f = s.finish { parts.append("finished \(f.padClock)") }
            parts.append("\(s.setsLogged) of \(s.setsTotal) sets")
        } else {
            if let m = s.movedFrom { parts.append("moved from \(m.formatted(.dateTime.weekday(.wide)))") }
            else if let l = s.programLabel { parts.append(l) }
            else { parts.append("\(s.setsTotal) sets") }
            if s.start == nil, let u = s.usualStartMinute {
                let t = cal.date(bySettingHour: u / 60, minute: u % 60, second: 0, of: Date()) ?? Date()
                parts.append("usually starts ~\(t.padClock)")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Needs you

    private struct NeedRow: Identifiable {
        let id: String
        let icon: String
        let iconColor: Color
        let voltIcon: Bool
        let headline: String
        let detail: String
        let action: String
        let run: () -> Void
    }

    private func flaggedLine(_ ci: APICheckIn) -> String? {
        let words = ["pain", "hurt", "injur", "tight", "sore", "ache", "tweak", "pinch"]
        return ci.fields.first { f in
            Double(f.value) == nil && words.contains { f.value.lowercased().contains($0) }
        }?.value
    }

    private var needsRows: [NeedRow] {
        var out: [NeedRow] = []
        // Check-ins waiting, oldest first.
        for q in store.checkInQueue.sorted(by: { $0.checkIn.date < $1.checkIn.date }) {
            let key = "ci|\(q.id)"
            if data.isSnoozed(key) { continue }
            var bits = ["Sent \(q.checkIn.date.padAgo)."]
            let fields = q.checkIn.fields.sorted { $0.fieldOrder < $1.fieldOrder }
            if let w = fields.first(where: { $0.cleanLabel.lowercased().contains("weight") }), let v = Double(w.value) {
                bits.append("\(StatsUnits.weightText(v)),")
            }
            if let s = fields.first(where: { $0.cleanLabel.lowercased().contains("sleep") }), Double(s.value) != nil { bits.append("sleep \(s.value)/10.") }
            if let fl = flaggedLine(q.checkIn) { bits.append("Flagged: \(fl)") }
            out.append(NeedRow(id: key, icon: "checkmark.square", iconColor: Pad.volt, voltIcon: true,
                               headline: "\(q.clientName.firstName)’s check-in is waiting",
                               detail: bits.joined(separator: " ").replacingOccurrences(of: ",.", with: "."),
                               action: "Review") {
                PadNav.shared.checkInId = q.checkIn.id
                go(.checkins)
            })
        }
        // Unread messages.
        for c in store.roster where c.unreadMessages > 0 {
            let key = "msg|\(c.id)"
            if data.isSnoozed(key) { continue }
            let t = (coach.threads[c.id] ?? []).filter { $0.unread > 0 }.max { $0.lastActivity < $1.lastActivity }
            let detail = t.map { "“\($0.preview)” · \($0.lastActivity.padWhen)" } ?? "\(c.unreadMessages.plural("unread message"))."
            out.append(NeedRow(id: key, icon: "bubble.left", iconColor: Pad.mute, voltIcon: false,
                               headline: "\(c.name.firstName) is waiting on a reply", detail: detail, action: "Reply") {
                PadNav.shared.inboxClientId = c.id
                PadNav.shared.inboxThreadId = t?.id
                go(.inbox)
            })
        }
        // Going quiet.
        for c in store.roster where c.isDrifting {
            let key = "quiet|\(c.id)"
            if data.isSnoozed(key) { continue }
            let ws = (data.workouts[c.id] ?? []).filter { $0.completed }.sorted { $0.date > $1.date }
            var detail = ws.first.map { "Last trained \($0.date.formatted(.dateTime.weekday(.wide)))." } ?? "Hasn't trained in \(c.daysSinceTrained) days."
            let usual = usualDays(ws)
            if !usual.isEmpty { detail += " Usually trains \(usual)." }
            let head = c.missedWorkouts >= 2 ? "\(c.name.firstName) has missed \(word(c.missedWorkouts).lowercased()) sessions"
                                             : "\(c.name.firstName) hasn’t trained in \(c.daysSinceTrained) days"
            out.append(NeedRow(id: key, icon: "exclamationmark.triangle", iconColor: Pad.orange, voltIcon: false,
                               headline: head, detail: detail, action: "Check in") {
                compose = CoachCompose(title: "Check in with \(c.name.firstName)", subtitle: "A friendly nudge", clientId: c.id,
                                       starters: ["Hey \(c.name.firstName)! Haven’t seen a session in a bit — everything okay?",
                                                  "Missing you in the logs! Want to adjust this week’s plan?",
                                                  "Quick check-in — how are you feeling?"])
            })
        }
        // Programs ending within two weeks with nothing after.
        let soon = cal.date(byAdding: .day, value: 14, to: Date()) ?? Date()
        for a in data.assignments where a.status.lowercased() != "ended" && a.endDate <= soon && a.endDate >= cal.startOfDay(for: Date()) {
            let later = data.assignments.contains { $0.clientId == a.clientId && $0.startDate > a.endDate }
            if later { continue }
            let key = "prog|\(a.id)"
            if data.isSnoozed(key) { continue }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: a.endDate)).day ?? 0
            out.append(NeedRow(id: key, icon: "calendar", iconColor: Pad.mute, voltIcon: false,
                               headline: "\(a.clientName.firstName)’s program ends \(days == 0 ? "today" : "in \(days.plural("day"))")",
                               detail: "\(a.programName) finishes \(a.endDate.formatted(.dateTime.month(.abbreviated).day())). Nothing is planned after it.",
                               action: "Plan next") { go(.programs) })
        }
        // Sessions clients moved this week.
        for m in data.moves where m.movedBy != "coach" {
            let key = "move|\(m.id)"
            if data.isSnoozed(key) { continue }
            out.append(NeedRow(id: key, icon: "arrow.left.arrow.right", iconColor: Pad.mute, voltIcon: false,
                               headline: "\(m.clientName.firstName) moved \(m.title)",
                               detail: "\(m.from.formatted(.dateTime.weekday(.wide))) to \(m.to.formatted(.dateTime.weekday(.wide))) · \(m.movedAt.padAgo)",
                               action: "See week") { go(.calendar) })
        }
        return out
    }

    /// "Monday and Wednesday": the two most common training weekdays over 8 weeks.
    private func usualDays(_ ws: [Workout]) -> String {
        let since = cal.date(byAdding: .weekOfYear, value: -8, to: Date()) ?? Date()
        var counts: [Int: Int] = [:]
        for w in ws where w.date >= since { counts[cal.component(.weekday, from: w.date), default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(2).map { $0.key }.sorted()
        let names = top.map { cal.weekdaySymbols[$0 - 1] }
        return names.joined(separator: " and ")
    }

    private var needsPanel: some View {
        let rows = needsRows
        return PadPanel(title: "Needs you", aside: rows.isEmpty ? nil : "\(rows.count)") {
            if !data.hasLoaded && store.roster.isEmpty {
                VStack(spacing: 10) { ForEach(0..<3, id: \.self) { _ in PadSkeleton(height: 56) } }
            } else if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All caught up").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                    Text("Nobody’s waiting on you.").font(PadFont.ui(14)).foregroundColor(Pad.mute)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { PadRule() }
                        PadSwipeRow(snoozeLabel: "Snooze until tomorrow", onSnooze: {
                            data.snooze(r.id)
                            PadToasts.shared.show("Snoozed until tomorrow", action: "Undo") { data.unsnooze(r.id) }
                        }) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: r.icon).font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(r.voltIcon ? (Pad.isLight ? Pad.onVolt : Pad.volt) : r.iconColor)
                                    .frame(width: 36, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(r.voltIcon && Pad.isLight ? Pad.volt : Pad.raised))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.headline).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
                                    Text(r.detail).font(PadFont.ui(14)).foregroundColor(Pad.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Button(r.action, action: r.run).buttonStyle(PadButtonStyle(kind: .outline, small: true))
                            }
                            .padding(.vertical, 14)
                            .background(Pad.surface)
                        }
                        .contextMenu {
                            Button { data.snooze(r.id); PadToasts.shared.show("Snoozed until tomorrow", action: "Undo") { data.unsnooze(r.id) } } label: {
                                Label("Snooze until tomorrow", systemImage: "clock")
                            }
                        }
                    }
                }
                .padding(.vertical, -14)
            }
        }
    }

    // MARK: This week

    private var weekPanel: some View {
        let start = cal.startOfWeek(for: Date())
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? Date()
        let week = data.sessions(for: store.roster).filter { $0.day >= start && $0.day < end }
        let done = week.filter { $0.isDone }.count
        let missed = week.filter { $0.isMissed }
        let cis = store.roster.flatMap { c in (coach.checkIns[c.id] ?? []).filter { $0.status != "draft" && $0.date >= start } }
        let answered = cis.filter { !($0.trainerResponse ?? "").isEmpty || $0.status == "reviewed" }.count
        let prs = store.roster.flatMap { c in data.prsThisWeek(clientId: c.id).map { (c.name.firstName, $0) } }
        var prNames: [String] = []
        for c in store.roster {
            let n = prs.filter { $0.0 == c.name.firstName }.count
            if n > 0 { prNames.append(n > 1 ? "\(c.name.firstName) \(n)" : c.name.firstName) }
        }
        var missedNames: [String] = []
        for c in store.roster {
            let n = missed.filter { $0.clientId == c.id }.count
            if n > 0 { missedNames.append(n > 1 ? "\(c.name.firstName) \(n)" : c.name.firstName) }
        }
        let cols = sideBySide ? 2 : 4
        return PadPanel(title: "This week", aside: "Mon to today") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
                PadKPI(label: "Sessions done", value: "\(done)", unit: "of \(week.count)") { PadBar(fraction: week.isEmpty ? 0 : Double(done) / Double(week.count)) }
                PadKPI(label: "Check-ins answered", value: "\(answered)", unit: "of \(cis.count)") { PadBar(fraction: cis.isEmpty ? 0 : Double(answered) / Double(cis.count), hero: false) }
                PadKPI(label: "Missed sessions", value: "\(missed.count)") { PadLab(missedNames.isEmpty ? "None" : missedNames.joined(separator: " · ")).lineLimit(1) }
                PadKPI(label: "PRs", value: "\(prs.count)") { PadDelta(text: prNames.isEmpty ? "None yet" : prNames.joined(separator: " · "), better: prs.isEmpty ? nil : true).lineLimit(1) }
            }
        }
    }
}

/// A row that slides left to reveal one action (Snooze). Also in the context menu for keyboards.
struct PadSwipeRow<Content: View>: View {
    let snoozeLabel: String
    let onSnooze: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var dx: CGFloat = 0
    @State private var open = false
    private let reveal: CGFloat = 170

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { dx = 0; open = false }
                onSnooze()
            } label: {
                Label(snoozeLabel, systemImage: "clock").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    .frame(width: reveal).frame(maxHeight: .infinity)
                    .background(Pad.raised)
            }
            .buttonStyle(.plain)
            .opacity(dx < -10 ? 1 : 0)
            content()
                .offset(x: dx)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            let base: CGFloat = open ? -reveal : 0
                            dx = min(0, max(-reveal, base + v.translation.width))
                        }
                        .onEnded { v in
                            withAnimation(.easeOut(duration: 0.18)) {
                                open = dx < -reveal / 2
                                dx = open ? -reveal : 0
                            }
                        }
                )
        }
        .clipped()
    }
}
