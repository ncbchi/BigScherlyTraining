import Foundation

// MARK: - API configuration
// Flip USE_MOCK to false once the backend is live and reachable.
enum APIConfig {
    static let useMock = true
    static let baseURL = "https://api.bigscherlytraining.com"   // your VPS API
}

// MARK: - API client
// Thin wrapper around the .NET API. When useMock is true, AppStore keeps using
// MockData and none of this runs — so the app works offline during development.
final class APIClient {
    static let shared = APIClient()
    private var token: String?

    private var base: URL { URL(string: APIConfig.baseURL)! }

    // Stored token in the Keychain in production; UserDefaults shown here for brevity.
    func setToken(_ t: String) {
        token = t
        UserDefaults.standard.set(t, forKey: "bst_token")
    }
    func loadToken() { token = UserDefaults.standard.string(forKey: "bst_token") }

    struct APIError: Error { let message: String }

    // MARK: Auth
    func login(email: String, password: String) async throws -> LoginResponse {
        try await post("/auth/login", body: ["email": email, "password": password])
    }

    // MARK: Generic helpers
    private func request(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Request failed")
        }
        return data
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

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromPascalCase   // .NET returns PascalCase by default; see note
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// LoginResponse decodes from the API's /auth/login result
struct LoginResponse: Decodable {
    let token: String
    let role: String
    let name: String
    let id: String
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
