import SwiftUI
import UIKit

// MARK: - Settings ▸ Lock Screen & Dynamic Island
// Everything the workout card does outside the app: on/off, its look, what closing the app
// does, what it shows, tidying up, and a sample. LiveSessionController reads CardPrefs.
// Target membership: BigScherlyTraining (automatic — it's in the BigScherlyTraining folder).

enum CardPrefs {
    enum Look: String, CaseIterable { case app, light, dark, auto }
    enum Close: String, CaseIterable { case keep, close, closeKeep }
    enum AfterSet: String, CaseIterable { case ask, auto, off }
    enum StartAt: String, CaseIterable { case open, firstSet }

    static let showKey = "bst_live_activity"            // (existing key: Rest timer ▸ Lock Screen card is the same switch)
    static let lookKey = "bst_card_look"
    static let accentKey = "bst_card_accent"           // 0 = the app's accent
    static let closeKey = "bst_card_close"
    static let idleKey = "bst_card_idle"               // minutes; 0 = never
    static let startViewKey = "bst_card_start_view"
    static let islandKey = "bst_card_island"           // hr · sets · rest
    static let afterSetKey = "bst_card_after_set"
    static let autoLogKey = "bst_card_autolog_secs"    // 10–30
    static let startAtKey = "bst_card_start_at"
    static let endKey = "bst_card_end_with_workout"

    private static var d: UserDefaults { .standard }
    static var showCard: Bool { d.object(forKey: showKey) as? Bool ?? true }
    static var look: Look { Look(rawValue: d.string(forKey: lookKey) ?? "") ?? .app }
    static var accent: UInt32? { let v = d.integer(forKey: accentKey); return v > 0 ? UInt32(v) : nil }
    static var close: Close { Close(rawValue: d.string(forKey: closeKey) ?? "") ?? .keep }
    static var idleMinutes: Int { d.object(forKey: idleKey) as? Int ?? 60 }
    static var startView: LiveView { LiveView(rawValue: d.string(forKey: startViewKey) ?? "") ?? .heartRate }
    static var island: String { d.string(forKey: islandKey) ?? "hr" }
    static var afterSet: AfterSet { AfterSet(rawValue: d.string(forKey: afterSetKey) ?? "") ?? .ask }
    static var autoLogSeconds: Int { min(30, max(10, d.object(forKey: autoLogKey) as? Int ?? 10)) }
    static var startAt: StartAt { StartAt(rawValue: d.string(forKey: startAtKey) ?? "") ?? .open }
    static var endWithWorkout: Bool { d.object(forKey: endKey) as? Bool ?? true }

    /// The line under the Settings row: how it's set right now.
    static var summary: String {
        guard showCard else { return "Off" }
        let l: String
        switch look {
        case .app: l = "Follows the app"
        case .light: l = "Light"
        case .dark: l = "Dark"
        case .auto: l = "Follows your iPhone"
        }
        let c: String
        switch close {
        case .keep: c = "Stays while a workout is going"
        case .close: c = "Closes with the app"
        case .closeKeep: c = "Closes with the app, workout kept"
        }
        return "On during workouts · \(l) · \(c)"
    }
}

struct LockCardSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("bst_units") private var units = "lb"
    @AppStorage("bst_weight_step") private var weightStep = "standard"
    @AppStorage(CardPrefs.showKey) private var show = true
    @AppStorage(CardPrefs.lookKey) private var look = CardPrefs.Look.app.rawValue
    @AppStorage(CardPrefs.accentKey) private var accent = 0
    @AppStorage(CardPrefs.closeKey) private var close = CardPrefs.Close.keep.rawValue
    @AppStorage(CardPrefs.idleKey) private var idle = 60
    @AppStorage(CardPrefs.startViewKey) private var startView = LiveView.heartRate.rawValue
    @AppStorage(CardPrefs.islandKey) private var island = "hr"
    @AppStorage(CardPrefs.afterSetKey) private var afterSet = CardPrefs.AfterSet.ask.rawValue
    @AppStorage(CardPrefs.autoLogKey) private var autoLogSecs = 10
    @AppStorage(CardPrefs.startAtKey) private var startAt = CardPrefs.StartAt.open.rawValue
    @AppStorage(CardPrefs.endKey) private var endWithWorkout = true
    @State private var sampleNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LockCardPreview(light: previewLight, accent: previewAccent, island: island)
                    section("The card", foot: "Off: no card at all. The rest timer still rings, and the Watch still shows the workout.") {
                        toggle("Show during workouts", "The card on your Lock Screen and in the Dynamic Island", $show)
                    }
                    if show {
                        appearance
                        closing
                        shows
                        tidying
                        checkIt
                    }
                }
                .padding(20)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Lock Screen & Dynamic Island")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundColor(Brand.voltText) }
            }
            .animation(.easeInOut(duration: 0.2), value: show)
        }
    }

    // MARK: Sections

    private var appearance: some View {
        section("Appearance", foot: "The Dynamic Island is always black: it's the hardware.") {
            segRow("Card", sel: $look, [("App", "app"), ("Light", "light"), ("Dark", "dark"), ("Auto", "auto")],
                   note: "App: follows Settings ▸ Appearance. Auto: follows your iPhone (light by day, dark at night).")
            divider
            HStack {
                label("Accent", "Fills, the rest border, the bars")
                Spacer()
                Picker("Accent", selection: $accent) {
                    Text("App accent").tag(0)
                    ForEach(ThemeStore.accents) { a in Text(a.name).tag(Int(a.hex)) }
                }
                .pickerStyle(.menu).tint(Brand.mute)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var closing: some View {
        section("When you close the app",
                foot: "iOS only tells an app it's closing while the app is still awake, about 30 s after you leave it. After that, Auto-end tidies up a card left behind.") {
            radio("Keep it while a workout is going",
                  "Stays until the workout's finished, then closes by itself. Closing the app doesn't end your workout.", "keep")
            divider
            radio("Close it with the app", "Swiping the app away ends the card, the Dynamic Island and the Watch session.", "close")
            divider
            radio("Close it, but keep the workout", "The card goes; open the app to pick the workout back up where you were.", "closeKeep")
        }
    }

    private var shows: some View {
        section("What it shows", foot: afterSet == "auto"
                ? "Log set and Edit stay on the card while it counts down. Edit stops the countdown."
                : (afterSet == "off" ? "Off: the card just says the set's done; log it in the app." : nil)) {
            segRow("Starts on", sel: $startView, [("Heart rate", LiveView.heartRate.rawValue), ("Bar speed", LiveView.speed.rawValue),
                                                  ("Sets", LiveView.sets.rawValue)],
                   note: "The right side's view when a workout opens. You can still flip views on the card.")
            divider
            segRow("Dynamic Island, right", sel: $island, [("Heart rate", "hr"), ("Set 3/5", "sets"), ("Rest", "rest")],
                   note: "The small pill next to the camera.")
            divider
            segRow("After a set", sel: $afterSet, [("Ask me", "ask"), ("Log by itself", "auto"), ("Off", "off")],
                   note: "Ask me: the set filled in, with Log set and Edit.")
            if afterSet == "auto" {
                divider
                HStack {
                    label("Log it after", "Time to tap Edit first")
                    Spacer()
                    Stepper("\(autoLogSecs) s", value: $autoLogSecs, in: 10...30, step: 5)
                        .font(BrandFont.body(14, .bold)).foregroundColor(Brand.text).fixedSize()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var tidying: some View {
        section("Tidying up", foot: nil) {
            segRow("Auto-end if idle", sel: $idle, [("30 min", 30), ("1 h", 60), ("2 h", 120), ("Never", 0)],
                   note: "No set logged and no rest running for this long: the card ends by itself. Your workout's kept — open it to carry on.")
            divider
            segRow("Start the card", sel: $startAt, [("Workout opens", "open"), ("First set", "firstSet")],
                   note: "First set: the card appears when you start lifting (in the app or on the Watch).")
            divider
            toggle("End with the workout", "Finish workout takes the card down right away (off: it shows the summary for a while)", $endWithWorkout)
        }
    }

    private var checkIt: some View {
        section("Check it", foot: sampleNote) {
            Button {
                sampleNote = LiveSessionController.shared.showSample()
                    ? "Showing for 15 seconds — lock your phone to see it."
                    : "A workout card is up right now — the sample needs the Lock Screen to itself."
            } label: {
                HStack {
                    label("Show a sample card", "A 15-second demo on your Lock Screen. Lock the phone to see it.")
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundColor(Brand.voltText)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            divider
            HStack {
                label("Weight steps", "Rounds the weights the card fills in")
                Spacer()
                Picker("Weight steps", selection: $weightStep) {
                    Text(units == "kg" ? "1.25" : "2.5").tag("small")
                    Text(units == "kg" ? "2.5" : "5").tag("standard")
                }
                .pickerStyle(.segmented).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Preview look

    private var previewLight: Bool {
        switch CardPrefs.Look(rawValue: look) ?? .app {
        case .light: return true
        case .dark: return false
        case .auto: return scheme == .light
        case .app: return (theme.forcedScheme ?? scheme) == .light
        }
    }
    private var previewAccent: UInt32 { accent > 0 ? UInt32(accent) : theme.accent }

    // MARK: Building blocks

    private var divider: some View { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 16) }

    private func label(_ t: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(BrandFont.body(15)).foregroundColor(Brand.text)
            if let sub { Text(sub).font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func section<C: View>(_ title: String, foot: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                .shadow(color: Brand.shadow, radius: 9, x: 0, y: 3)
            if let foot {
                Text(foot).font(BrandFont.body(11)).foregroundColor(Brand.mute).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ t: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { label(t, sub) }
            .tint(Brand.volt)
            .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func segRow<V: Hashable>(_ t: String, sel: Binding<V>, _ opts: [(String, V)], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(BrandFont.body(15)).foregroundColor(Brand.text)
            Picker(t, selection: sel) {
                ForEach(opts.indices, id: \.self) { i in Text(opts[i].0).tag(opts[i].1) }
            }
            .pickerStyle(.segmented)
            if let note { Text(note).font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func radio(_ t: String, _ sub: String, _ value: String) -> some View {
        Button { close = value } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if close == value {
                        Circle().fill(Brand.volt)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(Brand.onVolt)
                    } else {
                        Circle().stroke(Brand.line, lineWidth: 2)
                    }
                }
                .frame(width: 22, height: 22)
                label(t, sub)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small drawing of the card and the Dynamic Island, in the look you've picked.
private struct LockCardPreview: View {
    let light: Bool
    let accent: UInt32
    let island: String

    var body: some View {
        let raw = RGBColor(hex: accent)
        let fill = light ? Color(hex: UInt(accent)) : Color(hex: UInt(raw.readableOnDark(RGBColor(hex: 0x010101)).hex))
        let line = light && raw.contrast(.white) < 1.6 ? Color(hex: 0x8E8E93) : fill
        let card = light ? Color.white : Color(hex: 0x010101)
        let panel = light ? Color(hex: 0xF2F2F4) : Color(hex: 0x141416)
        let ink = light ? Color(hex: 0x111113) : Color.white
        let mute = light ? Color(hex: 0x6E6E73) : Color(white: 0.56)
        VStack(spacing: 8) {
            VStack(spacing: 12) {
                // Dynamic Island
                HStack {
                    Text(island == "rest" ? "Set 4/5" : "1:58").foregroundColor(Color(hex: UInt(raw.readableOnDark(RGBColor(hex: 0)).hex)))
                    Spacer()
                    Group {
                        switch island {
                        case "sets": Text("4/5").foregroundColor(Color(hex: UInt(raw.readableOnDark(RGBColor(hex: 0)).hex)))
                        case "rest": Text("1:58").foregroundColor(Color(hex: UInt(raw.readableOnDark(RGBColor(hex: 0)).hex)))
                        default: (Text(Image(systemName: "heart.fill")) + Text(" 142")).foregroundColor(Color(hex: 0xFF5555))
                        }
                    }
                }
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .padding(.horizontal, 16).frame(width: 200, height: 36)
                .background(Capsule().fill(Color.black))
                // The card
                HStack(spacing: 8) {
                    VStack(spacing: 4) {
                        Text("Back Squat").font(.system(size: 11, weight: .heavy)).foregroundColor(ink)
                        Text("5 × 275 lb").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(light ? ink : fill)
                        Text("1:58").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(ink)
                            .frame(width: 88, height: 44)
                            .background(RoundedRectangle(cornerRadius: 11).fill(card))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(line, lineWidth: 3))
                    }
                    .frame(width: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BAR SPEED").font(.system(size: 7, weight: .heavy)).tracking(1).foregroundColor(light ? Color(hex: UInt(raw.readableOnDark(RGBColor(hex: 0x39393B)).hex)) : fill)
                            .padding(.horizontal, light ? 5 : 0).padding(.vertical, light ? 1.5 : 0)
                            .background(Capsule().fill(light ? Color(red: 30 / 255, green: 30 / 255, blue: 33 / 255).opacity(0.88) : .clear))
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach([54.0, 52, 49, 46, 42], id: \.self) { h in
                                RoundedRectangle(cornerRadius: 2).fill(line).frame(height: h * 0.8)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        Text("Peak 0.58 · Loss 22%").font(.system(size: 8, weight: .bold)).foregroundColor(mute)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(panel))
                }
                .padding(10)
                .frame(height: 118)
                .background(RoundedRectangle(cornerRadius: 20).fill(card))
                .shadow(color: .black.opacity(light ? 0.12 : 0.4), radius: 10, x: 0, y: 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22).fill(light
                ? LinearGradient(colors: [Color(hex: 0xE9EEF6), Color(hex: 0xB9C4D6)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(hex: 0x3A2A5C), Color(hex: 0x0B0B0F)], startPoint: .top, endPoint: .bottom)))
            Text("Preview · changes as you pick").font(BrandFont.body(11)).foregroundColor(Brand.mute)
        }
        .animation(.easeInOut(duration: 0.2), value: light)
    }
}
