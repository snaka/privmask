import Foundation
import Testing

@testable import PrivMask

/// The model layer's spans were found to wrap a phone number (`03-1234-5678（日中）`)
/// and are dropped when they overlap a more trustworthy finding of another kind.
/// NER spans are as fallible, so the same rule applies. See #46.
@Suite("Model-only findings yield to deterministic ones")
struct NERPrecedenceTests {
    static let text = "連絡先 03-1234-5678（日中）"

    static func wrapping(_ sources: [DetectorSource]) -> [DetectedMatch] {
        let range = (text as NSString).range(of: "03-1234-5678（日中）")
        return sources.map { DetectedMatch(kind: .personalName, source: $0, range: range, text: "03-1234-5678（日中）") }
    }

    @Test("A name from NER alone that wraps a phone number is dropped", arguments: [
        [DetectorSource.ner], [.languageModel], [.ner, .languageModel],
    ])
    func dropped(sources: [DetectorSource]) {
        let candidates = DetectionPipeline().detect(in: Self.text, additional: Self.wrapping(sources))
        #expect(candidates.contains { $0.kind == .phoneNumber })
        #expect(!candidates.contains { $0.kind == .personalName }, "got \(candidates.map { ($0.kind, $0.sources) })")
    }
}
