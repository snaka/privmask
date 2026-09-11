import Foundation

/// Detects a credential by the name that introduces it, rather than by the shape
/// of the value.
///
/// This is what reaches a value no pattern can recognise: an AWS secret access
/// key, or a key issued by an internal service. See `CredentialName` for what
/// counts as a claim.
///
/// Confidence is `.medium`, lowered to `.low` for a value that cannot be a live
/// credential. Such a value is still reported: an exclusion rule that dropped it
/// could not tell you when it had dropped a real numeric password.
public struct CredentialContextDetector {
    public init() {}

    /// `name` — optional closing quote — `:` or `=`.
    ///
    /// The value is deliberately not part of the pattern. Ending the match at
    /// the separator keeps matches short, so a line carrying two claims yields
    /// two of them, and lets the terminator depend on whether the value is
    /// quoted.
    private static let assignment = Pattern(#"([A-Za-z][A-Za-z0-9_.\-]*)["']?[ \t]*[:=][ \t]*"#)

    /// An authentication scheme word is not the secret.
    private static let schemeWords = ["Bearer ", "Basic ", "Token "]

    /// Ends an unquoted value. The quotes are here so that a value inside a
    /// shell-quoted header stops before the closing quote, and the brackets so
    /// that masking cannot corrupt JSON or a function call.
    private static let unquotedTerminators = CharacterSet(charactersIn: " \t\"',;)}]")

    public func detect(in text: String) -> [DetectedMatch] {
        let nsText = text as NSString
        var matches: [DetectedMatch] = []

        for lineRange in Self.lineRanges(in: nsText) {
            let line = nsText.substring(with: lineRange)
            let nsLine = line as NSString

            for result in Self.assignment.results(in: line) {
                let nameRange = result.range(at: 1)
                guard nameRange.location != NSNotFound,
                    CredentialName.claimsCredential(nsLine.substring(with: nameRange))
                else { continue }

                let afterSeparator = result.range.location + result.range.length
                guard afterSeparator < nsLine.length else { continue }

                let rest = nsLine.substring(from: afterSeparator)
                let scheme = Self.skippingScheme(rest)
                guard let valueRange = Self.valueRange(in: scheme.remainder) else { continue }

                let range = NSRange(
                    location: lineRange.location + afterSeparator + scheme.offset + valueRange.location,
                    length: valueRange.length
                )
                let value = nsText.substring(with: range)
                matches.append(
                    DetectedMatch(
                        kind: .credential,
                        source: .credentialContext,
                        range: range,
                        text: value,
                        confidence: Self.looksLikePlaceholder(value) ? .low : nil
                    )
                )
            }
        }
        return matches
    }

    /// The value that follows a separator, or nil when there is none. An empty
    /// value is not a finding: there would be nothing to replace.
    static func valueRange(in rest: String) -> NSRange? {
        let nsRest = rest as NSString
        guard nsRest.length > 0 else { return nil }

        let opening = nsRest.substring(to: 1)
        if opening == "\"" || opening == "'" {
            let closing = nsRest.range(
                of: opening,
                range: NSRange(location: 1, length: nsRest.length - 1)
            )
            guard closing.location != NSNotFound, closing.location > 1 else { return nil }
            return NSRange(location: 1, length: closing.location - 1)
        }

        let terminator = nsRest.rangeOfCharacter(from: unquotedTerminators)
        let length = terminator.location == NSNotFound ? nsRest.length : terminator.location
        guard length > 0 else { return nil }
        return NSRange(location: 0, length: length)
    }

    /// Steps over `Bearer` / `Basic` / `Token`, reporting how far it moved.
    static func skippingScheme(_ rest: String) -> (offset: Int, remainder: String) {
        let lowered = rest.lowercased()
        for word in schemeWords where lowered.hasPrefix(word.lowercased()) {
            let length = (word as NSString).length
            return (length, (rest as NSString).substring(from: length))
        }
        return (0, rest)
    }

    /// Values that cannot be a live credential.
    static func looksLikePlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count < 6 { return true }
        if trimmed.allSatisfy(\.isNumber) { return true }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return true }
        if trimmed.allSatisfy({ "*xX.-_".contains($0) }) { return true }
        let upper = trimmed.uppercased()
        let markers = ["YOUR_", "YOUR-", "CHANGEME", "CHANGE_ME", "PLACEHOLDER", "REDACTED", "DUMMY", "TODO", "FIXME"]
        return markers.contains(where: upper.contains)
    }

    /// Each line's range, excluding its terminator. An assignment does not
    /// continue past one line.
    static func lineRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            ranges.append(NSRange(location: cursor, length: contentsEnd - cursor))
            cursor = lineEnd > cursor ? lineEnd : cursor + 1
        }
        return ranges
    }
}
