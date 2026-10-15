import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Coach HQ on iPad: Library ▸ Forms, Nutrition, Messages, Targets & awards, Imports (3.1.8)
//
// Forms: the default check-in form and named ones, who's on each and how on time they are; the
// new-client packet (intake, PAR-Q, goals, waiver) waits for the Documents update (needs the server).
// Nutrition: supplement templates and how well supplements stick; macro templates come with Nutrition.
// Messages: saved replies by how often you use them (counted on this iPad), and the Notes for next
// time starters Live offers. Targets & awards: your target templates by how often they're earned,
// who's working toward each, and awards earned lately. Imports: exercises in and out as a CSV.
// Synchronized folder: no target step needed.

// MARK: - Forms

struct PadLibraryForms: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go

    @State private var facts: [PadClientFacts] = []

    private var selectedId: String { lib.formId ?? "" }       // "" = the default form

    private func people(_ formId: String) -> [RosterItem] {
        store.roster.filter { c in (lib.clientForms[c.id] ?? "") == formId }
    }
    private func onTime(_ ids: Set<String>) -> Int? {
        let marks = facts.filter { ids.contains($0.id) }.flatMap { $0.checkInWeeks.suffix(8) }.filter { $0.counts }
        guard !marks.isEmpty else { return nil }
        return Int((Double(marks.filter { $0.isSent }.count) / Double(marks.count) * 100).rounded())
    }
    private func questions(_ formId: String) -> [CheckInQuestion] {
        formId.isEmpty ? CheckInSchema.questions : (lib.form(formId).flatMap { CheckInSchema.parse($0.json) } ?? [])
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PadLab("EVERY WEEK · CHECK-INS", color: Pad.faint, size: 11)
                        Spacer()
                        PadLab("Answers land in Check-ins", size: 12)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        formCard("")
                        ForEach(lib.forms) { f in formCard(f.id) }
                        Button { actions.sheet(.newForm) } label: {
                            Label("New form", systemImage: "plus").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.mute)
                                .frame(maxWidth: .infinity, minHeight: 112)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        }
                        .buttonStyle(.plain)
                    }
                    packet
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Pad.line).frame(width: 1)
            inspector.frame(width: 400)
        }
        .task {
            facts = PadRosterFacts.all(store)
            await lib.loadClientForms(store: store)
        }
    }

    private func formCard(_ id: String) -> some View {
        let on: Bool = selectedId == id
        let ppl = people(id)
        let ot = onTime(Set(ppl.map { $0.id }))
        let name: String = id.isEmpty ? "Default form" : (lib.form(id)?.name ?? "Form")
        let sub: String = id.isEmpty ? (CheckInSchema.custom == nil ? "standard questions · everyone else" : "your questions · everyone else") : "\(questions(id).count) questions"
        return Button { lib.formId = id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(1)
                PadLab(sub, size: 12).lineLimit(1)
                HStack(spacing: 18) {
                    mini("\(ppl.count)", "clients")
                    mini(ot.map { "\($0)%" } ?? "—", "on time", warn: (ot ?? 100) < 75)
                    mini("\(questions(id).count)", "questions")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Pad.text : Pad.line, lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.form(id).payload) { PadLibraryDragPreview(icon: "doc.text", title: name, sub: "check-in form") }
    }

    private func mini(_ v: String, _ l: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(PadFont.display(22)).foregroundColor(warn ? Pad.orange : Pad.text)
            PadLab(l, size: 12)
        }
    }

    private var packet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PadLab("ONCE · THE NEW-CLIENT PACKET", color: Pad.faint, size: 11)
                Text("NEEDS THE SERVER · 3.3 DOCUMENTS").font(PadFont.cond(11, .bold)).foregroundColor(Pad.isLight ? Color(hex: 0x00B8CC) : Pad.volt)
                    .padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(Pad.ink))
                Spacer()
            }
            HStack(spacing: 6) {
                step(1, "Intake", "contact, history, schedule")
                Image(systemName: "chevron.right").foregroundColor(Pad.faint)
                step(2, "PAR-Q", "7 yes/no · health screen")
                Image(systemName: "chevron.right").foregroundColor(Pad.faint)
                step(3, "Goals", "what, why, by when")
                Image(systemName: "chevron.right").foregroundColor(Pad.faint)
                step(4, "Waiver", "read and sign")
            }
            Text("One link for a new client: the four steps in order, a “yes” on the PAR-Q puts them in Needs you and holds their first workout until you clear it, and signed copies stay in their Documents. It needs the server to store the signed copies, so it comes with the Documents update.")
                .font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.well))
    }

    private func step(_ n: Int, _ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(PadFont.display(20)).foregroundColor(Pad.faint)
            Text(t).font(PadFont.ui(14, .bold)).foregroundColor(Pad.text)
            PadLab(s, size: 11).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
    }

    private var inspector: some View {
        let id = selectedId
        let ppl = people(id)
        let qs = questions(id)
        let name: String = id.isEmpty ? "Default form" : (lib.form(id)?.name ?? "Form")
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(name).font(PadFont.display(26)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    PadIconButton(systemName: "pencil", label: "Edit", small: true) {
                        if id.isEmpty { actions.sheet(.defaultFormEditor) } else if let f = lib.form(id) { actions.sheet(.formEditor(f)) }
                    }
                    PadLibraryGiveMenu(item: .form(id))
                }
                PadLab(id.isEmpty ? "Everyone who isn't on another form answers these each week." : "Clients on this form answer these each week, in this order.", size: 13)
                PadPane(title: "Who's on it", aside: ppl.isEmpty ? nil : onTime(Set(ppl.map { $0.id })).map { "\($0)% on time, 8 weeks" }) {
                    if ppl.isEmpty {
                        PadEmptyLine(text: lib.clientForms.isEmpty ? "" : "Nobody yet. Drag it onto a face below, or Give to….")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(ppl.enumerated()), id: \.element.id) { i, c in
                                if i > 0 { PadRule() }
                                personRow(c)
                            }
                        }
                    }
                }
                PadPane(title: "The questions", aside: qs.count.plural("question")) {
                    VStack(spacing: 0) {
                        ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                            if i > 0 { PadRule() }
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: q.kind == .scale ? "slider.horizontal.3" : (q.kind == .number ? "number" : "text.alignleft"))
                                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.mute).frame(width: 20).padding(.top, 2)
                                Text(q.label).font(PadFont.ui(14)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                PadLab(q.kind == .scale ? "1–10" : (q.kind == .number ? (q.unit.isEmpty ? "number" : q.unit) : "written"), color: Pad.faint, size: 12)
                            }
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func personRow(_ c: RosterItem) -> some View {
        let f = facts.first { $0.id == c.id }
        let marks = (f?.checkInWeeks ?? []).suffix(8)
        return HStack(spacing: 10) {
            PadAvatar(name: c.name, size: 28)
            Text(c.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    RoundedRectangle(cornerRadius: 3).fill(m.isSent ? Pad.text : (m.counts ? Pad.orange.opacity(0.7) : Pad.raised)).frame(width: 12, height: 12)
                }
            }
            PadLab(f?.lastCheckIn.map { PadDay.short($0.date) } ?? "none yet", size: 12).frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { PadOpen.client(c.id, .checkins, go: go) }
    }
}

// MARK: - Nutrition

struct PadLibraryNutrition: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var data = PadData.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go

    private var selected: APISupplementTemplate? {
        if let id = lib.templateId, let t = lib.template(id) { return t }
        return lib.templates.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PadLab("SUPPLEMENT TEMPLATES", color: Pad.faint, size: 11)
                    if lib.templates.isEmpty {
                        PadEmptyLine(text: lib.loaded ? "No templates yet. Save a client's protocol as one from their Supplements." : "")
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(lib.templates) { t in templateCard(t) }
                        }
                    }
                    stickPane
                    HStack(spacing: 12) {
                        Image(systemName: "chart.pie").font(.system(size: 18, weight: .semibold)).foregroundColor(Pad.mute)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Macro templates").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                            Text("Lean cut, recomp, training and rest days, with who's on each and how often they hit protein. They come with the Nutrition update; until then set macros from a client's Macros.")
                                .font(PadFont.ui(13)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(Pad.line2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Pad.line).frame(width: 1)
            Group {
                if let t = selected { inspector(t) } else {
                    PadLibraryPick(icon: "leaf", title: "No templates yet", text: "Save a client's supplements as a template from their Supplements, then give it to anyone from here.")
                }
            }
            .frame(width: 380)
        }
        .task {
            await data.loadAdherence(roster: store.roster)
            if let t = selected { await lib.templateDetail(t.id) }
        }
        .onChange(of: lib.templateId) { _, id in if let id { Task { await lib.templateDetail(id) } } }
    }

    private func templateCard(_ t: APISupplementTemplate) -> some View {
        let on: Bool = selected?.id == t.id
        let items: [LibSuppTemplate.Item] = lib.templateDetails[t.id]?.items ?? []
        return Button { lib.templateId = t.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(PadFont.ui(15, .bold)).foregroundColor(Pad.text).lineLimit(1)
                PadLab(items.isEmpty ? t.itemCount.plural("supplement") : items.map { $0.name }.joined(separator: " · "), size: 12).lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Pad.text : Pad.line, lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.supplement(t.id).payload) { PadLibraryDragPreview(icon: "leaf", title: t.name, sub: t.itemCount.plural("supplement")) }
        .task { await lib.templateDetail(t.id) }
    }

    private var stickPane: some View {
        let rows: [(RosterItem, APISupplementAdherence)] = store.roster.compactMap { c in data.adherence[c.id].map { (c, $0) } }.filter { $0.1.totalExpected > 0 }
            .sorted { $0.1.overallRate < $1.1.overallRate }
        return PadPane(title: "How supplements stick", aside: "taken, last 30 days") {
            if rows.isEmpty {
                PadEmptyLine(text: "Nobody's on supplements yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.0.id) { i, r in
                        if i > 0 { PadRule() }
                        HStack(spacing: 10) {
                            PadAvatar(name: r.0.name, size: 28)
                            Text(r.0.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).frame(width: 110, alignment: .leading).lineLimit(1)
                            PadLab(r.1.perSupplement.map { $0.name }.prefix(3).joined(separator: " · "), size: 12).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            PadBar(fraction: r.1.overallRate, hero: false, height: 7).frame(width: 90)
                            Text("\(Int((r.1.overallRate * 100).rounded()))%").font(PadFont.ui(13, .bold)).foregroundColor(r.1.overallRate < 0.5 ? Pad.orange : Pad.text).frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { PadOpen.client(r.0.id, .supplements, go: go) }
                    }
                }
            }
        }
    }

    private func inspector(_ t: APISupplementTemplate) -> some View {
        let d = lib.templateDetails[t.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(t.name).font(PadFont.display(26)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    PadLibraryGiveMenu(item: .supplement(t.id))
                }
                PadLab("Giving it adds these to their protocol. Anything they already take stays.", size: 13)
                PadPane(title: "In it", aside: t.itemCount.plural("supplement")) {
                    if let d {
                        VStack(spacing: 0) {
                            ForEach(Array(d.items.enumerated()), id: \.offset) { i, it in
                                if i > 0 { PadRule() }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(it.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                                        Spacer()
                                        Text(dose(it)).font(PadFont.ui(13)).foregroundColor(Pad.text)
                                    }
                                    PadLab([timing(it.timingKind), it.stackName, it.instructions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), size: 12)
                                }
                                .padding(.vertical, 7)
                            }
                        }
                    } else {
                        PadSkeleton(height: 60)
                    }
                }
            }
            .padding(16)
        }
    }

    private func dose(_ it: LibSuppTemplate.Item) -> String {
        guard let a = it.doseAmount else { return it.doseUnit ?? "" }
        let n: String = a == a.rounded() ? String(Int(a)) : String(format: "%.1f", a)
        return "\(n) \(it.doseUnit ?? "")"
    }
    private func timing(_ k: String?) -> String? {
        switch k {
        case "daily": return "every day"
        case "fixedDays": return "set days"
        case "beforeWorkout": return "before training"
        case "afterWorkout": return "after training"
        case "withMeals": return "with meals"
        default: return nil
        }
    }
}

// MARK: - Messages

struct PadLibraryMessages: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var ask = PadLibraryMessagesNew.shared
    @State private var tab = "replies"
    @State private var draft = ""
    @State private var editing = ""
    @State private var adding = false
    @FocusState private var addFocused: Bool

    private var items: [String] { tab == "replies" ? store.savedReplies : PadLiveStarters.list }
    private var sorted: [String] {
        guard tab == "replies" else { return items }
        return items.enumerated().sorted { a, b in
            let ua = PadReplyUses.count(a.element), ub = PadReplyUses.count(b.element)
            return ua != ub ? ua > ub : a.offset < b.offset
        }.map { $0.element }
    }
    private var selected: String? {
        if let r = lib.replyText, items.contains(r) { return r }
        return sorted.first
    }

    var body: some View {
        let _ = lib.replyUsesVersion + lib.startersVersion
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PadSeg(options: [(id: "replies", label: "Saved replies \(store.savedReplies.count)"), (id: "starters", label: "Notes for next time \(PadLiveStarters.list.count)")], selection: $tab)
                    Spacer()
                    Button { adding = true; addFocused = true } label: { Label("New", systemImage: "plus") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                .padding(12)
                Rectangle().fill(Pad.line).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        if adding {
                            HStack(spacing: 8) {
                                TextField(tab == "replies" ? "A reply you send often" : "A note you leave often", text: $draft).padInput().focused($addFocused).onSubmit { add() }
                                Button("Add") { add() }.buttonStyle(PadButtonStyle(kind: .primary, small: true)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { adding = false; draft = "" }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                            }
                            .padding(12)
                        }
                        ForEach(sorted, id: \.self) { r in row(r) }
                        PadLab(tab == "replies" ? "Use counts are kept on this iPad: they go up when you tap a reply in Inbox or Check-ins." : "Live offers these as one-tap notes for a client's next workout.", color: Pad.faint, size: 12)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Pad.line).frame(width: 1)
            inspector.frame(width: 420)
        }
        .onAppear { consumeAsk() }
        .onChange(of: ask.reply) { _, _ in consumeAsk() }
        .onChange(of: ask.starter) { _, _ in consumeAsk() }
        .onChange(of: selected) { _, s in editing = s ?? "" }
        .onChange(of: tab) { _, _ in lib.replyText = nil; editing = selected ?? "" }
    }

    private func consumeAsk() {
        if ask.reply { tab = "replies"; adding = true; addFocused = true; ask.reply = false }
        if ask.starter { tab = "starters"; adding = true; addFocused = true; ask.starter = false }
        editing = selected ?? ""
    }

    private func row(_ r: String) -> some View {
        let on: Bool = selected == r
        let uses: Int = PadReplyUses.count(r)
        let top: Int = max(items.map { PadReplyUses.count($0) }.max() ?? 1, 1)
        return Button { lib.replyText = r; editing = r } label: {
            HStack(spacing: 12) {
                Text(r).font(PadFont.ui(15)).foregroundColor(Pad.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if tab == "replies" {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(uses)×").font(PadFont.ui(14, .bold)).foregroundColor(uses == 0 ? Pad.faint : Pad.text)
                        PadBar(fraction: Double(uses) / Double(top), hero: false, height: 6).frame(width: 90)
                        PadLab(PadReplyUses.last(r).map { "last \(PadDay.short($0))" } ?? "not used yet", color: Pad.faint, size: 11)
                    }
                    .frame(width: 110)
                }
            }
            .padLibraryRow(on)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = selected {
                PadLab(tab == "replies" ? "SAVED REPLY" : "NOTE FOR NEXT TIME", color: Pad.faint, size: 11)
                TextEditor(text: $editing).font(PadFont.ui(16)).frame(minHeight: 120).scrollContentBackground(.hidden).padInput(multiline: true)
                HStack(spacing: 8) {
                    Button("Save") { replace(s, with: editing) }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
                        .disabled(editing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editing == s)
                    Button { move(s, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    Button { move(s, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                    Spacer()
                    Button("Delete", role: .destructive) { remove(s) }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                }
                if tab == "replies" {
                    HStack(spacing: 10) {
                        PadLibraryStat(value: "\(PadReplyUses.count(s))", label: "times used here")
                        PadLibraryStat(value: PadReplyUses.last(s).map { PadDay.short($0) } ?? "—", label: "last used")
                    }
                    PadLab("Shows in the composer in Inbox and Check-ins. The order here is the order there.", size: 12)
                } else {
                    PadLab("Live shows these under Notes for next time. Tap one and it goes on the client's next workout with that exercise.", size: 12)
                }
            } else {
                PadLibraryPick(icon: "text.bubble", title: "Nothing here yet", text: "Add a reply you send often, and it's one tap away in Inbox and Check-ins.")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func save(_ list: [String]) {
        if tab == "replies" { store.setSavedReplies(list) } else { PadLiveStarters.list = list; lib.startersVersion += 1 }
    }
    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var l = items
        if !l.contains(t) { l.append(t) }
        save(l)
        lib.replyText = t
        editing = t
        draft = ""
        adding = false
    }
    private func replace(_ old: String, with new: String) {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        save(items.map { $0 == old ? t : $0 })
        lib.replyText = t
        PadToasts.shared.show("Saved")
    }
    private func move(_ s: String, _ d: Int) {
        var l = items
        guard let i = l.firstIndex(of: s), i + d >= 0, i + d < l.count else { return }
        l.swapAt(i, i + d)
        save(l)
    }
    private func remove(_ s: String) {
        let before = items
        save(items.filter { $0 != s })
        lib.replyText = nil
        PadToasts.shared.show("Deleted “\(s)”", action: "Undo") { save(before) }
    }
}

// MARK: - Targets & awards

struct PadLibraryTargets: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @ObservedObject private var targets = PadTargets.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go
    @State private var confirmDelete: PadTargetTemplate?

    static func rule(_ t: PadTargetTemplate) -> String {
        switch t.kind {
        case .lift: return t.reps > 0 ? "\(t.lift) \(StatsUnits.weightText(t.weight)) × \(t.reps)" : "\(t.lift) \(StatsUnits.weightText(t.weight)) e1RM"
        case .sessions: return t.weeks > 0 ? "\(t.count) sessions in \(t.weeks) weeks" : "\(t.count) sessions"
        case .streak: return "Train every week for \(t.count) weeks"
        case .checkins: return "\(t.count) check-ins in a row"
        case .manual: return "You tick it when it happens"
        }
    }

    private var all: [(clientId: String, target: PadTarget)] {
        targets.targets.flatMap { kv in kv.value.map { (clientId: kv.key, target: $0) } }
    }
    private func earned(_ tp: PadTargetTemplate) -> [(clientId: String, target: PadTarget)] { all.filter { $0.target.title == tp.title && $0.target.isEarned } }
    private func working(_ tp: PadTargetTemplate) -> [(clientId: String, target: PadTarget)] { all.filter { $0.target.title == tp.title && !$0.target.isEarned } }

    /// Earned per month, last 6 months, oldest first.
    private func perMonth(_ tp: PadTargetTemplate) -> [Int] {
        let cal = Calendar.training
        let now = Date()
        return (0..<6).reversed().map { back in
            guard let m = cal.date(byAdding: .month, value: -back, to: now) else { return 0 }
            return earned(tp).filter { e in e.target.earnedDate.map { cal.isDate($0, equalTo: m, toGranularity: .month) } ?? false }.count
        }
    }

    private var list: [PadTargetTemplate] { targets.templates.sorted { earned($0).count != earned($1).count ? earned($0).count > earned($1).count : $0.title < $1.title } }
    private var selected: PadTargetTemplate? {
        if let id = lib.targetTemplateId, let t = targets.templates.first(where: { $0.id == id }) { return t }
        return list.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    PadLab("Your target templates · earned, last 6 months", size: 12)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 44)
                Rectangle().fill(Pad.line).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list) { t in row(t) }
                        awardsPane.padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Pad.line).frame(width: 1)
            Group {
                if let t = selected { inspector(t) } else {
                    PadLibraryPick(icon: "trophy", title: "No templates", text: "Save a target as a template from a client's Wins ▸ Set a target.")
                }
            }
            .frame(width: 400)
        }
        .confirmationDialog("Delete the “\(confirmDelete?.title ?? "")” template?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let t = confirmDelete { PadTargets.shared.removeTemplate(t.id, store: store); lib.targetTemplateId = nil } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Targets people are already working toward stay.") }
    }

    private func row(_ t: PadTargetTemplate) -> some View {
        let on: Bool = selected?.id == t.id
        let e = earned(t).count, w = working(t).count
        let never: Bool = e == 0
        return Button { lib.targetTemplateId = t.id } label: {
            HStack(spacing: 12) {
                Image(systemName: t.icon).font(.system(size: 18, weight: .semibold))
                    .foregroundColor(never ? Pad.faint : (Pad.isLight ? Pad.volt : Pad.ink))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(never ? Pad.well : (Pad.isLight ? Pad.ink : Pad.volt)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                    PadLab(Self.rule(t), size: 13)
                }
                Spacer(minLength: 6)
                PadLibraryBars(values: perMonth(t), hero: 5).frame(width: 80)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(never ? "never earned" : "\(e) earned").font(PadFont.ui(14, .bold)).foregroundColor(never && !all.isEmpty ? Pad.orange : Pad.text)
                    PadLab(w == 0 ? "" : "\(w) working on it", size: 12)
                }
                .frame(width: 120, alignment: .trailing)
            }
            .padLibraryRow(on)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.target(t.id).payload) { PadLibraryDragPreview(icon: t.icon, title: t.title, sub: Self.rule(t)) }
    }

    private var awardsPane: some View {
        PadPane(title: "Awards earned lately", aside: "last 90 days") {
            if lib.awards.isEmpty {
                PadEmptyLine(text: "None in the last 90 days.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lib.awards.sorted { $0.earnedAt > $1.earnedAt }.prefix(8).enumerated()), id: \.offset) { i, a in
                        if i > 0 { PadRule() }
                        HStack(spacing: 10) {
                            Image(systemName: a.icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.text).frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                                PadLab("\(a.clientName) · \(a.blurb)", size: 12).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            PadLab(PadDay.short(a.earnedAt), size: 12)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func inspector(_ t: PadTargetTemplate) -> some View {
        let w = working(t)
        let e = earned(t).sorted { ($0.target.earnedDate ?? .distantPast) > ($1.target.earnedDate ?? .distantPast) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(t.title).font(PadFont.display(26)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    PadIconButton(systemName: "trash", label: "Delete template", small: true, tint: Pad.red) { confirmDelete = t }
                    PadLibraryGiveMenu(item: .target(t.id))
                }
                PadLab(Self.rule(t), size: 14)
                if !t.note.isEmpty {
                    Text("“\(t.note)”").font(PadFont.ui(14)).foregroundColor(Pad.text).padWell(12).fixedSize(horizontal: false, vertical: true)
                    PadLab("What they see when they earn it.", color: Pad.faint, size: 12)
                }
                PadPane(title: "Working toward it", aside: w.isEmpty ? nil : "\(w.count)") {
                    if w.isEmpty {
                        PadEmptyLine(text: "Nobody right now. Drag it onto a face below, or Give to….")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(w.enumerated()), id: \.element.target.id) { i, x in
                                if i > 0 { PadRule() }
                                progressRow(x.clientId, x.target)
                            }
                        }
                    }
                }
                PadPane(title: "Earned it", aside: e.isEmpty ? nil : "\(e.count)") {
                    if e.isEmpty {
                        PadEmptyLine(text: "Nobody yet.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(e.prefix(10).enumerated()), id: \.element.target.id) { i, x in
                                if i > 0 { PadRule() }
                                HStack(spacing: 10) {
                                    PadAvatar(name: name(x.clientId), size: 26)
                                    Text(name(x.clientId)).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                                    Spacer()
                                    PadLab(x.target.earnedDate.map { PadDay.short($0) } ?? "", size: 12)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func name(_ id: String) -> String { store.roster.first { $0.id == id }?.name ?? "Client" }

    private func progressRow(_ clientId: String, _ t: PadTarget) -> some View {
        let c = store.roster.first { $0.id == clientId }
        let p: PadTargetProgress? = c.map { PadTargetProgress.compute(t, facts: PadInsights.facts($0, store: store)) }
        return HStack(spacing: 10) {
            PadAvatar(name: c?.name ?? "?", size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c?.name ?? "Client").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                    Spacer()
                    PadLab(p.map { "\($0.currentText) of \($0.goalText)" } ?? "", size: 12)
                }
                PadBar(fraction: p?.fraction ?? 0, hero: true, height: 6)
                if let p, !p.pace.isEmpty { PadLab(p.pace, color: p.onPace == false ? Pad.orange : Pad.mute, size: 11) }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { PadOpen.client(clientId, .awards, go: go) }
    }
}

// MARK: - Imports

struct PadLibraryImports: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    card(icon: "square.and.arrow.down", title: "Exercises from a CSV",
                         text: "A spreadsheet with a Name column, and any of: Muscle, Secondary, Equipment, Pattern, Level, Sets, Reps, Rest, Load, Tags, Cues, Video. New names are added to your library; names you already have are updated. Blank cells keep what's there.") {
                        Button { picking = true } label: { Label("Choose a file", systemImage: "doc") }.buttonStyle(PadButtonStyle(kind: .primary, small: true))
                        if let error { PadLab(error, color: Pad.orange, size: 13) }
                    }
                    card(icon: "square.and.arrow.up", title: "Your exercises as a CSV",
                         text: "Every exercise you have (yours and the standard ones), with muscles, defaults, tags, cues, video and how much it's used. Opens in Numbers or Excel.") {
                        if let url = exportFile() {
                            ShareLink(item: url) { Label("Share the CSV", systemImage: "square.and.arrow.up") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        } else {
                            PadLab(lib.loaded ? "Nothing to export yet." : "", size: 13)
                        }
                    }
                }
                card(icon: "person.2", title: "Clients from a spreadsheet",
                     text: "A client's whole program from their old spreadsheet (workouts, maxes, macros) comes in through Coach HQ on the web ▸ Clients ▸ Import, which asks about anything the sheet doesn't say.") { EmptyView() }
            }
            .padding(18)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { r in
            switch r {
            case .success(let url): read(url)
            case .failure: error = "Couldn't open that file."
            }
        }
    }

    private func card<A: View>(icon: String, title: String, text: String, @ViewBuilder actions a: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(Pad.text)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
                Text(title).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            }
            Text(text).font(PadFont.ui(14)).foregroundColor(Pad.mute).fixedSize(horizontal: false, vertical: true)
            a()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pad.line, lineWidth: 1))
    }

    private func read(_ url: URL) {
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            error = "Couldn't read that file."
            return
        }
        let rows = PadLibraryCSV.parse(text)
        guard rows.count >= 2 else { error = "That file has no rows."; return }
        let out = PadLibraryCSV.exerciseRows(rows)
        guard !out.isEmpty else { error = "It needs a “Name” column."; return }
        actions.sheet(.importRows(out))
    }

    private func exportFile() -> URL? {
        let xs = lib.exercises.filter { !$0.isTyped }
        guard !xs.isEmpty else { return nil }
        let head = ["Name", "Source", "Muscle", "Secondary", "Equipment", "Pattern", "Mechanics", "Sides", "Level", "Sets", "Reps", "Rest", "Load", "Tags", "Cues", "Video", "Programmed 30d", "Clients"]
        var lines = [head.joined(separator: ",")]
        for x in xs {
            let cells: [String] = [x.name, x.source, x.muscleGroup, x.secondary, x.equipment, x.pattern, x.mechanics, x.laterality, x.level,
                                   "\(x.defaultSets)", "\(x.defaultReps)", "\(x.restSeconds)", x.loadText, x.tags.joined(separator: ", "),
                                   x.cues, x.videoUrl ?? "", "\(x.used30)", x.clients.map { $0.name }.joined(separator: ", ")]
            lines.append(cells.map(PadLibraryCSV.cell).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exercise-library.csv")
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

enum PadLibraryCSV {
    static func cell(_ v: String) -> String {
        v.contains(",") || v.contains("\"") || v.contains("\n") ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    /// Same reader as Coach HQ: quotes, doubled quotes, commas and newlines inside quotes.
    static func parse(_ t: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cur = ""
        var q = false
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if q {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { q = false }
                } else { cur.append(c) }
            } else if c == "\"" { q = true }
            else if c == "," { row.append(cur); cur = "" }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(cur); rows.append(row); row = []; cur = ""
            } else { cur.append(c) }
            i += 1
        }
        if !cur.isEmpty || !row.isEmpty { row.append(cur); rows.append(row) }
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// Rows keyed by the server's field names, from the header's column names.
    static func exerciseRows(_ rows: [[String]]) -> [[String: String]] {
        let h = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int { h.firstIndex { names.contains($0) } ?? -1 }
        let ix: [(String, Int)] = [
            ("name", col(["name", "exercise"])), ("muscleGroup", col(["muscle", "muscle group", "primary"])),
            ("secondaryMuscles", col(["secondary", "secondary muscles"])), ("equipment", col(["equipment"])),
            ("pattern", col(["pattern", "movement pattern"])), ("mechanics", col(["mechanics"])), ("laterality", col(["sides", "laterality"])),
            ("level", col(["level"])), ("defaultSets", col(["sets"])), ("defaultReps", col(["reps"])), ("restSeconds", col(["rest", "rest seconds"])),
            ("loadText", col(["load"])), ("tags", col(["tags"])), ("cues", col(["cues", "form cues"])), ("videoUrl", col(["video", "video url", "demo video"])),
        ]
        guard ix.first(where: { $0.0 == "name" })?.1 ?? -1 >= 0 else { return [] }
        return rows.dropFirst().compactMap { r in
            var o: [String: String] = [:]
            for (k, i) in ix where i >= 0 && i < r.count {
                let v = r[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { o[k] = v }
            }
            return (o["name"] ?? "").isEmpty ? nil : o
        }
    }
}

struct PadLibraryImportSheet: View {
    let rows: [[String: String]]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = PadLibraryStore.shared
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import \(rows.count.plural("exercise"))").font(PadFont.display(28)).foregroundColor(Pad.text)
                Spacer()
                PadIconButton(systemName: "xmark", label: "Close", small: true) { dismiss() }
            }
            PadLab("New names are added to your library; names you already have are updated. Blank cells keep what's there.", size: 13)
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        PadLab("Name").frame(maxWidth: .infinity, alignment: .leading)
                        PadLab("Muscle").frame(width: 120, alignment: .leading)
                        PadLab("Equipment").frame(width: 120, alignment: .leading)
                        PadLab("Default").frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    ForEach(Array(rows.prefix(80).enumerated()), id: \.offset) { _, r in
                        HStack {
                            Text(r["name"] ?? "").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).frame(maxWidth: .infinity, alignment: .leading)
                            Text(r["muscleGroup"] ?? "").font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 120, alignment: .leading)
                            Text(r["equipment"] ?? "").font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 120, alignment: .leading)
                            Text((r["defaultSets"] ?? "") + ((r["defaultReps"] ?? "").isEmpty ? "" : "×" + (r["defaultReps"] ?? ""))).font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { PadRule() }
                    }
                    if rows.count > 80 { PadLab("…and \(rows.count - 80) more", size: 12).padding(.top, 6) }
                }
            }
            if let error { PadLab(error, color: Pad.orange, size: 13) }
            Button { go() } label: {
                HStack { if saving { ProgressView().tint(Pad.onVolt) }; Text("Import") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PadButtonStyle(kind: .primary))
            .disabled(saving)
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
    }

    private func go() {
        let nums: Set<String> = ["defaultSets", "defaultReps", "restSeconds"]
        let body: [[String: Any]] = rows.map { r in
            var o: [String: Any] = [:]
            for (k, v) in r {
                if nums.contains(k) {
                    if let n = Int(v) { o[k] = n } else { o[k] = NSNull() }
                } else { o[k] = v }
            }
            return o
        }
        saving = true
        error = nil
        Task {
            do {
                let r = try await APIClient.shared.importLibraryExercises(rows: body)
                await lib.reloadExercises()
                let skipped: Int = r.skipped?.count ?? 0
                PadToasts.shared.show("\(r.added ?? 0) added · \(r.updated ?? 0) updated" + (skipped > 0 ? " · \(skipped) skipped" : ""))
                dismiss()
            } catch {
                self.error = "Couldn't import. Check your connection and try again."
            }
            saving = false
        }
    }
}
