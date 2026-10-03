import Foundation
import Testing

@testable import PrivMask

/// The rules `Scripts/ner/nerlib.py` applies to the model's labels, ported. The
/// accepted detections came from those rules, so these cases are nerlib's
/// `check()`, one for one, plus what Swift's strings make easy to get wrong.
/// See #43 and #46.
@Suite("NER labels become names as nerlib makes them")
struct NERDetectorTests {
    /// One token per UTF-16 unit of the line, so labels can be written by
    /// position. ids are positions, so a predict closure can label by them.
    static let perUnit: NERDetector.Tokenize = { line in
        (0..<line.utf16.count).map { XLMRTokenizer.Token(id: Int32($0), range: NSRange(location: $0, length: 1)) }
    }

    static func detector(
        labelling: @escaping @Sendable (Int32) -> Int,
        words: Set<String> = [],
        names: Set<String> = [],
        calls: Counter? = nil
    ) -> NERDetector {
        NERDetector(
            tokenize: perUnit, clsID: -1, sepID: -2,
            predict: { ids in
                calls?.increment()
                return ids.map { $0 < 0 ? 0 : labelling($0) }
            },
            words: words, names: names)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    static func r(_ a: Int, _ b: Int) -> NSRange { NSRange(location: a, length: b - a) }

    @Test("B starts a name and I continues it")
    func bThenI() {
        #expect(NERDetector.spans(from: [Self.r(0, 2), Self.r(2, 4), Self.r(4, 5)], labels: [1, 2, 0]) == [Self.r(0, 4)])
    }

    @Test("I with nothing open starts a name")
    func loneI() {
        #expect(NERDetector.spans(from: [Self.r(0, 2), Self.r(2, 4)], labels: [2, 2]) == [Self.r(0, 4)])
    }

    @Test("An empty token closes a name and is never part of one")
    func emptyToken() {
        #expect(NERDetector.spans(from: [NSRange(location: 0, length: 0), Self.r(0, 2)], labels: [1, 1]) == [Self.r(0, 2)])
    }

    @Test("Overlapping spans merge and adjacent ones stay apart")
    func merging() {
        #expect(NERDetector.merge([Self.r(0, 4), Self.r(2, 6), Self.r(8, 9)]) == [Self.r(0, 6), Self.r(8, 9)])
        #expect(NERDetector.merge([Self.r(0, 2), Self.r(2, 4)]) == [Self.r(0, 2), Self.r(2, 4)])
    }

    @Test("plausible() keeps and drops what nerlib does")
    func plausibleRules() {
        let words: Set<String> = ["内線", "クエリ", "森", "本"]
        let names: Set<String> = ["森", "佐古"]
        #expect(!NERDetector.plausible("内線", words: words, names: names))
        #expect(!NERDetector.plausible("クエリ", words: words, names: names))
        #expect(NERDetector.plausible("森", words: words, names: names), "a word that is also a family name is kept")
        #expect(NERDetector.plausible("佐古宗直", words: words, names: names))
        #expect(NERDetector.plausible("田中", words: words, names: names))
        #expect(!NERDetector.plausible("ｸｴﾘ", words: words, names: names), "half-width katakana is folded first")
        #expect(!NERDetector.plausible("_", words: words, names: names))
        #expect(!NERDetector.plausible("達", words: words, names: names), "a lone unlisted character")
        #expect(!NERDetector.plausible("が", words: [], names: []))
        #expect(!NERDetector.plausible("ｶ", words: [], names: []))
        #expect(!NERDetector.plausible("MEDIUM", words: [], names: []))
        #expect(NERDetector.plausible("林", words: [], names: []))
        #expect(NERDetector.plausible("Jun Mannou", words: [], names: []))
        #expect(NERDetector.plausible("ゆい", words: [], names: []))
        #expect(!NERDetector.plausible("𠮷", words: words, names: names), "one non-BMP character is one character")
    }

    @Test("A name past the first window is found once")
    func pastTheWindow() throws {
        let line = String(repeating: "あ", count: 600) + "田中"
        let calls = Counter()
        let detector = Self.detector(labelling: { $0 == 600 ? 1 : $0 == 601 ? 2 : 0 }, calls: calls)
        let found = try detector.detect(in: line)
        #expect(found.map(\.range) == [Self.r(600, 602)])
        #expect(found.map(\.text) == ["田中"])
        #expect(calls.value == 3, "windows start at 0, 190 and 380; the last reaches 634, past 602")
    }

    @Test("A name inside the overlap of two windows is found once")
    func insideTheOverlap() throws {
        let line = String(repeating: "あ", count: 200) + "佐藤" + String(repeating: "あ", count: 200)
        let found = try Self.detector(labelling: { $0 == 200 ? 1 : $0 == 201 ? 2 : 0 }).detect(in: line)
        #expect(found.map(\.range) == [Self.r(200, 202)])
    }

    @Test("Listed one-kanji family names survive, through detect")
    func listedSingleKanji() throws {
        let found = try Self.detector(labelling: { $0 == 0 || $0 == 4 ? 1 : 0 }, words: ["森"], names: ["森", "林"])
            .detect(in: "森さんと林さん")
        #expect(found.map(\.text) == ["森", "林"])
    }

    @Test("Offsets are UTF-16 in the whole text, across lines")
    func offsetsAcrossLines() throws {
        // 𠮷 is two UTF-16 units, so 𠮷田 is three and the second line starts
        // at 3 + 1.
        let text = "𠮷田\n田中"
        let found = try Self.detector(labelling: { $0 == 0 ? 1 : $0 <= 2 ? 2 : 0 }).detect(in: text)
        #expect(found.map(\.range) == [Self.r(0, 3), Self.r(4, 6)])
        #expect(found.map(\.text) == ["𠮷田", "田中"])
    }

    @Test("CRLF input is split into lines, so a later line's offsets are right")
    func crlf() throws {
        let text = "了解\r\n田中です"
        let found = try Self.detector(labelling: { $0 == 0 ? 1 : $0 == 1 ? 2 : 0 }).detect(in: text)
        let names = found.map { (text as NSString).substring(with: $0.range) }
        #expect(names.contains("田中"), "got \(names)")
    }

    @Test("Blank lines are skipped and still counted")
    func blankLines() throws {
        let calls = Counter()
        let text = "\n  \n田中"
        let found = try Self.detector(labelling: { $0 == 0 ? 1 : $0 == 1 ? 2 : 0 }, calls: calls).detect(in: text)
        #expect(calls.value == 1)
        #expect(found.map(\.range) == [Self.r(4, 6)])
    }

    @Test("Latin spans must be name-shaped, as the model layer's are")
    func latinSpans() throws {
        let text = "orders-db"
        let found = try Self.detector(labelling: { $0 == 0 ? 1 : 2 }).detect(in: text)
        #expect(found.isEmpty)
    }

    @Test("Kanji outside the BMP count as Japanese at the gate")
    func extensionBKanji() {
        #expect(JapaneseText.containsJapanese("𠮷"))
    }

    @Test("Matches are personal names from the NER source, at low confidence")
    func source() throws {
        let found = try Self.detector(labelling: { $0 == 0 ? 1 : $0 == 1 ? 2 : 0 }).detect(in: "田中")
        #expect(found.map(\.kind) == [.personalName])
        #expect(found.map(\.source) == [.ner])
        #expect(DetectorSource.ner.baseConfidence == .low)
    }

    static func lines(_ count: Int) -> String {
        (0..<count).map { $0 % 3 == 0 ? "\($0) 田中さん、田村さん" : "line \($0) ok" }.joined(separator: "\n")
    }

    @Test("Many lines give the matches running each line alone gives, in line order")
    func manyLinesInOrder() throws {
        let text = Self.lines(200)
        let detector = Self.tanakaDetector()
        var expected: [DetectedMatch] = []
        var base = 0
        for line in text.components(separatedBy: "\n") {
            expected += try detector.detect(in: line).map {
                DetectedMatch(kind: $0.kind, source: $0.source,
                              range: NSRange(location: base + $0.range.location, length: $0.range.length), text: $0.text)
            }
            base += line.utf16.count + 1
        }
        let found = try detector.detect(in: text)
        #expect(found.count == 134)
        #expect(found.map(\.range) == expected.map(\.range))
        #expect(found.map(\.text) == expected.map(\.text))
    }

    @Test("An error on one line of many is thrown")
    func errorOnOneLine() {
        let detector = NERDetector(
            tokenize: Self.perUnit, clsID: -1, sepID: -2,
            predict: { ids in ids.count == 10 ? [0] : ids.map { _ in 0 } })  // only "bad line" is 8 units
        #expect(throws: NERDetector.Failure.self) { try detector.detect(in: Self.lines(100) + "\nbad line") }
    }

    /// A model that calls each 田 the start of a name and the next character
    /// its end.
    static func tanakaDetector() -> NERDetector {
        NERDetector(
            tokenize: { line in
                line.utf16.enumerated().map { XLMRTokenizer.Token(id: Int32($1), range: NSRange(location: $0, length: 1)) }
            },
            clsID: -1, sepID: -2,
            predict: { ids in
                var labels = ids.map { _ in 0 }
                for i in ids.indices where ids[i] == 0x7530 && i + 1 < ids.count { labels[i] = 1; labels[i + 1] = 2 }
                return labels
            })
    }

    @Test("A model that returns the wrong number of labels is an error, not a guess")
    func labelCount() {
        let detector = NERDetector(tokenize: Self.perUnit, clsID: -1, sepID: -2, predict: { _ in [0] })
        #expect(throws: NERDetector.Failure.self) { try detector.detect(in: "田中") }
    }
}
