# Publication review — 2026-09-28

Scope: the source checkout at base revision `9e209f5`, all three commits reachable
from its local refs, the GitHub branch/tag listing, and the changes prepared for
the first downloadable release. GitHub exposed only `main`, matching the local
base revision, with no tags, releases or Actions artifacts at review time.

## Source and history

- Reviewed 77 tracked paths and 86 distinct historical file blobs. No local
  wallet value from the two ignored configurations appeared in Git history.
- Checked for private-key headers, common service-token formats, credential
  filenames, personal absolute paths and credentials embedded in URLs. The URL
  matches were deliberate `u:p@example.com` rejection fixtures. Address literals
  were confined to the synthetic unit/integration fixtures.
- Public configuration examples contain wallet placeholders. All runtime JSON
  configuration under `Config/` is now ignored unless explicitly named as an
  example. Root mining logs, environment files, build outputs and GPU captures
  are also excluded from routine additions.
- Preserved the committed pool evidence, research measurements, independent
  fixtures, licenses and infrastructure provenance. No history rewrite was
  needed. Existing author/committer identity metadata remains in Git history.

This was a scoped source/history inspection and exact-value/pattern scan, not a
guarantee that arbitrary future additions contain no confidential information.
Review new files before staging, especially logs and configuration examples.

## User-facing changes

- Added a standalone [CLI reference](CLI.md), [contribution guide](CONTRIBUTING.md)
  and bug-report template.
- Standardized the batch option as `--batch-nonces`, retaining `--batch` as an
  alias and rejecting simultaneous use of both names.
- Added device/benchmark JSON, version output and command-specific help. Missing
  pool/wallet diagnostics identify the missing setting; failures exit with status 2.
- Added reproducible signed/notarized packaging and an Apple M1 CPU instruction
  baseline for Release builds. Hash primitives and the 4,096-nonce default remain
  unchanged.

## Validation

`make miner`, `make test-miner` and `make integration-miner` passed on Apple M4
with Xcode 27.0 and Swift 6.4. The unit suite passed 16 tests, including the 148
independent reference digests with Metal validation. CLI integration checked both
batch names, strict errors, JSON types and rate accounting. The synthetic local
pool test checked CPU-verified shares, job/target changes, reconnects, telemetry
and the loopback API. No external mining session was started for this review.

Artifact-specific signing, notarization and download verification are recorded in
the [release notes](releases/2026-09-28.md).
