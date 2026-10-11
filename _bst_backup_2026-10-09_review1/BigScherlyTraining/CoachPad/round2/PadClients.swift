import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Clients, a Finder-style column view (review 1, Oct 9, 2026)
//
// Level 1, the roster: every client with status, 8 weeks of sessions, check-in state, lift trend
// and renewal, sorted by who needs you most. Your business (choose the panes) sits on the right.
// Level 2, a client: the roster shrinks to the left, the client's sections (Overview first, then
// A to Z) sit next to it, then their Overview and what's worth knowing about them. The sidebar
// closes on its own here and comes back with the roster.
// Level 3, a section: the roster and the right pane slide away; the sections stay as icons.
// Weekly review steps through everyone in "needs you most" order without leaving the section.
// Synchronized folder: no target step needed.

struct PadClientsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var renewals = PadRenewals.shared
    @ObservedObject private var nav = PadNav.shared
    @Environment(\.padSidebarAuto) private var sidebarAuto
    @Environment(\.padBroadcast) private var broadcast

    @State private var selectedId: String?
    @State private var section: PadClientSection = .overview
    @State private var reviewing = false
    @State private var reviewIds: [String] = []
    @State private var reviewed: Set<String> = PadClientsView.loadReviewed()
    @State private var newWorkoutFor: RosterItem?
    @State private var awards: [String: [APIAward]] = [:]

    private var facts: [PadClientFacts] { store.roster.map { PadInsights.facts($0, store: store) } }
    /// Worked out once per render and passed down (each client's facts scan their whole history).
    private static func needsOrder(_ all: [PadClientFacts]) -> [PadClientFacts] {
        all.sorted { ($0.paused ? 1 : 0, -$0.needs, $0.name) < ($1.paused ? 1 : 0, -$1.needs, $1.name) }
    }
    private var level: Int { selectedId == nil ? 1 : (section == .overview ? 2 : 3) }

    var body: some View {
        let all = facts
        let order = Self.needsOrder(all)
        let cur = selectedId.flatMap { id in all.first { $0.id == id } }
        VStack(spacing: 0) {
            crumbBar(cur, order: order)
            header(cur, all: all)
            PadRule()
            GeometryReader { g in
                columns(all: all, order: order, cur: cur, width: g.size.width)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if reviewing, let cur { reviewBar(cur).padding(.bottom, 22).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .background(keys(order))
        .sheet(item: $newWorkoutFor) { c in
            WorkoutBuilderView(clientId: c.id, clientName: c.name) { Task { await data.refresh(roster: store.roster) } }
        }
        .task {
            if store.roster.isEmpty { store.loadRoster() }
            await renewals.load(store: store)
            await coach.loadAllThreads(store.roster)
            await data.loadAdherence(roster: store.roster)
        }
        .onAppear { consumeNav() }
        .onChange(of: nav.clientId) { _, _ in consumeNav() }
        .onChange(of: store.roster.map { $0.id }) { _, _ in
            consumeNav()
            Task { await coach.loadAllThreads(store.roster); await data.loadAdherence(roster: store.roster) }
        }
    }

    // MARK: Navigation

    private func consumeNav() {
        guard let id = nav.clientId, store.roster.contains(where: { $0.id == id }) else { return }
        let s = nav.clientSection ?? .overview
        nav.clientId = nil; nav.clientSection = nil
        open(id, section: s)
    }

    private func open(_ id: String, section s: PadClientSection? = nil) {
        sidebarAuto.hide()
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedId = id
            if let s { section = s }
        }
        Task {
            await data.loadContext(id)
            await coach.loadThreads(id)
            await coach.loadCheckIns(id)
            if awards[id] == nil, let a = try? await APIClient.shared.trainerAwards(clientId: id) { awards[id] = a }
        }
    }

    private func backToRoster() {
        withAnimation(.easeInOut(duration: 0.25)) { selectedId = nil; section = .overview; reviewing = false }
        sidebarAuto.restore()
    }

    private func step(_ d: Int, in list: [PadClientFacts]) {   // list is already in needs-you order
        let ids = reviewing ? reviewIds : list.filter { !$0.paused }.map { $0.id }
        guard let cur = selectedId, let i = ids.firstIndex(of: cur) else { return }
        let j = i + d
        guard j >= 0, j < ids.count else { return }
        open(ids[j])
    }

    private func keys(_ order: [PadClientFacts]) -> some View {
        Group {
            Button("Back") { if level == 3 { withAnimation { section = .overview } } else if level == 2 { backToRoster() } }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Previous client") { step(-1, in: order) }.keyboardShortcut("[", modifiers: .command)
            Button("Next client") { step(1, in: order) }.keyboardShortcut("]", modifiers: .command)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    // MARK: Crumbs and header

    private func crumbBar(_ cur: PadClientFacts?, order: [PadClientFacts]) -> some View {
        HStack(spacing: 10) {
            PadSidebarButton()
            HStack(spacing: 8) {
                if let cur {
                    crumbLink("Clients") { backToRoster() }
                    Text("›").foregroundColor(Pad.faint)
                    if level == 3 {
                        crumbLink(cur.name) { withAnimation(.easeInOut(duration: 0.25)) { section = .overview } }
                        Text("›").foregroundColor(Pad.faint)
                        Text(section.title).foregroundColor(Pad.text)
                    } else {
                        Text(cur.name).foregroundColor(Pad.text)
                    }
                } else {
                    Text("Clients").foregroundColor(Pad.text)
                }
            }
            .font(PadFont.ui(14, .semibold))
            .lineLimit(1)
            Spacer(minLength: 8)
            if let cur {
                if !reviewing {
                    Button { startReview() } label: { Label("Start weekly review", systemImage: "checklist") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                clientSwitch(cur, order: order)
            } else {
                HStack(spacing: 14) { keyHint("⌘]", "next client"); keyHint("⌘[", "previous"); keyHint("esc", "back") }
            }
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private func crumbLink(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(t, action: action).buttonStyle(.plain).foregroundColor(Pad.mute).hoverEffect(.highlight)
    }

    private func keyHint(_ k: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(PadFont.cond(11)).foregroundColor(Pad.mute).padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Pad.line2, lineWidth: 1))
            Text(what).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
    }

    private func clientSwitch(_ cur: PadClientFacts, order: [PadClientFacts]) -> some View {
        let ids = reviewing ? reviewIds : order.filter { !$0.paused }.map { $0.id }
        let i = ids.firstIndex(of: cur.id)
        let prev = i.flatMap { $0 > 0 ? ids[$0 - 1] : nil }.flatMap { id in store.roster.first { $0.id == id } }
        let next = i.flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }.flatMap { id in store.roster.first { $0.id == id } }
        let tail = level == 3 ? "’s \(section.title.lowercased())" : ""
        return HStack(spacing: 0) {
            Button { if let p = prev { open(p.id) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    if let p = prev { Text(p.name.firstName).font(PadFont.ui(14, .semibold)) }
                }
                .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(prev == nil).opacity(prev == nil ? 0.35 : 1)
            .accessibilityLabel(prev.map { "Previous client, \($0.name)" } ?? "No previous client")
            Rectangle().fill(Pad.line2).frame(width: 1, height: 44)
            Button { if let n = next { open(n.id) } } label: {
                HStack(spacing: 6) {
                    Text(next.map { $0.name.firstName + tail } ?? "Last one").font(PadFont.ui(14, .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(next == nil).opacity(next == nil ? 0.35 : 1)
            .accessibilityLabel(next.map { "Next client, \($0.name)" } ?? "No next client")
        }
        .foregroundColor(Pad.text)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private func header(_ cur: PadClientFacts?, all: [PadClientFacts]) -> some View {
        if let cur {
            HStack(alignment: .center, spacing: 14) {
                PadClientAvatar(facts: cur, size: level == 3 ? 44 : 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(cur.name).font(PadFont.display(level == 3 ? 40 : 46)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    if level == 2 { Text(clientLine(cur)).font(PadFont.ui(15)).foregroundColor(Pad.mute).lineLimit(1) }
                }
                Spacer(minLength: 12)
                Button { withAnimation(.easeInOut(duration: 0.25)) { section = .chat } } label: { Label("Message", systemImage: "bubble.left") }
                    .buttonStyle(PadButtonStyle(kind: .outline))
                Button { newWorkoutFor = cur.client } label: { Label("New workout", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 24).padding(.bottom, 14)
        } else {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clients").font(PadFont.display(46)).foregroundColor(Pad.text)
                    Text(rosterLine(all)).font(PadFont.ui(15)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Message everyone") { broadcast() }.buttonStyle(PadButtonStyle(kind: .outline))
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private func clientLine(_ f: PadClientFacts) -> String {
        var bits: [String] = []
        if let a = f.assignment { bits.append("\(a.programName), week \(a.currentWeek) of \(a.totalWeeks)") }
        else if !f.client.goal.isEmpty { bits.append(f.client.goal) }
        if let s = f.firstSeen { bits.append("coached since \(s.formatted(.dateTime.month(.wide)))") }
        if let r = f.renewsOn { bits.append("renews \(r.formatted(.dateTime.month(.abbreviated).day()))") }
        return bits.joined(separator: " · ")
    }

    private func rosterLine(_ all: [PadClientFacts]) -> String {
        let active = all.filter { !$0.paused }.count
        let paused = all.count - active
        let need = all.filter { $0.needs >= 40 }.count
        let risky = all.filter { $0.risk == .high }.sorted { $0.score > $1.score }
        var s = "\(active) active" + (paused > 0 ? ", \(paused) paused." : ".")
        if need > 0 { s += " \(need == 1 ? "One needs" : "\(need) need") you" + (risky.isEmpty ? "." : ",") }
        if let r = risky.first { s += risky.count == 1 ? " and \(r.first) is slipping." : " and \(risky.count) are slipping." }
        return s
    }

    // MARK: Columns

    @ViewBuilder
    private func columns(all: [PadClientFacts], order: [PadClientFacts], cur: PadClientFacts?, width: CGFloat) -> some View {
        if let cur {
            if level == 2 {
                let showRoster = width >= 1200
                let showRight = width >= 950
                HStack(spacing: 0) {
                    if showRoster {
                        PadCompactRoster(facts: order, selectedId: cur.id, reviewed: reviewing ? reviewed : []) { open($0) }
                            .frame(width: 272)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        vline
                    } else {
                        PadClientAvatarColumn(facts: order, selectedId: cur.id, reviewed: reviewing ? reviewed : []) { open($0) }
                            .frame(width: 64)
                        vline
                    }
                    PadSectionList(facts: cur, awards: awards[cur.id]?.count, selection: sectionBinding)
                        .frame(width: 232)
                    vline
                    PadClientOverview(facts: cur, awards: awards[cur.id] ?? [], go: go, extra: showRight ? nil : AnyView(PadClientAbout(facts: cur, go: go)))
                        .frame(maxWidth: .infinity)
                    if showRight {
                        vline
                        PadClientAbout(facts: cur, go: go)
                            .frame(width: 304)
                            .background(Pad.page)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                HStack(spacing: 0) {
                    // Clients as avatars, then this client's sections as icons (review 1, Oct 9).
                    PadClientAvatarColumn(facts: order, selectedId: cur.id, reviewed: reviewing ? reviewed : []) { open($0) }
                        .frame(width: 64)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    vline
                    PadSectionIcons(facts: cur, selection: sectionBinding).frame(width: 72)
                    vline
                    sectionContent(cur).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.bottom, reviewing ? 92 : 0)
            }
        } else {
            HStack(spacing: 0) {
                PadRoster(facts: all, open: { open($0) }, newWorkout: { newWorkoutFor = $0 })
                    .frame(width: width >= 900 ? width * 0.75 : width)
                if width >= 900 {
                    vline
                    PadBusinessPane(facts: all)
                        .frame(maxWidth: .infinity)
                        .background(Pad.page)
                }
            }
        }
    }

    private var vline: some View { Rectangle().fill(Pad.line).frame(width: 1) }

    private var sectionBinding: Binding<PadClientSection> {
        Binding(get: { section }, set: { s in withAnimation(.easeInOut(duration: 0.25)) { section = s } })
    }
    private var go: (PadClientSection) -> Void { { s in withAnimation(.easeInOut(duration: 0.25)) { section = s } } }

    @ViewBuilder
    private func sectionContent(_ f: PadClientFacts) -> some View {
        let c = f.client
        switch section {
        case .overview: EmptyView()
        case .workouts: PadClientWorkouts(facts: f).id(c.id)
        case .checkins: PadClientCheckIns(facts: f).id(c.id)
        case .macros: PadClientMacros(client: c).id(c.id)
        case .stats: PadClientStats(facts: f).id(c.id)
        case .awards: PadClientLegacy { TrainerAwardsView(clientId: c.id, clientName: c.name) }.id(c.id)
        case .chat: PadClientLegacy { CoachClientThreads(client: c) }.id(c.id)
        case .notes: PadClientLegacy { ClientNotebookView(clientId: c.id) }.id(c.id)
        case .photos: PadClientLegacy { TrainerPhotosView(clientId: c.id) }.id(c.id)
        case .program:
            PadClientLegacy {
                ScrollView { ClientProgramCard(clientId: c.id, clientName: c.name) { Task { await data.refresh(roster: store.roster) } }.padding(20) }
            }.id(c.id)
        case .supplements: PadClientLegacy { CoachClientSupplements(clientId: c.id, clientName: c.name) }.id(c.id)
        }
    }

    // MARK: Weekly review

    private static func weekKey() -> String {
        "bst_pad_reviewed_" + String(Int(Calendar.training.startOfWeek(for: Date()).timeIntervalSince1970))
    }
    private static func loadReviewed() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: weekKey()) ?? []) }

    private func startReview() {
        let ids = Self.needsOrder(facts).filter { !$0.paused }.map { $0.id }
        guard !ids.isEmpty else { return }
        reviewIds = ids
        withAnimation(.easeOut(duration: 0.2)) { reviewing = true }
        if let cur = selectedId, ids.contains(cur) { return }
        open(ids[0])
    }

    private func markReviewedAndNext(_ cur: PadClientFacts) {
        reviewed.insert(cur.id)
        UserDefaults.standard.set(Array(reviewed), forKey: Self.weekKey())
        guard let i = reviewIds.firstIndex(of: cur.id) else { return }
        if i + 1 < reviewIds.count { open(reviewIds[i + 1]) }
        else {
            withAnimation(.easeOut(duration: 0.2)) { reviewing = false }
            PadToasts.shared.show("Weekly review done · \(reviewIds.count.plural("client"))")
        }
    }

    private func reviewBar(_ cur: PadClientFacts) -> some View {
        let i = reviewIds.firstIndex(of: cur.id) ?? 0
        let nextId: String? = i + 1 < reviewIds.count ? reviewIds[i + 1] : nil
        let next = nextId.flatMap { id in store.roster.first(where: { $0.id == id }) }
        return HStack(spacing: 12) {
            Text("Weekly review").font(PadFont.ui(14, .bold))
            Text("\(cur.first) · \(i + 1) of \(reviewIds.count)").font(PadFont.ui(14, .semibold))
            HStack(spacing: 4) {
                ForEach(0..<min(reviewIds.count, 14), id: \.self) { k in
                    RoundedRectangle(cornerRadius: 3).fill(k <= i ? Pad.ink : Pad.ink.opacity(0.18)).frame(width: 16, height: 5)
                }
            }
            .accessibilityHidden(true)
            Button("Stop") { withAnimation(.easeOut(duration: 0.2)) { reviewing = false } }
                .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.ink).padding(.horizontal, 10).frame(height: 40)
            Button { markReviewedAndNext(cur) } label: {
                HStack(spacing: 6) {
                    Text(next.map { "Done, next: \($0.name.firstName)" } ?? "Done, finish")
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.chalk)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(Pad.ink))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .foregroundColor(Pad.ink)
        .padding(.leading, 18).padding(.trailing, 8).frame(height: 56)
        .background(Capsule().fill(Pad.chalk))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
    }
}

// MARK: - Pieces shared by the levels

/// Avatar with a ring when they're at risk.
struct PadClientAvatar: View {
    let facts: PadClientFacts
    var size: CGFloat = 64
    var body: some View {
        // The open client, filled with the coach's accent colour.
        PadAvatar(name: facts.name, size: size, volt: true)
            .overlay(Circle().stroke(facts.risk == .high ? Pad.orange : Color.clear, lineWidth: 2).padding(-4))
    }
}

/// Eight small bars, one per week; this week in volt (orange if it's zero).
struct PadWeekBars: View {
    let weeks: [Int]
    var height: CGFloat = 18
    var body: some View {
        let mx = max(weeks.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { i, n in
                let last = i == weeks.count - 1
                RoundedRectangle(cornerRadius: 2)
                    .fill(last ? (n == 0 ? Pad.orange : Pad.volt) : Pad.mute.opacity(0.7))
                    .frame(width: 6, height: n == 0 ? (last ? 3 : 0) : max(4, height * CGFloat(n) / CGFloat(mx)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityLabel("Sessions per week, last 8 weeks: \(weeks.map(String.init).joined(separator: ", "))")
    }
}

/// A card in the insight panes.
struct PadInsightCard<Content: View>: View {
    let title: String
    var aside: String? = nil
    var asideColor: Color = Pad.faint
    var dot: Color? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
                Spacer(minLength: 4)
                if let aside { Text(aside).font(PadFont.cond(12)).foregroundColor(asideColor) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }
}

/// One line in a card's list: avatar, name, a note on the right.
struct PadInsightRow: View {
    let name: String
    let note: String
    var noteColor: Color = Pad.mute
    var action: (() -> Void)? = nil
    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                PadAvatar(name: name, size: 26)
                Text(name).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(note).font(PadFont.cond(12)).foregroundColor(noteColor).lineLimit(1)
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Level 1: the roster

struct PadRoster: View {
    let facts: [PadClientFacts]
    let open: (String) -> Void
    let newWorkout: (RosterItem) -> Void
    @EnvironmentObject var store: AppStore

    enum Sort: String, CaseIterable { case needs = "Needs you most", name = "Name", lastTrained = "Last trained", renews = "Renews soonest" }
    enum Filter: String { case all, needs, risk, new }
    @AppStorage("bst_pad_roster_sort") private var sortRaw = Sort.needs.rawValue
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var renewFor: PadClientFacts?

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .needs }

    private var shown: [PadClientFacts] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = facts.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.client.goal.localizedCaseInsensitiveContains(q) }
        switch filter {
        case .all: break
        case .needs: list = list.filter { $0.needs >= 40 }
        case .risk: list = list.filter { $0.risk == .high }
        case .new: list = list.filter { $0.isNew }
        }
        switch sort {
        case .needs: list.sort { (-$0.needs, $0.name) < (-$1.needs, $1.name) }
        case .name: list.sort { $0.name < $1.name }
        case .lastTrained: list.sort { ($0.daysSince ?? 9999) > ($1.daysSince ?? 9999) }
        case .renews: list.sort { ($0.renewDays ?? 99999) < ($1.renewDays ?? 99999) }
        }
        return list
    }

    var body: some View {
        let list = shown
        let live = Set(facts.filter { f in PadData.shared.sessions(client: f.client).contains { $0.isLive } }.map { $0.id })
        let active = list.filter { !$0.paused }
        let paused = list.filter { $0.paused }
        VStack(spacing: 0) {
            toolbar
            headerRow
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(active) { f in row(f, live: live.contains(f.id)) }
                    if !paused.isEmpty {
                        Text("Paused · \(paused.count)").font(PadFont.cond(13)).foregroundColor(Pad.faint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        ForEach(paused) { f in row(f, live: false).opacity(0.6) }
                    }
                    if list.isEmpty {
                        Text(store.rosterLoading ? "" : (query.isEmpty ? "No clients here." : "Nobody matches “\(query)”."))
                            .font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(24)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .popover(item: $renewFor) { f in PadRenewEditor(facts: f) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundColor(Pad.faint)
                TextField("Search clients", text: $query).font(PadFont.ui(15)).foregroundColor(Pad.text).autocorrectionDisabled()
            }
            .padding(.horizontal, 12).frame(maxWidth: 300, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 11).fill(Pad.well))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pad.line2, lineWidth: 1))
            chip("All \(facts.count)", .all)
            chip("Needs you \(facts.filter { $0.needs >= 40 }.count)", .needs)
            let atRisk = facts.filter { $0.risk == .high }.count
            if atRisk > 0 { chip("At risk \(atRisk)", .risk) }
            if facts.contains(where: { $0.isNew }) { chip("New \(facts.filter { $0.isNew }.count)", .new) }
            Spacer(minLength: 8)
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(Sort.allCases, id: \.rawValue) { s in Text(s.rawValue).tag(s.rawValue) }
                }
            } label: {
                Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    .padding(.horizontal, 13).frame(minHeight: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func chip(_ t: String, _ f: Filter) -> some View {
        PadChip(text: t, on: filter == f) { filter = filter == f ? .all : f }
    }

    // Columns: client | status | sessions | check-in | lifts | renews | chevron
    private static let w: [CGFloat] = [128, 112, 100, 108, 64, 16]

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Client").frame(maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: Self.w[0], alignment: .leading)
            Text("Sessions, 8 wks").frame(width: Self.w[1], alignment: .leading)
            Text("Check-in").frame(width: Self.w[2], alignment: .leading)
            Text("Lifts, 4 wks").frame(width: Self.w[3], alignment: .leading)
            Text("Renews").frame(width: Self.w[4], alignment: .leading)
            Color.clear.frame(width: Self.w[5], height: 1)
        }
        .font(PadFont.cond(13)).foregroundColor(Pad.faint).lineLimit(1)
        .padding(.horizontal, 20).padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Pad.line2).frame(height: 1) }
    }

    private func row(_ f: PadClientFacts, live: Bool) -> some View {
        let st = f.status
        return Button { open(f.id) } label: {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    PadAvatar(name: f.name, size: 34, dot: f.risk == .high ? Pad.orange : (live ? Pad.volt : nil))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        Text(subLine(f)).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                cell(top: AnyView(HStack(spacing: 6) { Circle().fill(st.color).frame(width: 8, height: 8); Text(st.text).foregroundColor(f.risk == .high ? Pad.orange : Pad.text) }
                                    .font(PadFont.cond(13))), sub: st.sub, w: Self.w[0])
                cell(top: AnyView(PadWeekBars(weeks: f.weekly)), sub: sessionsSub(f), w: Self.w[1])
                checkInCell(f).frame(width: Self.w[2], alignment: .leading)
                liftCell(f).frame(width: Self.w[3], alignment: .leading)
                renewCell(f).frame(width: Self.w[4], alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.faint).frame(width: Self.w[5])
            }
            .padding(.horizontal, 20).frame(minHeight: 78)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu {
            Button { open(f.id) } label: { Label("Open \(f.first)", systemImage: "person") }
            Button { newWorkout(f.client) } label: { Label("New workout for \(f.first)", systemImage: "plus") }
            Button { renewFor = f } label: { Label(f.renewsOn == nil ? "Set renewal date" : "Change renewal date", systemImage: "calendar") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(f.name), \(st.text), \(st.sub)")
    }

    private func subLine(_ f: PadClientFacts) -> String {
        if let a = f.assignment { return "\(a.programName) · week \(a.currentWeek) of \(a.totalWeeks)" }
        return f.client.goal.isEmpty ? f.client.headline : f.client.goal
    }

    private func sessionsSub(_ f: PadClientFacts) -> String {
        if f.paused { return "paused" }
        let usual = Int(f.usualPerWeek.rounded())
        if f.plannedThisWeek > 0 { return "\(f.doneThisWeek) of \(f.plannedThisWeek) this week" }
        return "\(f.doneThisWeek) this week" + (usual > 0 ? " · usual \(usual)" : "")
    }

    private func cell(top: AnyView, sub: String, w: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            top
            Text(sub).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
        }
        .frame(width: w, alignment: .leading)
    }

    private func two(_ a: String, _ ac: Color, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(a).font(PadFont.ui(14)).foregroundColor(ac).lineLimit(1)
            Text(b).font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
        }
    }

    @ViewBuilder
    private func checkInCell(_ f: PadClientFacts) -> some View {
        if let w = f.waiting {
            two("Waiting \(w.date.padShortAgo)", Pad.text, "sent \(w.date.padWhen)")
        } else if f.checkInLateDays >= 1 {
            two("Late \(f.checkInLateDays.plural("day"))", Pad.orange, f.lastCheckIn.map { "last \($0.date.formatted(.dateTime.month(.abbreviated).day()))" } ?? "")
        } else if let l = f.lastCheckIn {
            two("\(l.date.formatted(.dateTime.weekday(.wide))) ✓", Pad.text, (l.trainerResponse ?? "").isEmpty ? "seen" : "replied")
        } else {
            two("None yet", Pad.mute, "")
        }
    }

    @ViewBuilder
    private func liftCell(_ f: PadClientFacts) -> some View {
        if let l = f.lift {
            if l.isFlat {
                two("→ Flat", Pad.text, "\(l.short) \(StatsUnits.weightText(l.current, unit: false))")
            } else if let c = l.change {
                let top = "\(c > 0 ? "↑" : "↓") \(l.short) \(c > 0 ? "+" : "−")\(StatsUnits.weightText(abs(c), unit: false))"
                two(top, c > 0 ? Pad.voltText : Pad.orange, "e1RM \(StatsUnits.weightText(l.current, unit: false))")
            } else {
                two(l.short, Pad.text, "e1RM \(StatsUnits.weightText(l.current, unit: false))")
            }
        } else {
            two("—", Pad.faint, "")
        }
    }

    @ViewBuilder
    private func renewCell(_ f: PadClientFacts) -> some View {
        Button { renewFor = f } label: {
            if let r = f.renewsOn, let d = f.renewDays {
                two(r.formatted(.dateTime.month(.abbreviated).day()), d <= 30 && f.risk == .high ? Pad.orange : Pad.text, d < 0 ? "passed" : d.plural("day"))
            } else {
                two("Set", Pad.faint, "")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.renewsOn == nil ? "Set renewal date" : "Renews \(f.renewsOn!.formatted(date: .abbreviated, time: .omitted))")
    }
}

extension Date {
    /// "2 h", "3 d" — short, for table cells.
    var padShortAgo: String {
        let s = Date().timeIntervalSince(self)
        if s < 3600 { return "\(max(1, Int(s / 60))) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86_400)) d"
    }
}

/// The "renews on" date: pick, clear, saved to the server with the coach's settings.
struct PadRenewEditor: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(facts.first) renews on").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            DatePicker("Renews on", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().tint(Pad.voltText)
            HStack {
                if facts.renewsOn != nil {
                    Button("Clear") { PadRenewals.shared.set(nil, for: facts.id, store: store); dismiss() }
                        .buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                }
                Spacer()
                Button("Save") { PadRenewals.shared.set(date, for: facts.id, store: store); dismiss() }
                    .buttonStyle(PadButtonStyle(kind: .primary, small: true))
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(Pad.surface)
        .onAppear { date = facts.renewsOn ?? (Calendar.training.date(byAdding: .month, value: 1, to: Date()) ?? Date()) }
    }
}

// MARK: - Level 1: your business

struct PadBusinessPane: View {
    let facts: [PadClientFacts]
    @EnvironmentObject var store: AppStore
    @ObservedObject private var prefs = PadBizPrefs.shared
    @ObservedObject private var coach = CoachData.shared
    @ObservedObject private var data = PadData.shared
    @State private var choosing = false

    private var active: [PadClientFacts] { facts.filter { !$0.paused } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your business").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                Button { choosing = true } label: { Label("Panes", systemImage: "slider.horizontal.3") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    .popover(isPresented: $choosing, arrowEdge: .top) { PadBizPanesMenu() }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(prefs.shown) { p in pane(p) }
                    if prefs.shown.isEmpty {
                        Text("No panes chosen. Tap Panes to pick some.").font(PadFont.ui(13)).foregroundColor(Pad.mute).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func pane(_ p: PadBizPane) -> some View {
        switch p {
        case .risk: if active.contains(where: { $0.risk == .high }) { riskCard }
        case .sessions: sessionsCard
        case .checkins: checkInsCard
        case .ending: endingCard
        case .unread: unreadCard
        case .prs: prsCard
        case .avgDays: avgDaysCard
        case .newInactive: newInactiveCard
        case .supplements: supplementsCard
        }
    }

    private func open(_ id: String) { PadNav.shared.clientId = id }

    private var riskCard: some View {
        // Only ever shown when someone is actually at risk (see pane(_:)).
        let list = active.filter { $0.risk == .high }.sorted { $0.score > $1.score }
        return PadInsightCard(title: "Flight risk", aside: list.count.plural("client"), dot: Pad.orange) {
            VStack(spacing: 0) {
                ForEach(list.prefix(4)) { f in
                    PadInsightRow(name: f.name, note: riskNote(f), noteColor: Pad.orange) { open(f.id) }
                }
            }
            if let top = list.first {
                Text(Self.why(top))
                    .font(PadFont.ui(13)).foregroundColor(Pad.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func why(_ f: PadClientFacts) -> String {
        let parts: [String] = f.reasons.prefix(3).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let joined: String = parts.joined(separator: "; ")
        return f.first + ": " + joined.lowercasedFirst + "."
    }

    private func riskNote(_ f: PadClientFacts) -> String {
        if let r = f.renewsOn { return "\(f.risk.label) · renews \(r.formatted(.dateTime.month(.abbreviated).day()))" }
        return f.risk.label
    }

    private var sessionsCard: some View {
        let weeks = (0..<8).map { i in active.reduce(0) { $0 + ($1.weekly.count > i ? $1.weekly[i] : 0) } }
        let done = weeks.last ?? 0
        let planned = active.reduce(0) { $0 + $1.plannedThisWeek }
        let prior = weeks.prefix(7).filter { $0 > 0 }
        let usual = prior.isEmpty ? 0 : prior.reduce(0, +) / prior.count
        let mx = max(weeks.max() ?? 1, 1)
        return PadInsightCard(title: "Sessions, all clients", aside: "8 weeks") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PadNumber(value: "\(done)", unit: planned > 0 ? "of \(planned) this week" : "this week", size: 30)
                Spacer()
                if usual > 0 { PadDelta(text: "\(done - usual >= 0 ? "+" : "−")\(abs(done - usual)) vs usual", better: done == usual ? nil : done > usual) }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, n in
                    RoundedRectangle(cornerRadius: 3).fill(i == weeks.count - 1 ? Pad.volt : Pad.raised)
                        .frame(maxWidth: .infinity).frame(height: max(3, 44 * CGFloat(n) / CGFloat(mx)))
                }
            }
            .frame(height: 44, alignment: .bottom)
            .accessibilityLabel("Sessions per week across clients: \(weeks.map(String.init).joined(separator: ", "))")
        }
    }

    private var checkInsCard: some View {
        var counted = 0
        var sent = 0
        for f in active {
            for m in f.checkInWeeks.suffix(5).prefix(4) where m.counts {
                counted += 1
                if m.isSent { sent += 1 }
            }
        }
        let rate: Int = counted == 0 ? 0 : Int((Double(sent) / Double(counted) * 100).rounded())
        let waiting = store.checkInQueue.sorted { $0.checkIn.date < $1.checkIn.date }
        return PadInsightCard(title: "Check-ins", aside: "4 weeks") {
            HStack(spacing: 8) {
                tile("Sent", "\(rate)", "%")
                tile("Waiting on you", "\(waiting.count)", waiting.first.map { "oldest \($0.checkIn.date.padShortAgo)" } ?? "")
            }
        }
    }

    private func tile(_ label: String, _ v: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PadLab(label, size: 12)
            PadNumber(value: v, unit: unit.isEmpty ? nil : unit, size: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
    }

    private var endingCard: some View {
        let list = facts.filter { $0.endingSoon }.sorted { ($0.assignment?.endDate ?? .distantFuture) < ($1.assignment?.endDate ?? .distantFuture) }
        return PadInsightCard(title: "Programs ending", aside: "14 days") {
            if list.isEmpty {
                Text("None in the next two weeks.").font(PadFont.ui(13)).foregroundColor(Pad.mute)
            } else {
                VStack(spacing: 0) {
                    ForEach(list.prefix(5)) { f in
                        PadInsightRow(name: f.name, note: "\(f.assignment!.endDate.formatted(.dateTime.month(.abbreviated).day())) · \(f.nothingAfter ? "nothing next" : "next planned")",
                                      noteColor: f.nothingAfter ? Pad.orange : Pad.mute) { open(f.id) }
                    }
                }
            }
        }
    }

    private var unreadCard: some View {
        let total = store.totalUnread
        var oldest: (Date, String)? = nil
        for c in store.roster {
            for t in coach.threads[c.id] ?? [] where t.unread > 0 {
                if oldest == nil || t.lastActivity < oldest!.0 { oldest = (t.lastActivity, c.name.firstName) }
            }
        }
        return PadInsightCard(title: "Unread messages", aside: "now") {
            HStack(alignment: .firstTextBaseline) {
                PadNumber(value: "\(total)", unit: "unread", size: 30)
                Spacer()
                if let o = oldest { PadLab("oldest \(o.0.padShortAgo), \(o.1)") }
            }
        }
    }

    private var prsCard: some View {
        let cal = Calendar.training
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let lastStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        var now = 0, before = 0
        var who = Set<String>()
        for c in store.roster {
            let prs = ProgressEngine.allPRs(workouts: data.workouts[c.id] ?? []).filter { !$0.isFirstEver }
            let m = prs.filter { $0.date >= monthStart }
            now += m.count
            before += prs.filter { $0.date >= lastStart && $0.date < monthStart }.count
            if !m.isEmpty { who.insert(c.id) }
        }
        return PadInsightCard(title: "PRs this month", aside: Date().formatted(.dateTime.month(.wide))) {
            HStack(alignment: .firstTextBaseline) {
                PadNumber(value: "\(now)", unit: "across \(who.count.plural("client"))", size: 30)
                Spacer()
                PadDelta(text: "\(now - before >= 0 ? "+" : "−")\(abs(now - before)) vs last month", better: now == before ? nil : now > before)
            }
        }
    }

    private var avgDaysCard: some View {
        let ds = active.compactMap { $0.daysSince }
        let avg = ds.isEmpty ? 0 : Double(ds.reduce(0, +)) / Double(ds.count)
        let worst = active.filter { $0.daysSince != nil }.sorted { $0.daysSince! > $1.daysSince! }.prefix(2)
        return PadInsightCard(title: "Days since trained", aside: "average") {
            PadNumber(value: String(format: "%.1f", avg), unit: "days", size: 30)
            VStack(spacing: 0) { ForEach(Array(worst)) { f in PadInsightRow(name: f.name, note: "\(f.daysSince!.plural("day"))") { open(f.id) } } }
        }
    }

    private var newInactiveCard: some View {
        let new = facts.filter { $0.isNew }
        let inactive = facts.filter { ($0.daysSince ?? 999) >= 14 }
        return PadInsightCard(title: "New and inactive", aside: "30 days") {
            HStack(spacing: 8) { tile("New", "\(new.count)", ""); tile("Inactive 2+ wks", "\(inactive.count)", "") }
            VStack(spacing: 0) {
                ForEach(Array(new.prefix(2))) { f in PadInsightRow(name: f.name, note: "new · since \(f.firstSeen?.formatted(.dateTime.month(.abbreviated).day()) ?? "")") { open(f.id) } }
                ForEach(Array(inactive.prefix(2))) { f in PadInsightRow(name: f.name, note: "\(f.daysSince.map { "\($0) days" } ?? "never trained")", noteColor: Pad.orange) { open(f.id) } }
            }
        }
    }

    private var supplementsCard: some View {
        let rows = store.roster.compactMap { c in data.adherence[c.id].map { (c, $0) } }.filter { $0.1.totalExpected > 0 }
        let avg = rows.isEmpty ? 0 : rows.map { $0.1.overallRate }.reduce(0, +) / Double(rows.count)
        let low = rows.sorted { $0.1.overallRate < $1.1.overallRate }.prefix(2)
        return PadInsightCard(title: "Supplements", aside: "taken as planned") {
            if rows.isEmpty {
                Text("No supplement plans yet.").font(PadFont.ui(13)).foregroundColor(Pad.mute)
            } else {
                PadNumber(value: "\(Int((avg * 100).rounded()))", unit: "% average", size: 30)
                VStack(spacing: 0) {
                    ForEach(Array(low), id: \.0.id) { row in
                        PadInsightRow(name: row.0.name, note: "\(Int((row.1.overallRate * 100).rounded()))%",
                                      noteColor: row.1.overallRate < 0.75 ? Pad.orange : Pad.mute) { open(row.0.id) }
                    }
                }
            }
        }
    }
}

extension String {
    var lowercasedFirst: String { self.prefix(1).lowercased() + String(self.dropFirst()) }
}

/// Choose and order the business panes (drag the handles).
struct PadBizPanesMenu: View {
    @ObservedObject private var prefs = PadBizPrefs.shared
    @State private var edit: EditMode = .active
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Show these panes").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            List {
                ForEach(prefs.order) { p in
                    Toggle(isOn: Binding(get: { prefs.on.contains(p) },
                                         set: { v in if v { prefs.on.insert(p) } else { prefs.on.remove(p) } })) {
                        Text(p.title).font(PadFont.ui(15)).foregroundColor(Pad.text)
                    }
                    .tint(Pad.volt)
                    .frame(minHeight: 40)
                    .listRowBackground(Pad.surface)
                }
                .onMove { from, to in prefs.order.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $edit)
            .frame(height: CGFloat(PadBizPane.allCases.count) * 48)
            Text("Drag to reorder. Remembered on this iPad.").font(PadFont.cond(12)).foregroundColor(Pad.faint).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 320)
        .background(Pad.surface)
    }
}

// MARK: - Level 2: the roster, compact

struct PadCompactRoster: View {
    let facts: [PadClientFacts]
    let selectedId: String
    let reviewed: Set<String>
    let open: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PadLab("Clients · needs you most")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(facts) { f in row(f).id(f.id) }
                    }
                }
                .onAppear { proxy.scrollTo(selectedId, anchor: .center) }
            }
        }
    }

    private func row(_ f: PadClientFacts) -> some View {
        let on = f.id == selectedId
        let st = f.status
        return Button { open(f.id) } label: {
            HStack(spacing: 10) {
                PadAvatar(name: f.name, size: 34, volt: on, dot: f.risk == .high ? Pad.orange : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    Text(st.sub.isEmpty ? st.text : "\(st.text) · \(st.sub)").font(PadFont.ui(12))
                        .foregroundColor(f.risk == .high ? Pad.orange : Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if reviewed.contains(f.id) { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Pad.voltText) }
            }
            .padding(.horizontal, 14).frame(minHeight: 60)
            .background(on ? Pad.surface : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Pad.volt).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Pad.line).frame(height: 1) }
            .opacity(f.paused && !on ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The roster folded to avatars, for switching client without leaving the section.
struct PadClientAvatarColumn: View {
    let facts: [PadClientFacts]
    let selectedId: String
    let reviewed: Set<String>
    let open: (String) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(facts) { f in avatar(f).id(f.id) }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(selectedId, anchor: .center) }
            .onChange(of: selectedId) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func avatar(_ f: PadClientFacts) -> some View {
        let on = f.id == selectedId
        return Button { open(f.id) } label: {
            PadAvatar(name: f.name, size: 40, volt: on, dot: f.risk == .high ? Pad.orange : nil)
                .overlay(alignment: .bottomTrailing) {
                    if reviewed.contains(f.id) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold))
                            .foregroundColor(Pad.voltText).background(Circle().fill(Pad.page)).offset(x: 3, y: 3)
                    }
                }
                .opacity(f.paused && !on ? 0.5 : 1)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(f.name)
        .accessibilityLabel(f.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Level 2: the client's sections, with a live detail on each

struct PadSectionList: View {
    let facts: PadClientFacts
    let awards: Int?
    @Binding var selection: PadClientSection
    @ObservedObject private var data = PadData.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(PadClientSection.ordered) { s in
                    row(s)
                    if s == .overview { Rectangle().fill(Pad.line).frame(height: 1).padding(.horizontal, 16).padding(.vertical, 6) }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func row(_ s: PadClientSection) -> some View {
        let on = s == selection
        let m = PadSectionMeta.meta(s, facts: facts, awards: awards)
        return Button { selection = s } label: {
            HStack(spacing: 11) {
                Image(systemName: s.icon).font(.system(size: 16, weight: .medium)).frame(width: 22)
                Text(s.title).font(PadFont.ui(15, .semibold))
                Spacer(minLength: 4)
                if let m { Text(m.text).font(PadFont.cond(12)).foregroundColor(m.color).lineLimit(1) }
            }
            .foregroundColor(on ? Pad.text : Pad.mute)
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Pad.raised : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .padding(.horizontal, 8)
        .accessibilityLabel(m.map { "\(s.title), \($0.text)" } ?? s.title)
    }
}

enum PadSectionMeta {
    @MainActor
    static func meta(_ s: PadClientSection, facts f: PadClientFacts, awards: Int?) -> (text: String, color: Color)? {
        let data = PadData.shared
        switch s {
        case .overview, .notes, .photos, .macros: return nil
        case .awards: return awards.map { ("\($0)", Pad.faint) }
        case .chat: return f.client.unreadMessages > 0 ? ("\(f.client.unreadMessages) unread", Pad.voltText) : nil
        case .checkins:
            if f.waiting != nil { return ("waiting", Pad.voltText) }
            if f.checkInLateDays > 0 { return ("\(f.checkInLateDays.plural("day")) late", Pad.orange) }
            return f.lastCheckIn.map { ($0.date.formatted(.dateTime.month(.abbreviated).day()), Pad.faint) }
        case .program:
            guard let a = f.assignment else { return ("none", Pad.faint) }
            return ("wk \(a.currentWeek) of \(a.totalWeeks)", f.endingSoon && f.nothingAfter ? Pad.orange : Pad.faint)
        case .stats:
            guard let l = f.lift else { return nil }
            if l.isFlat { return ("\(l.short) flat", Pad.orange) }
            guard let c = l.change else { return (l.short, Pad.faint) }
            let t = "\(l.short) \(c > 0 ? "+" : "−")\(StatsUnits.weightText(abs(c), unit: false))"
            return (t, c < 0 ? Pad.orange : Pad.faint)
        case .supplements:
            guard let a = data.adherence[f.id], a.totalExpected > 0 else { return nil }
            return ("\(Int((a.overallRate * 100).rounded()))%", a.overallRate < 0.75 ? Pad.orange : Pad.faint)
        case .workouts:
            guard let d = f.daysSince else { return ("none yet", Pad.faint) }
            let t = d == 0 ? "today" : (d == 1 ? "yesterday" : "\(d) days ago")
            return (t, f.risk == .high ? Pad.orange : Pad.faint)
        }
    }
}

/// Level 3: the sections as icons.
struct PadSectionIcons: View {
    let facts: PadClientFacts
    @Binding var selection: PadClientSection
    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(PadClientSection.ordered) { s in
                    icon(s)
                    if s == .overview { Rectangle().fill(Pad.line).frame(width: 32, height: 1).padding(.vertical, 4) }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private func icon(_ s: PadClientSection) -> some View {
        let on = s == selection
        let dot: Color? = {
            switch s {
            case .chat: return facts.client.unreadMessages > 0 ? Pad.volt : nil
            case .checkins: return facts.waiting != nil ? Pad.volt : (facts.checkInLateDays > 0 ? Pad.orange : nil)
            case .program: return facts.endingSoon && facts.nothingAfter ? Pad.orange : nil
            default: return nil
            }
        }()
        return Button { selection = s } label: {
            Image(systemName: s.icon).font(.system(size: 18, weight: .medium))
                .foregroundColor(on ? Pad.text : Pad.mute)
                .frame(width: 52, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? Pad.raised : Color.clear))
                .overlay(alignment: .leading) { if on { RoundedRectangle(cornerRadius: 1.5).fill(Pad.volt).frame(width: 3).padding(.vertical, 10) } }
                .overlay(alignment: .topTrailing) { if let dot { Circle().fill(dot).frame(width: 8, height: 8).offset(x: -9, y: 8) } }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(s.title)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Level 2: the Overview

struct PadClientOverview: View {
    let facts: PadClientFacts
    let awards: [APIAward]
    let go: (PadClientSection) -> Void
    var extra: AnyView? = nil
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared

    private var cal: Calendar { Calendar.training }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                numbers
                heat
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    lastWorkoutTile
                    lastCheckInTile
                    programTile
                    liftsTile
                    chatTile
                    awardTile
                }
                if let extra { extra }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    // Five numbers
    private var numbers: some View {
        let f = facts
        let cis = (coach.checkIns[f.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }
        let bw = cis.compactMap { c in PadInsights.bodyweight(c).map { (c.date, $0) } }
        let since = cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let bwNow = bw.last?.1
        let bwThen = bw.first { $0.0 >= since }?.1
        let sent4: Int = f.checkInWeeks.suffix(5).prefix(4).filter { $0.isSent }.count
        let adh = data.adherence[f.id]
        var bwSub = "from check-ins"
        if let n = bwNow, let t = bwThen {
            let d = n - t
            bwSub = (d >= 0 ? "+" : "−") + fmt(StatsUnits.weight(abs(d))) + " in 4 wks"
        }
        let bwValue = bwNow.map { fmt(StatsUnits.weight($0)) } ?? "—"
        let adhValue = adh.map { "\(Int(($0.overallRate * 100).rounded()))" } ?? "—"
        let adhSub = adh.map { $0.streakDays > 0 ? "\($0.streakDays)-day streak" : "taken as planned" } ?? "no plan"
        let lastSub = f.usualGap.map { "usual gap \(Int($0.rounded()))" } ?? ""
        let sessSub = f.donePrev28 > 0 ? "4 wks · was \(f.donePrev28)" : "last 4 weeks"
        let ciSub = f.checkInLateDays > 0 ? "\(f.checkInLateDays) days late" : (f.waiting != nil ? "1 waiting" : "4 weeks")
        return HStack(spacing: 8) {
            num("Last trained", f.daysSince.map { "\($0)" } ?? "—", f.daysSince == nil ? nil : "days", lastSub, warn: f.risk == .high)
            num("Sessions", "\(f.done28)", "of \(max(f.planned28, f.done28))", sessSub, subWarn: f.donePrev28 > f.done28 + 1)
            num("Check-ins", "\(sent4)", "of 4", ciSub, subWarn: f.checkInLateDays > 0)
            num("Bodyweight", bwValue, bwNow == nil ? nil : StatsUnits.weightLabel, bwSub)
            num("Supplements", adhValue, adh == nil ? nil : "%", adhSub, subWarn: (adh?.overallRate ?? 1) < 0.75)
        }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }

    private func num(_ label: String, _ v: String, _ unit: String?, _ sub: String, warn: Bool = false, subWarn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PadLab(label, size: 12).lineLimit(1)
            PadNumber(value: v, unit: unit, size: 24, color: warn ? Pad.orange : Pad.text).lineLimit(1).minimumScaleFactor(0.7)
            PadLab(sub, color: subWarn ? Pad.orange : Pad.mute, size: 12).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }

    // 28 days: trained, missed, planned, rest
    private var heat: some View {
        let today = cal.startOfDay(for: Date())
        let days = (0..<28).map { cal.date(byAdding: .day, value: $0 - 27, to: today) ?? today }
        let ss = data.sessions(client: facts.client)
        let kinds: [Int] = days.map { d in
            let mine = ss.filter { cal.isDate($0.day, inSameDayAs: d) || ($0.finish.map { cal.isDate($0, inSameDayAs: d) } ?? false) }
            if mine.contains(where: { $0.isDone }) { return 1 }
            if mine.contains(where: { $0.isMissed }) { return 2 }
            if !mine.isEmpty { return 3 }
            return 0
        }
        let trained = kinds.filter { $0 == 1 }.count
        let missed = kinds.filter { $0 == 2 }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 4 weeks").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                legend(Pad.volt, nil, "Trained"); legend(nil, Pad.orange, "Missed"); legend(Pad.raised, nil, "Rest")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 14), spacing: 4) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(k == 1 ? Pad.volt : (k == 0 ? Pad.raised : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(k == 2 ? Pad.orange : (k == 3 ? Pad.line2 : Color.clear), lineWidth: k == 2 ? 1.5 : 1))
                        .frame(height: 24)
                        .accessibilityLabel("\(days[i].formatted(.dateTime.month(.abbreviated).day())): \(["rest", "trained", "missed", "planned"][k])")
                }
            }
            PadLab(heatLine(trained: trained, missed: missed), size: 13)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func heatLine(trained: Int, missed: Int) -> String {
        var s = "\(trained.plural("session")) in 28 days"
        if missed > 0 { s += ", \(missed) missed" }
        if facts.missedStreak >= 2, let l = facts.lastTrained {
            s += ". Nothing since \(l.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))."
        } else { s += "." }
        return s
    }

    private func legend(_ fill: Color?, _ stroke: Color?, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(fill ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke ?? Color.clear, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
        .padding(.leading, 8)
    }

    // Tiles
    private func tile(_ icon: String, _ label: String, _ title: String, _ text: String, to s: PadClientSection) -> some View {
        Button { go(s) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    Text(label).font(PadFont.cond(13)).lineLimit(1)
                }
                .foregroundColor(Pad.mute)
                Text(title).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(text).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(3).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private var lastWorkoutTile: some View {
        let done = data.sessions(client: facts.client).filter { $0.isDone }.max { ($0.finish ?? $0.day) < ($1.finish ?? $1.day) }
        guard let w = done else {
            return tile("dumbbell", "Last workout", "Nothing logged yet", "Their first session will show here.", to: .workouts)
        }
        var txt = "\(w.setsLogged) of \(w.setsTotal) sets"
        if let r = w.avgRPE { txt += ", average RPE \(r.rpeText)" }
        if let a = w.start, let b = w.finish, b > a { txt += ". \(Int(b.timeIntervalSince(a) / 60)) minutes." } else { txt += "." }
        return tile("dumbbell", "Last workout · \(w.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))", w.title, txt, to: .workouts)
    }

    private var lastCheckInTile: some View {
        guard let c = facts.waiting ?? facts.lastCheckIn else {
            return tile("checkmark.square", "Check-ins", "None yet", "Their first check-in will show here.", to: .checkins)
        }
        let words = c.fields.sorted { $0.fieldOrder < $1.fieldOrder }.filter { Double($0.value) == nil && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let quote = facts.worry ?? PadCheckInReview.flaggedLine(c) ?? words.first?.value ?? ""
        let nums = c.fields.compactMap { f -> String? in
            guard let v = Double(f.value), !f.cleanLabel.lowercased().contains("weight") else { return nil }
            return "\(f.cleanLabel.components(separatedBy: " ").first ?? f.cleanLabel) \(Int(v))"
        }.prefix(3).joined(separator: ", ")
        let label = (facts.waiting != nil ? "Waiting · " : "Last check-in · ") + c.date.formatted(.dateTime.month(.abbreviated).day())
        let title = quote.isEmpty ? "Numbers only" : "“\(quote.count > 60 ? String(quote.prefix(58)) + "…" : quote)”"
        return tile("checkmark.square", label, title, nums.isEmpty ? "No scores." : nums + ".", to: .checkins)
    }

    private var programTile: some View {
        guard let a = facts.assignment else {
            return tile("list.bullet.rectangle", "Program", "No program", "Workouts are one-offs. Assign a program to plan the weeks ahead.", to: .program)
        }
        let after = facts.nothingAfter ? "Nothing is planned after it." : "The next block is planned."
        return tile("list.bullet.rectangle", "Program · \(a.programName)", "Ends \(a.endDate.formatted(.dateTime.month(.abbreviated).day()))",
                    "Week \(a.currentWeek) of \(a.totalWeeks), \(a.sessionsDone) of \(a.sessionsTotal) sessions. \(after)", to: .program)
    }

    private var liftsTile: some View {
        let best = data.bestLifts(clientId: facts.id)
        let title = best.prefix(2).map { "\($0.name.replacingOccurrences(of: "Back ", with: "").replacingOccurrences(of: " Press", with: "")) \(StatsUnits.weightText($0.e1rm, unit: false))" }.joined(separator: " · ")
        var txt = "Best e1RM over 8 weeks."
        if let l = facts.lift {
            if l.isFlat { txt = "\(l.short) flat for 4 weeks." }
            else if let c = l.change { txt = "\(l.short) \(c > 0 ? "up" : "down") \(StatsUnits.weightText(abs(c))) in 4 weeks." }
        }
        return tile("chart.bar", "Best lifts", title.isEmpty ? "No main lifts yet" : title, txt, to: .stats)
    }

    private var chatTile: some View {
        let t = (coach.threads[facts.id] ?? []).max { $0.lastActivity < $1.lastActivity }
        guard let t else { return tile("bubble.left", "Chat", "No conversations yet", "Start one from Message.", to: .chat) }
        let preview = t.preview.isEmpty ? t.topic : "“\(t.preview.count > 60 ? String(t.preview.prefix(58)) + "…" : t.preview)”"
        let txt = t.unread > 0 ? "\(t.unread) unread in \(t.topic)." : "In \(t.topic)."
        return tile("bubble.left", "Chat · \(t.lastActivity.padAgo)", preview, txt, to: .chat)
    }

    private var awardTile: some View {
        guard let a = awards.max(by: { $0.earnedAt < $1.earnedAt }) else {
            return tile("trophy", "Awards", "None yet", "Awards come with streaks, PRs and milestones.", to: .awards)
        }
        return tile("trophy", "Latest award · \(a.earnedAt.formatted(.dateTime.month(.abbreviated).day()))", a.title,
                    "\(awards.count.plural("award")) in all. \(a.blurb)", to: .awards)
    }
}

// MARK: - Level 2: about this client (risk, noticing, suggested next)

struct PadClientAbout: View {
    let facts: PadClientFacts
    let go: (PadClientSection) -> Void
    @State private var editingRenewal = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack { Text("About \(facts.first)").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text); Spacer() }
                    .padding(.top, 14)
                renewalRow
                if facts.risk == .high { riskCard }
                let ns = PadInsights.notices(facts)
                if !ns.isEmpty {
                    PadInsightCard(title: "Noticing") {
                        VStack(spacing: 0) {
                            ForEach(Array(ns.enumerated()), id: \.element.id) { i, n in
                                if i > 0 { PadRule() }
                                PadNoticeRow(notice: n).padding(.vertical, 9)
                            }
                        }
                    }
                }
                PadInsightCard(title: "Suggested next") {
                    VStack(spacing: 8) {
                        ForEach(PadInsights.suggestions(facts)) { s in
                            Button { go(s.section) } label: {
                                Text(s.title).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
    }

    private var riskCard: some View {
        PadInsightCard(title: "Flight risk", aside: "High", asideColor: Pad.orange, dot: Pad.orange) {
            PadRiskMeter(score: facts.score)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(facts.reasons, id: \.self) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Pad.orange).frame(width: 6, height: 6).padding(.top, 6)
                        Text(r).font(PadFont.ui(13)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The renewal date, always there (and editable), separate from any risk.
    private var renewalRow: some View {
        HStack {
            PadLab(facts.renewsOn.map { "Renews on \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "No renewal date")
            Spacer()
            Button(facts.renewsOn == nil ? "Set" : "Change") { editingRenewal = true }
                .font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                .popover(isPresented: $editingRenewal) { PadRenewEditor(facts: facts) }
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
    }
}

struct PadRiskMeter: View {
    let score: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Pad.green, Color(hex: 0xEDFF3D), Pad.orange, Pad.red], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 2).fill(Pad.text).frame(width: 4, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Pad.surface, lineWidth: 2))
                    .offset(x: max(0, min(g.size.width - 4, g.size.width * CGFloat(score) / 100 - 2)))
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .accessibilityLabel("Flight risk score \(score) of 100")
    }
}

struct PadNoticeRow: View {
    let notice: PadInsights.Notice
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.icon).font(.system(size: 13, weight: .semibold)).foregroundColor(notice.tint)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(Pad.raised))
            Text("\(Text(notice.text).foregroundColor(Pad.text))\(Text(notice.aside.isEmpty ? "" : " " + notice.aside).foregroundColor(Pad.mute))")
                .font(PadFont.ui(13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The app's own coach screens, inside a section (phone-width, centred).
struct PadClientLegacy<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack {
            content()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.bg.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}
