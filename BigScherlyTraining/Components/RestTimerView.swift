import SwiftUI
import UIKit
import Combine

// MARK: - Rest Timer
// Appears after a set is marked done. Counts down the trainer-specified rest.
// Client can add/subtract 15s or skip. Shows a volt ring that drains as time passes.
struct RestTimerView: View {
    let totalSeconds: Int
    var onDismiss: () -> Void

    @State private var remaining: Int
    @State private var running = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(totalSeconds: Int, onDismiss: @escaping () -> Void) {
        self.totalSeconds = totalSeconds
        self.onDismiss = onDismiss
        _remaining = State(initialValue: totalSeconds)
    }

    private var progress: Double {
        totalSeconds == 0 ? 0 : Double(remaining) / Double(totalSeconds)
    }
    private var timeLabel: String {
        let m = remaining / 60, s = remaining % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
                .onTapGesture { }   // block taps behind

            VStack(spacing: 28) {
                Text("REST").font(BrandFont.body(13, .bold)).tracking(3).foregroundColor(Brand.volt)

                // Countdown ring
                ZStack {
                    Circle().stroke(Brand.line, lineWidth: 10)
                        .frame(width: 220, height: 220)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Brand.volt, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .frame(width: 220, height: 220)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remaining)
                    VStack(spacing: 4) {
                        Text(timeLabel).font(BrandFont.display(56)).foregroundColor(.white)
                        Text(remaining == 0 ? "GO!" : "until next set")
                            .font(BrandFont.body(12, .semibold)).tracking(1)
                            .foregroundColor(remaining == 0 ? Brand.volt : Brand.mute)
                    }
                }

                // Adjust buttons
                HStack(spacing: 14) {
                    adjustBtn("−15") { remaining = max(0, remaining - 15) }
                    Button {
                        running.toggle()
                    } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Brand.black)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(Brand.volt))
                    }
                    adjustBtn("+15") { remaining += 15 }
                }

                Button { onDismiss() } label: {
                    Text(remaining == 0 ? "START NEXT SET" : "SKIP REST")
                        .font(BrandFont.body(14, .bold)).tracking(1)
                        .foregroundColor(remaining == 0 ? Brand.black : Brand.mute)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(remaining == 0 ? Brand.volt : Color.clear)
                        .overlay(Rectangle().stroke(remaining == 0 ? Brand.volt : Brand.line, lineWidth: 2))
                }
                .padding(.horizontal, 40)
            }
            .padding(32)
        }
        .onReceive(tick) { _ in
            guard running, remaining > 0 else { return }
            remaining -= 1
            if remaining == 0 {
                // gentle haptic when rest ends
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func adjustBtn(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(BrandFont.body(15, .bold)).foregroundColor(.white)
                .frame(width: 64, height: 48)
                .overlay(Rectangle().stroke(Brand.line, lineWidth: 1))
        }
    }
}
