# VerusMetal

VerusCoin GPU miner for Apple Silicon, built with Swift and Metal and an
independently written VerusHash v2.2 implementation. Nonce search runs on the GPU, with one nonce per thread. Job-constant input
absorption and key expansion run once on the CPU; each GPU thread performs the
nonce-dependent mix and finalization.

The CPU manages the pool connection and GPU dispatches, and verifies GPU-found
share candidates before submission. The shared canonical hash core also
supports correctness tests and CPU-versus-GPU benchmarks. The mining command
uses the GPU for nonce search; it has no CPU mining mode.

**Status:** development GPU miner tested on Apple M4. LuckPool accepted two shares
in a 115-second test on 2026-09-27, at 1.038 MH/s effective throughput. This is a
short functional test, not a long-term stability or performance guarantee.
[Validation and evidence](Docs/VALIDATION.md).

## Download

A Developer ID signed and notarized arm64 executable is available from the
[VerusMetal page](https://ios.gekko.de/verusmetal), with its SHA-256 checksum and
corresponding source. Extract the ZIP and run `./verusmetal --help` from Terminal.
Requires Apple Silicon and macOS 27 or later; Xcode is only needed to build from
source. See the [0.2.0 release notes](Docs/releases/0.2.0.md) for artifact
identity, validation and limits.

## Requirements and build

- Apple Silicon Mac running macOS 27 or later.
- Xcode 27 with the Metal compiler and Swift 6.4, selected with `xcode-select`
  or an explicit `DEVELOPER_DIR`.
- XcodeGen on `PATH`; Python 3 for integration tests and research tools.

Run all commands from the repository root:

```sh
make miner
./build/miner/Build/Products/Release/verusmetal devices
./build/miner/Build/Products/Release/verusmetal verify --fixtures tests/v22-vectors.json
./build/miner/Build/Products/Release/verusmetal --help
```

`project.yml` generates `VerusMetal.xcodeproj`; generated projects and build
outputs are ignored by Git. The Release executable embeds its Metal library and
can run without a sibling `.metallib`. It is not a signed/notarized distribution.

## Standalone executable

```sh
make standalone
```

This places the Release executable at `Distribution/verusmetal` and writes
`Distribution/verusmetal.sha256`. Copy the executable to any directory on the
supported Mac. Mining needs no external `.metal`, `.metallib`, configuration file
or project sources when all settings are supplied as arguments. The operating
system's Metal and Swift libraries are still required; Xcode is needed to build,
not to run the executable. This local build is not Developer ID signed or notarized.

From the directory containing the executable:

```sh
caffeinate -i ./verusmetal mine \
  --pool stratum+tcp://eu.luckpool.net:3956 \
  --wallet YOUR_VERUS_TRANSPARENT_ADDRESS \
  --worker m4 \
  --batch-nonces 32768 \
  --stats-file verusmetal.jsonl \
  --stats-interval 240
```

`caffeinate -i` prevents idle system sleep while the miner runs. Stop with Ctrl-C.
VerusMetal uses the optimized GPU kernel directly and does not prebuild a mining
dataset. See the [command-line reference](Docs/CLI.md) for all supported options.

## Mining

For the tested LuckPool endpoint, create a local configuration:

```sh
cp Config/luckpool-tcp.example.json Config/luckpool-tcp.local.json
```

Replace `YOUR_VERUS_TRANSPARENT_ADDRESS` in that file with your address. Worker
is `m4`. This endpoint uses plaintext TCP, explicitly selected by its
`stratum+tcp://` scheme. Local configuration files are ignored by Git.

```sh
./build/miner/Build/Products/Release/verusmetal mine \
  --config Config/luckpool-tcp.local.json \
  --stats-file build/mining.jsonl
```

Use Ctrl-C or SIGTERM to stop. Add `--duration 180 --stop-after-shares 2` for a
bounded test; it stops at the time limit or after two accepted shares, whichever
comes first. The default batch is 32,768 hashes (`--batch-nonces`); `--batch` remains
a compatibility alias. Supply only one of these option names. The cached GPU path
uses approximately 257.13 MiB of buffers at this default (256 MiB for sparse key
writes), plus 8 KiB of threadgroup masks per group. It uploads one 8,896-byte
prepared state per job/prefix and resets mutation masks for every dispatch.

Short, paired M4 tests measured about 2.23x higher dispatch throughput at equal
batch size. This is local synthetic evidence; the published live-pool result above
predates caching. See the [cache study](Docs/research/KEY-CACHING.md).

For another pool, copy `Config/example.json` to `Config/local.json` and fill in
its endpoint and your address. `make mine` builds and uses `Config/local.json`.
Edit existing local files rather than overwriting them. CLI options override
corresponding configuration fields. Password defaults to `x`; override with
`VERUSMETAL_POOL_PASSWORD` if required by the pool.

TLS endpoints use `stratum+ssl://` or `stratum+tls://` and macOS certificate
validation. There is no automatic fallback to plaintext. The certificate on
LuckPool port 3958 was expired when checked on 2026-09-27; the successful test used
port 3956. Certificate failures remain fatal to that connection.

The miner supports job changes, GPU nonce search, CPU share verification, submission
and reconnection with bounded backoff. Supported layouts and operational limits
are described in [protocol notes](Docs/PROTOCOL.md).

## Verification and monitoring

```sh
make test-miner         # XCTest, 148 independent vectors, Metal validation
make integration-miner # CLI, synthetic local pool, reconnect and status API checks
make sanitize-v22      # CPU AddressSanitizer and UndefinedBehaviorSanitizer
```

For scripts, `devices --json` returns device information and
`benchmark --duration 10 --batch-nonces 32768 --json` returns measured rates in
hashes per second. Use `--version` to print the CLI version and `COMMAND --help`
for command-specific usage.

These checks do not contact an external mining pool. CPU/GPU agreement alone is
not an independent oracle; reference-vector provenance is recorded with the
fixtures. See the [development guide](Docs/DEVELOPMENT.md).

`--stats-file PATH` writes session-tagged JSONL events, with performance snapshots
at startup, shutdown and every 30 seconds (`--telemetry-interval SECONDS`). Events
include millisecond timestamps, monotonic timing, share targets and response times.
Existing logs are appended without rewriting older sessions.
[Telemetry fields and interpretation](Docs/TELEMETRY.md).

`--stats-interval SECONDS`
controls terminal updates. In an interactive terminal, status refreshes in place
on one line and adapts to the available width. Redirected output uses plain lines.
Accepted shares update the counters and JSONL log without a separate terminal
message. Rejections and connection diagnostics remain visible, and shutdown ends
the status line with a newline. `--api-bind 127.0.0.1:4079` enables a loopback-only API
with `/v1/status`, `/v1/devices`, `/metrics` and `/healthz`. Status includes hash
rates, share counters, reconnects and thermal state. Health describes process
state; pool acknowledgements establish share acceptance. Unacknowledged shares
remain unresolved rather than being counted as accepted.

## Repository

| Path | Purpose |
| --- | --- |
| `Sources/VerusMetalCore` | Transport, jobs, GPU search and telemetry |
| `Sources/verusmetal` | CLI and mining lifecycle |
| `src/v22` | Metal hash core, CPU verifier and standalone benchmark |
| `tests` | Independent vectors, unit tests and local pool integration |
| `Docs` | Validation, protocol and development documentation |
| `Docs/research`, `experiments`, `tools` | Historical experiments and reproduction tools |
| `Config` | Public examples and ignored local settings |
| `vendor` | License notices and infrastructure provenance |

The [research index](Docs/research/README.md) covers Haraka screening, register
pressure, instruction optimization and parallelism. Historical hash rates refer
to their stated workloads and must not be compared directly with mining rates.

See [contributing](Docs/CONTRIBUTING.md) for change validation and bug reports, and
the [publication review](Docs/PUBLIC-REVIEW.md) for the reviewed source and history.

GPLv3: [LICENSE](LICENSE). The separate Haraka screening reference carries its
[MIT notice](vendor/HARAKA-LICENSE); it is not linked into the miner.
