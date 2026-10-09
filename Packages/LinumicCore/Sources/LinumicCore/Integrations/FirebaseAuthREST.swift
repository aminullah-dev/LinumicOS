import Foundation

// Firebase Authentication over plain REST (no Firebase SDK): email/password sign-in through the Identity
// Toolkit and ID-token refresh through the Secure Token service. Used for the WorkTrack vendor console.
// The password is sent once, to Google, and never kept. Only the refresh token is stored (Keychain).

/// Where the two Firebase Auth REST services live, and the project's public Web API key.
/// The Web API key identifies the project; it is not a secret. Access is granted by the ID token.
public struct FirebaseAuthEndpoints: Sendable, Equatable {
    public var identityToolkit: URL
    public var secureToken: URL
    public var apiKey: String

    public init(identityToolkit: URL, secureToken: URL, apiKey: String) {
        self.identityToolkit = identityToolkit
        self.secureToken = secureToken
        self.apiKey = apiKey
    }

    public static func google(apiKey: String) -> FirebaseAuthEndpoints {
        FirebaseAuthEndpoints(identityToolkit: URL(string: "https://identitytoolkit.googleapis.com/v1")!,
                              secureToken: URL(string: "https://securetoken.googleapis.com/v1")!, apiKey: apiKey)
    }

    /// The Firebase Auth emulator serves both APIs under its own host: `http://host:port/<service host>/v1`.
    public static func emulator(host: String, port: Int, apiKey: String) -> FirebaseAuthEndpoints {
        FirebaseAuthEndpoints(identityToolkit: URL(string: "http://\(host):\(port)/identitytoolkit.googleapis.com/v1")!,
                              secureToken: URL(string: "http://\(host):\(port)/securetoken.googleapis.com/v1")!, apiKey: apiKey)
    }
}

/// A Firebase ID token (one hour) with the refresh token that renews it.
public struct FirebaseTokens: Sendable, Equatable {
    public var idToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: String
    public var email: String?
}

public enum FirebaseAuthError: Error, LocalizedError, Equatable {
    /// Wrong email or password (Firebase no longer says which, on purpose).
    case invalidCredentials
    case userDisabled
    case tooManyAttempts
    case invalidEmail
    case missingPassword
    /// The refresh token was revoked (password changed, account disabled) or has expired.
    case sessionExpired
    /// The Web API key was refused (restricted key, wrong project).
    case apiKeyRejected(String)
    case server(status: Int, code: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: L("The email or password is wrong.")
        case .userDisabled: L("This account has been disabled in Firebase.")
        case .tooManyAttempts: L("Too many sign-in attempts. Firebase has blocked this account for a while; try again later or reset the password.")
        case .invalidEmail: L("That isn't a valid email address.")
        case .missingPassword: L("Enter the password.")
        case .sessionExpired: L("The WorkTrack session has ended (the password was changed, the account was disabled, or the session expired). Sign in again.")
        case .apiKeyRejected(let code): LF("Firebase refused the app's Web API key (%@).", code)
        case .server(let status, let code): LF("Firebase Auth returned HTTP %1$ld (%2$@).", status, code)
        }
    }

    /// Maps an Identity Toolkit / Secure Token error message such as `INVALID_LOGIN_CREDENTIALS` or
    /// `TOO_MANY_ATTEMPTS_TRY_LATER : Access to this account has been temporarily disabled…`.
    static func from(data: Data, status: Int, refreshing: Bool) -> FirebaseAuthError {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message ?? ""
        let code = message.split(separator: " ").first.map(String.init) ?? ""
        switch code {
        case "INVALID_LOGIN_CREDENTIALS", "EMAIL_NOT_FOUND", "INVALID_PASSWORD": return .invalidCredentials
        case "USER_DISABLED": return refreshing ? .sessionExpired : .userDisabled
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return .tooManyAttempts
        case "INVALID_EMAIL": return .invalidEmail
        case "MISSING_PASSWORD": return .missingPassword
        case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_NOT_FOUND", "INVALID_GRANT_TYPE", "MISSING_REFRESH_TOKEN": return .sessionExpired
        case _ where code.hasPrefix("API_KEY") || code.contains("API key"): return .apiKeyRejected(code)
        default:
            if message.localizedCaseInsensitiveContains("API key not valid") { return .apiKeyRejected("API_KEY_INVALID") }
            return .server(status: status, code: code.isEmpty ? "HTTP \(status)" : code)
        }
    }
}

/// The two Firebase Auth REST calls. Stateless; `WorkTrackVendorClient` holds the tokens.
public struct FirebaseAuthREST: Sendable {
    public let endpoints: FirebaseAuthEndpoints
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(endpoints: FirebaseAuthEndpoints, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { .now }) {
        self.endpoints = endpoints
        self.transport = transport
        self.now = now
    }

    /// `POST accounts:signInWithPassword`. The password goes in this one request body and nowhere else.
    public func signIn(email: String, password: String) async throws -> FirebaseTokens {
        var components = URLComponents(url: endpoints.identityToolkit.appending(path: "accounts:signInWithPassword"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: endpoints.apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let email: String; let password: String; let returnSecureToken = true }
        request.httpBody = try JSONEncoder().encode(Body(email: email, password: password))
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw FirebaseAuthError.from(data: data, status: response.statusCode, refreshing: false)
        }
        struct Reply: Decodable { let idToken: String; let refreshToken: String; let expiresIn: String?; let localId: String; let email: String? }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return FirebaseTokens(idToken: r.idToken, refreshToken: r.refreshToken,
                              expiresAt: now().addingTimeInterval(TimeInterval(r.expiresIn ?? "3600") ?? 3600),
                              userID: r.localId, email: r.email)
    }

    /// `POST token` with `grant_type=refresh_token`: a new one-hour ID token.
    public func refresh(_ refreshToken: String) async throws -> FirebaseTokens {
        var components = URLComponents(url: endpoints.secureToken.appending(path: "token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: endpoints.apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        // URLComponents leaves "+" alone; a refresh token is URL-safe base64-ish, but encode it anyway.
        let encoded = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(encoded.utf8)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw FirebaseAuthError.from(data: data, status: response.statusCode, refreshing: true)
        }
        struct Reply: Decodable { let id_token: String; let refresh_token: String; let expires_in: String?; let user_id: String }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return FirebaseTokens(idToken: r.id_token, refreshToken: r.refresh_token,
                              expiresAt: now().addingTimeInterval(TimeInterval(r.expires_in ?? "3600") ?? 3600),
                              userID: r.user_id, email: nil)
    }
}
