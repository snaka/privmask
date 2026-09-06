import Foundation
import NaturalLanguage

/// Wraps `NLTagger`'s named-entity recogniser.
///
/// All three entity types are reported: personal names are the target, while
/// organisation and place names are measured because they overlap with the user
/// dictionary (company names) and with addresses.
public struct AppleNameTagger {
    public init() {}

    public func detect(in text: String) -> [DetectedMatch] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        // Without this, the tagger reports many single-character noise spans in
        // Japanese, where there are no word boundaries to anchor on.
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var results: [DetectedMatch] = []
        let nsText = text as NSString
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag else { return true }
            let kind: SensitiveKind
            switch tag {
            case .personalName: kind = .personalName
            case .organizationName: kind = .organizationName
            case .placeName: kind = .placeName
            default: return true
            }
            let nsRange = NSRange(range, in: text)
            results.append(
                DetectedMatch(
                    kind: kind,
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
