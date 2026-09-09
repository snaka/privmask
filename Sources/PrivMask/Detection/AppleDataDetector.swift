import Foundation

/// Wraps `NSDataDetector`, which uses Apple's own models rather than regular
/// expressions for phone numbers and addresses.
///
/// Note: `NSDataDetector` does not report bare email addresses — it only sees
/// them inside `mailto:` links — so email needs a separate regex detector.
public struct AppleDataDetector {
    /// Types reported as sensitive matches.
    private static let sensitiveTypes: NSTextCheckingResult.CheckingType = [.phoneNumber, .address]

    /// Types collected only to observe false-positive pressure (dates and links
    /// are not masked, but we want to know when they overlap something we mask).
    private static let observedTypes: NSTextCheckingResult.CheckingType = [.date, .link]

    public init() {}

    /// Detects phone numbers and addresses.
    public func detect(in text: String) -> [DetectedMatch] {
        matches(in: text, types: Self.sensitiveTypes)
    }

    /// Detects dates and links. Not masked; reported by the probe as context.
    public func observations(in text: String) -> [(type: String, range: NSRange, text: String)] {
        guard let detector = try? NSDataDetector(types: Self.observedTypes.rawValue) else { return [] }
        let nsText = text as NSString
        let scanned = Self.detectorFriendly(text)
        var results: [(String, NSRange, String)] = []
        detector.enumerateMatches(in: scanned, range: NSRange(location: 0, length: nsText.length)) { result, _, _ in
            guard let result else { return }
            let label: String
            switch result.resultType {
            case .date: label = "date"
            case .link: label = "link"
            default: return
            }
            results.append((label, result.range, nsText.substring(with: result.range)))
        }
        return results
    }

    /// Rejects matches that cannot be what the detector says they are.
    ///
    /// A run of digits with no separator and no country code is only a phone
    /// number at Japanese lengths: 10 (03-1234-5678, 0120-123-456) or 11
    /// (090-1234-5678). NSDataDetector claimed the 12-digit order number
    /// `123456789010` as a phone number, which would have masked it. Matches
    /// that carry separators or a leading + are left alone, so an international
    /// number written normally is unaffected.
    static func isPlausible(kind: SensitiveKind, text: String) -> Bool {
        guard kind == .phoneNumber else { return true }
        let normalized = MyNumberDetector.normalizeDigits(text)
        guard normalized.allSatisfy(\.isNumber) else { return true }
        return (10...11).contains(normalized.count)
    }

    /// Cuts `range` back to its first line and drops trailing whitespace.
    /// Returns nil if nothing is left.
    static func trimmedToFirstLine(_ range: NSRange, in text: NSString) -> NSRange? {
        var end = range.location + range.length
        let newline = text.range(of: "\n", range: range)
        if newline.location != NSNotFound {
            end = newline.location
        }
        while end > range.location {
            let scalar = text.substring(with: NSRange(location: end - 1, length: 1)).unicodeScalars.first
            guard let scalar, CharacterSet.whitespaces.contains(scalar) else { break }
            end -= 1
        }
        let length = end - range.location
        return length > 0 ? NSRange(location: range.location, length: length) : nil
    }

    /// Japanese punctuation that stops the detector, mapped to ASCII equivalents.
    ///
    /// A phone number followed directly by an ideographic comma is not detected
    /// at all — and `連絡先 090-1234-5678、住所は…` is an ordinary sentence, not an
    /// edge case. Followed by a space or `。` the same number is found, so it is
    /// the comma specifically.
    ///
    /// Both characters occupy one UTF-16 unit, so substituting them leaves every
    /// offset unchanged and matches still refer to the original text.
    private static let punctuationSubstitutions: [Character: Character] = [
        "、": ",",
        "，": ",",
    ]

    /// A copy of `text` the detector can parse, with identical offsets.
    /// Returns the original unchanged if the lengths would ever diverge.
    static func detectorFriendly(_ text: String) -> String {
        guard text.contains(where: { punctuationSubstitutions[$0] != nil }) else { return text }
        let substituted = String(text.map { punctuationSubstitutions[$0] ?? $0 })
        guard (substituted as NSString).length == (text as NSString).length else { return text }
        return substituted
    }

    private func matches(in text: String, types: NSTextCheckingResult.CheckingType) -> [DetectedMatch] {
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let nsText = text as NSString
        let scanned = Self.detectorFriendly(text)
        var results: [DetectedMatch] = []
        detector.enumerateMatches(in: scanned, range: NSRange(location: 0, length: nsText.length)) { result, _, _ in
            guard let result else { return }
            let kind: SensitiveKind
            switch result.resultType {
            case .phoneNumber: kind = .phoneNumber
            case .address: kind = .address
            default: return
            }
            // The detector will run a phone-number match across a newline and
            // swallow unrelated trailing digits, so every match is cut back to
            // the line it starts on. See docs/findings/apple-detector-baseline.md.
            guard let range = Self.trimmedToFirstLine(result.range, in: nsText) else { return }
            guard Self.isPlausible(kind: kind, text: nsText.substring(with: range)) else { return }
            results.append(
                DetectedMatch(
                    kind: kind,
                    source: .dataDetector,
                    range: range,
                    text: nsText.substring(with: range)
                )
            )
        }
        return results
    }
}
