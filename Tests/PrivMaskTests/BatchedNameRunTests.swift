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

    /// Ten lines, each carrying the same name. Swift Testing builds a fresh
    /// suite value per test, so sharing it costs nothing.
    private let text = (1...10).map { "第\($0)報。担当は田中健一です。" }.joined(separator: "\n")


    private func setUp(_ text: String, characterLimit: Int) -> (String, [JapaneseText.Batch]) {
        (text, JapaneseText.batches(JapaneseText.japaneseLines(of: text), characterLimit: characterLimit))
    }

    @Test("A name found in any chunk lands at its offset in the original text")
    func matchesMapToTheOriginal() async {
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
        let (original, batches) = setUp(text, characterLimit: 60)

        var seen = 0
        _ = await BatchedNameRun.run(text: original, batches: batches) { _ in
            seen += 1
            throw Boom()
        }
        #expect(seen == batches.count)
    }
}

/// A log line is mostly ASCII, and the model refuses it as an unsupported
/// language even though it holds Japanese. The chunk is then sent again, once,
/// narrowed to its runs of Japanese. See #38.
@Suite("Retrying a chunk refused for its language")
struct NarrowedRetryTests {
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "unsupportedLanguageOrLocale" }
    }

    private let log = """
        2026-09-14T09:12:03+09:00 INFO  [order-svc] req=7f3a21 user=井出 遊 action=refund
        2026-09-14T09:12:04+09:00 WARN  [order-svc] 承認待ち: 担当は深見 房太郎さん
        """

    private func batches(_ text: String) -> [JapaneseText.Batch] {
        JapaneseText.batches(JapaneseText.japaneseLines(of: text), characterLimit: 1500)
    }

    @Test("Narrowing keeps only the Japanese runs, each mapped to where it came from")
    func narrowing() throws {
        let narrowed = try #require(JapaneseText.narrowed(batches(log)[0], in: log))
        #expect(!narrowed.text.contains("INFO"))
        #expect(narrowed.text.contains("井出 遊"))
        let found = (narrowed.text as NSString).range(of: "深見 房太郎")
        let original = try #require(narrowed.originalRange(for: found))
        #expect((log as NSString).substring(with: original) == "深見 房太郎")
    }

    @Test("A refused chunk is retried narrowed, and its names land in the original")
    func retried() async {
        var calls: [String] = []
        let result = await BatchedNameRun.run(text: log, batches: batches(log), retryNarrowed: { $0 is Refused }) { sent in
            calls.append(sent)
            if sent.contains("INFO") { throw Refused() }
            return ["井出 遊", "深見 房太郎"]
        }
        #expect(calls.count == 2)
        #expect(result.failures.isEmpty)
        #expect(result.matches.map { (log as NSString).substring(with: $0.range) } == ["井出 遊", "深見 房太郎"])
    }

    @Test("Other errors are not retried")
    func notRetried() async {
        var calls = 0
        let result = await BatchedNameRun.run(text: log, batches: batches(log), retryNarrowed: { $0 is Refused }) { _ in
            calls += 1
            throw CancellationError()
        }
        #expect(calls == 1)
        #expect(result.failures.count == 1)
    }

    @Test("A retry that fails too is reported once")
    func retryFails() async {
        var calls = 0
        let result = await BatchedNameRun.run(text: log, batches: batches(log), retryNarrowed: { $0 is Refused }) { _ in
            calls += 1
            throw Refused()
        }
        #expect(calls == 2)
        #expect(result.failures.count == 1)
        // Named by the chunk the caller sent, not by its narrowed retry.
        #expect(result.failures.first?.characters == batches(log)[0].text.count)
    }
}
