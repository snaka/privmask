import Foundation
import Testing

@testable import PrivMask

/// The surname list verifies what the language model returns, so a family name
/// missing from it is a name the model found and we discarded. See #22.
@Suite("Verifying a candidate against the family-name list")
struct JapaneseSurnameTests {
    /// The ten names measured in #22. The model returned every one of them and
    /// the 188-entry list rejected every one of them, leaving the text unmasked.
    @Test(
        "A family name outside the first couple of hundred is still a family name",
        arguments: [
            "滝口 健太", "尾形 真理子", "井出 淳一", "深谷 綾香", "市村 和也",
            "谷村 直樹", "玉置 沙織", "久田 亮", "畑山 恵", "福士 光男",
        ]
    )
    func acceptsNamesBeyondTheCommonest(name: String) {
        #expect(JapaneseSurnames.beginsWithSurname(name))
    }

    /// The list is matched as a prefix, so a single-kanji entry admits every word
    /// that starts with it. 東, 西, 新, 前, 今, 北, 所 and 見 are all real family
    /// names and all deliberately absent: with them, one common noun in five
    /// reaches the gate.
    @Test(
        "A word that merely begins with a single-kanji family name is not a name",
        arguments: [
            "東京都", "西日本", "新機能", "前提", "今回", "北海道", "所属", "見積書",
        ]
    )
    func rejectsWordsStartingWithASingleKanjiSurname(word: String) {
        #expect(!JapaneseSurnames.beginsWithSurname(word))
    }

    /// What the list exists for: the words the model reaches for when a text
    /// holds no names at all.
    @Test(
        "The words the model offers when there is no name are still rejected",
        arguments: ["緊急連絡先", "全角表記", "内線", "管理画面", "担当者", "作業手順"]
    )
    func rejectsTheModelsNearestAvailableWord(word: String) {
        #expect(!JapaneseSurnames.beginsWithSurname(word))
    }

    /// A katakana full name is written 「タキグチ ケンタ」, so the first token is
    /// matched in full rather than as a prefix.
    @Test(
        "A katakana family name outside the commonest readings is accepted",
        arguments: ["タキグチ ケンタ", "オガタ マリコ", "フカヤ アヤカ", "イチムラ カズヤ"]
    )
    func acceptsKatakanaReadingsBeyondTheCommonest(name: String) {
        #expect(JapaneseSurnames.beginsWithSurname(name))
    }

    /// One kanji spelling often has more than one reading, and the person
    /// writing their name in katakana is the one who knows which. 中田 is ナカタ
    /// or ナカダ, 河野 is カワノ or コウノ: keeping only the first reading of each
    /// spelling loses 523 of them, and whoever has the other one goes unmasked.
    @Test(
        "An alternative reading of the same family name is accepted too",
        arguments: ["ナカダ ユウジ", "コウノ サトシ", "ヤマザワ ミキ"]
    )
    func acceptsAlternativeReadings(name: String) {
        #expect(JapaneseSurnames.beginsWithSurname(name))
    }
}
