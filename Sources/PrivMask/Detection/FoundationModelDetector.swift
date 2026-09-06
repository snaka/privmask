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

        @Guide(description: "One of: personalName, organizationName, address, phoneNumber, email, other")
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
    }

    private static let instructions = """
        You find personal and sensitive information in text so that it can be masked \
        before the text is shared with other people.

        The text is usually Japanese, and may mix Japanese and English. Japanese \
        personal names are the most important thing to find: they appear as 姓名 with \
        or without a space, in kanji, hiragana, katakana, or romaji, and are often \
        followed by 様, さん, or 氏.

        Report every entity you find. For each one, copy the exact substring from the \
        input — do not paraphrase, translate, reformat, or normalise it.

        Do not report things that merely look like identifiers: UUIDs, git commit \
        hashes, version numbers, port numbers, error codes, library names, product \
        names, and dates are not personal information.
        """

    public init() {}

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

        let started = Date()
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: text, generating: Findings.self)
        let duration = Date().timeIntervalSince(started)

        let nsText = text as NSString
        var matches: [DetectedMatch] = []
        var ungrounded: [String] = []

        for entity in response.content.entities {
            guard let kind = Self.kind(from: entity.kind) else { continue }
            // The model is instructed to copy substrings verbatim, but it is a
            // language model: anything that does not actually occur in the input
            // is discarded rather than trusted.
            let ranges = Self.occurrences(of: entity.text, in: nsText)
            if ranges.isEmpty {
                ungrounded.append(entity.text)
                continue
            }
            for range in ranges {
                matches.append(
                    DetectedMatch(
                        kind: kind,
                        source: .languageModel,
                        range: range,
                        text: nsText.substring(with: range)
                    )
                )
            }
        }

        return Outcome(matches: matches, ungroundedTexts: ungrounded, duration: duration)
    }

    private static func kind(from raw: String) -> SensitiveKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "personalname": return .personalName
        case "organizationname": return .organizationName
        case "address": return .address
        case "phonenumber": return .phoneNumber
        case "email": return .email
        default: return nil
        }
    }

    private static func occurrences(of needle: String, in haystack: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = []
        var cursor = 0
        while cursor < haystack.length {
            let searchRange = NSRange(location: cursor, length: haystack.length - cursor)
            let range = haystack.range(of: needle, range: searchRange)
            if range.location == NSNotFound { break }
            found.append(range)
            cursor = range.location + max(range.length, 1)
        }
        return found
    }
}
#endif
