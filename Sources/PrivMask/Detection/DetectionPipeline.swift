import Foundation

/// One item offered to the user in the confirmation UI.
public struct MaskCandidate: Sendable, Identifiable {
    public let id: String
    public let kind: SensitiveKind
    public let range: NSRange
    public let text: String
    public let confidence: Confidence
    /// Every detector that found this span, in the order they ran.
    public let sources: [DetectorSource]

    /// Public so that a front end can hand back the subset of findings the user
    /// kept, without the pipeline having to remember what it offered.
    public init(
        kind: SensitiveKind,
        range: NSRange,
        text: String,
        confidence: Confidence,
        sources: [DetectorSource]
    ) {
        self.id = "\(kind.rawValue):\(range.location):\(range.length)"
        self.kind = kind
        self.range = range
        self.text = text
        self.confidence = confidence
        self.sources = sources
    }
}

/// Runs the deterministic detectors and reconciles what they found.
///
/// The on-device model is deliberately not part of this: it is slow enough that
/// the UI shows these results first and folds the model's in as they arrive.
public struct DetectionPipeline {
    private let regex = RegexDetectors()
    private let myNumber = MyNumberDetector()
    private let dataDetector = AppleDataDetector()
    private let nameTagger = AppleNameTagger()
    private let credentialContext = CredentialContextDetector()
    private let dictionary: DictionaryDetector

    public init(dictionaryTerms: [String] = []) {
        dictionary = DictionaryDetector(terms: dictionaryTerms)
    }

    /// - Parameter additional: findings from a slower source, typically the
    ///   on-device model. Passing them here rather than appending to the result
    ///   is what makes precedence apply to them: a span the model calls a
    ///   personal name, which a deterministic detector has already claimed as a
    ///   phone number or an address, is the deterministic finding.
    ///
    ///   The UI calls this twice: once with nothing, to show results
    ///   immediately, and again when the model returns.
    public func detect(in text: String, additional: [DetectedMatch] = []) -> [MaskCandidate] {
        var matches: [DetectedMatch] = []
        matches += myNumber.detect(in: text)
        matches += dictionary.detect(in: text)
        matches += regex.detect(in: text)
        matches += credentialContext.detect(in: text)
        matches += dataDetector.detect(in: text)
        matches += nameTagger.detect(in: text)
        matches += additional
        return Self.reconcile(matches, in: text)
    }

    /// Merges duplicates, applies precedence between conflicting kinds, and
    /// assigns confidence.
    public static func reconcile(_ matches: [DetectedMatch], in text: String) -> [MaskCandidate] {
        let merged = mergeSameKind(matches)
        let resolved = applyPrecedence(merged)
        return resolved.sorted { $0.range.location < $1.range.location }
    }

    /// Matches of the same kind covering the same span are one finding. Being
    /// found independently by two detectors is evidence, so confidence is
    /// promoted one step.
    private static func mergeSameKind(_ matches: [DetectedMatch]) -> [MaskCandidate] {
        var groups: [String: [DetectedMatch]] = [:]
        for match in matches {
            let key = "\(match.kind.rawValue):\(match.range.location):\(match.range.length)"
            groups[key, default: []].append(match)
        }

        return groups.values.map { group in
            let sources = group.map(\.source)
            let base = group.map(\.effectiveConfidence).max() ?? .low
            let distinctSources = Set(sources)
            let confidence = distinctSources.count > 1 ? base.promoted : base
            let first = group[0]
            return MaskCandidate(
                kind: first.kind,
                range: first.range,
                text: first.text,
                confidence: confidence,
                sources: Array(distinctSources).sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    /// When two findings of different kinds cover the same span, the more
    /// specific one wins. A My Number is claimed by NSDataDetector as a phone
    /// number; masking it as a phone number would be wrong in the report even
    /// though the characters would be covered either way.
    ///
    /// Only containment counts. Partially overlapping spans of different kinds
    /// are left alone: an address that happens to abut a postal code is two
    /// findings, not a conflict.
    private static func applyPrecedence(_ candidates: [MaskCandidate]) -> [MaskCandidate] {
        candidates.filter { candidate in
            !candidates.contains { other in
                guard other.id != candidate.id, other.kind != candidate.kind else { return false }
                if contains(other.range, candidate.range),
                    precedence(of: other.kind) > precedence(of: candidate.kind)
                {
                    return true
                }
                return supersedesModelFinding(other, candidate)
            }
        }
    }

    /// A finding that came only from the language model is dropped when it
    /// overlaps a more trustworthy finding of a different kind, in either
    /// direction.
    ///
    /// Containment alone is not enough, because the model returns spans that
    /// *wrap* a deterministic finding rather than sit inside it — it reported
    /// `03-1234-5678（日中）` as a personal name. Masking that as a name would
    /// swallow the annotation around the phone number.
    private static func supersedesModelFinding(_ other: MaskCandidate, _ candidate: MaskCandidate) -> Bool {
        candidate.sources == [.languageModel]
            && rangesOverlap(other.range, candidate.range)
            && other.confidence > candidate.confidence
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location
            && outer.location + outer.length >= inner.location + inner.length
    }

    /// Higher wins when one finding contains another.
    private static func precedence(of kind: SensitiveKind) -> Int {
        switch kind {
        case .myNumber: return 100
        case .credential: return 90
        case .dictionaryTerm: return 80
        case .email: return 70
        case .postalCode: return 60
        case .phoneNumber: return 50
        case .address: return 40
        case .personalName: return 30
        case .organizationName: return 20
        case .placeName: return 10
        }
    }
}
