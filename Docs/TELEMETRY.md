# Mining telemetry

Use `--stats-file PATH` to append JSONL events. Performance snapshots are written
at startup, every 30 seconds, and on normal or handled-error shutdown. Configure
this with `--telemetry-interval SECONDS` (1–3,600). It is independent of terminal
`--stats-interval`; an existing command using `--stats-interval 240` still gets
30-second telemetry. Periodic snapshots run between batches or while waiting for
a job, not from a concurrent GPU sampler. Abrupt process termination cannot
produce a final snapshot.

## Envelope and compatibility

New events use `schemaVersion: 2`. Existing log files are appended without rewriting
older records; readers must accept mixed sessions and schema versions. The envelope
retains `sessionID`, `type`, `timestamp` and string-valued `fields`.

- `timestamp`: UTC ISO 8601 with milliseconds, for matching the pool timeline.
- `monotonicNanoseconds`: host monotonic clock, for ordering and elapsed-time
  analysis without wall-clock adjustments. Do not compare across machines/reboots.
- `sessionID`: identifies one process run; split analysis by session.

No wallet, password, nonce or complete job payload is added to the log.

## Performance snapshots

`performance_snapshot` contains `kind` (`initial`, `periodic`, `final`), device,
state, batch size, available current job/generation/target, thermal state, Low
Power Mode, and cumulative counters. Thermal states are 0 nominal, 1 fair,
2 serious, 3 critical; this is not a temperature measurement.

| Fields | Meaning |
| --- | --- |
| `nonces`, `dispatches`, `gpu_seconds`, `command_wall_seconds`, `uptime_seconds` | Cumulative completed hashes, command count, GPU time, command wall time and session uptime |
| `current_hashrate`, `average_hashrate`, `effective_hashrate` | Existing short-sample rate, active-command average and session-wide effective rate, in H/s |
| `interval_seconds`, `interval_nonces`, `interval_dispatches` | Elapsed time and completed work since the preceding performance snapshot |
| `interval_gpu_seconds`, `interval_command_wall_seconds` | GPU time and command wall time for that completed work |
| `interval_hashrate` | Interval hashes divided by elapsed time, including idle time |
| `interval_gpu_hashrate`, `interval_command_hashrate` | Interval hashes divided by GPU or command wall time |
| `interval_command_overhead_seconds` | Command wall time minus GPU time, clamped at zero |
| `interval_outside_commands_seconds` | Elapsed interval minus command wall time, clamped at zero |
| `verified`, `submitted`, `accepted`, `rejected`, `stale`, `unresolved`, `jobs`, `reconnects` | Cumulative lifecycle counters |

GPU time comes from Metal command-buffer timestamps. Command wall time spans
command creation, encoding, submission and waiting. Outside-command time includes
job/input preparation, candidate processing, logging, idle periods and scheduling;
it is not exclusively CPU overhead. The overhead fields are diagnostic differences,
not independent profiler measurements. Register usage and occupancy still require
Xcode profiling.

The main loop flushes partial statistics windows before periodic/final snapshots,
so interval hashes and dispatch counts sum to the completed session totals. Zero
work yields a zero interval rate. Rates with a zero time denominator are also zero.
The terminal's `current` rate remains a short sample; use `interval_hashrate` for
time-series analysis. No display smoothing or mining optimization is introduced.

`session_ended` preserves the original summary counters and adds cumulative timing,
thermal state, batch size and lifecycle details. Its interval fields span the whole
session; do not add them to the `performance_snapshot` intervals.

## Targets and shares

- `target_changed` records each received target as `target_hex`: exactly 64
  hexadecimal characters, a big-endian 256-bit target. This avoids ambiguity
  between pool difficulty conventions.
- `job_received` includes job ID, generation, target and `clean_jobs`.
- `share_submitted`, `share_accepted` and `share_rejected` include request ID,
  job ID, generation and the target used when submitting that share. A later
  job/target change does not overwrite this context.
- Share responses include `response_ms`, measured with the monotonic clock from
  client send initiation to processing the response. This includes client/network
  scheduling and pool processing; it is not a pure network RTT. Rejections retain
  the sanitized numeric-code diagnostic.

A submission event precedes its response event. It records a send attempt, not
proof of delivery. Unanswered requests across disconnects or shutdown remain
`unresolved = submitted - accepted - rejected`; they are never counted as accepts.
The total is not necessarily the current connection's pending request count.

For diagnosis, compare interval throughput and thermal state against pool samples
from the same time window. Use each share's target to account for variable
difficulty rather than comparing unweighted share counts.
