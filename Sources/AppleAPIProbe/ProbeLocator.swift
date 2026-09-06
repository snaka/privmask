import Foundation

/// Resolves the corpus path for the development probes: the first CLI argument
/// if given, otherwise the corpus in the package this file was compiled from.
enum ProbeLocator {
    static func corpusURL(default relativePath: String = "Corpus/ja-baseline.json") -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1])
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppleAPIProbe
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // package root
        return packageRoot.appendingPathComponent(relativePath)
    }
}
