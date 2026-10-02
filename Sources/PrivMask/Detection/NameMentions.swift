import Foundation

/// The other mentions of a person whose full name was already found.
///
/// The model lists each person once. A text that names `佐古宗直` and later
/// says `佐古より` had the first masked and the second left in the output. On
/// the name corpus that was 134 occurrences whose full name was found in the
/// same input. This finds them deterministically, over the whole input, so a
/// mention in a later model chunk is caught too. See #36.
///
/// ponytail: a lone word equal to a found family name is masked even when it is
/// not the person (森が深い beside a 森さん). The corpus shows none; context
/// rules are the upgrade if real text does.
enum NameMentions {
    private static let honorifics = ["様", "さん", "氏", "くん", "ちゃん"]

    /// Further occurrences of the family and given parts of `matches`, each
    /// standing alone in `text` or followed by an honorific. Occurrences already
    /// covered by a match are left out.
    static func otherMentions(of matches: [DetectedMatch], in text: String) -> [DetectedMatch] {
        let nsText = text as NSString
        var covered = IndexSet()
        for match in matches { covered.insert(integersIn: match.range.location..<NSMaxRange(match.range)) }

        var seen: Set<String> = []
        var found: [DetectedMatch] = []
        for match in matches {
            let split = parts(of: match.text)
            guard split.count == 2 else { continue }
            // A one-character given name is too often an ordinary word.
            let candidates = [split[0]] + (split[1].count >= 2 ? [split[1]] : [])
            for part in candidates where seen.insert(part).inserted {
                for range in nsText.allRanges(of: part) {
                    guard !covered.contains(integersIn: range.location..<NSMaxRange(range)),
                          standsAlone(range, in: nsText) || isFollowedByHonorific(range, in: nsText)
                    else { continue }
                    covered.insert(integersIn: range.location..<NSMaxRange(range))
                    found.append(DetectedMatch(kind: .personalName, source: .languageModel, range: range, text: part))
                }
            }
        }
        return found
    }

    /// The family and given parts of a name, or nothing when it cannot be split.
    ///
    /// A space splits it. An unspaced kanji name is split where the family part
    /// is a listed family name and the rest a listed given name; failing that,
    /// where the rest alone is a listed given name (`五百旗頭堅至`, whose family
    /// name the list leaves out); failing that, after a listed family name of
    /// three or two kanji.
    static func parts(of name: String) -> [String] {
        var core = name.trimmingCharacters(in: .whitespaces)
        if let honorific = honorifics.first(where: { core.hasSuffix($0) }) {
            core = String(core.dropLast(honorific.count)).trimmingCharacters(in: .whitespaces)
        }

        let spaced = core.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map(String.init)
        if spaced.count >= 2 { return [spaced[0], spaced[spaced.count - 1]] }

        guard core.count >= 3, core.allSatisfy(isKanji) else { return [] }
        let splits = (1...min(5, core.count - 1)).map { (String(core.prefix($0)), String(core.dropFirst($0))) }
        if let split = splits.first(where: { JapaneseSurnames.kanji.contains($0.0) && JapaneseGivenNames.kanji.contains($0.1) })
            ?? splits.first(where: { JapaneseGivenNames.kanji.contains($0.1) && $0.0.count >= 1 })
            ?? splits.reversed().first(where: { $0.0.count >= 2 && $0.0.count <= 3 && JapaneseSurnames.kanji.contains($0.0) })
        {
            return [split.0, split.1]
        }
        return []
    }

    /// No kanji directly before or after the range, so it is not part of a
    /// longer word: `森` in `森林` is not the person 森.
    private static func standsAlone(_ range: NSRange, in text: NSString) -> Bool {
        let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let afterLocation = NSMaxRange(range)
        let after = afterLocation < text.length ? text.substring(with: NSRange(location: afterLocation, length: 1)) : ""
        return !before.contains(where: isKanji) && !after.contains(where: isKanji)
    }

    private static func isFollowedByHonorific(_ range: NSRange, in text: NSString) -> Bool {
        let rest = text.substring(from: NSMaxRange(range))
        let trimmed = rest.hasPrefix(" ") || rest.hasPrefix("\u{3000}") ? String(rest.dropFirst()) : rest
        return honorifics.contains(where: trimmed.hasPrefix)
    }

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005, 0x3006, 0x30F6: return true
            default: return false
            }
        }
    }
}
