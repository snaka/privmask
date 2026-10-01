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

@Suite("Detections file")
struct DetectionsFileTests {
    @Test("Offsets and rejected are optional")
    func optionalFields() throws {
        let file = try DetectionsFile.decode(Data("""
            {"system": "opus", "samples": {"a": {"names": [{"text": "滝口 健太"}]}}}
            """.utf8))
        #expect(file.samples["a"]?.names == [DetectionsFile.Name(text: "滝口 健太")])
        #expect(file.samples["a"]?.rejected == nil)
    }

    @Test("What is written reads back the same")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("detections-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = DetectionsFile(system: "privmask", samples: [
            "a": .init(names: [.init(text: "滝口", location: 3, length: 2)], rejected: ["内線"]),
        ])
        try original.write(to: url)
        let read = try DetectionsFile.load(contentsOf: url)
        #expect(read.system == "privmask")
        #expect(read.samples["a"]?.names == original.samples["a"]?.names)
        #expect(read.samples["a"]?.rejected == ["内線"])
    }
}

/// One sample, one system: the shape almost every scoring test needs.
private func score(
    _ text: String,
    expected: [String],
    names: [DetectionsFile.Name],
    rejected: [String]? = nil
) throws -> NameEvaluator.Report {
    let expectations = expected
        .map { #"{"kind": "personalName", "text": "\#($0)", "tags": ["kanji", "full"]}"# }
        .joined(separator: ",")
    let json = #"{"id": "s", "note": "", "text": "\#(text)", "genre": "slack", "writer": "human", "expected": [\#(expectations)], "mustNotDetect": []}"#
    let file = DetectionsFile(system: "test", samples: ["s": .init(names: names, rejected: rejected)])
    return NameEvaluator.evaluate(corpus: try makeCorpus(json), detections: file)
}

@Suite("Scoring names by coverage")
struct NameEvaluatorTests {
    @Test("A detection covering the whole name is covered")
    func exactCover() throws {
        let report = try score("担当は田中健一です", expected: ["田中健一"],
                               names: [.init(text: "田中健一", location: 3, length: 4)])
        #expect(report.expected.map(\.outcome) == [.covered])
        #expect(report.recall == 1)
        #expect(report.precision == 1)
    }

    @Test("Covering more than the name, such as the honorific, still counts")
    func widerCover() throws {
        let report = try score("担当は田中健一様です", expected: ["田中健一"],
                               names: [.init(text: "田中健一様", location: 3, length: 5)])
        #expect(report.expected.map(\.outcome) == [.covered])
    }

    @Test("Masking the family name alone leaves the given name: partial, and not recall")
    func partialIsNotRecall() throws {
        let report = try score("担当は田中健一です", expected: ["田中健一"],
                               names: [.init(text: "田中", location: 3, length: 2)])
        #expect(report.expected.map(\.outcome) == [.partial])
        #expect(report.recall == 0)
        #expect(report.falsePositives.isEmpty)
    }

    @Test("Two detections that together cover a name with an ideographic space in it")
    func jointCoverAcrossIdeographicSpace() throws {
        let report = try score("担当は田中　健一です", expected: ["田中　健一"],
                               names: [.init(text: "田中", location: 3, length: 2),
                                       .init(text: "健一", location: 6, length: 2)])
        #expect(report.expected.map(\.outcome) == [.covered])
    }

    @Test("No overlapping detection is a miss the model never returned")
    func missNeverReturned() throws {
        let report = try score("担当は田中健一です", expected: ["田中健一"], names: [])
        #expect(report.expected.map(\.outcome) == [.missed])
        #expect(report.expected.map(\.cause) == [.neverReturned])
    }

    @Test("A miss the filter threw away is attributed to the filter")
    func missFilterRejected() throws {
        let report = try score("担当は滝口健太です", expected: ["滝口健太"], names: [], rejected: ["滝口健太"])
        #expect(report.expected.map(\.cause) == [.filterRejected])
    }

    @Test("A detection overlapping no name is a false positive")
    func falsePositive() throws {
        let report = try score("内線は田中健一です", expected: ["田中健一"],
                               names: [.init(text: "田中健一", location: 3, length: 4),
                                       .init(text: "内線", location: 0, length: 2)])
        #expect(report.falsePositives.map(\.text) == ["内線"])
        #expect(report.precision == 0.5)
    }

    @Test("Each occurrence of an expected name is one expected name")
    func everyOccurrenceCounts() throws {
        let report = try score("田中健一と、再び田中健一", expected: ["田中健一"],
                               names: [.init(text: "田中健一", location: 0, length: 4)])
        #expect(report.expected.map(\.outcome) == [.covered, .missed])
    }

    @Test("A text-only detection counts at every place the text occurs")
    func textOnlyGrounding() throws {
        let report = try score("田中健一と、再び田中健一", expected: ["田中健一"],
                               names: [.init(text: "田中健一")])
        #expect(report.expected.map(\.outcome) == [.covered, .covered])
        #expect(report.detectionCount == 2)
    }

    @Test("A non-BMP character before a name: UTF-16 offsets land, code-point offsets past the end are invalid")
    func nonBMPOffsets() throws {
        // 𠮷 is one Character, one code point and two UTF-16 units.
        let text = "𠮷田さんと田中健一"
        let utf16 = (text as NSString).range(of: "田中健一")
        let report = try score(text, expected: ["𠮷田", "田中健一"], names: [
            .init(text: "田中健一", location: utf16.location, length: utf16.length),
            .init(text: "𠮷田"),
            .init(text: "bogus", location: 40, length: 4),
            .init(text: "田中健一", location: 5, length: 4),  // code-point offset: lands inside, wrong text
        ])
        #expect(report.expected.map(\.outcome) == [.covered, .covered])
        #expect(report.invalidDetections.count == 2)
    }

    @Test("A detections entry for a sample the corpus lacks is reported")
    func unknownSampleID() throws {
        let corpus = try makeCorpus(#"{"id": "s", "note": "", "text": "x", "expected": [], "mustNotDetect": []}"#)
        let file = DetectionsFile(system: "t", samples: ["s": .init(names: []), "typo": .init(names: [])])
        #expect(NameEvaluator.evaluate(corpus: corpus, detections: file).unknownSampleIDs == ["typo"])
    }

    @Test("A sample the system never examined is scored as missed, and listed")
    func unexaminedSample() throws {
        let corpus = try makeCorpus(#"{"id": "s", "note": "", "text": "田中健一", "expected": [{"kind": "personalName", "text": "田中健一"}], "mustNotDetect": []}"#)
        let report = NameEvaluator.evaluate(corpus: corpus, detections: DetectionsFile(system: "t", samples: [:]))
        #expect(report.expected.map(\.outcome) == [.missed])
        #expect(report.unexaminedSampleIDs == ["s"])
    }

    @Test("Whether the family name is on our list is computed, not tagged")
    func surnameListComputed() throws {
        let report = try score("勅使河原誠と田中健一", expected: ["勅使河原誠", "田中健一"], names: [])
        #expect(report.expected.map(\.beginsWithListedSurname) == [false, true])
    }

    @Test("An expected string nested inside another is not a second name")
    func nestedExpectations() throws {
        let a = try score("小林さんと林さん", expected: ["小林", "林"], names: [])
        #expect(a.expected.count == 2)
        let b = try score("田中健一です。田中が", expected: ["田中健一", "田中"], names: [])
        #expect(b.expected.count == 2)
    }

    @Test("An absurd offset is invalid, not a crash")
    func hugeOffset() throws {
        let report = try score("田中健一", expected: ["田中健一"],
                               names: [.init(text: "田中", location: Int.max, length: 1)])
        #expect(report.invalidDetections.count == 1)
    }

    @Test("The katakana middle dot need not be covered")
    func middleDot() throws {
        let report = try score("ジョン・スミス", expected: ["ジョン・スミス"],
                               names: [.init(text: "ジョン", location: 0, length: 3),
                                       .init(text: "スミス", location: 4, length: 3)])
        #expect(report.expected.map(\.outcome) == [.covered])
    }

    @Test("Covering only the BMP half of a name with a non-BMP kanji is partial")
    func nonBMPPartial() throws {
        let report = try score("𠮷田さん", expected: ["𠮷田"], names: [.init(text: "田")])
        #expect(report.expected.map(\.outcome) == [.partial])
    }

    @Test("The same span reported twice is one detection")
    func duplicateSpan() throws {
        let report = try score("田中健一", expected: ["田中健一"],
                               names: [.init(text: "田中健一", location: 0, length: 4),
                                       .init(text: "田中健一", location: 0, length: 4)])
        #expect(report.detectionCount == 1)
    }
}
