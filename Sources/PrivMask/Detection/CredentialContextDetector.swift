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
    private static let schemeWords = ["Bearer", "Basic", "Token"]

    /// A leading scheme word and the whitespace after it, in an
    /// `Authorization` header. Recognising the shape rather than a list is what
    /// reaches `Negotiate`, `Digest`, `Hawk` and `AWS4-HMAC-SHA256`: any one of
    /// them missing from a list leaves the token after it in the clear.
    private static let schemePrefix = Pattern(#"^[A-Za-z][A-Za-z0-9\-]*[ \t]+"#)

    /// Ends an unquoted value at the first character that is more likely to be
    /// a delimiter than part of the secret: whitespace, a closing quote left
    /// over from a shell-quoted header, or a bracket that would otherwise let
    /// masking corrupt JSON or a function call.
    ///
    /// `&` and `#` are deliberately absent even though `?api_key=abc&limit=10`
    /// then masks the whole `abc&limit=10` tail. Stopping at them would turn an
    /// unquoted `password=hunter2#2024` into a partial mask that leaks the
    /// suffix `2024`, and a partial mask is a leak — the over-masking this
    /// causes instead loses no secret; it only masks a little more of the
    /// visible text than strictly necessary. `<` and `>` stay out for the same
    /// reason: including them would cut `<your-key-here>` down to a zero-length
    /// value and stop it from being detected as a placeholder at all.
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
                let offset: Int
                let valueRange: NSRange
                if CredentialName.namesAuthorizationHeader(nsLine.substring(with: nameRange)) {
                    guard
                        let found = Self.authorizationValueRange(
                            in: rest,
                            openedBy: Self.quoteBefore(nameRange, in: nsLine)
                        )
                    else { continue }
                    offset = 0
                    valueRange = found
                } else {
                    guard let scheme = Self.skippingScheme(rest) else { continue }
                    guard let found = Self.valueRange(in: scheme.remainder) else { continue }
                    offset = scheme.offset
                    valueRange = found
                }

                let range = NSRange(
                    location: lineRange.location + afterSeparator + offset + valueRange.location,
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

        if Self.isQuote(nsRest.substring(to: 1)) {
            return quotedValueRange(in: nsRest)
        }

        let terminator = nsRest.rangeOfCharacter(from: unquotedTerminators)
        let length = terminator.location == NSNotFound ? nsRest.length : terminator.location
        guard length > 0 else { return nil }
        return NSRange(location: 0, length: length)
    }

    /// The content between a value's own quotes, or nil when the quote never
    /// closes or encloses nothing.
    static func quotedValueRange(in nsRest: NSString) -> NSRange? {
        let opening = nsRest.substring(to: 1)
        let closing = nsRest.range(
            of: opening,
            range: NSRange(location: 1, length: nsRest.length - 1)
        )
        guard closing.location != NSNotFound, closing.location > 1 else { return nil }
        return NSRange(location: 1, length: closing.location - 1)
    }

    /// The value of an `Authorization`-style header, in `rest`'s coordinates.
    ///
    /// This slot is unlike every other one: the whole header value is
    /// credential material, and the only part that is not secret is the leading
    /// scheme word. Ending the value at the first space — the ordinary rule —
    /// reports the scheme word itself as the secret for every scheme outside
    /// `schemeWords` and leaves the token beside it in the clear.
    ///
    /// - Parameter openingQuote: the quote immediately before the header name,
    ///   when there is one. That quote — `curl -H "Authorization: …"` — is the
    ///   only one that can be trusted to close the value. Stopping at any quote
    ///   would cut `Digest username="bob", response=…` down to `username=`,
    ///   leaving the response hash visible next to a placeholder that tells the
    ///   reader the line is safe.
    static func authorizationValueRange(in rest: String, openedBy openingQuote: String?) -> NSRange? {
        let nsRest = rest as NSString
        guard nsRest.length > 0 else { return nil }

        // A value inside quotes of its own, as in `{"Authorization": "Bearer
        // xyz"}`. Those quotes delimit it, and the scheme word sits within them.
        if Self.isQuote(nsRest.substring(to: 1)) {
            guard let quoted = quotedValueRange(in: nsRest),
                let value = schemeSkippedRange(in: nsRest.substring(with: quoted))
            else { return nil }
            return NSRange(location: quoted.location + value.location, length: value.length)
        }

        var end = nsRest.length
        if let quote = openingQuote {
            let closing = nsRest.range(of: quote)
            if closing.location != NSNotFound { end = closing.location }
        }
        while end > 0, Self.isSpaceOrTab(nsRest, at: end - 1) { end -= 1 }
        guard end > 0 else { return nil }

        return schemeSkippedRange(in: nsRest.substring(to: end))
    }

    /// What follows the scheme word, or the whole of `value` when no scheme
    /// word introduces it. Nil when the value is nothing but a scheme word:
    /// `Authorization: Bearer` names no secret, and reporting the word itself
    /// is a false positive.
    ///
    /// A lone word that is not a known scheme is kept, because an opaque token
    /// written with no scheme at all is still the credential.
    static func schemeSkippedRange(in value: String) -> NSRange? {
        let nsValue = value as NSString
        guard nsValue.length > 0 else { return nil }
        if let prefix = schemePrefix.matchRanges(in: value).first, prefix.length < nsValue.length {
            return NSRange(location: prefix.length, length: nsValue.length - prefix.length)
        }
        if schemeWords.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            return nil
        }
        return NSRange(location: 0, length: nsValue.length)
    }

    /// The quote that opened the argument a header name sits in, when there is
    /// one.
    static func quoteBefore(_ nameRange: NSRange, in line: NSString) -> String? {
        guard nameRange.location > 0 else { return nil }
        let character = line.substring(with: NSRange(location: nameRange.location - 1, length: 1))
        return isQuote(character) ? character : nil
    }

    private static func isQuote(_ character: String) -> Bool {
        character == "\"" || character == "'"
    }

    /// Steps over a scheme word and the whitespace after it, reporting how far
    /// it moved. Returns nil when the scheme word introduces no value at all.
    ///
    /// The word is located in `rest`'s own coordinates rather than measured
    /// from the constant. Taking the distance from the constant broke as soon
    /// as the separator was a tab or a run of spaces, and it did not fail
    /// safely: `Authorization: Bearer\tabc…` masked the word `Bearer` and left
    /// the token in the clear.
    static func skippingScheme(_ rest: String) -> (offset: Int, remainder: String)? {
        let nsRest = rest as NSString
        for word in schemeWords {
            let found = nsRest.range(
                of: word,
                options: [.caseInsensitive, .anchored],
                range: NSRange(location: 0, length: nsRest.length)
            )
            guard found.location != NSNotFound else { continue }

            var cursor = found.length
            while cursor < nsRest.length, Self.isSpaceOrTab(nsRest, at: cursor) {
                cursor += 1
            }

            // `Bearer` with nothing after it introduces no value, and reporting
            // the word itself as a secret is a false positive.
            guard cursor < nsRest.length else { return nil }
            // `Bearerfoo` is not a scheme word introducing a value; treat the
            // whole thing as an opaque value rather than losing it.
            guard cursor > found.length else { return (0, rest) }
            return (cursor, nsRest.substring(from: cursor))
        }
        return (0, rest)
    }

    private static func isSpaceOrTab(_ nsString: NSString, at index: Int) -> Bool {
        let character = nsString.character(at: index)
        return character == 0x20 || character == 0x09
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
