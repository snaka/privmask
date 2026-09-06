import Foundation
import PrivMask

// Measures NSDataDetector and NLTagger against the ground-truth corpus.
// Deterministic and fast; safe to run on every change.

let corpus = try Corpus.load(contentsOf: ProbeLocator.corpusURL())

let dataDetector = AppleDataDetector()
let nameTagger = AppleNameTagger()

var detections: [String: [DetectedMatch]] = [:]
for sample in corpus.samples {
    detections[sample.id] = dataDetector.detect(in: sample.text) + nameTagger.detect(in: sample.text)
}

let report = Evaluator.evaluate(corpus: corpus, detections: detections)

print("privmask — Apple built-in detector probe")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print(String(repeating: "=", count: 78))
print(
    report.rendered(
        coveredKinds: [.phoneNumber, .address, .personalName, .organizationName, .placeName],
        coveredLabel: "apple"
    )
)
