import Foundation

/// Replaces detected spans with numbered placeholders.
///
/// The same value always gets the same number, so `[NAME_1]` refers to one
/// person throughout. That is the only thing worth preserving here: the reader
/// is a colleague, not a program, and what they need is to follow who is who —
/// not to recover the original values.
public struct Masker {
    public struct Replacement: Sendable {
        public let range: NSRange
        public let original: String
        public let placeholder: String
        public let kind: SensitiveKind
    }

    public struct Result: Sendable {
        public let text: String
        /// What was replaced with what.
        ///
        /// Returned so the UI can show it and the caller can audit it. It is
        /// never written to disk: this table *is* the sensitive information, and
        /// storing it would add a copy of exactly what the masking removed.
        public let replacements: [Replacement]
    }

    public init() {}

    public func mask(_ text: String, candidates: [MaskCandidate]) -> Result {
        let selected = Self.resolveOverlaps(candidates)
        guard !selected.isEmpty else { return Result(text: text, replacements: []) }

        var numbers: [SensitiveKind: [String: Int]] = [:]
        var replacements: [Replacement] = []

        // Numbering follows reading order, so [NAME_1] is the first person the
        // reader meets.
        for candidate in selected.sorted(by: { $0.range.location < $1.range.location }) {
            var perKind = numbers[candidate.kind] ?? [:]
            let number: Int
            if let existing = perKind[candidate.text] {
                number = existing
            } else {
                number = perKind.count + 1
                perKind[candidate.text] = number
                numbers[candidate.kind] = perKind
            }
            replacements.append(
                Replacement(
                    range: candidate.range,
                    original: candidate.text,
                    placeholder: "[\(Self.label(for: candidate.kind))_\(number)]",
                    kind: candidate.kind
                )
            )
        }

        // Replace from the end so earlier offsets stay valid.
        let output = NSMutableString(string: text)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: replacement.range, with: replacement.placeholder)
        }

        return Result(text: output as String, replacements: replacements)
    }

    /// Picks a non-overlapping set to replace.
    ///
    /// Detection deliberately keeps overlapping findings — an address and the
    /// postal code inside it are two separate things to tell the user about —
    /// but only one of them can be substituted. The longer span wins, because it
    /// covers everything the shorter one did.
    static func resolveOverlaps(_ candidates: [MaskCandidate]) -> [MaskCandidate] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            return lhs.range.location < rhs.range.location
        }
        var chosen: [MaskCandidate] = []
        for candidate in ordered where !chosen.contains(where: { rangesOverlap($0.range, candidate.range) }) {
            chosen.append(candidate)
        }
        return chosen
    }

    static func label(for kind: SensitiveKind) -> String {
        switch kind {
        case .email: return "EMAIL"
        case .phoneNumber: return "PHONE"
        case .address: return "ADDRESS"
        case .postalCode: return "POSTAL"
        case .personalName: return "NAME"
        case .organizationName: return "ORG"
        case .placeName: return "PLACE"
        case .myNumber: return "MYNUMBER"
        case .credential: return "SECRET"
        case .dictionaryTerm: return "TERM"
        }
    }
}
