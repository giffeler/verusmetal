# Repository instructions

## Documentation language

Write all documentation in English, regardless of the language used in the conversation. This includes README files, release notes, benchmark reports, agent and skill instructions, explanatory script comments, and chart titles, labels, and captions. Translate existing German documentation when encountered. Preserve the meaning, measurements, identifiers, commands, and evidence boundaries; leave original logs and raw measurement records unchanged.

Conversation replies may remain in the user's language.

## Project boundaries

Keep changes within this checkout. Preserve source attribution in
`vendor/infrastructure-provenance.json`. VerusHash primitives remain independently written.

The canonical hash implementation is `src/v22`; the miner reuses it directly.
`Sources/VerusMetalCore` contains transport, job normalization, GPU search and
telemetry. `Sources/verusmetal` owns CLI policy and mining lifecycle.

Use `make miner`, `make test-miner`, and `make integration-miner`. Keep fixtures
independent of runtime CPU/GPU agreement. Preserve benchmark evidence in place.
Pool credentials and wallet configuration belong in ignored `Config/local.json`
or `Config/*.local.json`. Public examples must contain placeholders only.
`project.yml` is authoritative; do not commit the generated Xcode project.
Documentation lives in `Docs`, with historical reports in `Docs/research`.
TLS certificate validation must remain enabled. Never silently downgrade to TCP.
