import Foundation

/// The rules a name corpus must follow for `NameEvaluator`'s numbers to mean
/// anything. See #28.
///
/// Each name carries exactly one script tag and exactly one form tag.
///
/// Two rules cannot be checked here and are the reviewer's: that every name in
/// a text is listed, and that every name is fictional.
public enum NameCorpusCheck {
    private static let scripts: Set<NameTag> = [.kanji, .hiragana, .katakana, .romaji, .mixed]
    private static let forms: Set<NameTag> = [.full, .familyOnly, .givenOnly]
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
                let scriptCount = tags.intersection(scripts).count
                if scriptCount == 0 { problems.append("[\(id)] \(name): no script tag") }
                if scriptCount > 1 { problems.append("[\(id)] \(name): more than one script tag") }
                let formCount = tags.intersection(forms).count
                if formCount == 0 { problems.append("[\(id)] \(name): no form tag") }
                if formCount > 1 { problems.append("[\(id)] \(name): more than one form tag") }

                if ranges.contains(where: { range in forbidden.contains { rangesOverlap($0, range) } }) {
                    problems.append("[\(id)] \(name): also inside a mustNotDetect string")
                }
            }
        }
        return problems
    }
}
