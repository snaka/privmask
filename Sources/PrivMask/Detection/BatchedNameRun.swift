import Foundation

/// Running the name model over several chunks and putting the answers back
/// where they came from.
///
/// This is deliberately separate from the model itself: the model call arrives
/// as a closure, so the part with the interesting failure modes — a chunk that
/// throws, a span that does not occur in what was sent, an offset that has to
/// survive being joined and split — can be tested without Apple Intelligence,
/// and on a machine that does not have it.
public enum BatchedNameRun {
    /// A chunk that was never examined.
    ///
    /// It names the chunk rather than a range of the original text, because a
    /// chunk is a join of the Japanese-bearing lines that fit in it and those
    /// lines need not be adjacent.
    public struct ChunkFailure: Sendable, Equatable {
        /// 1-based, as it is spoken about.
        public let index: Int
        public let total: Int
        public let characters: Int
        public let reason: String

        public init(index: Int, total: Int, characters: Int, reason: String) {
            self.index = index
            self.total = total
            self.characters = characters
            self.reason = reason
        }
    }

    public struct Result: Sendable {
        public let matches: [DetectedMatch]
        /// Spans the model returned that do not occur in what was sent. Dropped,
        /// but counted: a rising number means the prompt is inviting paraphrase.
        public let ungroundedTexts: [String]
        public let failures: [ChunkFailure]
    }

    /// Asks `respond` for the names in each chunk, and maps what comes back to
    /// the original text.
    ///
    /// `respond` returns spans the caller already considers name-shaped; this
    /// only decides whether they are really there and where. Every chunk is
    /// attempted: one failure costs that chunk, not the run.
    public static func run(
        text: String,
        batches: [JapaneseText.Batch],
        respond: (String) async throws -> [String]
    ) async -> Result {
        let original = text as NSString
        var matches: [DetectedMatch] = []
        var ungrounded: [String] = []
        var failures: [ChunkFailure] = []

        for (offset, batch) in batches.enumerated() {
            let spans: [String]
            do {
                spans = try await respond(batch.text)
            } catch {
                failures.append(
                    ChunkFailure(
                        index: offset + 1,
                        total: batches.count,
                        characters: batch.text.count,
                        reason: "\(error)"
                    )
                )
                continue
            }

            let batchText = batch.text as NSString
            for span in spans {
                let hits = occurrences(of: span, in: batchText)
                if hits.isEmpty {
                    ungrounded.append(span)
                    continue
                }
                for hit in hits {
                    guard let range = batch.originalRange(for: hit) else { continue }
                    matches.append(
                        DetectedMatch(
                            kind: .personalName,
                            source: .languageModel,
                            range: range,
                            text: original.substring(with: range)
                        )
                    )
                }
            }
        }

        return Result(matches: matches, ungroundedTexts: ungrounded, failures: failures)
    }

    private static func occurrences(of needle: String, in haystack: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = []
        var cursor = 0
        while cursor < haystack.length {
            let searchRange = NSRange(location: cursor, length: haystack.length - cursor)
            let range = haystack.range(of: needle, range: searchRange)
            if range.location == NSNotFound { break }
            found.append(range)
            cursor = range.location + max(range.length, 1)
        }
        return found
    }
}
