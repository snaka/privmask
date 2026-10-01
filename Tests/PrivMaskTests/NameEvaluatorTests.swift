import Foundation
import Testing

@testable import PrivMask

/// Builds a corpus from inline JSON, so each test states its own ground truth.
func makeCorpus(_ samples: String) throws -> Corpus {
    try Corpus.decode(Data("""
        {"version": 1, "note": "test", "dictionary": [], "samples": [\(samples)]}
        """.utf8))
}

@Suite("Name corpus schema")
struct NameCorpusSchemaTests {
    @Test("Tags, genre and writer decode")
    func fieldsDecode() throws {
        let decoded = try makeCorpus("""
            {"id": "a", "note": "", "text": "担当は滝口 健太さん", "genre": "slack", "writer": "sonnet",
             "expected": [{"kind": "personalName", "text": "滝口 健太",
                           "tags": ["kanji", "full", "spaced", "honorific"]}],
             "mustNotDetect": []}
            """)
        let sample = decoded.samples[0]
        #expect(sample.genre == .slack)
        #expect(sample.writer == .sonnet)
        #expect(sample.expected[0].tags == [.kanji, .full, .spaced, .honorific])
    }

    @Test("An unknown tag fails to decode")
    func unknownTagFails() {
        #expect(throws: (any Error).self) {
            try makeCorpus("""
                {"id": "a", "note": "", "text": "滝口", "expected":
                 [{"kind": "personalName", "text": "滝口", "tags": ["surnameOnly"]}], "mustNotDetect": []}
                """)
        }
    }

    @Test("A sample without the new fields still decodes")
    func oldShapeDecodes() throws {
        let decoded = try makeCorpus("""
            {"id": "a", "note": "", "text": "滝口", "expected": [{"kind": "personalName", "text": "滝口"}],
             "mustNotDetect": []}
            """)
        #expect(decoded.samples[0].genre == nil)
        #expect(decoded.samples[0].expected[0].tags == nil)
    }
}
