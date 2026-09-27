import Foundation
import VerusMetalCore

protocol MiningStratumClient: AnyObject, Sendable {
    func connect()
    func disconnect()
    @discardableResult func submit(job: VerusStratumJob, nonce: UInt64) throws -> Int
}
extension VerusStratumClient: MiningStratumClient {}

struct NonceSequence {
    private var next: UInt64
    private let maximum: UInt64
    private var exhausted = false
    init(start: UInt64, maximum: UInt64) { self.next = start; self.maximum = maximum }
    mutating func take(_ count: Int) throws -> UInt64 {
        guard count > 0, !exhausted, next <= maximum, UInt64(count-1) <= maximum-next
        else { throw VerusError.invalid("Nonce range exhausted") }
        let first = next
        let last = next+UInt64(count-1)
        if last == maximum { exhausted = true } else { next = last+1 }
        return first
    }
}

/// Coordinates the condition-guarded job lifecycle and reconnect handling.
final class MiningCoordinator: @unchecked Sendable {
    let stats: StatisticsStore
    let writer: JSONLEventWriter
    private let condition = NSCondition()
    private let reconnectQueue = DispatchQueue(label: "dev.verusmetal.reconnect")
    private var client: (any MiningStratumClient)?
    private var job: VerusStratumJob?
    private var authorized = false
    private var stopped = false
    private var reconnectAttempt = 0
    private var reconnectGeneration: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let reconnectDelay: TimeInterval

    init(stats: StatisticsStore, writer: JSONLEventWriter, reconnectDelay: TimeInterval = 1) {
        self.stats = stats; self.writer = writer; self.reconnectDelay = reconnectDelay
    }
    func configure(client: any MiningStratumClient) {
        condition.lock(); self.client = client; condition.unlock()
    }
    func start() {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { return }
        emit("session_started"); client?.connect()
    }
    func handle(_ event: StratumEvent) {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { return }
        switch event {
        case .connected:
            stats.update { $0.state = .connecting; $0.lastError = nil }; emit("connected")
        case .authorized:
            authorized = true; stats.update { $0.state = job == nil ? .authorized : .mining }
            emit("authorized"); condition.broadcast()
        case .target:
            break
        case .job(let incoming):
            job = incoming; reconnectAttempt = 0
            stats.update { $0.jobID = incoming.id; $0.jobs += 1; if authorized { $0.state = .mining } }
            emit("job_received", ["job":incoming.id, "generation":String(incoming.generation)])
            condition.broadcast()
        case .shareResult(let id, let accepted, let message):
            stats.update { if accepted { $0.accepted += 1 } else { $0.rejected += 1; $0.lastError = message } }
            emit(accepted ? "share_accepted" : "share_rejected", ["id":String(id)])
            print(accepted ? "Share accepted (\(id))" : "Share rejected (\(id))")
            condition.broadcast()
        case .protocolError(let reason):
            stats.update { $0.lastError = reason }; emit("protocol_error", ["reason":reason])
        case .disconnected(let reason):
            job = nil; authorized = false; reconnectGeneration &+= 1
            stats.update { $0.state = .disconnected; $0.lastError = reason }
            print("Disconnected: \(reason)")
            emit("disconnected", ["reason":reason]); condition.broadcast()
            let token = reconnectGeneration
            let delay = min(30, reconnectDelay*pow(2,Double(min(reconnectAttempt,5))))
            reconnectAttempt += 1
            reconnectWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.condition.lock()
                defer { self.condition.unlock() }
                let client = !self.stopped && self.reconnectGeneration == token ? self.client : nil
                if let client {
                    self.stats.update { $0.reconnects += 1; $0.state = .connecting }
                    client.connect()
                }
            }
            reconnectWorkItem = item
            reconnectQueue.asyncAfter(deadline: .now()+delay, execute: item)
        }
    }
    func nextWork() -> VerusStratumJob? {
        condition.lock(); defer { condition.unlock() }
        if !stopped && (!authorized || job == nil) { _ = condition.wait(until: Date().addingTimeInterval(0.2)) }
        return !stopped && authorized ? job : nil
    }
    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    func isCurrent(_ work: VerusStratumJob) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !stopped && authorized && job?.generation == work.generation
    }
    func submit(_ candidate: Candidate, for work: VerusStratumJob) throws {
        guard VerusHash.digest(try work.input(nonce: candidate.nonce)) == candidate.digest,
              VerusHash.meetsTarget(candidate.digest, work.target)
        else { throw VerusError.invalid("CPU/GPU share verification failed") }
        stats.update { $0.verified += 1 }
        condition.lock()
        let client = !stopped && authorized && job?.generation == work.generation ? self.client : nil
        condition.unlock()
        guard let client else { stats.update { $0.stale += 1 }; return }
        while isCurrent(work) {
            do {
                let id = try client.submit(job: work, nonce: candidate.nonce)
                stats.update { $0.submitted += 1 }; emit("share_submitted", ["id":String(id)])
                return
            } catch StratumError.notReady { break }
            catch StratumError.tooManyPendingShares {
                condition.lock()
                if !stopped { _ = condition.wait(until: Date().addingTimeInterval(0.05)) }
                condition.unlock()
            }
        }
        stats.update { $0.stale += 1 }
    }
    func stop() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true; authorized = false; job = nil; reconnectGeneration &+= 1
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        let client = client; condition.broadcast(); condition.unlock()
        client?.disconnect()
    }
    func finish(failed: Bool = false) {
        stop(); stats.update { $0.state = failed ? .failed : .stopped }
        let s = stats.snapshot()
        emit("session_ended", ["nonces":String(s.nonces),"accepted":String(s.accepted),
                               "rejected":String(s.rejected),"submitted":String(s.submitted),
                               "unresolved":String(s.submitted >= s.accepted+s.rejected ? s.submitted-s.accepted-s.rejected : 0),
                               "effective_hashrate":String(s.effectiveHashrate)])
    }
    private func emit(_ type: String, _ fields: [String:String] = [:]) {
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID,type:type,fields:fields))
    }
}
