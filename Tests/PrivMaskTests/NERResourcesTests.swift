import Foundation
import Testing

@testable import PrivMask

/// Where privmask looks for the model. Homebrew links bin/privmask to the
/// Cellar, and the model sits beside the real file, not the link. See #46.
@Suite("Finding the installed NER model")
struct NERResourcesTests {
    @Test("PRIVMASK_NER_DIR, when set, is the only place looked")
    func environmentOnly() {
        let urls = NERResources.candidates(
            environment: ["PRIVMASK_NER_DIR": "/tmp/model"], executable: URL(fileURLWithPath: "/usr/local/bin/privmask"))
        #expect(urls.map(\.path) == ["/tmp/model"])
    }

    @Test("Otherwise share/privmask/ner beside the executable, with symlinks resolved")
    func besideTheRealExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cellar = root.appendingPathComponent("Cellar/privmask/0.5.0")
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("share/privmask/ner/ner.mlmodelc"), withIntermediateDirectories: true)
        let real = cellar.appendingPathComponent("bin/privmask")
        FileManager.default.createFile(atPath: real.path, contents: Data())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("bin/privmask")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let found = NERResources.directory(environment: [:], executable: link)
        #expect(found?.resolvingSymlinksInPath().path == cellar.appendingPathComponent("share/privmask/ner").resolvingSymlinksInPath().path)
    }

    @Test("No model anywhere is nil, not a guess")
    func nowhere() {
        #expect(NERResources.directory(environment: [:], executable: URL(fileURLWithPath: "/nonexistent/bin/privmask")) == nil)
    }

    @Test("A word list with CRLF line ends is split into its words")
    func crlfWordList() {
        #expect(NERDetector.wordList("森\r\n林\r\n") == ["森", "林"])
        #expect(NERDetector.wordList("森\n林") == ["森", "林"])
    }
}
