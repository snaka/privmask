import Foundation
import NaturalLanguage
import Testing

@testable import PrivMask

// Characterisation tests: these pin down what Apple's frameworks actually do,
// rather than what privmask does. They exist so that a change in macOS is
// noticed as a test failure instead of as a silent change in masking behaviour.

@Suite("NLTagger platform support")
struct NLTaggerSupportTests {
    /// The finding that shaped the whole design: NLTagger offers no named-entity
    /// recognition for Japanese. Only tokenisation is available.
    ///
    /// If this test ever fails, Apple has added Japanese NER and the personal-name
    /// detector should be reconsidered — see docs/findings/apple-detector-baseline.md.
    @Test("NameType is unavailable for Japanese")
    func nameTypeUnavailableForJapanese() {
        let schemes = NLTagger.availableTagSchemes(for: .word, language: .japanese)
        #expect(!schemes.contains(.nameType))
        #expect(!schemes.contains(.lexicalClass))
        // Tokenisation does work — the gap is specifically the entity model.
        #expect(schemes.contains(.tokenType))
    }

    @Test("NameType is available for English, so the gap is language-specific")
    func nameTypeAvailableForEnglish() {
        let schemes = NLTagger.availableTagSchemes(for: .word, language: .english)
        #expect(schemes.contains(.nameType))
    }

    @Test("Japanese personal names yield nothing")
    func japaneseNamesAreNotDetected() {
        let matches = AppleNameTagger().detect(in: "一次対応: 田中健一 / 二次対応: 佐藤 美咲")
        #expect(matches.filter { $0.kind == .personalName }.isEmpty)
    }
}

@Suite("NSDataDetector on Japanese text")
struct DataDetectorTests {
    private let detector = AppleDataDetector()

    @Test(
        "Japanese phone number formats are all recognised",
        arguments: [
            "090-1234-5678",
            "03-1234-5678",
            "0120-123-456",
            "0570-064-000",
            "09012345678",
            "０９０－１２３４－５６７８",
        ]
    )
    func phoneFormats(_ number: String) {
        let matches = detector.detect(in: "連絡先は \(number) です。")
        #expect(matches.contains { $0.kind == .phoneNumber })
    }

    @Test(
        "Japanese addresses are recognised",
        arguments: [
            "東京都渋谷区渋谷2丁目21番1号",
            "大阪府大阪市北区梅田3-1-3",
            "神奈川県横浜市西区みなとみらい2-3-5",
        ]
    )
    func addressFormats(_ address: String) {
        let matches = detector.detect(in: "住所: \(address)")
        #expect(matches.contains { $0.kind == .address })
    }

    /// Known defect to work around: the detector will run a phone-number match
    /// across a newline and swallow unrelated trailing digits.
    @Test("Phone matches can span a newline and over-capture")
    func phoneMatchSpansNewline() {
        let text = "全角表記: ０９０－１２３４－５６７８\n内線: 7788"
        let matches = detector.detect(in: text).filter { $0.kind == .phoneNumber }
        #expect(matches.contains { $0.text.contains("\n") })
    }

    /// A 12-digit My Number is claimed by the phone-number detector, so the
    /// dedicated My Number detector has to win when the ranges collide.
    @Test("A My Number is misread as a phone number")
    func myNumberLooksLikeAPhoneNumber() {
        let matches = detector.detect(in: "マイナンバー: 123456789018")
        #expect(matches.contains { $0.kind == .phoneNumber && $0.text.contains("123456789018") })
    }

    @Test("Bare email addresses are not detected")
    func bareEmailNotDetected() {
        let matches = detector.detect(in: "連絡先 suzuki@example.co.jp まで")
        #expect(matches.isEmpty)
    }
}
