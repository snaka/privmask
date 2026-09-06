import Foundation

/// Matches user-registered terms: customer names, company names, project code
/// names — the things no general detector can know are sensitive.
///
/// Matching is exact, but insensitive to case and to character width, because
/// Japanese text mixes full-width and half-width forms freely. Searching is done
/// against the original string so that reported ranges always refer to it.
///
/// Variant forms (株式会社アクメ / アクメ社 / Acme) are not derived automatically:
/// that is left to the language model layer, and where the model is unavailable
/// the UI says so rather than pretending the dictionary was fully applied.
public struct DictionaryDetector {
    private let terms: [String]

    public init(terms: [String]) {
        // Longest first, so that a longer registered term wins over a shorter one
        // it contains.
        self.terms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public func detect(in text: String) -> [DetectedMatch] {
        guard !terms.isEmpty else { return [] }
        let nsText = text as NSString
        var matches: [DetectedMatch] = []
        var claimed: [NSRange] = []

        for term in terms {
            var cursor = 0
            while cursor < nsText.length {
                let searchRange = NSRange(location: cursor, length: nsText.length - cursor)
                let range = nsText.range(
                    of: term,
                    options: [.caseInsensitive, .widthInsensitive],
                    range: searchRange
                )
                if range.location == NSNotFound { break }
                cursor = range.location + max(range.length, 1)
                // A shorter term inside an already-matched longer one is not a
                // separate finding.
                guard !claimed.contains(where: { rangesOverlap($0, range) }) else { continue }
                claimed.append(range)
                matches.append(
                    DetectedMatch(
                        kind: .dictionaryTerm,
                        source: .dictionary,
                        range: range,
                        text: nsText.substring(with: range)
                    )
                )
            }
        }
        return matches
    }
}
