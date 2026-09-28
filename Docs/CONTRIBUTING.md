# Contributing

VerusMetal is a development miner for Apple Silicon. Read the
[build and validation guide](DEVELOPMENT.md) before changing the implementation.

## Changes

Keep changes focused and explain the behavior they correct or add. Write
documentation and explanatory comments in English. Preserve licenses, source
attribution and the independent known-answer fixtures. `src/v22` is the canonical
hash implementation; do not create a separate miner copy.

For CLI or miner changes, run these sequentially from the repository root:

```sh
make miner
make test-miner
make integration-miner
```

For hash-core changes, also run `make sanitize-v22` and the relevant checks in
the [research index](research/README.md). Report the device, toolchain and checks
performed. Separate synthetic local-pool validation from live-pool acceptance.
Performance changes need repeated controlled measurements, not share counts alone.

Do not include generated Xcode projects, binaries, local configuration, new mining
logs or GPU traces in a routine source change. Existing committed raw evidence
must remain unchanged. Do not disable TLS certificate validation or add automatic
plaintext fallback.

## Bug reports

Include the CLI version, source revision when available, macOS/Xcode versions,
Mac chip, command and a small relevant diagnostic excerpt. Replace wallet
addresses, worker identifiers, passwords, private hostnames and local paths with
placeholders. Never attach private keys, seed phrases, complete local configuration
or unreviewed logs. Include expected behavior, observed behavior and steps to
reproduce; say whether a local test or a real pool was involved.

For performance reports, include the batch size, power mode, thermal state and
measurement method. GPU time, command wall time and complete-session throughput
measure different boundaries. Historical results do not establish performance on
other machines.
