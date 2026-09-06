import Foundation

enum PrivMaskVersion {
    static let current = "0.1.0-dev"
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
    let model: String
    let modelInputTruncated: Bool
}

enum ModelStatus {
    case used
    case disabled
    case unavailable(String)
    case failed(String)

    var description: String {
        switch self {
        case .used: return "used"
        case .disabled: return "disabled"
        case .unavailable(let reason): return "unavailable: \(reason)"
        case .failed(let reason): return "failed: \(reason)"
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
