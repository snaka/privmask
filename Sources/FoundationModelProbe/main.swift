import Foundation
import PrivMask

// Measures the on-device Apple Intelligence model against the same corpus.
//
// Unlike AppleAPIProbe this is slow and non-deterministic: it is a measurement
// to inform design decisions, not a regression test. Run it deliberately.

@available(macOS 26.0, *)
func runProbe() async throws {
    print("model availability: \(FoundationModelDetector.availabilityDescription)")
    guard FoundationModelDetector.isAvailable else {
        print("Model unavailable — this is exactly the environment where personal names cannot be found at all.")
        return
    }

    let corpus = try Corpus.load(contentsOf: ProbeLocator.corpusURL())
    // The chunk size is the one number the batching design left to be settled by
    // measurement, and recall for a name that comes after others is what it
    // trades against latency. PRIVMASK_CHUNK_CHARS varies it.
    let chunkCharacters =
        ProcessInfo.processInfo.environment["PRIVMASK_CHUNK_CHARS"].flatMap(Int.init)
        ?? FoundationModelDetector.defaultCharacterLimit
    print("chunk size: \(chunkCharacters) characters")
    let detector = FoundationModelDetector(characterLimit: chunkCharacters)
    // Evaluate what the product actually produces: the deterministic pipeline
    // plus whatever the model adds. Measuring the model alone understates it,
    // because English names are NLTagger's job and never reach the model.
    let pipeline = DetectionPipeline(dictionaryTerms: corpus.dictionary)

    var detections: [String: [DetectedMatch]] = [:]
    var ungroundedBySample: [(sampleID: String, texts: [String])] = []
    var durations: [TimeInterval] = []

    print(String(repeating: "=", count: 78))
    for sample in corpus.samples {
        // The deterministic layer runs regardless. A model failure must never
        // discard results that were already found without it.
        func flatten(_ candidates: [MaskCandidate]) -> [DetectedMatch] {
            candidates.map {
                DetectedMatch(kind: $0.kind, source: $0.sources[0], range: $0.range, text: $0.text)
            }
        }
        detections[sample.id] = flatten(pipeline.detect(in: sample.text))

        do {
            let outcome = try await detector.detect(in: sample.text)
            // Reconcile through the pipeline, exactly as the UI does when the
            // model returns, so precedence applies to the model's findings too.
            detections[sample.id] = flatten(
                pipeline.detect(in: sample.text, additional: outcome.matches)
            )
            durations.append(outcome.duration)
            if !outcome.ungroundedTexts.isEmpty {
                ungroundedBySample.append((sample.id, outcome.ungroundedTexts))
            }
            let id = sample.id.padding(toLength: 26, withPad: " ", startingAt: 0)
            let timing = String(format: "%6.2fs", outcome.duration)
            let failed = outcome.failures.isEmpty ? "" : "  \(outcome.failures.count)/\(outcome.chunks) CHUNKS FAILED"
            print("  \(id) \(sample.text.count) chars  \(outcome.linesExamined) ja-lines  \(outcome.chunks) chunks  \(timing)  \(outcome.matches.count) matches\(failed)")
        } catch {
            let kept = detections[sample.id]?.count ?? 0
            print("  \(sample.id.padding(toLength: 26, withPad: " ", startingAt: 0)) model failed, keeping \(kept) deterministic matches — \(error)")
        }
    }

    let report = Evaluator.evaluate(corpus: corpus, detections: detections)
    print(
        report.rendered(
            coveredKinds: Set(SensitiveKind.allCases),
            coveredLabel: "det+llm"
        )
    )

    print("\n## Ungrounded spans (model returned text absent from the input)\n")
    if ungroundedBySample.isEmpty {
        print("(none)")
    } else {
        for entry in ungroundedBySample {
            print("[\(entry.sampleID)]")
            for text in entry.texts { print("  - \(text.debugDescription)") }
        }
    }

    if !durations.isEmpty {
        let total = durations.reduce(0, +)
        let mean = total / Double(durations.count)
        let slowest = durations.max() ?? 0
        print("\n## Latency\n")
        print(String(format: "  total %.2fs over %d samples, mean %.2fs, slowest %.2fs",
                     total, durations.count, mean, slowest))
    }
}

/// Measures how latency scales with input length. The design caps the LLM layer
/// at some length and skips beyond it; this is where that cap comes from.
@available(macOS 26.0, *)
func measureLatencyScaling() async {
    let block = """
        2026-09-05 14:32:01 [ERROR] api-server: upstream timeout
        担当: 田中健一 / 連絡先 090-1234-5678 / tanaka@example.co.jp
        お客様: 株式会社サンプル商事 東京都渋谷区渋谷2丁目21番1号

        """
    print("\n## Latency scaling\n")
    print("  chars   duration  matches")
    let detector = FoundationModelDetector()
    for repeats in [1, 2, 4, 8, 16] {
        let text = String(repeating: block, count: repeats)
        do {
            let outcome = try await detector.detect(in: text)
            print(String(format: "  %6d  %7.2fs  %3d", text.count, outcome.duration, outcome.matches.count))
        } catch {
            print(String(format: "  %6d  FAILED — %@", text.count, String(describing: error)))
            break
        }
    }
}

print("privmask — full pipeline probe (deterministic + on-device model)")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

if #available(macOS 26.0, *) {
    if ProcessInfo.processInfo.environment["PRIVMASK_LATENCY"] == "1" {
        await measureLatencyScaling()
    } else {
        try await runProbe()
    }
} else {
    print("FoundationModels requires macOS 26 or later. Nothing to measure.")
}
