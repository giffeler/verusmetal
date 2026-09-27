import Foundation
import Darwin
import Synchronization

public struct MinerEvent: Codable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let monotonicNanoseconds: UInt64
    public let sessionID: UUID
    public let type: String
    public let fields: [String: String]

    public init(sessionID: UUID, type: String, fields: [String: String] = [:]) {
        self.schemaVersion = 2
        self.timestamp = Date()
        self.monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.sessionID = sessionID
        self.type = type
        self.fields = fields
    }
}

public final class JSONLEventWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        let encoder: JSONEncoder
        var failure: Error?
    }

    private let state: Mutex<State>

    public var failure: Error? {
        state.withLock { $0.failure }
    }

    public init(path: String?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        var handle: FileHandle?
        var failure: Error?
        if let path {
            do {
                let descriptor = Darwin.open(
                    path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            } catch {
                failure = error
                fputs("verusmetal event log: \(error.localizedDescription)\n", stderr)
            }
        }
        state = Mutex(State(handle: handle, encoder: encoder, failure: failure))
    }

    public func write(_ event: MinerEvent) {
        state.withLock { state in
            guard state.failure == nil, let handle = state.handle else { return }
            do {
                var data = try state.encoder.encode(event)
                data.append(0x0a)
                try Self.append(data, to: handle)
            } catch {
                state.failure = error
                try? handle.close()
                state.handle = nil
                fputs("verusmetal event log: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func append(_ data: Data, to handle: FileHandle) throws {
        // FileHandle may use multiple writes for one record. The file lock
        // keeps those together across independent writers and processes.
        while flock(handle.fileDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        try handle.write(contentsOf: data)
    }

    deinit {
        state.withLock { try? $0.handle?.close() }
    }
}
