import Foundation

/// Scores one system's personal-name detections against a name corpus.
///
/// Unlike `Evaluator`, a hit is not any overlap. privmask replaces what it
/// detects, so a detection that covers 田中 of 田中健一 leaves 健一 in the
/// output: that is `partial`, and partial is not recall. Detections are pooled,
/// so 田中 and 健一 found separately still cover 田中 健一. Whitespace inside
/// the name need not be covered. See #28.
public enum NameEvaluator {
    public enum Outcome: String, Sendable { case covered, partial, missed }
    public enum MissCause: String, Sendable { case filterRejected, neverReturned }

    public struct ExpectedName: Sendable {
        public let sampleID: String
        public let text: String
        public let range: NSRange
        public let tags: [NameTag]
        public let genre: Genre?
        public let writer: Writer?
        public let beginsWithListedSurname: Bool
        public let outcome: Outcome
        /// Set only when `outcome` is `.missed`.
        public let cause: MissCause?
    }

    public struct FalsePositive: Sendable {
        public let sampleID: String
        public let text: String
        public let range: NSRange
    }

    public struct Report: Sendable {
        public let system: String
        public let expected: [ExpectedName]
        public let falsePositives: [FalsePositive]
        public let detectionCount: Int
        /// Ids in the detections file that the corpus does not have: a typo or
        /// a stale file, and never scored.
        public let unknownSampleIDs: [String]
        /// Corpus samples the file has no entry for. Their names are scored as
        /// missed, because a sample nobody examined is text nobody masked.
        public let unexaminedSampleIDs: [String]
        /// Detections that could not be placed: offsets outside the text, or a
        /// string that does not occur in it.
        public let invalidDetections: [String]

        public var recall: Double? {
            guard !expected.isEmpty else { return nil }
            return Double(expected.filter { $0.outcome == .covered }.count) / Double(expected.count)
        }

        public var precision: Double? {
            guard detectionCount > 0 else { return nil }
            return Double(detectionCount - falsePositives.count) / Double(detectionCount)
        }
    }

    public static func evaluate(corpus: Corpus, detections: DetectionsFile) -> Report {
        var expected: [ExpectedName] = []
        var falsePositives: [FalsePositive] = []
        var detectionCount = 0
        var unexamined: [String] = []
        var invalid: [String] = []

        for sample in corpus.samples {
            let text = sample.text as NSString
            let entry = detections.samples[sample.id]
            if entry == nil { unexamined.append(sample.id) }

            var found: [NSRange] = []
            for name in entry?.names ?? [] {
                if let location = name.location, let length = name.length {
                    guard location >= 0, length > 0, location + length <= text.length else {
                        invalid.append("[\(sample.id)] \(name.text.debugDescription) at \(location)+\(length)")
                        continue
                    }
                    found.append(NSRange(location: location, length: length))
                } else {
                    let hits = text.allRanges(of: name.text)
                    if hits.isEmpty {
                        invalid.append("[\(sample.id)] \(name.text.debugDescription) does not occur")
                    }
                    found += hits
                }
            }
            found = Array(Set(found)).sorted { ($0.location, $0.length) < ($1.location, $1.length) }
            detectionCount += found.count

            var covered = IndexSet()
            for range in found { covered.insert(integersIn: range.location..<NSMaxRange(range)) }

            var nameRanges: [NSRange] = []
            for expectation in sample.expected where expectation.kind == .personalName {
                for range in text.allRanges(of: expectation.text) {
                    nameRanges.append(range)
                    let outcome = outcome(of: range, in: text, covered: covered)
                    let rejected = entry?.rejected ?? []
                    expected.append(ExpectedName(
                        sampleID: sample.id,
                        text: expectation.text,
                        range: range,
                        tags: expectation.tags ?? [],
                        genre: sample.genre,
                        writer: sample.writer,
                        beginsWithListedSurname: JapaneseSurnames.beginsWithSurname(expectation.text),
                        outcome: outcome,
                        cause: outcome != .missed ? nil
                            : rejected.contains { $0.contains(expectation.text) } ? .filterRejected
                            : .neverReturned
                    ))
                }
            }

            for range in found where !nameRanges.contains(where: { rangesOverlap($0, range) }) {
                falsePositives.append(FalsePositive(sampleID: sample.id, text: text.substring(with: range), range: range))
            }
        }

        let corpusIDs = Set(corpus.samples.map(\.id))
        return Report(
            system: detections.system,
            expected: expected,
            falsePositives: falsePositives,
            detectionCount: detectionCount,
            unknownSampleIDs: detections.samples.keys.filter { !corpusIDs.contains($0) }.sorted(),
            unexaminedSampleIDs: unexamined,
            invalidDetections: invalid
        )
    }

    /// Covered when every non-whitespace UTF-16 unit of the name is covered.
    /// A surrogate unit is never whitespace, so a non-BMP kanji must be covered
    /// in full.
    private static func outcome(of name: NSRange, in text: NSString, covered: IndexSet) -> Outcome {
        var required = IndexSet()
        for index in name.location..<NSMaxRange(name) {
            let unit = text.character(at: index)
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            required.insert(index)
        }
        if !required.isEmpty && covered.contains(integersIn: required) { return .covered }
        return covered.intersects(integersIn: name.location..<NSMaxRange(name)) ? .partial : .missed
    }
}
