import Foundation
import Testing

@testable import PrivMask

/// The corpus regression test. Detection accuracy is the whole product, so this
/// is the test that matters: it runs the deterministic pipeline over the
/// ground-truth corpus and demands full recall on everything that does not need
/// the language model, with no over-masking at all.
@Suite("Deterministic pipeline against the corpus")
struct CorpusRegressionTests {
    /// Kinds the deterministic layer is responsible for. Personal and
    /// organisation names are excluded: NLTagger has no Japanese entity model,
    /// so they come from the on-device model instead.
    static let deterministicKinds: Set<SensitiveKind> = [
        .email, .phoneNumber, .address, .postalCode, .myNumber, .credential, .dictionaryTerm,
    ]

    static func loadCorpus() throws -> Corpus {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PrivMaskTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        return try Corpus.load(contentsOf: root.appendingPathComponent("Corpus/ja-baseline.json"))
    }

    static func report() throws -> Evaluator.Report {
        let corpus = try loadCorpus()
        let pipeline = DetectionPipeline(dictionaryTerms: corpus.dictionary)
        var detections: [String: [DetectedMatch]] = [:]
        for sample in corpus.samples {
            detections[sample.id] = pipeline.detect(in: sample.text).map {
                DetectedMatch(kind: $0.kind, source: $0.sources[0], range: $0.range, text: $0.text)
            }
        }
        return Evaluator.evaluate(corpus: corpus, detections: detections)
    }

    @Test("The corpus itself is well-formed")
    func corpusIsWellFormed() throws {
        #expect(try Self.report().corpusErrors.isEmpty)
    }

    @Test("Every deterministic kind is fully recalled")
    func deterministicKindsFullyRecalled() throws {
        for tally in try Self.report().tallies where Self.deterministicKinds.contains(tally.kind) {
            let detail = "\(tally.kind.rawValue) missed \(tally.missed): \(tally.missedTexts.joined(separator: ", "))"
            #expect(tally.missed == 0, Comment(rawValue: detail))
        }
    }

    /// Over-masking destroys the text being shared. There is no acceptable
    /// number of these.
    @Test("Nothing in mustNotDetect is ever masked")
    func noOverMasking() throws {
        let violations = try Self.report().violations
        let detail = violations
            .map { "[\($0.sampleID)] \($0.match.text) as \($0.match.kind.rawValue)" }
            .joined(separator: "; ")
        #expect(violations.isEmpty, Comment(rawValue: detail))
    }

    @Test("No detections beyond what the corpus expects")
    func noUnexpectedDetections() throws {
        let unexpected = try Self.report().unexpected
        let detail = unexpected.flatMap { entry in
            entry.matches.map { "[\(entry.sampleID)] \($0.kind.rawValue): \($0.text)" }
        }.joined(separator: "; ")
        #expect(unexpected.isEmpty, Comment(rawValue: detail))
    }
}

@Suite("My Number check digit")
struct MyNumberTests {
    @Test("A valid number is accepted")
    func validNumber() {
        #expect(MyNumberDetector.isValid("123456789018"))
    }

    @Test("Changing the check digit rejects it", arguments: 0...9)
    func invalidCheckDigits(_ digit: Int) {
        let candidate = "12345678901\(digit)"
        #expect(MyNumberDetector.isValid(candidate) == (digit == 8))
    }

    @Test("Full-width digits are normalised before validation")
    func fullWidthDigits() {
        let matches = MyNumberDetector().detect(in: "マイナンバーは １２３４５６７８９０１８ です")
        #expect(matches.count == 1)
    }

    @Test("An invalid 12-digit number is not reported")
    func invalidNumberIgnored() {
        #expect(MyNumberDetector().detect(in: "注文番号 123456789010 について").isEmpty)
    }
}

@Suite("Precedence and merging")
struct PipelineTests {
    private let pipeline = DetectionPipeline()

    @Test("A My Number outranks the phone number NSDataDetector sees in it")
    func myNumberBeatsPhoneNumber() {
        let candidates = pipeline.detect(in: "マイナンバー: 123456789018")
        #expect(candidates.contains { $0.kind == .myNumber })
        #expect(!candidates.contains { $0.kind == .phoneNumber })
    }

    @Test("A phone match does not run past the end of its line")
    func phoneMatchStopsAtLineEnd() {
        let candidates = pipeline.detect(in: "全角表記: ０９０－１２３４－５６７８\n内線: 7788")
        let phones = candidates.filter { $0.kind == .phoneNumber }
        #expect(phones.count == 1)
        #expect(phones.first?.text == "０９０－１２３４－５６７８")
    }

    @Test("Regex findings are high confidence")
    func regexConfidence() {
        let candidates = pipeline.detect(in: "連絡は suzuki@example.co.jp まで")
        #expect(candidates.first { $0.kind == .email }?.confidence == .high)
    }
}
