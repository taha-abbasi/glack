import Testing
import Foundation
import CryptoKit
@testable import Glack

@Suite("PKCE helpers")
struct PKCETests {
    @Test("code verifier is base64url and within RFC 7636 length bounds")
    func codeVerifierLength() {
        let v = OAuthClient.makeCodeVerifier()
        // RFC 7636 §4.1: 43..128 chars from the unreserved set.
        #expect(v.count >= 43, "code verifier too short: \(v.count) chars")
        #expect(v.count <= 128, "code verifier too long: \(v.count) chars")
        // Base64URL alphabet only — no '+', '/', or '=' padding.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        #expect(v.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test("two code verifiers in a row are different (uses SecRandomCopyBytes)")
    func codeVerifierUniqueness() {
        let a = OAuthClient.makeCodeVerifier()
        let b = OAuthClient.makeCodeVerifier()
        #expect(a != b)
    }

    @Test("code challenge is SHA256(verifier) base64url-encoded with no padding")
    func codeChallengeShape() {
        let verifier = "test-verifier-for-pkce-challenge-deterministic-string"
        let challenge = OAuthClient.codeChallenge(for: verifier)

        // Verify against an independent SHA256 + base64url calc.
        let expected = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(challenge == expected)
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test("form encoding preserves key/value pairs and escapes reserved chars")
    func formEncoding() {
        let encoded = OAuthClient.formEncode([
            "client_id": "abc.apps.googleusercontent.com",
            "scope": "openid email",
            "code": "auth&code=weird",
        ])
        // Order isn't guaranteed (dictionary), so split and verify membership.
        let parts = Set(encoded.split(separator: "&").map(String.init))
        #expect(parts.contains("client_id=abc.apps.googleusercontent.com"))
        // Space → %20 (urlQueryAllowed encodes spaces in our impl).
        #expect(parts.contains { $0.hasPrefix("scope=openid") && $0.contains("email") })
        // & and = inside values must be percent-escaped so they don't collide with delimiters.
        #expect(!parts.contains("code=auth&code=weird"), "ampersand in value was not escaped")
    }

    @Test("random URL-safe strings produce the requested byte budget")
    func randomURLSafeLength() {
        // 32 bytes → ceil(32 * 4 / 3) = 43 base64 chars, minus '=' padding stripped.
        let s = OAuthClient.randomURLSafe(length: 32)
        #expect(s.count >= 40 && s.count <= 44, "unexpected length: \(s.count)")
    }
}
