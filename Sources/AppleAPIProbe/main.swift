import Foundation
import PrivMask

// Measures NSDataDetector and NLTagger against the ground-truth corpus.
// Deterministic and fast; safe to run on every change.

let corpus = try Corpus.load(contentsOf: ProbeLocator.corpusURL())

let pipeline = DetectionPipeline(dictionaryTerms: corpus.dictionary)

var detections: [String: [DetectedMatch]] = [:]
for sample in corpus.samples {
    // Evaluate the pipeline's output, not raw detector output: precedence and
    // merging are part of what is being measured.
    detections[sample.id] = pipeline.detect(in: sample.text).map {
        DetectedMatch(kind: $0.kind, source: $0.sources[0], range: $0.range, text: $0.text)
    }
}

let report = Evaluator.evaluate(corpus: corpus, detections: detections)

print("privmask — deterministic detection pipeline probe")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print(String(repeating: "=", count: 78))
print(
    report.rendered(
        coveredKinds: [.phoneNumber, .address, .email, .postalCode, .myNumber, .credential],
        coveredLabel: "det."
    )
)
