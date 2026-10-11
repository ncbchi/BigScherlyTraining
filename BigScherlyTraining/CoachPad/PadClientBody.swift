import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: a client's Photos, Supplements and Macros (Oct 9, 2026)
//
// Photos: a strip of dates, any two dates side by side pose for pose (or a slider), bodyweight
// under each, and your comment beside them. Tools: ask for photos.
// Supplements: a 28-day adherence grid (taken, late, missed) with the stack beside it to edit in
// place. What gets skipped, and when. Tools: add, apply a template, nudge.
// Macros: two weeks of targets with activity bumps, the bodyweight trend against the calories and
// the check-in nutrition/hunger scores, and new targets (training and rest days, presets, a start
// date). Nobody logs food in the app yet, so it's targets and outcomes, not intake.
// Synchronized folder: no target step needed.

// MARK: - Photos

struct PadClientPhotos: View {
    let facts: PadClientFacts
    @ObservedObject private var coach = CoachData.shared
    @State private var photos: [APIPhoto] = []
    @State private var loaded = false
    @State private var before: Date?
    @State private var after: Date?
    @State private var pose = "Front"
    @State private var slider = false
    @State private var split: CGFloat = 0.5
    @State private var comment = ""
    @State private var saving = false
    @State private var quick: PadQuickMessage?

    private var cal: Calendar { Calendar.training }
    private var days: [Date] { Array(Set(photos.map { cal.startOfDay(for: $0.date) })).sorted() }
    private var poses: [String] {
        let order = ["Front", "Side", "Back"]
        let cats = Array(Set(photos.map { $0.category }))
        return cats.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
    }

    var body: some View {
        let ds = days
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(ds), notices: notices(ds)) {
                if ds.count >= 2 {
                    PadSeg(options: [(id: false, label: "Side by side"), (id: true, label: "Slider")], selection: $slider)
                }
                Button {
                    quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Ask for photos",
                                            text: "Can you add front, side and back photos with your next check-in? Same spot and lighting as last time if you can.")
                } label: { Label("Ask for photos", systemImage: "camera") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadRule()
            if ds.isEmpty {
                PadEmptyLine(text: loaded ? "No progress photos yet. They come in with check-ins." : "").padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                dateStrip(ds)
                PadRule()
                HStack(alignment: .top, spacing: 0) {
                    compare.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Pad.line).frame(width: 1)
                    commentPane.frame(width: 300).background(Pad.page)
                }
            }
        }
        .task {
            photos = (try? await APIClient.shared.trainerPhotos(clientId: facts.id)) ?? photos
            loaded = true
            let ds = days
            if after == nil { after = ds.last }
            if before == nil { before = ds.count >= 2 ? ds.first : nil }
            if !poses.contains(pose), let p = poses.first { pose = p }
            syncComment()
            await coach.loadCheckIns(facts.id)
        }
        .onChange(of: after) { _, _ in syncComment() }
        .onChange(of: pose) { _, _ in syncComment() }
        .sheet(item: $quick) { m in PadQuickMessageSheet(message: m) }
    }

    private func photo(_ day: Date?, _ pose: String) -> APIPhoto? {
        guard let day else { return nil }
        return photos.first { cal.isDate($0.date, inSameDayAs: day) && $0.category == pose }
    }

    private func bodyweight(near d: Date) -> Double? {
        let cis = (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" }
        let close = cis.filter { abs($0.date.timeIntervalSince(d)) < 4 * 86_400 }.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
        return close.flatMap { PadInsights.bodyweight($0) }
    }

    // MARK: Headline

    private func stats(_ ds: [Date]) -> [PadStat] {
        guard let last = ds.last else { return [PadStat(label: "Photo sets", value: "0", sub: "none yet")] }
        let gaps = zip(ds.dropFirst(), ds).map { Double(cal.dateComponents([.day], from: $1, to: $0).day ?? 0) }
        let every = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        var out = [
            PadStat(label: "Photo sets", value: "\(ds.count)", sub: "since \(PadDay.short(ds.first!))"),
            PadStat(label: "Last set", value: "\(PadDay.daysAgo(last))", unit: "days ago", sub: PadDay.short(last), warn: PadDay.daysAgo(last) > 28),
            PadStat(label: "How often", value: every.map { ($0 / 7).padShort } ?? "—", unit: every == nil ? nil : "wks apart", sub: "on average")
        ]
        if let a = bodyweight(near: ds.first!), let b = bodyweight(near: last), ds.count >= 2 {
            let d = StatsUnits.weight(b - a)
            out.append(PadStat(label: "Bodyweight", value: "\(d >= 0 ? "+" : "−")\(abs(d).padShort)", unit: StatsUnits.weightLabel, sub: "first set to latest"))
        }
        return out
    }

    private func notices(_ ds: [Date]) -> [PadInsights.Notice] {
        guard let last = ds.last, PadDay.daysAgo(last) > 28 else { return [] }
        return [.init(icon: "camera.badge.clock", tint: Pad.orange, text: "Last photos were \(PadDay.daysAgo(last) / 7) weeks ago.",
                      aside: "Monthly photos show change the scale can't.")]
    }

    // MARK: Dates

    private func dateStrip(_ ds: [Date]) -> some View {
        let beforeLabel: String = "Before: " + (before.map { PadDay.short($0) } ?? "none")
        return HStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ds, id: \.self) { d in
                            let isA = before.map { cal.isDate($0, inSameDayAs: d) } ?? false
                            let isB = after.map { cal.isDate($0, inSameDayAs: d) } ?? false
                            let count: Int = photos.filter { cal.isDate($0.date, inSameDayAs: d) }.count
                            let tag: String = isA ? "Before" : (isB ? "After" : "\(count) photos")
                            Button { after = d } label: {
                                VStack(spacing: 2) {
                                    Text(PadDay.short(d)).font(PadFont.ui(13, .semibold))
                                    Text(tag).font(PadFont.cond(11))
                                }
                                .foregroundColor(isB ? Pad.onVolt : Pad.text)
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(isB ? Pad.volt : (isA ? Pad.raised : Color.clear)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isA || isB ? Color.clear : Pad.line2, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Set as before") { before = d }
                                Button("Set as after") { after = d }
                            }
                            .id(d)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .onAppear { if let a = after { proxy.scrollTo(a, anchor: .trailing) } }
            }
            Menu {
                ForEach(ds, id: \.self) { d in Button(PadDay.short(d)) { before = d } }
            } label: {
                Label(beforeLabel, systemImage: "chevron.down")
                    .font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
            }
            if poses.count > 1 {
                PadSeg(options: poses.map { (id: $0, label: $0) }, selection: $pose)
            }
        }
        .padding(.trailing, 20).padding(.vertical, 10)
    }

    // MARK: Compare

    @ViewBuilder
    private var compare: some View {
        let a = photo(before, pose), b = photo(after, pose)
        if slider, let a, let b {
            VStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        image(a).frame(width: g.size.width, height: g.size.height)
                        image(b).frame(width: g.size.width, height: g.size.height)
                            .mask(HStack(spacing: 0) { Color.clear.frame(width: g.size.width * split); Color.black })
                        Rectangle().fill(Pad.volt).frame(width: 3).offset(x: g.size.width * split - 1.5)
                        Circle().fill(Pad.volt).frame(width: 28, height: 28)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundColor(Pad.onVolt))
                            .offset(x: g.size.width * split - 14, y: g.size.height / 2 - 14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in split = min(max(v.location.x / g.size.width, 0), 1) })
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                HStack {
                    caption(before, "Before"); Spacer(); caption(after, "After")
                }
                .frame(maxWidth: 520)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            HStack(alignment: .top, spacing: 16) {
                side(before, "Before", a)
                side(after, "After", b)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func image(_ p: APIPhoto) -> some View {
        PhotoFill(photo: p.toModel(), url: APIClient.shared.trainerPhotoURL(photoId: p.id))
    }

    private func side(_ day: Date?, _ label: String, _ p: APIPhoto?) -> some View {
        let emptyText: String = day == nil ? "Pick a " + label.lowercased() + " date" : "No " + pose.lowercased() + " photo that day"
        return VStack(alignment: .leading, spacing: 8) {
            if let p {
                image(p)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("\(label): \(p.category) photo, \(PadDay.short(p.date))")
            } else {
                RoundedRectangle(cornerRadius: 14).fill(Pad.well).aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(Text(emptyText).font(PadFont.ui(13)).foregroundColor(Pad.mute))
            }
            caption(day, label)
        }
        .frame(maxWidth: .infinity)
    }

    private func caption(_ day: Date?, _ label: String) -> some View {
        HStack(spacing: 8) {
            PadLab(label, color: Pad.faint, size: 12)
            if let d = day {
                Text(PadDay.short(d)).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                if let w = bodyweight(near: d) { PadLab("\(StatsUnits.weightText(w))") }
            }
        }
    }

    // MARK: Comment

    private func syncComment() { comment = photo(after, pose)?.trainerComment ?? "" }

    private var commentPane: some View {
        let p = photo(after, pose)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your comment").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
            PadLab(p.map { "On the \($0.category.lowercased()) photo, \(PadDay.short($0.date)). \(facts.first) sees it in their app." } ?? "Pick a date with a photo.")
            TextEditor(text: $comment).scrollContentBackground(.hidden).frame(minHeight: 140).padInput(multiline: true).disabled(p == nil)
            Button {
                guard let p else { return }
                saving = true
                let t = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do {
                        try await APIClient.shared.trainerCommentPhoto(photoId: p.id, comment: t)
                        photos = (try? await APIClient.shared.trainerPhotos(clientId: facts.id)) ?? photos
                        PadToasts.shared.show("Comment saved")
                    } catch { PadToasts.shared.show("Couldn’t save the comment. Try again.") }
                    saving = false
                }
            } label: {
                HStack(spacing: 6) { if saving { ProgressView().tint(Pad.onVolt) }; Text("Save comment") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PadButtonStyle(kind: .primary))
            .disabled(p == nil || saving)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Supplements

struct PadClientSupplements: View {
    let facts: PadClientFacts
    @State private var supps: [Supplement] = []
    @State private var stacks: [SupplementStack] = []
    @State private var adherence: APISupplementAdherence?
    @State private var templates: [APISupplementTemplate] = []
    @State private var logs: [SupplementLog] = []
    @State private var loaded = false
    @State private var editing: SupplementDraft?
    @State private var confirmTemplate: APISupplementTemplate?
    @State private var quick: PadQuickMessage?

    private var cal: Calendar { Calendar.training }
    private var days: [Date] {
        let today = cal.startOfDay(for: Date())
        return (0..<28).reversed().map { cal.date(byAdding: .day, value: -$0, to: today) ?? today }
    }

    var body: some View {
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(), notices: notices()) {
                Button { editing = SupplementDraft() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                if !templates.isEmpty {
                    Menu {
                        ForEach(templates) { t in Button("\(t.name) (\(t.itemCount))") { confirmTemplate = t } }
                    } label: {
                        Label("Template", systemImage: "square.stack")
                            .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                            .padding(.horizontal, 13).frame(minHeight: 36)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pad.line2, lineWidth: 1))
                    }
                }
                Button {
                    quick = PadQuickMessage(clientId: facts.id, clientName: facts.name, title: "Supplement nudge",
                                            text: "Quick reminder to tick off your supplements in the app as you take them. Anything making them hard to keep up with?")
                } label: { Label("Nudge", systemImage: "bell") }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                ScrollView([.vertical]) { grid.padding(20) }.frame(maxWidth: .infinity)
                Rectangle().fill(Pad.line).frame(width: 1)
                ScrollView { stackList.padding(16) }.frame(width: 360).background(Pad.page)
            }
        }
        .task { await load() }
        .sheet(item: $editing) { d in
            SupplementEditorSheet(clientId: facts.id, draft: d, stacks: stacks) { Task { await load() } }
        }
        .sheet(item: $quick) { m in PadQuickMessageSheet(message: m) }
        .confirmationDialog("Apply this template?", isPresented: Binding(get: { confirmTemplate != nil }, set: { if !$0 { confirmTemplate = nil } }),
                            titleVisibility: .visible, presenting: confirmTemplate) { t in
            Button("Add its \(t.itemCount) supplements from \(t.name)") {
                let id = facts.id
                Task {
                    do {
                        try await APIClient.shared.applySupplementTemplate(clientId: id, templateId: t.id)
                        PadToasts.shared.show("Applied \(t.name)")
                    } catch { PadToasts.shared.show("Couldn’t apply it. Try again.") }
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        let api = APIClient.shared
        supps = (try? await api.coachSupplements(clientId: facts.id)) ?? supps
        stacks = (try? await api.coachSupplementStacks(clientId: facts.id)) ?? stacks
        adherence = (try? await api.coachSupplementAdherence(clientId: facts.id)) ?? adherence
        templates = (try? await api.supplementTemplates()) ?? templates
        if let v = try? await api.viewAsToken(clientId: facts.id) {
            let l: [SupplementLog]? = try? await api.get("/supplements/logs", token: v.token)
            if let l { logs = l }
        }
        loaded = true
    }

    private var recentLogs: [SupplementLog] {
        let from = days.first ?? Date()
        let to = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return logs.filter { $0.scheduledFor >= from && $0.scheduledFor < to }
    }

    private func isMiss(_ l: SupplementLog) -> Bool {
        l.status == .missed || l.status == .skipped || (l.status == .pending && l.scheduledFor < Date().addingTimeInterval(-6 * 3600))
    }

    // MARK: Headline

    private func stats() -> [PadStat] {
        let active = supps.filter { $0.isActive }
        let worst = adherence?.perSupplement.filter { $0.expected > 0 }.min { $0.rate < $1.rate }
        var takenValue: String = "—"
        var takenSub: String = ""
        if let a = adherence {
            takenValue = "\(Int((a.overallRate * 100).rounded()))"
            takenSub = "\(a.totalTaken) of \(a.totalExpected) doses"
        }
        let streak: Int = adherence?.streakDays ?? 0
        let paused: Int = supps.count - active.count
        var worstValue: String = "—"
        if let w = worst { worstValue = "\(Int((w.rate * 100).rounded()))" }
        var out: [PadStat] = []
        out.append(PadStat(label: "Taken, 30 days", value: takenValue, unit: adherence == nil ? nil : "%", sub: takenSub, warn: (adherence?.overallRate ?? 1) < 0.75))
        out.append(PadStat(label: "Streak", value: "\(streak)", unit: "days", sub: "every dose taken"))
        out.append(PadStat(label: "On protocol", value: "\(active.count)", sub: "\(paused) paused or ended"))
        out.append(PadStat(label: "Most missed", value: worstValue, unit: worst == nil ? nil : "%", sub: worst?.name ?? "nothing missed", warn: (worst?.rate ?? 1) < 0.6))
        return out
    }

    private func notices() -> [PadInsights.Notice] {
        let misses = recentLogs.filter { isMiss($0) }
        guard misses.count >= 3 else { return [] }
        var out: [PadInsights.Notice] = []
        let bySupp = Dictionary(grouping: misses, by: { $0.supplementId })
        if let top = bySupp.max(by: { $0.value.count < $1.value.count }), let s = supps.first(where: { $0.id == top.key }) {
            let weekend = top.value.filter { let d = cal.component(.weekday, from: $0.scheduledFor); return d == 1 || d == 7 }.count
            let evening = top.value.filter { cal.component(.hour, from: $0.scheduledFor) >= 17 }.count
            var when = ""
            if Double(weekend) / Double(top.value.count) >= 0.5 { when = "Mostly at weekends." }
            else if Double(evening) / Double(top.value.count) >= 0.6 { when = "Mostly the evening dose." }
            out.append(.init(icon: "pills", tint: Pad.orange, text: "\(s.name) is missed most: \(top.value.count) times in 4 weeks.", aside: when))
        }
        let low = supps.filter { $0.lowStock }
        if let l = low.first, let q = l.quantityOnHand {
            out.append(.init(icon: "shippingbox", tint: Pad.mute, text: "\(l.name) is running low: \(q) doses left.", aside: l.reorderURL == nil ? "" : "There's a reorder link in their app."))
        }
        return out
    }

    // MARK: Grid

    private var grid: some View {
        let active = supps.filter { $0.isActive }
        let rl = recentLogs
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 28 days").font(PadFont.ui(15, .bold)).foregroundColor(Pad.text)
                Spacer()
                legend(Pad.volt, nil, "On time"); legend(Pad.volt.opacity(0.45), nil, "Late or partly"); legend(nil, Pad.orange, "Missed")
            }
            if active.isEmpty {
                PadEmptyLine(text: loaded ? "No supplements on their protocol. Add one, or apply a template." : "")
            } else if logs.isEmpty && loaded {
                PadEmptyLine(text: "No dose history yet. It fills in as \(facts.first) ticks doses off.")
            }
            ForEach(active) { s in
                HStack(spacing: 8) {
                    Text(s.name).font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text).frame(width: 130, alignment: .leading).lineLimit(1)
                    HStack(spacing: 3) {
                        ForEach(days, id: \.self) { d in cell(rl.filter { $0.supplementId == s.id && cal.isDate($0.scheduledFor, inSameDayAs: d) }) }
                    }
                }
                .frame(height: 22)
            }
            if !active.isEmpty {
                HStack(spacing: 8) {
                    Text("").frame(width: 130)
                    HStack(spacing: 3) {
                        ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                            Text(i % 7 == 0 ? PadDay.short(d) : "").font(PadFont.cond(10)).foregroundColor(Pad.faint).frame(maxWidth: .infinity, alignment: .leading).fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ ls: [SupplementLog]) -> some View {
        let taken = ls.filter { $0.status == .taken }
        let late = taken.contains { t in (t.takenAt ?? t.scheduledFor) > t.scheduledFor.addingTimeInterval(2 * 3600) }
        let missed = ls.contains { isMiss($0) }
        var fill: Color = Color.clear
        if ls.isEmpty { fill = Pad.raised.opacity(0.35) }
        else if taken.count == ls.count { fill = late ? Pad.volt.opacity(0.45) : Pad.volt }
        else if !taken.isEmpty { fill = Pad.volt.opacity(0.45) }
        return RoundedRectangle(cornerRadius: 3).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(missed && taken.isEmpty ? Pad.orange : Color.clear, lineWidth: 1.2))
            .frame(maxWidth: .infinity).frame(height: 18)
    }

    private func legend(_ fill: Color?, _ stroke: Color?, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(fill ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(stroke ?? Color.clear, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
        .padding(.leading, 6)
    }

    // MARK: Stack list

    private var stackList: some View {
        let groups: [(String, [Supplement])] = {
            var out: [(String, [Supplement])] = stacks.map { st in (st.name, supps.filter { $0.stackId == st.id }) }
            out.append((stacks.isEmpty ? "Protocol" : "Not in a stack", supps.filter { s in s.stackId == nil || !stacks.contains { $0.id == s.stackId } }))
            return out.filter { !$0.1.isEmpty }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            if supps.isEmpty && loaded { PadEmptyLine(text: "Nothing on their protocol yet.") }
            ForEach(groups, id: \.0) { g in
                VStack(alignment: .leading, spacing: 6) {
                    PadLab(g.0, color: Pad.faint, size: 12)
                    ForEach(g.1) { s in suppRow(s) }
                }
            }
        }
    }

    private func suppRow(_ s: Supplement) -> some View {
        let r = adherence?.perSupplement.first { $0.supplementId == s.id }
        let pct: Double? = r.flatMap { $0.expected > 0 ? $0.rate : nil }
        var detail: String = s.timing.summary
        if let i = s.instructions, !i.isEmpty { detail += " · " + i }
        return Button { editing = SupplementDraft(s) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(s.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                    if s.isPrescription { PadTag(text: "Rx", kind: .line) }
                    if s.isOwn { PadTag(text: "Their own", kind: .line) }
                    Spacer(minLength: 4)
                    Text(s.dose.display).font(PadFont.cond(12)).foregroundColor(Pad.mute)
                }
                Text(detail).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(2)
                if let pct {
                    HStack(spacing: 8) {
                        PadBar(fraction: pct).frame(width: 120)
                        PadLab("\(Int((pct * 100).rounded()))% · 30 days", color: pct < 0.75 ? Pad.orange : Pad.mute, size: 11)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
            .opacity(s.isActive ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - Macros

struct PadClientMacros: View {
    let facts: PadClientFacts
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @ObservedObject private var coach = CoachData.shared
    @State private var days: [APIMacroDay] = []
    @State private var plan: APIPlanAdjustments?
    @State private var loading = true
    @State private var failed = false
    @State private var tP = ""
    @State private var tC = ""
    @State private var tF = ""
    @State private var rP = ""
    @State private var rC = ""
    @State private var rF = ""
    @State private var start = Calendar.training.date(byAdding: .day, value: 1, to: Calendar.training.startOfDay(for: Date())) ?? Date()
    @State private var length = 14
    @State private var saving = false

    private var cal: Calendar { Calendar.training }
    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.training; f.timeZone = Calendar.training.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            PadSectionTop(stats: stats(), notices: notices()) { EmptyView() }
            PadRule()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        weekGrid
                        trendPane
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(Pad.line).frame(width: 1)
                ScrollView { editor.padding(16) }.frame(width: 340).background(Pad.page)
            }
        }
        .task { await load(); await coach.loadCheckIns(facts.id) }
    }

    private func load() async {
        do {
            let v = try await APIClient.shared.viewAsToken(clientId: facts.id)
            let ds: [APIMacroDay] = try await APIClient.shared.get("/macros", token: v.token)
            days = ds
            prefill()
            loading = false
        } catch {
            loading = false; failed = true
        }
        plan = try? await APIClient.shared.trainerClientPlan(clientId: facts.id)
    }

    private func prefill() {
        let upcoming = days.filter { $0.date >= cal.startOfDay(for: Date()) }.sorted { $0.date < $1.date }
        if tP.isEmpty, let t = upcoming.first(where: { $0.isTrainingDay }) ?? days.last(where: { $0.isTrainingDay }) {
            tP = "\(t.proteinGoal)"; tC = "\(t.carbGoal)"; tF = "\(t.fatGoal)"
        }
        if rP.isEmpty, let r = upcoming.first(where: { !$0.isTrainingDay }) ?? days.last(where: { !$0.isTrainingDay }) {
            rP = "\(r.proteinGoal)"; rC = "\(r.carbGoal)"; rF = "\(r.fatGoal)"
        }
    }

    private func day(_ d: Date) -> APIMacroDay? { days.first { cal.isDate($0.date, inSameDayAs: d) } }

    private func bump(_ d: Date) -> (Int, String)? {
        guard let p = plan else { return nil }
        let key = Self.dayKey.string(from: d)
        let acts = p.activities.filter { $0.day == key && $0.addToTarget }
        var kcal: Int = 0
        for a in acts { kcal += Int((Double(a.reportedKcal ?? 0) * (1 + a.adjustPct)).rounded()) }
        guard kcal > 0 else { return nil }
        return (kcal, acts.map { $0.type.capitalized }.joined(separator: ", "))
    }

    private func checkInScores(_ word: String) -> [Double] {
        (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" }.sorted { $0.date < $1.date }.suffix(8)
            .compactMap { c in c.fields.first { $0.cleanLabel.lowercased().contains(word) }.flatMap { Double($0.value) } }
    }

    private var bodyweights: [(Date, Double)] {
        let since = cal.date(byAdding: .day, value: -35, to: Date()) ?? Date()
        return (coach.checkIns[facts.id] ?? []).filter { $0.status != "draft" && $0.date >= since }
            .compactMap { c in PadInsights.bodyweight(c).map { (c.date, $0) } }.sorted { $0.0 < $1.0 }
    }

    /// lb per week over the last ~5 weeks of check-ins.
    private var weightRate: Double? {
        let bw = bodyweights
        guard bw.count >= 2, let a = bw.first, let b = bw.last else { return nil }
        let wks = max(b.0.timeIntervalSince(a.0) / (7 * 86_400), 1)
        return (b.1 - a.1) / wks
    }

    private var avgKcal: Int? {
        let since = cal.date(byAdding: .day, value: -28, to: Date()) ?? Date()
        let ks = days.filter { $0.date >= since && $0.date <= Date() }.map { $0.calorieGoal }
        return ks.isEmpty ? nil : ks.reduce(0, +) / ks.count
    }

    // MARK: Headline

    private func stats() -> [PadStat] {
        let today = day(Date())
        var todayValue: String = "—"
        var todaySub: String = loading ? "" : "no target set"
        if let t = today {
            todayValue = "\(t.calorieGoal)"
            todaySub = (t.isTrainingDay ? "training" : "rest") + " day · \(t.proteinGoal) g protein"
        }
        var out: [PadStat] = []
        out.append(PadStat(label: "Today", value: todayValue, unit: today == nil ? nil : "kcal", sub: todaySub))
        if let r = weightRate {
            let w = StatsUnits.weight(r)
            out.append(PadStat(label: "Bodyweight", value: "\(w >= 0 ? "+" : "−")\(abs(w).padShort)", unit: "\(StatsUnits.weightLabel)/wk", sub: avgKcal.map { "on about \($0) kcal" } ?? "last 5 weeks"))
        }
        let n = checkInScores("nutrition")
        if let last = n.last { out.append(PadStat(label: "Nutrition score", value: last.padShort, unit: "/10", sub: n.count >= 2 ? "was \(n[n.count - 2].padShort)" : "latest check-in", warn: last <= 5)) }
        let h = checkInScores("hunger")
        if let last = h.last { out.append(PadStat(label: "Hunger", value: last.padShort, unit: "/10", sub: h.count >= 2 ? "was \(h[h.count - 2].padShort)" : "latest check-in", warn: last >= 7)) }
        return out
    }

    private func notices() -> [PadInsights.Notice] {
        var out: [PadInsights.Notice] = []
        if let r = weightRate, let k = avgKcal {
            let w = StatsUnits.weight(r)
            var verb: String = "Holding steady"
            if abs(w) >= 0.15 { verb = (w < 0 ? "Losing " : "Gaining ") + abs(w).padShort + " " + StatsUnits.weightLabel + " a week" }
            out.append(PadInsights.Notice(icon: "scalemass", tint: Pad.mute, text: verb + " on about \(k) kcal.", aside: "Does that match " + facts.first + "'s goal?"))
        }
        let h = checkInScores("hunger")
        if h.count >= 3, h[h.count - 1] - h[h.count - 3] >= 2 {
            out.append(.init(icon: "fork.knife", tint: Pad.orange, text: "Hunger is climbing: \(h[h.count - 3].padShort) → \(h[h.count - 1].padShort) over 3 check-ins.",
                             aside: "More protein or fibre, or a small carb bump on training days."))
        }
        let week = (0..<7).map { cal.date(byAdding: .day, value: $0, to: cal.startOfWeek(for: Date())) ?? Date() }
        let bumps = week.compactMap { d in bump(d).map { (d, $0) } }
        if !bumps.isEmpty {
            let total = bumps.reduce(0) { $0 + $1.1.0 }
            out.append(.init(icon: "figure.run", tint: Pad.mute, text: "+\(total) kcal added this week for activity (\(bumps.map { $0.1.1 }.joined(separator: ", "))).", aside: ""))
        }
        return out
    }

    // MARK: Two weeks of targets

    private var weekGrid: some View {
        let start = cal.startOfWeek(for: Date())
        let ds = (0..<14).map { cal.date(byAdding: .day, value: $0, to: start) ?? start }
        return PadPane(title: "Targets, this week and next", aside: "activity bumps in the accent") {
            if loading { PadSkeleton(height: 90) }
            if failed { Text("Couldn’t load \(facts.first)’s macros.").font(PadFont.ui(14)).foregroundColor(Pad.orange) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(ds, id: \.self) { d in dayCard(d) }
            }
        }
    }

    private func dayCard(_ d: Date) -> some View {
        let m = day(d)
        let isToday = cal.isDateInToday(d)
        let b = bump(d)
        return VStack(alignment: .leading, spacing: 3) {
            Text(isToday ? "Today" : d.formatted(.dateTime.weekday(.abbreviated).day())).font(PadFont.cond(12)).foregroundColor(isToday ? Pad.text : Pad.mute)
            if let m {
                Text(m.isTrainingDay ? "Training" : "Rest").font(PadFont.cond(11)).foregroundColor(m.isTrainingDay ? Pad.voltText : Pad.faint)
                Text("\(m.calorieGoal + (b?.0 ?? 0))").font(PadFont.display(20)).foregroundColor(Pad.text)
                Text("\(m.proteinGoal)P \(m.carbGoal)C \(m.fatGoal)F").font(PadFont.cond(11)).foregroundColor(Pad.mute).lineLimit(1).minimumScaleFactor(0.8)
                if let b { Text("+\(b.0) \(b.1)").font(PadFont.cond(11)).foregroundColor(Pad.voltText).lineLimit(1) }
            } else {
                Text("—").font(PadFont.display(20)).foregroundColor(Pad.faint)
                Text("no target").font(PadFont.cond(11)).foregroundColor(Pad.faint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isToday ? Pad.raised : Pad.well))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isToday ? Pad.volt : Color.clear, lineWidth: 1.2))
        .opacity(d < cal.startOfDay(for: Date()) ? 0.6 : 1)
    }

    private var trendPane: some View {
        let bw = bodyweights
        let n = checkInScores("nutrition"), h = checkInScores("hunger")
        return HStack(alignment: .top, spacing: 12) {
            PadPane(title: "Bodyweight", aside: "5 weeks of check-ins") {
                if bw.count >= 2 { PadLineChart(points: bw.map { StatsUnits.weight($0.1) }).frame(height: 80) }
                else { PadEmptyLine(text: "Needs two check-ins with bodyweight.") }
            }
            PadPane(title: "Check-in scores", aside: "last 8") {
                if n.count >= 2 {
                    PadLab("Nutrition, now \(n.last!.padShort)/10", size: 12)
                    PadLineChart(points: n).frame(height: 34)
                }
                if h.count >= 2 {
                    PadLab("Hunger, now \(h.last!.padShort)/10", size: 12)
                    PadLineChart(points: h, color: Pad.orange).frame(height: 34)
                }
                if n.count < 2 && h.count < 2 { PadEmptyLine(text: "Their check-in form has no nutrition or hunger score yet.") }
            }
        }
    }

    // MARK: New targets

    private func kcal(_ p: String, _ c: String, _ f: String) -> Int? {
        guard let p = Int(p), let c = Int(c), let f = Int(f) else { return nil }
        return p * 4 + c * 4 + f * 9
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New targets").font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
                Spacer()
                Menu {
                    Button("Cut") { preset(12) }
                    Button("Maintain") { preset(14) }
                    Button("Build") { preset(16) }
                } label: {
                    Label("Preset", systemImage: "wand.and.stars").font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                        .padding(.horizontal, 10).frame(minHeight: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pad.line2, lineWidth: 1))
                }
            }
            row("Training days", $tP, $tC, $tF)
            row("Rest days", $rP, $rC, $rF)
            PadLab("Presets use their latest bodyweight: protein 1 g/lb, fat 0.35 g/lb, carbs fill the rest. Rest days carry 25% fewer carbs.", size: 12)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Starts", selection: $start, in: cal.startOfDay(for: Date())..., displayedComponents: .date).tint(Pad.voltText)
                .font(PadFont.ui(14)).foregroundColor(Pad.text)
            HStack {
                PadLab("For")
                PadSeg(options: [(id: 14, label: "2 weeks"), (id: 28, label: "4 weeks")], selection: $length)
            }
            Button {
                save()
            } label: {
                HStack(spacing: 6) { if saving { ProgressView().tint(Pad.onVolt) }; Text("Set targets") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PadButtonStyle(kind: .primary))
            .disabled(saving || kcal(tP, tC, tF) == nil || kcal(rP, rC, rF) == nil)
            PadLab("Training days follow their planned sessions.", color: Pad.faint, size: 12)
        }
    }

    private func row(_ label: String, _ p: Binding<String>, _ c: Binding<String>, _ f: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                Spacer()
                PadLab(kcal(p.wrappedValue, c.wrappedValue, f.wrappedValue).map { "\($0) kcal" } ?? "")
            }
            HStack(spacing: 6) { field("P", p); field("C", c); field("F", f) }
        }
    }

    private func field(_ l: String, _ b: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField(l, text: b).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            Text("g \(l)").font(PadFont.cond(12)).foregroundColor(Pad.faint)
        }
        .padInput()
    }

    private func preset(_ kcalPerLb: Double) {
        let lb = bodyweights.last?.1 ?? (coach.checkIns[facts.id] ?? []).compactMap { PadInsights.bodyweight($0) }.last ?? 170
        let p = Int((lb * 1.0).rounded()), f = Int((lb * 0.35).rounded())
        let total = lb * kcalPerLb
        let c = max(Int(((total - Double(p * 4 + f * 9)) / 4).rounded()), 50)
        tP = "\(p)"; tF = "\(f)"; tC = "\(c)"
        rP = "\(p)"; rF = "\(f)"; rC = "\(Int((Double(c) * 0.75).rounded()))"
    }

    private func save() {
        guard let tk = kcal(tP, tC, tF), let rk = kcal(rP, rC, rF),
              let tp = Int(tP), let tc = Int(tC), let tf = Int(tF), let rp = Int(rP), let rc = Int(rC), let rf = Int(rF) else { return }
        saving = true
        let sessions = data.sessions(client: facts.client)
        let first = cal.startOfDay(for: start), n = length, id = facts.id
        Task {
            var bad = 0
            for i in 0..<n {
                let d = cal.date(byAdding: .day, value: i, to: first) ?? first
                let training = sessions.contains { cal.isDate($0.day, inSameDayAs: d) }
                do {
                    if training { try await APIClient.shared.trainerSetMacros(clientId: id, day: d, training: true, kcal: tk, protein: tp, carbs: tc, fat: tf) }
                    else { try await APIClient.shared.trainerSetMacros(clientId: id, day: d, training: false, kcal: rk, protein: rp, carbs: rc, fat: rf) }
                } catch { bad += 1 }
            }
            await load()
            saving = false
            PadToasts.shared.show(bad == 0 ? "New targets for \(facts.first) from \(PadDay.short(first))" : "Couldn’t save \(bad.plural("day")). Try again.")
        }
    }
}
