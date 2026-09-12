import Foundation
import Testing

@testable import PrivMaskCLI

/// What the terminal shows while the model reads.
///
/// Finding names costs seconds per chunk and the chunks run one after another,
/// so a long document is a long silence. The line has to move even when the
/// chunk number does not — a counter that sits still for twenty seconds looks
/// like a hang.
@Suite("The progress line")
struct ProgressLineTests {
    @Test("It names the chunk being read, and how many there are")
    func showsTheChunkAndTheTotal() {
        let line = ProgressLine.render(frame: 0, current: 3, total: 5)
        #expect(line.contains("3 of 5"))
        #expect(line.contains("names"))
    }

    @Test("One chunk needs no counter")
    func aSingleChunkHasNoCounter() {
        let line = ProgressLine.render(frame: 0, current: 1, total: 1)
        #expect(!line.contains("of"))
        #expect(line.contains("names"))
    }

    @Test("The spinner advances with the frame, so the line moves between chunks")
    func theSpinnerMoves() {
        let frames = (0..<4).map { ProgressLine.render(frame: $0, current: 1, total: 3) }
        #expect(Set(frames).count == 4, "every frame should differ: \(frames)")
    }

    @Test("The frame wraps rather than running off the end")
    func theFrameWraps() {
        let first = ProgressLine.render(frame: 0, current: 1, total: 3)
        #expect(ProgressLine.render(frame: ProgressLine.frameCount, current: 1, total: 3) == first)
        #expect(ProgressLine.render(frame: ProgressLine.frameCount * 7, current: 1, total: 3) == first)
    }

    @Test("It stays on one line, so redrawing replaces it instead of scrolling")
    func itIsASingleLine() {
        let line = ProgressLine.render(frame: 2, current: 2, total: 9)
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("\r"))
    }

    @Test("Erasing leaves the line blank, so a warning printed next is not sharing it")
    func erasingClearsWhatWasDrawn() {
        let longest = ProgressLine.render(frame: 0, current: 99, total: 99)
        let blanks = ProgressLine.erase.filter { $0 == " " }.count
        #expect(blanks >= longest.count)
        #expect(ProgressLine.erase.hasPrefix("\r"))
        #expect(ProgressLine.erase.hasSuffix("\r"))
    }
}
