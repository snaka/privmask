import Testing

@testable import PrivMaskCLI

@Suite("Command-line options")
struct OptionsTests {
    @Test("NER runs unless --no-ner is given")
    func nerFlag() throws {
        #expect(try Options.parse([]).useNER)
        #expect(try !Options.parse(["--no-ner"]).useNER)
        #expect(try Options.parse(["--no-ner"]).useModel, "--no-ner leaves the language model alone")
    }

    @Test("The help names --no-ner, and no longer says names need macOS 26")
    func help() {
        #expect(Options.usage.contains("--no-ner"))
        #expect(!Options.usage.contains("Japanese personal names are found only by that layer"))
    }
}
