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
    /// What must sit before a word for it to claim.
    private enum Qualification {
        /// Claims on its own: `password`, `secret`, `authorization`.
        case unqualified
        /// Claims only when something precedes it. A bare `token` matches
        /// `token_count: 1500` and `入力トークン数: 3,200`, and pasting a report
        /// about an LLM is squarely the intended use.
        case anyWord
        /// Claims only after one of these. `key` on its own opens a mapping in
        /// most YAML documents and names a column in `primary_key`; `api_key`
        /// and `AUTH_KEY=` are the shapes that hold a secret.
        case oneOf(Set<String>)
    }

    /// The words that can claim, and what each needs in front of it.
    ///
    /// One table rather than a word set, a phrase list and a special case for
    /// `token`, because all three answered the same question and a reader had
    /// to consult all three to predict any one name.
    ///
    /// A bare `auth` is deliberately absent: it names a switch far more often
    /// than a secret — `auth: enabled`, `auth_provider: google`. The shapes that
    /// do hold one are reached by other entries, `AUTH_KEY=` through `key`,
    /// `auth_token` through `token`, `Authorization` through `authorization`.
    private static let claimWords: [String: Qualification] = [
        "apikey": .unqualified,
        "secret": .unqualified,
        "password": .unqualified,
        "passwd": .unqualified,
        "pwd": .unqualified,
        "credential": .unqualified,
        "credentials": .unqualified,
        "authorization": .unqualified,
        "token": .anyWord,
        "key": .oneOf(["api", "auth"]),
    ]

    /// Tails that make the identifier a reference to a secret rather than the
    /// secret: where it lives, what it is called, or how much of it there is.
    ///
    /// `secretName: db-tls-cert` is in nearly every Kubernetes Ingress
    /// manifest, `password_file: /run/secrets/db_password` in every compose
    /// file that does secrets properly, and `api_key_count: 3` is the direct
    /// sibling of the `token_count` that `token`'s qualification already covers.
    /// Masking any of them destroys a line that was never sensitive, and
    /// `password_file` in particular replaces the one piece of information the
    /// reader needed: which file to look in.
    ///
    /// This is the reasoning behind `token`'s qualification, applied where it
    /// belongs. It is checked ahead of every claim, so it governs the
    /// Authorization rule too — which is what stops `authorization_url:` from
    /// masking to the end of the line.
    private static let referenceTails: Set<String> = [
        "count", "file", "path", "name", "id", "length", "url",
    ]

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
        return parts.indices.contains { index in
            guard let qualification = claimWords[parts[index]] else { return false }
            switch qualification {
            case .unqualified: return true
            case .anyWord: return index > 0
            case .oneOf(let qualifiers):
                return index > 0 && qualifiers.contains(parts[index - 1])
            }
        }
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
}
