import Foundation
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

    private func report(model: ModelStatus, truncated: Bool = false) -> Report {
        Report(masked: "text", findings: [], model: model, modelInputTruncated: truncated)
    }

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

    @Test("warnings reports input the model never saw")
    func warnsWhenInputWasTruncated() throws {
        let warnings = try encode(report(model: .used, truncated: true))["warnings"] as? [String] ?? []
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("not examined") == true)
    }

    @Test("warnings carries every degradation at once")
    func warningsAccumulate() throws {
        let report = report(model: .failed("boom"), truncated: true)
        #expect(try encode(report)["warnings"] as? [String] ?? [] == report.warnings)
        #expect(report.warnings.count == 2)
    }
}
