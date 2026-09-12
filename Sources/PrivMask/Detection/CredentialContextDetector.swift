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

    /// The authentication schemes whose leading word is not the secret.
    ///
    /// A list, and deliberately not a shape. Treating any leading word followed
    /// by whitespace as the scheme reached every scheme without naming them,
    /// but it read the token itself as a scheme whenever a value carried a
    /// trailing anything: `Authorization: abc123def456 # honban` masked the
    /// comment and left the token beside the placeholder.
    ///
    /// The two rules fail in opposite directions, and only one of those
    /// directions is acceptable here. A word missing from this list costs a
    /// masked scheme word — visible, and no secret lost. A shape rule costs the
    /// credential.
    private static let schemeWords = [
        "Bearer", "Basic", "Token", "Negotiate", "Digest", "Hawk", "NTLM",
        "ApiKey", "AWS4-HMAC-SHA256",
    ]

    /// Ends an unquoted value at the first character that is more likely to be
    /// a delimiter than part of the secret: whitespace, a closing quote left
    /// over from a shell-quoted header, or a bracket that would otherwise let
    /// masking corrupt JSON or a function call.
    ///
    /// Every character here can also occur inside a secret, so each one is in
    /// the set for the same reason: leaving it out corrupts the document being
    /// shared. What that costs is a partial mask — `password: correct horse
    /// battery staple` is masked as far as the first space, and the reader is
    /// shown a placeholder on a line that is not safe. The trade is accepted
    /// only because a secret containing a space, a semicolon or a bracket is
    /// rarer than one containing `&` or `#`, which is why those two stay out
    /// even though `?api_key=abc&limit=10` then masks the whole
    /// `abc&limit=10` tail. `<` and `>` stay out for an unrelated reason:
    /// including them would cut `<your-key-here>` down to a zero-length value
    /// and stop it from being detected as a placeholder at all.
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
        if let reference = Self.variableReferenceRange(in: nsRest) {
            return reference
        }

        let terminator = nsRest.rangeOfCharacter(from: unquotedTerminators)
        let length = terminator.location == NSNotFound ? nsRest.length : terminator.location
        guard length > 0 else { return nil }
        return NSRange(location: 0, length: length)
    }

    /// A `${…}` reference, closing brace included.
    ///
    /// `}` is a terminator, so the ordinary rule stopped one character short
    /// and left the brace orphaned — `secret: ${AWS_SECRET}` became
    /// `secret: [SECRET_1]}`. A `.env.example`, a compose file and a CI config
    /// are all intended input, so the output has to stay well-formed.
    ///
    /// A nested `${A:-${B}}` ends at the first `}`. Counting braces for a
    /// shape that does not appear in these files would buy nothing.
    static func variableReferenceRange(in nsRest: NSString) -> NSRange? {
        guard nsRest.length > 2, nsRest.substring(to: 2) == "${" else { return nil }
        let closing = nsRest.range(
            of: "}",
            range: NSRange(location: 2, length: nsRest.length - 2)
        )
        guard closing.location != NSNotFound else { return nil }
        return NSRange(location: 0, length: closing.location + 1)
    }

    /// The content between a value's own quotes, or nil when the quote never
    /// closes or encloses nothing.
    ///
    /// A quote the value escapes is not the closing one. Taking it as the close
    /// truncated `"abc\"def"` to `abc`, which both left `def` visible and broke
    /// the JSON around it — the thing `jsonStaysParseable` exists to prevent.
    static func quotedValueRange(in nsRest: NSString) -> NSRange? {
        let opening = nsRest.substring(to: 1)
        guard let closing = unescapedIndex(of: opening, in: nsRest, from: 1), closing > 1 else {
            return nil
        }
        return NSRange(location: 1, length: closing - 1)
    }

    /// Where `character` first occurs without the text escaping it, or nil when
    /// it never does.
    ///
    /// Both quote searches go through this. They did not, and the one that did
    /// not count backslashes ended a Hawk header at its first `\"`, leaving the
    /// `mac` — which is the credential — beside the placeholder.
    static func unescapedIndex(of character: String, in nsString: NSString, from start: Int) -> Int? {
        var searchFrom = start
        while searchFrom < nsString.length {
            let found = nsString.range(
                of: character,
                range: NSRange(location: searchFrom, length: nsString.length - searchFrom)
            )
            guard found.location != NSNotFound else { return nil }
            if backslashesBefore(found.location, in: nsString).isMultiple(of: 2) {
                return found.location
            }
            searchFrom = found.location + found.length
        }
        return nil
    }

    /// How many backslashes run consecutively up to `index`. An odd count means
    /// the character there is escaped.
    ///
    /// Counting is what separates `"abc\"def"`, where the quote is escaped,
    /// from `"abc\\"`, where the backslash is escaped and the quote really
    /// does close the value. Skipping every `\"` gets the first right and
    /// runs past the end of the second.
    private static func backslashesBefore(_ index: Int, in nsString: NSString) -> Int {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, nsString.character(at: cursor) == 0x5C {
            count += 1
            cursor -= 1
        }
        return count
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
        if let quote = openingQuote,
            let closing = Self.unescapedIndex(of: quote, in: nsRest, from: 0)
        {
            end = closing
        }
        while end > 0, Self.isSpaceOrTab(nsRest, at: end - 1) { end -= 1 }
        guard end > 0 else { return nil }

        return schemeSkippedRange(in: nsRest.substring(to: end))
    }

    /// What follows the scheme word, or the whole of `value` when no scheme word
    /// introduces it. Nil when the value is nothing but a scheme word:
    /// `Authorization: Bearer` names no secret, and reporting the word itself
    /// is a false positive.
    ///
    /// A value that does not open with a listed scheme is taken whole, from its
    /// first character. Anything else exposes it — a leading word that is not
    /// in the list is the credential, not a scheme.
    ///
    /// The word is located in `value`'s own coordinates rather than measured
    /// from the constant. Taking the distance from the constant broke as soon
    /// as the separator was a tab or a run of spaces, and it did not fail
    /// safely: `Authorization: Bearer\tabc…` masked the word `Bearer` and left
    /// the token in the clear.
    static func schemeSkippedRange(in value: String) -> NSRange? {
        let nsValue = value as NSString
        guard nsValue.length > 0 else { return nil }
        let whole = NSRange(location: 0, length: nsValue.length)

        for word in schemeWords {
            let found = nsValue.range(
                of: word,
                options: [.caseInsensitive, .anchored],
                range: whole
            )
            guard found.location != NSNotFound else { continue }

            var cursor = found.length
            while cursor < nsValue.length, Self.isSpaceOrTab(nsValue, at: cursor) {
                cursor += 1
            }

            // `Bearer` with nothing after it introduces no value, and reporting
            // the word itself as a secret is a false positive.
            guard cursor < nsValue.length else { return nil }
            // `Bearerfoo` is not a scheme word introducing a value; treat the
            // whole thing as an opaque value rather than losing it.
            guard cursor > found.length else { break }
            return NSRange(location: cursor, length: nsValue.length - cursor)
        }
        return whole
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

    /// Steps over a scheme word for an ordinary slot, reporting how far it
    /// moved. Nil when the scheme word introduces no value at all.
    ///
    /// Shares `schemeSkippedRange` rather than repeating the lookup, so
    /// `schemeWords` stays the one answer to which words are schemes. A second
    /// copy would let this path and the Authorization path drift apart on that
    /// question with nothing to notice.
    static func skippingScheme(_ rest: String) -> (offset: Int, remainder: String)? {
        guard let value = schemeSkippedRange(in: rest) else { return nil }
        return (value.location, (rest as NSString).substring(from: value.location))
    }

    private static func isSpaceOrTab(_ nsString: NSString, at index: Int) -> Bool {
        let character = nsString.character(at: index)
        return character == 0x20 || character == 0x09
    }

    /// `$DB_PASSWORD` and `${AWS_SECRET}` say where the secret comes from;
    /// they are not the secret. Same reading as `<your-key-here>`, and the
    /// finding is lowered rather than dropped for the same reason.
    private static let variableReference = Pattern(
        #"^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)$"#
    )

    /// Values that cannot be a live credential.
    static func looksLikePlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count < 6 { return true }
        if trimmed.allSatisfy(\.isNumber) { return true }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return true }
        if !variableReference.matchRanges(in: trimmed).isEmpty { return true }
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
