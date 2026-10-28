import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Library ▸ Home (3.1.8, Oct 10, 2026)
//
// A workbench, not folders: each shelf card says what that shelf is doing for you, with a small
// picture of it. Beside them: what's in use with clients this week, and what to tidy (names clients
// typed that aren't in the library, a saved workout left as a copy, exercises you use with no cues).
// Synchronized folder: no target step needed.

struct PadLibraryHome: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var targets = PadTargets.shared
    @Environment(\.padLibrary) private var actions

    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    PadLab("YOUR SHELVES", color: Pad.faint, size: 11)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                        exercisesCard
                        workoutsCard
                        programsCard
                        formsCard
                        nutritionCard
                        messagesCard
                        targetsCard
                        importsCard
                    }
                    recentPane
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    inUsePane
                    tidyPane
                }
                .frame(width: 320)
            }
            .padding(18)
        }
        .task {
            await data.loadAdherence(roster: store.roster)
            if lib.resultsStamp != data.loadedAt { lib.computeResults(store: store) }
        }
    }

    // MARK: Shelf cards

    private func card<V: View>(_ s: PadLibraryShelf, num: String, sub: String, say: Text, @ViewBuilder vis: () -> V) -> some View {
        Button { lib.open(s) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: s.icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.text)
                        .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
                    Text(s.title).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(Pad.faint)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(num).font(PadFont.display(34)).foregroundColor(Pad.text).lineLimit(1)
                    Text(sub).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1).minimumScaleFactor(0.8)
                }
                say.font(PadFont.ui(13.5)).foregroundColor(Pad.mute).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                vis()
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 236, maxHeight: 236, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func b(_ t: String) -> Text { Text(t).font(PadFont.ui(13.5, .bold)).foregroundColor(Pad.text) }
    private func t(_ s: String) -> Text { Text(s) }

    private var exercisesCard: some View {
        let top: [LibExercise] = lib.exercises.filter { $0.used30 > 0 && !$0.isTyped }.sorted { $0.used30 > $1.used30 }.prefix(3).map { $0 }
        let typed = lib.typed.count
        var say: Text = top.isEmpty ? t("Nothing programmed in the last 30 days.") : t("Most used this month: ")
        for (i, x) in top.enumerated() { say = say + b(x.name) + t(i == top.count - 1 ? "." : ", ") }
        if typed > 0 { say = say + t(" \(typed.plural("typed name")) \(typed == 1 ? "isn't" : "aren't") in the library yet.") }
        return card(.exercises, num: "\(lib.exercises.filter { !$0.isTyped }.count)", sub: "\(lib.mine.count) yours", say: say) {
            HStack(spacing: 4) {
                PadTag(text: "\(lib.exercises.filter { $0.source == "standard" }.count) standard")
                PadTag(text: "\(lib.mine.count) yours")
                if typed > 0 { PadTag(text: "\(typed) typed", kind: .warn) }
            }
        }
    }

    private var workoutsCard: some View {
        let top = lib.workouts.max { $0.given < $1.given }
        let total = lib.workouts.map { $0.given }.reduce(0, +)
        let say: Text = top.map { w in w.given > 0 ? b(w.title) + t(" is your workhorse: given \(w.given) times to \(w.clientCount.plural("client")).") : t("Saved, but not given to anyone yet.") }
            ?? t("Save a client's workout to the library and it shows here.")
        let bars: [Int] = lib.workouts.map { $0.given }.sorted(by: >).prefix(8).map { $0 }
        return card(.workouts, num: "\(lib.workouts.count)", sub: "\(total) times given", say: say) {
            PadLibraryBars(values: bars, hero: 0)
        }
    }

    private var programsCard: some View {
        let running: Int = Set(data.assignments.filter { $0.status.lowercased() != "ended" && $0.endDate >= Date() }.map { $0.clientId }).count
        let say: Text
        if let best = lib.bestProgram {
            say = b(best.program.name) + t(" works best: lifts ") + b(best.text) + t(" on average for the people who ran it.")
        } else if let most = lib.programs.max(by: { $0.activeAssignments < $1.activeAssignments }), most.activeAssignments > 0 {
            say = b(most.name) + t(" has the most people on it. Results show after a couple of weeks.")
        } else {
            say = t("Build programs in Library ▸ New ▸ Program; their results show here.")
        }
        let ranked: [Int] = lib.programs.compactMap { lib.programResults[$0.id]?.avgStrength }.sorted(by: >).map { Int(max(1, $0 * 10)) }
        return card(.programs, num: "\(lib.programs.count)", sub: "\(running) on one now", say: say) {
            PadLibraryBars(values: ranked.isEmpty ? lib.programs.map { $0.activeAssignments + 1 } : ranked, hero: 0, accent: true)
        }
    }

    private var onTime: Int? {
        let facts = PadRosterFacts.all(store)
        let marks = facts.flatMap { $0.checkInWeeks.suffix(8) }.filter { $0.counts }
        guard marks.count >= 4 else { return nil }
        return Int((Double(marks.filter { $0.isSent }.count) / Double(marks.count) * 100).rounded())
    }

    private var formsCard: some View {
        let ot = onTime
        let say: Text = ot.map { b("\($0)% on time") + t(" across everyone's weekly check-ins, last 8 weeks.") } ?? t("Your default form plus forms for specific clients.")
        return card(.forms, num: "\(lib.forms.count + 1)", sub: "check-in forms", say: say) {
            HStack(spacing: 4) {
                PadTag(text: "default")
                if !lib.forms.isEmpty { PadTag(text: "\(lib.forms.count) named") }
                PadTag(text: "new-client packet", kind: .line)
            }
        }
    }

    private var nutritionCard: some View {
        let rates: [Double] = store.roster.compactMap { data.adherence[$0.id] }.filter { $0.totalExpected > 0 }.map { $0.overallRate }
        let avg: Int? = rates.isEmpty ? nil : Int((rates.reduce(0, +) / Double(rates.count) * 100).rounded())
        let say: Text = avg.map { b("\($0)% taken") + t(" on average across \(rates.count.plural("client")) on supplements, last 30 days.") } ?? t("Supplement templates you can add to anyone's protocol.")
        return card(.nutrition, num: "\(lib.templates.count)", sub: "supplement templates", say: say) {
            PadBar(fraction: Double(avg ?? 0) / 100, hero: true, height: 8)
        }
    }

    private var messagesCard: some View {
        let replies = store.savedReplies
        let top = replies.max { PadReplyUses.count($0) < PadReplyUses.count($1) }
        let n = top.map { PadReplyUses.count($0) } ?? 0
        let say: Text = (top != nil && n > 0) ? b("“\(top!)”") + t(" used \(n.plural("time")) on this iPad.") : t("Saved replies and Notes for next time starters, one tap away.")
        let bars: [Int] = replies.map { PadReplyUses.count($0) }.sorted(by: >).prefix(8).map { $0 }
        return card(.messages, num: "\(replies.count)", sub: "replies · \(PadLiveStarters.list.count) starters", say: say) {
            PadLibraryBars(values: bars.allSatisfy { $0 == 0 } ? [] : bars, hero: 0)
        }
    }

    private var targetsCard: some View {
        let all: [PadTarget] = targets.targets.values.flatMap { $0 }
        let since = Date().addingTimeInterval(-90 * 86_400)
        let earned = all.filter { ($0.earnedDate ?? .distantPast) >= since }.count
        let open = all.filter { !$0.isEarned }.count
        let never: Int = targets.templates.filter { tp in !all.contains { $0.title == tp.title && $0.isEarned } }.count
        var say: Text = t("\(open.plural("target")) being worked toward now.")
        if never > 0 && !all.isEmpty { say = say + t(" ") + b("\(never) never earned") + t(" yet.") }
        let bars: [Int] = targets.templates.map { tp in all.filter { $0.title == tp.title && $0.isEarned }.count }
        return card(.targets, num: "\(targets.templates.count)", sub: "\(earned + lib.awards.count) earned, 90 days", say: say) {
            PadLibraryBars(values: bars, hero: -1)
        }
    }

    private var importsCard: some View {
        card(.imports, num: "CSV", sub: "", say: t("Bring in exercises from a spreadsheet, or take yours out as one.")) {
            PadMenuLabel(text: "Import a file", icon: "square.and.arrow.down")
        }
    }

    // MARK: Recently changed

    private var recent: [(icon: String, title: String, sub: String, date: Date, open: () -> Void)] {
        var out: [(icon: String, title: String, sub: String, date: Date, open: () -> Void)] = []
        let since = Date().addingTimeInterval(-14 * 86_400)
        for p in lib.programs where p.updatedAt >= since {
            out.append(("calendar", p.name, "updated \(PadDay.short(p.updatedAt))", p.updatedAt, { lib.programId = p.id; lib.open(.programs) }))
        }
        for w in lib.workouts { if let c = w.createdAt, c >= since { out.append(("list.bullet", w.title, "saved \(PadDay.short(c))", c, { lib.workoutId = w.id; lib.open(.workouts) })) } }
        for f in lib.forms where f.updatedAt >= since {
            out.append(("doc.text", f.name, "edited \(PadDay.short(f.updatedAt))", f.updatedAt, { lib.formId = f.id; lib.open(.forms) }))
        }
        return out.sorted { $0.date > $1.date }.prefix(4).map { $0 }
    }

    private var recentPane: some View {
        let r = recent
        return PadPane(title: "Recently changed", aside: "last 14 days") {
            if r.isEmpty {
                PadEmptyLine(text: "Nothing changed in the last two weeks.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(r.enumerated()), id: \.offset) { _, x in
                        Button(action: x.open) {
                            HStack(spacing: 10) {
                                Image(systemName: x.icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.text)
                                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(x.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                                    Text(x.sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: In use this week

    private struct Use: Identifiable { let id: String; let icon: String; let title: String; let sub: String; let open: () -> Void }

    private var inUse: [Use] {
        var out: [Use] = []
        let now = Date()
        let week: TimeInterval = 7 * 86_400
        let active = data.assignments.filter { $0.status.lowercased() != "ended" && $0.endDate >= now && $0.startDate <= now.addingTimeInterval(week) }
        for (pid, list) in Dictionary(grouping: active, by: { $0.programId }) {
            let names = list.map { $0.clientName.firstName }.sorted().joined(separator: ", ")
            let wk = list.map { $0.currentWeek }.max() ?? 1
            out.append(Use(id: "p" + pid, icon: "calendar", title: "\(list[0].programName) · week \(wk)", sub: names, open: { lib.programId = pid; lib.open(.programs) }))
        }
        for w in lib.workouts {
            let who = w.givenTo.filter { g in
                (g.last.map { abs($0.timeIntervalSince(now)) <= week } ?? false) || (g.next.map { $0.timeIntervalSince(now) <= week && $0 >= now.addingTimeInterval(-86_400) } ?? false)
            }
            if !who.isEmpty {
                out.append(Use(id: "w" + w.id, icon: "list.bullet", title: w.title, sub: who.map { $0.name.firstName }.joined(separator: ", "), open: { lib.workoutId = w.id; lib.open(.workouts) }))
            }
        }
        for f in lib.forms where f.clientCount > 0 {
            out.append(Use(id: "f" + f.id, icon: "doc.text", title: f.name, sub: "\(f.clientCount.plural("client")) · weekly check-in", open: { lib.formId = f.id; lib.open(.forms) }))
        }
        if let close = closestTarget {
            out.append(Use(id: "t", icon: "trophy", title: close.title, sub: close.sub, open: { lib.open(.targets) }))
        }
        return out
    }

    private var closestTarget: (title: String, sub: String)? {
        var best: (Double, String, String)? = nil
        for c in store.roster {
            let open = targets.open(c.id)
            guard !open.isEmpty else { continue }
            let facts = PadInsights.facts(c, store: store)
            for tg in open {
                let p = PadTargetProgress.compute(tg, facts: facts)
                if !p.reached, best == nil || p.fraction > best!.0 {
                    best = (p.fraction, tg.title, "\(c.name.firstName) is \(p.left) away")
                }
            }
        }
        return best.map { ($0.1, $0.2) }
    }

    private var inUsePane: some View {
        let u = inUse
        return PadPane(title: "In use this week", aside: "with clients now") {
            if u.isEmpty {
                PadEmptyLine(text: lib.loaded ? "Nothing from the library is out with clients this week." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(u.prefix(6).enumerated()), id: \.element.id) { i, x in
                        if i > 0 { PadRule() }
                        Button(action: x.open) {
                            HStack(spacing: 10) {
                                Image(systemName: x.icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.text)
                                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(x.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                                    Text(x.sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: To tidy

    private var tidyPane: some View {
        let typed = lib.typed.sorted { $0.totalTimes > $1.totalTimes }
        let dups = lib.duplicateWorkouts
        let noCues = lib.usedMissingCues
        let n: Int = lib.tidyCount
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("To tidy", systemImage: "exclamationmark.triangle").font(PadFont.ui(15, .bold)).foregroundColor(n > 0 ? Pad.orange : Pad.text)
                Spacer()
                PadLab(n == 0 ? "all tidy" : "\(n)", color: Pad.faint, size: 12)
            }
            if n == 0 {
                PadEmptyLine(text: lib.loaded ? "Nothing to tidy. Every name is in the library." : "")
            }
            ForEach(typed.prefix(4)) { x in
                let m = lib.likelyMatch(x.name)
                tidyRow(icon: "dumbbell", title: "“\(x.name)”",
                        sub: "typed \(x.totalTimes.plural("time"))" + (m.map { " · looks like \($0.name)" } ?? " · not in the library"),
                        button: "Add it") { actions.sheet(.exerciseEditor(x)) }
            }
            ForEach(Array(dups.prefix(2).enumerated()), id: \.offset) { _, d in
                tidyRow(icon: "list.bullet", title: "\(d.copy.title) and \(d.of.title)", sub: "same \(d.copy.exerciseCount) exercises", button: "Open") {
                    lib.workoutId = d.copy.id; lib.open(.workouts)
                }
            }
            if !noCues.isEmpty {
                tidyRow(icon: "text.quote", title: "\(noCues.count.plural("exercise")) you use have no cues", sub: noCues.prefix(3).map { $0.name }.joined(separator: ", "), button: "Show") {
                    lib.noCuesOnly = true; lib.inUseOnly = true; lib.source = "all"; lib.open(.exercises)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func tidyRow(icon: String, title: String, sub: String, button: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.orange)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Pad.orange.opacity(0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                Text(sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(button, action: run).buttonStyle(PadButtonStyle(kind: .outline, small: true))
        }
        .padding(.vertical, 2)
    }
}

/// Small column chart at the foot of a shelf card. hero = index drawn in the accent (-1 none).
struct PadLibraryBars: View {
    let values: [Int]
    var hero: Int = 0
    var accent = false
    var body: some View {
        let m: Int = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == hero ? (accent ? Pad.volt : Pad.text) : (accent ? Color(hex: 0xB9BAB5) : Pad.text.opacity(0.35)))
                    .frame(width: accent ? 20 : 9, height: max(3, 40 * CGFloat(v) / CGFloat(m)))
            }
        }
        .frame(height: 42, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}
