import Foundation

/// Hiragana words that are grammar rather than names, used to *verify*
/// candidates the language model returns — never to detect them.
///
/// This is the hiragana counterpart of `JapaneseSurnames`, and it exists for the
/// same reason. The model reaches for the nearest available word when a text
/// contains no names at all. A kanji or katakana span is checked against the
/// family-name list and rejected; a hiragana span had nothing to check against,
/// so it came through whole. On a real payload the sentence
/// `どこを見れば良いのでしょうか？` was masked as `[NAME_1]を見れば良い[NAME_2]？`,
/// destroying the text it was meant to protect. See #15.
///
/// The list is deliberately not exhaustive, and it is a denial list rather than
/// an allow list of names. Hiragana given names are an open set: `さくら`,
/// `ひなた`, `つむぎ` and the rest cannot be enumerated, so an allow list would
/// cost a real name every time it was short. Denying instead means a word
/// missing from this list costs one false positive on a low-confidence finding
/// the user still sees flagged.
public enum JapaneseNonNameWords {
    /// Demonstratives, interrogatives and the set phrases that open and close a
    /// message, matched in full.
    ///
    /// Exact rather than by prefix, so `ここ` cannot take `こころ` and `いつ`
    /// cannot take `いつき`.
    ///
    /// `どこ` is the entry a real payload paid for. The rest of its paradigm is
    /// here because that paradigm is a closed class — there is no other `こ/そ/
    /// あ/ど` series to discover later — not because each was observed.
    ///
    /// The manner series `こう / そう / ああ / どう` is deliberately absent. Two
    /// of its members are common given names: 蒼 and 奏 are written そう, 航 and
    /// 光 こう. An entry here that is also a name loses that name in silence,
    /// which is precisely the failure that ruled out an allow list of names. The
    /// same reasoning keeps 成 (なる) out. Where a word is both, the name wins:
    /// a false positive is visible and a missed name is not.
    static let exact: Set<String> = [
        "これ", "それ", "あれ", "どれ",
        "ここ", "そこ", "あそこ", "どこ",
        "こちら", "そちら", "あちら", "どちら",
        "この", "その", "あの", "どの",
        "だれ", "どなた", "なに", "なぜ", "いつ", "いくら", "いかが",
        "ありがとう", "よろしく", "おねがい", "すみません", "おつかれ",
    ]

    /// Sentence-final and auxiliary forms, matched at the end of the span.
    ///
    /// Suffix matching is what reaches `のでしょうか`, which the model returned
    /// as one span: no exact entry would have caught it, because the `の` in
    /// front belongs to the clause before it.
    ///
    /// Every entry is at least three characters. A shorter one would reach into
    /// names — `か` alone ends `はるか`, `あすか` and `ゆか`.
    ///
    /// There is no prefix equivalent, and there must not be: `のぞみ` is a name
    /// that begins with a particle, which is why `startsAContinuation` applies
    /// its particle rule only from the second token onward.
    static let suffixes: [String] = [
        "でしょうか", "でしょう", "ましょう",
        "ですか", "ますか", "ですね", "ますね",
        "ました", "ません", "でした", "ください", "くださる",
        "います", "あります", "だろう",
    ]

    /// True when a hiragana-only span is grammar rather than a name.
    public static func isGrammar(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if exact.contains(trimmed) { return true }
        return suffixes.contains { trimmed.hasSuffix($0) }
    }
}
