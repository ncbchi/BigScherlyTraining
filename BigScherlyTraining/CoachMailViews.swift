import SwiftUI
import Combine
import WebKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Coach email: the parts the phone and the iPad share, and the phone screens (Oct 15, 2026)
//
// Canvas row "Coach Inbox (coach@) on iPhone and iPad". The phone gets the list (folders, search,
// All · Clients · Others), a thread screen with who it's from on top, and a reply bar; New email is a
// sheet. The iPad (CoachPad/PadMail.swift) lays the same parts out in three panes in its own look,
// which is why every part here reads its colours and fonts from MailLook.
// Synchronized folder: no target step needed.

// MARK: Look

struct MailLook {
    var pad: Bool
    var page: Color { pad ? Pad.page : Brand.bg }
    var card: Color { pad ? Pad.surface : Brand.black }
    var field: Color { pad ? Pad.well : Brand.black }
    var raised: Color { pad ? Pad.raised : Brand.text.opacity(0.08) }
    var text: Color { pad ? Pad.text : Brand.text }
    var mute: Color { pad ? Pad.mute : Brand.mute }
    var faint: Color { pad ? Pad.faint : Brand.mute.opacity(0.8) }
    var line: Color { pad ? Pad.line : Brand.line }
    var line2: Color { pad ? Pad.line2 : Brand.text.opacity(0.18) }
    var fill: Color { pad ? Pad.volt : Brand.volt }
    var onFill: Color { pad ? Pad.onVolt : Brand.onVolt }
    var accentText: Color { pad ? Pad.voltText : Brand.voltText }
    var accentLine: Color { pad ? Pad.voltText.opacity(0.5) : Brand.voltLine }
    var warn: Color { pad ? Pad.orange : Color.orange }
    var automatic: Color { (pad ? Pad.isLight : Palette.current.scheme == .light) ? Color(hex: 0x3B3B8F) : Color(hex: 0x8C8CF5) }
    func title(_ s: CGFloat) -> Font { pad ? PadFont.display(s) : BrandFont.display(s) }
    func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { pad ? PadFont.ui(s, w) : BrandFont.body(s, w) }
    func label(_ s: CGFloat) -> Font { pad ? PadFont.cond(s) : BrandFont.body(s, .bold) }

    static let phone = MailLook(pad: false)
    static let iPad = MailLook(pad: true)
}

/// What the screens around the mail parts can do (open a client, a chat, show a toast).
struct MailActions {
    var openClient: (String) -> Void = { _ in }
    var answerInMessages: (String) -> Void = { _ in }
    var openWorkouts: ((String) -> Void)? = nil
    var toast: (String, (() -> Void)?) -> Void = { _, _ in }
    /// The open thread left this folder (moved, deleted): close the reader.
    var closed: (String) -> Void = { _ in }
}

private struct MailLookKey: EnvironmentKey { static let defaultValue = MailLook.phone }
private struct MailActionsKey: EnvironmentKey { static let defaultValue = MailActions() }
extension EnvironmentValues {
    var mailLook: MailLook { get { self[MailLookKey.self] } set { self[MailLookKey.self] = newValue } }
    var mailActions: MailActions { get { self[MailActionsKey.self] } set { self[MailActionsKey.self] = newValue } }
}

// MARK: Small parts

struct MailAvatar: View {
    let name: String
    var clientId: String? = nil
    var me = false
    var size: CGFloat = 34
    @Environment(\.mailLook) private var look
    var body: some View {
        Group {
            if me {
                Text((AppStore.shared.trainerName.isEmpty ? "Coach" : AppStore.shared.trainerName).initials)
                    .font(look.title(size * 0.42)).foregroundColor(look.onFill)
                    .frame(width: size, height: size).background(Circle().fill(look.fill))
            } else if look.pad {
                PadAvatar(name: name, size: size, id: clientId)
            } else {
                CoachAvatar(name: name, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

struct MailTag: View {
    enum Kind { case plain, client, person, automatic, warn }
    let text: String
    var kind: Kind = .plain
    var icon: String? = nil
    var accent: String? = nil
    @Environment(\.mailLook) private var look
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            if !text.isEmpty { Text(text).font(look.label(11.5)).lineLimit(1) }
        }
        .foregroundColor(fg)
        .padding(.horizontal, 7).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(bg))
    }
    private var clientTint: Color {
        if let v = ClientAccents.parse(accent) { return RGBColor(hex: v).color }
        return look.fill
    }
    private var fg: Color {
        switch kind {
        case .plain, .client: return look.text
        case .person, .warn: return look.warn
        case .automatic: return look.automatic
        }
    }
    private var bg: Color {
        switch kind {
        case .plain, .warn: return look.raised
        case .client: return clientTint.opacity(0.26)
        case .person: return look.warn.opacity(0.18)
        case .automatic: return look.automatic.opacity(0.16)
        }
    }
}

// MARK: A row in the list

struct MailRow: View {
    let item: MailItem
    let folder: String
    var selected = false
    @Environment(\.mailLook) private var look

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(item.unread ? look.accentText : Color.clear).frame(width: 8, height: 8).padding(.top, 13)
            MailAvatar(name: item.who, clientId: item.clientId, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(nameLine).font(look.ui(15, item.unread ? .bold : .semibold)).foregroundColor(look.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MailText.when(item.receivedAt)).font(look.label(12)).foregroundColor(look.faint)
                }
                Text(item.subject.isEmpty ? "(no subject)" : item.subject).font(look.ui(14, .semibold)).foregroundColor(look.text).lineLimit(1)
                Text(item.preview).font(look.ui(13.5)).foregroundColor(look.mute).lineLimit(1)
                tags.padding(.top, 3)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, look.pad ? 14 : 0)
        .background(selected ? (look.pad ? Pad.surface : look.raised) : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(look.fill).frame(width: 3) } }
        .overlay(alignment: .bottom) { Rectangle().fill(look.line).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.unread ? "Unread. " : "")\(nameLine), \(item.subject), \(MailText.when(item.receivedAt))")
    }

    private var nameLine: String {
        (item.fromMe && folder != "sent" && folder != "drafts" ? "To " : "") + item.who
    }

    private var tags: some View {
        HStack(spacing: 5) {
            if folder != "sent" && folder != "drafts" {
                switch item.kind {
                case "client": MailTag(text: "Client", kind: .client, accent: item.accent)
                case "person": MailTag(text: "Not a client", kind: .person)
                case "automatic": MailTag(text: "Automatic", kind: .automatic)
                default: EmptyView()
                }
            } else if item.kind == "client" {
                MailTag(text: "Client", kind: .client, accent: item.accent)
            }
            if let s = item.scheduledAt { MailTag(text: MailText.sendsText(s), icon: "clock") }
            if let w = item.waitingSince, folder == "inbox" { MailTag(text: MailText.waitingText(w), kind: .warn) }
            else if item.answered && folder == "inbox" { MailTag(text: "Answered") }
            if item.hasDraft && folder != "drafts" { MailTag(text: "Draft") }
            if item.hasAttachment { MailTag(text: "", icon: "paperclip") }
            if item.count > 1 { MailTag(text: "\(item.count)") }
        }
    }
}

// MARK: The thread's actions (archive, junk, trash…), the same list on both

struct MailThreadAction: Identifiable {
    let id: String
    let label: String
    let icon: String
    var destructive = false
    let run: () -> Void
}

@MainActor
enum MailThreadActions {
    static func list(threadId: String, folder: String, look: MailLook, actions: MailActions, confirmDelete: @escaping () -> Void) -> [MailThreadAction] {
        let box = MailBox.shared
        func move(_ to: String, _ done: String) {
            Task {
                do {
                    try await box.move(threadId, to: to)
                    actions.closed(threadId)
                    actions.toast(done, { Task { await box.undoMove(threadId, movedTo: to, from: folder) } })
                } catch {
                    actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't move it.", nil)
                }
            }
        }
        var out: [MailThreadAction] = []
        if folder == "inbox" { out.append(MailThreadAction(id: "archive", label: "Archive", icon: "archivebox") { move("archive", "Archived") }) }
        if folder == "archive" || folder == "junk" || folder == "trash" {
            out.append(MailThreadAction(id: "inbox", label: folder == "junk" ? "Not junk: move to Inbox" : "Move to Inbox", icon: "tray") { move("inbox", "Moved to Inbox") })
        }
        if folder != "junk" && folder != "sent" && folder != "drafts" {
            out.append(MailThreadAction(id: "junk", label: "Junk", icon: "xmark.octagon") { move("junk", "Moved to Junk") })
        }
        if folder != "sent" && folder != "drafts" {
            out.append(MailThreadAction(id: "unread", label: "Mark as unread", icon: "envelope.badge") {
                Task {
                    do { try await box.markRead(threadId, false); actions.closed(threadId) }
                    catch { actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't do that.", nil) }
                }
            })
        }
        if folder == "trash" || folder == "junk" {
            out.append(MailThreadAction(id: "delete", label: "Delete forever", icon: "trash", destructive: true) { confirmDelete() })
        } else {
            out.append(MailThreadAction(id: "trash", label: "Trash", icon: "trash", destructive: true) { move("trash", "Moved to Trash") })
        }
        return out
    }
}

// MARK: HTML email (sandboxed, remote pictures off until asked)

struct MailHTMLBlock: View {
    let id: String
    let html: String
    let showImages: Bool
    @State private var height: CGFloat = 160
    var body: some View {
        MailHTMLView(html: html, showImages: showImages, height: $height)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MailHTMLView: UIViewRepresentable {
    let html: String
    let showImages: Bool
    @Binding var height: CGFloat

    static func document(_ html: String, showImages: Bool) -> String {
        let csp = "default-src 'none'; style-src 'unsafe-inline'; font-src data:; img-src data: cid:" + (showImages ? " https: http:" : "")
        let body = showImages ? html : MailText.noRemote(html)
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<style>html,body{margin:0;padding:8px 10px;font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.45;color:#141416;background:#fff;overflow-wrap:anywhere}"
            + "img{max-width:100%;height:auto}table{max-width:100%}blockquote{margin:6px 0;padding-left:10px;border-left:3px solid #ddd;color:#666}</style></head><body>"
            + body + "</body></html>"
    }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.isOpaque = false
        wv.backgroundColor = .white
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let doc = Self.document(html, showImages: showImages)
        if context.coordinator.loaded != doc {
            context.coordinator.loaded = doc
            wv.loadHTMLString(doc, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loaded: String?
        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak webView] in
                if let webView { self?.measure(webView) }
            }
        }

        private func measure(_ wv: WKWebView) {
            wv.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] v, _ in
                let h: CGFloat = (v as? NSNumber).map { CGFloat($0.doubleValue) } ?? wv.scrollView.contentSize.height
                let fit = min(4000, max(60, h + 4))
                DispatchQueue.main.async { if abs((self?.height.wrappedValue ?? 0) - fit) > 1 { self?.height.wrappedValue = fit } }
            }
        }

        /// Links open in Safari, never inside the email.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let s = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(s) { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: One email in a thread

struct MailEmailCard: View {
    let email: MailEmail
    let open: Bool
    @ObservedObject var model: MailThreadModel
    var onFile: (MailAttachment) -> Void = { _ in }
    @Environment(\.mailLook) private var look

    var body: some View {
        if open { full } else { folded }
    }

    private var who: String { email.fromMe ? "You" : (email.from?.shown ?? "Someone") }
    private var contactClientId: String? {
        guard let c = model.thread?.contact, let e = c.email, let f = email.from?.email, e.lowercased() == f.lowercased() else { return nil }
        return c.clientId
    }

    private var folded: some View {
        let snippet = (email.text ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return Button { model.openOld.insert(email.id) } label: {
            HStack(spacing: 10) {
                MailAvatar(name: who, clientId: contactClientId, me: email.fromMe, size: 26)
                Text(email.fromMe ? "You" : (email.from?.shown ?? "").firstName).font(look.ui(13, .bold)).foregroundColor(look.text).fixedSize()
                Text(String(snippet.prefix(110))).font(look.ui(13)).foregroundColor(look.mute).lineLimit(1)
                Spacer(minLength: 4)
                Text(MailText.when(email.receivedAt)).font(look.label(12)).foregroundColor(look.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(look.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(email.fromMe ? look.accentLine.opacity(0.6) : look.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Earlier email from \(who). Tap to open.")
    }

    private var addressLine: String {
        let to = email.toList.map { $0.shown }.joined(separator: ", ")
        if email.fromMe { return "to \(to)" }
        return (email.from?.email ?? "") + (to.isEmpty ? "" : " → \(to)")
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MailAvatar(name: who, clientId: contactClientId, me: email.fromMe, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(who).font(look.ui(15, .bold)).foregroundColor(look.text)
                    Text(addressLine).font(look.label(12.5)).foregroundColor(look.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(MailText.whenLong(email.receivedAt)).font(look.label(12.5)).foregroundColor(look.faint).lineLimit(1)
            }
            bodyView
            if !email.files.isEmpty { files }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(look.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(email.fromMe ? look.accentLine.opacity(0.6) : look.line, lineWidth: 1))
    }

    @ViewBuilder private var bodyView: some View {
        if let html = email.html, !html.isEmpty {
            let shown = model.showImages.contains(email.id)
            if !shown && MailText.hasRemoteImages(html) {
                HStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 13)).foregroundColor(look.mute)
                    Text("Pictures are hidden so the sender can't tell you opened it.").font(look.ui(12.5)).foregroundColor(look.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Show pictures") { model.showImages.insert(email.id) }
                        .font(look.ui(13, .bold)).foregroundColor(look.accentText)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(look.raised))
            }
            MailHTMLBlock(id: email.id, html: html, showImages: shown)
        } else {
            let parts = MailText.splitQuote(email.text ?? "")
            Text(parts.main).font(look.ui(15)).foregroundColor(look.text).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !parts.quoted.isEmpty {
                if model.openQuote.contains(email.id) {
                    Text(parts.quoted).font(look.ui(14)).foregroundColor(look.mute).lineSpacing(2)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(look.line2).frame(width: 3) }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("··· \(parts.quoted.components(separatedBy: "\n").count) quoted lines · show") { model.openQuote.insert(email.id) }
                        .font(look.label(13)).foregroundColor(look.faint)
                }
            }
        }
    }

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(email.files, id: \.blobId) { a in
                    Button { onFile(a) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold))
                            Text(a.fileName).font(look.ui(13, .semibold)).lineLimit(1)
                            Text(MailText.size(a.size)).font(look.label(12)).foregroundColor(look.mute)
                        }
                        .foregroundColor(look.text)
                        .padding(.horizontal, 12).frame(minHeight: 40)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.line2, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(a.fileName)")
                }
            }
        }
    }
}

// MARK: The emails of a thread, newest at the bottom

struct MailThreadEmails: View {
    @ObservedObject var model: MailThreadModel
    var onFile: (MailAttachment) -> Void
    var body: some View {
        if let t = model.thread {
            let n = t.emails.count
            ForEach(Array(t.emails.enumerated()), id: \.element.id) { i, e in
                MailEmailCard(email: e, open: i >= n - 2 || model.openOld.contains(e.id), model: model, onFile: onFile)
                    .id(e.id)
            }
        }
    }
}

// MARK: Who it's from (client card, automatic, or someone new)

struct MailContactPanel: View {
    @ObservedObject var model: MailThreadModel
    var compact = false
    @EnvironmentObject var store: AppStore
    @Environment(\.mailLook) private var look
    @Environment(\.mailActions) private var actions
    @State private var adding: Bool? = nil        // the Add sheet; true = also send the invite
    @State private var linking = false

    var body: some View {
        if let t = model.thread, let c = t.contact {
            VStack(alignment: .leading, spacing: 12) {
                if let id = c.clientId, let r = store.roster.first(where: { $0.id == id }) {
                    clientCard(c, r)
                } else if c.kind == "automatic" {
                    automaticCard(c, t)
                } else {
                    personCard(c)
                }
                if let asks = t.asks, !asks.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(look.pad ? "This email asks" : "THIS EMAIL ASKS").font(look.pad ? look.ui(14, .bold) : BrandFont.body(11, .heavy))
                            .tracking(look.pad ? 0 : 1.4).foregroundColor(look.pad ? look.text : look.mute)
                        ForEach(asks, id: \.self) { a in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").foregroundColor(look.mute)
                                Text(a).font(look.ui(14)).foregroundColor(look.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(look.raised.opacity(look.pad ? 1 : 0.6)))
                }
            }
            .sheet(item: Binding(get: { adding.map { AddWrap(invite: $0) } }, set: { adding = $0?.invite })) { w in
                MailAddClientSheet(contact: c, invite: w.invite) { _ in
                    Task { await model.reload(); await MailBox.shared.load() }
                }
                .environmentObject(store)
            }
            .confirmationDialog("Which client is \(c.email ?? "this")?", isPresented: $linking, titleVisibility: .visible) {
                ForEach(store.roster.sorted { $0.name < $1.name }) { r in
                    Button(r.name) { link(c, r) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private struct AddWrap: Identifiable { let invite: Bool; var id: String { invite ? "i" : "a" } }

    private func clientCard(_ c: MailContact, _ r: RosterItem) -> some View {
        let first = r.name.firstName
        let onFile: String = (c.clientEmail ?? "").lowercased() != (c.email ?? "").lowercased() && c.clientEmail != nil
            ? "Their email on file is \(c.clientEmail ?? ""). You linked \(c.email ?? "") to them."
            : "Matched by the email on file, \(c.email ?? "")."
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MailAvatar(name: r.name, clientId: r.id, size: compact ? 36 : 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(compact ? r.name : r.name.uppercased()).font(compact ? look.ui(15, .bold) : look.title(26)).foregroundColor(look.text).lineLimit(1)
                    Text("Client · " + r.headline).font(look.label(12.5)).foregroundColor(look.mute).lineLimit(1)
                }
                Spacer(minLength: 4)
                if compact {
                    Button { actions.answerInMessages(r.id) } label: {
                        Image(systemName: "bubble.left.fill").font(.system(size: 14, weight: .bold)).foregroundColor(look.onFill)
                            .frame(width: 38, height: 38).background(Circle().fill(look.fill))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Answer \(first) in Messages")
                    Menu {
                        Button { actions.answerInMessages(r.id) } label: { Label("Answer in Messages", systemImage: "bubble.left") }
                        Button { saveNotes(r) } label: { Label("Save to \(first)'s notes", systemImage: "pin") }
                        Button { actions.openClient(r.id) } label: { Label("Open \(first)", systemImage: "person") }
                        if c.linked == true { Button(role: .destructive) { unlink(c) } label: { Label("Unlink this address", systemImage: "link") } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundColor(look.text)
                            .frame(width: 38, height: 38).overlay(Circle().stroke(look.line2, lineWidth: 1))
                    }
                    .accessibilityLabel("More about \(first)")
                }
            }
            if !compact {
                VStack(alignment: .leading, spacing: 8) {
                    actionButton("Answer in Messages", "bubble.left") { actions.answerInMessages(r.id) }
                    if let w = actions.openWorkouts { actionButton("Open \(first)'s workouts", "calendar") { w(r.id) } }
                    actionButton("Save to \(first)'s notes", "pin") { saveNotes(r) }
                    actionButton("Open \(first)", "person") { actions.openClient(r.id) }
                }
                HStack(spacing: 4) {
                    Text(onFile).font(look.ui(12)).foregroundColor(look.mute).fixedSize(horizontal: false, vertical: true)
                    if c.linked == true { Button("Unlink") { unlink(c) }.font(look.ui(12, .bold)).foregroundColor(look.accentText) }
                }
            }
        }
        .modifier(MailPanelBox(compact: compact))
    }

    private func automaticCard(_ c: MailContact, _ t: MailThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MailAvatar(name: c.shown, size: compact ? 36 : 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.shown).font(look.ui(15, .bold)).foregroundColor(look.text).lineLimit(1)
                    Text("Automatic email").font(look.label(12.5)).foregroundColor(look.automatic)
                }
            }
            Text("Receipts, app stores, renewals and newsletters. They never count as waiting on you.")
                .font(look.ui(13)).foregroundColor(look.mute).fixedSize(horizontal: false, vertical: true)
        }
        .modifier(MailPanelBox(compact: compact))
    }

    private func personCard(_ c: MailContact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MailAvatar(name: c.shown, size: compact ? 44 : 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.shown.uppercased()).font(look.title(compact ? 22 : 26)).foregroundColor(look.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text("Not a client yet" + (compact ? " · \(c.email ?? "")" : "")).font(look.label(12.5)).foregroundColor(look.warn).lineLimit(1)
                }
            }
            if !compact { Text(c.email ?? "").font(look.ui(13)).foregroundColor(look.mute) }
            primaryButton("Add as a client", "person.badge.plus") { adding = false }
            HStack(spacing: 8) {
                actionButton(compact ? "Add + invite" : "Add and send the invite", "envelope") { adding = true }
                actionButton("This is a client…", "link") { linking = true }
            }
            if !look.pad || !compact {
                Menu {
                    ForEach(store.savedReplies, id: \.self) { r in Button(r) { model.insert(r) } }
                } label: {
                    Label("Reply with a saved reply", systemImage: "text.bubble").font(look.ui(14, .semibold)).foregroundColor(look.text)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(RoundedRectangle(cornerRadius: look.pad ? 9 : 20).stroke(look.line2, lineWidth: 1))
                }
            }
            Text("Adding them fills in their name and email from this one. Nothing is sent until you choose the invite.")
                .font(look.ui(12)).foregroundColor(look.mute).fixedSize(horizontal: false, vertical: true)
        }
        .modifier(MailPanelBox(compact: compact, warn: true))
    }

    private func actionButton(_ t: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(t, systemImage: icon).font(look.ui(14, .semibold)).foregroundColor(look.text).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: look.pad ? .leading : .center)
                .padding(.horizontal, 12).frame(minHeight: 40)
                .overlay(RoundedRectangle(cornerRadius: look.pad ? 9 : 20).stroke(look.line2, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ t: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(t, systemImage: icon).font(look.ui(15, .bold)).foregroundColor(look.onFill)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: look.pad ? 11 : 23).fill(look.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveNotes(_ r: RosterItem) {
        Task {
            let ok = await model.saveToNotes(r.id)
            actions.toast(ok ? "Saved to \(r.name.firstName)'s notes" : "Couldn't save it. Try again.", nil)
        }
    }

    private func link(_ c: MailContact, _ r: RosterItem) {
        guard let e = c.email else { return }
        Task {
            do {
                try await MailBox.shared.link(e, to: r.id)
                await model.reload()
                actions.toast("Linked to \(r.name)", nil)
            } catch { actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't link it.", nil) }
        }
    }

    private func unlink(_ c: MailContact) {
        guard let e = c.email else { return }
        Task {
            do {
                try await MailBox.shared.link(e, to: nil)
                await model.reload()
                actions.toast("Unlinked", nil)
            } catch { actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't unlink it.", nil) }
        }
    }
}

private struct MailPanelBox: ViewModifier {
    var compact: Bool
    var warn = false
    @Environment(\.mailLook) private var look
    @ViewBuilder func body(content: Content) -> some View {
        if compact {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(look.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(warn ? look.warn.opacity(0.45) : look.line, lineWidth: 1))
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Add as a client (from an email)

struct MailAddClientSheet: View {
    let contact: MailContact
    let invite: Bool
    var onDone: (String) -> Void = { _ in }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailLook) private var look
    @State private var name = ""
    @State private var email = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(invite ? "Add them and email the welcome link with their Set Up My Account button."
                                : "Adds them to your clients. Nothing is sent: invite them from Invites when you're ready.")
                        .font(look.ui(14)).foregroundColor(look.mute).fixedSize(horizontal: false, vertical: true)
                    field("Name", $name, .name)
                    field("Email", $email, .emailAddress)
                    if let error { Text(error).font(look.ui(13)).foregroundColor(look.warn) }
                    Button { add() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(look.onFill) }
                            Text(invite ? "Add and send the invite" : "Add as a client")
                        }
                        .font(look.ui(15, .bold)).foregroundColor(look.onFill)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: look.pad ? 11 : 24).fill(look.fill))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !MailText.isEmail(email.trimmingCharacters(in: .whitespaces)))
                }
                .padding(20)
            }
            .background(look.page.ignoresSafeArea())
            .navigationTitle(invite ? "Add and invite" : "Add as a client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(look.accentText) } }
            .onAppear {
                if name.isEmpty {
                    let n = (contact.name ?? "").trimmingCharacters(in: .whitespaces)
                    name = n.isEmpty ? String((contact.email ?? "").split(separator: "@").first ?? "") : n
                    email = contact.email ?? ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func field(_ label: String, _ text: Binding<String>, _ type: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(look.label(12.5)).foregroundColor(look.mute)
            TextField(label, text: text)
                .textContentType(type)
                .keyboardType(type == .emailAddress ? .emailAddress : .default)
                .textInputAutocapitalization(type == .emailAddress ? .never : .words)
                .autocorrectionDisabled()
                .font(look.ui(16)).foregroundColor(look.text)
                .padding(.horizontal, 12).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 10).fill(look.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.line2, lineWidth: 1))
        }
    }

    private func add() {
        busy = true; error = nil
        let n = name.trimmingCharacters(in: .whitespaces), e = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let id = try await APIClient.shared.mailAddClient(name: n, email: e, invite: invite)
                store.loadRoster()
                busy = false
                onDone(id)
                dismiss()
            } catch {
                busy = false
                self.error = (error as? APIClient.APIError)?.message ?? "Couldn't add them. Try again."
            }
        }
    }
}

// MARK: Attaching files (Files or Photos)

struct MailAttachMenu<Label: View>: View {
    let add: (Data, String, String) -> Void
    var onError: (String) -> Void = { _ in }
    @ViewBuilder var label: () -> Label
    @State private var files = false
    @State private var photos = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { photos = true } label: { SwiftUI.Label("Photo or video", systemImage: "photo") }
            Button { files = true } label: { SwiftUI.Label("File", systemImage: "folder") }
        } label: { label() }
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: u) else { onError("Couldn't read \(u.lastPathComponent)."); continue }
                let type = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                add(d, u.lastPathComponent, type)
            }
        }
        .photosPicker(isPresented: $photos, selection: $picked, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            let list = items
            picked = []
            Task {
                for (i, item) in list.enumerated() {
                    guard let d = try? await item.loadTransferable(type: Data.self) else { onError("Couldn't read that photo."); continue }
                    let t: UTType = item.supportedContentTypes.first ?? .jpeg
                    let ext = t.preferredFilenameExtension ?? "jpg"
                    let kind = t.conforms(to: .movie) ? "video" : "photo"
                    add(d, "\(kind)-\(i + 1).\(ext)", t.preferredMIMEType ?? "application/octet-stream")
                }
            }
        }
    }
}

// MARK: Send later

struct MailLaterMenu<Label: View>: View {
    @Binding var sendAt: Date?
    @ViewBuilder var label: () -> Label
    @State private var picking = false
    var body: some View {
        Menu {
            ForEach(MailText.laterChoices()) { c in Button(c.label) { sendAt = c.at } }
            Button("Pick a time…") { picking = true }
            if sendAt != nil { Button("Send now instead") { sendAt = nil } }
        } label: { label() }
        .sheet(isPresented: $picking) { MailPickTime(sendAt: $sendAt) }
    }
}

struct MailPickTime: View {
    @Binding var sendAt: Date?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailLook) private var look
    @State private var when = Date().addingTimeInterval(3600)
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                DatePicker("When", selection: $when, in: Date().addingTimeInterval(60)...Date().addingTimeInterval(29 * 86_400),
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).tint(look.accentText)
                Text("Up to 29 days ahead. It waits on the mail server, so your phone can be off.")
                    .font(look.ui(12)).foregroundColor(look.mute)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(look.page.ignoresSafeArea())
            .navigationTitle("Send later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(look.accentText) }
                ToolbarItem(placement: .topBarTrailing) { Button("Set") { sendAt = when; dismiss() }.font(.body.bold()).foregroundColor(look.accentText) }
            }
            .onAppear { if let s = sendAt { when = s } }
        }
        .presentationDetents([.large])
    }
}

/// The files on an email being written, each removable.
struct MailOutFiles: View {
    @Binding var files: [MailOutFile]
    @Environment(\.mailLook) private var look
    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files) { f in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold))
                            Text(f.name).font(look.ui(13, .semibold)).lineLimit(1)
                            if f.uploading { ProgressView().controlSize(.mini) }
                            else { Text(MailText.size(Int64(f.size))).font(look.label(12)).foregroundColor(look.mute) }
                            Button { files.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(look.mute).frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(f.name)")
                        }
                        .foregroundColor(look.text)
                        .padding(.leading, 10).padding(.trailing, 4).frame(minHeight: 34)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.line2, lineWidth: 1))
                    }
                }
            }
        }
    }
}

// MARK: The reply bar under a thread

struct MailReplyBar: View {
    @ObservedObject var model: MailThreadModel
    @EnvironmentObject var store: AppStore
    @Environment(\.mailLook) private var look
    @Environment(\.mailActions) private var actions
    @FocusState private var focused: Bool

    var body: some View {
        let target = model.replyTarget
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                (Text(model.draft.replyAll ? "Reply all to " : "Reply to ") + Text(target.name).bold() + Text(" · from coach@"))
                    .font(look.label(12.5)).foregroundColor(look.mute).lineLimit(1)
                Spacer(minLength: 4)
                if model.saving { MailTag(text: "Saving…") }
                else if model.draft.draftId != nil && !model.draft.dirty { MailTag(text: "Draft saved") }
                if let at = model.draft.sendAt { MailTag(text: MailText.sendsText(at), icon: "clock") }
            }
            TextField("", text: Binding(get: { model.draft.text }, set: { model.draft.text = $0; model.textChanged() }),
                      prompt: Text("Write to \(target.name.firstName)…").foregroundColor(look.faint), axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
                .font(look.ui(15)).foregroundColor(look.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(look.field))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? look.accentLine : look.line2, lineWidth: focused ? 1.5 : 1))
            if focused && !model.box.signature.isEmpty {
                Text(model.box.signature).font(look.ui(12.5)).foregroundColor(look.mute).padding(.horizontal, 4)
            }
            MailOutFiles(files: $model.draft.files)
            if !model.sendError.isEmpty { Text(model.sendError).font(look.ui(12.5)).foregroundColor(look.warn) }
            HStack(spacing: 6) {
                MailAttachMenu(add: { d, n, t in model.attach(d, name: n, type: t) }, onError: { model.sendError = $0 }) {
                    toolIcon("paperclip", "Attach")
                }
                Menu {
                    ForEach(store.savedReplies, id: \.self) { r in Button(r.count > 60 ? String(r.prefix(57)) + "…" : r) { model.insert(r) } }
                } label: { toolIcon("text.bubble", "Saved replies") }
                if target.many {
                    Button(model.draft.replyAll ? "Just them" : "Reply all") { model.draft.replyAll.toggle(); model.textChanged() }
                        .font(look.ui(13, .semibold)).foregroundColor(look.text)
                        .padding(.horizontal, 10).frame(minHeight: 38)
                        .overlay(RoundedRectangle(cornerRadius: look.pad ? 9 : 19).stroke(look.line2, lineWidth: 1))
                }
                Spacer(minLength: 4)
                MailLaterMenu(sendAt: $model.draft.sendAt) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 13, weight: .semibold))
                        Text(model.draft.sendAt == nil ? "Send later" : "Change time").font(look.ui(13, .semibold))
                    }
                    .foregroundColor(look.text)
                    .padding(.horizontal, 11).frame(minHeight: 38)
                    .overlay(RoundedRectangle(cornerRadius: look.pad ? 9 : 19).stroke(look.line2, lineWidth: 1))
                }
                Button { send() } label: {
                    HStack(spacing: 6) {
                        if model.sending { ProgressView().tint(look.onFill).controlSize(.small) }
                        Text(model.draft.sendAt == nil ? "Send" : "Schedule")
                    }
                    .font(look.ui(14, .bold)).foregroundColor(look.onFill)
                    .padding(.horizontal, 16).frame(minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: look.pad ? 9 : 19).fill(look.fill))
                    .opacity(model.canSend ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, look.pad ? 16 : 14).padding(.top, 10).padding(.bottom, look.pad ? 14 : 10)
        .background(look.page)
        .overlay(alignment: .top) { Rectangle().fill(look.line).frame(height: 1) }
    }

    private func toolIcon(_ name: String, _ label: String) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundColor(look.text)
            .frame(width: 38, height: 38)
            .overlay(RoundedRectangle(cornerRadius: look.pad ? 9 : 19).stroke(look.line2, lineWidth: 1))
            .accessibilityLabel(label)
    }

    private func send() {
        focused = false
        Task {
            if let msg = await model.send() { actions.toast(msg, nil) }
        }
    }
}

// MARK: New email

struct MailComposeSheet: View {
    var prefillTo: [MailRecipient] = []
    var onSent: (String) -> Void = { _ in }
    @EnvironmentObject var store: AppStore
    @ObservedObject private var box = MailBox.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailLook) private var look
    @State private var d = MailDraft()
    @State private var typed = ""
    @State private var showCc = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var started = false
    @FocusState private var toFocused: Bool

    private var separate: Bool { d.to.contains { $0.isGroup } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labeled("From") { Text("coach@bigscherlytraining.com").font(look.ui(15)).foregroundColor(look.text) }
                    labeled("To") { toField }
                    if separate {
                        Text("A group goes as separate emails, one to each person, so nobody sees anyone else's address.")
                            .font(look.ui(12)).foregroundColor(look.mute).fixedSize(horizontal: false, vertical: true)
                    }
                    if showCc {
                        labeled("Cc") { input("Comma-separated", $d.cc, keyboard: .emailAddress) }
                    } else {
                        Button("Add Cc") { showCc = true }.font(look.ui(13, .semibold)).foregroundColor(look.accentText)
                    }
                    labeled("Subject") { input("Subject", $d.subject) }
                    TextField("", text: $d.text, prompt: Text("Write your email…").foregroundColor(look.faint), axis: .vertical)
                        .lineLimit(8...)
                        .font(look.ui(15)).foregroundColor(look.text)
                        .padding(12)
                        .frame(minHeight: 200, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(look.field))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.accentLine, lineWidth: 1.5))
                    if !box.signature.isEmpty { Text(box.signature).font(look.ui(12.5)).foregroundColor(look.mute).padding(.horizontal, 4) }
                    MailOutFiles(files: $d.files)
                    if let error { Text(error).font(look.ui(13)).foregroundColor(look.warn).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .background(look.page.ignoresSafeArea())
            .navigationTitle("New email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dismiss() } else { confirmDiscard = true } }
                        .foregroundColor(look.accentText)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Save draft") { saveDraft() }.foregroundColor(look.accentText) }
            }
            .confirmationDialog("Discard this email?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Save draft") { saveDraft() }
            } message: { Text("Save draft keeps it in Drafts.") }
            .task {
                if !started { started = true; d.to = prefillTo; if !prefillTo.isEmpty { toFocused = false } else { toFocused = true } }
                if box.people == nil { await box.loadPeople() }
            }
        }
        .interactiveDismissDisabled(!d.text.isEmpty)
    }

    // To: chips, the typed text, and suggestions under it.
    private var toField: some View {
        VStack(alignment: .leading, spacing: 6) {
            MailFlowRow(spacing: 6) {
                ForEach(d.to) { r in token(r) }
                TextField("", text: $typed, prompt: Text(d.to.isEmpty ? "Start typing a client or a group" : "").foregroundColor(look.faint))
                    .focused($toFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    .font(look.ui(15)).foregroundColor(look.text)
                    .frame(minWidth: 140, minHeight: 32)
                    .onSubmit { if let first = suggestions.first { add(first) } else { addTyped() } }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).fill(look.field))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.line2, lineWidth: 1))
            let sug = suggestions
            if !sug.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sug.enumerated()), id: \.offset) { i, s in
                        Button { add(s) } label: {
                            HStack(spacing: 10) {
                                if s.isGroup {
                                    Image(systemName: "person.2.fill").font(.system(size: 13)).foregroundColor(look.text)
                                        .frame(width: 28, height: 28).background(Circle().fill(look.raised))
                                } else {
                                    MailAvatar(name: s.name, clientId: s.clientId, size: 28)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(look.ui(14, .semibold)).foregroundColor(look.text).lineLimit(1)
                                    Text(s.sub).font(look.label(12)).foregroundColor(look.mute).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < sug.count - 1 { Rectangle().fill(look.line).frame(height: 1).padding(.leading, 48) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(look.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.line2, lineWidth: 1))
            }
        }
    }

    private struct Suggestion {
        let name: String
        let email: String
        var clientId: String?
        let sub: String
        var group: [MailAddr] = []
        var isGroup: Bool { !group.isEmpty }
    }

    private var suggestions: [Suggestion] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let has: (String) -> Bool = { e in d.to.contains { $0.email.lowercased() == e.lowercased() } }
        var out: [Suggestion] = []
        for c in box.people?.clients ?? [] {
            guard let e = c.email, !e.isEmpty, !has(e) else { continue }
            if c.name.lowercased().contains(q) || e.lowercased().contains(q) {
                out.append(Suggestion(name: c.name, email: e, clientId: c.id, sub: "Client · \(e)"))
            }
        }
        for o in box.people?.others ?? [] {
            guard !has(o.email) else { continue }
            if (o.name ?? "").lowercased().contains(q) || o.email.lowercased().contains(q) {
                let when: String = o.lastAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
                out.append(Suggestion(name: (o.name ?? "").isEmpty ? o.email : (o.name ?? ""), email: o.email, sub: "\(o.wrote == true ? "Emailed you" : "You emailed") \(when) · not a client"))
            }
        }
        for g in MailGroups.all(people: box.people) where g.label.lowercased().contains(q) {
            out.append(Suggestion(name: g.label, email: "", sub: "\(g.members.count) client\(g.members.count == 1 ? "" : "s") · goes as separate emails", group: g.members))
        }
        if MailText.isEmail(q), !has(q), !out.contains(where: { $0.email.lowercased() == q }) {
            out.append(Suggestion(name: q, email: q, sub: "New address"))
        }
        return Array(out.prefix(8))
    }

    private func add(_ s: Suggestion) {
        d.to.append(MailRecipient(name: s.name, email: s.email, clientId: s.clientId, members: s.group))
        typed = ""
        toFocused = true
    }

    private func addTyped() {
        let t = typed.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        guard !t.isEmpty else { return }
        if MailText.isEmail(t) { d.to.append(MailRecipient(name: t, email: t)); typed = "" }
        else { error = "“\(t)” isn't an email address. Pick someone from the list, or type a full address." }
    }

    private func token(_ r: MailRecipient) -> some View {
        HStack(spacing: 6) {
            if r.isGroup {
                Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundColor(look.text)
                    .frame(width: 22, height: 22).background(Circle().fill(look.raised))
            } else {
                MailAvatar(name: r.name, clientId: r.clientId, size: 22)
            }
            Text(r.isGroup ? "\(r.name) · \(r.members.count)" : r.name).font(look.ui(13, .semibold)).foregroundColor(look.text).lineLimit(1)
            Button { d.to.removeAll { $0.id == r.id } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(look.mute).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(r.name)")
        }
        .padding(.leading, 4).padding(.trailing, 2).frame(height: 30)
        .background(Capsule().fill(look.raised))
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            MailAttachMenu(add: { data, name, type in attach(data, name, type) }, onError: { error = $0 }) {
                Image(systemName: "paperclip").font(.system(size: 15, weight: .semibold)).foregroundColor(look.text)
                    .frame(width: 40, height: 40).overlay(Circle().stroke(look.line2, lineWidth: 1))
                    .accessibilityLabel("Attach")
            }
            Menu {
                ForEach(store.savedReplies, id: \.self) { r in
                    Button(r.count > 60 ? String(r.prefix(57)) + "…" : r) {
                        let t = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        d.text = t.isEmpty ? r : t + "\n\n" + r
                    }
                }
            } label: {
                Image(systemName: "text.bubble").font(.system(size: 15, weight: .semibold)).foregroundColor(look.text)
                    .frame(width: 40, height: 40).overlay(Circle().stroke(look.line2, lineWidth: 1))
                    .accessibilityLabel("Saved replies")
            }
            if let at = d.sendAt { MailTag(text: MailText.sendsText(at), icon: "clock") }
            Spacer(minLength: 4)
            MailLaterMenu(sendAt: $d.sendAt) {
                Image(systemName: "clock").font(.system(size: 15, weight: .semibold)).foregroundColor(look.text)
                    .frame(width: 40, height: 40).overlay(Circle().stroke(look.line2, lineWidth: 1))
                    .accessibilityLabel(d.sendAt == nil ? "Send later" : "Change the time")
            }
            Button { send() } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().tint(look.onFill).controlSize(.small) }
                    Text(d.sendAt == nil ? "Send" : "Schedule")
                }
                .font(look.ui(15, .bold)).foregroundColor(look.onFill)
                .padding(.horizontal, 20).frame(minHeight: 44)
                .background(Capsule().fill(look.fill))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(look.page)
        .overlay(alignment: .top) { Rectangle().fill(look.line).frame(height: 1) }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(look.pad ? label : label.uppercased()).font(look.pad ? look.label(12.5) : BrandFont.body(11, .heavy))
                .tracking(look.pad ? 0 : 1.4).foregroundColor(look.mute)
            content()
        }
    }

    private func input(_ prompt: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(look.faint))
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
            .font(look.ui(15)).foregroundColor(look.text)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(look.field))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.line2, lineWidth: 1))
    }

    private func attach(_ data: Data, _ name: String, _ type: String) {
        let temp = MailOutFile(name: name, type: type, size: data.count, blobId: nil, uploading: true)
        d.files.append(temp)
        Task {
            do {
                let f = try await box.upload(data, name: name, type: type)
                if let i = d.files.firstIndex(where: { $0.id == temp.id }) { d.files[i] = f }
            } catch {
                d.files.removeAll { $0.id == temp.id }
                self.error = (error as? APIClient.APIError)?.message ?? "Couldn't attach \(name)."
            }
        }
    }

    private func send() {
        guard !busy else { return }
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            addTyped()
            if !typed.isEmpty { return }
        }
        error = nil
        if box.flatTo(d).isEmpty { error = "Who's it to?"; return }
        if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && d.files.isEmpty { error = "Write something first."; return }
        if d.files.contains(where: { $0.uploading }) { error = "Still uploading the attachment."; return }
        busy = true
        let at = d.sendAt
        let draft = d
        let sep = separate
        Task {
            do {
                let n = try await box.send(draft, separate: sep)
                busy = false
                let line: String = at.map { "Scheduled: " + MailText.sendsText($0).replacingOccurrences(of: "Sends ", with: "") }
                    ?? (n > 1 ? "Sent \(n) separate emails" : "Sent")
                onSent(line)
                dismiss()
            } catch {
                busy = false
                self.error = (error as? APIClient.APIError)?.message ?? "Couldn't send. Try again."
            }
        }
    }

    private func saveDraft() {
        if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && d.subject.trimmingCharacters(in: .whitespaces).isEmpty { dismiss(); return }
        let draft = d
        Task {
            do { d.draftId = try await box.saveDraft(draft); onSent("Saved in Drafts") }
            catch { onSent((error as? APIClient.APIError)?.message ?? "Couldn't save the draft.") }
            await box.refresh()
            dismiss()
        }
    }
}

/// Lays children out left to right, wrapping onto new lines (the To chips).
struct MailFlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            if x > 0 && x + sz.width > maxW { y += row + spacing; x = 0; row = 0 }
            x += sz.width + spacing
            row = max(row, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            var sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + sz.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            // The last one (the text field) takes the rest of its line.
            if i == subviews.count - 1 { sz.width = max(sz.width, bounds.maxX - x) }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sz.width, height: sz.height))
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}

// MARK: - Phone ▸ COMMUNICATIONS ▸ Inbox

enum MailRoute: Hashable {
    case thread(String)
    case chat(clientId: String, name: String, threadId: String, category: String)
}

/// A short line at the bottom of the phone's mail screens ("Archived · Undo").
@MainActor
final class MailBanner: ObservableObject {
    static let shared = MailBanner()
    @Published var text: String?
    var undo: (() -> Void)?
    private var task: Task<Void, Never>?
    func show(_ t: String, undo u: (() -> Void)?) {
        withAnimation(.easeOut(duration: 0.18)) { text = t }
        undo = u
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.text = nil }
        }
    }
    func dismiss() { task?.cancel(); withAnimation(.easeOut(duration: 0.18)) { text = nil } }
}

struct MailBannerHost: View {
    @ObservedObject private var banner = MailBanner.shared
    var body: some View {
        VStack {
            Spacer()
            if let t = banner.text {
                HStack(spacing: 14) {
                    Text(t).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.onVolt)
                    if let u = banner.undo {
                        Button("Undo") { u(); banner.dismiss() }.font(BrandFont.body(14, .heavy)).foregroundColor(Brand.onVolt).underline()
                    }
                }
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Capsule().fill(Brand.volt))
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(banner.text != nil)
    }
}

struct CoachMailView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var box = MailBox.shared
    @State private var path: [MailRoute] = []
    @State private var composing = false
    @State private var confirmDeleteId: String?

    var body: some View {
        NavigationStack(path: $path) {
            list
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: MailRoute.self) { r in
                    switch r {
                    case .thread(let id):
                        PhoneMailThreadScreen(threadId: id, folder: box.folder)
                    case .chat(let clientId, let name, let threadId, let category):
                        TrainerChatThreadScreen(clientId: clientId, clientName: name, threadId: threadId, categoryLabel: category)
                    }
                }
        }
        .overlay { MailBannerHost() }
        .environment(\.mailLook, .phone)
        .environment(\.mailActions, actions)
        .sheet(isPresented: $composing) {
            MailComposeSheet { line in MailBanner.shared.show(line, undo: nil) }
                .environmentObject(store)
                .environment(\.mailLook, .phone)
        }
        .task { await box.show() }
        .confirmationDialog("Delete it forever?", isPresented: Binding(get: { confirmDeleteId != nil }, set: { if !$0 { confirmDeleteId = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteId { run({ try await box.deleteForever(id) }, ok: "Deleted") }
            }
        } message: { Text("It can't be brought back.") }
    }

    private var actions: MailActions {
        MailActions(
            openClient: { id in if let r = store.roster.first(where: { $0.id == id }) { store.selectedClient = r } },
            answerInMessages: { id in openChat(id) },
            openWorkouts: nil,
            toast: { t, u in MailBanner.shared.show(t, undo: u) },
            closed: { id in if case .thread(let open)? = path.last, open == id { path.removeLast() } }
        )
    }

    private func openChat(_ clientId: String) {
        guard let r = store.roster.first(where: { $0.id == clientId }) else { return }
        Task {
            await CoachData.shared.loadThreads(clientId, force: true)
            if let t = (CoachData.shared.threads[clientId] ?? []).max(by: { $0.lastActivity < $1.lastActivity }) {
                path.append(.chat(clientId: clientId, name: r.name, threadId: t.id, category: t.category))
            } else {
                store.selectedClient = r
            }
        }
    }

    @ViewBuilder private var list: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DSScreenHeader(eyebrow: "Communications", title: "Inbox", subtitle: subtitle)
                    if !box.checked {
                        ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 30)
                    } else if !box.live {
                        notLive
                    } else {
                        DSCarousel(options: folderOptions,
                                   selection: Binding(get: { box.folder }, set: { box.setFolder($0) }),
                                   itemWidth: 104, accessibilityName: "Folder")
                        CoachSearchField(prompt: "Search mail", text: Binding(get: { box.query }, set: { box.query = $0; box.searchChanged() }))
                        if box.folder == "inbox" { filterSeg }
                        rows
                    }
                }
                .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 110)
            }
            .refreshable { await box.refresh() }
            if box.live {
                Button { composing = true } label: {
                    Label("New email", systemImage: "square.and.pencil")
                        .font(BrandFont.body(15, .heavy)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 20).frame(minHeight: 52)
                        .background(Capsule().fill(Brand.volt))
                        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
                }
                .buttonStyle(PressableStyle())
                .padding(.trailing, 20).padding(.bottom, 28)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
    }

    private var folderOptions: [DSCarousel<String>.Option] {
        MailText.folders.map { f -> DSCarousel<String>.Option in
            let n: Int = box.status?.count(f.id) ?? 0
            return DSCarousel<String>.Option(id: f.id, label: n > 0 ? "\(f.name) \(n)" : f.name)
        }
    }

    private var subtitle: String {
        guard box.live, let s = box.status else { return "coach@bigscherlytraining.com" }
        var parts = ["coach@ · \(s.unread ?? 0) unread"]
        if let o = s.oldestWaiting {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: o.since), to: Calendar.current.startOfDay(for: Date())).day ?? 0
            parts.append("\((o.name ?? "Someone").firstName) waiting \(days <= 0 ? "today" : "\(days) day\(days == 1 ? "" : "s")")")
        }
        if let n = s.newPeople, n > 0 { parts.append("\(n) new \(n == 1 ? "person" : "people")") }
        return parts.joined(separator: " · ")
    }

    private var filterSeg: some View {
        HStack(spacing: 2) {
            ForEach(["all", "clients", "others"], id: \.self) { f in
                Button { withAnimation(.easeOut(duration: 0.15)) { box.filter = f } } label: {
                    Text(f.capitalized).font(BrandFont.body(13, .bold))
                        .foregroundColor(box.filter == f ? Brand.text : Brand.mute)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(box.filter == f ? Brand.text.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(box.filter == f ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.black))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
    }

    @ViewBuilder private var rows: some View {
        if box.items == nil {
            ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 20)
        } else if box.shown.isEmpty {
            VStack(spacing: 4) {
                Text(MailText.emptyLine(box.folder, searching: !box.query.isEmpty)).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                if !box.listError.isEmpty { Text(box.listError).font(BrandFont.body(12)).foregroundColor(Brand.mute) }
            }
            .frame(maxWidth: .infinity).padding(.top, 30)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(box.shown) { i in
                    Button {
                        if box.folder == "drafts" { composingDraft(i) } else { path.append(.thread(i.threadId)) }
                    } label: { MailRow(item: i, folder: box.folder) }
                        .buttonStyle(.plain)
                        .contextMenu { rowMenu(i) }
                }
            }
        }
    }

    /// Drafts open as their thread too (a reply draft shows under its emails; a new one shows alone).
    private func composingDraft(_ i: MailItem) { path.append(.thread(i.threadId)) }

    @ViewBuilder private func rowMenu(_ i: MailItem) -> some View {
        if box.folder == "drafts" {
            Button(role: .destructive) { run({ try await box.deleteDraft(i.emailId) }, ok: "Draft deleted") } label: { Label("Delete draft", systemImage: "trash") }
        } else {
            ForEach(MailThreadActions.list(threadId: i.threadId, folder: box.folder, look: .phone, actions: actions,
                                           confirmDelete: { confirmDeleteId = i.threadId })) { a in
                if a.destructive {
                    Button(role: .destructive) { a.run() } label: { Label(a.label, systemImage: a.icon) }
                } else if a.id == "unread" {
                    Button { run({ try await box.markRead(i.threadId, i.unread) }, ok: nil) } label: {
                        Label(i.unread ? "Mark as read" : "Mark as unread", systemImage: i.unread ? "envelope.open" : "envelope.badge")
                    }
                } else {
                    Button { a.run() } label: { Label(a.label, systemImage: a.icon) }
                }
            }
            if let s = i.scheduledAt, s > Date() {
                Button { run({ try await box.cancelScheduled(i.emailId) }, ok: "Stopped. It's back in Drafts.") } label: { Label("Don't send", systemImage: "xmark.circle") }
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void, ok: String?) {
        Task {
            do { try await work(); if let ok { MailBanner.shared.show(ok, undo: nil) } }
            catch { MailBanner.shared.show((error as? APIClient.APIError)?.message ?? "Couldn't do that.", undo: nil) }
        }
    }

    private var notLive: some View {
        let title: String
        let msg: String
        switch box.reason {
        case "demo":
            title = "Not in Demo Mode"
            msg = "Email to coach@ shows here when you're signed in to your coach account."
        case "notOwner":
            title = "Email lands here soon"
            msg = "The coach@ inbox belongs to another Coach HQ login, so it isn't shown here."
        case "unreachable":
            title = "Can't reach the mail server"
            msg = "The app can't reach the mail server right now" + (box.detail.isEmpty ? "." : ": \(box.detail)")
        default:
            title = "Email lands here soon"
            msg = "Email to coach@bigscherlytraining.com shows up here once the mail server is switched on" + (box.detail.isEmpty ? "." : " (\(box.detail))")
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
            Text(msg).font(BrandFont.body(13)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { store.select(.coachChat) } label: {
                    Label("Open Messages", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(BrandFont.body(14, .heavy)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .background(Capsule().fill(Brand.volt))
                }
                .buttonStyle(PressableStyle())
                if box.reason == "unreachable" {
                    Button("Try again") { Task { await box.show() } }
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.voltText)
                        .padding(.horizontal, 14).frame(minHeight: 40)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

// MARK: Phone ▸ one thread

struct PhoneMailThreadScreen: View {
    let threadId: String
    let folder: String
    @EnvironmentObject var store: AppStore
    @StateObject private var model = MailThreadModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mailActions) private var actions
    @State private var confirmDelete = false
    @State private var preview: URL?
    @State private var downloading = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.loading && model.thread == nil {
                            ProgressView().tint(Brand.volt).frame(maxWidth: .infinity).padding(.top, 40)
                        } else if !model.error.isEmpty {
                            VStack(spacing: 8) {
                                Text("Couldn't open it.").font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                                Text(model.error).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                                Button("Try again") { Task { await model.open(threadId) } }.foregroundColor(Brand.voltText)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        } else if model.thread != nil {
                            if folder != "sent" && folder != "drafts" { MailContactPanel(model: model, compact: true) }
                            MailThreadEmails(model: model) { a in open(a) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.thread?.emails.last?.id) { _, id in
                    if let id { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
                }
            }
            if model.thread != nil && folder != "junk" && folder != "trash" {
                MailReplyBar(model: model)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { if model.threadId != threadId { await model.open(threadId) } }
        .onDisappear { Task { await model.saveNow() } }
        .quickLookPreview($preview)
        .confirmationDialog("Delete it forever?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await MailBox.shared.deleteForever(threadId); actions.toast("Deleted", nil); dismiss() }
                    catch { actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't delete it.", nil) }
                }
            }
        } message: { Text("It can't be brought back.") }
    }

    private var topBar: some View {
        let t = model.thread
        let people: String = {
            guard let t else { return "" }
            var seen: [String] = []
            for e in t.emails {
                let n = e.fromMe ? "you" : (e.from?.shown ?? "").firstName
                if !seen.contains(n) { seen.append(n) }
            }
            return "\(t.emails.count) email\(t.emails.count == 1 ? "" : "s") · " + seen.joined(separator: " and ")
        }()
        let list = MailThreadActions.list(threadId: threadId, folder: folder, look: .phone, actions: actions, confirmDelete: { confirmDelete = true })
        return HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundColor(Brand.voltText).frame(width: 40, height: 44)
            }
            .accessibilityLabel("Back to Inbox")
            VStack(alignment: .leading, spacing: 1) {
                Text(t?.subject.isEmpty == false ? (t?.subject ?? "") : "(no subject)").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text).lineLimit(1)
                Text(people).font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let first = list.first, first.id == "archive" {
                Button { first.run() } label: {
                    Image(systemName: "archivebox").font(.system(size: 16, weight: .semibold)).foregroundColor(Brand.text).frame(width: 40, height: 44)
                }
                .accessibilityLabel("Archive")
            }
            Menu {
                ForEach(list) { a in
                    if a.destructive { Button(role: .destructive) { a.run() } label: { Label(a.label, systemImage: a.icon) } }
                    else { Button { a.run() } label: { Label(a.label, systemImage: a.icon) } }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .semibold)).foregroundColor(Brand.text).frame(width: 40, height: 44)
            }
            .accessibilityLabel("More")
            // Room for the floating menu button.
            Color.clear.frame(width: 48, height: 1)
        }
        .padding(.leading, 6).padding(.top, 8).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }

    private func open(_ a: MailAttachment) {
        guard !downloading else { return }
        downloading = true
        Task {
            do { preview = try await APIClient.shared.mailDownload(a) }
            catch { actions.toast((error as? APIClient.APIError)?.message ?? "Couldn't download it.", nil) }
            downloading = false
        }
    }
}
