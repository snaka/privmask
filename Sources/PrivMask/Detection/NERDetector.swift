import Foundation

/// Personal names found by the NER model trained in #43, run on device. See #46.
///
/// The rules here are `Scripts/ner/nerlib.py`'s, which produced the detections
/// the model was accepted on. A change to one is a change to the other, and
/// `NERParityTests` checks they still agree.
public struct NERDetector: Sendable {
    public typealias Tokenize = @Sendable (String) -> [XLMRTokenizer.Token]
    /// One label per id (0 O, 1 B-PER, 2 I-PER), for ids that begin with `<s>`
    /// and end with `</s>`.
    public typealias Predict = @Sendable ([Int32]) throws -> [Int]

    public enum Failure: Error, CustomStringConvertible {
        case labelCount(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .labelCount(let expected, let got): return "the model returned \(got) labels for \(expected) tokens"
            }
        }
    }

    /// Tokens per call, leaving room for `<s>` and `</s>`, and how many of them
    /// the next window repeats.
    static let window = 254
    static let overlap = 64

    private let tokenize: Tokenize
    private let clsID: Int32
    private let sepID: Int32
    private let predict: Predict
    private let words: Set<String>
    private let names: Set<String>

    public init(
        tokenize: @escaping Tokenize, clsID: Int32, sepID: Int32, predict: @escaping Predict,
        words: Set<String> = [], names: Set<String> = []
    ) {
        self.tokenize = tokenize
        self.clsID = clsID
        self.sepID = sepID
        self.predict = predict
        self.words = words
        self.names = names
    }

    public func detect(in text: String) throws -> [DetectedMatch] {
        var found: [DetectedMatch] = []
        var base = 0
        // components(separatedBy:), not split(separator:): Swift reads "\r\n"
        // as one Character, and nerlib splits on "\n" alone.
        for line in text.components(separatedBy: "\n") {
            defer { base += line.utf16.count + 1 }
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let nsLine = line as NSString
            for range in try spans(in: line) {
                let name = nsLine.substring(with: range)
                guard Self.plausible(name, words: words, names: names) else { continue }
                // Latin text passes the check the model layer's does (#32, #40).
                guard JapaneseText.containsJapanese(name) || LatinNameShape.isNameShaped(name) else { continue }
                found.append(DetectedMatch(
                    kind: .personalName, source: .ner,
                    range: NSRange(location: base + range.location, length: range.length), text: name))
            }
        }
        return found
    }

    /// Names in one line, windowing a line longer than the model takes.
    func spans(in line: String) throws -> [NSRange] {
        let tokens = tokenize(line)
        var found: [NSRange] = []
        var start = 0
        while true {
            let chunk = tokens[start..<min(tokens.count, start + Self.window)]
            let labels = try predict([clsID] + chunk.map(\.id) + [sepID])
            guard labels.count == chunk.count + 2 else {
                throw Failure.labelCount(expected: chunk.count + 2, got: labels.count)
            }
            found += Self.spans(from: chunk.map(\.range), labels: Array(labels.dropFirst().dropLast()))
            if start + Self.window >= tokens.count { return Self.merge(found) }
            start += Self.window - Self.overlap
        }
    }

    /// B starts a name; I continues it, and starts one when nothing is open.
    static func spans(from ranges: [NSRange], labels: [Int]) -> [NSRange] {
        var spans: [NSRange] = []
        var open = false
        for (range, label) in zip(ranges, labels) {
            if range.length == 0 {
                open = false
            } else if label == 1 || (label == 2 && !open) {
                spans.append(range)
                open = true
            } else if label == 2 {
                let last = spans.removeLast()
                spans.append(NSRange(location: last.location, length: NSMaxRange(range) - last.location))
            } else {
                open = false
            }
        }
        return spans
    }

    static func merge(_ spans: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for span in spans.sorted(by: { ($0.location, NSMaxRange($0)) < ($1.location, NSMaxRange($1)) }) {
            if let last = out.last, span.location < NSMaxRange(last) {
                out[out.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(span)) - last.location)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Whether a merged span may be a name: nerlib's `plausible`, in its order.
    /// On the span NFKC-folded, with lengths in code points: no letter, drop; one
    /// character with a word list given, keep only a listed name; exactly a word
    /// and not a listed name, drop. Then, on the span as written: a single kana,
    /// drop; an all-capitals ASCII word, drop.
    static func plausible(_ text: String, words: Set<String>, names: Set<String>) -> Bool {
        let folded = text.precomposedStringWithCompatibilityMapping
        let isLetter: (Unicode.Scalar) -> Bool = {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
        guard folded.unicodeScalars.contains(where: isLetter) else { return false }
        if folded.unicodeScalars.count == 1, !words.isEmpty, !names.contains(folded) { return false }
        if words.contains(folded), !names.contains(folded) { return false }
        let scalars = Array(text.unicodeScalars)
        if scalars.count == 1, (0x3040...0x30FF).contains(scalars[0].value) || (0xFF66...0xFF9D).contains(scalars[0].value) {
            return false
        }
        if scalars.count > 1, scalars.allSatisfy({ (0x41...0x5A).contains($0.value) }) { return false }
        return true
    }
}
