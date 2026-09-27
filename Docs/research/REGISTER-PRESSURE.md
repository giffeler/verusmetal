# VerusHash v2.2 register-pressure experiments

2026-09-27. **Historical decision: no register-only variant adopted.** Fourteen isolated GPU variants were implemented. None establishes the required reproducible net-hashrate gain. The experimental sources, frozen CPU reference, paired driver and checks remain available. The subsequent default-kernel improvement is documented in [INSTRUCTION-OPTIMIZATION.md](INSTRUCTION-OPTIMIZATION.md).

## Controlled conditions

Apple M4; macOS 27; Xcode 27.0 (27A266a), Swift 6.4, Metal 4.0 / -O3. Every thread computes one complete v2.2 hash with fresh key generation. Each timing batch has 4,096 hashes, 128 threads/group and a pipeline compilation limit of 128. Shared buffers and inputs are identical. No algorithm, digest, CPU reference, memory size or pool behavior was changed.

Five interleaved A/B pairs follow equal alternating warm-up (at least 0.75 seconds total); pair order reverses. GPU command-buffer timestamps and wall time including create/encode/dispatch/wait are recorded separately. Allocation, compilation, input generation and digest checks are outside timing. Xcode replay is stopped before timing; its Serial/Medium durations are never used as runtime rates.

All 15 kernels including the baseline pass 148 independent reference vectors, partial threadgroups, dirty workspace reuse, guard checks and Metal shader validation. Each also passes 512 directed full-mix comparisons against the frozen CPU core, including all selector operations, equal/different key indices, lanes, loop endpoints and selector signs. GPU rounded-product tests load signed extrema from device memory to prevent constant folding. The unchanged CPU passes ASan/UBSan. The frozen rebuilt CPU object matches the original SHA-256.

## Resource measurements

These preserve Xcode metric labels: Temporary Registers and Allocated Registers / High Register are distinct displays, not interchangeable units. All read counter rows report exactly 4,096 kernel invocations.

| Variant | Temporary | Allocated / High | Spill bytes | Occupancy |
| --- | ---: | ---: | ---: | ---: |
| baseline (first) | 96 | 192 / 192 | 32 | 9.18% |
| e1_finish (first) | 96 | 192 / 192 | 32 | 9.16% |
| e1_parity (first) | 96 | 192 / 192 | 32 | 9.07% |
| e1_selector (first) | 96 | 192 / 192 | 32 | 9.13% |
| e2_late (first) | 96 | 192 / 192 | 32 | 9.09% |
| e2_split (first) | 96 | 192 / 192 | 32 | 9.15% |
| e3_halves (first) | 96 | 192 / 192 | 32 | 9.15% |
| e4_reload (first) | 96 | 192 / 192 | 32 | 9.13% |
| baseline (followup) | 96 | 192 / 192 | 32 | 9.14% |
| e2_aes_key (followup) | 96 | 192 / 192 | 48 | 9.09% |
| e5_product (followup) | 96 | 192 / 192 | 32 | 9.03% |
| e5_rounds (followup) | 96 | 192 / 192 | 32 | 9.20% |
| e5_aes (followup) | 60 | 119 / 119 | 0 | 10.03% |
| e1_dispatch (followup) | 96 | 192 / 192 | 32 | 9.12% |
| baseline (final) | 96 | 192 / 192 | 32 | 9.14% |
| e5_aes2 (final) | 61 | 122 / 122 | 0 | 9.69% |
| e4_snapshot (final) | 96 | 192 / 192 | 16 | 9.18% |

## Runtime screening

Values below are GPU / end-to-end MH/s medians, with each candidate next to its own interleaved baseline. Small differences are not accepted as gains. Later runs have large wall-time scatter despite nominal thermal state and Low Power Mode off. Raw samples and min/max/MAD are in the JSON result.

| Variant | Experiment | Baseline GPU / E2E | Candidate GPU / E2E |
| --- | --- | ---: | ---: |
| e1_finish | Load final a/b after tail patching | 0.6500 / 0.6190 | 0.6713 / 0.6321 |
| e1_parity | Keep one dividend parity bit | 0.6527 / 0.6189 | 0.6619 / 0.6361 |
| e1_selector | Decode selector from 32-bit words | 0.6441 / 0.6209 | 0.6562 / 0.6303 |
| e2_late | Reconstruct branch-selected messages at use | 0.6516 / 0.6175 | 0.6628 / 0.6386 |
| e2_split | Separate selector cases 5 and 6 | 0.6422 / 0.6108 | 0.6518 / 0.6276 |
| e3_halves | Pack low half-products before computing high halves | 0.6468 / 0.6056 | 0.6668 / 0.6368 |
| e4_reload | Reload Haraka-256 feed-forward from device memory | 0.6456 / 0.6206 | 0.6574 / 0.6139 |
| e2_aes_key | Load AES key after the table expression | 0.5941 / 0.4346 | 0.6019 / 0.4949 |
| e5_product | Disable polynomial-product loop unrolling | 0.5934 / 0.4838 | 0.5987 / 0.5282 |
| e5_rounds | Disable five-round Haraka loop unrolling | 0.5751 / 0.3545 | 0.6185 / 0.4415 |
| e5_aes | Disable four-column AES loop unrolling | 0.6212 / 0.5125 | 0.5180 / 0.4253 |
| e1_dispatch | Reload input length after mix; form output address late | 0.5717 / 0.4823 | 0.6023 / 0.4973 |
| e4_snapshot | Snapshot Haraka-512 feed-forward in dead workspace slots | 0.5783 / 0.4459 | 0.6021 / 0.3894 |
| e5_aes2 | Unroll AES columns by two | 0.6026 / 0.4172 | 0.5562 / 0.4204 |

Confirmation runs are included in the JSON for the initially promising late-message/half-product variants and the AES loop variants. They do not establish an adoption-quality end-to-end improvement. The no-unroll AES variant also has a 1,487-byte comparison.

## Findings and stop decision

- Scope-only final loads, the parity bit, and sequential half-products leave the reported allocation and static instruction counts unchanged. This is evidence of no resource improvement, not proof of byte-identical machine code.
- Branch-local message reconstruction adds static loads (382 to 417) and ALU instructions (2,642 to 2,827) without reducing spills. Splitting cases 5/6 and decoding the selector also leave allocation unchanged.
- Haraka-256 feed reload adds two static device-load instructions (382 to 384), but does not remove the kernel peak. These are static instructions, not DRAM traffic measurements.
- Moving the AES key expression later makes spilling worse: 48 instead of 32 bytes. Source load order is not a guarantee about machine scheduling.
- Disabling AES column unrolling reduces Temporary Registers from 96 to 60 and spills from 32 to zero. Occupancy rises from 9.14% to 10.03% in its matched replay, while dynamic ALU instructions rise from 5,679,804,896 to 8,277,166,416 (about 45.7%). Runtime GPU throughput decreases. Lower register use alone is therefore an insufficient selection criterion.
- The explicit 32-byte Haraka-512 snapshot reuses workspace slots 552/553: these are unused during absorption and dead after mix; keyed finalization reads key slots only through 550. It introduces two vector stores and two requested reloads per Haraka-512 call, without enlarging scratch. The final replay reports 16 spill bytes and 9.18% occupancy, but no reproducible net-rate gain was established.
- AES unrolling by two reports 61 Temporary Registers, zero spills and 9.69% occupancy in the final replay. Executed ALU instructions still increase to 6,488,627,840 from its matched baseline of 5,683,897,376.
- No register-only combination was promoted. The acceptance gate requires correctness, reproducible >=3% median E2E improvement beyond scatter, and no material long-input regression. Lower-resource but slower kernels remain experiments.
- Narrower metadata, threadgroup snapshots and dispatch/compile-limit tuning remain deferred. Current evidence does not justify a broad sweep, a forced volatile reload, or more invasive memory changes. No fixed 96-register hardware boundary is inferred.

## Reproduce

```sh
make test-register-v22
./build/v22/register-study/study bench 64 baseline e5_aes
./build/v22/register-study/study bench 1487 baseline e5_aes
MTL_CAPTURE_ENABLED=1 ./build/v22/register-study/study capture 64 baseline e5_aes
make sanitize-v22
```

Open a capture in Xcode, disable automatic profiling, replay, then select Performance / Serial / Medium / Profile. Inspect Shaders, Compute Kernel counters and Timeline / Pipeline State compiler statistics. Stop GPU workload before any runtime timing.

Frozen source: `experiments/v22-register-pressure/baseline`. Variant transformations: `tools/v22_register_variants.py`. Results, raw timings, manifests, validation logs, captures and Xcode screenshots: `build/v22/register-study`. `python3 tools/v22_register_report.py` regenerates this summary without rerunning benchmarks.
