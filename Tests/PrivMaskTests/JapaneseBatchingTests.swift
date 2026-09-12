import Foundation
import Testing

@testable import PrivMask

/// Splitting a line that is longer than one model call can hold.
///
/// Line granularity is an assumption about logs. A markdown paragraph is one
/// line, so a document can put 700 characters — or 2,000 — on it, and the layer
/// that packs whole lines has nowhere to put that.
@Suite("Splitting a line to fit a model call")
struct SegmentSplittingTests {
    /// Every piece has to be findable at the offset it claims, or a match inside
    /// it maps to the wrong place in the original text.
    private func checkOffsets(_ pieces: [JapaneseText.Segment], in original: String) {
        let text = original as NSString
        for piece in pieces {
            let claimed = NSRange(location: piece.offset, length: (piece.text as NSString).length)
            #expect(NSMaxRange(claimed) <= text.length)
            #expect(text.substring(with: claimed) == piece.text)
        }
    }

    @Test("A line that already fits is left alone")
    func shortLineIsUnchanged() {
        let line = "担当は田中健一です。"
        let segments = JapaneseText.japaneseLines(of: line)
        let pieces = JapaneseText.splitToFit(segments[0], characterLimit: 100)
        #expect(pieces.count == 1)
        #expect(pieces[0].text == line)
        #expect(pieces[0].offset == 0)
    }

    @Test("A long line is cut at sentence ends")
    func splitsAtSentenceEnds() {
        let sentence = "担当の田中健一が対応を進めている。"
        let line = String(repeating: sentence, count: 10)
        let segments = JapaneseText.japaneseLines(of: line)
        let pieces = JapaneseText.splitToFit(segments[0], characterLimit: 60)

        #expect(pieces.count > 1)
        for piece in pieces {
            #expect(piece.text.count <= 60)
            #expect(piece.text.hasSuffix("。"))
        }
        #expect(pieces.map(\.text).joined() == line)
        checkOffsets(pieces, in: line)
    }

    @Test("With no sentence end, it falls back to a clause boundary")
    func fallsBackToClauseBoundary() {
        let clause = "担当は田中健一、副担当は佐藤美咲、"
        let line = String(repeating: clause, count: 8)
        let segments = JapaneseText.japaneseLines(of: line)
        let pieces = JapaneseText.splitToFit(segments[0], characterLimit: 50)

        #expect(pieces.count > 1)
        for piece in pieces { #expect(piece.text.count <= 50) }
        #expect(pieces.dropLast().allSatisfy { $0.text.hasSuffix("、") })
        #expect(pieces.map(\.text).joined() == line)
        checkOffsets(pieces, in: line)
    }

    @Test("An unbroken run is cut hard rather than left unexamined")
    func hardCutIsTheLastResort() {
        let line = String(repeating: "あ", count: 250)
        let segments = JapaneseText.japaneseLines(of: line)
        let pieces = JapaneseText.splitToFit(segments[0], characterLimit: 100)

        #expect(pieces.count == 3)
        for piece in pieces { #expect(piece.text.count <= 100) }
        #expect(pieces.map(\.text).joined() == line)
        checkOffsets(pieces, in: line)
    }

    @Test("No piece is ever empty")
    func noEmptyPieces() {
        let line = "。。。" + String(repeating: "報告。", count: 40)
        let segments = JapaneseText.japaneseLines(of: line)
        let pieces = JapaneseText.splitToFit(segments[0], characterLimit: 30)
        #expect(pieces.allSatisfy { !$0.text.isEmpty })
        #expect(pieces.map(\.text).joined() == line)
        checkOffsets(pieces, in: line)
    }
}

/// Packing lines into model calls.
///
/// The layer this replaces packed whole lines and stopped at the first that
/// would not fit, so everything after it was never looked for. Nothing is
/// dropped here; the input costs as many calls as it takes.
@Suite("Packing lines into model calls")
struct BatchingTests {
    private func segments(_ text: String) -> [JapaneseText.Segment] {
        JapaneseText.japaneseLines(of: text)
    }

    @Test("Lines that fit together make one call")
    func oneBatchWhenItAllFits() {
        let text = "担当は田中健一です。\n連絡は佐藤美咲まで。"
        let batches = JapaneseText.batches(segments(text), characterLimit: 200)
        #expect(batches.count == 1)
        #expect(batches[0].text.contains("田中健一"))
        #expect(batches[0].text.contains("佐藤美咲"))
    }

    @Test("More than one call's worth becomes more than one call, and nothing is dropped")
    func nothingIsDropped() {
        let lines = (1...20).map { "第\($0)報。担当は田中健一、状況を確認のうえ報告します。" }
        let text = lines.joined(separator: "\n")
        let batches = JapaneseText.batches(segments(text), characterLimit: 100)

        #expect(batches.count > 1)
        for line in lines {
            #expect(batches.contains { $0.text.contains(line) }, "lost: \(line)")
        }
    }

    @Test("A match in any batch maps back to where it sits in the original")
    func offsetsSurviveAcrossBatches() {
        let lines = (1...12).map { "第\($0)報。担当は田中健一です。" }
        let text = lines.joined(separator: "\n")
        let original = text as NSString
        let batches = JapaneseText.batches(segments(text), characterLimit: 80)

        var found = 0
        for batch in batches {
            let batchText = batch.text as NSString
            var cursor = 0
            while cursor < batchText.length {
                let search = NSRange(location: cursor, length: batchText.length - cursor)
                let hit = batchText.range(of: "田中健一", range: search)
                if hit.location == NSNotFound { break }
                let mapped = batch.originalRange(for: hit)
                #expect(mapped != nil)
                if let mapped { #expect(original.substring(with: mapped) == "田中健一") }
                found += 1
                cursor = NSMaxRange(hit)
            }
        }
        #expect(found == 12, "every occurrence should be reachable, got \(found)")
    }

    @Test("A line longer than one call is split rather than skipped")
    func longLineIsSplitNotSkipped() {
        let line = String(repeating: "担当の田中健一が状況を確認している。", count: 20)
        let batches = JapaneseText.batches(segments(line), characterLimit: 100)

        #expect(batches.count > 1)
        #expect(batches.map(\.text).joined().contains("田中健一"))
        let total = batches.reduce(0) { $0 + $1.text.count }
        #expect(total >= line.count, "text was lost: \(total) < \(line.count)")
    }

    @Test("A trailing crumb is carried by the previous call, never sent alone")
    func noCrumbIsSentOnItsOwn() {
        // 96 characters a line against a limit of 100, so the 4-character
        // heading cannot join the line before it by ordinary packing: greedy
        // packing leaves it as a call of its own. A fragment that small is what
        // makes the model generate until the context window is gone.
        let body = (1...3).map { _ in String(repeating: "報告。", count: 32) }
        let text = (body + ["# 報告"]).joined(separator: "\n")
        let batches = JapaneseText.batches(segments(text), characterLimit: 100, minimumChunkCharacters: 32)

        #expect(batches.count == 3, "sizes: \(batches.map(\.text.count))")
        #expect(batches.allSatisfy { $0.text.count >= 32 }, "sizes: \(batches.map(\.text.count))")
        // The crumb overshoots the limit rather than travelling alone.
        #expect(batches.last?.text.hasSuffix("# 報告") == true)
        #expect((batches.last?.text.count ?? 0) > 100)
    }

    @Test("A single short line is still sent, because there is nothing to carry it")
    func theOnlyChunkIsSentEvenIfSmall() {
        let batches = JapaneseText.batches(segments("報告"), characterLimit: 100, minimumChunkCharacters: 32)
        #expect(batches.count == 1)
        #expect(batches[0].text == "報告")
    }

    @Test("No input means no calls")
    func noSegmentsMeansNoBatches() {
        #expect(JapaneseText.batches(segments("no japanese here\n"), characterLimit: 100).isEmpty)
    }
}
