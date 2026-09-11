import Foundation

/// Pattern-based detectors for values with an unambiguous shape.
///
/// These carry `.high` confidence: unlike the model or the entity tagger, a
/// match here is a structural fact about the text, not a judgement.
public struct RegexDetectors {
    public init() {}

    public func detect(in text: String) -> [DetectedMatch] {
        var matches: [DetectedMatch] = []
        matches += Self.postalCodes.matches(in: text, kind: .postalCode)
        for pattern in Self.credentials {
            matches += pattern.matches(in: text, kind: .credential)
        }
        let urlCredentials = Self.urlCredential.matches(in: text, kind: .credential, group: 1)
        matches += urlCredentials

        // The userinfo component of a URL is not an email address, even though it
        // has the same shape. Drop any email match that overlaps with a URL credential.
        let emailMatches = Self.emails.matches(in: text, kind: .email)
        for email in emailMatches {
            if !urlCredentials.contains(where: { rangesOverlap(email.range, $0.range) }) {
                matches.append(email)
            }
        }

        return matches
    }

    /// NSDataDetector reports emails only inside `mailto:` links, so bare
    /// addresses need their own pattern.
    private static let emails = Pattern(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    /// A 〒 marker is required. A bare `123-4567` is indistinguishable from an
    /// order number or a date range, and masking those would corrupt the text.
    private static let postalCodes = Pattern(#"〒\s*[0-9０-９]{3}[-－ー−][0-9０-９]{4}"#)

    private static let credentials: [Pattern] = [
        // AWS access key ID
        Pattern(#"\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b"#),
        // GitHub personal access / OAuth / server / refresh tokens
        Pattern(#"\bgh[pousr]_[A-Za-z0-9]{36,255}\b"#),
        // OpenAI-style secret keys
        Pattern(#"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}\b"#),
        // GitHub fine-grained personal access token
        Pattern(#"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#),
        // Slack bot / user / app-level tokens
        Pattern(#"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#),
        Pattern(#"\bxapp-[0-9]-[A-Za-z0-9\-]{10,}"#),
        // Slack incoming webhook: the URL is the credential
        Pattern(#"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]{20,}"#),
        // Google API key
        Pattern(#"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        // Stripe secret and restricted keys. `pk_` is publishable: left alone.
        Pattern(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        // npm access token
        Pattern(#"\bnpm_[A-Za-z0-9]{36}\b"#),
        // SendGrid API key
        Pattern(#"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b"#),
        // JWT: header.payload.signature, both halves base64url-encoded JSON
        Pattern(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#),
        // A private key block, newlines included. A block with no END of its own
        // must not reach forward to a later key's END and mask the text in between.
        // `PUBLIC KEY` is not matched.
        Pattern(
            #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----(?:(?!-----BEGIN )[\s\S])*?-----END (?:[A-Z]+ )?PRIVATE KEY-----"#
        ),
    ]

    /// Credentials embedded in a URL. Group 1 is the password.
    ///
    /// `@` and `/` are excluded from both halves so the match cannot run past
    /// the authority component into a path that happens to contain a colon.
    private static let urlCredential = Pattern(
        #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/?#@]+:([^\s/?#@]+)@"#
    )
}

/// A compiled regular expression that yields `DetectedMatch` values.
struct Pattern {
    private let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // These patterns are literals in this file: a failure here is a
        // programming error, not something a caller can recover from.
        // swiftlint:disable:next force_try
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(in text: String, kind: SensitiveKind) -> [DetectedMatch] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { result in
                DetectedMatch(
                    kind: kind,
                    source: .regex,
                    range: result.range,
                    text: nsText.substring(with: result.range)
                )
            }
    }

    func matchRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map(\.range)
    }

    /// Matches reported at one capture group rather than the whole match.
    ///
    /// The URL-credential pattern needs this: the match has to span
    /// `scheme://user:pass@` to know what it is looking at, but only the
    /// password is the secret.
    func matches(in text: String, kind: SensitiveKind, group: Int) -> [DetectedMatch] {
        let nsText = text as NSString
        return results(in: text).compactMap { result in
            let range = result.range(at: group)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return DetectedMatch(
                kind: kind,
                source: .regex,
                range: range,
                text: nsText.substring(with: range)
            )
        }
    }

    /// Raw results, for a caller that needs match positions rather than a
    /// finished `DetectedMatch`.
    func results(in text: String) -> [NSTextCheckingResult] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    }
}
