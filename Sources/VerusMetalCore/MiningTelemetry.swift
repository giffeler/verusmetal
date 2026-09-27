import Foundation

extension MinerSnapshot {
    /// Rates use completed work between snapshots, including idle time in the interval rate.
    public func telemetryFields(since previous: MinerSnapshot?, batchSize: Int) -> [String: String] {
        let elapsed = max(0, uptimeSeconds - (previous?.uptimeSeconds ?? 0))
        let hashes = nonces - min(nonces, previous?.nonces ?? 0)
        let commands = dispatches - min(dispatches, previous?.dispatches ?? 0)
        let gpu = max(0, gpuSeconds - (previous?.gpuSeconds ?? 0))
        let active = max(0, activeSeconds - (previous?.activeSeconds ?? 0))
        func rate(_ time: Double) -> String { String(time > 0 ? Double(hashes) / time : 0) }
        return [
            "device": device, "state": state.rawValue, "batch_size": String(batchSize),
            "uptime_seconds": String(uptimeSeconds), "nonces": String(nonces),
            "dispatches": String(dispatches), "gpu_seconds": String(gpuSeconds),
            "command_wall_seconds": String(activeSeconds),
            "current_hashrate": String(hashrate), "average_hashrate": String(averageHashrate),
            "effective_hashrate": String(effectiveHashrate),
            "interval_seconds": String(elapsed), "interval_nonces": String(hashes),
            "interval_dispatches": String(commands), "interval_gpu_seconds": String(gpu),
            "interval_command_wall_seconds": String(active),
            "interval_command_overhead_seconds": String(max(0, active - gpu)),
            "interval_outside_commands_seconds": String(max(0, elapsed - active)),
            "interval_hashrate": rate(elapsed), "interval_gpu_hashrate": rate(gpu),
            "interval_command_hashrate": rate(active),
            "thermal_state": String(thermalState), "low_power_mode": String(lowPowerMode),
            "verified": String(verified), "submitted": String(submitted),
            "accepted": String(accepted), "rejected": String(rejected), "stale": String(stale),
            "unresolved": String(submitted - min(submitted, accepted + rejected)),
            "jobs": String(jobs), "reconnects": String(reconnects)
        ]
    }
}
