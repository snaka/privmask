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
