import Foundation
import Synchronization

public enum MinerState: String, Codable, Sendable { case connecting, authorized, mining, disconnected, stopped, failed }

public struct MinerSnapshot: Codable, Sendable {
    public var sessionID = UUID()
    public var startedAt = Date()
    public var state = MinerState.connecting
    public var device = ""
    public var jobID: String?
    public var jobs: UInt64 = 0
    public var nonces: UInt64 = 0
    public var dispatches: UInt64 = 0
    public var verified: UInt64 = 0
    public var submitted: UInt64 = 0
    public var accepted: UInt64 = 0
    public var rejected: UInt64 = 0
    public var stale: UInt64 = 0
    public var reconnects: UInt64 = 0
    public var hashrate: Double = 0
    public var averageHashrate: Double = 0
    public var effectiveHashrate: Double = 0
    public var gpuSeconds: Double = 0
    public var activeSeconds: Double = 0
    public var uptimeSeconds: Double = 0
    public var thermalState = 0
    public var lowPowerMode = false
    public var lastError: String?
}

public final class StatisticsStore: Sendable {
    private let value = Mutex(MinerSnapshot())
    private let start = ProcessInfo.processInfo.systemUptime
    public init() {}
    public func update(_ body: (inout MinerSnapshot) -> Void) { value.withLock { body(&$0) } }
    public func snapshot() -> MinerSnapshot {
        value.withLock { value in
            var result = value
            result.uptimeSeconds = ProcessInfo.processInfo.systemUptime-start
            result.effectiveHashrate = Double(result.nonces)/max(0.001,result.uptimeSeconds)
            result.thermalState = ProcessInfo.processInfo.thermalState.rawValue
            result.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            return result
        }
    }
    public func recordBatch(nonces: Int, dispatches: Int, gpuSeconds: Double, wallSeconds: Double, hashrateWindowSeconds: Double) {
        update {
            $0.dispatches += UInt64(dispatches)
            $0.nonces += UInt64(nonces); $0.gpuSeconds += gpuSeconds; $0.activeSeconds += wallSeconds
            $0.hashrate = Double(nonces)/max(0.000001,hashrateWindowSeconds)
            $0.averageHashrate = Double($0.nonces)/max(0.000001,$0.activeSeconds)
        }
    }
    public func prometheus() -> String {
        let s = snapshot()
        return "verusmetal_hashes_total \(s.nonces)\nverusmetal_hashrate \(s.hashrate)\nverusmetal_shares_accepted_total \(s.accepted)\nverusmetal_shares_rejected_total \(s.rejected)\n"
    }
}
