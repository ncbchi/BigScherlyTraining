import Foundation

extension Notification.Name {
    // Posted when an API call returns 401 (expired/invalid token) so the app logs out.
    static let bstUnauthorized = Notification.Name("bstUnauthorized")
}

// MARK: - API configuration
// Flip USE_MOCK to false once the backend is live and reachable.
enum APIConfig {
    static let useMock = false
    static let baseURL = "https://api.bigscherlytraining.com"   // your VPS API
}

// MARK: - API client
// Thin wrapper around the .NET API. When useMock is true, AppStore keeps using
// MockData and none of this runs — so the app works offline during development.
final class APIClient {
    static let shared = APIClient()
    private var token: String?

    private var base: URL { URL(string: APIConfig.baseURL)! }

    // Token is stored in the Keychain (see TokenStore.swift), not UserDefaults —
    // Keychain items with ThisDeviceOnly accessibility are excluded from backups.
    func setToken(_ t: String) {
        token = t
        TokenStore.save(t)
    }
    func loadToken() { token = TokenStore.load() }

    // Called on logout — forget the saved login so the app returns to the login screen.
    func clearToken() {
        token = nil
        TokenStore.clear()
    }

    struct APIError: Error { let message: String }

    // MARK: Auth
    func login(email: String, password: String) async throws -> LoginResponse {
        try await post("/auth/login", body: ["email": email, "password": password])
    }

    // Client sets their own password (first-login forced change)
    func changePassword(current: String, new: String) async throws {
        _ = try await request("/change-password", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["currentPassword": current, "newPassword": new]))
    }

    // Permanently deletes the caller's account and all their data (server: DELETE /account).
    func deleteAccount() async throws {
        _ = try await request("/account", method: "DELETE")
    }

    // MARK: Data fetches (client-scoped by the JWT)
    func profile() async throws -> APIProfile { try await get("/me") }
    func workouts() async throws -> [APIWorkoutSummary] { try await get("/workouts") }
    func workout(_ id: String) async throws -> APIWorkout { try await get("/workouts/\(id)") }
    func macros() async throws -> [APIMacroDay] { try await get("/macros") }
    func checkins() async throws -> [APICheckIn] { try await get("/checkins") }

    // Submit a completed check-in. Best-effort — encodes fields as label/value pairs.
    func submitCheckIn(_ checkIn: CheckIn) async throws {
        let body: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: checkIn.date),
            "fields": checkIn.fields.map { ["id": $0.id, "label": $0.label, "value": $0.value] },
            "photoIDs": checkIn.photoIDs
        ]
        try await postVoid("/checkins", body: body)
    }
    func photos() async throws -> [APIPhoto] { try await get("/photos") }

    // Uploads a progress / check-in photo as multipart form data. Image should be
    // pre-compressed to JPEG <=3MB. Optional checkInId links it to a check-in.
    // Returns the server-created photo record.
    @discardableResult
    func uploadPhoto(imageData: Data, category: String, checkInId: String? = nil) async throws -> APIPhoto {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("/photos"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ s: String) { body.append(s.data(using: .utf8)!) }
        // file part
        field("--\(boundary)\r\n")
        field("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n")
        field("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        field("\r\n")
        // category part
        field("--\(boundary)\r\n")
        field("Content-Disposition: form-data; name=\"category\"\r\n\r\n")
        field("\(category)\r\n")
        // optional checkInId part
        if let checkInId {
            field("--\(boundary)\r\n")
            field("Content-Disposition: form-data; name=\"checkInId\"\r\n\r\n")
            field("\(checkInId)\r\n")
        }
        field("--\(boundary)--\r\n")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Photo upload failed")
        }
        return try decoder.decode(APIPhoto.self, from: data)
    }
    func chats() async throws -> [APIChatThread] { try await get("/chats") }
    func messages(_ threadId: String) async throws -> [APIChatMessage] { try await get("/chats/\(threadId)/messages") }
    func announcements() async throws -> [APIAnnouncement] { try await get("/announcements") }
    func shareStats() async throws -> APIShareStats { try await get("/stats/summary") }
    func supplements() async throws -> [APISupplement] { try await get("/supplements") }
    func supplementStacks() async throws -> [APISupplementStack] { try await get("/supplements/stacks") }
    func supplementLogs() async throws -> [APISupplementLog] { try await get("/supplements/logs") }

    // MARK: Client actions
    func logSet(workoutId: String, exerciseId: String, setId: String,
                reps: Int?, weight: Double?, rpe: Double?, loggedAt: Date? = nil) async throws {
        var body: [String: Any] = [:]
        if let reps { body["loggedReps"] = reps }
        if let weight { body["loggedWeight"] = weight }
        if let rpe { body["rpe"] = rpe }
        if let loggedAt { body["loggedAt"] = ISO8601DateFormatter().string(from: loggedAt) }
        try await patch("/workouts/\(workoutId)/exercises/\(exerciseId)/sets/\(setId)", body: body)
    }

    // Upload HealthKit-derived vitals for a completed workout (coach visibility).
    func uploadWorkoutVitals(workoutId: String, vitals: WorkoutVitals) async throws {
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [
            "start": iso.string(from: vitals.start),
            "end": iso.string(from: vitals.end),
            "durationMinutes": vitals.durationMinutes
        ]
        if let a = vitals.avgHeartRate { body["avgHeartRate"] = a }
        if let p = vitals.peakHeartRate { body["peakHeartRate"] = p }
        if let c = vitals.activeCalories { body["activeCalories"] = c }
        // Full HR series so the coach + client can slice it per-exercise / per-set.
        body["heartRateSeries"] = vitals.heartRateSeries.map {
            ["t": iso.string(from: $0.time), "b": $0.bpm]
        }
        try await patch("/workouts/\(workoutId)/health", body: body)
    }

    // Fetch a workout's stored health data (vitals + HR series) for slicing.
    func workoutHealth(workoutId: String) async throws -> WorkoutVitals? {
        let dto: WorkoutHealthResponse = try await get("/workouts/\(workoutId)/health")
        return dto.toVitals()
    }
    func sendMessage(threadId: String, text: String) async throws {
        _ = try await request("/chats/\(threadId)/messages", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["text": text]))
    }
    func clearAnnouncement(_ id: String) async throws {
        _ = try await request("/announcements/\(id)/clear", method: "POST")
    }
    // Records that the client took a dose (feeds the trainer's adherence view).
    func confirmSupplement(id: String, takenAt: Date) async throws {
        let iso = ISO8601DateFormatter().string(from: takenAt)
        _ = try await request("/supplements/\(id)/confirm", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["takenAt": iso]))
    }

    // MARK: Chat video
    // Uploads the already-compressed (540p, ≤120s) clip as multipart form data.
    // Returns the server key; the server is responsible for encrypting at rest
    // and deleting the file 90 days after upload.
    func uploadChatVideo(threadId: String, fileURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("/chats/\(threadId)/video"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        func field(_ s: String) { body.append(s.data(using: .utf8)!) }
        field("--\(boundary)\r\n")
        field("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        field("Content-Type: video/mp4\r\n\r\n")
        body.append(fileData)
        field("\r\n--\(boundary)--\r\n")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Video upload failed")
        }
        return try decoder.decode(VideoUploadResponse.self, from: data).videoKey
    }

    // Asks the server for a short-lived signed URL to stream a stored clip.
    // Signed (not the JWT) so AVPlayer can fetch it without a token in the URL.
    // Returns nil-throwing if the video has passed its 90-day expiry.
    func chatVideoURL(threadId: String, key: String) async throws -> URL {
        let data = try await request("/chats/\(threadId)/video/\(key)/url", method: "GET")
        let signed = try decoder.decode(SignedURLResponse.self, from: data)
        guard let url = URL(string: signed.url) else { throw APIError(message: "Bad video URL") }
        return url
    }
    // Full URL for a photo image (JWT sent via header by AsyncImage loader helper)
    func photoURL(_ id: String) -> URL { base.appendingPathComponent("photos/\(id)") }
    var authToken: String? { token }

    // MARK: Generic helpers
    /// Builds the full URL. A query ("?days=30") is attached as a query — appendingPathComponent
    /// alone would escape the "?" and the server would never see it.
    private func url(_ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let u = base.appendingPathComponent(String(parts[0]))
        guard parts.count == 2, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.percentEncodedQuery = String(parts[1])
        return c.url ?? u
    }

    /// HTTP status of the last failed request (404 vs 500 vs offline) — sync uses it to
    /// decide whether to retry or drop an item.
    struct HTTPStatusError: Error { let status: Int }

    func request(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            // Saved token is expired or invalid — force a clean logout on the main thread.
            clearToken()
            await MainActor.run { NotificationCenter.default.post(name: .bstUnauthorized, object: nil) }
            throw APIError(message: "Session expired")
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Request failed") }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode)
        }
        return data
    }

    /// Push the client's earned awards up so the trainer can see them.
    /// Idempotent server-side (keyed on client + kind), so re-syncing is safe.
    func syncAwards(_ awards: [Award]) async throws {
        let payload: [[String: Any]] = awards.map { a in
            [
                "kind": a.kind.rawValue,
                "title": a.title,
                "blurb": a.blurb,
                "icon": a.icon,
                "earnedAt": ISO8601DateFormatter().string(from: a.earnedAt),
                "stats": a.stats.map { s in
                    ["value": s.value, "label": s.label, "isPrivate": s.isPrivate]
                }
            ]
        }
        _ = try await request("/awards/sync", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["awards": payload]))
    }

    // MARK: Trainer
    func roster() async throws -> [RosterItem] { try await get("/admin/roster") }
    func recentAwards(days: Int = 30) async throws -> [RosterAward] {
        try await get("/admin/recent-awards?days=\(days)")
    }
    func trainerCheckIns(clientId: String) async throws -> [APICheckIn] {
        try await get("/admin/clients/\(clientId)/checkins")
    }
    func trainerRespondCheckIn(checkInId: String, response: String) async throws {
        try await patch("/admin/checkins/\(checkInId)", body: ["response": response])
    }
    func trainerChats(clientId: String) async throws -> [APIChatThread] {
        try await get("/admin/clients/\(clientId)/chats")
    }
    func trainerCreateChat(clientId: String, topic: String, category: String) async throws -> APIChatThread {
        try await post("/admin/clients/\(clientId)/chats", body: ["topic": topic, "category": category])
    }
    func trainerMessages(threadId: String) async throws -> [APIChatMessage] {
        try await get("/admin/chats/\(threadId)/messages")
    }
    func trainerSendMessage(threadId: String, text: String) async throws {
        _ = try await request("/admin/chats/\(threadId)/messages", method: "POST",
                              body: try JSONSerialization.data(withJSONObject: ["text": text]))
    }
    func trainerWorkouts(clientId: String) async throws -> [APIWorkout] {
        try await get("/admin/clients/\(clientId)/workouts")
    }
    func trainerAwards(clientId: String) async throws -> [APIAward] {
        try await get("/admin/clients/\(clientId)/awards")
    }
    // New trainer features
    func checkInQueue() async throws -> [QueuedCheckIn] { try await get("/admin/checkin-queue") }
    func clientNote(clientId: String) async throws -> ClientNote {
        try await get("/admin/clients/\(clientId)/note")
    }
    func saveClientNote(clientId: String, body: String) async throws {
        _ = try await request("/admin/clients/\(clientId)/note", method: "PUT",
                              body: try JSONSerialization.data(withJSONObject: ["body": body]))
    }
    // Announcements — one post to all clients (replaces the old per-client broadcast).
    func createAnnouncement(title: String, body: String) async throws {
        _ = try await request("/admin/announcements", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["title": title, "body": body]))
    }
    func adminAnnouncements() async throws -> [APIAnnouncement] {
        try await get("/admin/announcements")
    }
    func deleteAnnouncement(id: String) async throws {
        _ = try await request("/admin/announcements/\(id)", method: "DELETE")
    }
    func trainerPhotos(clientId: String) async throws -> [APIPhoto] {
        try await get("/admin/clients/\(clientId)/photos")
    }
    func trainerPhotoURL(photoId: String) -> URL {
        URL(string: "\(APIConfig.baseURL)/admin/photos/\(photoId)/file")!
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request(path, method: "GET")
        return try decoder.decode(T.self, from: data)
    }
    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try await request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        return try decoder.decode(T.self, from: data)
    }
    func patch(_ path: String, body: [String: Any]) async throws {
        _ = try await request(path, method: "PATCH", body: try JSONSerialization.data(withJSONObject: body))
    }
    func postVoid(_ path: String, body: [String: Any]) async throws {
        _ = try await request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    var decoder: JSONDecoder {
        let d = JSONDecoder()
        // ASP.NET Core (System.Text.Json) outputs camelCase by default, which matches
        // our Swift property names — so use default keys (no conversion).
        d.keyDecodingStrategy = .useDefaultKeys
        // .NET emits ISO8601, but two variants the stock parser rejects: 7-digit
        // fractional seconds ("...T11:20:51.4527974") and — after an EF/SQLite
        // round-trip — no timezone suffix at all. Normalize both: trim the fraction
        // to milliseconds and assume UTC when no offset is present.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let normalized = APIClient.normalizeAPIDate(str)
            if let date = ISO8601DateFormatter.bstWithFractional.date(from: normalized)
                ?? ISO8601DateFormatter.bstPlain.date(from: normalized) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unrecognized date: \(str)")
        }
        return d
    }

    // Rewrites a .NET date string into strict ISO8601 the Apple parser accepts.
    static func normalizeAPIDate(_ raw: String) -> String {
        var s = raw
        var tz = ""
        if s.hasSuffix("Z") {
            tz = "Z"; s.removeLast()
        } else if let t = s.firstIndex(of: "T") {
            // An offset sign after the "T" (e.g. "+05:00" / "-04:00") is a timezone.
            let afterT = s.index(after: t)
            if let sign = s[afterT...].firstIndex(where: { $0 == "+" || $0 == "-" }) {
                tz = String(s[sign...])
                s = String(s[..<sign])
            }
        }
        // Trim/pad fractional seconds to exactly 3 digits (Apple accepts only ms).
        if let dot = s.firstIndex(of: ".") {
            let frac = String(s[s.index(after: dot)...])
            let ms = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s = String(s[..<dot]) + "." + ms
        }
        return s + (tz.isEmpty ? "Z" : tz)   // server dates are UTC when unmarked
    }
}

// Chat video endpoint responses
struct VideoUploadResponse: Decodable { let videoKey: String }
struct SignedURLResponse: Decodable { let url: String }

// LoginResponse decodes from the API's /auth/login result
struct LoginResponse: Decodable {
    let token: String
    let role: String
    let name: String
    let id: String
    var mustChangePassword: Bool = false
}

// .NET's System.Text.Json defaults to camelCase output, so standard decoding works.
// This custom strategy is a safety net if PascalCase is ever returned.
extension JSONDecoder.KeyDecodingStrategy {
    static var convertFromPascalCase: JSONDecoder.KeyDecodingStrategy {
        .custom { keys in
            let last = keys.last!
            let s = last.stringValue
            let lowered = s.prefix(1).lowercased() + s.dropFirst()
            return AnyKey(stringValue: lowered)
        }
    }
}
struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}

// Formatters that accept .NET's ISO8601 output (with or without fractional seconds).
extension ISO8601DateFormatter {
    static let bstWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let bstPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
