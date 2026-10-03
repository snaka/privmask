import Foundation
import PrivMask

enum PrivMaskVersion {
    static let current = "0.5.0"
}

/// What `--json` emits.
///
/// `text` carries the original value, because a caller that is going to show the
/// user what will be masked needs it. That makes this output as sensitive as the
/// input: it is written to stdout for the caller, never to a file by privmask.
struct Report: Encodable {
    struct Finding: Encodable {
        let kind: String
        let confidence: String
        let sources: [String]
        let text: String
        let location: Int
        let length: Int
        let placeholder: String?
    }

    let masked: String
    let findings: [Finding]
    let model: ModelStatus
    let ner: ModelStatus
    /// Chunks of the input the model layer never examined. Empty is the normal
    /// case: the layer sends as many calls as the input takes, so a chunk is
    /// missing only because its call failed.
    let chunkFailures: [BatchedNameRun.ChunkFailure]

    var warnings: [String] {
        Degradation.warnings(model: model, ner: ner, chunkFailures: chunkFailures)
    }

    private enum CodingKeys: String, CodingKey {
        case masked, findings, model, modelDetail, ner, nerDetail, warnings
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(masked, forKey: .masked)
        try container.encode(findings, forKey: .findings)
        try container.encode(model.token, forKey: .model)
        // Written even when nil. A key that comes and goes makes a caller test
        // for its presence before its value, which is one more thing to get
        // wrong than reading null.
        try container.encode(model.detail, forKey: .modelDetail)
        try container.encode(ner.token, forKey: .ner)
        try container.encode(ner.detail, forKey: .nerDetail)
        try container.encode(warnings, forKey: .warnings)
    }
}

enum ModelStatus {
    case used
    case disabled
    case unavailable(String)
    case failed(String)

    /// The state, as a token from a closed set: `used`, `disabled`,
    /// `unavailable`, `failed`. A caller switches on this; the reason it was in
    /// that state is `detail`, and is prose.
    var token: String {
        switch self {
        case .used: return "used"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }

    /// Failed, with the error said in one line: a Swift error's own
    /// description, or an NSError's localized description rather than its
    /// whole chain of underlying errors.
    static func failed(_ error: Error) -> ModelStatus {
        if type(of: error) is CustomStringConvertible.Type, !(type(of: error) is NSObject.Type) {
            return .failed(String(describing: error))
        }
        return .failed((error as NSError).localizedDescription)
    }

    /// Why, where there is a why. Never parsed — shown.
    var detail: String? {
        switch self {
        case .used, .disabled: return nil
        case .unavailable(let reason), .failed(let reason): return reason
        }
    }

    /// The layer's state as the start of a warning, or nil when it ran.
    func state(layer: String) -> String? {
        switch self {
        case .used: return nil
        case .disabled: return "\(layer) disabled"
        case .unavailable(let reason): return "\(layer) \(reason)"
        case .failed(let reason): return "\(layer) failed (\(reason))"
        }
    }

    var isUsed: Bool { if case .used = self { return true } else { return false } }
}

/// Every way in which a run examined less than the whole input.
///
/// The contract a caller is told to rely on: **this is empty if and only if
/// every layer ran over the whole input.** A caller deciding whether the masked
/// text can be passed on has one thing to check, and a layer added later that
/// can degrade adds an entry here rather than a field nobody knows to look at.
///
/// It lives apart from `Report` because the plain-text mode needs the same list
/// for stderr without paying to build the findings it will not print — one
/// source of wording, two callers.
enum Degradation {
    /// Two layers look for Japanese personal names: the NER model and the
    /// language model. Each one's absence is stated, with what is left.
    static func warnings(
        model: ModelStatus,
        ner: ModelStatus,
        chunkFailures: [BatchedNameRun.ChunkFailure]
    ) -> [String] {
        var warnings: [String] = []
        if let state = model.state(layer: "language model") {
            warnings.append(state + "; Japanese personal names were "
                + (ner.isUsed ? "looked for by the NER model alone" : "not looked for"))
        }
        if let state = ner.state(layer: "NER model") {
            warnings.append(state + "; Japanese personal names were "
                + (model.isUsed ? "looked for by the language model alone" : "not looked for"))
        }
        warnings += chunkFailures.map { failure in
            "chunk \(failure.index) of \(failure.total) (\(failure.characters) characters) "
                + "was not examined for names: \(failure.reason)"
        }
        return warnings
    }
}
