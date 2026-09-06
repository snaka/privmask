import Foundation

/// How much a match should be trusted. Shown as the primary signal in the
/// confirmation UI, with the detector shown as secondary information.
///
/// This is a property of the detector that produced the match, not of the text.
/// A match found by two detectors is promoted one step: independent agreement is
/// the only cheap evidence available.
public enum Confidence: Int, Sendable, Comparable, Codable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
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
    public var baseConfidence: Confidence {
        switch self {
        case .regex, .dictionary: return .high
        case .dataDetector: return .medium
        case .nameTagger, .languageModel: return .low
        }
    }
}
