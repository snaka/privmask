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
        failures: [BatchedNameRun.ChunkFailure] = []
    ) -> Report {
        Report(masked: "text", findings: [], model: model, chunkFailures: failures)
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

    @Test("warnings reports a model that did not run")
    func warnsWhenTheModelDidNotRun() throws {
        let warnings = try encode(report(model: .disabled))["warnings"] as? [String] ?? []
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("Japanese personal names were not looked for") == true)
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

    @Test("The help says not to reach for --no-model to go faster")
    func helpWarnsAgainstDisablingTheModelForSpeed() {
        #expect(Options.usage.contains("Do not reach for --no-model"))
    }
}
