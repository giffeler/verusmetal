# Miner validation

Local platform: Apple M4, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4.

- Independent corpus: 148 known-answer digests through the CPU backend and the
  new embedded Metal search kernel, with shader validation enabled.
- GPU checks: partial groups through 129 threads, buffer reuse, full 64-bit nonce
  values, nonce-space bounds, little-endian digest comparison and target equality.
- Protocol checks: solution version/length validation, PBaaS canonical hash view,
  original solution preservation for submission, subscription parsing, malformed
  inputs, address checksum and endpoint parsing.
- Lifecycle checks: stale-work rejection, CPU/GPU candidate mismatch rejection,
  cancellation of scheduled reconnects, nonce exhaustion and strict CLI parsing.
- Local integration: two CPU-verified accepted test shares across a disconnect,
  with new subscription prefix, job replacement, PBaaS and legacy solution jobs.
  These are synthetic local accepts, not real-pool acceptance.

The first implementation supports block version 0x00010004, a 1,344-byte solution,
solution versions 4–8 and the nine-field Equihash-style notify layout. Unsupported
layouts fail closed. PBaaS jobs require reserved chain commitments and at least
15 bytes of free solution space. Latest-job policy discards previous work even
when `clean_jobs` is false. No shared-prefix/key caching is implemented yet.

## Live plaintext pool validation

On 2026-09-27, the explicitly selected `stratum+tcp://eu.luckpool.net:3956`
endpoint authorized worker `m4`, delivered jobs and job changes, and accepted
two GPU-found, CPU-verified shares. The test stopped automatically after the
second acknowledgement.

- Duration: approximately 115 seconds, 07:55:06–07:57:01 UTC.
- Nonces searched: 118,665,216.
- Submitted / accepted / rejected / unresolved: 2 / 2 / 0 / 0.
- Effective throughput, including session overhead: 1.038 MH/s.
- Locally discarded stale candidates: 0.
- Session ID: `0C277DC0-B112-4AA0-8BE4-DE2959FC6BBD`.

This confirms real-pool share acceptance for the observed workload. It does not
establish long-term stability or sustained throughput. Reconnection remains
covered by the local integration test, not this uninterrupted successful run.

The first live attempts exposed two decoder assumptions: solution version 8
was rejected, and the PBaaS extra-payload length was treated as free space.
Both were corrected without changing the hash primitives. Regression coverage
now includes version-8 GPU/CPU agreement, padded payloads, rejection of unknown
versions, and rejection of payloads overlapping the nonce tail. All 12 XCTest
tests pass, including the existing 148 independent reference vectors and Metal
validation. The local integration test also passes with a version-8 job.
See [protocol references](PROTOCOL.md).

The additional ignored configuration is `Config/luckpool-tcp.local.json`.
`Config/local.json` retains the separately selected TLS endpoint. No fallback
or TLS verification bypass was introduced.

Raw records retained locally (not included in a fresh checkout):

- `build/setup/luckpool-tcp-ready-events.jsonl`
- `build/setup/luckpool-tcp-ready-live.log`
- `build/setup/tests-tcp.log`
- `build/setup/integration-tcp.log`
- `build/setup/luckpool-tcp-validation.json`

The successful session is also preserved unchanged in Git:
[events](../experiments/mining/2026-09-27-luckpool/events.jsonl),
[terminal log](../experiments/mining/2026-09-27-luckpool/run.log), and
[summary with source/binary fingerprints](../experiments/mining/2026-09-27-luckpool/summary.json).
These are historical records; their fingerprints describe the tested build.
Local configuration files are not distributed. Use the public configuration
examples described in the [README](../README.md).

## Earlier TLS limitation

On 2026-09-27, `eu.luckpool.net:3958` returned a certificate valid from 2022-10-20
to 2023-01-18. The bounded CLI test failed in Network.framework with error -9814,
`chain had an expired cert`; it completed zero hashes and submitted no shares.
`verus.farm:9998` had also returned an expired certificate (2021-07-29).
`pool.verus.farm` did not resolve. TLS verification remains enabled.

Earlier records and the original implementation validation are retained in
`build/setup/validation.json`; they describe the state before the TCP test.
