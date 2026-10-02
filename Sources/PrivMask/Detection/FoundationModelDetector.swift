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
        /// Spans the model returned that `isPlausibleName` discarded. Never
        /// masked; recorded so that a measurement can tell a name the model
        /// never returned from one the filter threw away. See #28.
        public let rejectedTexts: [String]
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
                matches: [], ungroundedTexts: [], rejectedTexts: [], duration: duration,
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

    /// - Parameter onChunkStart: see `BatchedNameRun.run`. The default does
    ///   nothing, so a caller that has nowhere to draw need not care.
    public func detect(
        in text: String,
        onChunkStart: (Int, Int) async -> Void = { _, _ in }
    ) async throws -> Outcome {
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

        var rejected: [String] = []
        let result = await BatchedNameRun.run(
            text: text,
            batches: batches,
            onChunkStart: onChunkStart
        ) { batchText in
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
                        Data("    model: \(entity.kind) \(entity.text.debugDescription) plausible=\(Self.isPlausibleName(entity.text, in: batchText))\n".utf8)
                    )
                }
                // The model is instructed to copy substrings verbatim, but it is
                // a language model: it has been observed normalising full-width
                // digits to half-width. Anything that does not occur in what was
                // sent is discarded downstream rather than trusted.
                guard Self.isPlausibleName(entity.text, in: batchText) else {
                    rejected.append(entity.text)
                    return nil
                }
                return entity.text
            }
        }

        return Outcome(
            matches: result.matches,
            ungroundedTexts: result.ungroundedTexts,
            rejectedTexts: rejected,
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
    /// - Parameter context: the text the candidate was found in. An honorific
    ///   straight after it there is evidence of a person that no list supplies.
    static func isPlausibleName(_ text: String, in context: String = "") -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }

        // An honorific alone is never a name. The model returned さん on its own
        // from 林さんと関さんには, and the hiragana path accepted it.
        guard !withoutHonorific(text).isEmpty else { return false }

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

        return isNameShaped(text) || isFollowedByHonorific(text, in: context)
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
    /// Kanji and katakana candidates are checked against the surname list, which
    /// is what rejects the words the model reaches for when a text contains no
    /// names. Hiragana candidates are checked against `JapaneseNonNameWords`,
    /// which is the same idea in the other direction — a denial list, because
    /// hiragana given names are an open set that no allow list could hold.
    ///
    /// Hiragana used to be accepted as-is, on the grounds that there was no
    /// reliable signal and a wrong rejection costs a name. What that missed is
    /// that the same words recur: the model returned `どこ` and `のでしょうか`
    /// from one sentence, and both are grammar no name could be confused with.
    ///
    /// Latin text is checked by its shape: romaji, or a Western personal name.
    /// It used to be accepted as-is, on the grounds that `AppleNameTagger`
    /// covers English names, and the model's hostnames and job names came
    /// through whole. See `LatinNameShape` and #32.
    static func isNameShaped(_ text: String) -> Bool {
        var hasKanji = false
        var hasKatakana = false
        var hasHiragana = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                hasKanji = true
            case 0x30A0...0x30FF, 0xFF66...0xFF9D:
                hasKatakana = true
            case 0x3040...0x309F:
                hasHiragana = true
            default:
                break
            }
        }

        // Japanese names are written in one script. `サポート窓口` mixes them.
        if hasKanji && hasKatakana { return false }

        if hasKanji || hasKatakana {
            return JapaneseSurnames.beginsWithSurname(text) || endsWithGivenName(text)
        }
        if hasHiragana { return !JapaneseNonNameWords.isGrammar(text) }
        return LatinNameShape.isNameShaped(text)
    }
    private static let honorifics = ["様", "さん", "氏", "くん", "ちゃん"]

    /// The candidate without a trailing honorific or space. The model is told to
    /// leave the honorific out, and does not always.
    private static func withoutHonorific(_ text: String) -> String {
        var core = text.trimmingCharacters(in: .whitespaces)
        if let honorific = honorifics.first(where: { core.hasSuffix($0) }) {
            core = String(core.dropLast(honorific.count)).trimmingCharacters(in: .whitespaces)
        }
        return core
    }

    /// True when the candidate, all kanji, is a family part of one to five kanji
    /// followed by a given name of two or more.
    ///
    /// This is what keeps `潮 洋介` and `五百旗頭堅至`, whose family names the
    /// surname list leaves out on purpose: one kanji admits too many common
    /// nouns as a prefix, and the prefix match stops at three. Over SudachiDict's
    /// common nouns this check admits 0.15%, against 1.67% for the surname
    /// check. See #34.
    static func endsWithGivenName(_ text: String) -> Bool {
        let joined = withoutHonorific(text).filter { $0 != " " && $0 != "\u{3000}" }
        let isKanji: (Character) -> Bool = { character in
            character.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005, 0x3006, 0x30F6: return true
                default: return false
                }
            }
        }
        guard joined.count >= 3, joined.allSatisfy(isKanji) else { return false }
        return (1...min(5, joined.count - 2)).contains { familyLength in
            JapaneseGivenNames.kanji.contains(String(joined.dropFirst(familyLength)))
        }
    }

    /// True when, in `context`, the candidate is followed directly or after one
    /// space by an honorific. `イイタケ様` and `舩津様` begin with no listed
    /// family name, and the honorific is what says they are people. See #34.
    static func isFollowedByHonorific(_ text: String, in context: String) -> Bool {
        let core = withoutHonorific(text)
        guard !core.isEmpty, !context.isEmpty else { return false }
        let pattern = NSRegularExpression.escapedPattern(for: core) + "[ \u{3000}]?(?:" + honorifics.joined(separator: "|") + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)) != nil
    }
}
#endif
