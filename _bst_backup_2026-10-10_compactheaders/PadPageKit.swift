import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: the Clients pattern for every page (round 3, Oct 9, 2026)
//
// Each page reads the same way as a client section: title and tools on top, a headline strip
// (the 3–5 numbers that answer "how is this going?"), a noticing line only when there's something
// real (each with its own fix button), then the work area using the full width. The client card
// here is the same one everywhere (Inbox inspector, Today, Calendar).
// Synchronized folder: no target step needed.

/// One thing worth noticing on a page, with an optional fix.
struct PadNote: Identifiable {
    let icon: String
    let tint: Color
    let text: String
    var aside: String = ""
    var go: String? = nil
    var run: (() -> Void)? = nil
    var id: String { icon + text }
}

/// One tile in a headline strip.
struct PadStatTile: View {
    let stat: PadStat
    var body: some View {
        let subColor: Color = stat.warn ? Pad.orange : (stat.good ? Pad.voltText : Pad.mute)
        let valueColor: Color = stat.warn ? Pad.orange : Pad.text
        return VStack(alignment: .leading, spacing: 2) {
            PadLab(stat.label, size: 12).lineLimit(1)
            PadNumber(value: stat.value, unit: stat.unit, size: 26, color: valueColor)
            PadLab(stat.sub, color: subColor, size: 12).lineLimit(1)
        }
        .frame(minWidth: 128, maxWidth: 200, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
        .accessibilityElement(children: .combine)
    }
}

/// A noticing card: the sentence, then its fix button.
struct PadNoteCard: View {
    let note: PadNote
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PadNoticeRow(notice: PadInsights.Notice(icon: note.icon, tint: note.tint, text: note.text, aside: note.aside))
            if let g = note.go, let run = note.run {
                Button(g, action: run).buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pad.line, lineWidth: 1))
    }
}

/// Headline strip, then the noticing line (up to three).
struct PadPageStrip: View {
    let stats: [PadStat]
    var notes: [PadNote] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !stats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stats) { s in PadStatTile(stat: s) }
                    }
                }
            }
            if !notes.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(notes.prefix(3)) { n in PadNoteCard(note: n) }
                }
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 16)
    }
}

/// A row inside a pane: avatar, two lines, and whatever goes on the right.
struct PadPaneRow<Trailing: View>: View {
    var name: String? = nil
    var ring = false
    let title: String
    var detail: String = ""
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            if let name {
                PadAvatar(name: name, size: 30)
                    .overlay(Circle().stroke(ring ? Pad.orange : Color.clear, lineWidth: 2).padding(-3))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(PadFont.ui(12)).foregroundColor(Pad.mute).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 8)
    }
}

/// A Menu's label drawn like a PadButtonStyle button (Menus don't take button styles everywhere).
struct PadMenuLabel: View {
    let text: String
    var kind: PadButtonStyle.Kind = .outline
    var icon: String? = nil
    var body: some View {
        let fg: Color = kind == .primary ? Pad.onVolt : (kind == .quiet ? Pad.mute : Pad.text)
        let bg: Color = kind == .primary ? Pad.volt : Color.clear
        let stroke: Color = kind == .outline ? Pad.line2 : Color.clear
        return HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
            Text(text).font(PadFont.ui(14, .semibold)).lineLimit(1)
        }
        .foregroundColor(fg)
        .padding(.horizontal, 13).frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - The whole roster, worked out once

enum PadRosterFacts {
    static func all(_ store: AppStore) -> [PadClientFacts] {
        store.roster.map { PadInsights.facts($0, store: store) }
    }
}

// MARK: - Going somewhere

enum PadOpen {
    /// Opens a client in the Clients workspace, on one of their sections.
    static func client(_ id: String, _ section: PadClientSection? = nil, go: PadGo) {
        PadNav.shared.clientSection = section
        PadNav.shared.clientId = id
        go(.clients)
    }
    /// Opens Inbox on a client's latest conversation.
    static func inbox(_ clientId: String, thread: String? = nil, go: PadGo) {
        PadNav.shared.inboxThreadId = thread
        PadNav.shared.inboxClientId = clientId
        go(.inbox)
    }
}

// MARK: - The client card (same everywhere)

struct PadClientCard: View {
    let facts: PadClientFacts
    var showOpen = true
    @ObservedObject private var data = PadData.shared
    @Environment(\.padGo) private var go

    private var statusText: String {
        if facts.risk == .high { return facts.renewsOn.map { "At risk · renews \(PadDay.short($0))" } ?? "At risk" }
        if let r = facts.renewsOn { return "\(facts.status.text) · renews \(PadDay.short(r))" }
        return facts.status.text
    }
    private var statusColor: Color { facts.risk == .high ? Pad.orange : Pad.mute }
    private var lastTrained: String { facts.daysSince.map { $0 == 0 ? "Today" : ($0 == 1 ? "Yesterday" : "\($0) days ago") } ?? "Not yet" }
    private var program: String {
        guard let a = facts.assignment else { return "None" }
        return "Wk \(a.currentWeek) of \(a.totalWeeks)"
    }
    private var checkIn: String {
        if facts.waiting != nil { return "Waiting on you" }
        if facts.checkInLateDays > 0 { return "\(facts.checkInLateDays.plural("day")) late" }
        return facts.lastCheckIn.map { PadDay.agoText($0.date).capitalizedFirst } ?? "None yet"
    }
    private var supplements: String {
        guard let a = data.adherence[facts.id], a.totalExpected > 0 else { return "—" }
        let pct: Int = Int((a.overallRate * 100).rounded())
        return "\(pct)%"
    }
    private var note: String {
        let n = (data.notes[facts.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Nothing yet. Add it in their Notes." : n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PadClientAvatar(facts: facts, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(facts.name).font(PadFont.display(26)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.7)
                    PadLab(statusText, color: statusColor, size: 13).lineLimit(1)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                fact("Last trained", lastTrained, warn: (facts.daysSince ?? 0) >= 7)
                fact("Program", program, warn: facts.endingSoon && facts.nothingAfter)
                fact("Check-in", checkIn, warn: facts.checkInLateDays > 0)
                fact("Supplements", supplements, warn: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                PadLab("What to remember", size: 12)
                Text(note).font(PadFont.ui(13)).foregroundColor(Pad.text).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
            }
            if showOpen {
                Button { PadOpen.client(facts.id, go: go) } label: {
                    Label("Open \(facts.first) in Clients", systemImage: "arrow.right")
                }
                .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
        }
        .task(id: facts.id) { await data.loadContext(facts.id) }
    }

    private func fact(_ label: String, _ value: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            PadLab(label, size: 11)
            Text(value).font(PadFont.ui(14, .semibold)).foregroundColor(warn ? Pad.orange : Pad.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Pad.well))
    }
}

extension String {
    /// "yesterday" → "Yesterday".
    var capitalizedFirst: String { isEmpty ? self : String(self.prefix(1)).uppercased() + String(self.dropFirst()) }
}

// MARK: - Coach preferences that shape what the iPad shows (Settings ▸ Flight risk & renewals)

enum PadPrefs {
    static let showRiskKey = "bst_pad_show_risk"
    static let lateGraceKey = "bst_pad_checkin_grace"
    static let renewWindowKey = "bst_pad_renew_window"

    /// Off = nobody is ever labelled "At risk" (the business pane's risk card goes too).
    static var showRisk: Bool { UserDefaults.standard.object(forKey: showRiskKey) as? Bool ?? true }
    /// Days past the weekly due day before a check-in counts as late.
    static var lateGrace: Int { UserDefaults.standard.integer(forKey: lateGraceKey) }
    /// How far ahead renewals show up (Insights, Today).
    static var renewWindow: Int {
        let v = UserDefaults.standard.integer(forKey: renewWindowKey)
        return v > 0 ? v : 30
    }
}
