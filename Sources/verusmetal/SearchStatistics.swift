import Foundation
import VerusMetalCore

/// Starts with a one-second sample, then doubles the delay up to the user's limit.
struct MiningStatusSchedule {
    let maximumInterval: TimeInterval
    private var interval: TimeInterval = 1
    private var nextUpdate: TimeInterval?

    var isActive: Bool { nextUpdate != nil }

    mutating func start(at now: TimeInterval) {
        interval = min(1, maximumInterval)
        nextUpdate = now + interval
    }

    mutating func stop() { nextUpdate = nil }

    mutating func consumeIfDue(at now: TimeInterval) -> Bool {
        guard let nextUpdate, now >= nextUpdate else { return false }
        interval = min(maximumInterval, interval * 2)
        self.nextUpdate = now + interval
        return true
    }
}

struct SearchStatisticsSample {
    let nonces: Int
    let dispatches: Int
    let gpuSeconds: Double
    /// Increment of the session-wide union; never use this as the denominator
    /// for this sample's full nonce count when commands cross window boundaries.
    let activeSearchSeconds: Double
    /// Union of the complete submit-to-completion intervals of this sample's
    /// commands, including overlap with earlier samples.
    let hashrateWindowSeconds: Double

    func record(in stats: StatisticsStore) {
        stats.recordBatch(nonces: nonces, dispatches: dispatches, gpuSeconds: gpuSeconds,
                          wallSeconds: activeSearchSeconds, hashrateWindowSeconds: hashrateWindowSeconds)
    }

}

/// Each measurement contains 16 completed commands, or the remaining commands
/// on flush. Its rate uses those commands' full interval union. Cumulative time
/// separately adds only previously unaccounted portions of that union.
/// Callers consume submissions in FIFO order (nondecreasing start timestamps)
/// and drain/flush before a job or dataset change; completion times may overlap
/// or arrive out of order. A new accumulator is safe after the old work drains.
struct SearchStatisticsAccumulator {
    private var nonces = 0
    private var batchCount = 0
    private var wallIntervals: [(start: TimeInterval, end: TimeInterval)] = []
    private var gpuSeconds = 0.0
    private var accountedWallEnd: TimeInterval?

    mutating func append(
        _ batch: SearchBatch,
        flush: Bool = false
    ) -> SearchStatisticsSample? {
        nonces += batch.nonceCount
        batchCount += 1
        gpuSeconds += max(0, batch.gpuSeconds)
        if batch.wallEndTime > batch.wallStartTime {
            wallIntervals.append((batch.wallStartTime, batch.wallEndTime))
        }
        return batchCount >= 16 || flush ? take() : nil
    }

    mutating func flush() -> SearchStatisticsSample? {
        batchCount == 0 ? nil : take()
    }

    private mutating func take() -> SearchStatisticsSample {
        let ordered = wallIntervals.sorted { $0.start < $1.start }
        var activeSearchSeconds = 0.0
        var cursor = accountedWallEnd
        var hashrateWindowSeconds = 0.0
        var windowEnd: TimeInterval?
        for interval in ordered {
            let windowStart = max(windowEnd ?? interval.start, interval.start)
            hashrateWindowSeconds += max(0, interval.end - windowStart)
            windowEnd = max(windowEnd ?? interval.end, interval.end)

            let start = cursor.map { max($0, interval.start) } ?? interval.start
            activeSearchSeconds += max(0, interval.end - start)
            cursor = max(cursor ?? interval.end, interval.end)
        }
        accountedWallEnd = cursor
        let sample = SearchStatisticsSample(
            nonces: nonces,
            dispatches: batchCount,
            gpuSeconds: gpuSeconds,
            activeSearchSeconds: activeSearchSeconds,
            hashrateWindowSeconds: hashrateWindowSeconds)
        nonces = 0
        batchCount = 0
        wallIntervals.removeAll(keepingCapacity: true)
        gpuSeconds = 0
        return sample
    }
}
