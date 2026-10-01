import Foundation
import PrivMask

// Scores one or more systems' name detections against a name corpus, side by
// side. Each detections file is a DetectionsFile; see #28.
//
//     swift run NameScore Corpus/ja-names.json .build/name-score/privmask.json .build/name-score/opus.json

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: NameScore <corpus.json> <detections.json>...\n".utf8))
    exit(64)
}

let corpus = try Corpus.load(contentsOf: URL(fileURLWithPath: arguments[0]))
let reports = try arguments.dropFirst().map {
    NameEvaluator.evaluate(corpus: corpus, detections: try DetectionsFile.load(contentsOf: URL(fileURLWithPath: $0)))
}
print(NameEvaluator.renderComparison(reports))
