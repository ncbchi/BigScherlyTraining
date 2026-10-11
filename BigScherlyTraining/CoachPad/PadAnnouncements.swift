import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Announcements (round 3, Oct 9, 2026)
//
// Write once, choose who by what's true about them. "Everyone" posts an announcement on every
// client's Home (and can be scheduled). A group (on a program, missed this week, new, or people you
// pick) goes as a message to each of them, because announcements on the server always go to
// everyone. Posted and scheduled ones are listed with Reuse and Delete. Read receipts need the
// server to record opens, so they aren't shown yet.
// Synchronized folder: no target step needed.

struct PadAnnouncementsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var data = PadData.shared
    @Environment(\.padSideBySide) private var sideBySide

    enum Audience: String, CaseIterable, Identifiable {
        case everyone, program, missed, new, pick
        var id: String { rawValue }
    }

    @State private var audience: Audience = .everyone
    @State private var picked: Set<String> = []
    @State private var picking = false
    @State private var title = ""
    @State private var text = ""
    @State private var schedule = false
    @State private var publishAt: Date = PadAnnouncementsView.nextMorning()
    @State private var posted: [APIAnnouncement] = []
    @State private var loaded = false
    @State private var sending = false
    @State private var failed: String?
    @State private var deleting: APIAnnouncement?

    private var cal: Calendar { Calendar.training }

    static func nextMorning() -> Date {
        let cal = Calendar.training
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Announcements", subtitle: "Posts on everyone's Home. Or pick a group, and it goes to them as a message.") { EmptyView() }
                PadPageStrip(stats: strip, notes: notes)
                PadRule()
                if sideBySide {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 12) { composer; previewPane }.frame(maxWidth: .infinity)
                        VStack(spacing: 12) { scheduledPane; postedPane }.frame(width: 420)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 12) { composer; previewPane; scheduledPane; postedPane }.padding(20)
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
        } message: { _ in
            Text("It comes off everyone's Home.")
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

    private func label(_ a: Audience) -> String {
        let n = members(a).count
        switch a {
        case .everyone: return "Everyone · \(n)"
        case .program: return "On a program · \(n)"
        case .missed: return "Missed this week · \(n)"
        case .new: return "New · \(n)"
        case .pick: return picked.isEmpty ? "Pick people…" : "Picked · \(n)"
        }
    }

    // MARK: Strip

    private var sent: [APIAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) <= Date() }.sorted { $0.createdAt > $1.createdAt } }
    private var queued: [APIAnnouncement] { posted.filter { ($0.publishAt ?? .distantPast) > Date() }.sorted { ($0.publishAt ?? Date()) < ($1.publishAt ?? Date()) } }

    private var strip: [PadStat] {
        let last = sent.first
        let since90 = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let count90 = sent.filter { $0.createdAt >= since90 }.count
        let next: String = queued.first?.publishAt.map { Self.when($0) } ?? "nothing queued"
        return [
            PadStat(label: "Last posted", value: last.map { PadDay.short($0.createdAt) } ?? "—", sub: last.map { "“\($0.title)”" } ?? "nothing yet"),
            PadStat(label: "Scheduled", value: "\(queued.count)", sub: next),
            PadStat(label: "Posted, 90 days", value: "\(count90)", sub: "to everyone"),
        ]
    }

    private var notes: [PadNote] {
        guard loaded, let last = sent.first else { return [] }
        let days = PadDay.daysAgo(last.createdAt)
        if days >= 21 && queued.isEmpty {
            return [PadNote(icon: "megaphone.fill", tint: Pad.mute, text: "Nothing posted in \(days) days.", aside: "A short weekly note keeps Home feeling alive.")]
        }
        return []
    }

    static func when(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + d.padClock
    }

    // MARK: Composer

    private var isGroup: Bool { audience != .everyone }
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTitle = !title.trimmingCharacters(in: .whitespaces).isEmpty
        return hasText && (isGroup ? !members(audience).isEmpty : hasTitle) && !sending
    }
    private var sendLabel: String {
        if isGroup { return "Message \(members(audience).count.plural("person").replacingOccurrences(of: "persons", with: "people"))" }
        return schedule ? "Schedule" : "Post to everyone"
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
                        }
                    }
                }
            }
            if isGroup {
                let names = members(audience).prefix(6).map { $0.name.firstName }.joined(separator: ", ")
                let more: String = members(audience).count > 6 ? " and more" : ""
                PadLab(names.isEmpty ? "Nobody in this group right now." : "Goes as a message to \(names)\(more). Announcements always go to everyone.", color: Pad.mute, size: 12)
            }
            TextField(isGroup ? "Title (optional, goes first in bold)" : "Title", text: $title).padInput()
            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 160).padInput(multiline: true)
            if let failed { Text(failed).font(PadFont.ui(13)).foregroundColor(Pad.orange) }
            HStack(spacing: 10) {
                Toggle("", isOn: $schedule).labelsHidden().tint(Pad.volt).disabled(isGroup)
                if schedule && !isGroup {
                    DatePicker("", selection: $publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                } else {
                    Text(isGroup ? "Messages go now" : "Schedule for later").font(PadFont.ui(14)).foregroundColor(Pad.mute)
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
        return PadPane(title: "Preview", aside: isGroup ? "as a message" : "on their Home") {
            VStack(alignment: .leading, spacing: 6) {
                if isGroup {
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

    private var scheduledPane: some View {
        PadPane(title: "Scheduled") {
            if queued.isEmpty {
                PadEmptyLine(text: loaded ? "Nothing scheduled." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { PadRule() }
                        PadPaneRow(title: a.title, detail: a.publishAt.map { "goes out \(Self.when($0))" } ?? "") {
                            Button("Cancel") { deleting = a }.buttonStyle(PadButtonStyle(kind: .quiet, small: true))
                        }
                    }
                }
            }
        }
    }

    private var postedPane: some View {
        PadPane(title: "Posted", aside: "to everyone") {
            if !loaded {
                PadSkeleton(height: 44)
            } else if sent.isEmpty {
                PadEmptyLine(text: "Nothing posted yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sent.prefix(15).enumerated()), id: \.element.id) { i, a in
                        if i > 0 { PadRule() }
                        PadPaneRow(title: a.title, detail: "\(PadDay.short(a.createdAt)) · \(a.body)") {
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
        if let a = try? await APIClient.shared.adminAnnouncements() { posted = a }
        loaded = true
    }

    private func reuse(_ a: APIAnnouncement) {
        title = a.title
        text = a.body
        audience = .everyone
        PadToasts.shared.show("Copied into New announcement")
    }

    private func delete(_ a: APIAnnouncement) {
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

    private func send() {
        failed = nil
        sending = true
        let t = title.trimmingCharacters(in: .whitespaces)
        let b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGroup {
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
        } else {
            let at: Date? = schedule ? publishAt : nil
            Task {
                do {
                    try await APIClient.shared.createAnnouncement(title: t, body: b, publishAt: at)
                    sending = false
                    PadToasts.shared.show(at == nil ? "Posted to everyone's Home" : "Scheduled for \(Self.when(at ?? Date()))")
                    title = ""; text = ""; schedule = false
                    await load()
                } catch {
                    sending = false
                    failed = "Couldn't post. Check your connection and try again."
                }
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
                                PadAvatar(name: c.name, size: 32)
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
