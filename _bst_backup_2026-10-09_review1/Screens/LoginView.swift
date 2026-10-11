import SwiftUI
import UIKit
import Combine

// MARK: - Login Screen
struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            BrandDark.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // The volt logo from the asset catalog (the login page always stays dark).
                Image("logoVolt").renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundColor(BrandDark.volt)
                    .frame(height: 120)
                    .padding(.bottom, 8)

                Text("Big Scherly Training")
                    .font(BrandFont.display(30))
                    .foregroundColor(BrandDark.white)
                Text("Lets Get Big Together Queens")
                    .font(BrandFont.body(11, .bold))
                    .tracking(3).foregroundColor(BrandDark.volt)
                    .padding(.bottom, 40)

                VStack(spacing: 14) {
                    styledField("Email", text: $email, secure: false)
                    styledField("Password", text: $password, secure: true)
                    if showError {
                        Text("Check your email and password.")
                            .font(BrandFont.body(13)).foregroundColor(BrandDark.danger)
                    }
                    VoltButton(title: "Log In") {
                        // Both fields empty → offline demo account (App Store review). No network call.
                        if email.trimmingCharacters(in: .whitespaces).isEmpty && password.isEmpty {
                            store.enterDemo()
                            return
                        }
                        if APIConfig.useMock {
                            store.login()          // prototype: any input logs in
                        } else {
                            Task {
                                do {
                                    let resp = try await APIClient.shared.login(email: email, password: password)
                                    APIClient.shared.setToken(resp.token)
                                    await MainActor.run {
                                        // The same login screen serves both roles — the
                                        // server tells us which shell to show.
                                        store.isTrainer = (resp.role == "trainer")
                                        store.trainerName = resp.name
                                        store.isDemoMode = false   // isLive computes from this
                                        // Set identity immediately from the login response
                                        // so the greeting is correct even before /me loads.
                                        if resp.role != "trainer" {
                                            store.client = Client(id: resp.id, name: resp.name,
                                                                  email: email, startDate: store.client.startDate,
                                                                  goal: store.client.goal)
                                        }
                                        // Persist role + name so relaunch restores the
                                        // correct shell and identity, not a default.
                                        UserDefaults.standard.set(resp.role == "trainer", forKey: "bst_isTrainer")
                                        UserDefaults.standard.set(resp.name, forKey: "bst_userName")

                                        if store.isTrainer {
                                            // His own training runs on a hidden profile; keep his login
                                            // name and email on screen.
                                            store.client = Client(id: resp.id, name: resp.name, email: email,
                                                                  startDate: store.client.startDate, goal: store.client.goal)
                                            UserDefaults.standard.set(email, forKey: "bst_userEmail")
                                            store.login()
                                            store.startCoachSession()
                                        } else {
                                            store.mustChangePassword = resp.mustChangePassword
                                            store.login()
                                            if !resp.mustChangePassword { store.loadAllFromAPI() }
                                        }
                                    }
                                } catch {
                                    await MainActor.run { showError = true }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)

                Spacer()

                // Small, unobtrusive demo entry pinned at the bottom. App Review
                // needs a credential-free way into a login-gated app (Guideline 2.1);
                // this keeps it discoverable without competing with the real login.
                // The leave-both-fields-empty path still works as a fallback.
                Button {
                    store.enterDemo()
                } label: {
                    Text("Demo Mode")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundColor(BrandDark.volt)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .overlay(Capsule().stroke(BrandDark.volt.opacity(0.35), lineWidth: 1))
                }
                .padding(.bottom, 14)

                Text("LGBTQ+ owned · Since 2024")
                    .font(BrandFont.body(11, .semibold))
                    .tracking(2).foregroundColor(BrandDark.mute)
                    .padding(.bottom, 20)
            }
        }
        .tapToDismissKeyboard()
    }

    @ViewBuilder
    func styledField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField("", text: text) } else { TextField("", text: text) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundColor(.white)
        .padding(15)
        .background(BrandDark.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).stroke(BrandDark.line, lineWidth: 1)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).foregroundColor(BrandDark.mute)
                        .padding(.leading, 16).allowsHitTesting(false)
                }
            }
        )
    }
}

// MARK: - Post-login welcome board
// Revolving grid of #bigscherlytraining photos with the big overlay headline.
struct WelcomeBoardView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var motion = MotionManager()     // the QUEENS sheen follows the phone's tilt
    @Binding var showBoard: Bool

    var body: some View {
        ZStack {
            BrandDark.black.ignoresSafeArea()

            // Flat grid of tiles that flip to the next photo
            FlippingTileGrid(photos: store.boardPhotos)
                .opacity(0.55)
                .allowsHitTesting(false)

            // Dark scrim for text legibility
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.4), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // Overlay headline — left aligned, fills the width, alternating
            // filled / outlined like the website. Each word auto-shrinks to fit one line.
            VStack(alignment: .leading, spacing: -4) {
                Spacer()
                filledWord("LET'S")
                outlinedWord("GET")
                filledWord("BIG")
                outlinedWord("TOGETHER")
                MetallicRainbowText(text: "QUEENS", size: 140, fillWidth: true, motion: motion)
                Spacer()
                enterButton
                    .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    // Big, heavy, one line each — shrinks to fit width so TOGETHER never wraps.
    private let headlineSize: CGFloat = 96

    // The original Enter: a Volt capsule with black type, whatever accent is chosen.
    private var enterButton: some View {
        Button { withAnimation { showBoard = false } } label: {
            Text("ENTER")
                .font(BrandFont.body(14, .bold))
                .tracking(1.5)
                .foregroundColor(BrandDark.onVolt)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BrandDark.volt)
                .clipShape(Capsule())
        }
    }

    func filledWord(_ w: String) -> some View {
        Text(w)
            .font(BrandFont.welcome(headlineSize))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    func outlinedWord(_ w: String) -> some View {
        StrokeText(text: w, size: headlineSize)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Flipping tile grid
// A flat grid of photo tiles. Each tile periodically flips (3D rotation) to the
// next photo in the set, on a staggered timer so the board feels alive but calm.
// MARK: - Enter (a standard bar in your theme colour: — ENTER —)

struct EnterCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                line
                Text("ENTER")
                    .font(BrandFont.display(24)).tracking(5)
                    .lineLimit(1).fixedSize()
                    .offset(x: 2.5)                     // tracking adds space after the last letter
                line
            }
            .foregroundColor(Brand.onVolt)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.volt))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(EnterPress())
        .accessibilityLabel("Enter")
    }

    /// A thin line either side of the word.
    private var line: some View {
        Rectangle().fill(Brand.onVolt).frame(width: 36, height: 1.5)
    }
}

private struct EnterPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct FlippingTileGrid: View {
    let photos: [String]
    private let cols = 3
    private let rows = 5

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let tileW = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let tileH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { c in
                            let index = r * cols + c
                            FlipTile(photos: photos,
                                     startOffset: index,
                                     delay: Double((index * 13) % 17) * 1.1 + 2.0)
                                .frame(width: tileW, height: tileH)
                        }
                    }
                }
            }
        }
    }
}

// A single tile that flips to reveal the next photo on a repeating timer.
struct FlipTile: View {
    let photos: [String]
    let startOffset: Int
    let delay: Double

    @State private var current: Int
    @State private var angle: Double = 0
    @State private var showingFront = true

    init(photos: [String], startOffset: Int, delay: Double) {
        self.photos = photos
        self.startOffset = startOffset
        self.delay = delay
        _current = State(initialValue: startOffset)
    }

    var body: some View {
        tileFace(current)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .onAppear { scheduleFlip() }
    }

    private func tileFace(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(BrandDark.bg)
            .overlay(
                Group {
                    if !photos.isEmpty, UIImage(named: photos[i % photos.count]) != nil {
                        Image(photos[i % photos.count]).resizable().scaledToFill()
                    } else {
                        // fallback tile
                        ZStack {
                            BrandDark.bg
                            Text("#bigscherlytraining")
                                .font(BrandFont.body(8, .bold)).foregroundColor(BrandDark.mute)
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func scheduleFlip() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            flip()
        }
    }

    private func flip() {
        // Rotate 90° (edge-on), swap photo at the midpoint, finish to 0. Gentle/slow.
        withAnimation(.easeIn(duration: 0.5)) { angle = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            current = (current + 1) % max(1, photos.count)
            angle = -90
            withAnimation(.easeOut(duration: 0.5)) { angle = 0 }
            // schedule the next flip after a longer, calmer rest
            let next = Double.random(in: 9.0...16.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + next) { flip() }
        }
    }
}

// MARK: - Stroke (outlined) text helper for GET / TOGETHER
// Hollow white outline: white ring of offset copies with the letter center
// knocked out so the photo board shows through, matching the website's outlined words.

struct StrokeText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        ZStack {
            // White ring: 8 offset copies form the stroke
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                Text(text)
                    .font(BrandFont.welcome(size))
                    .foregroundColor(.white)
                    .offset(x: CGFloat(cos(angle)) * 2.2, y: CGFloat(sin(angle)) * 2.2)
            }
            // Knock out the center so it's hollow (shows the board behind)
            Text(text)
                .font(BrandFont.welcome(size))
                .foregroundColor(.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }
}

// MARK: - The welcome board's face
// The original welcome board asked for the display font by name before the font file was
// bundled, so iOS drew every word (and QUEENS) in its own system face. That look is the
// welcome board. Asking for a name that isn't installed takes exactly the same path, so it
// renders identically now that Big Shoulders is bundled for the rest of the app.
extension BrandFont {
    static func welcome(_ size: CGFloat) -> Font {
        .custom("BST-WelcomeBoard-SystemFace", size: size)
            .weight(.black)
    }
}
