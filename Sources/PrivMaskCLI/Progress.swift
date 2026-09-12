import Foundation

/// The line drawn while the model reads, and the sequence that removes it.
///
/// Kept apart from the drawing so that what it says can be tested without a
/// terminal.
enum ProgressLine {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    static var frameCount: Int { frames.count }

    /// Long enough to cover the widest line this can draw.
    static let erase = "\r" + String(repeating: " ", count: 60) + "\r"

    /// `current` is the chunk being read, counted from one.
    ///
    /// Leads with a carriage return so that each draw replaces the last rather
    /// than scrolling. A single chunk gets no counter: "chunk 1 of 1" tells the
    /// reader nothing they cannot already see.
    static func render(frame: Int, current: Int, total: Int) -> String {
        let spinner = frames[frame % frames.count]
        let counter = total > 1 ? " \(current) of \(total)" : ""
        return "\r\(spinner) looking for names\(counter)"
    }
}

/// Draws the progress line, and keeps it moving while a chunk is in flight.
///
/// Only ever writes to stderr, and only when stderr is a terminal: stdout has to
/// stay pipeable, and a pipe or a file has no use for a carriage return and a
/// spinner. That check is also what keeps this quiet under an agent, which sees
/// pipes rather than a terminal.
actor ProgressIndicator {
    static var isSupported: Bool { isatty(STDERR_FILENO) == 1 }

    private var current = 1
    private var total = 1
    private var frame = 0
    private var ticker: Task<Void, Never>?

    /// Roughly ten frames a second: fast enough to read as motion, slow enough
    /// not to be the reason the terminal is busy.
    private static let interval = Duration.milliseconds(100)

    func start(total: Int) {
        self.total = total
        current = 1
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.draw()
                try? await Task.sleep(for: ProgressIndicator.interval)
            }
        }
    }

    func advance(to chunk: Int) {
        current = chunk
        draw()
    }

    /// Erases the line. Whatever is printed next — a warning, the masked text —
    /// starts on a clean one.
    func stop() {
        ticker?.cancel()
        ticker = nil
        write(ProgressLine.erase)
    }

    private func draw() {
        write(ProgressLine.render(frame: frame, current: current, total: total))
        frame += 1
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
