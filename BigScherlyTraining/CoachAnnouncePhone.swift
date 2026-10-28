import SwiftUI

// MARK: - Phone ▸ COMMUNICATIONS ▸ Announcements (Oct 15, 2026)
//
// Canvas "Announcements · 1 — iPhone, pick who" and "· 2 — Who's read it". Was Everyone only; now the
// same choices as the iPad and Coach HQ: Everyone, On a program, Missed this week, New, or people you
// pick. Server 2.3.0 puts a group's announcement on just their Home (it can be scheduled too) and keeps
// who has read each one: "Read by 4 of 6". Anyone who missed the last one gets Message, which sends it
// to their chat instead. On a server before 2.3.0 a group goes as a chat message to each of them, so it
// can never land on everyone's Home by mistake. (Moved here from Screens/TrainerSections.swift.)
// Synchronized folder: no target step needed.

struct AnnouncementsComposerView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared

    enum Audience: String, CaseIterable, Hashable {
        case everyone, program, missed, new, pick
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

    enum When: String, CaseIterable, Hashable { case now = "Post now", later = "Schedule" }

    @State private var audience: Audience = .everyone
    @State private var picked: Set<String> = []
    @State private var picking = false
    @State private var title = ""
    @State private var messageBody = ""
    @State private var when: When = .now
    @State private var publishAt: Date = AnnouncementsComposerView.nextMorning()
    /// Send a push notification with it (server 2.7.1; Nick, Oct 15). Off = Home and Announcements only.
    @State private var push = true
    @State private var posted: [APIAdminAnnouncement] = []
    @State private var loading = true
    @State private var v23 = false
    @State private var posting = false
    @State private var note: String?
    @State private var failed: String?
    @State private var confirmDelete: APIAdminAnnouncement?
    @State private var nudging: Nudge?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DSScreenHeader(eyebrow: "Communications", title: "Announcements",
                               subtitle: v23 ? "Posts on their Home: everyone, or the people you pick. You see who's read it."
                                             : "Posts on everyone's Home. Pick a group and it goes to them as a message.")
                composer
                if !title.isEmpty || !messageBody.isEmpty { preview }
                unreadCard
                if !queued.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DSSectionHeader(title: "SCHEDULED", subtitle: "\(queued.count) waiting")
                        ForEach(queued, id: \.id) { a in card(a) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    DSSectionHeader(title: "POSTED", subtitle: v23 ? "who it went to · who's read it" : nil)
                    if loading { ProgressView().tint(Brand.volt).frame(maxWidth: .infinity) }
                    else if sent.isEmpty { Text("Nothing posted yet.").font(BrandFont.body(13)).foregroundColor(Brand.mute) }
                    ForEach(sent.prefix(20), id: \.id) { a in card(a) }
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .task { await load() }
        .refreshable { await load() }
        .tapToDismissKeyboard()
        .keyboardDoneButton()
        .sheet(isPresented: $picking) { PhonePeoplePicker(picked: $picked).environmentObject(store) }
        .onChange(of: audience) { _, a in
            if a == .pick && picked.isEmpty { picking = true }
            if asMessages { when = .now }
        }
        .confirmationDialog("Delete this announcement?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { a in
            Button("Delete “\(a.title)”", role: .destructive) { remove(a) }
        } message: { a in
            Text(a.publishAt.map { $0 > Date() } == true ? "It won't go out." : (a.isEveryone ? "It comes off everyone's Home." : "It comes off their Home."))
        }
        .confirmationDialog("Send it as a message?", isPresented: Binding(get: { nudging != nil }, set: { if !$0 { nudging = nil } }),
                            titleVisibility: .visible, presenting: nudging) { n in
            Button("Message \(n.name)") { message(n) }
        } message: { n in
            Text("“\(n.announcement.title)” goes to \(n.name)'s chat, so it's harder to miss.")
        }
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

    /// Groups need everyone's sessions; until they're in, the chips show no count.
    private var groupsReady: Bool { data.hasLoaded }

    private func label(_ a: Audience) -> String {
        switch a {
        case .everyone: return "Everyone · \(store.roster.count)"
        case .pick: return picked.isEmpty ? "Pick people…" : "Picked · \(picked.count)"
        default: return groupsReady ? "\(a.name) · \(members(a).count)" : a.name
        }
    }

    private var isGroup: Bool { audience != .everyone }
    private var asMessages: Bool { isGroup && !v23 }

    private var namesLine: String {
        let list = members(audience)
        if !groupsReady && audience != .pick { return "Working out who's in this group…" }
        if list.isEmpty { return audience == .pick ? "Pick who it goes to." : "Nobody in this group right now." }
        let names = list.prefix(6).map { $0.name.firstName }
        let joined: String = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        let more: String = list.count > 6 ? " and \(list.count - 6) more" : ""
        let who = list.count > 6 ? names.joined(separator: ", ") + more : joined
        return asMessages ? "Goes as a message to \(who). Announcements to a group need server 2.3.0."
                          : "Goes on the Home of \(who). Nobody else sees it."
    }

    private var canSend: Bool {
        let hasText = !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTitle = !title.trimmingCharacters(in: .whitespaces).isEmpty
        let groupOK: Bool = !isGroup || (audience == .pick ? !picked.isEmpty : (groupsReady && !members(audience).isEmpty))
        return hasText && (asMessages || hasTitle) && groupOK && !posting
    }

    private var sendLabel: String {
        let n = members(audience).count
        let people: String = n == 1 ? "1 person" : "\(n) people"
        if asMessages { return "Message \(people)" }
        if when == .later { return "Schedule for " + publishAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }
        return isGroup ? "Post to \(people)" : "Post to all clients"
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHO").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
            DSCarousel(options: Audience.allCases.map { DSCarousel<Audience>.Option(id: $0, label: label($0)) },
                       selection: $audience, itemWidth: 150, accessibilityName: "Who it goes to")
            if isGroup {
                HStack(alignment: .top, spacing: 8) {
                    Text(namesLine).font(BrandFont.body(12)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if audience == .pick {
                        Button(picked.isEmpty ? "Pick" : "Change") { picking = true }
                            .font(BrandFont.body(12, .heavy)).foregroundColor(Brand.voltText)
                    }
                }
            }
            Text("TITLE").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
            TextField("", text: $title, prompt: Text(asMessages ? "Optional, goes first in bold" : "New PR Challenge Starts Monday").foregroundColor(Brand.mute))
                .font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.voltLine, lineWidth: 1.5))
            Text("MESSAGE").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
            TextEditor(text: $messageBody)
                .font(BrandFont.body(15)).foregroundColor(Brand.text)
                .scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
            if !asMessages {
                Text("WHEN").font(BrandFont.body(10, .bold)).tracking(1.4).headerPill()
                DSCarousel(options: When.allCases.map { DSCarousel<When>.Option(id: $0, label: $0.rawValue) },
                           selection: $when, itemWidth: 124, accessibilityName: "When to post")
                if when == .later {
                    DatePicker("Goes out", selection: $publishAt, in: Date().addingTimeInterval(120)...,
                               displayedComponents: [.date, .hourAndMinute])
                        .font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text).tint(Brand.voltText)
                        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                    Text(isGroup ? "They won't see it, and nobody's notified, until then." : "Clients won't see it, and nobody's notified, until then.")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
            } else {
                Text("Messages go now.").font(BrandFont.body(11)).foregroundColor(Brand.mute)
            }
            if !asMessages {
                Toggle(isOn: $push) {
                    Text("Send a push notification").font(BrandFont.body(14, .semibold)).foregroundColor(Brand.text)
                }
                .tint(Brand.volt)
                if !push {
                    Text("Off: it shows on their Home and in Announcements without a notification.")
                        .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note { Text(note).font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText) }
            if let failed { Text(failed).font(BrandFont.body(12)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            Button { post() } label: {
                HStack(spacing: 8) {
                    if posting { ProgressView().tint(Brand.onVolt) }
                    Label(sendLabel, systemImage: asMessages ? "bubble.left.fill" : (when == .later ? "clock.fill" : "megaphone.fill"))
                }
            }
            .buttonStyle(DSButtonStyle(kind: .primary))
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.5)
        }
        .card(padding: 16)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(asMessages ? "PREVIEW · AS A MESSAGE" : "PREVIEW · WHAT THEY SEE").font(BrandFont.body(10, .bold)).tracking(1.4).foregroundColor(Brand.mute)
            if asMessages {
                Text(combined(title: title, body: messageBody.isEmpty ? "Your message" : messageBody))
                    .font(BrandFont.body(14)).foregroundColor(Brand.onVolt)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Brand.volt))
                    .frame(maxWidth: 300, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "megaphone.fill").font(.system(size: 12)).foregroundColor(Brand.voltText)
                        Text("TODAY").font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                        DSChip(text: "New", color: Brand.volt, filled: true)
                    }
                    Text(title.isEmpty ? "Your title" : title).font(BrandFont.display(26)).foregroundColor(Brand.text)
                    Text(messageBody.isEmpty ? "Your message" : messageBody).font(BrandFont.body(14)).foregroundColor(Brand.text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
            }
        }
    }

    private func combined(title: String, body: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? body : "\(t)\n\n\(body)"
    }

    // MARK: Reads (server 2.3.0)

    private var sent: [APIAdminAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) <= Date() }.sorted { $0.createdAt > $1.createdAt } }
    private var queued: [APIAdminAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) > Date() }.sorted { ($0.publishAt ?? Date()) < ($1.publishAt ?? Date()) } }

    /// The first read the server ever kept. Posts from before then (no reads at all) weren't tracked.
    private var trackedSince: Date? { posted.flatMap { $0.reads ?? [] }.map { $0.readAt }.min() }

    private func tracked(_ a: APIAdminAnnouncement) -> Bool {
        guard v23, a.hasReceipts, !(a.audienceIds ?? []).isEmpty else { return false }
        if !(a.reads ?? []).isEmpty { return true }
        guard let since = trackedSince else { return a.createdAt >= installSeen }
        return a.createdAt >= since.addingTimeInterval(-86400 * 2)
    }

    /// When this device first saw server 2.3.0 (shared with the iPad's key).
    private var installSeen: Date {
        (UserDefaults.standard.object(forKey: "bst_pad_v23_seen") as? Date) ?? .distantFuture
    }

    private func first(_ id: String) -> String? { store.roster.first { $0.id == id }?.name.firstName }

    private func readLine(_ a: APIAdminAnnouncement) -> String? {
        guard tracked(a) else { return nil }
        let to = a.audienceIds ?? []
        let unread = a.unreadIds
        let read = to.count - unread.count
        if unread.isEmpty { return "Read by \(read) of \(to.count)" }
        let names = unread.compactMap { first($0) }
        let who: String = names.count == 1 ? "\(names[0]) hasn't" : (names.count == 2 ? "\(names[0]) and \(names[1]) haven't" : "\(unread.count) haven't")
        return "Read by \(read) of \(to.count) · \(who) opened it"
    }

    /// Clients sent both of the last two tracked posts who opened neither.
    private var missedTwo: Set<String> {
        let list = Array(sent.filter { tracked($0) }.prefix(2))
        guard list.count == 2, Date().timeIntervalSince(list[0].createdAt) > 86400 else { return [] }
        return Set(list[0].unreadIds).intersection(Set(list[1].unreadIds))
    }

    @ViewBuilder private var unreadCard: some View {
        if let last = sent.first, tracked(last), !last.unreadIds.isEmpty {
            let rows: [RosterItem] = last.unreadIds.compactMap { id in store.roster.first { $0.id == id } }.sorted { $0.name < $1.name }
            let two = missedTwo
            VStack(alignment: .leading, spacing: 10) {
                DSSectionHeader(title: "HASN'T READ THE LAST ONE")
                VStack(alignment: .leading, spacing: 10) {
                    Text("“\(last.title)” · posted \(PadDay.agoText(last.createdAt))").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                        HStack(spacing: 10) {
                            CoachAvatar(name: r.name, size: 34)
                                .overlay(Circle().stroke(two.contains(r.id) ? Color.orange : Color.clear, lineWidth: 2).padding(-3))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(BrandFont.body(14, .heavy)).foregroundColor(Brand.text)
                                Text(two.contains(r.id) ? "missed 2 in a row" : "posted \(PadDay.agoText(last.createdAt))")
                                    .font(BrandFont.body(12)).foregroundColor(two.contains(r.id) ? .orange : Brand.mute)
                            }
                            Spacer(minLength: 6)
                            CoachActionPill(title: "Message", icon: "bubble.left", primary: false) {
                                nudging = Nudge(clientId: r.id, name: r.name.firstName, announcement: last)
                            }
                        }
                    }
                    Text("Opening it on their Home, in Announcements, or clearing it counts.").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                }
                .card(padding: 14)
            }
        }
    }

    /// "Everyone", "On a program · 4", "Picked · 2".
    private func who(_ a: APIAdminAnnouncement) -> String {
        guard let aud = a.audience else { return "Everyone" }
        return "\(a.audienceLabel ?? "Picked") · \(aud.count)"
    }

    private func card(_ a: APIAdminAnnouncement) -> some View {
        let isQueued = (a.publishAt ?? .distantPast) > Date()
        let date: Date = a.publishAt ?? a.createdAt
        let stamp: String = isQueued ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                     : a.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let line: String? = isQueued ? nil : readLine(a)
        let warn: Bool = !a.unreadIds.isEmpty && Date().timeIntervalSince(a.createdAt) > 2 * 86400
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isQueued { Image(systemName: "clock.fill").font(.system(size: 11)).foregroundColor(Brand.voltText) }
                Text((stamp + (v23 ? " · " + who(a) : "")).uppercased()).font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button { reuse(a) } label: { Label("Reuse", systemImage: "arrow.uturn.left") }
                    Button(role: .destructive) { confirmDelete = a } label: { Label(isQueued ? "Cancel it" : "Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundColor(Brand.mute).frame(width: 36, height: 36)
                }
                .accessibilityLabel("More for \(a.title)")
            }
            Text(a.title).font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
            Text(a.body).font(BrandFont.body(13)).foregroundColor(Brand.mute).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let line {
                Text(line).font(BrandFont.body(12, .bold)).foregroundColor(warn ? .orange : Brand.mute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isQueued ? Brand.voltLine.opacity(0.45) : Color.clear, lineWidth: 1))
        .contextMenu {
            Button { reuse(a) } label: { Label("Reuse", systemImage: "arrow.uturn.left") }
            Button(role: .destructive) { confirmDelete = a } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Doing it

    private func load() async {
        guard store.isLive else { loading = false; return }
        v23 = await ServerVersion.has23()
        if v23, UserDefaults.standard.object(forKey: "bst_pad_v23_seen") == nil {
            UserDefaults.standard.set(Date(), forKey: "bst_pad_v23_seen")
        }
        if let a = try? await APIClient.shared.adminAnnouncementsWithReads() { posted = a }
        loading = false
        // Groups need assignments and sessions for everyone (the same data the iPad keeps).
        if !data.hasLoaded {
            if store.roster.isEmpty { store.loadRoster() }
            await data.refresh(roster: store.roster, force: false)
        }
    }

    private func reuse(_ a: APIAdminAnnouncement) {
        title = a.title
        messageBody = a.body
        if let aud = a.audience, v23 {
            picked = Set(aud)
            audience = .pick
        } else {
            audience = .everyone
        }
        push = true
        note = "Copied into the composer above."
    }

    private func remove(_ a: APIAdminAnnouncement) {
        Task {
            do {
                try await APIClient.shared.deleteAnnouncement(id: a.id)
                posted.removeAll { $0.id == a.id }
            } catch {
                failed = "Couldn't delete it. Try again."
            }
        }
    }

    private func message(_ n: Nudge) {
        let text = combined(title: n.announcement.title, body: n.announcement.body)
        Task {
            do {
                try await CoachMessenger.send(text, to: n.clientId)
                note = "Sent to \(n.name)'s chat."
            } catch {
                failed = "Couldn't send. Try again."
            }
        }
    }

    private func post() {
        failed = nil; note = nil
        posting = true
        let t = title.trimmingCharacters(in: .whitespaces)
        let b = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if asMessages {
            let ids = members(audience).map { $0.id }
            let text = combined(title: t, body: b)
            Task {
                var bad = 0
                for id in ids { do { try await CoachMessenger.send(text, to: id) } catch { bad += 1 } }
                posting = false
                if bad == 0 {
                    note = "Sent to \(ids.count == 1 ? "1 client" : "\(ids.count) clients") as a message. 👑"
                    title = ""; messageBody = ""
                } else {
                    failed = "\(bad) didn't send. Check your connection and try again."
                }
            }
            return
        }
        let at: Date? = when == .later ? publishAt : nil
        let ids: [String]? = isGroup ? members(audience).map { $0.id } : nil
        let groupLabel: String? = isGroup ? audience.name : nil
        let sendPush = push
        Task {
            do {
                if ids != nil {
                    // Re-check: a group must never go out on a server that would post it to everyone.
                    guard await ServerVersion.has23() else {
                        posting = false
                        v23 = false
                        failed = "Your server isn't on 2.3.0, so a group can't get an announcement. It can go as messages instead."
                        return
                    }
                    try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at, clientIds: ids, audienceLabel: groupLabel, push: sendPush)
                } else {
                    try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at, push: sendPush)
                }
                posting = false
                let whom: String = ids.map { $0.count == 1 ? "1 person's Home" : "\($0.count) people's Homes" } ?? "every client's Home"
                note = at == nil ? "Posted to \(whom). 👑" : "Scheduled. 👑"
                title = ""; messageBody = ""; when = .now; push = true
                if let a = try? await APIClient.shared.adminAnnouncementsWithReads() { posted = a }
            } catch {
                posting = false
                failed = "Couldn't post. Check your connection and try again."
            }
        }
    }
}

// MARK: - Pick people (phone)

struct PhonePeoplePicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var picked: Set<String>
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    CoachSearchField(prompt: "Search clients", text: $query)
                    VStack(spacing: 0) {
                        let list = store.roster.sorted { $0.name < $1.name }.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                        ForEach(list) { c in
                            Button {
                                if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    CoachAvatar(name: c.name, size: 34)
                                    Text(c.name).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                                    Spacer()
                                    Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 21)).foregroundColor(picked.contains(c.id) ? Brand.voltText : Brand.mute)
                                }
                                .padding(.horizontal, 14).frame(minHeight: 54).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(picked.contains(c.id) ? .isSelected : [])
                            if c.id != list.last?.id { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 60) }
                        }
                    }
                    .card(padding: 0)
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(picked.isEmpty ? "Pick people" : "\(picked.count) picked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !picked.isEmpty { Button("Clear") { picked = [] }.foregroundColor(Brand.voltText) }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(.body.bold()).foregroundColor(Brand.voltText) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
