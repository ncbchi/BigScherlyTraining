import SwiftUI
import Combine

// MARK: - 2-step sign-in: the code step (server 2.4.0, Oct 11, 2026)
// Shown after a correct password on a phone or iPad this account hasn't used before.
// The code is in the user's email; iOS offers it above the keyboard (.oneTimeCode),
// and a full code signs straight in. Once it works, this device is never asked again
// (until a password reset).
struct MfaCodeSheet: View {
    let challenge: MfaChallenge
    /// Called on the main actor after the sheet closes, with the server's login answer.
    let onSignedIn: @MainActor (LoginResponse) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var note: String?
    @State private var wait = 60
    /// The server ended this sign-in (expired / too many tries): only "Back" makes sense.
    @State private var dead = false
    @FocusState private var focused: Bool
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            BrandDark.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .font(BrandFont.body(15, .semibold))
                            .foregroundColor(BrandDark.mute)
                    }
                    .padding(.top, 6)

                    Text("Check Your\nEmail")
                        .font(BrandFont.display(40)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This is a new \(DeviceIdentity.name) for your account, so we sent a 6-digit code to \(challenge.sentTo). You'll only need to do this once on this device.")
                        .font(BrandFont.body(14)).foregroundColor(BrandDark.mute)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("6-DIGIT CODE").font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(BrandDark.mute)
                        TextField("", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .focused($focused)
                            .foregroundColor(.white).padding(14)
                            .background(BrandDark.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrandDark.line, lineWidth: 1))
                            .disabled(dead)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13, .semibold)).foregroundColor(BrandDark.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let note {
                        Text(note).font(BrandFont.body(13, .semibold)).foregroundColor(LoginLook.palette().accentText)
                    }

                    VoltButton(title: dead ? "Back to Sign In" : (working ? "Checking…" : "Sign In")) {
                        if dead { dismiss() } else { submit() }
                    }
                    .disabled(working)
                    .opacity(working ? 0.6 : 1)

                    if !dead {
                        Button(wait > 0 ? "Send a new code in \(wait)s" : "Send a new code") { resend() }
                            .disabled(wait > 0 || working)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundColor(BrandDark.mute)
                        Text("Not in your inbox? Check junk. The code works for 10 minutes.")
                            .font(BrandFont.body(12)).foregroundColor(BrandDark.mute)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .tapToDismissKeyboard()
        .onAppear {
            wait = challenge.retryAfter ?? 60
            focused = true
        }
        .onReceive(ticker) { _ in if wait > 0 { wait -= 1 } }
        .onChange(of: code) { _, v in
            let digits = String(v.filter(\.isNumber).prefix(6))
            if digits != v { code = digits }
            if digits.count == 6, !working, !dead { submit() }
        }
    }

    private func submit() {
        error = nil; note = nil
        guard code.count == 6 else { error = "Enter the 6-digit code from the email."; return }
        working = true
        let c = code, token = challenge.mfaToken
        Task {
            do {
                let resp = try await APIClient.shared.verifyLoginCode(mfaToken: token, code: c)
                await MainActor.run {
                    working = false
                    dismiss()
                    onSignedIn(resp)
                }
            } catch {
                await MainActor.run {
                    working = false
                    let msg = (error as? APIClient.APIError)?.message ?? "That didn't work. Check your connection and try again."
                    self.error = msg
                    // The server says when this sign-in is over; its sentences end with "sign in again."
                    if msg.contains("sign in again") { dead = true }
                    code = ""
                }
            }
        }
    }

    private func resend() {
        error = nil; note = nil
        working = true
        let token = challenge.mfaToken
        Task {
            do {
                let retry = try await APIClient.shared.resendLoginCode(mfaToken: token)
                await MainActor.run { working = false; wait = retry; note = "New code sent. Use the newest one." }
            } catch {
                await MainActor.run {
                    working = false
                    let msg = (error as? APIClient.APIError)?.message ?? "Couldn't send the code. Check your connection and try again."
                    self.error = msg
                    if msg.contains("sign in again") { dead = true }
                }
            }
        }
    }
}
