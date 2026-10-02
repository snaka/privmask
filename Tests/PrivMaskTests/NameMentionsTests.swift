import Foundation
import Testing

@testable import PrivMask

/// The model lists each person once, so `佐古` further down a text whose `佐古宗直`
/// was found was left unmasked. See #36.
@Suite("Later mentions of a found name")
struct NameMentionsTests {
    private func found(_ name: String, in text: String) -> [DetectedMatch] {
        let range = (text as NSString).range(of: name)
        return [DetectedMatch(kind: .personalName, source: .languageModel, range: range, text: name)]
    }

    private func mentions(_ name: String, in text: String) -> [String] {
        NameMentions.otherMentions(of: found(name, in: text), in: text).map(\.text)
    }

    @Test("A name is split on its space, or by the family and given lists")
    func splits() {
        #expect(NameMentions.parts(of: "井出 奈保美") == ["井出", "奈保美"])
        #expect(NameMentions.parts(of: "佐古宗直") == ["佐古", "宗直"])
        #expect(NameMentions.parts(of: "五百旗頭堅至様") == ["五百旗頭", "堅至"])
        #expect(NameMentions.parts(of: "ヤマダ タロウ") == ["ヤマダ", "タロウ"])
        #expect(NameMentions.parts(of: "funatsu.keigo").isEmpty)
    }

    @Test("A later family-name mention is masked")
    func familyMention() {
        #expect(mentions("佐古宗直", in: "担当は佐古宗直です。\n以上、佐古より。") == ["佐古"])
        #expect(mentions("井出 奈保美", in: "井出 奈保美が対応。井出さんに確認済み。") == ["井出"])
    }

    @Test("A later given-name mention of two or more characters is masked")
    func givenMention() {
        #expect(mentions("中道 宗直", in: "中道 宗直 / 宗直さんがレビュー") == ["宗直"])
    }

    @Test("A part inside a longer kanji word is left alone")
    func boundedByKanji() {
        #expect(mentions("森 健一", in: "森 健一が森林公園の基地局を確認した。").isEmpty)
        #expect(mentions("中西 定行", in: "中西 定行の担当は中西部です。").isEmpty)
    }

    @Test("A part right before an honorific is masked even when kanji precede it")
    func honorificOverridesBoundary() {
        #expect(mentions("宮窪 洋介", in: "宮窪 洋介。引継ぎ先は営業宮窪さん。") == ["宮窪"])
    }

    @Test("A one-character given name is not propagated")
    func shortGivenName() {
        #expect(mentions("井出 遊", in: "井出 遊。遊びに行く").isEmpty)
    }

    @Test("Occurrences already covered are not reported again")
    func noDuplicates() {
        let text = "佐古宗直と佐古宗直"
        let both = [(text as NSString).range(of: "佐古宗直"), NSRange(location: 5, length: 4)]
            .map { DetectedMatch(kind: .personalName, source: .languageModel, range: $0, text: "佐古宗直") }
        #expect(NameMentions.otherMentions(of: both, in: text).isEmpty)
    }
}
