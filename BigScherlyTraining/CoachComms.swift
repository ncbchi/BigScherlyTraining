import SwiftUI
import Combine

// MARK: - Communications (Oct 11, 2026)
// The coach menus (phone COMMUNICATIONS group, iPad sidebar, Coach HQ on the web) gather
//   Inbox          email to coach@ and support@ (help@ too). A placeholder until the mail server is live.
//   Messages       the app's chat with clients (was Inbox on iPad and the web, Chat on the phone)
//   Check-ins
//   Announcements
// each with its own badge. Synchronized folder: no target step needed.

/// Badge counts that don't come with the roster.
@MainActor
final class CommsBadges: ObservableObject {
    static let shared = CommsBadges()
    /// Announcements scheduled to go out later.
    @Published var scheduledAnnouncements = 0
    /// Unread email, once the mail server is live.
    @Published var unreadMail = 0
    private var last = Date.distantPast

    /// Cheap to call often: it asks the server at most once a minute unless forced.
    func refresh(force: Bool = false) {
        let store = AppStore.shared
        guard store.isTrainer, !store.isDemoMode else { return }
        guard force || Date().timeIntervalSince(last) > 60 else { return }
        last = Date()
        Task {
            if let a = try? await APIClient.shared.adminAnnouncementsWithReads() {
                let now = Date()
                scheduledAnnouncements = a.filter { ($0.publishAt ?? .distantPast) > now }.count
            }
        }
    }
}

/// What the email Inbox says until the mail server is live (same words as Coach HQ on the web).
struct MailSetupStep: Identifiable {
    let id: Int
    let done: Bool
    let title: String
    let detail: String

    static let intro = "Mail sent to coach@bigscherlytraining.com and support@ (help@ too) will show up here: read, reply, write new emails, attachments, search, archive and spam. When a client emails you, their card shows beside the message."
    static let all: [MailSetupStep] = [
        MailSetupStep(id: 0, done: true, title: "Messages moved", detail: "The app's chat with clients is now Messages, right under Inbox."),
        MailSetupStep(id: 1, done: false, title: "Mail server", detail: "Our own server on Cloudzy, with mailboxes for coach@ and support@."),
        MailSetupStep(id: 2, done: false, title: "Domain records", detail: "MX, SPF and DMARC at GoDaddy so mail reaches it."),
        MailSetupStep(id: 3, done: false, title: "This inbox", detail: "Turns on by itself once the server answers. Apple Mail and Outlook work too (IMAP).")
    ]
}

// MARK: Phone ▸ COMMUNICATIONS ▸ Inbox

struct CoachMailView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DSScreenHeader(eyebrow: "Communications", title: "Inbox", subtitle: "coach@ and support@")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Email lands here soon").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                    Text(MailSetupStep.intro).font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(MailSetupStep.all) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(s.done ? Brand.voltText : Brand.mute)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                                Text(s.detail).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))

                Button { store.select(.coachChat) } label: {
                    Label("Open Messages", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(BrandFont.body(14, .heavy)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .background(Capsule().fill(Brand.volt))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
    }
}

// MARK: iPad ▸ Communications ▸ Inbox

struct PadMailView: View {
    @Environment(\.padGo) private var go

    var body: some View {
        VStack(spacing: 0) {
            PadPageTop(title: "Inbox", facts: [PadFact(bold: "coach@"), PadFact(lead: "and ", bold: "support@")]) {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PadPane(title: "Email lands here soon") {
                        Text(MailSetupStep.intro).font(PadFont.ui(15)).foregroundColor(Pad.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(MailSetupStep.all) { s in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: s.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(s.done ? Pad.volt : Pad.faint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                    Text(s.detail).font(PadFont.ui(13)).foregroundColor(Pad.mute)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Button { go(.inbox) } label: { Label("Open Messages", systemImage: "bubble.left") }
                        .buttonStyle(PadButtonStyle(kind: .outline, small: true))
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Pad.page.ignoresSafeArea())
    }
}
