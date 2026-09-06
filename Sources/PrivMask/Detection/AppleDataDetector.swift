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
        var results: [(String, NSRange, String)] = []
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { result, _, _ in
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

    private func matches(in text: String, types: NSTextCheckingResult.CheckingType) -> [DetectedMatch] {
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let nsText = text as NSString
        var results: [DetectedMatch] = []
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { result, _, _ in
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
