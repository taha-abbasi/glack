import Foundation
import AuthenticationServices
import CryptoKit
import AppKit

enum OAuthError: LocalizedError {
    case missingClientID
    case sessionFailedToStart
    case noCallbackURL
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Missing GoogleOAuthClientID — check Config/Secrets.xcconfig."
        case .sessionFailedToStart:
            return "Couldn't open the Google sign-in window."
        case .noCallbackURL:
            return "Google returned no callback URL."
        case .stateMismatch:
            return "OAuth state mismatch — try signing in again."
        case .missingAuthorizationCode:
            return "Google's callback did not include an authorization code."
        case .tokenExchangeFailed(let status, let body):
            return "Token exchange failed (HTTP \(status)): \(body)"
        }
    }
}

struct TokenSet {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var idToken: String?
}

private struct GoogleTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let id_token: String?
    let scope: String?
    let token_type: String?
}

@MainActor
final class OAuthClient: NSObject {
    static let shared = OAuthClient()

    /// Google's "reverse client ID" custom scheme for Desktop-app OAuth.
    /// Strip `.apps.googleusercontent.com` and prepend `com.googleusercontent.apps.`.
    /// No Cloud Console registration needed — Google accepts this format implicitly for Desktop clients.
    private var callbackScheme: String {
        let suffix = ".apps.googleusercontent.com"
        let stripped = clientID.hasSuffix(suffix)
            ? String(clientID.dropLast(suffix.count))
            : clientID
        return "com.googleusercontent.apps.\(stripped)"
    }
    private var redirectURI: String { "\(callbackScheme):/oauth2redirect" }
    private var anchorForSession: NSWindow?
    private let scopes: [String] = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/chat.messages",
        "https://www.googleapis.com/auth/chat.spaces",
        "https://www.googleapis.com/auth/chat.memberships",
        "https://www.googleapis.com/auth/chat.users.readstate",
        "https://www.googleapis.com/auth/chat.spaces.pins",
    ]

    private var clientID: String {
        BuildConfig.googleOAuthClientID
    }
    private var clientSecret: String {
        BuildConfig.googleOAuthClientSecret
    }

    func signIn() async throws -> TokenSet {
        guard !clientID.isEmpty else { throw OAuthError.missingClientID }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(length: 32)

        let authURL = buildAuthorizationURL(challenge: challenge, state: state)
        let callbackURL = try await presentAuthSession(authURL: authURL)

        let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw OAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.missingAuthorizationCode
        }
        return try await exchangeCode(code, verifier: verifier)
    }

    func refresh(refreshToken: String) async throws -> TokenSet {
        guard !clientID.isEmpty else { throw OAuthError.missingClientID }
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let response = try await tokenRequest(body: body)
        return TokenSet(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
            idToken: response.id_token
        )
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> TokenSet {
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        let response = try await tokenRequest(body: body)
        return TokenSet(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
            idToken: response.id_token
        )
    }

    private func tokenRequest(body: [String: String]) async throws -> GoogleTokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed(status: status, body: body)
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private func presentAuthSession(authURL: URL) async throws -> URL {
        // Capture the anchor on the main thread BEFORE the session starts —
        // the presentation-anchor callback runs synchronously from start()
        // and must not hop threads (would deadlock).
        anchorForSession = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        defer { anchorForSession = nil }

        let scheme = callbackScheme

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme,
                completionHandler: Self.makeCallbackHandler(continuation: cont)
            )
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(throwing: OAuthError.sessionFailedToStart)
            }
        }
    }

    /// The completion handler ASWebAuth invokes on a background queue.
    /// MUST be produced in a nonisolated context so it doesn't inherit the
    /// enclosing @MainActor isolation — otherwise Swift 6's runtime executor
    /// check trips with SIGTRAP when ASWebAuth calls it off the main thread.
    private nonisolated static func makeCallbackHandler(
        continuation cont: CheckedContinuation<URL, Error>
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            if let error {
                cont.resume(throwing: error)
                return
            }
            guard let url else {
                cont.resume(throwing: OAuthError.noCallbackURL)
                return
            }
            cont.resume(returning: url)
        }
    }

    private func buildAuthorizationURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        return comps.url!
    }

    // MARK: - PKCE / random helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formEncode(_ dict: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        return dict.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

extension OAuthClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Called synchronously from session.start() on the main thread.
        // assumeIsolated lets us read MainActor state without a dispatch hop.
        MainActor.assumeIsolated {
            anchorForSession ?? NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
