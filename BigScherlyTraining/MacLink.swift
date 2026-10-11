import Foundation
import Network
import Combine

// MARK: - Mac link (DEVELOPER TOOL — removed before release)
// The live session's file, straight to a small listener on the Mac over Wi-Fi: about a second,
// instead of iCloud's minutes. The Mac runs bst-live/listen.py (in the project folder), which
// announces itself on the network as "_bstlive._tcp"; the phone finds it by itself (Bonjour).
// Each send is the whole file, so a missed one is simply replaced by the next (15 s later).
// iCloud Auto-save carries on alongside as the backup.
//
// Lives in the phone app folder (added automatically).

@MainActor
final class MacLink: ObservableObject {
    static let shared = MacLink()

    @Published private(set) var state = "Not started"
    @Published private(set) var lastSent: Date?

    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var pending: (name: String, body: Data)?
    private var attempt = 0
    private var busy = false

    private init() {}

    /// Look for the Mac. (The first time, iOS asks to allow Local Network access.)
    func start() {
        guard browser == nil else { return }
        state = "Looking for the Mac…"
        let b = NWBrowser(for: .bonjour(type: "_bstlive._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let found = results.first?.endpoint
            Task { @MainActor in MacLink.shared.found(found) }
        }
        b.stateUpdateHandler = { st in
            let text: String?
            switch st {
            case .failed(let e): text = "Can't search the network (\(e))"
            case .waiting(let e): text = "Waiting for Local Network access (\(e))"
            default: text = nil
            }
            guard let text else { return }
            Task { @MainActor in MacLink.shared.browserTrouble(text) }
        }
        browser = b
        b.start(queue: .main)
    }

    /// Send the newest version of a file (an older one still waiting is dropped).
    func send(name: String, text: String) {
        start()
        pending = (name, Data(text.utf8))
        flush()
    }

    private func found(_ ep: NWEndpoint?) {
        endpoint = ep
        if ep == nil {
            state = "Looking for the Mac… (is listen.py running?)"
        } else if lastSent == nil {
            state = "Mac found"
        }
        flush()
    }

    private func browserTrouble(_ text: String) {
        state = text
        browser?.cancel()
        browser = nil                                     // the next send searches again
    }

    private func flush() {
        guard !busy, let ep = endpoint, let job = pending else { return }
        pending = nil
        busy = true
        attempt += 1
        let mine = attempt
        var payload = Data("BST1 \(job.name)\n".utf8)
        payload.append(job.body)
        let message = payload
        let c = NWConnection(to: ep, using: .tcp)
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                c.send(content: message, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { err in
                    if let err {
                        c.cancel()
                        Task { @MainActor in MacLink.shared.finished(mine, ok: false, note: "\(err)") }
                        return
                    }
                    c.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                        let ok = String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("OK")
                        c.cancel()
                        Task { @MainActor in MacLink.shared.finished(mine, ok: ok, note: ok ? nil : "no reply") }
                    }
                })
            case .failed(let e), .waiting(let e):
                c.cancel()
                Task { @MainActor in MacLink.shared.finished(mine, ok: false, note: "\(e)") }
            default:
                break
            }
        }
        c.start(queue: .global(qos: .utility))
        // Never stuck: give up on this one after 10 s (the next update comes anyway).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if MacLink.shared.busy, MacLink.shared.attempt == mine {
                c.cancel()
                MacLink.shared.finished(mine, ok: false, note: "timed out")
            }
        }
    }

    private func finished(_ which: Int, ok: Bool, note: String?) {
        guard which == attempt, busy else { return }     // already settled (e.g. timed out)
        busy = false
        if ok {
            lastSent = Date()
            state = "Sending to the Mac"
            flush()                                       // a newer version may be waiting
        } else {
            endpoint = nil                                // look again; the next update retries
            browser?.cancel(); browser = nil
            start()
            state = "Mac not reached" + (note.map { " — \($0)" } ?? "")
        }
    }
}
