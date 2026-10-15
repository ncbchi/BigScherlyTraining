import SwiftUI
import Combine

// MARK: - Emailed 6-digit codes (Oct 10, 2026)
// One sheet for both "Forgot password?" and "Email me a code" on the login screen.
// Step 1 asks for the email and sends a code. Step 2 takes the code (iOS offers it from
// Mail above the keyboard) and, for a reset, the new password. On success the server
// answers like /auth/login, and LoginView finishes the sign-in exactly as a password login.
struct EmailCodeSheet: View {
    enum Mode: String, Identifiable {
        case reset, signIn
        var id: String { rawValue }
    }

    let mode: Mode
    let startEmail: String
    /// Called on the main actor after the sheet closes, with the server's login answer.
    let onSignedIn: @MainActor (LoginResponse, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var newPass = ""
    @State private var confirm = ""
    @State private var step = 1
    @State private var working = false
    @State private var error: String?
    @State private var note: String?
    @State private var wait = 0
    @FocusState private var focus: Field?
    private enum Field { case email, code, pass }
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

                    Text(mode == .reset ? "Reset\nYour Password" : "Sign In\nWith a Code")
                        .font(BrandFont.display(40)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(BrandFont.body(14)).foregroundColor(BrandDark.mute)
                        .fixedSize(horizontal: false, vertical: true)

                    field("Email", text: $email, kind: .email)
                        .disabled(step == 2)
                        .opacity(step == 2 ? 0.6 : 1)

                    if step == 2 {
                        field("6-digit code", text: $code, kind: .code)
                        if mode == .reset {
                            field("New password (min 8 characters)", text: $newPass, kind: .pass)
                            field("Confirm new password", text: $confirm, kind: .pass)
                        }
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13, .semibold)).foregroundColor(BrandDark.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let note {
                        Text(note).font(BrandFont.body(13, .semibold)).foregroundColor(LoginLook.palette().accentText)
                    }

                    VoltButton(title: buttonTitle) { submit() }
                        .disabled(working)
                        .opacity(working ? 0.6 : 1)

                    if step == 2 {
                        HStack {
                            Button(wait > 0 ? "Send a new code in \(wait)s" : "Send a new code") { resend() }
                                .disabled(wait > 0 || working)
                            Spacer()
                            Button("Use a different email") {
                                step = 1; code = ""; error = nil; note = nil; focus = .email
                            }
                        }
                        .font(BrandFont.body(13, .semibold))
                        .foregroundColor(BrandDark.mute)
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
            email = startEmail.trimmingCharacters(in: .whitespaces)
            focus = email.isEmpty ? .email : nil
        }
        .onReceive(ticker) { _ in if wait > 0 { wait -= 1 } }
        .onChange(of: code) { _, v in
            let digits = String(v.filter(\.isNumber).prefix(6))
            if digits != v { code = digits }
            // A full code typed (or filled from Mail) signs straight in; a reset still needs the password.
            if digits.count == 6, mode == .signIn, step == 2, !working { submit() }
        }
    }

    private var subtitle: String {
        if step == 1 {
            return mode == .reset
                ? "Enter the email you sign in with. We'll send you a 6-digit code to set a new password."
                : "Enter the email you sign in with. We'll send you a 6-digit code instead of using your password."
        }
        return "If \(email.trimmingCharacters(in: .whitespaces)) has an account, a code is on its way. It works for 10 minutes. Check your junk folder if it doesn't show up."
    }

    private var buttonTitle: String {
        if working { return step == 1 ? "Sending…" : "Checking…" }
        if step == 1 { return "Send Code" }
        return mode == .reset ? "Reset & Sign In" : "Sign In"
    }

    private enum Kind { case email, code, pass }

    private func field(_ label: String, text: Binding<String>, kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(BrandDark.mute)
            Group {
                switch kind {
                case .pass:
                    SecureField("", text: text)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .pass)
                case .code:
                    TextField("", text: text)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .focused($focus, equals: .code)
                case .email:
                    TextField("", text: text)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .focused($focus, equals: .email)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundColor(.white).padding(14)
            .background(BrandDark.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrandDark.line, lineWidth: 1))
        }
    }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        error = nil; note = nil
        if step == 1 {
            guard cleanEmail.contains("@"), cleanEmail.contains(".") else {
                error = "Enter the email you sign in with."; return
            }
            send(thenStep2: true)
            return
        }
        guard code.count == 6 else { error = "Enter the 6-digit code from the email."; return }
        if mode == .reset {
            guard newPass.count >= 8 else { error = "Your new password needs at least 8 characters."; return }
            guard newPass == confirm else { error = "The new passwords don't match."; return }
        }
        working = true
        let em = cleanEmail, c = code, p = newPass, m = mode
        Task {
            do {
                let resp = m == .reset
                    ? try await APIClient.shared.resetPassword(email: em, code: c, newPassword: p)
                    : try await APIClient.shared.signInWithCode(email: em, code: c)
                await MainActor.run {
                    working = false
                    dismiss()
                    onSignedIn(resp, em)
                }
            } catch {
                await MainActor.run {
                    working = false
                    self.error = (error as? APIClient.APIError)?.message ?? "That didn't work. Check your connection and try again."
                    if m == .signIn { code = "" }
                }
            }
        }
    }

    private func resend() {
        error = nil; note = nil
        send(thenStep2: false)
    }

    private func send(thenStep2: Bool) {
        working = true
        let em = cleanEmail, m = mode
        Task {
            do {
                let retry = m == .reset
                    ? try await APIClient.shared.sendResetCode(email: em)
                    : try await APIClient.shared.sendSignInCode(email: em)
                await MainActor.run {
                    working = false
                    wait = retry
                    if thenStep2 { step = 2; code = ""; focus = .code } else { note = "New code sent. Use the newest one." }
                }
            } catch {
                await MainActor.run {
                    working = false
                    self.error = (error as? APIClient.APIError)?.message ?? "Couldn't send the code. Check your connection and try again."
                }
            }
        }
    }
}
