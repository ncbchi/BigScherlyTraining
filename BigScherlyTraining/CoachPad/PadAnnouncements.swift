import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Announcements (round 3, Oct 9, 2026)
//
// Write once, choose who by what's true about them: everyone, on a program, missed this week, new, or
// people you pick. Posted and scheduled ones are listed with Reuse and Delete.
// Server 2.3.0 (Oct 11): a group gets a real announcement on just their Home (it can be scheduled too),
// and every post shows who has read it: "Read 5 of 6 · Dev hasn't opened it". Anyone who's missed the
// last two gets a note with Message, which sends the latest to them as a chat message instead.
// On a server before 2.3.0 a group still goes as a message to each of them, as before.
// Synchronized folder: no target step needed.

struct PadAnnouncementsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padSideBySide) private var sideBySide

    enum Audience: String, CaseIterable, Identifiable {
        case everyone, program, missed, new, pick
        var id: String { rawValue }
        var name: String {
            switch self {
            case .everyone: return "Everyone"
            case .program: return "On a program"
            case .missed: return "Missed this week"
            case .new: return "New"
            case .pick: return "Picked"
            }
        }
    }

    @State private var audience: Audience = .everyone
    @State private var picked: Set<String> = []
    @State private var picking = false
    @State private var title = ""
    @State private var text = ""
    @State private var schedule = false
    @State private var publishAt: Date = PadAnnouncementsView.nextMorning()
    @State private var posted: [APIAdminAnnouncement] = []
    @State private var loaded = false
    @State private var sending = false
    @State private var failed: String?
    @State private var deleting: APIAdminAnnouncement?
    /// Server 2.3.0: groups get real announcements, and reads are kept.
    @State private var v23 = false
    @State private var nudging: Nudge?
    /// Send a push notification with it (server 2.7.1, Oct 15, 2026). Off = Home and Announcements only.
    @State private var push = true

    struct Person: Identifiable {
        let id: String
        let name: String
    }

    struct Nudge: Identifiable {
        let clientId: String
        let name: String
        let announcement: APIAdminAnnouncement
        var id: String { clientId + announcement.id }
    }

    private var cal: Calendar { Calendar.training }

    static func nextMorning() -> Date {
        let cal = Calendar.training
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Announcements", subtitle: subtitle, compact: true, facts: PadFact.from(strip), notes: notes) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sideBySide {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 12) { composer; previewPane }.frame(maxWidth: .infinity)
                            VStack(spacing: 12) { unreadPane; scheduledPane; postedPane }.frame(width: 420)
                        }
                        .padding(20)
                    } else {
                        VStack(spacing: 12) { composer; previewPane; unreadPane; scheduledPane; postedPane }.padding(20)
                    }
                }
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $picking) { PadPeoplePicker(picked: $picked) }
        .confirmationDialog("Delete this announcement?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { a in
            Button("Delete “\(a.title)”", role: .destructive) { delete(a) }
        } message: { a in
            Text(a.isEveryone ? "It comes off everyone's Home." : "It comes off their Home.")
        }
        .confirmationDialog("Send it as a message?", isPresented: Binding(get: { nudging != nil }, set: { if !$0 { nudging = nil } }),
                            titleVisibility: .visible, presenting: nudging) { n in
            Button("Message \(n.name)") { message(n) }
        } message: { n in
            Text("“\(n.announcement.title)” goes to \(n.name)'s chat, so it's harder to miss.")
        }
    }

    private var subtitle: String {
        v23 ? "Posts on their Home: everyone, or the group you pick. You see who's read it."
            : "Posts on everyone's Home. Or pick a group, and it goes to them as a message."
    }

    // MARK: Who

    private func members(_ a: Audience) -> [RosterItem] {
        let start = cal.startOfWeek(for: Date())
        switch a {
        case .everyone: return store.roster
        case .program:
            let ids = Set(data.assignments.filter { $0.status.lowercased() != "ended" && $0.endDate >= cal.startOfDay(for: Date()) }.map { $0.clientId })
            return store.roster.filter { ids.contains($0.id) }
        case .missed:
            let ids = Set(data.sessions(for: store.roster).filter { $0.day >= start && $0.isMissed }.map { $0.clientId })
            return store.roster.filter { ids.contains($0.id) }
        case .new:
            return store.roster.filter { c in
                let first = data.sessions(client: c).map { $0.day }.min()
                return first.map { PadDay.daysAgo($0) < 28 } ?? true
            }
        case .pick:
            return store.roster.filter { picked.contains($0.id) }
        }
    }

    private func label(_ a: Audience) -> String {
        let n = members(a).count
        switch a {
        case .pick: return picked.isEmpty ? "Pick people…" : "Picked · \(n)"
        default: return "\(a.name) · \(n)"
        }
    }

    private func first(_ id: String) -> String? { store.roster.first { $0.id == id }?.name.firstName }

    // MARK: Reads

    private var sent: [APIAdminAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) <= Date() }.sorted { $0.createdAt > $1.createdAt } }
    private var queued: [APIAdminAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) > Date() }.sorted { ($0.publishAt ?? Date()) < ($1.publishAt ?? Date()) } }

    /// The first read the server ever kept. Posts from before then (with no reads) weren't tracked.
    private var trackedSince: Date? { posted.flatMap { $0.reads ?? [] }.map { $0.readAt }.min() }

    private func tracked(_ a: APIAdminAnnouncement) -> Bool {
        guard v23, a.hasReceipts, !(a.audienceIds ?? []).isEmpty else { return false }
        if !(a.reads ?? []).isEmpty { return true }
        guard let since = trackedSince else { return a.createdAt >= installSeen }
        return a.createdAt >= since.addingTimeInterval(-86400 * 2)
    }

    /// When this iPad first saw server 2.3.0: posts after it are tracked even before anyone has read one.
    private var installSeen: Date {
        let key = "bst_pad_v23_seen"
        if let d = UserDefaults.standard.object(forKey: key) as? Date { return d }
        return .distantFuture
    }

    private func readLine(_ a: APIAdminAnnouncement) -> String? {
        guard tracked(a) else { return nil }
        let to = a.audienceIds ?? []
        let read = to.filter { a.readIds.contains($0) }.count
        return "read by \(read) of \(to.count)"
    }

    /// Clients who were sent both of the last two tracked posts and opened neither.
    private var missedTwo: [Person] {
        let list = sent.filter { tracked($0) }.prefix(2)
        guard list.count == 2, let newest = list.first, Date().timeIntervalSince(newest.createdAt) > 86400 else { return [] }
        let a = Set(list[list.startIndex].unreadIds), b = Set(list[list.startIndex + 1].unreadIds)
        return a.intersection(b).compactMap { id in first(id).map { Person(id: id, name: $0) } }.sorted { $0.name < $1.name }
    }

    // MARK: Strip

    private var strip: [PadStat] {
        let last = sent.first
        let since90 = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let count90 = sent.filter { $0.createdAt >= since90 }.count
        let next: String = queued.first?.publishAt.map { Self.when($0) } ?? "nothing queued"
        var out = [
            PadStat(label: "Last posted", value: last.map { PadDay.short($0.createdAt) } ?? "—", sub: last.map { "“\($0.title)”" } ?? "nothing yet"),
        ]
        if let last, tracked(last) {
            let to = last.audienceIds ?? []
            let unread = last.unreadIds
            let names = unread.compactMap { first($0) }
            let sub: String = unread.isEmpty ? "everyone's opened it"
                : (names.count == 1 ? "\(names[0]) hasn't opened it" : "\(unread.count) haven't opened it")
            out.append(PadStat(label: "Read", value: "\(to.count - unread.count)", unit: "of \(to.count)", sub: sub,
                               warn: !unread.isEmpty && Date().timeIntervalSince(last.createdAt) > 2 * 86400, good: unread.isEmpty))
        }
        out.append(PadStat(label: "Scheduled", value: "\(queued.count)", sub: next))
        out.append(PadStat(label: "Posted, 90 days", value: "\(count90)", sub: v23 ? "" : "to everyone"))
        return out
    }

    private var notes: [PadNote] {
        guard loaded else { return [] }
        var out: [PadNote] = []
        if let latest = sent.first(where: { tracked($0) }) {
            for p in missedTwo.prefix(2) {
                let n = Nudge(clientId: p.id, name: p.name, announcement: latest)
                out.append(PadNote(icon: "envelope.badge", tint: Pad.orange, text: "\(p.name) hasn't opened the last two.",
                                   aside: "Send it as a message instead?", go: "Message", run: { nudging = n }))
            }
        }
        if let last = sent.first {
            let days = PadDay.daysAgo(last.createdAt)
            if days >= 21 && queued.isEmpty {
                out.append(PadNote(icon: "megaphone.fill", tint: Pad.mute, text: "Nothing posted in \(days) days.", aside: "A short weekly note keeps Home feeling alive."))
            }
        }
        return out
    }

    static func when(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + d.padClock
    }

    // MARK: Composer

    private var isGroup: Bool { audience != .everyone }
    /// Before 2.3.0 a group can only be reached by messages.
    private var asMessages: Bool { isGroup && !v23 }
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTitle = !title.trimmingCharacters(in: .whitespaces).isEmpty
        return hasText && (asMessages || hasTitle) && (!isGroup || !members(audience).isEmpty) && !sending
    }
    private var sendLabel: String {
        let n = members(audience).count
        let people: String = n == 1 ? "1 person" : "\(n) people"
        if asMessages { return "Message \(people)" }
        if schedule { return "Schedule" }
        return isGroup ? "Post to \(people)" : "Post to everyone"
    }

    private var composer: some View {
        PadPane(title: "New announcement") {
            PadLab("Who", size: 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Audience.allCases) { a in
                        PadChip(text: label(a), on: audience == a) {
                            audience = a
                            if a == .pick { picking = true }
                            if asMessages { schedule = false }
                        }
                    }
                }
            }
            if isGroup {
                let names = members(audience).prefix(6).map { $0.name.firstName }.joined(separator: ", ")
                let more: String = members(audience).count > 6 ? " and \(members(audience).count - 6) more" : ""
                let how: String = asMessages ? "Goes as a message to \(names)\(more). Announcements to a group need server 2.3.0."
                                             : "Goes on the Home of \(names)\(more). Nobody else sees it."
                PadLab(names.isEmpty ? "Nobody in this group right now." : how, color: Pad.mute, size: 12)
            }
            TextField(asMessages ? "Title (optional, goes first in bold)" : "Title", text: $title).padInput()
            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 160).padInput(multiline: true)
            if !asMessages {
                Toggle(isOn: $push) { Text("Send a push notification").font(PadFont.ui(15)).foregroundColor(Pad.text) }
                    .tint(Pad.volt)
                if !push {
                    PadLab("Off: it shows on their Home and in Announcements without a notification.", size: 12)
                }
            }
            if let failed { Text(failed).font(PadFont.ui(13)).foregroundColor(Pad.orange) }
            HStack(spacing: 10) {
                Toggle("", isOn: $schedule).labelsHidden().tint(Pad.volt).disabled(asMessages)
                if schedule && !asMessages {
                    DatePicker("", selection: $publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                } else {
                    Text(asMessages ? "Messages go now" : "Schedule for later").font(PadFont.ui(14)).foregroundColor(Pad.mute)
                }
                Spacer()
                Button { send() } label: {
                    HStack(spacing: 6) { if sending { ProgressView().tint(Pad.onVolt) }; Text(sendLabel) }
                }
                .buttonStyle(PadButtonStyle(kind: .primary))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var previewPane: some View {
        let t: String = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Your title" : title
        let b: String = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "What you write shows here, the way it reads on their phone." : text
        return PadPane(title: "Preview", aside: asMessages ? "as a message" : "on their Home") {
            VStack(alignment: .leading, spacing: 6) {
                if asMessages {
                    Text(messageBody(title: title, body: b)).font(PadFont.ui(14)).foregroundColor(Pad.isLight ? .white : Pad.ink)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Pad.isLight ? Pad.ink : Pad.chalk))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "megaphone.fill").font(.system(size: 12, weight: .bold)).foregroundColor(Pad.voltText)
                        PadLab("FROM YOUR COACH", color: Pad.voltText, size: 11)
                    }
                    Text(t).font(PadFont.display(22)).foregroundColor(Pad.text)
                    Text(b).font(PadFont.ui(14)).foregroundColor(Pad.mute).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Pad.well))
        }
    }

    private func messageBody(title: String, body: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? body : "\(t)\n\n\(body)"
    }

    // MARK: Lists

    /// Who hasn't opened the latest post (2.3.0).
    @ViewBuilder private var unreadPane: some View {
        if let last = sent.first, tracked(last) {
            let rows: [Person] = last.unreadIds.compactMap { id in
                store.roster.first { $0.id == id }.map { Person(id: id, name: $0.name) }
            }.sorted { $0.name < $1.name }
            let two = Set(missedTwo.map { $0.id })
            PadPane(title: "Hasn't read the last one", aside: "“\(last.title)”") {
                if rows.isEmpty {
                    PadEmptyLine(text: "Everyone it went to has opened it.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { PadRule() }
                            let detail: String = two.contains(r.id) ? "missed 2 in a row" : "posted \(PadDay.agoText(last.createdAt))"
                            PadPaneRow(name: r.name, ring: two.contains(r.id), title: r.name, detail: detail) {
                                Button("Message") { nudging = Nudge(clientId: r.id, name: r.name.firstName, announcement: last) }
                                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                            }
                        }
                    }
                    PadLab("Opening it on their Home, in Announcements, or clearing it counts. Reads come from the latest app.", color: Pad.faint, size: 12)
                }
            }
        }
    }

    private var scheduledPane: some View {
        PadPane(title: "Scheduled") {
            if queued.isEmpty {
                PadEmptyLine(text: loaded ? "Nothing scheduled." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { PadRule() }
                        PadPaneRow(title: a.title, detail: a.publishAt.map { "\(who(a)) · goes out \(Self.when($0))" } ?? who(a)) {
                            Button("Cancel") { deleting = a }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                        }
                    }
                }
            }
        }
    }

    /// "Everyone", "On a program · 4", "Picked · 2".
    private func who(_ a: APIAdminAnnouncement) -> String {
        guard let aud = a.audience else { return "Everyone" }
        return "\(a.audienceLabel ?? "Picked") · \(aud.count)"
    }

    private var postedPane: some View {
        PadPane(title: "Posted", aside: v23 ? "who it went to · who's read it" : "to everyone") {
            if !loaded {
                PadSkeleton(height: 44)
            } else if sent.isEmpty {
                PadEmptyLine(text: "Nothing posted yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sent.prefix(15).enumerated()), id: \.element.id) { i, a in
                        if i > 0 { PadRule() }
                        let parts: [String] = [PadDay.short(a.createdAt), v23 ? who(a) : nil, readLine(a)].compactMap { $0 }
                        PadPaneRow(title: a.title, detail: parts.joined(separator: " · ") + "\n" + a.body) {
                            Button("Reuse") { reuse(a) }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                        }
                        .contextMenu {
                            Button { reuse(a) } label: { Label("Reuse", systemImage: "arrow.uturn.left") }
                            Button(role: .destructive) { deleting = a } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    // MARK: Doing it

    private func load() async {
        guard store.isLive else { loaded = true; return }
        v23 = await ServerVersion.has23()
        if v23, UserDefaults.standard.object(forKey: "bst_pad_v23_seen") == nil {
            UserDefaults.standard.set(Date(), forKey: "bst_pad_v23_seen")
        }
        if let a = try? await APIClient.shared.adminAnnouncementsWithReads() { posted = a }
        loaded = true
    }

    private func reuse(_ a: APIAdminAnnouncement) {
        title = a.title
        text = a.body
        if let aud = a.audience, v23 {
            picked = Set(aud)
            audience = .pick
        } else {
            audience = .everyone
        }
        push = true
        PadToasts.shared.show("Copied into New announcement")
    }

    private func delete(_ a: APIAdminAnnouncement) {
        Task {
            do {
                try await APIClient.shared.deleteAnnouncement(id: a.id)
                posted.removeAll { $0.id == a.id }
                PadToasts.shared.show("Deleted")
            } catch {
                PadToasts.shared.show("Couldn't delete. Try again.")
            }
        }
    }

    private func message(_ n: Nudge) {
        let body = messageBody(title: n.announcement.title, body: n.announcement.body)
        Task {
            do {
                try await CoachMessenger.send(body, to: n.clientId)
                PadToasts.shared.show("Sent to \(n.name)")
            } catch {
                PadToasts.shared.show("Couldn't send. Try again.")
            }
        }
    }

    private func send() {
        failed = nil
        sending = true
        let t = title.trimmingCharacters(in: .whitespaces)
        let b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if asMessages {
            let ids = members(audience).map { $0.id }
            let body = messageBody(title: t, body: b)
            Task {
                var bad = 0
                for id in ids { do { try await CoachMessenger.send(body, to: id) } catch { bad += 1 } }
                sending = false
                if bad == 0 {
                    PadToasts.shared.show("Sent to \(ids.count.plural("client"))")
                    title = ""; text = ""
                } else {
                    failed = "\(bad) didn't send. Check your connection and try again."
                }
            }
            return
        }
        let at: Date? = schedule ? publishAt : nil
        let ids: [String]? = isGroup ? members(audience).map { $0.id } : nil
        let groupLabel: String? = isGroup ? audience.name : nil
        let sendPush = push
        Task {
            do {
                if ids != nil {
                    // Re-check: a group must never go out on a server that would post it to everyone.
                    guard await ServerVersion.has23() else {
                        sending = false
                        v23 = false
                        failed = "Your server isn't on 2.3.0, so a group can't get an announcement. It can go as messages instead."
                        return
                    }
                    try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at, clientIds: ids, audienceLabel: groupLabel, push: sendPush)
                } else {
                    try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at, push: sendPush)
                }
                sending = false
                let whom: String = ids.map { $0.count == 1 ? "1 person's Home" : "\($0.count) people's Homes" } ?? "everyone's Home"
                PadToasts.shared.show(at == nil ? "Posted to \(whom)" : "Scheduled for \(Self.when(at ?? Date()))")
                title = ""; text = ""; schedule = false; push = true
                await load()
            } catch {
                sending = false
                failed = "Couldn't post. Check your connection and try again."
            }
        }
    }
}

// MARK: - Pick people

struct PadPeoplePicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var picked: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pick people").font(PadFont.display(28)).foregroundColor(Pad.text)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PadButtonStyle(kind: .primary, small: true)).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            PadRule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.roster.sorted { $0.name < $1.name }) { c in
                        Button {
                            if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                        } label: {
                            HStack(spacing: 12) {
                                PadAvatar(name: c.name, size: 32, id: c.id)
                                Text(c.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                Spacer()
                                Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20)).foregroundColor(picked.contains(c.id) ? Pad.voltText : Pad.faint)
                            }
                            .padding(.horizontal, 20).frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverEffect(.highlight)
                    }
                }
            }
        }
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}
