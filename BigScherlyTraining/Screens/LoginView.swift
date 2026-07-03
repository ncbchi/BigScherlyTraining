import SwiftUI
import Combine

// MARK: - Login Screen
struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            Brand.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image("logo")            // add logo asset; text fallback below
                    .resizable().scaledToFit()
                    .frame(height: 120)
                    .padding(.bottom, 8)

                Text("Big Scherly Training")
                    .font(BrandFont.display(30))
                    .foregroundColor(Brand.white)
                Text("Lets Get Big Together Queens")
                    .font(BrandFont.body(11, .bold))
                    .tracking(3).foregroundColor(Brand.volt)
                    .padding(.bottom, 40)

                VStack(spacing: 14) {
                    styledField("Email", text: $email, secure: false)
                    styledField("Password", text: $password, secure: true)
                    if showError {
                        Text("Check your email and password.")
                            .font(BrandFont.body(13)).foregroundColor(Brand.danger)
                    }
                    VoltButton(title: "Log In") {
                        if APIConfig.useMock {
                            store.login()          // prototype: any input logs in
                        } else {
                            Task {
                                do {
                                    let resp = try await APIClient.shared.login(email: email, password: password)
                                    APIClient.shared.setToken(resp.token)
                                    await MainActor.run { store.login() }
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
                Text("LGBTQ+ owned · Since 2024")
                    .font(BrandFont.body(11, .semibold))
                    .tracking(2).foregroundColor(Brand.mute)
                    .padding(.bottom, 20)
            }
        }
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
        .background(Brand.black)
        .overlay(
            ZStack(alignment: .leading) {
                Rectangle().stroke(Brand.line, lineWidth: 1)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).foregroundColor(Brand.mute)
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
    @StateObject private var motion = MotionManager()
    @State private var scroll: CGFloat = 0
    @Binding var showBoard: Bool

    let timer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Brand.black.ignoresSafeArea()

            // Revolving photo board (two tilted columns drifting opposite directions)
            HStack(spacing: 12) {
                revolvingColumn(reversed: false)
                revolvingColumn(reversed: true)
                revolvingColumn(reversed: false)
            }
            .rotationEffect(.degrees(-8))
            .scaleEffect(1.5)
            .opacity(0.5)
            .allowsHitTesting(false)

            // Dark scrim for text legibility
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.45), .black.opacity(0.8)],
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
                MetallicRainbowText(text: "QUEENS", size: 96, motion: motion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                VoltButton(title: "Enter") { withAnimation { showBoard = false } }
                    .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .onReceive(timer) { _ in scroll += 0.6 }
    }

    // Big, heavy, one line each — shrinks to fit width so TOGETHER never wraps.
    private let headlineSize: CGFloat = 96

    func filledWord(_ w: String) -> some View {
        Text(w)
            .font(BrandFont.display(headlineSize))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    func outlinedWord(_ w: String) -> some View {
        // Outlined white text: stroked ring with a transparent center.
        StrokeText(text: w, size: headlineSize)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Vertically drifting column of photos, looping
    func revolvingColumn(reversed: Bool) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let dir: CGFloat = reversed ? 1 : -1
            let y = (scroll * dir).truncatingRemainder(dividingBy: h)
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { i in
                    boardTile(i)
                }
                ForEach(0..<6, id: \.self) { i in
                    boardTile(i)   // duplicate for seamless loop
                }
            }
            .offset(y: y - h/2)
        }
    }
    func boardTile(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Brand.bg)
            .aspectRatio(0.8, contentMode: .fit)
            .overlay(
                Image(store.boardPhotos[i % store.boardPhotos.count])
                    .resizable().scaledToFill()
            )
            .overlay(
                // fallback label when no asset present
                Text("#bigscherlytraining")
                    .font(BrandFont.body(9, .bold)).foregroundColor(Brand.mute)
            )
            .clipped()
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
                    .font(BrandFont.display(size))
                    .foregroundColor(.white)
                    .offset(x: CGFloat(cos(angle)) * 2.2, y: CGFloat(sin(angle)) * 2.2)
            }
            // Knock out the center so it's hollow (shows the board behind)
            Text(text)
                .font(BrandFont.display(size))
                .foregroundColor(.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }
}
