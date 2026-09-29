# Historical hashing research

Local Apple Silicon hashing benchmarks. The new **VerusHash v2.2** implementation
is in `src/v22`; it contains independently written CPU/Metal code and a Swift 6.4
host. Each GPU thread computes a complete hash. These benchmark programs have no pool or network functionality; the current
CLI miner is documented in the [project README](../../README.md).

```sh
make run-v22       # Full hash, fresh key per input; one CPU thread vs GPU
make test-v22      # Independent reference vectors and boundary checks
make validate-v22 # Metal shader validation; no benchmark timings
make capture-v22  # Xcode GPU capture
```

Requires Xcode 27, Swift 6.4 and macOS 27. See [V22.md](V22.md) for the short implementation
and measurement notes. The original Haraka screening below remains available;
its third-party CPU reference is not linked into the new benchmark.

Register-pressure experiments are isolated from the default kernel. Build them
with `make register-study-v22` and validate them with `make test-register-v22`.
See [REGISTER-PRESSURE.md](REGISTER-PRESSURE.md) for measurements and the acceptance decision.

The default v2.2 GPU backend now uses pre-rotated AES tables and four independent
32-bit polynomial partial products. Controlled comparisons show 27–37% higher
end-to-end throughput for 64-byte inputs, with unchanged register/spill counts.
See [INSTRUCTION-OPTIMIZATION.md](INSTRUCTION-OPTIMIZATION.md); reproduce its checks with
`make test-instructions-v22`.

Further within-thread parallelism experiments and an identical-source timing
control are documented in [PARALLELISM.md](PARALLELISM.md) (`make test-parallel-v22`). None of
these later variants replaces the current default.

## Cached mining and sustained pool operation

[KEY-CACHING.md](KEY-CACHING.md) records the independently written holes CLMUL,
per-job preparation and cached GPU path, with approximately 2.23x higher command
throughput at equal batch size in controlled paired tests.
[LONG-RUN-2026-09-29.md](LONG-RUN-2026-09-29.md) adds a maintainer-recorded eight-hour
M4 pool run at 3.415 MH/s effective, 1,376 accepted shares and a successful reconnect.
These mining results use the 1,487-byte layout; the earlier benchmark workloads
and historical results above retain their original scope.

## Historical Haraka architecture screening

The original workload is **Haraka-512/256 v2**, not full VerusHash.

```sh
make run
make capture  # Optional: save one dispatch as an Xcode GPU trace.
```

Requires Apple Silicon, Xcode and its Metal compiler. No additional packages.

For the controlled state-pressure experiment, use `make sweep` and
`make capture-sweep`. See [PRESSURE.md](PRESSURE.md) for the current results, conditions and
limitations. The original single-kernel run below is preserved as historical data.

One CPU thread uses ARM AES instructions and processes one hash at a time. Each
GPU thread computes one complete hash; independent hashes fill SIMD groups of
32 lanes on the tested M4. One command queue, one dispatch at a time, no overlapping
CPU/GPU work. The fixed threadgroup size and pipeline compilation limit are 128.

The GPU uses four `uint4` state values, eight feed-forward words and a 1-KiB AES
T-table with rotations. These source-level quantities are **not hardware register
counts**. The compiler can reschedule, allocate and spill temporaries.

The program checks the official known-answer vector, compares every digest in a
262,144-input batch, and checks output guards for partial threadgroups. At least
0.5 seconds of warm-up and five alternating-order timing samples follow. GPU execution uses Metal command
buffer timestamps; GPU wall time includes encoding, submission and waiting. Both
paths exclude setup, allocation and input generation. Results measure batch
throughput, not single-hash latency. CPU QoS is user-initiated; no core is pinned.

M4 run after the warm-up adjustment (2026-09-26, macOS 27.0 build 26A428; raw samples in
`build/screening.txt`):

| Path | Median throughput | Relative to one CPU thread |
| --- | ---: | ---: |
| CPU, ARM AES | 141.105 MH/s | 1.000x |
| GPU execution | 184.706 MH/s | 1.309x |
| GPU including encode/submit/wait | 69.141 MH/s | 0.490x |

GPU execution beat one CPU thread; the complete GPU call was slower. GPU execution
samples ranged from 1.013 to 1.780 ms and GPU wall times from 1.245 to 4.258 ms.
This is a short, variable screening result, not a steady-state hardware limit.
The earlier two-pair warm-up run is preserved in `build/screening-initial.txt`;
its GPU execution ratio was 0.860x, illustrating sensitivity to run conditions.

One separate Xcode replay of the unchanged kernel reported **90 Temporary Registers**,
**180 Allocated Registers / High Register** in the shader table, **0 Spilled Bytes**,
and **25.77% Kernel Occupancy**. These are the exact Xcode metric labels; the two
register displays are not treated as interchangeable units. Screenshots and raw
accessibility readings are saved in `build/`. This supports investigating register
pressure but does not prove that it caused the low occupancy. Full VerusHash's
additional live state and memory accesses are absent here.

`make capture` embeds shader sources and saves a `.gputrace` under `build/`.
Open it in Xcode, Replay with Profile after replay, then inspect Performance and
the compute shader's compiler statistics for occupancy and spills. The CLI's
pipeline thread limit is not an occupancy measurement.

CPU function/constants and the known-answer vector are adapted from
[kste/haraka](https://github.com/kste/haraka/tree/74d7f4e0a2c74f844939e1654b2f6741a437c507)
(MIT; notice in [vendor/HARAKA-LICENSE](../../vendor/HARAKA-LICENSE)). GPU round constants follow the same
reference; the table kernel is implemented locally. The CPU object contains 40
`aese` and 40 `aesmc` instructions in its single-hash loop.

All commands and source paths in these reports are relative to the repository
root. Historical files under `build/` are local evidence and are not distributed
in Git. The frozen baseline and Xcode metric JSON under `experiments/` are kept
in the repository; new benchmark runs produce their own measurements.
