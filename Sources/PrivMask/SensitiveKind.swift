import Foundation

/// A category of sensitive information that can be found in text.
public enum SensitiveKind: String, Hashable, Sendable, Codable, CaseIterable {
    case email
    case phoneNumber
    case address
    case postalCode
    case personalName
    case organizationName
    case placeName
    case myNumber
    case credential
    case dictionaryTerm
}

/// Which detector produced a match. Shown as secondary information in the
/// confirmation UI so the reader can judge how much to trust an item.
public enum DetectorSource: String, Hashable, Sendable, Codable {
    case dataDetector
    case nameTagger
    case regex
    case dictionary
    case languageModel
    case credentialContext
}

/// One piece of sensitive information located in a text.
public struct DetectedMatch: Hashable, Sendable {
    public let kind: SensitiveKind
    public let source: DetectorSource
    /// Range within the text, in UTF-16 offsets (`NSString` semantics).
    public let range: NSRange
    public let text: String
    /// Set by a detector that has grounds to differ from what its source
    /// normally carries. `nil` means the source's `baseConfidence` applies.
    ///
    /// `CredentialContextDetector` is the only user: the name that introduces a
    /// value is the same evidence whether the value is a live key or
    /// `YOUR_API_KEY_HERE`, so the value itself has to move the confidence.
    public let confidence: Confidence?

    public init(
        kind: SensitiveKind,
        source: DetectorSource,
        range: NSRange,
        text: String,
        confidence: Confidence? = nil
    ) {
        self.kind = kind
        self.source = source
        self.range = range
        self.text = text
        self.confidence = confidence
    }
}
