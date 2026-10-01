import Foundation
import Darwin
import VerusMetalCore

/// Serializes status refreshes and asynchronous connection diagnostics.
final class MiningConsole: @unchecked Sendable {
    private let lock = NSLock()
    private let output = FileHandle.standardOutput
    private let terminal = isatty(STDOUT_FILENO) == 1
    private var statusVisible = false
    private var startupText: String?
    private var startupSince = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    init() {
        if terminal {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.verusmetal.startup-status"))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.refreshStartup() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Phase changes are immediate; only terminals receive periodic wait updates.
    func startup(_ text: String?, snapshot: MinerSnapshot? = nil) {
        lock.lock(); defer { lock.unlock() }
        startupText = text
        startupSince = ProcessInfo.processInfo.systemUptime
        if text != nil { writeStartup() }
        else if let snapshot { writeStatus(snapshot) }
    }

    private func refreshStartup() {
        lock.lock(); defer { lock.unlock() }
        if startupText != nil { writeStartup() }
    }

    private func writeStartup() {
        guard let text = startupText else { return }
        let elapsed = Int(ProcessInfo.processInfo.systemUptime - startupSince)
        let line = "\(text) \(elapsed)s"
        writeLine(terminal ? String(line.prefix(maximumColumns() ?? 80)) : line)
    }

    func status(_ snapshot: MinerSnapshot) {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.state == .mining || snapshot.state == .stopped || snapshot.state == .failed else { return }
        guard startupText == nil || snapshot.state == .stopped || snapshot.state == .failed else { return }
        if snapshot.state == .stopped || snapshot.state == .failed { startupText = nil }
        writeStatus(snapshot)
    }

    private func maximumColumns() -> Int? {
        var columns: Int?
        if terminal {
            var size = winsize()
            let width = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0
                ? Int(size.ws_col) : 80
            columns = max(1, width - 1)
        }
        return columns
    }

    private func writeStatus(_ snapshot: MinerSnapshot) {
        writeLine(MinerStatusLineFormatter.format(snapshot, maximumColumns: maximumColumns()))
    }

    private func writeLine(_ line: String) {
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
        timer?.cancel(); timer = nil
        startupText = nil
        if statusVisible { write("\n"); statusVisible = false }
    }

    private func write(_ text: String) {
        output.write(Data(text.utf8))
    }
}
