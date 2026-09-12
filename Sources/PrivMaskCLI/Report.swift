import Foundation
import PrivMask

enum PrivMaskVersion {
    static let current = "0.2.0"
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
    /// Chunks of the input the model layer never examined. Empty is the normal
    /// case: the layer sends as many calls as the input takes, so a chunk is
    /// missing only because its call failed.
    let chunkFailures: [BatchedNameRun.ChunkFailure]

    /// Every way in which this run examined less than the whole input.
    ///
    /// The contract a caller is told to rely on: **this is empty if and only if
    /// every layer ran over the whole input.** A caller deciding whether the
    /// masked text can be passed on has one thing to check, and a layer added
    /// later that can degrade adds an entry here rather than a field nobody
    /// knows to look at.
    var warnings: [String] {
        var warnings: [String] = []
        if let warning = model.warning { warnings.append(warning) }
        warnings += chunkFailures.map { failure in
            "chunk \(failure.index) of \(failure.total) (\(failure.characters) characters) "
                + "was not examined for names: \(failure.reason)"
        }
        return warnings
    }

    private enum CodingKeys: String, CodingKey {
        case masked, findings, model, modelDetail, warnings
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

    /// Why, where there is a why. Never parsed — shown.
    var detail: String? {
        switch self {
        case .used, .disabled: return nil
        case .unavailable(let reason), .failed(let reason): return reason
        }
    }

    /// What to tell the user when the model did not run. Personal names in
    /// Japanese are found by nothing else, so its absence is a real gap and is
    /// always stated.
    var warning: String? {
        switch self {
        case .used: return nil
        case .disabled: return "language model disabled; Japanese personal names were not looked for"
        case .unavailable(let reason):
            return "language model \(reason); Japanese personal names were not looked for"
        case .failed(let reason):
            return "language model failed (\(reason)); Japanese personal names were not looked for"
        }
    }
}
