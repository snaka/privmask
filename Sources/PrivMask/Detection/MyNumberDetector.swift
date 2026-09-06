import Foundation

/// Detects Japanese Individual Numbers (マイナンバー).
///
/// Twelve digits with a check digit, so a candidate can be verified rather than
/// guessed at. That makes this both high confidence and nearly free of false
/// positives — which is why it is worth having even though the number rarely
/// appears in developer text: when it does appear, it is the worst thing in the
/// text to leak.
///
/// NSDataDetector claims a bare 12-digit number as a phone number, so this
/// detector has to win when the ranges collide. `DetectionPipeline` enforces
/// that precedence.
public struct MyNumberDetector {
    public init() {}

    private static let candidates = Pattern(#"(?<![0-9０-９])[0-9０-９]{12}(?![0-9０-９])"#)

    public func detect(in text: String) -> [DetectedMatch] {
        let nsText = text as NSString
        return Self.candidates.matchRanges(in: text).compactMap { range in
            let raw = nsText.substring(with: range)
            guard Self.isValid(Self.normalizeDigits(raw)) else { return nil }
            return DetectedMatch(kind: .myNumber, source: .regex, range: range, text: raw)
        }
    }

    /// Full-width digits are common in Japanese documents; normalise before
    /// arithmetic.
    static func normalizeDigits(_ text: String) -> String {
        String(
            text.unicodeScalars.map { scalar in
                (0xFF10...0xFF19).contains(scalar.value)
                    ? Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
                    : Character(scalar)
            }
        )
    }

    /// Check digit per the Individual Number regulation: the last digit is
    /// derived from the preceding eleven.
    ///
    ///     check = 11 - (Σ Pₙ × Qₙ) mod 11,  and 0 when that yields 10 or 11
    ///     Pₙ = the nth digit from the right of the 11-digit body
    ///     Qₙ = n + 1 for 1…6, n - 5 for 7…11
    static func isValid(_ digits: String) -> Bool {
        let values = digits.compactMap { $0.wholeNumberValue }
        guard values.count == 12 else { return false }

        let body = Array(values[0..<11])
        let stated = values[11]

        var sum = 0
        for n in 1...11 {
            let p = body[11 - n]
            let q = n <= 6 ? n + 1 : n - 5
            sum += p * q
        }

        let remainder = sum % 11
        let expected = remainder <= 1 ? 0 : 11 - remainder
        return expected == stated
    }
}
