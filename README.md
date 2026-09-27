# VerusMetal

Apple Silicon CLI miner with an independently written VerusHash v2.2 CPU/Metal
implementation. Each GPU thread computes one complete hash. Every candidate is
checked on the CPU before submission to the pool.

**Status:** development miner tested on Apple M4. LuckPool accepted two shares
in a 115-second test on 2026-09-27, at 1.038 MH/s effective throughput. This is a
short functional test, not a long-term stability or performance guarantee.
[Validation and evidence](Docs/VALIDATION.md).

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
```

`project.yml` generates `VerusMetal.xcodeproj`; generated projects and build
outputs are ignored by Git. The Release executable embeds its Metal library and
can run without a sibling `.metallib`. It is not a signed/notarized distribution.

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
comes first. The default batch is 4,096 hashes (`--batch`).

For another pool, copy `Config/example.json` to `Config/local.json` and fill in
its endpoint and your address. `make mine` builds and uses `Config/local.json`.
Edit existing local files rather than overwriting them. CLI options override
corresponding configuration fields. Password defaults to `x`; override with
`VERUSMETAL_POOL_PASSWORD` if required by the pool.

TLS endpoints use `stratum+ssl://` or `stratum+tls://` and macOS certificate
validation. There is no automatic fallback to plaintext. The certificate on
LuckPool port 3958 was expired when checked on 2026-09-27; the successful test used
port 3956. Certificate failures remain fatal to that connection.

The miner supports job changes, nonce search, CPU verification, share submission
and reconnection with bounded backoff. Supported layouts and operational limits
are described in [protocol notes](Docs/PROTOCOL.md).

## Verification and monitoring

```sh
make test-miner         # XCTest, 148 independent vectors, Metal validation
make integration-miner # Synthetic local pool, reconnect and status API checks
make sanitize-v22      # CPU AddressSanitizer and UndefinedBehaviorSanitizer
```

These checks do not contact an external mining pool. CPU/GPU agreement alone is
not an independent oracle; reference-vector provenance is recorded with the
fixtures. See the [development guide](Docs/DEVELOPMENT.md).

`--stats-file PATH` writes session-tagged JSONL events. `--stats-interval SECONDS`
controls terminal updates. `--api-bind 127.0.0.1:4079` enables a loopback-only API
with `/v1/status`, `/v1/devices`, `/metrics` and `/healthz`. Status includes hash
rates, share counters, reconnects and thermal state. Health describes process
state; pool acknowledgements establish share acceptance. Unacknowledged shares
remain unresolved rather than being counted as accepted.

## Repository

| Path | Purpose |
| --- | --- |
| `Sources/VerusMetalCore` | Transport, jobs, GPU search and telemetry |
| `Sources/verusmetal` | CLI and mining lifecycle |
| `src/v22` | Canonical CPU/Metal hash core and standalone benchmark |
| `tests` | Independent vectors, unit tests and local pool integration |
| `Docs` | Validation, protocol and development documentation |
| `Docs/research`, `experiments`, `tools` | Historical experiments and reproduction tools |
| `Config` | Public examples and ignored local settings |
| `vendor` | License notices and infrastructure provenance |

The [research index](Docs/research/README.md) covers Haraka screening, register
pressure, instruction optimization and parallelism. Historical hash rates refer
to their stated workloads and must not be compared directly with mining rates.

GPLv3: [LICENSE](LICENSE). The separate Haraka screening reference carries its
[MIT notice](vendor/HARAKA-LICENSE); it is not linked into the miner.
