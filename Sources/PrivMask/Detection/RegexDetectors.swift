import Foundation

/// Pattern-based detectors for values with an unambiguous shape.
///
/// These carry `.high` confidence: unlike the model or the entity tagger, a
/// match here is a structural fact about the text, not a judgement.
public struct RegexDetectors {
    public init() {}

    public func detect(in text: String) -> [DetectedMatch] {
        var matches: [DetectedMatch] = []
        matches += Self.emails.matches(in: text, kind: .email)
        matches += Self.postalCodes.matches(in: text, kind: .postalCode)
        for pattern in Self.credentials {
            matches += pattern.matches(in: text, kind: .credential)
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
    ]
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
}
