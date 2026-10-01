import Foundation
import Testing

@testable import PrivMask

@Suite("Name corpus check")
struct NameCorpusCheckTests {
    private func problems(_ samples: String) throws -> [String] {
        NameCorpusCheck.problems(in: try makeCorpus(samples))
    }

    private let good = #"{"id": "a", "note": "", "text": "担当は滝口 健太さん", "genre": "slack", "writer": "human", "expected": [{"kind": "personalName", "text": "滝口 健太", "tags": ["kanji", "full"]}], "mustNotDetect": []}"#

    @Test("A well-formed sample has no problems")
    func wellFormed() throws { #expect(try problems(good).isEmpty) }

    @Test("Duplicate ids are a problem")
    func duplicateIDs() throws { #expect(try problems("\(good),\(good)").count == 1) }

    @Test("A missing genre or writer is a problem")
    func missingGenreWriter() throws {
        #expect(try problems(#"{"id": "a", "note": "", "text": "x", "expected": [], "mustNotDetect": []}"#).count == 2)
    }

    @Test("An expected name absent from the text is a problem")
    func absentName() throws {
        let found = try problems(good.replacingOccurrences(of: "担当は滝口 健太さん", with: "担当は尾形さん"))
        #expect(found.count == 1 && found[0].contains("not in the text"))
    }

    @Test("A name without a script and a form tag is a problem")
    func missingTags() throws {
        #expect(try problems(good.replacingOccurrences(of: #""kanji", "full""#, with: #""honorific""#)).count == 2)
    }

    @Test("A string used as a name and as a non-name in one sample is a problem")
    func nameAndNonName() throws {
        let sample = #"{"id": "a", "note": "", "text": "田中さんが田中式で直した", "genre": "slack", "writer": "human", "expected": [{"kind": "personalName", "text": "田中", "tags": ["kanji", "familyOnly"]}], "mustNotDetect": ["田中式"]}"#
        #expect(try problems(sample).count == 1)
    }

    @Test("More than one script tag is a problem")
    func twoScripts() throws {
        let found = try problems(good.replacingOccurrences(of: #""kanji", "full""#, with: #""kanji", "mixed", "full""#))
        #expect(found.count == 1 && found[0].contains("more than one script tag"))
    }

    /// Four katakana labels were tagged romaji, and the romaji row counted them.
    /// See #32.
    @Test(
        "The script tag must match how the name is written",
        arguments: [
            ("滝口 健太", "kanji", true), ("滝口 健太", "katakana", false),
            ("田ヶ原 小一", "kanji", true),  // ヶ and 々 belong to kanji names
            ("佐々木", "kanji", true),
            ("コヤバ ナオキ", "romaji", false), ("コヤバ ナオキ", "katakana", true),
            ("エマ・ブラウン", "katakana", true),
            ("ｺﾔﾊﾞ", "katakana", true),  // half-width, with a voicing mark
            ("コウタニ太郎", "mixed", true), ("コウタニ太郎", "katakana", false),
            ("IiiTake_01", "romaji", true), ("Hiroki Kotani", "romaji", true),
            ("井出 ゆう", "mixed", true), ("井出 ゆう", "kanji", false),
            ("さくら", "hiragana", true), ("さくら", "mixed", false),
        ]
    )
    func scriptTagMatches(_ name: String, _ script: String, _ ok: Bool) throws {
        let sample = #"{"id": "a", "note": "", "text": "担当は\#(name)さん", "genre": "slack", "writer": "human", "expected": [{"kind": "personalName", "text": "\#(name)", "tags": ["\#(script)", "full"]}], "mustNotDetect": []}"#
        let found = try problems(sample)
        #expect(found.isEmpty == ok, Comment(rawValue: found.joined(separator: "; ")))
    }

    @Test("More than one form tag is a problem")
    func twoForms() throws {
        let found = try problems(good.replacingOccurrences(of: #""kanji", "full""#, with: #""kanji", "full", "familyOnly""#))
        #expect(found.count == 1 && found[0].contains("more than one form tag"))
    }

    @Test("A non-name kind in the name corpus is a problem")
    func otherKind() throws {
        #expect(try problems(good.replacingOccurrences(of: "personalName", with: "phoneNumber")).count == 1)
    }
}

/// The real corpora. `Corpus/local/` is gitignored and holds real failures;
/// when it is present here it is checked too, and it never leaves the machine.
@Suite("Name corpora on disk are well-formed")
struct NameCorpusFilesTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PrivMaskTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    static func files() -> [URL] {
        let local = root.appendingPathComponent("Corpus/local")
        let entries = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? []
        return [root.appendingPathComponent("Corpus/ja-names.json")]
            + entries.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    @Test("Every name corpus passes the check", arguments: files())
    func passes(_ url: URL) throws {
        let problems = NameCorpusCheck.problems(in: try Corpus.load(contentsOf: url))
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }
}
