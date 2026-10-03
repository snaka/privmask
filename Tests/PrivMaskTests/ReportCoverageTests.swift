import Foundation
import PrivMask
import Testing

@testable import PrivMaskCLI

/// What `--json` promises a caller that has to decide whether the masked text is
/// safe to pass on.
///
/// The contract is that `warnings` is empty if and only if every layer ran over
/// the whole input. A caller that checks one thing has to be checking the right
/// thing.
@Suite("What --json says about its own coverage")
struct ReportCoverageTests {
    private func encode(_ report: Report) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(report))
        return object as? [String: Any] ?? [:]
    }

    private func report(
        model: ModelStatus,
        ner: ModelStatus = .used,
        failures: [BatchedNameRun.ChunkFailure] = []
    ) -> Report {
        Report(masked: "text", findings: [], model: model, ner: ner, chunkFailures: failures)
    }

    private static let oneFailure = [
        BatchedNameRun.ChunkFailure(
            index: 2, total: 5, characters: 1204, reason: "exceededContextWindowSize"
        )
    ]

    @Test(
        "model is a bare token, never a sentence",
        arguments: [
            (ModelStatus.used, "used"),
            (ModelStatus.disabled, "disabled"),
            (ModelStatus.unavailable("requires macOS 26 or later"), "unavailable"),
            (ModelStatus.failed("exceededContextWindowSize"), "failed"),
        ]
    )
    func modelIsABareToken(status: ModelStatus, token: String) throws {
        #expect(try encode(report(model: status))["model"] as? String == token)
    }

    @Test("modelDetail carries the reason, and is present as null when there is none")
    func modelDetailIsAlwaysPresent() throws {
        let used = try encode(report(model: .used))
        #expect(used.keys.contains("modelDetail"))
        #expect(used["modelDetail"] is NSNull)

        let unavailable = try encode(report(model: .unavailable("requires macOS 26 or later")))
        #expect(unavailable["modelDetail"] as? String == "requires macOS 26 or later")
    }

    @Test("warnings is empty when every layer ran over the whole input")
    func noWarningsWhenFullyExamined() throws {
        #expect(try encode(report(model: .used))["warnings"] as? [String] == [])
    }

    @Test("warnings reports a model that did not run, and that names were looked for by NER alone")
    func modelDidNotRun() throws {
        let warnings = try encode(report(model: .disabled))["warnings"] as? [String] ?? []
        #expect(warnings == ["language model disabled; Japanese personal names were looked for by the NER model alone"])
    }

    @Test("warnings reports NER that did not run, and that names were looked for by the language model alone")
    func nerDidNotRun() throws {
        let warnings = try encode(report(model: .used, ner: .unavailable("is not installed")))["warnings"] as? [String] ?? []
        #expect(warnings == ["NER model is not installed; Japanese personal names were looked for by the language model alone"])
    }

    @Test("With neither layer, both are named and names were not looked for")
    func neither() throws {
        let warnings = try encode(report(model: .unavailable("requires macOS 26 or later"), ner: .disabled))["warnings"] as? [String] ?? []
        #expect(warnings == [
            "language model requires macOS 26 or later; Japanese personal names were not looked for",
            "NER model disabled; Japanese personal names were not looked for",
        ])
    }

    @Test("ner is a bare token with its reason beside it, as model is")
    func nerToken() throws {
        let json = try encode(report(model: .used, ner: .failed("bad model")))
        #expect(json["ner"] as? String == "failed")
        #expect(json["nerDetail"] as? String == "bad model")
        #expect(try encode(report(model: .used))["nerDetail"] is NSNull)
    }

    @Test("warnings reports a chunk the model never examined, and says which")
    func warnsWhenAChunkWasNotExamined() throws {
        let json = try encode(report(model: .used, failures: Self.oneFailure))
        let warnings = json["warnings"] as? [String] ?? []
        #expect(warnings.count == 1)
        let warning = warnings.first ?? ""
        #expect(warning.contains("chunk 2 of 5"))
        #expect(warning.contains("1204 characters"))
        #expect(warning.contains("not examined"))
    }

    @Test("warnings carries every degradation at once")
    func warningsAccumulate() throws {
        let report = report(model: .failed("boom"), failures: Self.oneFailure)
        #expect(try encode(report)["warnings"] as? [String] ?? [] == report.warnings)
        #expect(report.warnings.count == 2)
    }
}

/// What the CLI tells a caller that is not a person.
///
/// `--json` gained a `warnings` array that says whether the text was fully
/// examined, but nothing pointed anyone at it, and the first thing an agent
/// reaches for — a file path — was answered with a non sequitur.
@Suite("What the CLI tells an agent")
struct AgentFacingCLITests {
    /// The message a caller actually sees, which is what is being asserted —
    /// `fail` interpolates the error into its output.
    private func message(parsing arguments: [String]) -> String {
        do {
            _ = try Options.parse(arguments)
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test("A file path is answered with the way to pass the file")
    func aPositionalArgumentSaysToUseStdin() {
        let message = message(parsing: ["incident.txt"])
        #expect(message.contains("stdin"))
        #expect(message.contains("privmask < incident.txt"))
    }

    @Test("A misspelled flag is still an unknown option, not a file")
    func anUnknownFlagIsUnchanged() {
        #expect(message(parsing: ["--nope"]).contains("unknown option: --nope"))
    }

    @Test("The help points at warnings, which is the one thing worth checking")
    func helpNamesTheCoverageContract() {
        #expect(Options.usage.contains("warnings"))
    }

    @Test("The help says the report carries the unmasked values")
    func helpWarnsThatTheReportIsSensitive() {
        #expect(Options.usage.contains("findings[].text"))
    }

    @Test("The help says masking cannot be undone")
    func helpSaysMaskingIsIrreversible() {
        #expect(Options.usage.lowercased().contains("not reversible"))
    }

    @Test("The help says not to reach for --no-ner or --no-model to go faster")
    func helpWarnsAgainstDisablingTheModelForSpeed() {
        #expect(Options.usage.contains("Do not reach for --no-ner or --no-model"))
    }

    @Test("A failure's detail is one line, not an NSError's whole chain")
    func failureDetailIsShort() {
        let underlying = NSError(domain: "inner", code: 1)
        let error = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "the model could not be loaded", NSUnderlyingErrorKey: underlying,
        ])
        #expect(ModelStatus.failed(error).detail == "the model could not be loaded")
        #expect(ModelStatus.failed(NERDetector.Failure.labelCount(expected: 3, got: 1)).detail
            == "the model returned 1 labels for 3 tokens")
    }
}
