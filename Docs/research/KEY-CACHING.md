# Per-job key caching and GPU carry-less multiplication

2026-09-28. The mining path now prepares the job-constant hash state once and
searches nonces with a shared pristine key and per-thread mutation overlay.
The canonical implementation remains `src/v22`; no third-party primitive code
or diagnostic prototype scaffolding was copied. CPU/hybrid mining was declined
by the maintainer and is not implemented. No new live-pool test was run.

## Hash split and invariants

For the supported 1,487-byte mining layout, the first 46 full 32-byte blocks end
at offset 1,472. Both the extranonce prefix and nonce fit in the 15-byte tail.
`prepare(input, size, workspace)` absorbs the full blocks, builds the FillExtra
tail from the absorbed first vector, and expands all 552 key vectors. It writes
8,832 key bytes and four 16-byte seed vectors. Host preparation is outside batch
timing and occurs on job generation, input, prefix or nonce-layout changes.

`finishNonce` patches little-endian nonce bytes in the tail, executes the original
32-step mix, then performs keyed finalization using the **mutated** key. `hash`
is the reference composition of `prepare` and `finishNonce` with no nonce patch.
The existing full CPU hash is still used to verify every share candidate.

The mix is templated over workspace access; its operations and store order are
unchanged. Each step writes exactly the selected first and second indices,
both at most 511. Equal indices remain legal. Higher key reads through index 551
always see the pristine key. Finalization may read changed slots and must use
the overlay too. No scratch-key copy is required on the cached GPU path.

Each GPU thread owns sparse writes at 512 transposed device-buffer slots and a
512-bit dirty mask. A 128-thread group uses 8 KiB of mask storage. A dispatch
clears each active lane's mask before use; old device writes are never read unless
marked in the current dispatch. This also works when dispatch counts/strides
change. There are no cross-lane accesses or barriers in the production kernel;
partial groups return before touching inactive lanes' state.

The Swift CPU API `PreparedVerusHash` owns a pristine key and reusable overlay for
one serial worker. It is not Sendable. The C API specifies aligned buffer sizes
and returns the selected mode. `canCacheNonce` requires a valid nonce span entirely
in the tail. Both public hosts select complete hashing when the nonce overlaps a
full block and expose `usesCachedHash == false`; invalid spans fail explicitly.
A zero-byte nonce patch can reuse preparation for all independent fixture lengths,
including empty inputs and exact block boundaries.

## GPU primitive and compiler policy

The Metal product uses three 32-by-32 polynomial products in a Karatsuba
composition. Each product separates bit coefficients into four residue classes
using masks `0x11111111`, `0x22222222`, `0x44444444`, `0x88888888`. Sixteen integer
products are XOR-combined by residue and masked afterwards. At most eight terms
contribute to a coefficient, so three unused bits contain the integer carries;
the surviving bits are the carry-less parity. ARM AES/PMULL primitives are unchanged.

`VM_INLINE` applies `always_inline` on Metal hot-path helpers, including workspace
access, mix, Haraka and CLMUL. The build tool emits optimized AIR and rejects
remaining application-helper calls. The only calls in the checked mining AIR are
LLVM lifetime intrinsics. Compiler inlining is checked rather than assumed.

## Timing method and results

Apple M4, macOS 27.0, Xcode 27.0 (27A266a), Metal 4.0 / `-O3`. Each engine has a
separate queue and identical target/digest output policy. Groups and pipeline
thread limits are 128. All reported samples have nominal thermal state and Low
Power Mode off. Xcode replay is stopped during timings.

Each comparison has 20 paired samples, alternating the dispatch order, after at
least 0.75 seconds of equal alternating warm-up. The entire comparison is repeated
with reversed argument order. A renamed but otherwise identical cached kernel is
the control described in [PARALLELISM.md](PARALLELISM.md). GPU timestamps and wall
time including command creation, encoding, submission and waiting are separate.
Allocation, preparation, compilation and digest checks are excluded. Every output
is checked against the frozen full CPU core outside timing. The independent
fixtures supply the separate algorithm oracle.

Initial paired results (GPU / command end-to-end MH/s):

| Batch | Argument order | Previous kernel | Holes only | Cached |
| ---: | --- | ---: | ---: | ---: |
| 4,096 | baseline, holes | 1.165 / 1.079 | 1.555 / 1.408 | — |
| 4,096 | holes, baseline | 1.163 / 1.082 | 1.554 / 1.404 | — |
| 4,096 | baseline, cached | 1.164 / 1.086 | — | 2.874 / 2.415 |
| 4,096 | cached, baseline | 1.164 / 1.082 | — | 2.862 / 2.406 |
| 32,768 | baseline, holes | 1.587 / 1.567 | 1.740 / 1.710 | — |
| 32,768 | holes, baseline | 1.582 / 1.562 | 1.743 / 1.716 | — |
| 32,768 | baseline, cached | 1.586 / 1.566 | — | 3.604 / 3.497 |
| 32,768 | cached, baseline | 1.581 / 1.559 | — | 3.583 / 3.481 |

The cached path improves end-to-end throughput by about **2.22–2.23x at equal
batch size**, in both argument orders. Holes alone improves end-to-end throughput
by about 30% at 4,096 and 9–10% at 32,768. The cached/control differences remain
below 1% in both orders at both sizes. This run's smaller control effect does not
invalidate the earlier 4–6% bias; it reinforces the need for per-session controls.

A direct interleaved cached-kernel batch comparison gives 2.405 versus 3.493 MH/s
end-to-end for 4,096 versus 32,768; reversing arguments gives 2.413 versus 3.474.
That is approximately 44–45% more throughput. This supports the new **32,768**
default. Cached dispatches still allocate 8,192 sparse-write bytes per nonce:
256 MiB at the default. Including output, flags, prepared state and target, the
explicit buffer footprint is 269,624,032 bytes (257.134 MiB), excluding Metal
implementation overhead and the 8 KiB threadgroup masks per resident group.

The CLI benchmark uses the actual 1,487-byte shape with an eight-byte tail nonce.
Separate ten-second loops measured GPU / command / whole-loop rates of
2.872 / 2.383 / 2.373 MH/s at 4,096 and 3.779 / 3.663 / 3.647 MH/s at 32,768.
Its all-zero template differs from the paired driver's deterministic patterned
job; these CLI values do not replace paired speedup evidence. These are short
synthetic tests, not sustained power/thermal measurements or pool acceptance.

Pipelining was not adopted. The default cached CLI command overhead is about 3%
of command time in this run. One synchronous command preserves existing disjoint
nonce allocation, stale-job rejection and `SearchStatisticsAccumulator` semantics.

## Xcode resources

One Serial / Medium replay of the patterned 1,487-byte workload, 4,096 invocations
per row. Temporary Registers and Allocated Registers / High Register retain
Xcode's distinct labels and are not treated as interchangeable units.

| Variant | Temporary Registers | Allocated / High Register | Spilled Bytes | Kernel Occupancy | Encoder Kernel ALU Instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous kernel | 96 | 192 / 192 | 32 | 9.45% | 4,106,080,080 |
| Holes only | 96 | 192 / 192 | 384 | 10.24% | 2,563,337,680 |
| Cached | 96 | 192 / 192 | 480 | 10.86% | 1,430,129,168 |

The larger spill amounts are a measured cost; the change is accepted for its
reproducible throughput gain, not for lower register use. These values are not
DRAM traffic measurements. Encoder-level and GPU-command-level ALU counters show
different totals in Xcode; the table consistently uses encoder-level counters.
Replay durations are never substituted for runtime benchmark durations.
Raw screenshots, accessibility readings and the capture remain under
`build/v22/cache-study`; transcribed metrics are retained with the new evidence.

## Divergence experiment: not adopted

`experiments/v22-cache/binned.metal` keeps 128 contexts alive through all 32 steps
and repartitions them into threadgroup queues. A context's accumulator is 16 bytes;
its nonce and overlay slot derive from its stable context index, and all contexts
share the outer step. Messages are reconstructed from the prepared seeds and nonce.
Each SIMD group serves one queue. Cases 5 and 6 use separate bins for each of their
eight loop lengths, giving 22 bins in total; inner data-dependent branches remain.
Device/threadgroup barriers publish overlay mutations when contexts move lanes.
The prototype uses 21,592 bytes of explicit threadgroup storage.

Two ranges, consecutive dispatch reuse and counts 1, 31, 32, 33, 127, 128 and 129
match the frozen full CPU hash with Metal validation and guard checks. The
32,768-context benchmark measures 2.480 versus 3.492 MH/s end-to-end; reversed
arguments give 2.482 versus 3.503. This prototype is about **29% slower** and is
not embedded in the miner. Sparse bins, synchronization and context movement are
plausible costs; their individual contributions were not isolated. Larger queues
or cross-threadgroup scheduling need another correctness and measurement cycle.
The task's approximately 14 MH/s uniform-control-flow diagnostic is non-semantic
and is neither a measured production rate here nor an attainable-rate guarantee.

## Validation and reproduction

```sh
make miner
make test-miner
make integration-miner
make sanitize-v22
make validate-v22
make test-cache-v22
python3 tools/run_v22_cache_benchmarks.py
```

- 148 independent vectors: full and split CPU/GPU paths.
- Prefixes 1–14 and PBaaS versions 7/8: random nonces, two ranges, two passes,
  partial groups, changed dispatch strides, same-generation prefix/input changes.
- Overlapping full blocks: explicit cached/full mode checks and digest comparison,
  including transitions between cached and fallback paths.
- CPU sanitizers: 21,000 cached nonce comparisons plus independent fixtures and
  invalid/fallback bounds.
- Metal validation: 8,192 product/AES cases against frozen ARM PMULL/AES and 512
  directed mix cases, comparing all 556 vectors, reduced result, signed rounded
  product extrema, guard bytes and overlay reset across two passes.
- Local CLI/pool integration: CPU-verified submissions, replacement jobs, reconnect,
  status API and telemetry accounting. No external pool or credentials required.

The new evidence is in `experiments/v22-cache/evidence`; the baseline source is
frozen alongside it. Initial timing files are under `run-20260928-200722`, with
batch and queue follow-ups under `followup-20260928-201657`. Subsequent reproduction
runs use unique directories under `build/v22/cache-study` and never overwrite
historical measurements. The report leaves all earlier research files unchanged.


A final confirmation using the complete reproduction script is retained under
`run-866ca42b-2494-4166-b2fb-acf6a5096eb0`. It fingerprints the final host source,
CPU oracle, Metal libraries and Release CLI, and records medians, ranges and MAD.
At 32,768, the cached / baseline end-to-end medians are 3.486 / 1.570 MH/s and
3.480 / 1.560 MH/s with reversed arguments, confirming 2.22–2.23x. Identical-source
controls remain below 1%; the queue prototype remains approximately 29% slower.
The final confirmation checks both nonce ranges twice before each timed run.
All 640 paired dispatch samples are nominal thermal state with Low Power Mode off.
