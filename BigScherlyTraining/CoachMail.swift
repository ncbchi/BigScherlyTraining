import SwiftUI
import Combine

// MARK: - Coach email (coach@) in the apps (Oct 15, 2026)
//
// The same mailbox as Coach HQ ▸ Communications ▸ Inbox, through the server's /admin/mail routes
// (server 2.6.0). Only the Coach HQ login that owns coach@ sees it; everyone else, a server with mail
// switched off, or a mail server that doesn't answer gets a clear state instead of an error.
// This file is the data side shared by the phone (CoachMailView) and the iPad (PadMailView):
// the models, the calls, the mailbox list (MailBox) and one open thread with its reply (MailThreadModel).
// Shapes come from the server source (MailController.cs) and the Coach HQ page (48-mail.js).
// Synchronized folder: no target step needed.

// MARK: Models

struct MailAddr: Codable, Hashable {
    var name: String?
    var email: String
    var shown: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? email : n
    }
}

struct MailStatus: Decodable {
    let live: Bool
    let reason: String?
    let detail: String?
    let address: String?
    let unread: Int?
    let waiting: Int?
    let oldestWaiting: Oldest?
    let newPeople: Int?
    let folders: [Folder]?
    let signature: String?

    struct Oldest: Decodable { let threadId: String; let name: String?; let clientId: String?; let since: Date }
    struct Folder: Decodable { let folder: String; let name: String?; let total: Int; let unread: Int }

    func count(_ f: String) -> Int {
        guard let x = (folders ?? []).first(where: { $0.folder == f }) else { return 0 }
        if f == "drafts" { return x.total }
        if f == "junk" { return x.unread }
        return 0
    }
}

struct MailItem: Decodable, Identifiable, Equatable {
    let threadId: String
    let emailId: String
    let subject: String
    let preview: String
    let receivedAt: Date
    let name: String?
    let email: String?
    let kind: String              // client · person · automatic
    let clientId: String?
    let accent: String?
    let fromMe: Bool
    var unread: Bool
    let count: Int
    let hasAttachment: Bool
    let answered: Bool
    let waitingSince: Date?
    let hasDraft: Bool
    let scheduledAt: Date?
    var id: String { threadId }
    var who: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let e = (email ?? "").trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? "(nobody)" : e
    }
}

struct MailAttachment: Decodable, Hashable {
    let blobId: String
    let name: String?
    let type: String?
    let size: Int64?
    let cid: String?
    var fileName: String { (name ?? "").isEmpty ? "attachment" : (name ?? "attachment") }
}

struct MailEmail: Decodable, Identifiable {
    let id: String
    let folder: String?
    let from: MailAddr?
    let to: [MailAddr]?
    let cc: [MailAddr]?
    let subject: String?
    let receivedAt: Date
    let fromMe: Bool
    let unread: Bool?
    let text: String?
    let html: String?
    let attachments: [MailAttachment]?
    let kind: String?
    let replyToEmailId: String?

    var toList: [MailAddr] { to ?? [] }
    var ccList: [MailAddr] { cc ?? [] }
    /// Attachments that aren't pictures already shown inside the HTML.
    var files: [MailAttachment] {
        let h = html ?? ""
        return (attachments ?? []).filter { a in
            guard let cid = a.cid, !cid.isEmpty else { return true }
            return !h.contains("cid:" + cid)
        }
    }
}

struct MailContact: Decodable {
    let name: String?
    let email: String?
    let kind: String?
    let clientId: String?
    let clientEmail: String?
    let linked: Bool?
    let notClient: Bool?
    var shown: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (email ?? "") : n
    }
}

struct MailThread: Decodable {
    let threadId: String
    let subject: String
    let emails: [MailEmail]
    let draft: MailEmail?
    let contact: MailContact?
    let asks: [String]?
    let lastIncomingId: String?
}

struct MailPeople: Decodable {
    struct Client: Decodable, Identifiable { let id: String; let name: String; let email: String?; let accent: String? }
    struct Other: Decodable { let name: String?; let email: String; let lastAt: Date?; let wrote: Bool? }
    let clients: [Client]
    let others: [Other]
}

/// A file being added to an email you're writing.
struct MailOutFile: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var type: String
    var size: Int
    var blobId: String?
    var uploading: Bool
}

/// A reply or a new email being written.
struct MailDraft {
    var text = ""
    var subject = ""
    var to: [MailRecipient] = []
    var cc = ""
    var files: [MailOutFile] = []
    var sendAt: Date?
    var draftId: String?
    var replyToEmailId: String?
    var replyAll = false
    var dirty = false
}

/// Someone on the To line: a person, or a group that goes as separate emails.
struct MailRecipient: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var email: String
    var clientId: String?
    /// A group (Everyone, Missed this week…): its people, each with an email.
    var members: [MailAddr] = []
    var isGroup: Bool { !members.isEmpty }
}

// MARK: Calls

extension APIClient {
    private struct MailErr: Decodable { let error: String? }

    /// A /admin/mail call. A failure carries the server's own sentence ("That isn't an email address: …").
    func mailCall(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: APIConfig.baseURL + path) else { throw APIError(message: "Bad address") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token(for: "/admin") { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: req) }
        catch { throw APIError(message: "Couldn't reach the server. Check your connection.") }
        return try mailCheck(result.0, result.1)
    }

    private func mailCheck(_ data: Data, _ resp: URLResponse) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Request failed") }
        if http.statusCode == 401 {
            clearToken()
            Task { @MainActor in NotificationCenter.default.post(name: .bstUnauthorized, object: nil) }
            throw APIError(message: "Session expired")
        }
        guard (200..<300).contains(http.statusCode) else {
            let e = try? JSONDecoder().decode(MailErr.self, from: data)
            throw APIError(message: e?.error ?? "Something went wrong (\(http.statusCode)). Try again.")
        }
        return data
    }

    func mailStatus() async throws -> MailStatus {
        try decoder.decode(MailStatus.self, from: try await mailCall("/admin/mail/status"))
    }

    func mailList(folder: String, query: String) async throws -> [MailItem] {
        struct R: Decodable { let items: [MailItem] }
        var path = "/admin/mail/list?folder=\(folder)"
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) {
            path += "&q=\(e)"
        }
        return try decoder.decode(R.self, from: try await mailCall(path)).items
    }

    func mailThread(_ id: String) async throws -> MailThread {
        let e = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try decoder.decode(MailThread.self, from: try await mailCall("/admin/mail/thread/\(e)"))
    }

    func mailPeople() async throws -> MailPeople {
        try decoder.decode(MailPeople.self, from: try await mailCall("/admin/mail/people"))
    }

    /// Uploads one attachment (up to 25 MB). Returns its blob id.
    func mailUpload(data: Data, name: String, type: String) async throws -> String {
        struct R: Decodable { let blobId: String }
        guard let url = URL(string: APIConfig.baseURL + "/admin/mail/upload") else { throw APIError(message: "Bad address") }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let t = token(for: "/admin") { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let safe = name.replacingOccurrences(of: "\"", with: "'")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.upload(for: req, from: body) }
        catch { throw APIError(message: "Couldn't upload \(name). Check your connection.") }
        let d = try mailCheck(result.0, result.1)
        return try decoder.decode(R.self, from: d).blobId
    }

    /// Downloads an attachment to a temporary file (for Quick Look and sharing).
    func mailDownload(_ a: MailAttachment) async throws -> URL {
        var c = URLComponents(string: APIConfig.baseURL + "/admin/mail/blob/" + (a.blobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? a.blobId))
        c?.queryItems = [URLQueryItem(name: "name", value: a.fileName), URLQueryItem(name: "type", value: a.type ?? "application/octet-stream")]
        guard let url = c?.url else { throw APIError(message: "Bad address") }
        var req = URLRequest(url: url)
        if let t = token(for: "/admin") { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: req) }
        catch { throw APIError(message: "Couldn't download it. Check your connection.") }
        let d = try mailCheck(result.0, result.1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bst-mail", isDirectory: true)
            .appendingPathComponent(a.blobId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(a.fileName.replacingOccurrences(of: "/", with: "-"))
        try d.write(to: file, options: .atomic)
        return file
    }

    /// Adds someone as a client from an email (Coach HQ's "Add as a client"). Nothing is sent unless `invite`.
    func mailAddClient(name: String, email: String, invite: Bool) async throws -> String {
        struct R: Decodable { let id: String }
        let d = try await mailCall("/admin/clients", method: "POST",
                                   body: ["name": name, "email": email, "goal": "", "tempPassword": "", "sendWelcome": invite])
        return try decoder.decode(R.self, from: d).id
    }
}

// MARK: Words and dates

struct MailLaterChoice: Identifiable {
    let label: String
    let at: Date
    var id: String { label }
}

enum MailText {
    static let folders: [(id: String, name: String)] = [
        ("inbox", "Inbox"), ("sent", "Sent"), ("drafts", "Drafts"), ("archive", "Archive"), ("junk", "Junk"), ("trash", "Trash")
    ]
    static func folderName(_ f: String) -> String { folders.first { $0.id == f }?.name ?? f.capitalized }

    static func emptyLine(_ folder: String, searching: Bool) -> String {
        if searching { return "Nothing matches." }
        switch folder {
        case "sent": return "Nothing sent yet."
        case "drafts": return "No drafts."
        case "archive": return "Nothing archived."
        case "junk": return "No junk."
        case "trash": return "Trash is empty."
        default: return "Inbox zero."
        }
    }

    /// The text without its quoted reply ("> …" lines, and everything from "On … wrote:").
    static func splitQuote(_ text: String) -> (main: String, quoted: String) {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var cut: Int? = nil
        for (i, raw) in lines.enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("On "), l.hasSuffix("wrote:"), l.count >= 12, l.count <= 220 { cut = i; break }
            if l.hasPrefix("-----Original Message-----") { cut = i; break }
            if l.hasPrefix(">") {
                let rest = lines[i...].allSatisfy { x in
                    let t = x.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty || t.hasPrefix(">")
                }
                if rest { cut = i; break }
            }
        }
        guard let c = cut else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), "") }
        let main = lines[..<c].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = lines[c...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (main, quoted)
    }

    /// List previews: the new words only, no quoted reply, signature or **bold** markers.
    static func cleanPreview(_ p: String, signature: String) -> String {
        var t = p
        if let r = t.range(of: "\n— ") ?? t.range(of: "\n-- ") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: #"\s(On [^>]{4,120}? wrote:|>\s)"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        let sig = signature.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if !sig.isEmpty, let r = t.range(of: sig), r.lowerBound > t.startIndex { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// A saved draft's text without the signature the server adds on send.
    static func stripSignature(_ text: String, signature: String) -> String {
        let main = splitQuote(text).main
        let s = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, main.hasSuffix(s) { return String(main.dropLast(s.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return main
    }

    static func size(_ n: Int64?) -> String {
        guard let n, n > 0 else { return "" }
        if n < 1024 { return "\(n) B" }
        if n < 1_048_576 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    /// "9:41", "Yesterday", "Mon", "Oct 13".
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(.dateTime.hour().minute()) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    static func whenLong(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(.dateTime.hour().minute())
            : d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + d.formatted(.dateTime.hour().minute())
    }

    static func sendsText(_ d: Date) -> String {
        "Sends " + d.formatted(.dateTime.weekday(.abbreviated)) + ", " + d.formatted(.dateTime.hour().minute())
    }

    static func waitingText(_ since: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: since), to: cal.startOfDay(for: Date())).day ?? 0
        return n <= 0 ? "Waiting today" : "Waiting \(n) day\(n == 1 ? "" : "s")"
    }

    /// Send later: tomorrow 7 am, tomorrow noon, Monday 7 am (the web's three).
    static func laterChoices() -> [MailLaterChoice] {
        let cal = Calendar.current
        func at(_ days: Int, _ hour: Int, monday: Bool = false) -> Date {
            var d = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
            if monday { while cal.component(.weekday, from: d) != 2 { d = cal.date(byAdding: .day, value: 1, to: d) ?? d } }
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: d) ?? d
        }
        return [MailLaterChoice(label: "Tomorrow, 7:00 am", at: at(1, 7)), MailLaterChoice(label: "Tomorrow, 12:00 pm", at: at(1, 12)),
                MailLaterChoice(label: "Monday, 7:00 am", at: at(1, 7, monday: true))]
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) != nil
    }

    /// Hidden pictures: remote src/srcset/background are dropped so nothing is even asked for.
    static func noRemote(_ html: String) -> String {
        var h = html
        h = h.replacingOccurrences(of: #"\s(src|srcset|background)\s*=\s*(["'])\s*(https?:)?//[^"']*\2"#, with: "", options: [.regularExpression, .caseInsensitive])
        h = h.replacingOccurrences(of: #"\s(src|srcset|background)\s*=\s*(https?:)?//[^\s>]*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return h
    }

    static func hasRemoteImages(_ html: String) -> Bool {
        html.range(of: #"<img[^>]+src=["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: The mailbox

@MainActor
final class MailBox: ObservableObject {
    static let shared = MailBox()

    @Published var checked = false
    @Published var live = false
    @Published var status: MailStatus?
    @Published var reason = ""
    @Published var detail = ""
    @Published var folder = "inbox"
    @Published var filter = "all"           // inbox only: all · clients · others
    @Published var query = ""
    @Published var items: [MailItem]?
    @Published var loading = false
    @Published var listError = ""
    @Published var people: MailPeople?
    private var polledAt = Date.distantPast
    private var queryTask: Task<Void, Never>?

    var signature: String { status?.signature ?? "" }
    var unread: Int { live ? (status?.unread ?? 0) : 0 }

    /// Status: live or not, unread, who's waiting. Cheap to call often (at most every 110 s unless forced).
    func poll(force: Bool = false) async {
        let store = AppStore.shared
        guard store.isTrainer, store.isLive else {
            checked = true; live = false; reason = store.isDemoMode ? "demo" : "off"
            return
        }
        guard force || Date().timeIntervalSince(polledAt) > 110 else { return }
        polledAt = Date()
        do {
            let s = try await APIClient.shared.mailStatus()
            status = s
            live = s.live
            reason = s.reason ?? ""
            detail = s.detail ?? ""
        } catch {
            // The status route answers 200 even when mail is off; a failure here is the connection.
            if status == nil { live = false; reason = "unreachable"; detail = (error as? APIClient.APIError)?.message ?? "" }
        }
        checked = true
        CommsBadges.shared.unreadMail = unread
    }

    func load() async {
        guard live else { return }
        loading = true; listError = ""
        let want = folder, q = query
        do {
            let sig = signature
            let list = try await APIClient.shared.mailList(folder: want, query: q)
            // The folder or search changed while this was loading: a newer load will fill the list.
            guard want == folder, q == query else { return }
            items = list.map { i in
                MailItem(threadId: i.threadId, emailId: i.emailId, subject: i.subject, preview: MailText.cleanPreview(i.preview, signature: sig),
                         receivedAt: i.receivedAt, name: i.name, email: i.email, kind: i.kind, clientId: i.clientId, accent: i.accent,
                         fromMe: i.fromMe, unread: i.unread, count: i.count, hasAttachment: i.hasAttachment, answered: i.answered,
                         waitingSince: i.waitingSince, hasDraft: i.hasDraft, scheduledAt: i.scheduledAt)
            }
        } catch {
            listError = (error as? APIClient.APIError)?.message ?? "Couldn't load your email."
            if items == nil { items = [] }
        }
        loading = false
    }

    /// Opens the page: status, then the list once.
    func show() async {
        await poll(force: true)
        if live && items == nil { await load() }
    }

    func refresh() async {
        await poll(force: true)
        await load()
    }

    func setFolder(_ f: String) {
        guard f != folder else { return }
        folder = f; filter = "all"; items = nil
        Task { await load() }
    }

    /// Search as you type, 350 ms after the last key.
    func searchChanged() {
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    var shown: [MailItem] {
        let l = items ?? []
        guard folder == "inbox" else { return l }
        switch filter {
        case "clients": return l.filter { $0.kind == "client" }
        case "others": return l.filter { $0.kind != "client" }
        default: return l
        }
    }

    func markOpened(_ threadId: String) {
        guard var l = items, let i = l.firstIndex(where: { $0.threadId == threadId }), l[i].unread else { return }
        l[i].unread = false
        items = l
        Task { await poll(force: true) }
    }

    // MARK: Tidying

    /// Moves a thread; returns the folder it came from (for Undo).
    func move(_ threadId: String, to: String) async throws {
        let from = folder
        _ = try await APIClient.shared.mailCall("/admin/mail/move", method: "POST", body: ["threadId": threadId, "to": to, "from": from])
        items = (items ?? []).filter { $0.threadId != threadId }
        await poll(force: true)
    }

    func undoMove(_ threadId: String, movedTo: String, from: String) async {
        let back: String = (from == "sent" || from == "drafts") ? "inbox" : from
        _ = try? await APIClient.shared.mailCall("/admin/mail/move", method: "POST", body: ["threadId": threadId, "to": back, "from": movedTo])
        await refresh()
    }

    func markRead(_ threadId: String, _ read: Bool) async throws {
        _ = try await APIClient.shared.mailCall("/admin/mail/read", method: "POST", body: ["threadId": threadId, "read": read])
        if var l = items, let i = l.firstIndex(where: { $0.threadId == threadId }) { l[i].unread = !read; items = l }
        await poll(force: true)
    }

    func deleteForever(_ threadId: String) async throws {
        _ = try await APIClient.shared.mailCall("/admin/mail/delete", method: "POST", body: ["threadId": threadId])
        items = (items ?? []).filter { $0.threadId != threadId }
        await poll(force: true)
    }

    func deleteDraft(_ emailId: String) async throws {
        let e = emailId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emailId
        _ = try await APIClient.shared.mailCall("/admin/mail/draft/\(e)", method: "DELETE")
        await refresh()
    }

    func cancelScheduled(_ emailId: String) async throws {
        _ = try await APIClient.shared.mailCall("/admin/mail/cancel", method: "POST", body: ["emailId": emailId])
        await refresh()
    }

    /// "This address is Maya" (clientId), or nil to unlink.
    func link(_ email: String, to clientId: String?) async throws {
        if let clientId {
            _ = try await APIClient.shared.mailCall("/admin/mail/contact", method: "POST", body: ["email": email, "clientId": clientId])
        } else {
            let e = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? email
            _ = try await APIClient.shared.mailCall("/admin/mail/contact?email=\(e)", method: "DELETE")
        }
        await load()
    }

    func loadPeople() async {
        if let p = try? await APIClient.shared.mailPeople() { people = p }
        else if people == nil { people = MailPeople(clients: [], others: []) }
    }

    // MARK: Sending

    private func files(_ d: MailDraft) -> [[String: Any]] {
        d.files.compactMap { f -> [String: Any]? in
            guard let b = f.blobId else { return nil }
            return ["blobId": b, "name": f.name, "type": f.type]
        }
    }

    /// Sends a reply (replyToEmailId set) or a new email. Returns how many went out.
    func send(_ d: MailDraft, separate: Bool = false) async throws -> Int {
        struct R: Decodable { let sent: Int }
        var body: [String: Any] = ["text": d.text, "replyAll": d.replyAll, "attachments": files(d), "separate": separate]
        if let r = d.replyToEmailId { body["replyToEmailId"] = r }
        if let id = d.draftId { body["draftId"] = id }
        if let at = d.sendAt { body["sendAt"] = MailText.iso(at) }
        if d.replyToEmailId == nil {
            body["subject"] = d.subject
            body["to"] = flatTo(d).map { ["name": $0.name ?? "", "email": $0.email] }
            body["cc"] = ccList(d).map { ["name": "", "email": $0] }
        }
        let data = try await APIClient.shared.mailCall("/admin/mail/send", method: "POST", body: body)
        let n = (try? JSONDecoder().decode(R.self, from: data))?.sent ?? 1
        await refresh()
        return n
    }

    /// Saves a draft (replaces draftId). Returns the new draft id.
    func saveDraft(_ d: MailDraft) async throws -> String {
        struct R: Decodable { let draftId: String }
        var body: [String: Any] = ["text": d.text, "replyAll": d.replyAll, "attachments": files(d)]
        if let r = d.replyToEmailId { body["replyToEmailId"] = r }
        if let id = d.draftId { body["draftId"] = id }
        if d.replyToEmailId == nil {
            body["subject"] = d.subject
            body["to"] = flatTo(d).map { ["name": $0.name ?? "", "email": $0.email] }
        }
        let data = try await APIClient.shared.mailCall("/admin/mail/draft", method: "POST", body: body)
        return try JSONDecoder().decode(R.self, from: data).draftId
    }

    /// Everyone on the To line, groups opened up, each address once.
    func flatTo(_ d: MailDraft) -> [MailAddr] {
        var out: [MailAddr] = []
        var seen = Set<String>()
        for r in d.to {
            let list: [MailAddr] = r.isGroup ? r.members : [MailAddr(name: r.name, email: r.email)]
            for a in list where !a.email.isEmpty && seen.insert(a.email.lowercased()).inserted { out.append(a) }
        }
        return out
    }

    func ccList(_ d: MailDraft) -> [String] {
        d.cc.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map { String($0) }.filter { !$0.isEmpty }
    }

    /// Uploads a picked file into a draft (the caller keeps the draft; this returns the finished entry).
    func upload(_ data: Data, name: String, type: String) async throws -> MailOutFile {
        guard data.count <= 25_000_000 else { throw APIClient.APIError(message: "\(name) is over 25 MB.") }
        let id = try await APIClient.shared.mailUpload(data: data, name: name, type: type)
        return MailOutFile(name: name, type: type, size: data.count, blobId: id, uploading: false)
    }
}

// MARK: Groups for the To line (the same four Coach HQ offers)

enum MailGroups {
    @MainActor
    static func all(people: MailPeople?) -> [(id: String, label: String, members: [MailAddr])] {
        let store = AppStore.shared
        let data = PadData.shared
        let cal = Calendar.training
        let emails: [String: String] = Dictionary((people?.clients ?? []).compactMap { c in c.email.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        func addrs(_ list: [RosterItem]) -> [MailAddr] { list.compactMap { c in emails[c.id].map { MailAddr(name: c.name, email: $0) } } }
        let today = cal.startOfDay(for: Date())
        let onProgram = Set(data.assignments.filter { $0.status.lowercased() != "ended" && $0.endDate >= today }.map { $0.clientId })
        let weekStart = cal.startOfWeek(for: Date())
        let missed = Set(data.sessions(for: store.roster).filter { $0.day >= weekStart && $0.isMissed }.map { $0.clientId })
        let newOnes = store.roster.filter { c in
            let first = data.sessions(client: c).map { $0.day }.min()
            return first.map { PadDay.daysAgo($0) < 28 } ?? true
        }
        let out: [(id: String, label: String, members: [MailAddr])] = [
            ("everyone", "Everyone", addrs(store.roster)),
            ("program", "Everyone on a program", addrs(store.roster.filter { onProgram.contains($0.id) })),
            ("missed", "Missed this week", addrs(store.roster.filter { missed.contains($0.id) })),
            ("new", "New clients", addrs(newOnes)),
        ]
        return out.filter { !$0.members.isEmpty }
    }
}

// MARK: One open thread and its reply

@MainActor
final class MailThreadModel: ObservableObject {
    @Published var threadId: String?
    @Published var thread: MailThread?
    @Published var loading = false
    @Published var error = ""
    @Published var draft = MailDraft()
    @Published var saving = false
    @Published var sending = false
    @Published var sendError = ""
    @Published var openOld: Set<String> = []
    @Published var openQuote: Set<String> = []
    @Published var showImages: Set<String> = []
    private var saveTask: Task<Void, Never>?

    var box: MailBox { MailBox.shared }

    func open(_ id: String) async {
        if threadId != nil, threadId != id { await saveNow() }
        threadId = id
        thread = nil; error = ""; loading = true
        draft = MailDraft(); sendError = ""
        openOld = []; openQuote = []
        do {
            let t = try await APIClient.shared.mailThread(id)
            guard threadId == id else { return }
            thread = t
            draft = newReply(t)
            box.markOpened(id)
        } catch {
            if threadId == id { self.error = (error as? APIClient.APIError)?.message ?? "Couldn't open it." }
        }
        loading = false
    }

    func reload() async {
        guard let id = threadId else { return }
        if let t = try? await APIClient.shared.mailThread(id), threadId == id {
            thread = t
            if !draft.dirty { draft = newReply(t) }
        }
    }

    func close() async {
        await saveNow()
        threadId = nil; thread = nil; draft = MailDraft()
    }

    private func newReply(_ t: MailThread) -> MailDraft {
        var d = MailDraft()
        let last: String? = t.lastIncomingId ?? t.emails.last?.id
        if let dr = t.draft {
            d.draftId = dr.id
            d.replyToEmailId = dr.replyToEmailId ?? last
            d.text = MailText.stripSignature(dr.text ?? "", signature: box.signature)
        } else {
            d.replyToEmailId = last
        }
        return d
    }

    /// Who the reply goes to, and whether Reply all is worth offering.
    var replyTarget: (name: String, many: Bool) {
        guard let t = thread else { return ("them", false) }
        let last = t.emails.last(where: { !$0.fromMe }) ?? t.emails.last
        guard let e = last else { return ("them", false) }
        let name: String = e.fromMe ? (e.toList.first?.shown ?? "them") : (e.from?.shown ?? "them")
        return (name, e.toList.count + e.ccList.count > 1)
    }

    func textChanged() {
        draft.dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        guard draft.dirty, !sending, thread != nil else { return }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.draftId != nil else { return }
        saving = true
        if let id = try? await box.saveDraft(draft) {
            draft.draftId = id
            draft.dirty = false
        }
        saving = false
    }

    var canSend: Bool {
        (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty) && !sending
            && !draft.files.contains { $0.uploading }
    }

    /// Sends the reply. Returns the line to show ("Sent", "Scheduled for …").
    func send() async -> String? {
        guard canSend else { return nil }
        saveTask?.cancel()
        sending = true; sendError = ""
        let at = draft.sendAt
        do {
            _ = try await box.send(draft)
            sending = false
            draft = MailDraft()
            await reload()
            return at.map { "Scheduled: " + MailText.sendsText($0).replacingOccurrences(of: "Sends ", with: "") } ?? "Sent"
        } catch {
            sending = false
            sendError = (error as? APIClient.APIError)?.message ?? "Couldn't send. Try again."
            return nil
        }
    }

    func insert(_ text: String) {
        let t = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.text = t.isEmpty ? text : t + "\n\n" + text
        textChanged()
    }

    func attach(_ data: Data, name: String, type: String) {
        let temp = MailOutFile(name: name, type: type, size: data.count, blobId: nil, uploading: true)
        draft.files.append(temp)
        Task {
            do {
                let f = try await box.upload(data, name: name, type: type)
                if let i = draft.files.firstIndex(where: { $0.id == temp.id }) { draft.files[i] = f }
                textChanged()
            } catch {
                draft.files.removeAll { $0.id == temp.id }
                sendError = (error as? APIClient.APIError)?.message ?? "Couldn't attach \(name)."
            }
        }
    }

    /// Saves to the client's private notes: the email's date, subject and what it asks (or its first words).
    func saveToNotes(_ clientId: String) async -> Bool {
        guard let t = thread, let last = t.emails.last(where: { !$0.fromMe }) else { return false }
        let main = MailText.splitQuote(last.text ?? "").main
        let what: String = (t.asks ?? []).isEmpty ? String(main.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(280))
                                                  : (t.asks ?? []).joined(separator: " ")
        let line = "Email \(last.receivedAt.formatted(.dateTime.month(.abbreviated).day())), “\(t.subject)”: \(what.trimmingCharacters(in: .whitespaces))"
        do {
            let cur = (try? await APIClient.shared.clientNote(clientId: clientId))?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try await APIClient.shared.saveClientNote(clientId: clientId, body: cur.isEmpty ? line : cur + "\n\n" + line)
            return true
        } catch { return false }
    }
}
