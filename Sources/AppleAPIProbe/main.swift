import Foundation
import PrivMask

// Measures what Apple's built-in detectors actually find in Japanese text.
//
// This is not a pass/fail test — it is a characterisation of NSDataDetector and
// NLTagger, run against a hand-written ground-truth corpus. Its output decides
// how much work the hand-written regex layer has to do, and whether NLTagger's
// personal-name detection is accurate enough to stay on by default.

// MARK: - Corpus model

struct Corpus: Decodable {
    struct Expectation: Decodable {
        let kind: SensitiveKind
        let text: String
    }

    struct Sample: Decodable {
        let id: String
        let note: String
        let text: String
        let expected: [Expectation]
        let mustNotDetect: [String]
    }

    let version: Int
    let note: String
    let samples: [Sample]
}

// MARK: - Helpers

/// All ranges at which `needle` occurs in `haystack`.
func occurrences(of needle: String, in haystack: String) -> [NSRange] {
    let nsText = haystack as NSString
    var found: [NSRange] = []
    var cursor = 0
    while cursor < nsText.length {
        let searchRange = NSRange(location: cursor, length: nsText.length - cursor)
        let range = nsText.range(of: needle, range: searchRange)
        if range.location == NSNotFound { break }
        found.append(range)
        cursor = range.location + max(range.length, 1)
    }
    return found
}

func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
    NSIntersectionRange(a, b).length > 0
}

/// Kinds that Apple's built-in detectors are able to produce at all. Anything
/// else in the corpus is a gap the regex layer must close by definition.
let appleCoveredKinds: Set<SensitiveKind> = [
    .phoneNumber, .address, .personalName, .organizationName, .placeName,
]

// MARK: - Load corpus

let corpusPath: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    let probeFile = URL(fileURLWithPath: #filePath)
    let packageRoot = probeFile
        .deletingLastPathComponent()  // AppleAPIProbe
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // package root
    return packageRoot.appendingPathComponent("Corpus/ja-baseline.json").path
}()

guard let data = FileManager.default.contents(atPath: corpusPath) else {
    FileHandle.standardError.write(Data("corpus not found: \(corpusPath)\n".utf8))
    exit(1)
}
let corpus = try JSONDecoder().decode(Corpus.self, from: data)

// MARK: - Run detectors

let dataDetector = AppleDataDetector()
let nameTagger = AppleNameTagger()

struct KindTally {
    var expected = 0
    var hit = 0
    var missedTexts: [String] = []
}

var tallies: [SensitiveKind: KindTally] = [:]
var unexpectedBySample: [(sample: String, matches: [DetectedMatch])] = []
var violationsBySample: [(sample: String, matches: [(DetectedMatch, String)])] = []

print("privmask — Apple built-in detector probe")
print("corpus: \(corpusPath)")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print(String(repeating: "=", count: 78))

for sample in corpus.samples {
    let detections = dataDetector.detect(in: sample.text) + nameTagger.detect(in: sample.text)

    // Ground-truth ranges, per expectation.
    var expectationRanges: [(Corpus.Expectation, [NSRange])] = sample.expected.map {
        ($0, occurrences(of: $0.text, in: sample.text))
    }

    // Warn loudly if the corpus itself is wrong: an expectation whose text does
    // not appear in the sample would silently count as a permanent miss.
    for (expectation, ranges) in expectationRanges where ranges.isEmpty {
        FileHandle.standardError.write(
            Data("CORPUS ERROR [\(sample.id)]: expected text not present: \(expectation.text)\n".utf8)
        )
    }
    expectationRanges = expectationRanges.filter { !$0.1.isEmpty }

    // Recall: did some detection of the same kind cover each expectation?
    for (expectation, ranges) in expectationRanges {
        var tally = tallies[expectation.kind] ?? KindTally()
        tally.expected += 1
        let wasHit = detections.contains { detection in
            detection.kind == expectation.kind && ranges.contains { overlaps(detection.range, $0) }
        }
        if wasHit {
            tally.hit += 1
        } else {
            tally.missedTexts.append(expectation.text)
        }
        tallies[expectation.kind] = tally
    }

    // Detections that match no expectation of the same kind.
    let unexpected = detections.filter { detection in
        !expectationRanges.contains { expectation, ranges in
            expectation.kind == detection.kind && ranges.contains { overlaps(detection.range, $0) }
        }
    }
    if !unexpected.isEmpty {
        unexpectedBySample.append((sample.id, unexpected))
    }

    // Detections that touch a span the corpus says must never be masked.
    var violations: [(DetectedMatch, String)] = []
    for forbidden in sample.mustNotDetect {
        let forbiddenRanges = occurrences(of: forbidden, in: sample.text)
        for detection in detections where forbiddenRanges.contains(where: { overlaps(detection.range, $0) }) {
            violations.append((detection, forbidden))
        }
    }
    if !violations.isEmpty {
        violationsBySample.append((sample.id, violations))
    }
}

// MARK: - Report

print("\n## Recall by kind\n")
print("kind                 covered   expected  hit  missed")
print(String(repeating: "-", count: 60))
for kind in SensitiveKind.allCases {
    guard let tally = tallies[kind] else { continue }
    let covered = appleCoveredKinds.contains(kind) ? "apple   " : "REGEX   "
    let name = kind.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
    let missed = tally.expected - tally.hit
    print("\(name) \(covered)  \(String(format: "%8d", tally.expected))  \(String(format: "%3d", tally.hit))  \(String(format: "%6d", missed))")
}

print("\n## Missed (false negatives)\n")
var anyMissed = false
for kind in SensitiveKind.allCases {
    guard let tally = tallies[kind], !tally.missedTexts.isEmpty else { continue }
    anyMissed = true
    let label = appleCoveredKinds.contains(kind) ? "" : "  [not covered by Apple APIs — regex layer's job]"
    print("\(kind.rawValue)\(label)")
    for text in tally.missedTexts {
        print("  - \(text)")
    }
}
if !anyMissed { print("(none)") }

print("\n## Unexpected detections (candidate false positives)\n")
if unexpectedBySample.isEmpty {
    print("(none)")
} else {
    for (sampleID, matches) in unexpectedBySample {
        print("[\(sampleID)]")
        for match in matches {
            print("  - \(match.kind.rawValue)/\(match.source.rawValue): \(match.text.debugDescription)")
        }
    }
}

print("\n## mustNotDetect violations (over-masking)\n")
if violationsBySample.isEmpty {
    print("(none)")
} else {
    for (sampleID, matches) in violationsBySample {
        print("[\(sampleID)]")
        for (match, forbidden) in matches {
            print("  - \(match.kind.rawValue)/\(match.source.rawValue): \(match.text.debugDescription) overlaps forbidden \(forbidden.debugDescription)")
        }
    }
}
