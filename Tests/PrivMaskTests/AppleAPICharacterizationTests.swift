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

    /// Every Japanese number carries the domestic prefix `0`, so a separator-less
    /// run that starts with anything else is some other ten- or eleven-digit
    /// number. A JSON number cannot have a leading zero either, which makes every
    /// bare digit run in a JSON numeric position — timestamps, counters, IDs —
    /// fall out of the same rule.
    @Test(
        "A separator-less digit run that does not start with 0 is not a phone number",
        arguments: [
            "1789049614",  // unix timestamp in seconds
            "2147483647",
            "12345678901",
            "9876543210",
        ]
    )
    func digitRunsWithoutDomesticPrefix(_ digits: String) {
        #expect(!AppleDataDetector.isPlausible(kind: .phoneNumber, text: digits))
    }

    @Test(
        "A separator-less digit run starting with 0 is still a phone number",
        arguments: ["09012345678", "0312345678", "0120123456"]
    )
    func bareDigitRunsWithDomesticPrefix(_ digits: String) {
        #expect(AppleDataDetector.isPlausible(kind: .phoneNumber, text: digits))
    }

    /// The plausibility rule only judges runs that normalise to digits alone, so
    /// a number written with separators or an international prefix never reaches
    /// it. Holding that here keeps the new rule from narrowing to domestic form.
    @Test(
        "A number carrying separators or a country code is left to the detector",
        arguments: ["+81 90-1234-5678", "+81-3-1234-5678", "090-1234-5678", "03 1234 5678"]
    )
    func separatedNumbersAreExempt(_ number: String) {
        #expect(AppleDataDetector.isPlausible(kind: .phoneNumber, text: number))
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

    /// Apple's defect, checked against the framework directly: NSDataDetector
    /// runs a phone-number match across a newline and swallows unrelated
    /// trailing digits. AppleDataDetector cuts matches back to their first line
    /// to compensate; that workaround is covered by PipelineTests.
    @Test("Raw NSDataDetector runs a phone match across a newline")
    func rawDetectorSpansNewline() throws {
        let text = "全角表記: ０９０－１２３４－５６７８\n内線: 7788"
        let raw = try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        let nsText = text as NSString
        let matches = raw.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
        #expect(matches.contains { $0.contains("\n") })
    }

    /// Apple's behaviour, checked against the framework directly: a bare
    /// 12-digit number is reported as a phone number. That is why AppleDataDetector
    /// rejects separator-free digit runs outside Japanese phone lengths, and why
    /// the My Number detector outranks the phone detector when both fire.
    @Test("Raw NSDataDetector reads a 12-digit number as a phone number")
    func rawDetectorClaimsTwelveDigits() throws {
        let text = "番号: 123456789018"
        let raw = try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        let nsText = text as NSString
        let matches = raw.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
        #expect(matches.contains { $0.contains("123456789018") })
    }

    @Test("A digit run that is not a Japanese phone length is rejected")
    func implausibleDigitRunsRejected() {
        #expect(detector.detect(in: "注文番号 123456789010 の件").isEmpty)
        #expect(detector.detect(in: "伝票 4912345678901 は対象外").isEmpty)
        #expect(!detector.detect(in: "携帯 09012345678 です").isEmpty)
    }

    /// Apple's behaviour, checked directly: a phone number followed by an
    /// ideographic comma is not detected at all, though the same number followed
    /// by a space or 。 is. AppleDataDetector scans a copy with the comma
    /// substituted; both characters are one UTF-16 unit, so offsets survive.
    @Test("Raw NSDataDetector misses a phone number before an ideographic comma")
    func rawDetectorMissesPhoneBeforeIdeographicComma() throws {
        let raw = try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        func count(_ text: String) -> Int {
            raw.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).count
        }
        #expect(count("連絡先 090-1234-5678、住所は東京都渋谷区渋谷1丁目1番地です") == 0)
        #expect(count("連絡先 090-1234-5678。") == 1)
    }

    @Test("The substitution recovers those numbers, with offsets intact")
    func commaSubstitutionRecoversPhone() {
        let text = "連絡先 090-1234-5678、住所は大阪府大阪市北区梅田3-1-3です"
        let matches = detector.detect(in: text).filter { $0.kind == .phoneNumber }
        #expect(matches.count == 1)
        #expect(matches.first?.text == "090-1234-5678")
    }

    @Test("Substitution never changes the length of the text")
    func substitutionPreservesLength() {
        let samples = ["連絡先、住所", "a、b，c", "、、、", "no japanese punctuation"]
        for sample in samples {
            let scanned = AppleDataDetector.detectorFriendly(sample)
            #expect((scanned as NSString).length == (sample as NSString).length)
        }
    }

    @Test("Bare email addresses are not detected")
    func bareEmailNotDetected() {
        let matches = detector.detect(in: "連絡先 suzuki@example.co.jp まで")
        #expect(matches.isEmpty)
    }
}

@Suite("Model output plausibility")
struct ModelPlausibilityTests {
    @available(macOS 26.0, *)
    @Test(
        "Real names are accepted",
        arguments: ["田中健一", "佐藤 美咲", "高橋 由美", "ヤマダ タロウ", "あきら", "林 修", "John Smith"]
    )
    func acceptsNames(_ name: String) {
        #expect(FoundationModelDetector.isPlausibleName(name))
    }

    /// Every one of these was actually returned by the model during measurement.
    @available(macOS 26.0, *)
    @Test(
        "Spans the model returned that are not names are rejected",
        arguments: [
            "サポート窓口",  // katakana mixed with kanji
            "緊急連絡先",  // does not begin with a family name
            "全角表記",
            "内線",
            "式",
            "ナビダイヤル",  // katakana, not a family name reading
            "7788",  // no letters
            "マイナンバー: 123456789018",  // a whole line
            "田中式アルゴリズムを採用",  // contains を, so it is a clause
            "田中健一 の再掲",  // ran past the name into the sentence
        ]
    )
    func rejectsNonNames(_ span: String) {
        #expect(!FoundationModelDetector.isPlausibleName(span))
    }

    /// Kanji and katakana candidates are checked against the family-name list;
    /// hiragana had no equivalent, so the model's filler words came through
    /// whole. `どこを見れば良いのでしょうか？` was masked as
    /// `[NAME_1]を見れば良い[NAME_2]？`. See #15.
    @available(macOS 26.0, *)
    @Test(
        "Hiragana spans that are grammar rather than names are rejected",
        arguments: [
            "どこ",  // returned by the model on a real payload
            "のでしょうか",  // likewise
            "これ", "それ", "ここ", "そこ", "なぜ", "いつ", "だれ", "どちら",
            "ですか", "ますか", "ました", "ません", "ください", "でしょうか",
            "わかりました",
        ]
    )
    func rejectsHiraganaGrammar(_ span: String) {
        #expect(!FoundationModelDetector.isPlausibleName(span))
    }

    /// The exclusion list may not reach into names that merely start the same
    /// way: `ここ` must not take `こころ`, and no prefix rule may take `のぞみ`.
    @available(macOS 26.0, *)
    @Test(
        "Hiragana given names are still accepted",
        arguments: [
            "さくら", "ゆい", "あおい", "ひなた", "つむぎ", "のぞみ", "みお",
            "ことね", "すみれ", "はるか", "こころ", "いつき", "なぎさ",
            // Two-mora names that collide with grammar. 蒼 and 奏 are both
            // written そう, 航 and 光 both こう, and 成 is なる. An entry in the
            // exclusion list that is also a name loses it silently, which is
            // the failure an allow list was rejected for.
            "そう", "こう", "なる",
        ]
    )
    func acceptsHiraganaNames(_ name: String) {
        #expect(FoundationModelDetector.isPlausibleName(name))
    }

    /// A single-token name may begin with a character that is also a particle.
    @available(macOS 26.0, *)
    @Test("A one-token name beginning with a particle character is kept")
    func singleTokenParticleNameKept() {
        #expect(!FoundationModelDetector.startsAContinuation("のぞみ"))
        #expect(FoundationModelDetector.startsAContinuation("田中健一 の再掲"))
    }
}
