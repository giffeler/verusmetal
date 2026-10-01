import Foundation
import Network

public struct ShareMetadata: Sendable {
    public let id: Int
    public let jobID: String
    public let generation: UInt64
    public let target: UInt256

    public init(id: Int, job: VerusStratumJob) {
        self.id = id; jobID = job.id; generation = job.generation; target = job.target
    }
    public var telemetryFields: [String: String] {
        ["id": String(id), "job": jobID, "generation": String(generation),
         "target_hex": target.bigEndianBytes.hex]
    }
}

public enum StratumEvent: Sendable {
    case connected
    case subscribed
    case authorized
    case disconnected(String)
    case target(UInt256)
    case job(VerusStratumJob)
    case shareSubmitted(ShareMetadata)
    case shareResult(share: ShareMetadata, accepted: Bool, message: String?, responseMilliseconds: Double)
    case protocolError(String)
}

public enum StratumError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidJob(String)
    case notReady
    case tooManyPendingShares(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Stratum URL; use a host and port without credentials, path or query"
        case .unsupportedScheme(let value): return "Unsupported Stratum URL scheme: \(value)"
        case .invalidJob(let value): return "Invalid Verus Stratum job: \(value)"
        case .notReady: return "Stratum client has not received subscription data and a job"
        case .tooManyPendingShares(let count):
            return "Stratum client already has \(count) pending share submissions"
        }
    }
}

/// Equihash-style Verus Stratum client. It deliberately exposes events
/// rather than owning the solver so stale-work policy stays in the orchestrator.
public final class VerusStratumClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (StratumEvent) -> Void

    static let keepaliveIdleSeconds = 30
    static let keepaliveIntervalSeconds = 10
    static let keepaliveProbeCount = 3

    private let queue = DispatchQueue(label: "dev.verusmetal.stratum")
    private let queueKey = DispatchSpecificKey<Void>()
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let user: String
    private let password: String
    private let handler: EventHandler
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 10
    private var generation: UInt64 = 0
    private var extraNoncePrefix: [UInt8] = []
    private var target: UInt256?
    private var lastJobParams: [Any]?
    private var lastReceived = Date()
    private var receivedJob = false
    private struct PendingShare {
        let metadata: ShareMetadata
        let sentAt: UInt64
    }
    private var pendingShares: [Int: PendingShare] = [:]
    private var ready = false
    private var authorized = false
    private let maximumBufferedBytes = 1_048_576

    public let redactedHost: String

    public init(url value: String, user: String, password: String = "x", handler: @escaping EventHandler) throws {
        guard let url = URL(string: value), let host = url.host, let portValue = url.port,
              let rawPort = UInt16(exactly: portValue), rawPort > 0, let port = NWEndpoint.Port(rawValue: rawPort),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty
        else { throw StratumError.invalidURL(value) }
        switch url.scheme?.lowercased() {
        case "stratum+tcp": parameters = Self.connectionParameters(useTLS: false)
        case "stratum+tls", "stratum+ssl": parameters = Self.connectionParameters(useTLS: true)
        default: throw StratumError.unsupportedScheme(url.scheme ?? "")
        }
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        redactedHost = "\(host):\(portValue)"
        self.user = user
        self.password = password
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    static func connectionParameters(useTLS: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdleSeconds
        tcp.keepaliveInterval = keepaliveIntervalSeconds
        tcp.keepaliveCount = keepaliveProbeCount
        return NWParameters(tls: useTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)
    }

    public func connect() {
        queue.async { [self] in
            self.cancelCurrentConnection()
            self.buffer.removeAll(keepingCapacity: true)
            self.extraNoncePrefix = []
            self.target = nil
            self.lastJobParams = nil
            self.lastReceived = Date()
            self.receivedJob = false
            self.authorized = false
            self.pendingShares.removeAll(keepingCapacity: true)
            self.generation &+= 1
            let connection = NWConnection(to: self.endpoint, using: self.parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                self?.stateChanged(state, connection: connection)
            }
            connection.start(queue: self.queue)
            self.receive(from: connection)
            self.queue.asyncAfter(deadline: .now()+15) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                if !self.authorized || !self.receivedJob {
                    self.reportDisconnect("authorization/job timeout", connection: connection)
                }
            }
            self.checkIdle(connection)
        }
    }

    public func disconnect() {
        queue.async {
            self.cancelCurrentConnection()
            self.buffer.removeAll(keepingCapacity: true)
            self.authorized = false
            self.pendingShares.removeAll(keepingCapacity: true)
            self.generation &+= 1
        }
    }

    @discardableResult
    public func submit(job: VerusStratumJob, nonce: UInt64) throws -> Int {
        return try onQueue {
            guard ready, authorized, connection != nil, job.generation == generation,
                  job.extraNoncePrefix == extraNoncePrefix else { throw StratumError.notReady }
            guard pendingShares.count < 1024 else { throw StratumError.tooManyPendingShares(pendingShares.count) }
            let parameters = try job.submission(user: user, nonce: nonce)
            let id = nextID; nextID += 1
            let metadata = ShareMetadata(id: id, job: job)
            // Emit submission before the response can be processed on this queue.
            handler(.shareSubmitted(metadata))
            pendingShares[id] = PendingShare(metadata: metadata, sentAt: DispatchTime.now().uptimeNanoseconds)
            send(id: id, method: "mining.submit", params: parameters)
            if let candidate = connection {
                queue.asyncAfter(deadline: .now()+30) { [weak self, weak candidate] in
                    guard let self, let candidate, self.connection === candidate,
                          self.pendingShares[id] != nil else { return }
                    self.reportDisconnect("share response timed out", connection: candidate)
                }
            }
            return id
        }
    }

    private func stateChanged(_ state: NWConnection.State, connection candidate: NWConnection) {
        guard connection === candidate else { return }
        switch state {
        case .ready:
            ready = true
            handler(.connected)
            send(id: 1, method: "mining.subscribe", params: ["verusmetal/0.2.1"])
        case .waiting(let error): reportDisconnect(error.localizedDescription, connection: candidate)
        case .failed(let error): reportDisconnect(error.localizedDescription, connection: candidate)
        case .cancelled: reportDisconnect("cancelled", connection: candidate)
        default: break
        }
    }

    private func send(id: Int, method: String, params: [Any]) {
        guard ready, let connection else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        var line = data; line.append(0x0a)
        connection.send(content: line, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, let error else { return }
            self.queue.async {
                self.reportDisconnect(error.localizedDescription, connection: connection)
            }
        })
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let connection else { return }
            guard let self else { return }
            guard self.connection === connection else { return }
            if let data {
                self.lastReceived = Date()
                self.buffer.append(data)
                guard self.drainLines(connection: connection) else { return }
            }
            if self.buffer.count > self.maximumBufferedBytes {
                let message = "Stratum message exceeds \(self.maximumBufferedBytes) buffered bytes"
                self.handler(.protocolError(message))
                self.reportDisconnect(message, connection: connection)
                return
            }
            if let error {
                self.reportDisconnect(error.localizedDescription, connection: connection)
                return
            }
            if complete {
                self.reportDisconnect("remote closed connection", connection: connection)
                return
            }
            self.receive(from: connection)
        }
    }

    private func drainLines(connection: NWConnection) -> Bool {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= maximumBufferedBytes else {
                let message = "Stratum message exceeds \(maximumBufferedBytes) bytes"
                handler(.protocolError(message))
                reportDisconnect(message, connection: connection)
                return false
            }
            let message: [String: Any]
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                guard let parsed = object as? [String: Any] else {
                    throw StratumError.invalidJob("message is not an object")
                }
                message = parsed
            } catch {
                handler(.protocolError(error.localizedDescription))
                continue
            }
            do {
                try process(message)
            } catch {
                handler(.protocolError(error.localizedDescription))
                reportDisconnect("invalid Stratum message", connection: connection)
                return false
            }
        }
        return true
    }

    private func process(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            let params = message["params"] as? [Any] ?? []
            switch method {
            case "mining.set_target":
                guard params.count == 1, let text = params[0] as? String,
                      let bytes = [UInt8](hex: text), bytes.count == 32,
                      UInt256(bigEndian: bytes) != .zero
                else { throw StratumError.invalidJob("invalid share target") }
                target = UInt256(bigEndian: bytes)
                handler(.target(target!))
                if let lastJobParams { try processJob(lastJobParams) }
            case "mining.set_extranonce":
                guard let text = params.first as? String, let prefix = [UInt8](hex: text),
                      (1...14).contains(prefix.count)
                else { throw StratumError.invalidJob("invalid extranonce") }
                extraNoncePrefix = prefix
                if let lastJobParams { try processJob(lastJobParams) }
            case "mining.notify": try processJob(params)
            default: break
            }
            return
        }
        guard let number = message["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let id = Int(number.stringValue) else { return }
        let hasError = message["error"] != nil && !(message["error"] is NSNull)
        if id == 1 {
            guard !hasError else { throw StratumError.invalidJob("subscription rejected") }
            let parsed = try Self.decodeSubscription(message["result"])
            extraNoncePrefix = parsed
            if let lastJobParams { try processJob(lastJobParams) }
            handler(.subscribed)
            send(id: 2, method: "mining.authorize", params: [user, password])
        } else if id == 2 {
            let accepted = (message["result"] as? Bool) ?? false
            if accepted && !hasError { authorized = true; handler(.authorized) }
            else { throw StratumError.invalidJob("pool authorization rejected") }
        } else if let pending = pendingShares.removeValue(forKey: id) {
            let accepted = ((message["result"] as? Bool) ?? false) && !hasError
            let elapsed = DispatchTime.now().uptimeNanoseconds - pending.sentAt
            handler(.shareResult(share: pending.metadata, accepted: accepted,
                message: accepted ? nil : Self.shareRejectionDiagnostic(message["error"]),
                responseMilliseconds: Double(elapsed) / 1_000_000))
        }
    }

    /// Pool-provided prose may echo the authorization parameters. Only a
    /// numeric protocol code crosses into logs and status diagnostics.
    static func shareRejectionDiagnostic(_ raw: Any?) -> String {
        if let array = raw as? [Any], let number = array.first as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           let code = Int(number.stringValue) {
            return "pool rejected share (code \(code))"
        }
        return "pool rejected share"
    }

    private func processJob(_ params: [Any]) throws {
        lastJobParams = params
        guard let target, !extraNoncePrefix.isEmpty else { return }
        let nextGeneration = generation &+ 1
        let job = try VerusStratumJob.decode(params, generation: nextGeneration,
                                            prefix: extraNoncePrefix, target: target)
        generation = nextGeneration
        receivedJob = true
        handler(.job(job))
    }

    static func decodeSubscription(_ raw: Any?) throws -> [UInt8] {
        guard let result = raw as? [Any], result.count >= 2,
              let text = result[1] as? String, let prefix = [UInt8](hex: text),
              (1...14).contains(prefix.count)
        else { throw StratumError.invalidJob("invalid subscription extranonce") }
        return prefix
    }

    private func checkIdle(_ candidate: NWConnection) {
        queue.asyncAfter(deadline: .now()+20) { [weak self, weak candidate] in
            guard let self, let candidate, self.connection === candidate else { return }
            if Date().timeIntervalSince(self.lastReceived) > 120 {
                self.reportDisconnect("pool idle timeout", connection: candidate)
            } else { self.checkIdle(candidate) }
        }
    }

    private func cancelCurrentConnection() {
        ready = false
        authorized = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func reportDisconnect(_ message: String, connection candidate: NWConnection) {
        guard connection === candidate else { return }
        cancelCurrentConnection()
        buffer.removeAll(keepingCapacity: true)
        pendingShares.removeAll(keepingCapacity: true)
        generation &+= 1
        handler(.disconnected(message))
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }
}
