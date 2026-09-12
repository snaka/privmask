import Foundation

/// Splitting text by script.
///
/// The on-device model refuses input whose language it cannot identify, and a
/// timestamped log line mixed into Japanese is identified as Indonesian. Feeding
/// it only the lines that actually contain Japanese avoids that, and keeps the
/// input inside the model's context window. See
/// docs/findings/on-device-model-baseline.md.
public enum JapaneseText {
    public static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isJapaneseScalar)
    }

    static func isJapaneseScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,  // hiragana, katakana
            0x3400...0x4DBF,  // CJK extension A
            0x4E00...0x9FFF,  // CJK unified ideographs
            0xF900...0xFAFF,  // CJK compatibility ideographs
            0xFF66...0xFF9D:  // half-width katakana
            return true
        default:
            return false
        }
    }

    /// A run of the original text, carrying the offset it came from so that
    /// matches found inside it can be mapped back.
    public struct Segment: Sendable {
        public let text: String
        /// Location of this segment's first character in the original string,
        /// in UTF-16 offsets.
        public let offset: Int
    }

    /// The lines containing Japanese, each kept as its own segment so that ranges
    /// map back exactly. Lines are not joined: joining would make offsets depend
    /// on the separator and invite off-by-one errors.
    public static func japaneseLines(of text: String) -> [Segment] {
        var segments: [Segment] = []
        let nsText = text as NSString
        var lineStart = 0

        while lineStart <= nsText.length {
            let searchRange = NSRange(location: lineStart, length: nsText.length - lineStart)
            let newline = nsText.range(of: "\n", range: searchRange)
            let lineEnd = newline.location == NSNotFound ? nsText.length : newline.location
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let line = nsText.substring(with: lineRange)
            if containsJapanese(line) {
                segments.append(Segment(text: line, offset: lineStart))
            }
            if newline.location == NSNotFound { break }
            lineStart = newline.location + newline.length
        }
        return segments
    }

    /// Ends a sentence. Cutting after one of these leaves both pieces readable.
    /// Held as UTF-16 code units because that is what `NSString.character(at:)`
    /// returns, and every one of them is a single unit.
    private static let sentenceEnds: Set<unichar> = Set("。！？!?".utf16)

    /// Ends a clause. Second choice: the pieces are fragments of a sentence, but
    /// a name is not split across one.
    private static let clauseEnds: Set<unichar> = Set("、，,；;　 ".utf16)

    /// A line broken into pieces that each fit one model call.
    ///
    /// `japaneseLines` works a line at a time, which suits a log and not a
    /// markdown document, where a paragraph is one line and can be longer than
    /// anything the model will accept. Nothing here is dropped: the pieces
    /// concatenate back to the line, and each carries the offset it came from so
    /// that a match inside it still maps to the original text.
    ///
    /// The hard cut is the last resort, and it can land inside a name — neither
    /// half is then recognisable and the name is missed with nothing to say so.
    /// It only happens on an unbroken run of Japanese longer than a chunk, which
    /// prose does not produce; it is there so that pathological input degrades
    /// instead of being skipped.
    public static func splitToFit(_ segment: Segment, characterLimit: Int) -> [Segment] {
        guard characterLimit > 0 else { return [segment] }
        let text = segment.text as NSString
        guard text.length > characterLimit else { return [segment] }

        var pieces: [Segment] = []
        var start = 0
        while start < text.length {
            let end =
                text.length - start <= characterLimit
                ? text.length
                : breakPoint(in: text, window: NSRange(location: start, length: characterLimit))
            pieces.append(
                Segment(
                    text: text.substring(with: NSRange(location: start, length: end - start)),
                    offset: segment.offset + start
                )
            )
            start = end
        }
        return pieces
    }

    /// The offset to cut at, always within `window` and always past its start so
    /// that the walk terminates.
    ///
    /// One backward pass: the first sentence end it meets is the rightmost one
    /// and wins immediately; the rightmost clause end is remembered in case
    /// there is no sentence end at all.
    private static func breakPoint(in text: NSString, window: NSRange) -> Int {
        var clause: Int?
        var index = NSMaxRange(window) - 1
        while index > window.location {
            let unit = text.character(at: index)
            if sentenceEnds.contains(unit) { return index + 1 }
            if clause == nil, clauseEnds.contains(unit) { clause = index + 1 }
            index -= 1
        }
        return clause ?? NSMaxRange(window)
    }

    /// Segments joined into one string for a single model call. Carries the
    /// offset of each piece within it, so a match found in the joined text maps
    /// back to where it sits in the original.
    public struct Batch: Sendable {
        public let text: String
        /// Maps a range in `text` back to the original: for a match at location
        /// `l` in `text`, find the last entry whose `batchOffset <= l`.
        public let mapping: [(batchOffset: Int, originalOffset: Int, length: Int)]
    }

    /// A chunk smaller than this is not worth a call of its own.
    ///
    /// The model, handed a fragment with no names in it and asked for a list,
    /// has been measured generating until the context window was exhausted —
    /// most of a minute, for four characters. A trailing crumb is carried by the
    /// call before it instead. See docs/findings/on-device-model-baseline.md.
    public static let defaultMinimumChunkCharacters = 32

    /// Every segment, packed into as many calls as it takes.
    ///
    /// Nothing is dropped. The layer this replaces packed whole lines and
    /// stopped at the first that would not fit, which on a markdown document —
    /// where a paragraph is one line — could skip most of the text or all of it.
    /// The cost is that a long input takes proportionally longer: the on-device
    /// model serialises, so the calls cannot be overlapped.
    public static func batches(
        _ segments: [Segment],
        characterLimit: Int,
        minimumChunkCharacters: Int = defaultMinimumChunkCharacters
    ) -> [Batch] {
        let pieces = segments.flatMap { splitToFit($0, characterLimit: characterLimit) }
        guard !pieces.isEmpty else { return [] }

        var groups: [[Segment]] = []
        var current: [Segment] = []
        var currentLength = 0

        for piece in pieces {
            let length = (piece.text as NSString).length
            if !current.isEmpty, currentLength + length + 1 > characterLimit {
                groups.append(current)
                current = []
                currentLength = 0
            }
            currentLength += current.isEmpty ? length : length + 1  // the joining newline
            current.append(piece)
        }
        if !current.isEmpty { groups.append(current) }

        return merged(groups, minimumChunkCharacters: minimumChunkCharacters).map(build)
    }

    /// Groups too small to send on their own, joined to a neighbour.
    ///
    /// A group closes when the *next* piece will not fit, so an undersized one
    /// turns up anywhere — a short heading before a long paragraph is left alone
    /// exactly as a short trailing line is, and a heading before a paragraph is
    /// the ordinary shape of a markdown document. Overshooting the limit by less
    /// than the minimum is safe; sending a crumb is not.
    private static func merged(_ groups: [[Segment]], minimumChunkCharacters: Int) -> [[Segment]] {
        var merged: [[Segment]] = []
        for group in groups {
            let previousIsCrumb = merged.last.map {
                joinedLength($0) < minimumChunkCharacters
            } ?? false
            if previousIsCrumb || (!merged.isEmpty && joinedLength(group) < minimumChunkCharacters) {
                merged[merged.count - 1].append(contentsOf: group)
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    /// The length the group will have once joined with newlines.
    private static func joinedLength(_ group: [Segment]) -> Int {
        group.reduce(0) { $0 + ($1.text as NSString).length + 1 } - 1
    }

    private static func build(_ group: [Segment]) -> Batch {
        var joined = ""
        var mapping: [(Int, Int, Int)] = []
        // Tracked rather than re-measured: `joined` is mutated every iteration,
        // so asking it for its UTF-16 length again would rescan the whole string
        // each time.
        var offset = 0
        for segment in group {
            if !joined.isEmpty {
                joined += "\n"
                offset += 1
            }
            let length = (segment.text as NSString).length
            mapping.append((offset, segment.offset, length))
            joined += segment.text
            offset += length
        }
        return Batch(text: joined, mapping: mapping)
    }
}

extension JapaneseText.Batch {
    /// Translates a range found in the batch text back to the original text.
    /// Returns nil if the range straddles a line boundary, which would make the
    /// mapping meaningless.
    public func originalRange(for range: NSRange) -> NSRange? {
        guard
            let entry = mapping.last(where: { $0.batchOffset <= range.location })
        else { return nil }
        let offsetInLine = range.location - entry.batchOffset
        guard offsetInLine + range.length <= entry.length else { return nil }
        return NSRange(location: entry.originalOffset + offsetInLine, length: range.length)
    }
}
