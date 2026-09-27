# Development

Run commands from the repository root. `make` defaults to `make miner`.
Builds require the toolchain listed in the [README](../README.md).

## Build configurations

`project.yml` is the source of truth. `make miner` runs XcodeGen and builds the
Release CLI under `build/miner/Build/Products/Release/verusmetal`. Open the generated
`VerusMetal.xcodeproj` in Xcode after generation if needed. Do not commit it.

- Debug: interactive development.
- Profile: optimized tests, testability and shader source information.
- Release: optimized Swift whole-module compilation, no debug information and an
  embedded Metal library. Code signing is disabled for these local builds.

Swift 6.4 is the compiler requirement; `SWIFT_VERSION: 6.0` selects Swift 6
language mode. The CPU core uses `-mcpu=native`, so release artifacts built on
one machine are not yet a validated distribution for every Apple Silicon model.

## Verification

Run these sequentially; the Xcode targets share a derived-data directory:

```sh
make test-miner
make integration-miner
make sanitize-v22
```

The unit suite covers 148 independent digests, partial GPU groups, target
boundaries, nonce bounds, solution normalization, stale jobs and lifecycle
handling. The integration test starts a local TCP server, checks CPU-verified
submissions, changes jobs, disconnects, reconnects and probes the loopback API.
Its CPU oracle shares our hash core; independent fixture digests provide separate
algorithm evidence. Test fixtures contain a synthetic address.

After modifying the hash core, preserve the independent-vector checks and run
appropriate [research checks](research/README.md). For documentation-only
changes, validate links and command paths; new hashing experiments are unnecessary.

## Local state and evidence

Keep wallets in `Config/local.json` or `Config/*.local.json`. Supply pool passwords
through `VERUSMETAL_POOL_PASSWORD`. Public examples contain placeholders only.
No local configuration or credential is needed to build or run automated tests.

`build/` holds ignored binaries, local logs and GPU traces. Do not remove it as a
routine cleanup step: historical reports may reference evidence retained there.
Selected immutable evidence lives in `experiments/`, including the frozen hash
baseline, Xcode measurements and the successful LuckPool session. Keep raw logs
unchanged; put interpretation and caveats in documentation.

The research report generator writes `Docs/research/REGISTER-PRESSURE.md` and
requires its original local measurement records under `build/v22/register-study`.
Those records are not all distributed in Git. A fresh checkout can run new
experiments but cannot regenerate the exact historical report without them.

The canonical hash core remains in `src/v22`; both the CLI and standalone
benchmark use it. Keep algorithm changes separate from transport or documentation
work. Preserve notices and `vendor/infrastructure-provenance.json` when adapting
infrastructure; never disable TLS verification to work around a pool error.
