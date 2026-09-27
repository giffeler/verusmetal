import Foundation
import Darwin
import VerusMetalCore

/// Serializes status refreshes and asynchronous connection diagnostics.
final class MiningConsole: @unchecked Sendable {
    private let lock = NSLock()
    private let output = FileHandle.standardOutput
    private let terminal = isatty(STDOUT_FILENO) == 1
    private var statusVisible = false

    func status(_ snapshot: MinerSnapshot) {
        lock.lock(); defer { lock.unlock() }
        var columns: Int?
        if terminal {
            var size = winsize()
            let width = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0
                ? Int(size.ws_col) : 80
            columns = max(1, width - 1)
        }
        let line = MinerStatusLineFormatter.format(snapshot, maximumColumns: columns)
        write(terminal ? "\r\u{001B}[2K" + line : line + "\n")
        statusVisible = terminal
    }

    func message(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if statusVisible { write("\r\u{001B}[2K"); statusVisible = false }
        write(text + "\n")
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if statusVisible { write("\n"); statusVisible = false }
    }

    private func write(_ text: String) {
        output.write(Data(text.utf8))
    }
}
