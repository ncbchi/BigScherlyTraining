import SwiftUI
import Combine
import AVFoundation
import Speech

// MARK: - Inbox extras (Oct 8, 2026): voice notes, video replies, set comments
//
// Voice notes are recorded as AAC (.m4a) at 24 kbps mono, 22 kHz — about 180 KB a minute,
// capped at 2 minutes. The transcript is made on this phone (Apple's on-device speech
// recognition when the phone supports it) before anything is sent, and you can fix it.
// The server keeps the audio 14 days; after that the message is just the transcript.
// Synchronized folder: no target step needed.
// Needs two Info.plist keys (check.sh lists them): Privacy - Microphone Usage Description
// and Privacy - Speech Recognition Usage Description.

// MARK: API

struct APISetRef: Codable, Hashable {
    let workoutId: String
    let setId: String
    let workoutTitle: String
    let workoutDate: Date
    let exerciseName: String
    let setNumber: Int
    let summary: String
}

struct APISetCommentResult: Decodable {
    let threadId: String
}

extension APIClient {
    /// Multipart POST with one file plus text fields. Uses the same token routing as everything else.
    func multipart(_ path: String, fileURL: URL, fileName: String, mime: String, fields: [String: String]) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: APIConfig.baseURL)!.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let t = token(for: path) { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        add("\r\n--\(boundary)--\r\n")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct E: Decodable { let error: String }
            throw APIError(message: (try? JSONDecoder().decode(E.self, from: data).error) ?? "Upload failed")
        }
        return data
    }

    /// Client → coach, or coach → client when `asCoach`.
    func sendVoiceNote(threadId: String, fileURL: URL, seconds: Double, transcript: String, asCoach: Bool) async throws {
        _ = try await multipart(asCoach ? "/admin/chats/\(threadId)/voice" : "/chats/\(threadId)/voice",
                                fileURL: fileURL, fileName: "voice.m4a", mime: "audio/mp4",
                                fields: ["seconds": String(format: "%.1f", seconds), "transcript": transcript])
    }
    func voiceNoteAudio(threadId: String, messageId: String, asCoach: Bool) async throws -> Data {
        try await request(asCoach ? "/admin/chats/\(threadId)/voice/\(messageId)" : "/chats/\(threadId)/voice/\(messageId)", method: "GET")
    }
    func coachSendVideo(threadId: String, fileURL: URL, caption: String) async throws {
        _ = try await multipart("/admin/chats/\(threadId)/video", fileURL: fileURL, fileName: "reply.mp4", mime: "video/mp4",
                                fields: ["text": caption])
    }
    /// Downloads a chat video (with the token) to a temp file AVPlayer can open.
    func chatVideoFile(threadId: String, key: String, asCoach: Bool) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("chat_\(key).mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let data = try await request(asCoach ? "/admin/chats/\(threadId)/video/\(key)" : "/chats/\(threadId)/video/\(key)/stream", method: "GET")
        try data.write(to: out, options: .atomic)
        return out
    }
    @discardableResult
    func commentOnSet(setId: String, text: String) async throws -> APISetCommentResult {
        try decoder.decode(APISetCommentResult.self, from: try await request("/admin/sets/\(setId)/comment", method: "POST",
                                                                               body: try JSONSerialization.data(withJSONObject: ["text": text])))
    }
}

// MARK: - Recorder

@MainActor
final class VoiceNoteRecorder: ObservableObject {
    static let maxSeconds: Double = 120
    @Published var recording = false
    @Published var elapsed: Double = 0
    @Published var level: Float = 0
    @Published var fileURL: URL?
    @Published var transcript = ""
    @Published var transcribing = false
    @Published var problem: String?
    private var recorder: AVAudioRecorder?

    func start() async {
        problem = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone is off for Big Scherly. Turn it on in Settings ▸ Big Scherly."
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { problem = "Couldn't start the microphone."; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxSeconds) else { problem = "Couldn't start recording."; return }
            recorder = r
            fileURL = nil; transcript = ""; elapsed = 0; recording = true
        } catch { problem = "Couldn't start recording." }
    }

    /// Called by the view's timer: elapsed time, level, and the 2-minute auto-stop.
    func tick() {
        guard recording, let r = recorder else { return }
        if r.isRecording {
            r.updateMeters()
            elapsed = r.currentTime
            level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
        } else {
            Task { await stop() }    // hit the cap
        }
    }

    func stop() async {
        guard recording, let r = recorder else { return }
        let secs = max(elapsed, r.currentTime)
        r.stop()
        recording = false
        elapsed = min(secs, Self.maxSeconds)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        fileURL = r.url
        recorder = nil
        await transcribe(r.url)
    }

    func discard() {
        recorder?.stop(); recorder = nil
        if recording { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        recording = false
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        fileURL = nil; transcript = ""; elapsed = 0
    }

    private func transcribe(_ url: URL) async {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.isAvailable else {
            problem = "No transcript (speech recognition is off). Type one below so it stays after 14 days."
            return
        }
        transcribing = true
        let text = await VoiceTranscriber.run(url: url, recognizer: rec)
        transcribing = false
        if let text, !text.isEmpty { transcript = text }
        else if transcript.isEmpty { problem = "Couldn't make out any words. Type a transcript below if you like." }
    }
}

/// One-shot file transcription. On-device when the phone supports it (nothing leaves the phone).
nonisolated enum VoiceTranscriber {
    nonisolated final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func run(url: URL, recognizer: SFSpeechRecognizer) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.shouldReportPartialResults = false
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            let once = Once()
            let task = recognizer.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    if once.claim() { c.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    if once.claim() { c.resume(returning: nil) }
                }
            }
            // Safety net: never hang the sheet.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if once.claim() { task.cancel(); c.resume(returning: nil) }
            }
        }
    }
}

private func clockText(_ s: Double) -> String {
    let t = Int(s.rounded())
    return "\(t / 60):" + String(format: "%02d", t % 60)
}

// MARK: Record sheet

struct VoiceNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title = "Voice note"
    /// (file, seconds, transcript) — throw to show an error and keep the sheet open.
    let send: (URL, Double, String) async throws -> Void
    @StateObject private var rec = VoiceNoteRecorder()
    @State private var sending = false
    @State private var error: String?
    @State private var preview: AVAudioPlayer?
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(clockText(rec.elapsed)).font(BrandFont.display(56)).foregroundColor(Brand.text)
                        .monospacedDigit()
                    Text("Up to 2 minutes. The audio is kept 14 days, then just the transcript.")
                        .font(BrandFont.body(12)).foregroundColor(Brand.mute).multilineTextAlignment(.center)
                    meter

                    Button {
                        Task { if rec.recording { await rec.stop() } else { preview?.stop(); await rec.start() } }
                    } label: {
                        ZStack {
                            Circle().fill(Brand.danger).frame(width: 84, height: 84)
                            if rec.recording { RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: 28, height: 28) }
                            else { Image(systemName: "mic.fill").font(.system(size: 30, weight: .bold)).foregroundColor(.white) }
                        }
                    }
                    .accessibilityLabel(rec.recording ? "Stop recording" : (rec.fileURL == nil ? "Start recording" : "Record again"))
                    .disabled(sending || rec.transcribing)

                    if let url = rec.fileURL, !rec.recording {
                        Button {
                            if preview?.isPlaying == true { preview?.stop() }
                            else {
                                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                                try? AVAudioSession.sharedInstance().setActive(true)
                                preview = try? AVAudioPlayer(contentsOf: url); preview?.play()
                            }
                        } label: { Label("Listen back", systemImage: "play.circle.fill") }
                            .font(BrandFont.body(14, .bold)).foregroundColor(Brand.voltText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("TRANSCRIPT").font(BrandFont.body(11, .bold)).tracking(1.5).headerPill()
                            Spacer()
                            if rec.transcribing {
                                ProgressView().tint(Brand.volt)
                                Text("Transcribing…").font(BrandFont.body(11)).foregroundColor(Brand.mute)
                            }
                        }
                        TextEditor(text: $rec.transcript)
                            .font(BrandFont.body(15)).foregroundColor(Brand.text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                        Text("Made on this phone. Fix anything it misheard — this is what stays after 14 days.")
                            .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    }

                    if let p = rec.problem ?? error {
                        Text(p).font(BrandFont.body(12)).foregroundColor(.orange).multilineTextAlignment(.center)
                    }

                    Button { Task { await doSend() } } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(Brand.onVolt) }
                            Label("Send voice note", systemImage: "arrow.up")
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(rec.fileURL == nil || rec.recording || rec.transcribing || sending)
                    .opacity(rec.fileURL == nil ? 0.5 : 1)
                }
                .padding(20)
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preview?.stop(); rec.discard(); dismiss() }.foregroundColor(Brand.mute)
                }
            }
            .onReceive(timer) { _ in rec.tick() }
            .interactiveDismissDisabled(rec.recording || sending)
            .keyboardDoneButton()
        }
    }

    /// Live level while recording; afterwards, how much of the 2 minutes was used.
    private var meterFraction: CGFloat {
        if rec.recording { return CGFloat(rec.level) }
        let used: Double = rec.elapsed / VoiceNoteRecorder.maxSeconds
        return CGFloat(min(1.0, used))
    }

    private var meterColor: Color { rec.recording ? Brand.volt : Brand.mute.opacity(0.4) }

    private var meter: some View {
        let fraction: CGFloat = meterFraction
        let color: Color = meterColor
        return Capsule().fill(Brand.text.opacity(0.08)).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(color).frame(width: g.size.width * fraction)
                }
            }
            .padding(.horizontal, 30)
    }

    private func doSend() async {
        guard let url = rec.fileURL else { return }
        preview?.stop()
        sending = true; error = nil
        do {
            try await send(url, rec.elapsed, rec.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(at: url)
            sending = false
            dismiss()
        } catch {
            sending = false
            self.error = (error as? APIClient.APIError)?.message ?? "Couldn't send. Check your connection and try again."
        }
    }
}

// MARK: - Playback (one voice note at a time)

@MainActor
final class VoicePlayback: ObservableObject {
    static let shared = VoicePlayback()
    @Published var playingId: String?
    @Published var progress: Double = 0
    @Published var loadingId: String?
    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]

    func toggle(id: String, load: @escaping () async throws -> Data) async {
        if playingId == id { stop(); return }
        stop()
        loadingId = id
        do {
            let data: Data
            if let d = cache[id] { data = d } else { data = try await load(); cache[id] = data }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.play()
            player = p; playingId = id; progress = 0
        } catch {
            playingId = nil
        }
        loadingId = nil
    }

    func tick() {
        guard let p = player, playingId != nil else { return }
        if p.isPlaying { progress = p.duration > 0 ? p.currentTime / p.duration : 0 }
        else { stop() }
    }

    func stop() {
        player?.stop(); player = nil
        if playingId != nil { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        playingId = nil; progress = 0
    }
}

/// A voice note in a chat: play button while the audio exists, then just the transcript.
struct VoiceNoteBubble: View {
    let id: String
    let fromMe: Bool
    let seconds: Double
    let available: Bool
    let expiresAt: Date?
    let transcript: String?
    let load: () async throws -> Data
    @ObservedObject private var playback = VoicePlayback.shared
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var playedFraction: CGFloat {
        guard playback.playingId == id else { return 0 }
        return CGFloat(playback.progress)
    }

    var body: some View {
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 10) {
                if available {
                    Button { Task { await playback.toggle(id: id, load: load) } } label: {
                        ZStack {
                            Circle().fill(Brand.volt).frame(width: 38, height: 38)
                            if playback.loadingId == id { ProgressView().tint(Brand.onVolt) }
                            else {
                                Image(systemName: playback.playingId == id ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .bold)).foregroundColor(Brand.onVolt)
                            }
                        }
                    }
                    .accessibilityLabel(playback.playingId == id ? "Pause voice note" : "Play voice note")
                } else {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundColor(Brand.mute)
                        .frame(width: 38, height: 38).background(Circle().fill(Brand.text.opacity(0.06)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice note · \(clockText(seconds))").font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                    if available {
                        Capsule().fill(Brand.text.opacity(0.1)).frame(width: 130, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Brand.volt).frame(width: 130 * playedFraction, height: 4)
                            }
                        if let e = expiresAt {
                            Text("Audio until \(e.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(BrandFont.body(10)).foregroundColor(Brand.mute)
                        }
                    } else {
                        Text("Audio removed after 14 days").font(BrandFont.body(10)).foregroundColor(Brand.mute)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18).fill(Brand.black))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(fromMe ? Brand.voltLine.opacity(0.6) : Brand.line, lineWidth: 1))
            if let t = transcript, !t.isEmpty {
                Text(t).font(BrandFont.body(14)).foregroundColor(Brand.text)
                    .multilineTextAlignment(fromMe ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                Text("No transcript").font(BrandFont.body(12).italic()).foregroundColor(Brand.mute).padding(.horizontal, 4)
            }
        }
        .onReceive(timer) { _ in if playback.playingId == id { playback.tick() } }
        .onDisappear { if playback.playingId == id { playback.stop() } }
    }
}

/// The quoted set on a coach's set comment.
struct SetRefQuote: View {
    let ref: APISetRef
    var onVolt = false
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(onVolt ? Brand.onVolt : Brand.volt).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ref.exerciseName) · Set \(ref.setNumber) — \(ref.summary)")
                    .font(BrandFont.body(12, .heavy)).foregroundColor(onVolt ? Brand.onVolt : Brand.text)
                Text("\(ref.workoutTitle) · \(ref.workoutDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(BrandFont.body(11)).foregroundColor(onVolt ? Brand.onVolt.opacity(0.7) : Brand.mute)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The comment text without the "↳ Bench · Set 3 — …" first line older apps read.
func setCommentBody(_ text: String) -> String {
    guard text.hasPrefix("↳"), let nl = text.firstIndex(of: "\n") else { return text }
    return String(text[text.index(after: nl)...])
}

// MARK: - Comment on a set (coach, from a client's workout)

struct SetCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let setId: String
    let label: String
    let clientName: String
    @State private var text = ""
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Rectangle().fill(Brand.volt).frame(width: 3)
                    Text(label).font(BrandFont.body(13, .heavy)).foregroundColor(Brand.text)
                }
                .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(BrandFont.body(15)).foregroundColor(Brand.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.black))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line, lineWidth: 1))
                Text("Lands in \(clientName.isEmpty ? "their" : clientName + "'s") chat, in a thread for this workout, with the set quoted.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
                if failed { Text("Couldn't send. Try again.").font(BrandFont.body(12)).foregroundColor(.orange) }
                Button {
                    sending = true; failed = false
                    Task {
                        do { try await APIClient.shared.commentOnSet(setId: setId, text: text); sending = false; dismiss() }
                        catch { sending = false; failed = true }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(Brand.onVolt) }
                        Label("Send", systemImage: "arrow.up")
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Comment on set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(Brand.mute) } }
            }
            .sheetFitsScrollContent()            // the card is only as tall as what's in it
            .background(Brand.bg.ignoresSafeArea())
        }
    }
}
