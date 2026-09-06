import Foundation

/// Loads the user's term list.
///
/// A plain text file, one term per line, is the whole format. It can live in
/// dotfiles, be edited with any editor, and be read by both the CLI and the
/// Raycast extension — which is why the dictionary is the one thing the two
/// share. Detector on/off switches are not shared: those belong to how each
/// front end is being used at the moment, while the dictionary is knowledge
/// about the user's organisation.
public enum DictionaryFile {
    public static var defaultURL: URL {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("privmask/terms.txt")
    }

    /// Terms from `url`, or an empty list if the file does not exist.
    ///
    /// A missing file is normal — most people will never create one — but a file
    /// that exists and cannot be read is not, and throws. Silently masking less
    /// than the user configured is the failure this tool exists to prevent.
    public static func load(from url: URL = defaultURL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    static func parse(_ contents: String) -> [String] {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
