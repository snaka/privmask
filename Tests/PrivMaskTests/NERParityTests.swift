import Foundation
import Testing

@testable import PrivMask

/// The Swift NER layer must find what the Python pipeline found when the
/// maintainer accepted the model: the same names on the dev and test halves of
/// the corpus. The one intended difference is the Latin check, which Python did
/// not apply. See #46.
@Suite("Swift NER finds what Python found", .enabled(if: NERTestResources.hasPythonDetections))
struct NERParityTests {
    static let export = NERTestResources.export

    @Test("Same names on each half of the corpus", arguments: ["dev", "test"])
    func sameNames(half: String) throws {
        let pythonURL = Self.export.appendingPathComponent("detections-\(half).json")
        let python = try DetectionsFile.load(contentsOf: pythonURL)
        let corpus = try Corpus.load(contentsOf: NERTestResources.packageRoot.appendingPathComponent("Corpus/ja-names.json"))
        let detector = try NERDetector.load(from: NERTestResources.directory!)

        var differences: [String] = []
        for sample in corpus.samples {
            guard let expected = python.samples[sample.id] else { continue }
            let want = expected.names
                .filter { JapaneseText.containsJapanese($0.text) || LatinNameShape.isNameShaped($0.text) }
                .map { "\($0.location ?? -1):\($0.length ?? -1):\($0.text)" }
            let got = try detector.detect(in: sample.text).map { "\($0.range.location):\($0.range.length):\($0.text)" }
            if want != got { differences.append("\(sample.id)\n  want \(want)\n  got  \(got)") }
        }
        #expect(differences.isEmpty, "\(differences.count) samples differ:\n\(differences.prefix(5).joined(separator: "\n"))")
    }
}
