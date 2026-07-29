import SwiftUI

// MARK: - Set New Password (first-login forced change)
// Shown when the client logs in with a coach-issued temporary password.
// They must set their own password before reaching the app.
struct SetPasswordView: View {
    @EnvironmentObject var store: AppStore
    @State private var current = ""
    @State private var newPass = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Eyebrow(text: "One Quick Step")
                Text("Set Your\nPassword")
                    .font(BrandFont.display(44)).foregroundColor(.white)
                Text("You're logged in with a temporary password from your coach. Choose your own to continue.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                field("Temporary password", text: $current, secure: true)
                field("New password (min 8 characters)", text: $newPass, secure: true)
                field("Confirm new password", text: $confirm, secure: true)

                if let error {
                    Text(error).font(BrandFont.body(13, .semibold)).foregroundColor(Color(hex: 0xFF5A5A))
                }

                VoltButton(title: working ? "Saving…" : "Set Password") { submit() }
                    .disabled(working)
                Spacer()
            }
            .padding(24)
        }
        .tapToDismissKeyboard()
    }

    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BrandFont.body(10, .bold)).tracking(1).foregroundColor(Brand.mute)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textInputAutocapitalization(.never)
            .foregroundColor(.white).padding(12)
            .background(Brand.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        }
    }

    private func submit() {
        error = nil
        guard newPass.count >= 8 else { error = "New password must be at least 8 characters."; return }
        guard newPass == confirm else { error = "New passwords don't match."; return }

        if APIConfig.useMock {
            // Prototype: accept and proceed
            store.mustChangePassword = false
            return
        }
        working = true
        Task {
            do {
                try await APIClient.shared.changePassword(current: current, new: newPass)
                await MainActor.run { store.mustChangePassword = false; store.loadAllFromAPI(); working = false }
            } catch {
                await MainActor.run { self.error = "Couldn't set password. Check your temporary password."; working = false }
            }
        }
    }
}
