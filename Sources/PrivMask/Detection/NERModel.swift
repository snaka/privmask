import CoreML
import Foundation

/// The compiled Core ML model from `Scripts/ner/package.sh`: ids in, one label
/// per id out. See #46.
final class NERModel: @unchecked Sendable {  // MLModel.prediction is thread-safe
    enum Failure: Error, CustomStringConvertible {
        case unexpectedOutput(String)
        var description: String {
            switch self {
            case .unexpectedOutput(let what): return "the NER model returned \(what)"
            }
        }
    }

    private let model: MLModel

    init(contentsOf url: URL, computeUnits: MLComputeUnits) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func labels(for ids: [Int32]) throws -> [Int] {
        let shape = [1, NSNumber(value: ids.count)]
        let input = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        for (index, id) in ids.enumerated() {
            input[index] = NSNumber(value: id)
            mask[index] = 1
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": input, "mask": mask]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw Failure.unexpectedOutput("no logits")
        }
        guard logits.shape.count == 3, logits.shape[1].intValue == ids.count else {
            throw Failure.unexpectedOutput("logits of shape \(logits.shape) for \(ids.count) ids")
        }
        let classes = logits.shape[2].intValue
        // argmax, first maximum on a tie, as numpy's.
        return (0..<ids.count).map { token in
            (0..<classes).max { logits[[0, token, $0] as [NSNumber]].floatValue < logits[[0, token, $1] as [NSNumber]].floatValue }!
        }
    }
}

/// Where the model is installed. See #46.
public enum NERResources {
    /// `PRIVMASK_NER_DIR` when set, and only that: a directory the user named
    /// is not silently swapped for another. Otherwise `share/privmask/ner`
    /// beside the real executable, which is where the Homebrew formula puts it.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL
    ) -> [URL] {
        if let named = environment["PRIVMASK_NER_DIR"], !named.isEmpty { return [URL(fileURLWithPath: named)] }
        guard let executable else { return [] }
        return [executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/privmask/ner")]
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL
    ) -> URL? {
        candidates(environment: environment, executable: executable)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ner.mlmodelc").path) }
    }
}

extension NERDetector {
    /// The detector over an installed model directory: `ner.mlmodelc`,
    /// `tokenizer.json`, `words.txt` and `names.txt`.
    ///
    /// ponytail: CPU only, because that is what the accepted detections were
    /// measured on. The Neural Engine is the upgrade once #46's measurement
    /// shows its labels agree.
    public static func load(from directory: URL, computeUnits: MLComputeUnits = .cpuOnly) throws -> NERDetector {
        let tokenizer = try XLMRTokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let model = try NERModel(contentsOf: directory.appendingPathComponent("ner.mlmodelc"), computeUnits: computeUnits)
        func list(_ name: String) throws -> Set<String> {
            wordList(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
        }
        return NERDetector(
            tokenize: { tokenizer.encode($0) }, clsID: tokenizer.clsID, sepID: tokenizer.sepID,
            predict: { try model.labels(for: $0) },
            words: try list("words.txt"), names: try list("names.txt"))
    }

    /// One entry per line. On newlines rather than "\n": Swift reads "\r\n" as
    /// one Character, so a CRLF file would never split on "\n".
    static func wordList(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map(String.init))
    }
}
