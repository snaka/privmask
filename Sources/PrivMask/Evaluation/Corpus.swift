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
        /// How a name is written and where it sits. Only the name corpus sets these.
        public let tags: [NameTag]?
    }

    public struct Sample: Decodable, Sendable {
        public let id: String
        public let note: String
        public let text: String
        public let expected: [Expectation]
        public let mustNotDetect: [String]
        public let genre: Genre?
        public let writer: Writer?
    }

    public let version: Int
    public let note: String
    /// User-registered terms assumed to be configured when evaluating this corpus.
    public let dictionary: [String]
    public let samples: [Sample]

    public static func load(contentsOf url: URL) throws -> Corpus {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: data)
    }
}

/// How a name in the name corpus is written, and where it sits.
///
/// A closed set: an unknown value fails to decode, which is the whole of the
/// vocabulary check. Recall is reported per value, so a misspelt tag would
/// otherwise make a row silently empty. Whether a name contains whitespace
/// (`spaced`) and whether it falls in a later model chunk (`late`) are computed
/// by `NameEvaluator`, not tagged: a tag can drift from the text, a computation
/// cannot.
public enum NameTag: String, Decodable, Sendable, CaseIterable {
    // Script.
    case kanji, hiragana, katakana, romaji, mixed
    // Form.
    case full, familyOnly, givenOnly
    // Marker.
    case honorific
}

/// The kind of text a sample imitates. `messy` is text broken on purpose: names
/// in log fields, dropped particles, mixed widths, a line break inside a name.
public enum Genre: String, Decodable, Sendable, CaseIterable {
    case incident, log, slack, markdown, email, messy
}

/// Who wrote a sample. Recorded so that a model's recall on text it wrote
/// itself can be compared with its recall on text others wrote. See #28.
public enum Writer: String, Decodable, Sendable, CaseIterable {
    case opus, sonnet, haiku, human
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
