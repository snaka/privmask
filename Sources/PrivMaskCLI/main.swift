import Foundation
import PrivMask

// The CLI exists for two reasons. It is how the detection layers get exercised
// over a corpus — accuracy is the product, so being able to pipe text through
// them matters more than convenience — and it is useful on its own, before any
// of this reaches a UI.

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("privmask: \(message)\n".utf8))
    exit(status)
}

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(Options.usage)", status: 2)
}

if options.showHelp {
    print(Options.usage)
    exit(0)
}

if options.showVersion {
    print("privmask \(PrivMaskVersion.current)")
    exit(0)
}

let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard !input.isEmpty else { exit(0) }

var terms: [String] = []
if let url = options.dictionaryURL {
    if options.dictionaryWasNamed, !FileManager.default.fileExists(atPath: url.path) {
        fail("no dictionary at \(url.path)")
    }
    do {
        terms = try DictionaryFile.load(from: url)
    } catch {
        // A dictionary that exists but cannot be read means masking less than
        // the user asked for. That is the failure this tool exists to prevent,
        // so it stops rather than quietly continuing.
        fail("cannot read dictionary at \(url.path): \(error.localizedDescription)")
    }
}

let pipeline = DetectionPipeline(dictionaryTerms: terms)
var candidates = pipeline.detect(in: input)
var modelStatus = ModelStatus.disabled
var truncated = false

if options.useModel {
    if #available(macOS 26.0, *), FoundationModelDetector.isAvailable {
        do {
            let outcome = try await FoundationModelDetector().detect(in: input)
            candidates = pipeline.detect(in: input, additional: outcome.matches)
            truncated = outcome.truncated
            modelStatus = .used
        } catch {
            // Fail open: the model is an addition, and losing it must not lose
            // everything the deterministic layers already found. The degradation
            // is reported rather than hidden.
            modelStatus = .failed("\(error)")
        }
    } else if #available(macOS 26.0, *) {
        modelStatus = .unavailable(FoundationModelDetector.availabilityDescription)
    } else {
        modelStatus = .unavailable("requires macOS 26 or later")
    }
}

let result = Masker().mask(input, candidates: candidates)

if options.json {
    let report = Report(
        masked: result.text,
        findings: candidates.map { candidate in
            Report.Finding(
                kind: candidate.kind.rawValue,
                confidence: candidate.confidence.name,
                sources: candidate.sources.map(\.rawValue),
                text: candidate.text,
                location: candidate.range.location,
                length: candidate.range.length,
                placeholder: result.replacements.first { $0.range == candidate.range }?.placeholder
            )
        },
        model: modelStatus.description,
        modelInputTruncated: truncated
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else {
        fail("could not encode the report")
    }
    print(text)
} else {
    // The masked text already carries whatever trailing newline the input had.
    print(result.text, terminator: "")
    // Degradation goes to stderr so that stdout stays pipeable, but it is never
    // silent: the user has to be able to tell that names were not looked for.
    if let warning = modelStatus.warning {
        FileHandle.standardError.write(Data("privmask: \(warning)\n".utf8))
    }
    if truncated {
        FileHandle.standardError.write(
            Data("privmask: input was longer than the model layer accepts; the tail was not examined for names\n".utf8)
        )
    }
}
