import Foundation

/// Formats Verus mining counters for the CLI status line.
public enum MinerStatusLineFormatter {
    public static func format(_ s: MinerSnapshot, suffix: String = "", maximumColumns: Int? = nil) -> String {
        let full = String(format: "current=%.3f avg=%.3f effective=%.3f MH/s shares=%llu/%llu stale=%llu %@ %@",
                          s.hashrate/1e6, s.averageHashrate/1e6, s.effectiveHashrate/1e6,
                          s.accepted, s.rejected, s.stale, s.state.rawValue, suffix).trimmingCharacters(in: .whitespaces)
        let compact = String(format: "%.3f MH/s shares=%llu/%llu %@", s.effectiveHashrate/1e6,
                             s.accepted, s.rejected, s.state.rawValue)
        guard let maximumColumns else { return full }
        return String((full.count <= maximumColumns ? full : compact).prefix(max(1,maximumColumns)))
    }
}
