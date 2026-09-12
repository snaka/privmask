#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Detects sensitive information using the on-device Apple Intelligence model.
///
/// This layer exists because `NLTagger` has no Japanese named-entity model, so
/// personal names cannot be found by any deterministic on-device means. See
/// docs/findings/apple-detector-baseline.md.
///
/// The model is asked to work from the text alone, without being shown what the
/// deterministic detectors already found: seeing them anchors the model and
/// reduces what it adds, and adding is the entire point of this layer.
@available(macOS 26.0, *)
public struct FoundationModelDetector {
    /// One entity as reported by the model.
    @Generable
    struct Entity {
        @Guide(description: "The exact substring copied verbatim from the input text. Never paraphrase, translate, or normalise it.")
        var text: String

        @Guide(description: "Always the string personalName.")
        var kind: String
    }

    @Generable
    struct Findings {
        @Guide(description: "Every piece of personal or sensitive information found in the text.")
        var entities: [Entity]
    }

    /// Why a run produced no results, when it produced none.
    public enum Unavailability: Error, Sendable {
        case modelUnavailable(String)
    }

    public struct Outcome: Sendable {
        public let matches: [DetectedMatch]
        /// Spans the model returned that do not occur in the input. Dropped, but
        /// counted: a rising number means the prompt is inviting paraphrase.
        public let ungroundedTexts: [String]
        public let duration: TimeInterval
        /// How many calls the input took.
        public let chunks: Int
        /// Chunks that were never examined. Each one is text the caller was not
        /// told about by any other means, so it has to be reported: a silent
        /// miss is the failure this tool exists to prevent.
        public let failures: [BatchedNameRun.ChunkFailure]
        /// Number of Japanese-bearing lines sent to the model.
        public let linesExamined: Int

        public static func empty(duration: TimeInterval = 0) -> Outcome {
            Outcome(
                matches: [], ungroundedTexts: [], duration: duration,
                chunks: 0, failures: [], linesExamined: 0
            )
        }
    }

    /// How much Japanese text is sent to the model in one call.
    ///
    /// A chunk size, not a ceiling on coverage: an input larger than this costs
    /// more calls, not less examination. The number keeps one call inside the
    /// context window with room to spare, and smaller chunks put fewer
    /// candidates in front of the model at once, which is what the recall gap
    /// for a name that comes after others turns on.
    /// See docs/findings/on-device-model-baseline.md.
    public static let defaultCharacterLimit = 1500

    private static let instructions = """
        You find personal names in Japanese text, so that they can be masked before the \
        text is shared with other people.

        Personal names are the important ones. They appear as 姓名 with or without a \
        space, written in kanji, hiragana, katakana, or romaji, and are often followed \
        by 様, さん, or 氏.

        For each name, copy the exact substring from the input — do not paraphrase, \
        translate, reformat, or normalise it. Do not include a following 様, さん, or 氏 \
        in the substring.

        Only report a name that refers to a specific individual person. A word that \
        names a role, a department, a contact channel, a document section, or a \
        category is not a personal name, even where a name would normally sit — such \
        as at the start of a line, before a colon.

        A family name occurring inside a longer word, a product name, or a compound \
        term is not a personal name either. Report the person, never the phrase around \
        them.

        Report nothing else at all. Company names, phone numbers, addresses, postal \
        codes, email addresses, numbers, ports, error codes, hostnames, library names, \
        product names and dates are handled elsewhere.

        Most text contains no personal names. When there is none, return an empty list. \
        That is the correct answer and the expected one — never offer the nearest \
        available word instead.
        """

    /// A ceiling on what one call may generate.
    ///
    /// Handed a fragment with no names in it, the model has been measured
    /// generating until the context window was exhausted — 58 seconds for four
    /// characters of input. This bounds that; not sending fragments is what
    /// prevents it. A dense chunk holding ten names returned all ten under this
    /// cap. See docs/findings/on-device-model-baseline.md.
    static let maximumResponseTokens = 1024

    private let characterLimit: Int

    public init(characterLimit: Int = FoundationModelDetector.defaultCharacterLimit) {
        self.characterLimit = characterLimit
    }

    public static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable(\(reason))"
        @unknown default:
            return "unknown"
        }
    }

    public func detect(in text: String) async throws -> Outcome {
        guard Self.isAvailable else {
            throw Unavailability.modelUnavailable(Self.availabilityDescription)
        }

        // Only the lines containing Japanese are sent. Mixing a timestamped log
        // line into Japanese makes Apple's language identifier report an
        // unsupported language, and the model then refuses the whole input.
        // Filtering also keeps the request inside the context window.
        // See docs/findings/on-device-model-baseline.md.
        let segments = JapaneseText.japaneseLines(of: text)
        guard !segments.isEmpty else { return .empty() }

        // As many calls as the input takes. Nothing is left unexamined for being
        // late in the document; the cost is that the calls cannot be overlapped,
        // because the on-device model serialises.
        let batches = JapaneseText.batches(segments, characterLimit: characterLimit)

        let started = Date()
        let debug = ProcessInfo.processInfo.environment["PRIVMASK_DEBUG"] == "1"

        let result = await BatchedNameRun.run(text: text, batches: batches) { batchText in
            // A fresh session per chunk. Carrying one session across chunks
            // would accumulate the transcript in the context window, which is
            // the thing the chunking exists to stay inside.
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: batchText,
                generating: Findings.self,
                options: GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
            )
            return response.content.entities.compactMap { entity in
                if debug {
                    FileHandle.standardError.write(
                        Data("    model: \(entity.kind) \(entity.text.debugDescription) plausible=\(Self.isPlausibleName(entity.text))\n".utf8)
                    )
                }
                // The model is instructed to copy substrings verbatim, but it is
                // a language model: it has been observed normalising full-width
                // digits to half-width. Anything that does not occur in what was
                // sent is discarded downstream rather than trusted.
                guard Self.isPlausibleName(entity.text) else { return nil }
                return entity.text
            }
        }

        return Outcome(
            matches: result.matches,
            ungroundedTexts: result.ungroundedTexts,
            duration: Date().timeIntervalSince(started),
            chunks: batches.count,
            failures: result.failures,
            linesExamined: batches.reduce(0) { $0 + $1.mapping.count }
        )
    }

    /// Rejects spans that cannot be a name, and is the only thing that decides
    /// what this layer emits.
    ///
    /// The model's own label is ignored. It is not reliable — `鈴木一郎` came back
    /// as an organisation name in two runs out of three, and dropping it on that
    /// basis lost a real name — so the span is judged here instead, by how the
    /// text is written rather than by what the model called it. A genuine
    /// company name does not begin with a family name, so it is rejected here
    /// and left to the user dictionary, which is how the design treats
    /// organisations.
    ///
    /// Nothing but names is taken from the model at all, which is why
    /// `BatchedNameRun` records every span it keeps as a personal name. The
    /// deterministic layer has full recall on phone numbers, addresses, postal
    /// codes, emails, My Numbers and credentials, so the model's opinion on
    /// those only costs: it read `8080`, `1,234,567円` and `E-4521-9` as
    /// addresses.
    ///
    /// The model also returns whole lines — `マイナンバー: 123456789018` was
    /// reported as a personal name — and a line is recognisable by its
    /// structural punctuation and its length.
    static func isPlausibleName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }

        // The model has returned whole lines. Structural punctuation marks a
        // line or a clause, never a name.
        let structural: Set<Character> = [":", "：", "\n", "\t", "=", "、", "。", "/", "|"]
        guard !text.contains(where: structural.contains) else { return false }

        // を is only ever the accusative particle in modern Japanese. Its
        // presence means the span is a clause: "田中式アルゴリズムを採用".
        guard !text.contains("を") else { return false }

        // A name contains at least one letter. `7788` was returned as one.
        guard text.contains(where: { $0.isLetter }) else { return false }

        guard !startsAContinuation(text) else { return false }

        return isNameShaped(text)
    }

    /// Particles that can begin a word but never begin part of a name.
    private static let particles = ["の", "は", "が", "を", "に", "で", "と", "も", "へ", "や"]

    /// Rejects a span that has run past the name into the sentence around it.
    ///
    /// The model returned `田中健一 の再掲` — the name plus the words after it. A
    /// name written with a space separates family from given name, and neither
    /// part can begin with a grammatical particle, so a later token starting
    /// with one means the span kept going when it should have stopped.
    ///
    /// The rule is only applied from the second token onward. A single-token
    /// name may legitimately begin with one of these characters: のぞみ is a name.
    static func startsAContinuation(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
            .map(String.init)
        guard tokens.count > 1 else { return false }
        return tokens.dropFirst().contains { token in
            particles.contains { token.hasPrefix($0) }
        }
    }

    /// Checks a candidate against how Japanese names are actually written.
    ///
    /// Text in Latin or hiragana alone is accepted as-is: there is no reliable
    /// signal to apply, and the cost of a wrong rejection is a missed name.
    /// Kanji and katakana candidates are checked against the surname list,
    /// which is what rejects the words the model reaches for when a text
    /// contains no names.
    static func isNameShaped(_ text: String) -> Bool {
        var hasKanji = false
        var hasKatakana = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                hasKanji = true
            case 0x30A0...0x30FF, 0xFF66...0xFF9D:
                hasKatakana = true
            default:
                break
            }
        }

        // Japanese names are written in one script. `サポート窓口` mixes them.
        if hasKanji && hasKatakana { return false }

        guard hasKanji || hasKatakana else { return true }
        return JapaneseSurnames.beginsWithSurname(text)
    }
}
#endif
