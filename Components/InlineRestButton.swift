import SwiftUI
import Combine

// MARK: - Inline Rest Button
// Tap "Done" and THIS button becomes the rest timer: a volt progress bar drains
// across it with the countdown inside. No separate window. Works in the background
// via a scheduled notification, and recomputes from the saved end-time on return.
struct InlineRestButton: View {
    let restSeconds: Int

    @Environment(\.scenePhase) private var scenePhase
    @State private var running = false
    @State private var endTime: Date?
    @State private var remaining: Int = 0
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var progress: Double {
        guard restSeconds > 0 else { return 0 }
        return max(0, min(1, Double(remaining) / Double(restSeconds)))
    }
    private var timeLabel: String {
        let m = remaining / 60, s = remaining % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }
    private var restLabel: String {
        let m = restSeconds / 60, s = restSeconds % 60
        return m > 0 ? (s > 0 ? "\(m):\(String(format: "%02d", s))" : "\(m) MIN") : "\(s)S"
    }

    var body: some View {
        Group {
            if running {
                countdownBar
            } else {
                doneButton
            }
        }
        .onReceive(tick) { _ in updateRemaining() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updateRemaining() }   // recompute after returning
        }
    }

    // Idle state: the green Done button
    private var doneButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                Text("DONE — REST \(restLabel)")
            }
            .font(BrandFont.body(13, .bold)).tracking(0.5)
            .foregroundColor(Brand.onVolt)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Brand.volt)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // Running state: progress bar fills within the button footprint
    private var countdownBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // track
                Rectangle().fill(Brand.black)
                // draining volt fill
                Rectangle().fill(Brand.volt)
                    .frame(width: geo.size.width * progress)
                    .animation(.linear(duration: 0.2), value: progress)

                // label sits on top; readable over both fill and track
                HStack {
                    Text(remaining == 0 ? "GO!" : "REST")
                        .font(BrandFont.body(13, .bold)).tracking(1)
                    Spacer()
                    Text(remaining == 0 ? "" : timeLabel)
                        .font(BrandFont.body(14, .bold))
                    Spacer()
                    // tap to skip
                    Text(remaining == 0 ? "TAP TO CLOSE" : "SKIP")
                        .font(BrandFont.body(11, .bold)).tracking(0.5)
                }
                .foregroundColor(Brand.text)
                .blendMode(.difference)   // stays legible over volt + black
                .padding(.horizontal, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.voltLine, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { stop() }      // tap anywhere on the bar to skip/close
        }
        .frame(height: 48)
    }

    private func start() {
        let end = Date().addingTimeInterval(TimeInterval(restSeconds))
        endTime = end
        remaining = restSeconds
        running = true
        RestTimerEngine.shared.requestPermissionIfNeeded()
        RestTimerEngine.shared.scheduleBackgroundBell(after: restSeconds)  // background bell
        WatchBridge.shared.startRest(seconds: restSeconds)                 // buzz the wrist too
    }

    private func stop() {
        running = false
        endTime = nil
        RestTimerEngine.shared.cancel()
    }

    private func updateRemaining() {
        guard running, let end = endTime else { return }
        let secs = Int(ceil(end.timeIntervalSinceNow))
        if secs <= 0 {
            if remaining != 0 {
                remaining = 0
                // If we're in the foreground when it hits zero, play the ducking bell
                // (this also cancels the scheduled notification to avoid a double ring).
                if scenePhase == .active {
                    RestTimerEngine.shared.fireForegroundBell()
                }
            }
        } else {
            remaining = secs
        }
    }
}
