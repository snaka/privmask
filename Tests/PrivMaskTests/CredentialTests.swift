import Foundation
import Testing

@testable import PrivMask

@Suite("Credentials in a URL")
struct URLCredentialTests {
    private let pipeline = DetectionPipeline()
    private let masker = Masker()

    private func masked(_ text: String) -> String {
        masker.mask(text, candidates: pipeline.detect(in: text)).text
    }

    /// The user name is not the secret, and hiding it costs the reader the
    /// answer to which account the failure was under.
    @Test("The password is masked and the user name kept")
    func passwordOnly() {
        let text = "DATABASE_URL=postgres://app:hunter2@db.internal:5432/orders"
        #expect(masked(text) == "DATABASE_URL=postgres://app:[SECRET_1]@db.internal:5432/orders")
    }

    @Test("A URL with no credentials is left alone")
    func noCredentials() {
        #expect(pipeline.detect(in: "https://github.com/snaka/privmask").isEmpty)
    }

    /// Email addresses are still detected when preceded by a colon in other
    /// contexts (e.g., labels, mailto: links).
    @Test("An email immediately preceded by a colon is still detected")
    func emailAfterColon() {
        let text = "Email:someone@example.com"
        #expect(masked(text) == "Email:[EMAIL_1]")
    }

    /// The userinfo component of a URL (before @) is not an email address,
    /// even though it has the same shape.
    @Test("The userinfo in a URL is not reported as an email")
    func noEmailInUserinfo() {
        let text = "postgres://app:hunter2@db.internal:5432/orders"
        let candidates = pipeline.detect(in: text)
        // The password should be detected as a credential, not as an email
        #expect(!candidates.contains { $0.kind == .email })
    }
}

@Suite("Known credential prefixes")
struct KnownPrefixTests {
    private let detectors = RegexDetectors()

    private func findsWholeValue(_ value: String, in text: String) -> Bool {
        detectors.detect(in: text).contains { $0.kind == .credential && $0.text == value }
    }

    @Test(
        "A value with a published prefix is found whole",
        arguments: [
            "github_pat_11ABCDEFG0abcdefghijkl_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqr",
            "xoxb-123456789012-123456789012-abcdefghijklmnopqrstuvwx",
            "xapp-1-A012BCDEFGH-1234567890123-abcdefghijklmnopqrstuvwxyz",
            "AIzaSyB1234567890abcdefghijklmnopqrstuv",
            "sk_live_51H1234567890abcdefghijkl",
            "rk_test_51H1234567890abcdefghijkl",
            "npm_abcdefghijklmnopqrstuvwxyz0123456789",
            "SG.abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuvwxyz0123456789012345678",
            "https://hooks.slack.com/services/T00000000/B00000000/abcdefghijklmnopqrstuvwx",
        ]
    )
    func knownPrefix(_ value: String) {
        #expect(findsWholeValue(value, in: "value: \(value)"))
    }

    @Test("A JWT is found")
    func jwt() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
            + ".dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(findsWholeValue(token, in: "Bearer \(token)"))
    }

    @Test("A private key block is found whole, newlines included")
    func privateKeyBlock() {
        let block = """
            -----BEGIN PRIVATE KEY-----
            MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
            -----END PRIVATE KEY-----
            """
        #expect(findsWholeValue(block, in: "key:\n\(block)\n"))
    }

    /// A publishable key is meant to be public, and a public key is a public
    /// key. Masking either destroys the text for no gain.
    @Test("Public counterparts are not credentials", arguments: [
        "pk_live_51H1234567890abcdefghijkl",
        "-----BEGIN PUBLIC KEY-----",
    ])
    func publicCounterparts(_ value: String) {
        #expect(!findsWholeValue(value, in: "value: \(value)"))
    }

    /// A truncated block must not reach forward to a later key's END, which
    /// would mask everything in between.
    @Test("A block with no END of its own does not swallow the text up to the next key")
    func danglingBlockDoesNotBridge() {
        let text = """
            -----BEGIN PRIVATE KEY-----
            TRUNCATEDMATERIAL
            この行は絶対にマスクされてはいけない
            -----BEGIN RSA PRIVATE KEY-----
            MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
            -----END RSA PRIVATE KEY-----
            """
        let found = detectors.detect(in: text).filter { $0.kind == .credential }
        #expect(found.count == 1)
        #expect(found.first?.text.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") == true)
        #expect(found.allSatisfy { !$0.text.contains("この行は") })
    }
}

@Suite("What counts as claiming to hold a credential")
struct CredentialNameTests {
    @Test("An identifier splits into words on separators and case changes", arguments: [
        ("api_key", ["api", "key"]),
        ("X-Api-Key", ["x", "api", "key"]),
        ("secretKey", ["secret", "key"]),
        ("AWSSecretKey", ["aws", "secret", "key"]),
        ("API_KEY", ["api", "key"]),
        ("spring.datasource.password", ["spring", "datasource", "password"]),
        ("Authorization", ["authorization"]),
    ])
    func splitsIntoWords(_ identifier: String, _ expected: [String]) {
        #expect(CredentialName.words(in: identifier) == expected)
    }

    @Test("It claims to hold a credential", arguments: [
        "api_key", "apiKey", "API_KEY", "X-Api-Key", "apikey",
        "client_secret", "secretKey", "AWSSecretKey", "AWS_SECRET_ACCESS_KEY",
        "password", "PASSWORD", "spring.datasource.password", "passwd", "pwd",
        "credential", "credentials", "auth", "Authorization",
        "access_token", "refresh_token", "GITHUB_TOKEN",
    ])
    func claims(_ identifier: String) {
        #expect(CredentialName.claimsCredential(identifier))
    }

    /// `secretary` contains `secret`; `token_count` and `入力トークン数` are why
    /// a bare `token` is not a claim; `key` on its own opens a mapping in most
    /// YAML documents.
    @Test("It does not", arguments: [
        "secretary", "token", "token_count", "key", "primary_key",
        "AWS_ACCESS_KEY_ID", "STRIPE_PUBLISHABLE_KEY",
        "keyboard", "monkey", "name", "retries",
    ])
    func doesNotClaim(_ identifier: String) {
        #expect(!CredentialName.claimsCredential(identifier))
    }
}
