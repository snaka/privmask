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

    /// Segments joined into one string for a single model call, truncated at
    /// `characterLimit`. Returns the joined text, the offset of each line within
    /// it, and whether anything was dropped.
    public struct Batch: Sendable {
        public let text: String
        /// Maps a range in `text` back to the original: for a match at location
        /// `l` in `text`, find the last entry whose `batchOffset <= l`.
        public let mapping: [(batchOffset: Int, originalOffset: Int, length: Int)]
        public let truncated: Bool
    }

    public static func batch(_ segments: [Segment], characterLimit: Int) -> Batch {
        var joined = ""
        var mapping: [(Int, Int, Int)] = []
        var truncated = false

        for segment in segments {
            let addition = joined.isEmpty ? segment.text : "\n" + segment.text
            let lineOffsetInBatch = (joined as NSString).length + (joined.isEmpty ? 0 : 1)
            if (joined as NSString).length + (addition as NSString).length > characterLimit {
                truncated = true
                break
            }
            joined += addition
            mapping.append((lineOffsetInBatch, segment.offset, (segment.text as NSString).length))
        }

        return Batch(text: joined, mapping: mapping, truncated: truncated)
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
