# Development

Run commands from the repository root. `make` defaults to `make miner`.
Builds require the toolchain listed in the [README](../README.md).

## Build configurations

`project.yml` is the source of truth. `make miner` runs XcodeGen and builds the
Release CLI under `build/miner/Build/Products/Release/verusmetal`. Open the generated
`VerusMetal.xcodeproj` in Xcode after generation if needed. Do not commit it.

`make standalone` also copies the Release executable to `Distribution/verusmetal`
and records its SHA-256 checksum. This ignored directory is for local artifacts;
the target does not sign with Developer ID, notarize or publish anything. The
Metal library is embedded in the executable's `__TEXT,__metallib` section and
loaded from memory. A missing embedded library is an error, not a file fallback.

- Debug: interactive development.
- Profile: optimized tests, testability and shader source information.
- Release: optimized Swift whole-module compilation, no debug information and an
  embedded Metal library. Code signing is disabled for these local builds.

Swift 6.4 is the compiler requirement; `SWIFT_VERSION: 6.0` selects Swift 6
language mode. Release builds use `-O3 -mcpu=apple-m1` for the CPU verifier, keeping
its instruction baseline compatible with the first Apple Silicon generation.
Debug, Profile and historical research builds retain `-mcpu=native`. Runtime
validation has been performed on Apple M4; other chips still need device testing.

## Signed releases

```sh
tools/package-release.zsh notarized YYYY-MM-DD
```

This builds a fresh Release executable, strips local/debug symbols, signs it with
a Developer ID Application identity, enables Hardened Runtime, and obtains a
secure timestamp. The ZIP contains one root executable named `verusmetal`, with
its Metal library embedded. The script validates architecture, dependencies,
signature and independent CPU/GPU vectors, runs an isolated benchmark, and submits
the ZIP to Apple's notary service. It requires `Accepted` and a Gatekeeper ticket
assessment before producing the final archive under `Distribution/`.

Use `VERUSMETAL_DEVELOPER_ID_APPLICATION` to select an installed signing identity
when more than one exists. `VERUSMETAL_NOTARY_PROFILE` selects an existing Keychain
profile; its default name is `verusmetal-notary`. Credentials are never stored in
the repository. A raw CLI cannot be stapled like an app bundle; Gatekeeper may
describe the ticket-validated executable as valid code that is not an app.

The script also preserves the notary response/log, writes a ZIP checksum, and
refreshes the ignored `Distribution/verusmetal` executable. It refuses to overwrite
an existing versioned ZIP. `ad-hoc` mode is available for local packaging tests;
those archives are not notarized releases. Publication is a separate step and
must include access to the corresponding source and license.

## Verification

Run these sequentially; the Xcode targets share a derived-data directory:

```sh
make test-miner
make integration-miner
make sanitize-v22
```

The unit suite covers 148 independent digests, partial GPU groups, target
boundaries, nonce bounds, solution normalization, stale jobs and lifecycle
handling. The integration target first tests the built CLI's help, strict parsing,
batch alias and JSON rate accounting. The pool test starts a local TCP server, checks CPU-verified
submissions, changes jobs, disconnects, reconnects and probes the loopback API.
To exercise terminal refreshes and width handling after the integration build:

```sh
python3 tests/test_pool_integration.py --terminal-width 120
python3 tests/test_pool_integration.py --terminal-width 60
```

These use a pseudo-terminal, assert in-place status updates and a final newline,
and verify that accepted shares remain in JSONL without separate terminal messages.
The default integration invocation also checks plain redirected output. Telemetry
checks cover snapshots independent of the terminal interval, a target change while
a share is pending, monotonic response timing and preservation of share context.
Unit tests cover idle intervals, partial-window dispatch accounting and appending
schema-v2 events to an existing schema-v1 log. See [telemetry](TELEMETRY.md).

Its CPU oracle shares our hash core; independent fixture digests provide separate
algorithm evidence. Test fixtures contain a synthetic address.

After modifying the hash core, preserve the independent-vector checks and run
appropriate [research checks](research/README.md). For documentation-only
changes, validate links and command paths; new hashing experiments are unnecessary.

## Local state and evidence

Keep wallets in `Config/local.json` or `Config/*.local.json`. Supply pool passwords
through `--password VALUE` or `VERUSMETAL_POOL_PASSWORD`; the default is `x`.
The environment option avoids putting a password in command arguments. Public
examples contain placeholders only.
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
