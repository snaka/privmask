import Foundation

/// Scores a set of detections against a corpus.
public enum Evaluator {
    public struct KindTally: Sendable {
        public let kind: SensitiveKind
        public var expected: Int = 0
        public var hit: Int = 0
        public var missedTexts: [String] = []
        public var missed: Int { expected - hit }
    }

    public struct Unexpected: Sendable {
        public let sampleID: String
        public let matches: [DetectedMatch]
    }

    public struct Violation: Sendable {
        public let sampleID: String
        public let match: DetectedMatch
        public let forbiddenText: String
    }

    public struct Report: Sendable {
        public let tallies: [KindTally]
        public let unexpected: [Unexpected]
        public let violations: [Violation]
        /// Expectations whose text does not occur in the sample. A corpus bug:
        /// these would otherwise count as permanent, unfixable misses.
        public let corpusErrors: [String]
    }

    /// - Parameter detections: detections keyed by sample id.
    public static func evaluate(corpus: Corpus, detections: [String: [DetectedMatch]]) -> Report {
        var tallies: [SensitiveKind: KindTally] = [:]
        var unexpected: [Unexpected] = []
        var violations: [Violation] = []
        var corpusErrors: [String] = []

        for sample in corpus.samples {
            let found = detections[sample.id] ?? []
            let nsText = sample.text as NSString

            var grounded: [(Corpus.Expectation, [NSRange])] = []
            for expectation in sample.expected {
                let ranges = nsText.allRanges(of: expectation.text)
                if ranges.isEmpty {
                    corpusErrors.append("[\(sample.id)] expected text not present: \(expectation.text)")
                } else {
                    grounded.append((expectation, ranges))
                }
            }

            for (expectation, ranges) in grounded {
                var tally = tallies[expectation.kind] ?? KindTally(kind: expectation.kind)
                tally.expected += 1
                let wasHit = found.contains { match in
                    match.kind == expectation.kind && ranges.contains { rangesOverlap(match.range, $0) }
                }
                if wasHit {
                    tally.hit += 1
                } else {
                    tally.missedTexts.append(expectation.text)
                }
                tallies[expectation.kind] = tally
            }

            let extras = found.filter { match in
                !grounded.contains { expectation, ranges in
                    expectation.kind == match.kind && ranges.contains { rangesOverlap(match.range, $0) }
                }
            }
            if !extras.isEmpty {
                unexpected.append(Unexpected(sampleID: sample.id, matches: extras))
            }

            for forbidden in sample.mustNotDetect {
                let forbiddenRanges = nsText.allRanges(of: forbidden)
                for match in found where forbiddenRanges.contains(where: { rangesOverlap(match.range, $0) }) {
                    violations.append(
                        Violation(sampleID: sample.id, match: match, forbiddenText: forbidden)
                    )
                }
            }
        }

        let ordered = SensitiveKind.allCases.compactMap { tallies[$0] }
        return Report(
            tallies: ordered,
            unexpected: unexpected,
            violations: violations,
            corpusErrors: corpusErrors
        )
    }
}

// MARK: - Text rendering

extension Evaluator.Report {
    public func rendered(coveredKinds: Set<SensitiveKind>, coveredLabel: String) -> String {
        var out = ""

        out += "\n## Recall by kind\n\n"
        out += "kind                 source    expected  hit  missed\n"
        out += String(repeating: "-", count: 60) + "\n"
        for tally in tallies {
            let source = coveredKinds.contains(tally.kind) ? coveredLabel : "—       "
            let name = tally.kind.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
            out += "\(name) \(source.padding(toLength: 8, withPad: " ", startingAt: 0))  "
            out += String(format: "%8d  %3d  %6d\n", tally.expected, tally.hit, tally.missed)
        }

        out += "\n## Missed (false negatives)\n\n"
        let missedTallies = tallies.filter { !$0.missedTexts.isEmpty }
        if missedTallies.isEmpty {
            out += "(none)\n"
        } else {
            for tally in missedTallies {
                out += "\(tally.kind.rawValue)\n"
                for text in tally.missedTexts { out += "  - \(text)\n" }
            }
        }

        out += "\n## Unexpected detections (candidate false positives)\n\n"
        if unexpected.isEmpty {
            out += "(none)\n"
        } else {
            for entry in unexpected {
                out += "[\(entry.sampleID)]\n"
                for match in entry.matches {
                    out += "  - \(match.kind.rawValue)/\(match.source.rawValue): \(match.text.debugDescription)\n"
                }
            }
        }

        out += "\n## mustNotDetect violations (over-masking)\n\n"
        if violations.isEmpty {
            out += "(none)\n"
        } else {
            for violation in violations {
                out += "[\(violation.sampleID)] \(violation.match.kind.rawValue)/\(violation.match.source.rawValue): "
                out += "\(violation.match.text.debugDescription) overlaps \(violation.forbiddenText.debugDescription)\n"
            }
        }

        if !corpusErrors.isEmpty {
            out += "\n## Corpus errors\n\n"
            for error in corpusErrors { out += "  \(error)\n" }
        }

        return out
    }
}
