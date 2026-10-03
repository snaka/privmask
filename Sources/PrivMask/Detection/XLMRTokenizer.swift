import Foundation

/// The XLM-R SentencePiece tokenizer the NER model was trained with, read from
/// the `tokenizer.json` that `Scripts/ner/export.py` writes. See #46.
///
/// It reproduces what Hugging Face `tokenizers` does with that file: the
/// `Precompiled` normalizer, `WhitespaceSplit` then `Metaspace` (a `▁` before
/// every word), and Unigram. Its output is checked against Hugging Face's on
/// every line of the name corpus (`XLMRTokenizerTests`); the two must not drift.
///
/// ponytail: a literal `<s>` or `<unk>` in the input is tokenized as text, where
/// Hugging Face would emit the special token. Logs do not contain them.
public struct XLMRTokenizer: Sendable {
    public struct Token: Equatable, Sendable {
        public let id: Int32
        /// UTF-16 range in the line. Empty for a lone word-boundary piece (`▁`),
        /// which covers no text.
        public let range: NSRange
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unsupported(String)
        public var description: String {
            switch self {
            case .unsupported(let what): return "tokenizer.json is not the XLM-R Unigram tokenizer: \(what)"
            }
        }
    }

    public let clsID: Int32
    public let sepID: Int32
    private let pieces: [[UInt8]: Piece]
    private let longestPiece: Int  // in Unicode scalars
    private let unknownID: Int32
    private let unknownScore: Double
    private let charsmap: PrecompiledCharsmap

    private struct Piece: Sendable { let id: Int32; let score: Double }

    public init(contentsOf url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        guard let model = json["model"] as? [String: Any], model["type"] as? String == "Unigram" else {
            throw LoadError.unsupported("model is not Unigram")
        }
        guard (model["byte_fallback"] as? Bool ?? false) == false else { throw LoadError.unsupported("byte_fallback") }
        guard let vocab = model["vocab"] as? [[Any]], let unknown = model["unk_id"] as? Int else {
            throw LoadError.unsupported("no vocab or unk_id")
        }
        guard let normalizer = json["normalizer"] as? [String: Any], normalizer["type"] as? String == "Precompiled",
            let encoded = normalizer["precompiled_charsmap"] as? String, let map = Data(base64Encoded: encoded)
        else { throw LoadError.unsupported("normalizer is not Precompiled") }
        let special = Set(((json["added_tokens"] as? [[String: Any]]) ?? []).compactMap { $0["content"] as? String })

        var pieces: [[UInt8]: Piece] = [:]
        var longest = 1
        var minimum = 0.0
        var ids: [String: Int32] = [:]
        for (index, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.doubleValue else {
                throw LoadError.unsupported("vocab entry \(index)")
            }
            minimum = min(minimum, score)
            ids[piece] = Int32(index)
            guard !special.contains(piece) else { continue }
            pieces[Array(piece.utf8)] = Piece(id: Int32(index), score: score)
            longest = max(longest, piece.unicodeScalars.count)
        }
        guard let cls = ids["<s>"], let sep = ids["</s>"] else { throw LoadError.unsupported("no <s> or </s>") }
        self.pieces = pieces
        self.longestPiece = longest
        self.unknownID = Int32(unknown)
        self.unknownScore = minimum - 10  // tokenizers' K_UNK_PENALTY
        self.clsID = cls
        self.sepID = sep
        self.charsmap = try PrecompiledCharsmap(map)
    }

    /// Tokens for one line, without `<s>` and `</s>`.
    public func encode(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var word: [Normalized] = []
        var offset = 0
        for character in line {
            for item in charsmap.normalize(character, at: offset) {
                if item.scalar.properties.isWhitespace {
                    if !word.isEmpty { tokens += encode(word: word); word = [] }
                } else {
                    word.append(item)
                }
            }
            offset += character.utf16.count
        }
        if !word.isEmpty { tokens += encode(word: word) }
        return tokens
    }

    /// Viterbi over `▁` + the word, as Unigram does.
    private func encode(word: [Normalized]) -> [Token] {
        let scalars = [Unicode.Scalar(0x2581)!] + word.map(\.scalar)
        let count = scalars.count
        // best[end]: the best path ending at `end`, as (score, start of its last piece, that piece's id).
        var best = [(score: Double, start: Int, id: Int32)?](repeating: nil, count: count + 1)
        best[0] = (0, 0, -1)
        for start in 0..<count {
            guard let reached = best[start] else { continue }
            var key: [UInt8] = []
            var hasSingle = false
            for end in (start + 1)...min(count, start + longestPiece) {
                key += Array(String(scalars[end - 1]).utf8)
                guard let piece = pieces[key] else { continue }
                if end == start + 1 { hasSingle = true }
                let score = reached.score + piece.score
                if best[end] == nil || score > best[end]!.score { best[end] = (score, start, piece.id) }
            }
            if !hasSingle {
                let score = reached.score + unknownScore
                if best[start + 1] == nil || score > best[start + 1]!.score { best[start + 1] = (score, start, unknownID) }
            }
        }

        var path: [(id: Int32, start: Int, end: Int)] = []
        var end = count
        while end > 0, let node = best[end] {
            // Consecutive unknown pieces are one token (tokenizers' fuse_unk).
            if node.id == unknownID, let last = path.last, last.id == unknownID {
                path[path.count - 1] = (unknownID, node.start, last.end)
            } else {
                path.append((node.id, node.start, end))
            }
            end = node.start
        }
        return path.reversed().map { piece in
            // Scalar 0 is the `▁` this added; it covers no text.
            let covered = word[max(piece.start, 1) - 1..<max(piece.end - 1, 0)].map(\.source)
            guard let first = covered.first else {
                let after = NSMaxRange(word[0].source)
                return Token(id: piece.id, range: NSRange(location: after, length: 0))
            }
            let upper = covered.map(NSMaxRange).max()!
            return Token(id: piece.id, range: NSRange(location: first.location, length: upper - first.location))
        }
    }
}

/// One scalar of normalized text, and the UTF-16 range of the input it came from.
struct Normalized: Sendable {
    let scalar: Unicode.Scalar
    let source: NSRange
}

/// SentencePiece's precompiled normalization map: a darts-clone double-array
/// trie over UTF-8, then the replacement strings, NUL-terminated. Read as the
/// `spm_precompiled` crate reads it, because Hugging Face's output is the
/// reference.
struct PrecompiledCharsmap: Sendable {
    private let units: [UInt32]
    private let replacements: [UInt8]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 4 else { throw XLMRTokenizer.LoadError.unsupported("charsmap too short") }
        let size = Int(word(0))
        guard size % 4 == 0, size > 0, 4 + size <= bytes.count else {
            throw XLMRTokenizer.LoadError.unsupported("charsmap trie size")
        }
        units = stride(from: 4, to: 4 + size, by: 4).map(word)
        replacements = Array(bytes[(4 + size)...])
    }

    /// As `tokenizers`' Precompiled normalizer: the grapheme whole when it is
    /// short and listed, otherwise each scalar, unchanged when unlisted. Every
    /// output scalar keeps the range of what it replaced.
    func normalize(_ character: Character, at offset: Int) -> [Normalized] {
        let grapheme = String(character)
        if grapheme.utf8.count < 6, let replaced = transform(grapheme) {
            let range = NSRange(location: offset, length: grapheme.utf16.count)
            return replaced.unicodeScalars.map { Normalized(scalar: $0, source: range) }
        }
        var out: [Normalized] = []
        var at = offset
        for scalar in grapheme.unicodeScalars {
            let range = NSRange(location: at, length: UTF16.width(scalar))
            let text = String(scalar)
            out += (transform(text) ?? text).unicodeScalars.map { Normalized(scalar: $0, source: range) }
            at += range.length
        }
        return out
    }

    /// The replacement for the first listed prefix of `text`, as
    /// `spm_precompiled`'s `transform` returns it.
    func transform(_ text: String) -> String? {
        var position = 0
        var unit = units[0]
        position ^= Self.offset(unit)
        for byte in text.utf8 {
            position ^= Int(byte)
            guard position >= 0, position < units.count else { return nil }
            unit = units[position]
            guard Self.label(unit) == UInt32(byte) else { return nil }
            position ^= Self.offset(unit)
            guard position < units.count else { return nil }
            if Self.hasLeaf(unit) {
                let start = Int(Self.value(units[position]))
                guard start < replacements.count else { return nil }
                let end = replacements[start...].firstIndex(of: 0) ?? replacements.endIndex
                return String(decoding: replacements[start..<end], as: UTF8.self)
            }
        }
        return nil
    }

    private static func hasLeaf(_ unit: UInt32) -> Bool { (unit >> 8) & 1 == 1 }
    private static func value(_ unit: UInt32) -> UInt32 { unit & 0x7FFF_FFFF }
    private static func label(_ unit: UInt32) -> UInt32 { unit & (0x8000_0000 | 0xFF) }
    private static func offset(_ unit: UInt32) -> Int { Int((unit >> 10) << ((unit & (1 << 9)) >> 6)) }
}
