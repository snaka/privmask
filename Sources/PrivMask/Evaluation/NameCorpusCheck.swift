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
                if scriptCount == 1, let tagged = tags.intersection(scripts).first,
                   let written = writtenScript(of: name), tagged != written {
                    problems.append("[\(id)] \(name): tagged \(tagged.rawValue) but written in \(written.rawValue)")
                }
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

    /// The script a name is written in, as the script tag should say: one of
    /// kanji, hiragana, katakana or romaji, or `mixed` for more than one.
    /// Separators and digits belong to no script. `nil` when there is nothing to
    /// judge by.
    static func writtenScript(of name: String) -> NameTag? {
        var found: Set<NameTag> = []
        for scalar in name.precomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.value {
            // 々 and 〆 repeat or abbreviate kanji, and ヶ sits inside kanji names
            // (田ヶ原), so all three count as kanji.
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005, 0x3006, 0x30F6:
                found.insert(.kanji)
            // The voicing marks (U+3099–309C) sit in the hiragana block but mark
            // katakana as often: NFKC turns half-width ﾊﾞ into ハ plus U+3099.
            case 0x3099...0x309C:
                break
            case 0x3041...0x3098, 0x309D...0x309F:
                found.insert(.hiragana)
            // The middle dot and the long-vowel mark are katakana punctuation.
            case 0x30A0...0x30FF:
                found.insert(.katakana)
            case 0x41...0x5A, 0x61...0x7A:
                found.insert(.romaji)
            default:
                break
            }
        }
        if found.count > 1 { return .mixed }
        return found.first
    }
}
