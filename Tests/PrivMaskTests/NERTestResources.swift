import Foundation

/// Where tests find the NER model: `PRIVMASK_NER_DIR`, as the release workflow
/// sets it, then what `Scripts/ner/export.py` and `package.sh` leave in
/// `.build/ner/export`. Tests that need it are disabled without it: the model
/// is not committed. See #46.
enum NERTestResources {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PrivMaskTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    static var directory: URL? {
        // A directory named in the environment is the only one looked at, so
        // PRIVMASK_NER_DIR=/nonexistent runs the suite as CI without a model would.
        let candidate = ProcessInfo.processInfo.environment["PRIVMASK_NER_DIR"].map { URL(fileURLWithPath: $0) }
            ?? packageRoot.appendingPathComponent(".build/ner/export")
        return FileManager.default.fileExists(atPath: candidate.appendingPathComponent("tokenizer.json").path) ? candidate : nil
    }

    static var hasTokenizer: Bool { directory != nil }
    static var hasModel: Bool {
        directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ner.mlmodelc").path) } ?? false
    }

    /// The Python detections the model was accepted on. `export.py` writes them
    /// locally; the release workflow's model tarball does not carry them.
    static let export = packageRoot.appendingPathComponent(".build/ner/export")
    static var hasPythonDetections: Bool {
        hasModel && FileManager.default.fileExists(atPath: export.appendingPathComponent("detections-dev.json").path)
    }

    static let fixture = packageRoot.appendingPathComponent("Tests/PrivMaskTests/Fixtures/ner-tokens.json")
}
