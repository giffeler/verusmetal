# Command-line reference

Run `verusmetal --help` for a summary, `verusmetal COMMAND --help` (or `-h`) for
command-specific usage, and `verusmetal --version` for the CLI version. Commands
use long options with a separate value: `--duration 10`, not `--duration=10`.
Unknown options, duplicate options, missing values and values supplied to flags
are errors. Success exits with status 0; argument or runtime errors exit with
status 2 and write diagnostics to standard error.

## Devices

```sh
verusmetal devices
verusmetal devices --json
```

Lists available Metal devices. JSON is an array with `name`, `unifiedMemory` and
`recommendedWorkingSetBytes`. An empty array means no Metal device was found.
Mining uses the system default Metal device; there is no device-selection option.

## Benchmark

```sh
verusmetal benchmark --duration 10 --batch-nonces 32768 --json
```

Measures full VerusHash v2.2 on a synthetic 1,487-byte input, without contacting a
pool. It uses the same per-job preparation and GPU nonce path as mining, with
the nonce wholly in the final 15-byte tail. At least 0.75 seconds of warmup precedes the timed loop. A dispatch already
in progress finishes before the duration limit is applied.

| Option | Default | Accepted values |
| --- | --- | --- |
| `--duration SECONDS` | `10` | Integers from 1 to 3,600 |
| `--batch-nonces N` | `32768` | Integers from 1 to 32,768 |
| `--batch N` | Same setting | Compatibility alias; do not combine with `--batch-nonces` |
| `--json` | Off | Flag; writes one JSON object instead of text |

Text reports MH/s. JSON schema version 1 reports rates in **hashes per second**:

| Field | Meaning |
| --- | --- |
| `schemaVersion`, `version`, `device` | Report format, CLI version and device name |
| `batchNonces`, `requestedDurationSeconds` | Requested workload settings |
| `durationSeconds` | Measured loop duration, excluding warmup |
| `nonces`, `dispatches` | Completed work in the timed loop |
| `gpuSeconds` | Sum of Metal command GPU durations |
| `commandWallSeconds` | Sum of command encode/submit/wait durations |
| `gpuHashrate` | Nonces divided by GPU duration |
| `averageHashrate` | Nonces divided by command wall duration |
| `effectiveHashrate` | Nonces divided by complete loop duration |

These are local synthetic measurements, not pool share rates. Compare settings
under similar thermal and power conditions using alternating repeated runs.

## Verify

```sh
verusmetal verify --fixtures tests/v22-vectors.json
```

Checks the independent reference digests on both CPU and GPU with Metal shader
validation enabled. The fixture file is required and is distributed with the
source, not embedded in the standalone executable.

## Mine

```sh
verusmetal mine --config Config/local.json --batch-nonces 32768 \
  --stats-file build/mining.jsonl
```

Alternatively, provide `--pool URL --wallet ADDRESS`. Configuration JSON contains
required `pool` and `wallet` strings and an optional `worker` string. CLI values
override the matching fields. Other settings are CLI options only.

| Option | Default | Accepted values or behavior |
| --- | --- | --- |
| `--config PATH` | None | Read pool, wallet and optional worker from JSON |
| `--pool URL` | Configured pool | `stratum+ssl://`, `stratum+tls://` or explicitly selected `stratum+tcp://`; host and port required |
| `--wallet ADDRESS` | Configured wallet | Valid Verus transparent address |
| `--worker NAME` | `m4` | 1–64 ASCII letters or digits |
| `--batch-nonces N` | `32768` | 1–32,768 nonces per dispatch |
| `--batch N` | Same setting | Compatibility alias; do not supply both names |
| `--duration SECONDS` | Unlimited | Integer from 1 to 604,800 |
| `--stop-after-shares N` | Unlimited | Integer from 1 to 1,000,000 accepted shares |
| `--stats-file PATH` | Disabled | Append session-tagged JSONL; parent directory must exist |
| `--stats-interval SECONDS` | `10` | Mining statistics every 1–3,600 seconds |
| `--telemetry-interval SECONDS` | `30` | JSONL snapshots every 1–3,600 seconds |
| `--api-bind ADDRESS:PORT` | Disabled | IPv4 loopback only; for example `127.0.0.1:4079` |

Startup reports GPU preparation, pool connection, subscription, worker authorization
and waiting for the first job as they happen. Terminal wait times refresh every
second, independently of `--stats-interval`; redirected output records each phase
once without cursor control. Mining statistics appear immediately when an authorized
job is available. Reconnects show the retry delay and subsequent connection phases.

The first reached duration/share limit ends the session. Ctrl-C or SIGTERM also
stops mining. Every GPU-found share is verified on the CPU before submission.

The pool password comes from `VERUSMETAL_POOL_PASSWORD` and defaults to `x`.
There is no password argument or password field in the configuration schema.
Keep local settings under `Config/`; Git ignores JSON files there except explicit
example files. Public examples use wallet placeholders. Never provide private
keys or seed phrases: the miner only needs a public receiving address.

TLS uses system certificate validation; a failed TLS connection never switches
automatically to plaintext. The status API is opt-in and loopback-only. See
[protocol](PROTOCOL.md) and [telemetry](TELEMETRY.md) for their contracts.

## Execution limits

The current solver uses one synchronous GPU command at a time, a fixed
128-thread group and the cached nonce kernel. At the default batch of 32,768,
explicit GPU buffers occupy 269,624,032 bytes (257.134 MiB): 256 MiB of sparse
per-nonce key-write slots, 1 MiB of digests, 128 KiB of candidate flags, an
8,896-byte prepared key/seed state and a 32-byte target. Threadgroup masks add
8 KiB per resident group. No per-nonce input buffer or pristine-key copy is made.
Job/prefix/input/layout changes invalidate preparation. For generic API inputs
whose nonce overlaps a full 32-byte block, the solver uses full hashing and
reports `usesCachedHash == false`; that path also allocates input copies and
8,896 workspace bytes per nonce. Zero-byte nonce fields can always use caching.

The solver keeps command buffers synchronous; nonce allocation, stale-job
rejection and statistics accounting retain their existing semantics. It has no CPU
mining mode, performance profiles, autotuning, selectable kernels or prebuilt mining dataset.
The benchmark has JSON output; the mining command uses terminal status and the
separate JSONL telemetry stream. Hardware temperatures in degrees are not exposed;
telemetry reports the macOS thermal state and Low Power Mode.
