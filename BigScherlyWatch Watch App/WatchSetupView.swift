import SwiftUI
import WatchKit

// MARK: - Watch setup, on the wrist
// The Watch half of the first-time setup (the phone shows the card, the figure and the checks).
// Same language as the workout card: your accent, the same tile — Go, the border filling while
// you hold still or hold the bottom (with a tap at two seconds), then the reps against the target.

struct WatchSetupView: View {
    @EnvironmentObject var state: WatchState
    @EnvironmentObject var motion: MotionRecorder
    private let mute = Color(white: 0.56)

    var body: some View {
        if let step = state.setup {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 7) {
                        VStack(spacing: 1) {
                            Text(eyebrow(step)).font(.system(size: 8.5, weight: .heavy)).tracking(1.2).foregroundColor(mute)
                            Text(step.title).font(.system(size: 16, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                            tile(step, ctx.date)
                        }
                        .onTapGesture { if state.setupPhase == "ready" { state.setupGo() } }
                        if let m = state.setupMessage {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(state.accentColor)
                                Text(m).font(.system(size: 10.5, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 4)
                            if let d = state.setupDiag {                     // DIAGNOSTIC (temporary)
                                Text(d).font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundColor(Color(white: 0.45)).multilineTextAlignment(.center)
                            }
                        } else {
                            Text(hint(step)).font(.system(size: 9.5, weight: .bold)).foregroundColor(mute)
                                .multilineTextAlignment(.center)
                        }
                        // A way out on the wrist, in case the phone's gone (the phone has its own Skip).
                        Button { state.setupExit() } label: {
                            Text("Exit setup").font(.system(size: 11, weight: .semibold)).foregroundColor(mute)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private func eyebrow(_ s: WatchState.SetupStep) -> String {
        if s.lift == "body" { return "SETUP · \(s.n) OF \(s.of)" }
        return "\(s.lift.uppercased()) · SETUP"
    }

    private func hint(_ s: WatchState.SetupStep) -> String {
        switch state.setupPhase {
        case "ready": return s.kind == "still" ? "Tap, lower your arm — 3 seconds to get set" : "Tap, then get set — 3 seconds before it measures"
        case "countdown": return s.kind == "still" ? "Arm down, stand tall…" : "Get into position…"
        case "holding": return "Don't move…"
        case "checking": return "Checking your numbers on the phone"
        case "ok": return "Got it"
        default: return s.hint
        }
    }

    @ViewBuilder
    private func tile(_ s: WatchState.SetupStep, _ now: Date) -> some View {
        switch state.setupPhase {
        case "ready":
            filled(VStack(spacing: 1) {
                Text("Go").font(.system(size: 30, weight: .black))
                Text(s.caps).font(.system(size: 8, weight: .heavy)).tracking(1.1).opacity(0.7).lineLimit(1)
            })
        case "countdown":
            let left = max(0, (state.countdownEnds ?? now).timeIntervalSince(now))
            border((3 - left) / 3, VStack(spacing: 0) {
                Text("GET SET").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(state.accentColor)
                Text("\(max(1, Int(left.rounded(.up))))").font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(s.kind == "still" ? "ARM DOWN" : "INTO POSITION").font(.system(size: 7.5, weight: .heavy)).tracking(1).foregroundColor(mute)
            })
        case "holding":
            let held = now.timeIntervalSince(state.holdStarted ?? now)
            border(held / 3, VStack(spacing: 0) {
                Text("HOLD STILL").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(mute)
                Text("\(max(1, Int((3 - held).rounded(.up))))").font(.system(size: 32, weight: .heavy, design: .rounded))
            })
        case "capturing":
            if s.holdAtBottom, let start = motion.pauseStart {
                let held = now.timeIntervalSince(start)
                if motion.pauseReached || held >= 2 {
                    filled(VStack(spacing: 0) {
                        Image(systemName: "checkmark").font(.system(size: 18, weight: .heavy))
                        Text("2 s — up you go").font(.system(size: 11, weight: .heavy))
                    })
                } else {
                    border(held / 2, VStack(spacing: 0) {
                        Text("HOLD").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(state.accentColor)
                        Text(String(format: "%.1f", held)).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text(s.caps).font(.system(size: 7.5, weight: .heavy)).tracking(1).foregroundColor(mute).lineLimit(1)
                    })
                }
            } else {
                filled(VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(state.setupCount)").font(.system(size: 32, weight: .heavy, design: .rounded))
                        if s.target > 0 { Text("/ \(s.target)").font(.system(size: 16, weight: .heavy, design: .rounded)).opacity(0.6) }
                    }
                    Text(s.caps).font(.system(size: 8, weight: .heavy)).tracking(1.1).opacity(0.7).lineLimit(1)
                })
                .animation(.spring(response: 0.3), value: state.setupCount)
            }
        case "checking":
            VStack(spacing: 4) {
                ProgressView().tint(state.accentColor)
                Text("CHECKING").font(.system(size: 8.5, weight: .heavy)).tracking(1.4).foregroundColor(mute)
            }
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(state.accentColor.opacity(0.6), lineWidth: 1.5))
            .padding(.horizontal, 4)
        default:   // ok
            filled(Image(systemName: "checkmark.seal.fill").font(.system(size: 30, weight: .bold)))
        }
    }

    private func filled<C: View>(_ content: C) -> some View {
        content.foregroundColor(state.inkColor)
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 18).fill(state.accentColor))
            .padding(.horizontal, 4)
    }

    /// The border fills clockwise from top centre — the rest border's shape, filling instead of draining.
    private func border<C: View>(_ fraction: Double, _ content: C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.black)
            TileOutline().stroke(Color.white.opacity(0.08), lineWidth: 4).padding(2)
            TileOutline().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(state.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)).padding(2)
            content
        }
        .frame(maxWidth: .infinity).frame(height: 78)
        .padding(.horizontal, 4)
    }
}
