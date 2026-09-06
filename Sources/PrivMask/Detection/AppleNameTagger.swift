import Foundation
import NaturalLanguage

/// Wraps `NLTagger`'s named-entity recogniser, for English text only.
///
/// `NameType` is not offered for Japanese at all, so this detector cannot see
/// Japanese names — those come from the on-device model instead. It is kept
/// because it is deterministic, instant, and free, and because English names do
/// appear in the text this tool is pointed at.
///
/// Only `personalName` is reported. `placeName` tagged `SwiftNIO` as a place and
/// `organizationName` fired on a hostname, so neither is a usable masking signal.
/// See docs/findings/apple-detector-baseline.md.
public struct AppleNameTagger {
    public init() {}

    public func detect(in text: String) -> [DetectedMatch] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var results: [DetectedMatch] = []
        let nsText = text as NSString
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard tag == .personalName else { return true }
            let matched = String(text[range])
            // Any span containing Japanese is noise here by construction: the
            // tagger has no Japanese entity model to have found it with.
            guard !JapaneseText.containsJapanese(matched) else { return true }
            let nsRange = NSRange(range, in: text)
            results.append(
                DetectedMatch(
                    kind: .personalName,
                    source: .nameTagger,
                    range: nsRange,
                    text: nsText.substring(with: nsRange)
                )
            )
            return true
        }
        return results
    }
}
