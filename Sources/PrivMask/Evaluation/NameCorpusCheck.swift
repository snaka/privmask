import Foundation

/// The rules a name corpus must follow for `NameEvaluator`'s numbers to mean
/// anything. See #28.
///
/// Two rules cannot be checked here and are the reviewer's: that every name in
/// a text is listed, and that every name is fictional.
public enum NameCorpusCheck {
    private static let scripts: Set<NameTag> = [.kanji, .hiragana, .katakana, .romaji, .mixed]
    private static let forms: Set<NameTag> = [.full, .familyOnly, .givenOnly]
    /// Characters before which a name does not count as `late`. Matches
    /// `FoundationModelDetector.defaultCharacterLimit`, which this target cannot
    /// reference below macOS 26.
    private static let lateAfter = 1500

    public static func problems(in corpus: Corpus) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []

        for sample in corpus.samples {
            let id = sample.id
            if !seen.insert(id).inserted { problems.append("[\(id)] duplicate id") }
            if sample.genre == nil { problems.append("[\(id)] no genre") }
            if sample.writer == nil { problems.append("[\(id)] no writer") }

            let text = sample.text as NSString
            let forbidden = sample.mustNotDetect.flatMap { text.allRanges(of: $0) }

            for expectation in sample.expected {
                let name = expectation.text
                guard expectation.kind == .personalName else {
                    problems.append("[\(id)] \(name): kind \(expectation.kind.rawValue) in a name corpus")
                    continue
                }
                let ranges = text.allRanges(of: name)
                if ranges.isEmpty { problems.append("[\(id)] \(name): not in the text") }

                let tags = Set(expectation.tags ?? [])
                if tags.isDisjoint(with: scripts) { problems.append("[\(id)] \(name): no script tag") }
                if tags.isDisjoint(with: forms) { problems.append("[\(id)] \(name): no form tag") }

                if ranges.contains(where: { range in forbidden.contains { rangesOverlap($0, range) } }) {
                    problems.append("[\(id)] \(name): also inside a mustNotDetect string")
                }

                if let first = sample.text.range(of: name) {
                    let before = sample.text.distance(from: sample.text.startIndex, to: first.lowerBound)
                    if tags.contains(.late), before < lateAfter {
                        problems.append("[\(id)] \(name): tagged late but has fewer than \(lateAfter) characters before it")
                    } else if !tags.contains(.late), before >= lateAfter {
                        problems.append("[\(id)] \(name): starts after \(lateAfter) characters but is not tagged late")
                    }
                }
            }
        }
        return problems
    }
}
