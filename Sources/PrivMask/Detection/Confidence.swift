import Foundation

/// How much a match should be trusted. Shown as the primary signal in the
/// confirmation UI, with the detector shown as secondary information.
///
/// This is normally a property of the detector that produced the match, not of
/// the text. A detector that has grounds to differ may override it for one
/// finding: `CredentialContextDetector` reports a placeholder value at `.low`,
/// because the name introducing it is evidence about the slot, not the value.
/// A match found by two detectors is promoted one step: independent agreement is
/// the only cheap evidence available.
public enum Confidence: Int, Sendable, Comparable, Codable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Stable name for crossing a process or language boundary.
    public var name: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    public init?(name: String) {
        switch name {
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: return nil
        }
    }

    var promoted: Confidence {
        Confidence(rawValue: min(rawValue + 1, Confidence.high.rawValue)) ?? self
    }
}

extension DetectorSource {
    /// The confidence a match carries before any promotion.
    ///
    /// `regex` and `dictionary` are exact by construction. `dataDetector` uses
    /// Apple's models and measured 11/11 on the corpus, but it also claimed a My
    /// Number as a phone number. `languageModel` finds names nothing else can,
    /// and also read an IP address as an address.
    /// `credentialContext` is medium: the name is a reliable signal about the
    /// slot, but nothing has checked the value.
    public var baseConfidence: Confidence {
        switch self {
        case .regex, .dictionary: return .high
        case .dataDetector, .credentialContext: return .medium
        case .nameTagger, .languageModel: return .low
        }
    }
}

extension DetectedMatch {
    /// The confidence to reconcile with: the detector's override if it set one,
    /// otherwise its source's default.
    var effectiveConfidence: Confidence { confidence ?? source.baseConfidence }
}
