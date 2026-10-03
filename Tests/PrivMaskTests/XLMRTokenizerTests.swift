import CryptoKit
import Foundation
import Testing

@testable import PrivMask

/// The Swift tokenizer must give the ids Hugging Face gives, or the model sees
/// different input than it was trained and accepted on. The fixture is
/// `Scripts/ner/fixtures.py`'s output over the public corpus. See #46.
@Suite("XLM-R tokenizer matches Hugging Face", .enabled(if: NERTestResources.hasTokenizer))
struct XLMRTokenizerTests {
    struct Fixture: Decodable {
        struct Line: Decodable { let line: String; let ids: [Int32]; let offsets: [[Int]] }
        let tokenizer_sha256: String
        let cls: Int32
        let sep: Int32
        let lines: [Line]
    }

    static func load() throws -> (XLMRTokenizer, Fixture, Data) {
        let url = NERTestResources.directory!.appendingPathComponent("tokenizer.json")
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: NERTestResources.fixture))
        return (try XLMRTokenizer(contentsOf: url), fixture, data)
    }

    @Test("The fixture was made from this tokenizer.json")
    func fixtureIsCurrent() throws {
        let (_, fixture, data) = try Self.load()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == fixture.tokenizer_sha256, "regenerate with Scripts/ner/fixtures.py")
    }

    @Test("<s> and </s> are the ids Hugging Face wraps a line in")
    func specialIDs() throws {
        let (tokenizer, fixture, _) = try Self.load()
        #expect(tokenizer.clsID == fixture.cls)
        #expect(tokenizer.sepID == fixture.sep)
    }

    @Test("Every fixture line gets the same ids and UTF-16 offsets")
    func everyLine() throws {
        let (tokenizer, fixture, _) = try Self.load()
        var mismatches: [String] = []
        for line in fixture.lines {
            let tokens = tokenizer.encode(line.line)
            let ids = tokens.map(\.id)
            let offsets = tokens.map { [$0.range.location, NSMaxRange($0.range)] }
            if ids != line.ids || offsets != line.offsets {
                mismatches.append("\(line.line.debugDescription)\n  want \(line.ids) \(line.offsets)\n  got  \(ids) \(offsets)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(fixture.lines.count) lines differ:\n\(mismatches.prefix(5).joined(separator: "\n"))")
    }
}
