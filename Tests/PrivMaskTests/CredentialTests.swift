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

@Suite("Credentials named by their context")
struct CredentialContextDetectorTests {
    private let detector = CredentialContextDetector()
    private let masker = Masker()

    /// Masks with this detector alone, so a failure here is not a merge or a
    /// precedence problem elsewhere.
    private func masked(_ text: String) -> String {
        let candidates = DetectionPipeline.reconcile(detector.detect(in: text), in: text)
        return masker.mask(text, candidates: candidates).text
    }

    private func confidence(of text: String) -> Confidence? {
        DetectionPipeline.reconcile(detector.detect(in: text), in: text).first?.confidence
    }

    @Test("An AWS secret access key is reached by the name that introduces it")
    func awsSecretAccessKey() {
        let text = "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYzTBLURKEY"
        #expect(masked(text) == "AWS_SECRET_ACCESS_KEY=[SECRET_1]")
    }

    @Test("Only the value is masked, never the name")
    func nameIsKept() {
        #expect(masked("DB_PASSWORD=hunter2") == "DB_PASSWORD=[SECRET_1]")
    }

    /// Swallowing the comma would corrupt the document.
    @Test("A quoted value ends at its closing quote")
    func jsonStaysParseable() throws {
        let text = #"{"api_key": "abc123def456", "retries": 3}"#
        let output = masked(text)
        #expect(output == #"{"api_key": "[SECRET_1]", "retries": 3}"#)
        #expect(try JSONSerialization.jsonObject(with: Data(output.utf8)) is [String: Any])
    }

    @Test("Two claims on one line are two findings")
    func twoClaimsOnOneLine() {
        let text = #"{"api_key": "aaaaaaaaaa", "password": "bbbbbbbbbb"}"#
        #expect(masked(text) == #"{"api_key": "[SECRET_1]", "password": "[SECRET_2]"}"#)
    }

    /// Keeping the scheme word also makes the span coincide with what the JWT
    /// pattern finds, so the two merge instead of nesting.
    @Test("The scheme word of an Authorization header is kept")
    func authorizationScheme() {
        #expect(masked("Authorization: Bearer abc123def456") == "Authorization: Bearer [SECRET_1]")
    }

    /// An unlisted scheme used to fall through to the ordinary unquoted rule,
    /// which stops at the first space: the scheme word became the masked span
    /// and the token stayed in the clear. `Negotiate` is everywhere in Active
    /// Directory, and SigV4's `Signature=` is credential-equivalent.
    @Test("Every scheme keeps its word and loses its token", arguments: [
        (
            "Authorization: Negotiate YIIGabcdef1234567890",
            "Authorization: Negotiate [SECRET_1]"
        ),
        (
            "Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20260911, Signature=abcdef123456",
            "Authorization: AWS4-HMAC-SHA256 [SECRET_1]"
        ),
        (
            "Authorization: Hawk id=\"dh37fgj\", mac=\"6R4rV5iE+NPoym\"",
            "Authorization: Hawk [SECRET_1]"
        ),
        (
            "Proxy-Authorization: Negotiate YIIGabcdef1234567890",
            "Proxy-Authorization: Negotiate [SECRET_1]"
        ),
    ])
    func unlistedSchemeLosesItsToken(_ input: String, _ expected: String) {
        #expect(masked(input) == expected)
    }

    /// Terminating at any quote would leave `response=` beside a placeholder
    /// that tells the reader the line is safe — a partial mask, which is worse
    /// than either an obvious leak or an over-mask.
    @Test("A Digest header is masked whole, its inner quotes included")
    func digestHeaderIsMaskedWhole() {
        let text = #"Authorization: Digest username="bob", response=abcdef123456"#
        #expect(masked(text) == "Authorization: Digest [SECRET_1]")
        #expect(!masked(text).contains("abcdef123456"))
    }

    /// The quote that opened the header is the one that closes its value, so
    /// the rest of the shell command survives.
    @Test("An Authorization header inside a shell command stops at the closing quote")
    func authorizationInsideShellCommand() {
        let text = #"curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghijklmnop" https://api.example.com/v1/orders"#
        #expect(
            masked(text)
                == #"curl -H "Authorization: Bearer [SECRET_1]" https://api.example.com/v1/orders"#
        )
    }

    @Test("A quoted Authorization value keeps its quotes and its scheme word")
    func quotedAuthorizationValue() {
        #expect(
            masked(#"{"Authorization": "Bearer xyz123abc"}"#)
                == #"{"Authorization": "Bearer [SECRET_1]"}"#
        )
    }

    /// A token written with no scheme at all is still the credential, so a
    /// lone word is only dropped when it is a scheme word already known to be
    /// one.
    @Test("An Authorization value with no scheme word is the credential")
    func authorizationWithoutScheme() {
        #expect(masked("Authorization: abc123def456") == "Authorization: [SECRET_1]")
    }

    @Test("A quoted header inside a shell command stops at the quote")
    func headerInsideShellCommand() {
        let text = #"curl -H "X-Api-Key: abc123def456" https://api.example.com/v1/orders"#
        #expect(masked(text) == #"curl -H "X-Api-Key: [SECRET_1]" https://api.example.com/v1/orders"#)
    }

    /// `合言葉は𩸽ひらけごま` includes a supplementary-plane character (a
    /// surrogate pair in UTF-16), so its `Character` count and `utf16.count`
    /// differ. A value made only of BMP characters would pass even if the
    /// range arithmetic secretly used `String.Index` offsets.
    @Test("A value containing Japanese is masked whole")
    func japaneseValue() {
        #expect(masked("password = 合言葉は𩸽ひらけごま") == "password = [SECRET_1]")
    }

    /// The reported range is composed from four offsets; only a value on a
    /// later line exercises the line's own contribution.
    @Test("A claim on the second line is masked in place")
    func claimOnLaterLine() {
        #expect(masked("retries = 3\napi_key = abcdef123456") == "retries = 3\napi_key = [SECRET_1]")
    }

    @Test("CRLF line endings do not shift the range")
    func crlfLineEndings() {
        #expect(masked("retries = 3\r\napi_key = abcdef123456") == "retries = 3\r\napi_key = [SECRET_1]")
    }

    /// `skippingScheme` measured its skip distance from the constant's own
    /// length, which happened to match only when the separator after the
    /// scheme word was exactly one ASCII space. A tab or a second space left
    /// the token itself unmasked or, worse, masked the scheme word instead.
    @Test("A tab after the scheme word does not leak the token")
    func schemeWordFollowedByTab() {
        #expect(masked("Authorization: Bearer\tabc123def456") == "Authorization: Bearer\t[SECRET_1]")
    }

    @Test("Two spaces after the scheme word do not leak the token")
    func schemeWordFollowedByTwoSpaces() {
        #expect(masked("Authorization: Bearer  abc123def456") == "Authorization: Bearer  [SECRET_1]")
    }

    /// A scheme word with nothing after it introduces no value. Reporting the
    /// word itself as the secret, which the old length-from-constant skip
    /// did, is a false positive.
    @Test("A scheme word with no token after it is not a claim")
    func schemeWordAloneIsNotAClaim() {
        #expect(detector.detect(in: "Authorization: Bearer").isEmpty)
    }

    @Test("Nothing is claimed here", arguments: [
        "secretary: unassigned",
        "token_count: 1500",
        "primary_key = orders.id",
        "パスワードを再設定してください",
        "Authorization:",
    ])
    func notAClaim(_ text: String) {
        #expect(detector.detect(in: text).isEmpty)
    }

    @Test("An ordinary value is medium confidence")
    func ordinaryValueIsMedium() {
        #expect(confidence(of: "DB_PASSWORD=hunter2") == .medium)
    }

    /// A placeholder is still a candidate. A rule that dropped it would
    /// eventually drop a real numeric password, and nobody would see it go.
    @Test("A value that cannot be live is low confidence, not discarded", arguments: [
        "api_key = YOUR_API_KEY_HERE",
        "api_key = xxxxxxxxxx",
        "api_key = <your-key-here>",
        "api_key = ****************",
        "refresh_token_expires_at: 3600",
        "password = abc",
    ])
    func placeholderIsLow(_ text: String) {
        #expect(confidence(of: text) == .low)
    }
}
