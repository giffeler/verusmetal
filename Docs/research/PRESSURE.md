# Haraka state-pressure screening — 2026-09-26

The unchanged kernel is close to a **compiler allocation/spill transition in this
configuration**, not a proven universal hardware limit. The first tested spilling
variant has 128 extra bytes of source state: 96 Temporary Registers, 80 Spilled Bytes,
and 19.68% Kernel Occupancy. At 256 extra bytes, spills reach 272 bytes and kernel
throughput falls 48.7% below the baseline. Full VerusHash is not implemented.

| Variant | Extra state | Temporary registers | Allocated registers | Spill bytes | Occupancy | Kernel MH/s | End-to-end MH/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Original | 0 B | 90 | 180 | 0 | 26.27% | 259.634 | 202.262 |
| Control: 1 uint4 | 16 B | 94 | 188 | 0 | 26.06% | 250.038 | 194.945 |
| 4 uint4 | 64 B | 92 | 184 | 0 | 25.89% | 190.867 | 156.863 |
| 8 uint4 | 128 B | 96 | 192 | 80 | 19.68% | 190.002 | 154.593 |
| 16 uint4 | 256 B | 96 | 192 | 272 | 17.22% | 133.124 | 115.669 |

CPU baseline: **162.159 MH/s**, one thread with ARM AES. Original GPU/CPU throughput
is 1.601x for GPU execution and 1.247x including command creation, encoding,
submission and waiting. CPU and original GPU process identical 64-byte inputs and
32-byte digests. The synthetic GPU rows include extra work; their ratios against
the CPU would not compare identical algorithms.

All GPU threads compute an entire Haraka-512/256 v2 hash. Unused arrays would be
eliminated. The variants therefore keep an observable `uint4 state[N]`, update it
using intermediate Haraka state, and write a separate 16-byte checksum. Hash
results remain unchanged. All four variants perform 16 vector updates per Haraka
round (80 total) and write the same output size. No volatile storage or barriers
force the compiler to use memory. The CPU checks every auxiliary checksum using an
untimed independent ARM-AES oracle, as well as all hashes and output guards.

The experiment holds source-level update count constant, but it is not a pure
register-only perturbation: dependency depth, initialization, final reduction and
compiler scheduling change. Xcode reports 642/666/698/762 ALU instructions for the
four variants, versus 382 for the baseline. Register allocation is non-monotonic
(94 then 92), and caps at 96 while spills increase. This is measured compiler
behavior, not an assumed register reservation from array size.

The 64-byte variant slows down without spills or an occupancy collapse. The
128-byte variant has almost the same throughput despite its first spills. Thus
the data supports limited state headroom, but does not attribute every slowdown
to occupancy or establish a universal "96 registers is the cliff" rule. Within
this synthetic family, first spilling is bracketed between 64 and 128 added bytes.

Conditions: Apple M4, macOS 27.0 (26A428), Xcode 27.0, `-O3`, CPU `-mcpu=native`;
AC power, low-power mode off, nominal thermal state throughout timing. Fixed
262,144-input batch, 128 threads/group and pipeline compilation limit 128, SIMD
width 32, shared buffers, one queue, no overlapping CPU/GPU runs. At least one
second of warm-up (95 suites), then ten samples per variant with rotating order;
CPU runs alternate before/after each suite. Reported rates use median duration.
Allocation, compilation, input generation and correctness checks are excluded.
Kernel timing uses the GPU timestamps of a single-dispatch command buffer; it
does not subtract GPU encoder overhead or measure individual instruction latency.

Register/spill values and occupancy come from a separate Xcode replay, Full
profiler, Serial execution, Medium performance state. All five serial counters
report exactly 262,144 kernel invocations. An initial Overlapping replay had an
incorrect state4 invocation count; its raw readings are preserved but are not
used in the table. Profiler durations are not mixed with normal-run throughput.
The baseline's 26.27% occupancy is close to the earlier 25.77%, not identical.
The two register columns preserve Xcode's distinct metric labels. Spill bytes are
the compiler's reported amount, not total traffic over the dispatch.

Reproduce with `make sweep`; use `make capture-sweep` for a new five-dispatch trace.
Timing samples, source hashes, profiler text and screenshots are under
`build/pressure/`. `results.json` combines the accepted values; `manifest.json`
identifies the exact timing and capture directories. All validation passed.

[Apple's register-pressure guidance](https://developer.apple.com/videos/play/tech-talks/10580/)
and [occupancy guidance](https://developer.apple.com/documentation/xcode/finding-your-metal-apps-gpu-occupancy)
describe why register counts and occupancy must be interpreted together with
spills and other workload characteristics.
