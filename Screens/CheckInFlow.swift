import SwiftUI
import PhotosUI

extension Calendar {
    // Monday-agnostic start of the week containing `date`.
    func startOfWeek(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? date
    }
}

// MARK: - Check-in schema
//
// Fields are typed so the form can render the right control and the celebration
// can compute week-over-week deltas. Values still serialize into the existing
// CheckInField {label, value} container, with the type/kind encoded so the
// trainer console and history can read them back.

enum CheckInKind: String, Codable, CaseIterable {
    case scale        // 1–10 slider
    case number       // numeric input (weight) — supports week-over-week delta
    case longText     // open-ended answer
}

struct CheckInQuestion: Identifiable {
    let id: String
    let label: String
    let kind: CheckInKind
    let unit: String          // e.g. "lb" for weight; "" otherwise
    let tracksDelta: Bool     // show week-over-week change (weight)
    let higherIsBetter: Bool  // for framing wins (e.g. sleep up = good)

    init(_ id: String, _ label: String, _ kind: CheckInKind,
         unit: String = "", tracksDelta: Bool = false, higherIsBetter: Bool = true) {
        self.id = id; self.label = label; self.kind = kind
        self.unit = unit; self.tracksDelta = tracksDelta; self.higherIsBetter = higherIsBetter
    }
}

enum CheckInSchema {
    // Coach's list + the five approved additions. Order is intentional: the quick
    // 1–10 scales first, then weight, then the open-ended reflection last.
    static let questions: [CheckInQuestion] = [
        .init("hydration",   "Hydration",              .scale),
        .init("nutrition",   "Nutrition adherence",    .scale),
        .init("consistency", "Workout consistency",    .scale),
        .init("sleepQuality","Sleep quality",          .scale),
        // Five approved additions
        .init("energy",      "Energy / fatigue",       .scale),
        .init("stress",      "Stress load",            .scale, higherIsBetter: false),
        .init("soreness",    "Soreness / recovery",    .scale),
        .init("cravings",    "Cravings / hunger",      .scale, higherIsBetter: false),
        .init("motivation",  "Motivation / mood",      .scale),
        // Weight with week-over-week delta
        .init("weight",      "Bodyweight",             .number, unit: "lb", tracksDelta: true),
        // Open-ended
        .init("feedback",    "How did the workouts feel? (too long/short/hard/easy?)", .longText),
        .init("anythingElse","Anything else you'd like to cover?", .longText),
    ]

    static func question(_ id: String) -> CheckInQuestion? { questions.first { $0.id == id } }
}

// MARK: - Reading stored fields

// Fields are stored with label "Human Label|kind". These helpers parse them back
// so the UI never shows the raw "|scale" suffix.
extension CheckInField {
    var cleanLabel: String { label.components(separatedBy: "|").first ?? label }
    var kind: CheckInKind {
        let raw = label.components(separatedBy: "|").last ?? ""
        return CheckInKind(rawValue: raw) ?? .longText
    }
}

// MARK: - Summary card (list)

struct CheckInSummaryCard: View {
    let checkIn: CheckIn

    // A couple of headline stats for the compact card.
    private var weightField: CheckInField? {
        checkIn.fields.first { $0.cleanLabel == "Bodyweight" }
    }
    private var scaleAverage: Int? {
        let scales = checkIn.fields.filter { $0.kind == .scale }.compactMap { Double($0.value) }
        guard !scales.isEmpty else { return nil }
        return Int((scales.reduce(0, +) / Double(scales.count)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(dateLabel(checkIn.date)).font(BrandFont.display(22)).foregroundColor(Brand.text)
                Spacer()
                statusPill(checkIn.status)
            }
            HStack(spacing: 10) {
                if let w = weightField, !w.value.isEmpty {
                    miniStat(icon: "scalemass.fill", value: "\(w.value) lb", label: "WEIGHT")
                }
                if let avg = scaleAverage {
                    miniStat(icon: "chart.bar.fill", value: "\(avg)/10", label: "AVG SCORE")
                }
                if !checkIn.photoIDs.isEmpty {
                    miniStat(icon: "photo.fill", value: "\(checkIn.photoIDs.count)", label: "PHOTOS")
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(Brand.mute)
            }
            if checkIn.trainerResponse != nil {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 10))
                    Text("Coach responded").font(BrandFont.body(11, .bold))
                }
                .foregroundColor(Brand.voltText)
            }
        }
        .card()
    }

    private func miniStat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(Brand.voltText)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(BrandFont.body(14, .bold)).foregroundColor(Brand.text)
                Text(label).font(BrandFont.body(8, .bold)).tracking(0.5).foregroundColor(Brand.mute)
            }
        }
    }

    private func statusPill(_ s: CheckInStatus) -> some View {
        let (txt, col): (String, Color) = {
            switch s {
            case .draft:     return ("Draft", Brand.mute)
            case .submitted: return ("Sent", Brand.volt)
            case .reviewed:  return ("Reviewed", Brand.volt)
            }
        }()
        return Text(txt.uppercased())
            .font(BrandFont.body(10, .bold)).tracking(1)
            .foregroundColor(s == .draft ? Brand.mute : Brand.onVolt)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(s == .draft ? Color.clear : col)
            .overlay(Capsule().stroke(col, lineWidth: 1))
            .clipShape(Capsule())
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d)
    }
}

// MARK: - Full detail view

struct CheckInDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let checkIn: CheckIn

    private var scales: [CheckInField] { checkIn.fields.filter { $0.kind == .scale } }
    private var numbers: [CheckInField] { checkIn.fields.filter { $0.kind == .number } }
    private var longText: [CheckInField] { checkIn.fields.filter { $0.kind == .longText } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let resp = checkIn.trainerResponse {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR COACH SAID").font(BrandFont.body(10, .bold)).tracking(1.2).headerPill()
                            Text("“\(resp)”").font(BrandFont.body(16, .semibold)).foregroundColor(Brand.text)
                                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
                    }

                    // Weight (with its own emphasis)
                    ForEach(numbers) { f in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.cleanLabel.uppercased())
                                .font(BrandFont.body(11, .bold)).tracking(1.2).headerPill()
                            Text(f.value.isEmpty ? "—" : "\(f.value) lb")
                                .font(BrandFont.display(34)).foregroundColor(Brand.text)
                        }
                    }

                    // Scales as labeled bars
                    if !scales.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("HOW THE WEEK FELT")
                                .font(BrandFont.body(11, .bold)).tracking(1.2).headerPill()
                            ForEach(scales) { f in
                                scaleBar(f.cleanLabel, value: Int(f.value) ?? 0)
                            }
                        }
                    }

                    // Long answers
                    ForEach(longText) { f in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.cleanLabel.uppercased())
                                .font(BrandFont.body(11, .bold)).tracking(1.2).headerPill()
                            Text(f.value.isEmpty ? "—" : f.value)
                                .font(BrandFont.body(15)).foregroundColor(Brand.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Brand.black)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                        }
                    }

                    if !checkIn.photoIDs.isEmpty {
                        Text("\(checkIn.photoIDs.count) photo\(checkIn.photoIDs.count > 1 ? "s" : "") attached")
                            .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.voltText)
                    }

                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(dateLabel(checkIn.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }.foregroundColor(Brand.voltText) } }
        }
    }

    private func scaleBar(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(BrandFont.body(13, .semibold)).foregroundColor(Brand.text)
                Spacer()
                Text("\(value)/10").font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.line)
                    Capsule().fill(Brand.volt)
                        .frame(width: geo.size.width * CGFloat(value) / 10)
                }
            }
            .frame(height: 6)
        }
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d)
    }
}

// MARK: - New check-in form

struct NewCheckInForm: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // Answers keyed by question id.
    @State private var scales: [String: Double] = [:]
    @State private var weight: String = ""
    @State private var longAnswers: [String: String] = [:]
    @State private var showCelebration = false
    @State private var submittedFields: [CheckInField] = []
    @State private var photos: [String: UIImage] = [:]   // slot label → picked image

    // Previous week's weight, for the live delta.
    private var previousWeight: Double? {
        store.lastCheckInValue(questionId: "weight").flatMap { Double($0) }
    }
    private var weightDelta: Double? {
        guard let prev = previousWeight, let now = Double(weight), !weight.isEmpty else { return nil }
        return now - prev
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Rate this past week, log your weight, and tell your coach how it went.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)

                    ForEach(CheckInSchema.questions) { q in
                        questionView(q)
                    }

                    // Check-in photos — the six shots the coach asks for.
                    photoSection

                    VoltButton(title: "Submit Check-In") { submit() }
                        .padding(.top, 4)
                }
                .padding(.top, 12).padding(.horizontal, 20).padding(.bottom, 30)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("New Check-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }.foregroundColor(Brand.voltText) } }
            .tapToDismissKeyboard()
        }
        .fullScreenCover(isPresented: $showCelebration) {
            CheckInCelebrationView(fields: submittedFields) { dismiss() }
        }
    }

    // The six labeled check-in photo slots.
    private let photoSlots = ["Front", "Side", "Back", "Side 2", "Flex Front", "Flex Back"]

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHECK-IN PHOTOS")
                .font(BrandFont.body(11, .bold)).tracking(1.2).headerPill()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(photoSlots, id: \.self) { slot in
                    PhotoSlotTile(label: slot, image: photos[slot]) { img in
                        photos[slot] = img
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func questionView(_ q: CheckInQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q.label.uppercased())
                .font(BrandFont.body(11, .bold)).tracking(1.2).headerPill()

            switch q.kind {
            case .scale:
                ScaleRow(value: Binding(
                    get: { scales[q.id] ?? 5 },
                    set: { scales[q.id] = $0 }))
            case .number:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("0", text: $weight)
                            .keyboardType(.decimalPad)
                            .font(BrandFont.display(26)).foregroundColor(Brand.text)
                            .frame(maxWidth: 120)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
                        Text(q.unit).font(BrandFont.body(15, .bold)).foregroundColor(Brand.mute)
                        Spacer()
                    }
                    if let d = weightDelta {
                        let up = d > 0
                        HStack(spacing: 5) {
                            Image(systemName: up ? "arrow.up.right" : (d < 0 ? "arrow.down.right" : "minus"))
                                .font(.system(size: 11, weight: .bold))
                            Text("\(up ? "+" : "")\(String(format: "%.1f", d)) \(q.unit) vs last week")
                                .font(BrandFont.body(12, .semibold))
                        }
                        .foregroundColor(Brand.voltText)
                    } else if previousWeight == nil {
                        Text("First weigh-in — we'll track the change next week.")
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                }
            case .longText:
                TextEditor(text: Binding(
                    get: { longAnswers[q.id] ?? "" },
                    set: { longAnswers[q.id] = $0 }))
                    .font(BrandFont.body(15)).foregroundColor(Brand.text)
                    .scrollContentBackground(.hidden)
                    .padding(10).frame(height: 110)
                    .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line, lineWidth: 1))
            }
        }
    }

    private func submit() {
        var fields: [CheckInField] = []
        for q in CheckInSchema.questions {
            let value: String
            switch q.kind {
            case .scale:   value = "\(Int(scales[q.id] ?? 5))"
            case .number:  value = weight.isEmpty ? "" : weight
            case .longText: value = longAnswers[q.id] ?? ""
            }
            // Encode the kind into the label so history/trainer can parse it back:
            // "Hydration|scale" etc. Keeps the existing {label,value} container.
            fields.append(CheckInField(id: q.id, label: "\(q.label)|\(q.kind.rawValue)", value: value))
        }
        submittedFields = fields
        store.submitCheckIn(fields: fields, photos: photos)
        showCelebration = true
    }
}

// A single check-in photo slot: tap to pick, shows the thumbnail once chosen.
struct PhotoSlotTile: View {
    let label: String
    let image: UIImage?
    let onPick: (UIImage) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Brand.black)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack {
                        Spacer()
                        Text(label.uppercased())
                            .font(BrandFont.body(9, .bold)).tracking(0.5).foregroundColor(Brand.text)
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                                       startPoint: .top, endPoint: .bottom))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundColor(Brand.voltText)
                        Text(label.uppercased())
                            .font(BrandFont.body(9, .bold)).tracking(0.5).foregroundColor(Brand.mute)
                    }
                }
            }
            .aspectRatio(3.0/4.0, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(image == nil ? Brand.line : Brand.voltLine.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: image == nil ? [5] : [])))
        }
        .buttonStyle(.plain)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    await MainActor.run { onPick(ui) }
                }
            }
        }
    }
}

// A 1–10 scale. Only the SELECTED number lights up volt (with a soft glow) — the
// rest stay quiet so a full screen of scores reads calm, not a wall of yellow.
struct ScaleRow: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...10, id: \.self) { n in
                let selected = Int(value) == n
                Button { value = Double(n) } label: {
                    Text("\(n)")
                        .font(BrandFont.body(n == 10 ? 13 : 14, .bold))
                        .foregroundColor(selected ? Brand.onVolt : tileText(n))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(selected ? Brand.volt : Brand.black)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? Brand.voltLine : Brand.line, lineWidth: 1))
                        .shadow(color: selected ? Brand.volt.opacity(0.4) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Unselected numbers dim slightly toward the low end so the scale still reads
    // left→right without shouting.
    private func tileText(_ n: Int) -> Color {
        n <= 3 ? Brand.mute.opacity(0.55) : Brand.mute
    }
}

// MARK: - Celebration

struct CheckInCelebrationView: View {
    @EnvironmentObject var store: AppStore
    let fields: [CheckInField]
    let onDone: () -> Void

    @State private var appear = false
    @State private var showWins = false

    private var wins: [CheckInWin] { store.computeWins(from: fields) }

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            ConfettiView().opacity(appear ? 1 : 0)

            ScrollView {
                VStack(spacing: 22) {
                    // Hero
                    ZStack {
                        Circle().fill(Brand.volt.opacity(0.15))
                            .frame(width: 130, height: 130)
                            .scaleEffect(appear ? 1 : 0.4)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 68, weight: .bold))
                            .foregroundColor(Brand.voltText)
                            .scaleEffect(appear ? 1 : 0.3)
                            .rotationEffect(.degrees(appear ? 0 : -30))
                    }
                    .padding(.top, 40)

                    VStack(spacing: 6) {
                        Text("CHECK-IN COMPLETE")
                            .font(BrandFont.body(12, .bold)).tracking(2).headerPill()
                        Text("Look at this week 👑")
                            .font(BrandFont.display(32)).foregroundColor(Brand.text)
                            .multilineTextAlignment(.center)
                    }
                    .opacity(appear ? 1 : 0)

                    // Wins
                    VStack(spacing: 12) {
                        if wins.isEmpty {
                            Text("Logged and sent to your coach. Keep stacking weeks — the wins compound. 💪")
                                .font(BrandFont.body(15)).foregroundColor(Brand.mute)
                                .multilineTextAlignment(.center).padding(.horizontal, 20)
                        } else {
                            ForEach(Array(wins.enumerated()), id: \.element.id) { i, win in
                                winCard(win)
                                    .opacity(showWins ? 1 : 0)
                                    .offset(y: showWins ? 0 : 16)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.7)
                                        .delay(Double(i) * 0.12), value: showWins)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Button { onDone() } label: {
                        Text("Done")
                            .font(BrandFont.body(16, .bold)).foregroundColor(Brand.onVolt)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Brand.volt).clipShape(Capsule())
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                    .opacity(appear ? 1 : 0)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { appear = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) { showWins = true }
        }
    }

    private func winCard(_ win: CheckInWin) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Brand.volt).frame(width: 44, height: 44)
                Image(systemName: win.icon)
                    .font(.system(size: 19, weight: .bold)).foregroundColor(Brand.onVolt)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(win.title).font(BrandFont.body(15, .bold)).foregroundColor(Brand.text)
                Text(win.detail).font(BrandFont.body(13)).foregroundColor(Brand.mute)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.voltLine.opacity(0.5), lineWidth: 1))
    }
}

// A single celebratory stat.
struct CheckInWin: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

// MARK: - Lightweight confetti

struct ConfettiView: View {
    @State private var animate = false
    private let pieces = 40
    private let colors: [Color] = [Brand.volt, Brand.text, Brand.volt.opacity(0.6)]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<pieces, id: \.self) { i in
                    let x = CGFloat.random(in: 0...geo.size.width)
                    let size = CGFloat.random(in: 5...10)
                    let delay = Double.random(in: 0...0.5)
                    Rectangle()
                        .fill(colors[i % colors.count])
                        .frame(width: size, height: size * 1.6)
                        .position(x: x, y: animate ? geo.size.height + 40 : -40)
                        .rotationEffect(.degrees(animate ? Double.random(in: 180...540) : 0))
                        .animation(.easeIn(duration: Double.random(in: 1.6...2.6)).delay(delay), value: animate)
                }
            }
            .onAppear { animate = true }
        }
        .allowsHitTesting(false)
    }
}
