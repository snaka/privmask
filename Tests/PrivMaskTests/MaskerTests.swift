import Foundation
import Testing

@testable import PrivMask

@Suite("Masking")
struct MaskerTests {
    private let pipeline = DetectionPipeline()
    private let masker = Masker()

    private func mask(_ text: String, dictionary: [String] = []) -> Masker.Result {
        let pipeline = DetectionPipeline(dictionaryTerms: dictionary)
        return masker.mask(text, candidates: pipeline.detect(in: text))
    }

    @Test("A detected value is replaced by a numbered placeholder")
    func replacesWithPlaceholder() {
        let result = mask("連絡は suzuki@example.co.jp まで")
        #expect(result.text == "連絡は [EMAIL_1] まで")
    }

    @Test("The same value keeps the same number wherever it appears")
    func sameValueSameNumber() {
        let result = mask("a@example.com と b@example.com、折り返しは a@example.com へ")
        #expect(result.text == "[EMAIL_1] と [EMAIL_2]、折り返しは [EMAIL_1] へ")
    }

    @Test("Numbering follows reading order")
    func numberingFollowsReadingOrder() {
        let result = mask("一次 090-1111-2222 / 二次 090-3333-4444")
        #expect(result.text == "一次 [PHONE_1] / 二次 [PHONE_2]")
    }

    @Test("Different kinds are numbered independently")
    func kindsNumberedIndependently() {
        let result = mask("x@example.com と 090-1111-2222")
        #expect(result.text == "[EMAIL_1] と [PHONE_1]")
    }

    @Test("Nothing detected leaves the text untouched")
    func noDetectionsLeavesTextAlone() {
        let text = "ビルドは v2.14.3、ポートは 8080 です"
        #expect(mask(text).text == text)
    }

    /// The postal code sits inside the address NSDataDetector reports. Both are
    /// worth telling the user about, but only the longer one can be substituted.
    @Test("Overlapping findings collapse to the longer span")
    func overlapsCollapseToLongerSpan() {
        let result = mask("住所: 〒150-0002 東京都渋谷区渋谷2丁目21番1号")
        #expect(!result.text.contains("〒150-0002"))
        #expect(!result.text.contains("東京都渋谷区"))
        #expect(result.replacements.count == 1)
    }

    @Test("A dictionary term is replaced")
    func dictionaryTermReplaced() {
        let result = mask("お客様は株式会社サンプル商事です", dictionary: ["株式会社サンプル商事"])
        #expect(result.text == "お客様は[TERM_1]です")
    }

    @Test("The replacement table reports what was substituted")
    func replacementTableIsReturned() {
        let result = mask("連絡は suzuki@example.co.jp まで")
        #expect(result.replacements.count == 1)
        #expect(result.replacements[0].original == "suzuki@example.co.jp")
        #expect(result.replacements[0].placeholder == "[EMAIL_1]")
        #expect(result.replacements[0].kind == .email)
    }

    @Test("Only the selected candidates are masked")
    func masksOnlySelectedCandidates() {
        let text = "x@example.com と 090-1111-2222"
        let candidates = pipeline.detect(in: text).filter { $0.kind == .email }
        let result = masker.mask(text, candidates: candidates)
        #expect(result.text == "[EMAIL_1] と 090-1111-2222")
    }
}
