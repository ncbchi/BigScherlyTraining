import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Wins (round 3, Oct 9, 2026)
//
// Everyone's PRs, awards and session milestones, newest first, each with Congratulate. Beside it:
// who is close to their next one, who has the longest run of weeks with a session, and a weekly
// round-up drafted from the week's wins that can go out as an announcement or a message to everyone.
// Synchronized folder: no target step needed.

struct PadWinItem: Identifiable {
    enum Kind { case pr, award, milestone }
    let id: String
    let kind: Kind
    let clientId: String
    let clientName: String
    let title: String
    let detail: String
    let date: Date
}

struct PadWinsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var congrats = CongratsLog.shared
    @Environment(\.padGo) private var go
    @Environment(\.padSideBySide) private var sideBySide
    @State private var feed: [PadWinItem] = []
    @State private var awards: [RosterAward] = []
    @State private var prs: [String: [PersonalRecord]] = [:]
    @State private var compose: CoachCompose?
    @State private var roundup: String?
    @State private var showAll = false

    private var cal: Calendar { Calendar.training }
    private var weekStart: Date { cal.startOfWeek(for: Date()) }

    var body: some View {
        let streaks = streakList()
        let close = closeList()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Wins", subtitle: "PRs, awards and milestones across everyone.") {
                    Button { roundup = draftRoundup() } label: { Label("Weekly round-up", systemImage: "text.bubble") }
                        .buttonStyle(PadButtonStyle(kind: .outline))
                }
                PadPageStrip(stats: strip(streaks), notes: notes(close, streaks: streaks))
                PadRule()
                if sideBySide {
                    HStack(alignment: .top, spacing: 16) {
                        feedPane.frame(maxWidth: .infinity)
                        VStack(spacing: 12) { closePane(close); streakPane(streaks); roundupPane }.frame(width: 360)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 12) { closePane(close); feedPane; streakPane(streaks); roundupPane }.padding(20)
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: data.loadedAt) { _, _ in build() }
        .sheet(item: $compose) { c in
            CoachComposeSheet(title: c.title, subtitle: c.subtitle, clientId: c.clientId, starters: c.starters, initial: c.initial) {
                if let w = c.winId { CongratsLog.shared.mark(w) }
                PadToasts.shared.show("Sent")
            }
        }
        .sheet(isPresented: Binding(get: { roundup != nil }, set: { if !$0 { roundup = nil } })) {
            PadRoundupSheet(text: roundup ?? "")
        }
    }

    // MARK: Building the feed

    private func load() async {
        if !data.hasLoaded { await data.refresh(roster: store.roster) }
        if store.isLive, let a = try? await APIClient.shared.recentAwards(days: 90) { awards = a } else { awards = store.recentAwards }
        build()
    }

    private func build() {
        var p: [String: [PersonalRecord]] = [:]
        var items: [PadWinItem] = []
        let since = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        for c in store.roster {
            let list = ProgressEngine.allPRs(workouts: data.workouts[c.id] ?? []).filter { !$0.isFirstEver }
            p[c.id] = list
            for r in list where r.date >= since {
                let detail = "\(StatsUnits.weightText(r.weight, unit: false)) × \(r.reps) · e1RM \(StatsUnits.weightText(r.estimatedOneRepMax, unit: false)), up \(StatsUnits.weightText(r.gain, unit: false))"
                items.append(PadWinItem(id: "pr|\(c.id)|\(r.id)", kind: .pr, clientId: c.id, clientName: c.name,
                                        title: "\(c.name.firstName) · \(r.exercise) PR", detail: detail, date: r.date))
            }
            // Session milestones: 10, 25, 50, then every 50.
            let done = (data.workouts[c.id] ?? []).filter { $0.completed }.sorted { $0.date < $1.date }
            for m in Self.milestones where m <= done.count {
                let w = done[m - 1]
                guard w.date >= since else { continue }
                items.append(PadWinItem(id: "ms|\(c.id)|\(m)", kind: .milestone, clientId: c.id, clientName: c.name,
                                        title: "\(c.name.firstName) · \(m) sessions", detail: "Since \(PadDay.short(done[0].date))", date: w.date))
            }
        }
        for a in awards where a.earnedAt >= since {
            items.append(PadWinItem(id: "aw|\(a.clientId)|\(a.kind)", kind: .award, clientId: a.clientId, clientName: a.clientName,
                                    title: "\(a.clientName.firstName) · \(a.title)", detail: a.blurb, date: a.earnedAt))
        }
        prs = p
        feed = items.sorted { $0.date > $1.date }
    }

    static let milestones = [10, 25, 50, 100, 150, 200, 250, 300, 400, 500]

    // MARK: Streaks and close-to

    struct Streak: Identifiable {
        let id: String
        let name: String
        let weeks: Int
        let alive: Bool          // this week still needs a session to keep it
        let ended: Date?
    }

    /// Weeks in a row with at least one session, counting back from last week (this week adds one if it has a session).
    private func streakList() -> [Streak] {
        store.roster.map { c -> Streak in
            let days = data.sessions(client: c).filter { $0.isDone }.map { cal.startOfWeek(for: $0.day) }
            let weeksWith = Set(days)
            let thisWeek = weeksWith.contains(weekStart)
            var n = thisWeek ? 1 : 0
            var w = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
            while weeksWith.contains(w) {
                n += 1
                w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w
            }
            let last = weeksWith.max()
            let ended: Date? = n == 0 ? last.flatMap { cal.date(byAdding: .day, value: 6, to: $0) } : nil
            return Streak(id: c.id, name: c.name, weeks: n, alive: n > 0 && !thisWeek, ended: ended)
        }
        .sorted { $0.weeks > $1.weeks }
    }

    struct CloseTo: Identifiable {
        let id: String
        let clientId: String
        let name: String
        let title: String
        let detail: String
    }

    private func closeList() -> [CloseTo] {
        var out: [CloseTo] = []
        let recent = cal.date(byAdding: .day, value: -21, to: Date()) ?? Date()
        for c in store.roster {
            // A lift whose latest e1RM is within 4% of their best, without being a PR.
            let ws = data.workouts[c.id] ?? []
            for lift in ["Back Squat", "Bench Press", "Deadlift", "Overhead Press", "Hip Thrust"] {
                let h = ProgressEngine.history(for: lift, workouts: ws)
                guard let last = h.last, last.date >= recent, h.count >= 3 else { continue }
                let best = h.dropLast().map { $0.estimatedOneRepMax }.max() ?? 0
                guard best > 0, last.estimatedOneRepMax < best, last.estimatedOneRepMax >= best * 0.96 else { continue }
                let gap = StatsUnits.weightText(best - last.estimatedOneRepMax)
                out.append(CloseTo(id: "lift|\(c.id)|\(lift)", clientId: c.id, name: c.name,
                                   title: "\(lift) PR", detail: "\(gap) under best e1RM"))
            }
            // Session milestones within 5.
            let done = (data.workouts[c.id] ?? []).filter { $0.completed }.count
            if let next = Self.milestones.first(where: { $0 > done }), next - done <= 5 {
                out.append(CloseTo(id: "ms|\(c.id)|\(next)", clientId: c.id, name: c.name,
                                   title: "\(next) sessions", detail: "\(next - done) to go"))
            }
        }
        // Streaks one week from a round number, still needing this week's session.
        for s in streakList() where s.alive && (s.weeks + 1) % 4 == 0 {
            out.append(CloseTo(id: "st|\(s.id)", clientId: s.id, name: s.name,
                               title: "\(s.weeks + 1)-week streak", detail: "needs a session by Sunday"))
        }
        return out
    }

    private func daysSinceWin(_ clientId: String) -> Int? {
        let last = feed.first { $0.clientId == clientId }?.date
        guard let last else { return nil }
        return PadDay.daysAgo(last)
    }

    // MARK: Strip and noticing

    private func strip(_ streaks: [Streak]) -> [PadStat] {
        let weekPRs = feed.filter { $0.kind == .pr && $0.date >= weekStart }
        let who = Set(weekPRs.map { $0.clientId }).count
        let month = cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let monthAwards = feed.filter { $0.kind == .award && $0.date >= month }
        let latest: String = monthAwards.first.map { "latest: \($0.title.replacingOccurrences(of: " · ", with: ", "))" } ?? "none yet"
        let top = streaks.first
        let quiet = store.roster.filter { c in (daysSinceWin(c.id) ?? 99) >= 21 }
        var quietSub = "everyone's had one"
        if let c = quiet.first {
            let d: String = daysSinceWin(c.id).map { " · \($0) days" } ?? " · none yet"
            quietSub = c.name.firstName + d
        }
        return [
            PadStat(label: "PRs this week", value: "\(weekPRs.count)", sub: who.plural("client"), good: !weekPRs.isEmpty),
            PadStat(label: "Awards, 30 days", value: "\(monthAwards.count)", sub: latest),
            PadStat(label: "Longest streak", value: "\(top?.weeks ?? 0)", unit: "wks", sub: top.map { $0.name.firstName } ?? "", good: (top?.weeks ?? 0) >= 4),
            PadStat(label: "No win in 3+ weeks", value: "\(quiet.count)", sub: quietSub, warn: !quiet.isEmpty),
        ]
    }

    private func notes(_ close: [CloseTo], streaks: [Streak]) -> [PadNote] {
        var out: [PadNote] = []
        if let c = close.first(where: { $0.id.hasPrefix("lift|") }) {
            let cid = c.clientId, first = c.name.firstName, title = c.title
            out.append(PadNote(icon: "bolt.fill", tint: Pad.voltText, text: "\(first) is close to a \(title):", aside: "\(c.detail). A nudge could tip it.",
                               go: "Nudge", run: {
                compose = CoachCompose(title: "Nudge \(first)", subtitle: title, clientId: cid,
                                       starters: ["You're right on the edge of a \(title). Next session, go get it.",
                                                  "That last one was close to your best. Rest up, it's coming."])
            }))
        }
        let quiet = store.roster.filter { c in (daysSinceWin(c.id) ?? 99) >= 21 }
        if let q = quiet.first {
            let days: String = daysSinceWin(q.id).map { "in \($0) days" } ?? "yet"
            let qid = q.id
            out.append(PadNote(icon: "exclamationmark.triangle.fill", tint: Pad.orange, text: "\(q.name.firstName) hasn't had a win \(days).",
                               aside: "A small target this week could break it.", go: "Open", run: { PadOpen.client(qid, .stats, go: go) }))
        }
        return out
    }

    // MARK: Panes

    private var feedPane: some View {
        let shown = showAll ? feed : Array(feed.prefix(25))
        return PadPane(title: "Everyone, newest first", aside: "PR · award · milestone") {
            if feed.isEmpty {
                PadEmptyLine(text: data.hasLoaded ? "No wins in the last 90 days yet." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { PadRule() }
                        feedRow(w)
                    }
                }
                if feed.count > 25 && !showAll {
                    Button("Show all \(feed.count)") { showAll = true }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                }
            }
        }
    }

    private func feedRow(_ w: PadWinItem) -> some View {
        let icon: String = w.kind == .pr ? "bolt.fill" : (w.kind == .award ? "trophy.fill" : "flag.checkered")
        let volt = w.kind == .pr
        let done = congrats.done.contains(w.id)
        let when: String = PadDay.daysAgo(w.date) == 0 ? "Today" : w.date.padWhen
        return HStack(alignment: .top, spacing: 12) {
            PadAvatar(name: w.clientName, size: 34)
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundColor(volt ? Pad.onVolt : Pad.text)
                .frame(width: 30, height: 30)
                .background(Circle().fill(volt ? Pad.volt : Pad.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                Text(w.detail).font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                PadLab(when, color: Pad.faint, size: 11)
            }
            Spacer(minLength: 8)
            if done {
                PadLab("Congratulated", color: Pad.faint, size: 12).padding(.top, 8)
            } else {
                Button("Congratulate") { congratulate(w) }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button { PadOpen.client(w.clientId, w.kind == .pr ? .stats : .awards, go: go) } label: { Label("Open \(w.clientName.firstName)", systemImage: "person") }
        }
    }

    private func congratulate(_ w: PadWinItem) {
        let first = w.clientName.firstName
        let what = w.title.replacingOccurrences(of: "\(first) · ", with: "")
        compose = CoachCompose(title: "Congratulate \(first)", subtitle: what, clientId: w.clientId,
                               starters: ["\(what)! That was earned. Proud of you.",
                                          "Huge, \(first). \(what). Keep it rolling.",
                                          "Saw the \(what). This is what consistency looks like."],
                               winId: w.id)
    }

    private func closePane(_ close: [CloseTo]) -> some View {
        PadPane(title: "Close to") {
            if close.isEmpty {
                PadEmptyLine(text: "Nobody's on the edge of a PR, milestone or streak right now.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(close.prefix(6).enumerated()), id: \.element.id) { i, c in
                        if i > 0 { PadRule() }
                        Button { PadOpen.client(c.clientId, .stats, go: go) } label: {
                            PadPaneRow(name: c.name, title: "\(c.name.firstName) · \(c.title)", detail: c.detail) { EmptyView() }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func streakPane(_ streaks: [Streak]) -> some View {
        let top = Array(streaks.filter { $0.weeks > 0 }.prefix(5))
        let ended = streaks.filter { $0.weeks == 0 && $0.ended != nil }.prefix(2)
        return PadPane(title: "Streaks", aside: "weeks with a session") {
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { PadRule() }
                    PadPaneRow(name: s.name, title: s.name, detail: s.alive ? "this week still to do" : "") {
                        Text("\(s.weeks)").font(PadFont.display(20)).foregroundColor(i == 0 ? Pad.voltText : Pad.text)
                    }
                }
                ForEach(Array(ended), id: \.id) { s in
                    PadRule()
                    PadPaneRow(name: s.name, ring: true, title: s.name, detail: s.ended.map { "ended \(PadDay.short($0))" } ?? "") {
                        Text("0").font(PadFont.display(20)).foregroundColor(Pad.orange)
                    }
                }
                if top.isEmpty && ended.isEmpty { PadEmptyLine(text: "No streaks yet.") }
            }
        }
    }

    private var roundupPane: some View {
        let text = draftRoundup()
        return PadPane(title: "Weekly round-up", aside: "drafted for you") {
            Text(text).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Button("Edit and send") { roundup = text }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
        }
    }

    /// "Huge week, team. 5 PRs: Priya's hip thrust, Jordan's squat… Alex hit 25 sessions."
    private func draftRoundup() -> String {
        let week = feed.filter { $0.date >= weekStart }
        let prItems = week.filter { $0.kind == .pr }
        let others = week.filter { $0.kind != .pr }
        if week.isEmpty { return "Solid week of work, team. Every session counts, even the ones that didn't feel big. Let's keep stacking them." }
        var parts: [String] = []
        if !prItems.isEmpty {
            let names = prItems.prefix(3).map { w -> String in
                let lift = w.title.components(separatedBy: " · ").last?.replacingOccurrences(of: " PR", with: "").lowercased() ?? "lift"
                return "\(w.clientName.firstName)'s \(lift)"
            }
            let more: String = prItems.count > 3 ? " and more" : ""
            parts.append("\(prItems.count.plural("PR")): \(names.joined(separator: ", "))\(more).")
        }
        for o in others.prefix(2) {
            let what = o.title.components(separatedBy: " · ").last ?? ""
            parts.append("\(o.clientName.firstName): \(what).")
        }
        return "Huge week, team. " + parts.joined(separator: " ") + " Keep it rolling."
    }
}

// MARK: - Round-up: post it to Home, or message everyone

struct PadRoundupSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    @State private var title = "This week's wins"
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Weekly round-up").font(PadFont.display(30)).foregroundColor(Pad.text)
                Spacer()
                Button("Cancel") { dismiss() }.font(PadFont.ui(15, .semibold)).foregroundColor(Pad.mute).keyboardShortcut(.cancelAction)
            }
            TextField("Title", text: $title).padInput()
            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 160).padInput(multiline: true)
            if failed { Text("Couldn't send. Check your connection and try again.").font(PadFont.ui(13)).foregroundColor(Pad.orange) }
            HStack(spacing: 8) {
                PadLab("An announcement shows on everyone's Home. A message lands in each client's latest conversation.", size: 12)
                Spacer()
                Button("Message everyone") { message() }.buttonStyle(PadButtonStyle(kind: .outline))
                    .disabled(sending || blank)
                Button { post() } label: {
                    HStack(spacing: 6) { if sending { ProgressView().tint(Pad.onVolt) }; Text("Post to Announcements") }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(sending || blank)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func post() {
        sending = true; failed = false
        let t = title.trimmingCharacters(in: .whitespaces).isEmpty ? "This week's wins" : title
        let b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await APIClient.shared.createAnnouncement(title: t, body: b)
                sending = false
                PadToasts.shared.show("Posted to everyone's Home")
                dismiss()
            } catch {
                sending = false; failed = true
            }
        }
    }

    private func message() {
        sending = true; failed = false
        let b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = store.roster.map { $0.id }
        Task {
            var bad = 0
            for id in ids { do { try await CoachMessenger.send(b, to: id) } catch { bad += 1 } }
            sending = false
            if bad == 0 { PadToasts.shared.show("Sent to \(ids.count.plural("client"))"); dismiss() } else { failed = true }
        }
    }
}
