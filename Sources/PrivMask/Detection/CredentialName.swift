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
    ///
    /// A bare `auth` is not among them. It names a switch far more often than
    /// a secret — `auth: enabled`, `auth_provider: google`. Dropping it does
    /// cost something, though: `AUTH_KEY=` in a `.env` stopped being a claim
    /// until `["auth", "key"]` was added to `phrases`. `auth_token` and
    /// `Authorization` were never at risk, being reached by the qualified
    /// `token` rule and by the word `authorization`.
    private static let claims: Set<String> = [
        "apikey", "secret", "password", "passwd", "pwd",
        "credential", "credentials", "authorization",
    ]

    /// Tails that make the identifier a reference to a secret rather than the
    /// secret: where it lives, what it is called, or how much of it there is.
    ///
    /// `secretName: db-tls-cert` is in nearly every Kubernetes Ingress
    /// manifest, `password_file: /run/secrets/db_password` in every compose
    /// file that does secrets properly, and `api_key_count: 3` is the direct
    /// sibling of the `token_count` that `qualifiedTail` already exists for.
    /// Masking any of them destroys a line that was never sensitive, and
    /// `password_file` in particular replaces the one piece of information the
    /// reader needed: which file to look in.
    ///
    /// This is the reasoning behind `qualifiedTail`, applied where it belongs.
    /// It is checked ahead of every claim, so it governs the Authorization
    /// rule too — which is what stops `authorization_url:` from masking to the
    /// end of the line.
    private static let referenceTails: Set<String> = [
        "count", "file", "path", "name", "id", "length", "url",
    ]

    /// Claims written as adjacent words: `API_KEY`, `X-Api-Key`, `apiKey`.
    ///
    /// `["auth", "key"]` is here rather than in `claims` because it is the pair
    /// that claims, not either word alone. `AUTH_KEY=` is an ordinary `.env`
    /// shape; a bare `auth` names a switch.
    private static let phrases: [[String]] = [["api", "key"], ["auth", "key"]]

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
        let parts = words(in: identifier)
        guard !namesAReference(parts) else { return false }
        return parts.contains("authorization")
    }

    static func claimsCredential(_ identifier: String) -> Bool {
        let parts = words(in: identifier)
        guard !parts.isEmpty, !namesAReference(parts) else { return false }
        if parts.contains(where: claims.contains) { return true }
        if phrases.contains(where: { contains(parts, $0) }) { return true }
        if let index = parts.firstIndex(of: qualifiedTail), index > 0 { return true }
        return false
    }

    /// True when the identifier names something *about* a secret rather than
    /// the secret itself. Only the last word decides: `secret_file_password`
    /// ends on the secret and still claims.
    private static func namesAReference(_ parts: [String]) -> Bool {
        guard let last = parts.last else { return false }
        return referenceTails.contains(last)
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
