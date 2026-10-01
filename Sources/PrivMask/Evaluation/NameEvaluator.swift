import Foundation

/// Scores one system's personal-name detections against a name corpus.
///
/// Unlike `Evaluator`, a hit is not any overlap. privmask replaces what it
/// detects, so a detection that covers 田中 of 田中健一 leaves 健一 in the
/// output: that is `partial`, and partial is not recall. Detections are pooled,
/// so 田中 and 健一 found separately still cover 田中 健一. Whitespace and the
/// katakana middle dot inside the name need not be covered. See #28.
public enum NameEvaluator {
    public enum Outcome: String, Sendable { case covered, partial, missed }
    public enum MissCause: String, Sendable { case filterRejected, neverReturned }

    /// Mirrors `FoundationModelDetector.defaultCharacterLimit`, which this
    /// target cannot reference below macOS 26.
    private static let modelChunkCharacters = 1500

    public struct ExpectedName: Sendable {
        public let sampleID: String
        public let text: String
        public let range: NSRange
        public let tags: [NameTag]
        public let genre: Genre?
        public let writer: Writer?
        /// The name contains whitespace, U+3000 included. Computed, not tagged.
        public let spaced: Bool
        /// This occurrence falls inside a model chunk other than the first, as
        /// the detector chunks the sample. A line with no Japanese is never sent
        /// to the model, so a name there is not late. Computed, not tagged.
        public let late: Bool
        /// Whether the family name is on our list. Non-nil only for a kanji or
        /// katakana name that begins with a family name (`full` or `familyOnly`);
        /// nil for given-name-only, romaji, hiragana and mixed names.
        public let beginsWithListedSurname: Bool?
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
            // As the detector chunks: only the first chunk is "early".
            let laterChunks = JapaneseText.batches(
                JapaneseText.japaneseLines(of: sample.text), characterLimit: modelChunkCharacters
            ).dropFirst()
            let entry = detections.samples[sample.id]
            if entry == nil { unexamined.append(sample.id) }

            var found: [NSRange] = []
            for name in entry?.names ?? [] {
                if (name.location == nil) != (name.length == nil) {
                    invalid.append("[\(sample.id)] \(name.text.debugDescription) has \(name.location == nil ? "length but no location" : "location but no length")")
                    continue
                }
                if let location = name.location, let length = name.length {
                    guard location >= 0, location <= text.length, length > 0, length <= text.length - location else {
                        invalid.append("[\(sample.id)] \(name.text.debugDescription) at \(location)+\(length)")
                        continue
                    }
                    let range = NSRange(location: location, length: length)
                    let actual = text.substring(with: range)
                    guard actual == name.text else {
                        invalid.append("[\(sample.id)] \(name.text.debugDescription) at \(location)+\(length) does not match \(actual.debugDescription)")
                        continue
                    }
                    found.append(range)
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

            var candidates: [(range: NSRange, expectation: Corpus.Expectation)] = []
            for expectation in sample.expected where expectation.kind == .personalName {
                for range in text.allRanges(of: expectation.text) { candidates.append((range, expectation)) }
            }
            // A string nested inside another expected name (林 in 小林) is the
            // same name, not a second one; identical spans count once.
            var kept: [(range: NSRange, expectation: Corpus.Expectation)] = []
            for c in candidates {
                let nested = candidates.contains { o in
                    o.range != c.range && NSIntersectionRange(o.range, c.range) == c.range
                }
                if !nested && !kept.contains(where: { $0.range == c.range }) { kept.append(c) }
            }

            let rejected = entry?.rejected ?? []
            var nameRanges: [NSRange] = []
            for (range, expectation) in kept {
                nameRanges.append(range)
                let outcome = outcome(of: range, in: text, covered: covered)
                let tags = expectation.tags ?? []
                let isFamilyName = !Set(tags).isDisjoint(with: [.kanji, .katakana]) && !Set(tags).isDisjoint(with: [.full, .familyOnly])
                expected.append(ExpectedName(
                    sampleID: sample.id,
                    text: expectation.text,
                    range: range,
                    tags: tags,
                    genre: sample.genre,
                    writer: sample.writer,
                    spaced: expectation.text.unicodeScalars.contains { CharacterSet.whitespaces.contains($0) },
                    late: laterChunks.contains { batch in
                        batch.mapping.contains { range.location >= $0.originalOffset && NSMaxRange(range) <= $0.originalOffset + $0.length }
                    },
                    beginsWithListedSurname: isFamilyName ? JapaneseSurnames.beginsWithSurname(expectation.text) : nil,
                    outcome: outcome,
                    cause: outcome != .missed ? nil
                        : rejected.contains { $0.contains(expectation.text) } ? .filterRejected
                        : .neverReturned
                ))
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

    /// Covered when every UTF-16 unit that is not whitespace or a katakana middle dot of the name is covered.
    /// A surrogate unit is never whitespace, so a non-BMP kanji must be covered
    /// in full.
    private static func outcome(of name: NSRange, in text: NSString, covered: IndexSet) -> Outcome {
        var required = IndexSet()
        for index in name.location..<NSMaxRange(name) {
            let unit = text.character(at: index)
            if let scalar = Unicode.Scalar(unit),
               CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{30FB}" || scalar == "\u{FF65}" { continue }
            required.insert(index)
        }
        if !required.isEmpty && covered.contains(integersIn: required) { return .covered }
        return covered.intersects(integersIn: name.location..<NSMaxRange(name)) ? .partial : .missed
    }
}

extension NameEvaluator {
    public struct Tally: Sendable, Equatable {
        public var expected = 0
        public var covered = 0
        public var partial = 0

        public init(expected: Int = 0, covered: Int = 0, partial: Int = 0) {
            self.expected = expected
            self.covered = covered
            self.partial = partial
        }
    }
}

extension NameEvaluator.Report {
    /// Recall split every way the corpus records. The order is fixed, so that
    /// reports for different systems over one corpus line up row for row.
    public var breakdown: [(label: String, tally: NameEvaluator.Tally)] {
        var rows: [(String, (NameEvaluator.ExpectedName) -> Bool)] = [("all", { _ in true })]
        rows += NameTag.allCases.map { tag in ("tag:\(tag.rawValue)", { $0.tags.contains(tag) }) }
        rows += [("spaced", { $0.spaced }), ("late", { $0.late })]
        rows += Genre.allCases.map { genre in ("genre:\(genre.rawValue)", { $0.genre == genre }) }
        rows += Writer.allCases.map { writer in ("writer:\(writer.rawValue)", { $0.writer == writer }) }
        rows += [("surname:listed", { $0.beginsWithListedSurname == true }),
                 ("surname:unlisted", { $0.beginsWithListedSurname == false })]

        return rows.compactMap { label, matches in
            var tally = NameEvaluator.Tally()
            for name in expected where matches(name) {
                tally.expected += 1
                if name.outcome == .covered { tally.covered += 1 }
                if name.outcome == .partial { tally.partial += 1 }
            }
            return tally.expected == 0 ? nil : (label, tally)
        }
    }
}

extension NameEvaluator {
    /// One table with a column per system, then each system's misses and false
    /// positives. Every report must come from the same corpus.
    public static func renderComparison(_ reports: [Report]) -> String {
        func percent(_ value: Double?) -> String {
            value.map { String(format: "%5.1f%%", $0 * 100) } ?? "     —"
        }
        let width = max(16, (reports.map { $0.system.count }.max() ?? 0) + 2)
        func cell(_ text: String) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
        func rowCell(_ text: String) -> String { text.padding(toLength: 16, withPad: " ", startingAt: 0) }

        var out = "## Recall (covered / expected)\n\n"
        out += rowCell("row") + "     n  " + reports.map { cell($0.system) }.joined() + "\n"
        // Rows with nothing expected are dropped per report, so line reports up
        // by label: the union in first-seen order, "—" where a report has none.
        let breakdowns = reports.map { Dictionary($0.breakdown.map { ($0.label, $0.tally) }, uniquingKeysWith: { first, _ in first }) }
        var labels: [String] = []
        for report in reports { for row in report.breakdown where !labels.contains(row.label) { labels.append(row.label) } }
        for label in labels {
            let n = breakdowns.lazy.compactMap { $0[label]?.expected }.first ?? 0
            out += rowCell(label) + String(format: "%6d  ", n)
            out += breakdowns.map { rows in
                guard let tally = rows[label] else { return cell("     —") }
                return cell("\(percent(Double(tally.covered) / Double(tally.expected))) p\(tally.partial)")
            }.joined()
            out += "\n"
        }

        out += "\n## Precision\n\n"
        for report in reports {
            out += "\(cell(report.system)) \(percent(report.precision))  "
            out += "\(report.falsePositives.count) false positives of \(report.detectionCount) detections\n"
        }

        for report in reports {
            out += "\n## \(report.system)\n\n"
            let misses = report.expected.filter { $0.outcome != .covered }
            out += "missed or partial (\(misses.count)):\n"
            for name in misses {
                let why = name.outcome == .partial ? "partial" : name.cause?.rawValue ?? ""
                out += "  [\(name.sampleID)] \(name.text)  \(why)\n"
            }
            out += "false positives (\(report.falsePositives.count)):\n"
            for fp in report.falsePositives { out += "  [\(fp.sampleID)] \(fp.text.debugDescription)\n" }
            if !report.unexaminedSampleIDs.isEmpty {
                out += "UNEXAMINED samples, scored as missed: \(report.unexaminedSampleIDs.joined(separator: ", "))\n"
            }
            if !report.unknownSampleIDs.isEmpty {
                out += "UNKNOWN sample ids, ignored: \(report.unknownSampleIDs.joined(separator: ", "))\n"
            }
            for problem in report.invalidDetections { out += "INVALID detection: \(problem)\n" }
        }
        return out
    }
}
