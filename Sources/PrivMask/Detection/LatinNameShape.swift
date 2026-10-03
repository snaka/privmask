import Foundation
import NaturalLanguage

/// Whether Latin text the language model returned can be a personal name.
///
/// Kanji and katakana candidates are checked against `JapaneseSurnames`, and
/// hiragana against `JapaneseNonNameWords`. Latin text used to pass unchecked,
/// on the grounds that `AppleNameTagger` covers English names. But what the model
/// returns in Latin script is mostly not English names: on the name corpus it
/// returned `orders-db`, `lb-orders-01` and `nightly-sync-12`, and masking those
/// destroys the runbooks and logs this tool is for. See #32.
///
/// A candidate passes if it reads as romaji, which covers user ids such as
/// `funatsu.keigo`, or if it is shaped like a Western personal name. The second
/// test is not redundant with `AppleNameTagger`: `Michael O'Connor` in a
/// Japanese sentence is found by the model and missed by NLTagger.
///
/// A Western-shaped candidate must also be tagged a personal name by NLTagger,
/// read in English: `Android` and `Google Play Console` have the shape and were
/// masked until it was. See #40.
///
/// ponytail: romaji-shaped English words (`INFO`, `region`) still pass the romaji
/// test, which NLTagger cannot judge for a single romaji token. A small stop-list
/// is the upgrade if they recur.
enum LatinNameShape {
    static func isNameShaped(_ text: String) -> Bool {
        let normalised = text.precomposedStringWithCompatibilityMapping
        return readsAsRomaji(normalised) || (isWesternName(normalised) && taggedAsPerson(normalised))
    }

    /// One Japanese syllable: a vowel; a consonant, or a consonant pair such as
    /// `ky`, `sh`, `ch` or `ts`, followed by a vowel; a syllabic `n`; or the first
    /// half of a doubled consonant (`kk`, and the `t` of `tch`).
    private static let romajiToken = try! NSRegularExpression(
        pattern: "^(?:[aiueo]|(?:ky|gy|sh|sy|zy|jy|ch|cy|ty|dy|ny|hy|by|py|my|ry|ts)[aiueo]|[kgsztdnhbpmrywfjv][aiueo]|n(?![aiueoy])|([kgsztdhbpmrfjc])(?=\\1|ch))+$"
    )

    /// Every token reads as romaji. Tokens are split on space, `.`, `_` and `-`.
    /// Tokens made only of digits are ignored, so `IiiTake_01` passes, and so
    /// are tokens of one ASCII letter, so an initial or a one-letter suffix
    /// (`S. Suguri`, `koyaba_j`) passes. At least one token must be left: `S. K`
    /// fails.
    static func readsAsRomaji(_ text: String) -> Bool {
        let tokens = text.lowercased()
            .split(whereSeparator: { " ._-\u{3000}".contains($0) })
            .map(String.init)
            .filter { !$0.allSatisfy(\.isNumber) && !($0.count == 1 && $0.first!.isASCII && $0.first!.isLetter) }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            let range = NSRange(token.startIndex..., in: token)
            return romajiToken.firstMatch(in: token, range: range) != nil
        }
    }

    /// A capital followed by lower case, optionally joined by `'` or `-` to a
    /// further capitalised part (`O'Connor`, `Mary-Jane`) or running straight
    /// into one (`McDonald`).
    private static let westernWord = try! NSRegularExpression(
        pattern: "^[A-Z][a-z]*(?:['’-]?[A-Z][a-z]+)*$|^[A-Z][a-z]+(?:['’-][a-z]+)*$"
    )

    /// One to four space-separated capitalised words, each with some lower case.
    /// All capitals is rejected: allowing it lets `ORD-OPS` back in.
    static func isWesternName(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard word.contains(where: \.isLowercase) else { return false }
            let range = NSRange(word.startIndex..., in: word)
            return westernWord.firstMatch(in: word, range: range) != nil
        }
    }

    /// Where the candidate is read: alone, and in a neutral English sentence.
    /// Either one tagging it a person is enough.
    ///
    /// On independent lists of 240 names across twelve regions and 240 product,
    /// team and place names, the pair kept 98.8% of the names and let 13.3% of
    /// the others through. Shape alone let 92.9% through. The sentence alone
    /// kept 97.9%, and every name it lost was Asian; reading alone as well gets
    /// back `Seungwoo Song` and `Meera Mehta`. See #40.
    private static let probes = [("", ""), ("Please ask ", " about it.")]

    /// Whether NLTagger, reading the candidate in English, calls it a personal
    /// name.
    static func taggedAsPerson(_ text: String) -> Bool {
        probes.contains { prefix, suffix in
            let sentence = prefix + text + suffix
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = sentence
            tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
            var person = false
            tagger.enumerateTags(
                in: sentence.range(of: text)!, unit: .word, scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, _ in
                if tag == .personalName { person = true }
                return !person
            }
            return person
        }
    }
}
