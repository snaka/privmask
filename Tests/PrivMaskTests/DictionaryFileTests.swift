import Foundation
import Testing

@testable import PrivMask

@Suite("Dictionary file")
struct DictionaryFileTests {
    @Test("One term per line, comments and blank lines ignored")
    func parsesLines() {
        let contents = """
            # Customers
            株式会社サンプル商事

              アクメ株式会社
            # trailing comment
            """
        #expect(DictionaryFile.parse(contents) == ["株式会社サンプル商事", "アクメ株式会社"])
    }

    @Test("An empty file yields no terms")
    func emptyFile() {
        #expect(DictionaryFile.parse("").isEmpty)
    }

    @Test("A missing file is not an error")
    func missingFileIsNotAnError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privmask-absent-\(UUID().uuidString).txt")
        #expect(try DictionaryFile.load(from: url).isEmpty)
    }

    @Test("Terms are read back from a real file")
    func readsFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privmask-terms-\(UUID().uuidString).txt")
        try "アクメ株式会社\n# comment\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try DictionaryFile.load(from: url) == ["アクメ株式会社"])
    }

    /// Dictionary matching ignores case and character width, because Japanese
    /// text mixes full-width and half-width forms freely.
    @Test("Matching ignores case and character width")
    func matchingIsWidthAndCaseInsensitive() {
        let detector = DictionaryDetector(terms: ["Acme Corp"])
        #expect(!detector.detect(in: "取引先は ACME CORP です").isEmpty)
        #expect(!detector.detect(in: "取引先は Ａｃｍｅ Ｃｏｒｐ です").isEmpty)
    }

    @Test("A longer registered term wins over a shorter one inside it")
    func longerTermWins() {
        let detector = DictionaryDetector(terms: ["サンプル", "株式会社サンプル商事"])
        let matches = detector.detect(in: "お客様は株式会社サンプル商事です")
        #expect(matches.count == 1)
        #expect(matches[0].text == "株式会社サンプル商事")
    }
}
