import SwiftUI
import UIKit

// MARK: - Motion captures (DEBUG TOOL — removed before release)
// Settings ▸ Apple Watch setup ▸ Motion captures. Each capture is the Watch's raw motion from Go to
// hand-over, with its own count and the phone's verdict. Copy puts compact text on the clipboard —
// paste it into the chat.
//
// Target membership: BigScherlyTraining.

struct MotionCapturesView: View {
    @ObservedObject private var store = MotionCaptureStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copiedId: UUID?
    @State private var confirmClear = false
    @State private var shareURL: URL?
    @AppStorage(MotionCaptureStore.trackKey) private var tracking = true
    @AppStorage(MotionCaptureStore.heightKey) private var heightCm = 178.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("DEBUG").font(BrandFont.body(10, .heavy)).tracking(1.2).foregroundColor(Brand.onVolt)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Brand.volt))
                        Text("Developer tool — removed before release").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    }
                    DebugRecordPanel()
                    if !store.captures.isEmpty {
                        Button {
                            shareURL = PhoneDebugRecorder.exportFile()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .bold))
                                Text("Share all \(store.captures.count) captures").font(BrandFont.body(15, .heavy))
                            }
                            .foregroundColor(Brand.onVolt)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.volt))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        Text("One text file with everything below — AirDrop it to your Mac, or attach it in the chat.")
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }
                    VStack(spacing: 0) {
                        Toggle(isOn: $tracking) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Track with the camera").font(BrandFont.body(15)).foregroundColor(Brand.text)
                                Text("During recordings and setup's rep steps, the camera follows your wrist (hips on squats) beside the Watch. Prop the phone side-on, about 2.5 m back, and stand in view before you start.")
                                    .font(BrandFont.body(11)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Brand.volt).padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().overlay(Brand.line).padding(.leading, 16)
                        Stepper(value: $heightCm, in: 140...215, step: 1) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your height — \(Int(heightCm)) cm").font(BrandFont.body(15)).foregroundColor(Brand.text)
                                Text("The camera's ruler: it turns pixels into centimetres.").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .background(Brand.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
                    if store.captures.isEmpty {
                        Text("Nothing yet. Run any Watch setup step (Settings ▸ Apple Watch setup ▸ Recalibrate) and its raw motion shows up here.")
                            .font(BrandFont.body(14)).foregroundColor(Brand.mute).padding(.top, 8)
                    }
                    ForEach(store.captures) { c in card(c) }
                    if !store.captures.isEmpty {
                        Button { confirmClear = true } label: {
                            Text("Delete all").font(BrandFont.body(15)).foregroundColor(Brand.voltText)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Motion captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL { CaptureShareSheet(url: url) }
            }
            .confirmationDialog("Delete every capture?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            }
        }
    }

    private func card(_ c: MotionCapture) -> some View {
        var counted = c.kind == "still" ? "Still check" : "Watch \(c.reps.count)"
        if c.kind == "debug" { counted = "Recording · " + counted }
        if let cc = c.cameraCount { counted += " · Camera \(cc)" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(c.title) · \(c.lift)").font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                Spacer()
                Text(c.date.formatted(.dateTime.hour().minute())).font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            Text(counted).font(BrandFont.body(13, .bold)).foregroundColor(Brand.text)
            if let v = c.verdict {
                let ok = v.hasPrefix("accepted")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(ok ? Brand.voltText : Brand.text)
                    Text("Phone: \(v)").font(BrandFont.body(12, .semibold)).foregroundColor(ok ? Brand.voltText : Brand.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if c.kind != "still", let cc = c.cameraCount {
                let diff = c.reps.count - cc
                HStack(spacing: 6) {
                    Image(systemName: diff == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(diff == 0 ? Brand.voltText : Brand.text)
                    Text(diff == 0 ? "Watch and camera agree" : String(format: "Watch is %+d rep%@ against the camera", diff, abs(diff) == 1 ? "" : "s"))
                        .font(BrandFont.body(12, .semibold)).foregroundColor(diff == 0 ? Brand.voltText : Brand.text)
                }
            }
            if let d = c.diag { Text(d).font(BrandFont.body(11)).foregroundColor(Brand.mute) }
            HStack {
                Text(String(format: "%.0f s · %d samples · build %@", c.seconds, c.rawCount, c.build))
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                Spacer()
                if c.camera != nil {
                    NavigationLink { CameraCompareView(capture: c) } label: {
                        Text("Compare").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.voltText)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(Capsule().stroke(Brand.voltLine, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    UIPasteboard.general.string = c.compactText()
                    copiedId = c.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if copiedId == c.id { copiedId = nil } }
                } label: {
                    Text(copiedId == c.id ? "Copied ✓" : "Copy").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Brand.volt))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
        .contextMenu { Button("Delete", role: .destructive) { store.delete(c.id) } }
    }
}
