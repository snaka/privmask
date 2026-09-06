import Foundation

/// A ground-truth corpus: text samples annotated with what must be detected and
/// what must never be masked.
///
/// Negative examples matter as much as positive ones. Over-masking destroys the
/// text being shared, and a detector that improves recall by masking everything
/// is not an improvement.
public struct Corpus: Decodable, Sendable {
    public struct Expectation: Decodable, Sendable {
        public let kind: SensitiveKind
        public let text: String
    }

    public struct Sample: Decodable, Sendable {
        public let id: String
        public let note: String
        public let text: String
        public let expected: [Expectation]
        public let mustNotDetect: [String]
    }

    public let version: Int
    public let note: String
    /// User-registered terms assumed to be configured when evaluating this corpus.
    public let dictionary: [String]
    public let samples: [Sample]

    public static func load(contentsOf url: URL) throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}

// MARK: - Range helpers

extension NSString {
    /// Every range at which `needle` occurs.
    func allRanges(of needle: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = []
        var cursor = 0
        while cursor < length {
            let searchRange = NSRange(location: cursor, length: length - cursor)
            let range = range(of: needle, range: searchRange)
            if range.location == NSNotFound { break }
            found.append(range)
            cursor = range.location + max(range.length, 1)
        }
        return found
    }
}

func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
    NSIntersectionRange(a, b).length > 0
}
