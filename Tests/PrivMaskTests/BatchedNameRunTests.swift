import Foundation
import Testing

@testable import PrivMask

/// Running the model over several chunks, and what happens when one of them
/// fails.
///
/// One throw used to lose the whole layer. With several calls that is
/// untenable: a runaway on chunk 3 must not discard what chunks 1, 2 and 4
/// found, and the chunk that failed has to be reported rather than dropped.
@Suite("Running the name model chunk by chunk")
struct BatchedNameRunTests {
    private struct Boom: Error, CustomStringConvertible {
        var description: String { "exceededContextWindowSize" }
    }

    private func setUp(_ text: String, characterLimit: Int) -> (String, [JapaneseText.Batch]) {
        (text, JapaneseText.batches(JapaneseText.japaneseLines(of: text), characterLimit: characterLimit))
    }

    @Test("A name found in any chunk lands at its offset in the original text")
    func matchesMapToTheOriginal() async {
        let text = (1...10).map { "第\($0)報。担当は田中健一です。" }.joined(separator: "\n")
        let (original, batches) = setUp(text, characterLimit: 60)
        #expect(batches.count > 1)

        let result = await BatchedNameRun.run(text: original, batches: batches) { _ in ["田中健一"] }

        #expect(result.failures.isEmpty)
        #expect(result.matches.count == 10)
        let source = original as NSString
        for match in result.matches {
            #expect(source.substring(with: match.range) == "田中健一")
        }
    }

    @Test("A chunk that fails does not lose what the other chunks found")
    func failureIsIsolated() async {
        let text = (1...10).map { "第\($0)報。担当は田中健一です。" }.joined(separator: "\n")
        let (original, batches) = setUp(text, characterLimit: 60)

        var call = 0
        let result = await BatchedNameRun.run(text: original, batches: batches) { _ in
            call += 1
            if call == 2 { throw Boom() }
            return ["田中健一"]
        }

        #expect(result.failures.count == 1)
        #expect(!result.matches.isEmpty, "the chunks that succeeded still count")
    }

    @Test("A failure says which chunk, of how many, and how much text went unexamined")
    func failureNamesTheChunk() async {
        let text = (1...10).map { "第\($0)報。担当は田中健一です。" }.joined(separator: "\n")
        let (original, batches) = setUp(text, characterLimit: 60)

        var call = 0
        let result = await BatchedNameRun.run(text: original, batches: batches) { _ in
            call += 1
            if call == 2 { throw Boom() }
            return []
        }

        let failure = try! #require(result.failures.first)
        #expect(failure.index == 2)
        #expect(failure.total == batches.count)
        #expect(failure.characters == batches[1].text.count)
        #expect(failure.reason.contains("exceededContextWindowSize"))
    }

    @Test("A span the model invented is counted, not masked")
    func ungroundedSpansAreNotMatched() async {
        let (original, batches) = setUp("担当は田中健一です。", characterLimit: 200)

        let result = await BatchedNameRun.run(text: original, batches: batches) { _ in
            ["田中健一", "山田太郎"]
        }

        #expect(result.matches.count == 1)
        #expect(result.ungroundedTexts == ["山田太郎"])
    }

    @Test("Every chunk is asked, even after one fails")
    func everyChunkIsAttempted() async {
        let text = (1...10).map { "第\($0)報。担当は田中健一です。" }.joined(separator: "\n")
        let (original, batches) = setUp(text, characterLimit: 60)

        var seen = 0
        _ = await BatchedNameRun.run(text: original, batches: batches) { _ in
            seen += 1
            throw Boom()
        }
        #expect(seen == batches.count)
    }
}
