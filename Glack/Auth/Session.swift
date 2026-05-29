import Foundation
import Observation

@MainActor
@Observable
final class Session {
    static let shared = Session()

    enum State {
        case unknown          // before bootstrap()
        case signedOut
        case signingIn
        case signedIn(email: String?)
    }

    private(set) var state: State = .unknown
    private(set) var lastError: String?

    private var currentTokens: TokenSet?

    private let keychainAccount = "oauth-refresh"

    private init() {}

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }

    func bootstrap() async {
        guard case .unknown = state else { return }
        do {
            guard let refresh = try KeychainStore.get(account: keychainAccount),
                  !refresh.isEmpty else {
                state = .signedOut
                return
            }
            let tokens = try await OAuthClient.shared.refresh(refreshToken: refresh)
            try? KeychainStore.set(tokens.refreshToken, account: keychainAccount)
            currentTokens = tokens
            state = .signedIn(email: extractEmail(idToken: tokens.idToken))
        } catch {
            // Silent refresh failed — token may be revoked. Drop it and show sign-in.
            try? KeychainStore.delete(account: keychainAccount)
            lastError = "Couldn't restore session: \(error.localizedDescription)"
            state = .signedOut
        }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        state = .signingIn
        lastError = nil
        do {
            let tokens = try await OAuthClient.shared.signIn()
            guard !tokens.refreshToken.isEmpty else {
                lastError = "Google returned no refresh token. Revoke Glack's access at https://myaccount.google.com/permissions and try again."
                state = .signedOut
                return
            }
            try KeychainStore.set(tokens.refreshToken, account: keychainAccount)
            currentTokens = tokens
            state = .signedIn(email: extractEmail(idToken: tokens.idToken))
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .signedOut
        }
    }

    func signOut() async {
        try? KeychainStore.delete(account: keychainAccount)
        currentTokens = nil
        lastError = nil
        state = .signedOut
    }

    /// Returns a valid access token, refreshing when within 60s of expiry.
    func accessToken() async throws -> String {
        if let tokens = currentTokens, tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        guard let refresh = try KeychainStore.get(account: keychainAccount), !refresh.isEmpty else {
            throw OAuthError.missingClientID  // semantically "not signed in"; reusing for simplicity
        }
        let tokens = try await OAuthClient.shared.refresh(refreshToken: refresh)
        try? KeychainStore.set(tokens.refreshToken, account: keychainAccount)
        currentTokens = tokens
        if case .signedIn = state {
            state = .signedIn(email: extractEmail(idToken: tokens.idToken))
        }
        return tokens.accessToken
    }

    // MARK: - Helpers

    private func extractEmail(idToken: String?) -> String? {
        guard let parts = idToken?.split(separator: "."), parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                  .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}
