import Foundation

/// Decides whether an identifier is claiming to hold a credential.
///
/// The claim is the evidence. The right-hand side of `api_key = "…"` is a secret
/// whatever the value looks like, and that is the only route to an AWS secret
/// access key — 40 base64-ish characters with no prefix — or to a key issued by
/// an internal service, whose prefix nobody has published.
///
/// Matching is on whole words, never substrings. `secretary: 山田健一` contains
/// `secret`, and treating that as a claim would report a person's name as a key.
enum CredentialName {
    /// Words that make the claim on their own.
    private static let claims: Set<String> = [
        "apikey", "secret", "password", "passwd", "pwd",
        "credential", "credentials", "auth", "authorization",
    ]

    /// Claims written as adjacent words: `API_KEY`, `X-Api-Key`, `apiKey`.
    private static let phrases: [[String]] = [["api", "key"]]

    /// `token` is a claim only when something qualifies it.
    ///
    /// A bare `token` matches `token_count: 1500` and `入力トークン数: 3,200`.
    /// Pasting a report about an LLM is squarely the intended use, so this is
    /// fixed by narrowing the name rule rather than by an exclusion list — an
    /// exclusion list cannot tell you when it has eaten something real.
    ///
    /// `key` is absent for the same reason: `key:` opens a mapping in most YAML
    /// documents, and `primary_key` names a column.
    private static let qualifiedTail = "token"

    /// True when the identifier names an Authorization-style header, where the
    /// entire value after the scheme word is credential material — unlike an
    /// ordinary slot, where the value ends at the first delimiter.
    static func namesAuthorizationHeader(_ identifier: String) -> Bool {
        words(in: identifier).contains("authorization")
    }

    static func claimsCredential(_ identifier: String) -> Bool {
        let parts = words(in: identifier)
        guard !parts.isEmpty else { return false }
        if parts.contains(where: claims.contains) { return true }
        if phrases.contains(where: { contains(parts, $0) }) { return true }
        if let index = parts.firstIndex(of: qualifiedTail), index > 0 { return true }
        return false
    }

    /// Splits an identifier into lower-cased words on `_`, `-`, `.` and case
    /// changes. `AWSSecretKey` becomes `["aws", "secret", "key"]`: an upper-case
    /// run ends one word before the capital that starts the next.
    static func words(in identifier: String) -> [String] {
        let characters = Array(identifier)
        var parts: [String] = []
        var current = ""

        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { parts.append(current.lowercased()) }
                current = ""
                continue
            }
            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    parts.append(current.lowercased())
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current.lowercased()) }
        return parts
    }

    private static func contains(_ parts: [String], _ phrase: [String]) -> Bool {
        guard parts.count >= phrase.count else { return false }
        return (0...(parts.count - phrase.count)).contains { start in
            Array(parts[start..<(start + phrase.count)]) == phrase
        }
    }
}
