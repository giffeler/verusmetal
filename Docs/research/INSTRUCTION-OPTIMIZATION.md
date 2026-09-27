# VerusHash v2.2 instruction optimization

2026-09-27. **Adopted:** the combined GPU backend in `src/v22/platform.h`.
One complete, fresh-key hash still runs per thread. The core algorithm, digests,
device workspace and CPU backend are unchanged. The rebuilt CPU object is
byte-identical to the frozen baseline.

## Changes

- **Pre-rotated AES tables:** derive three additional tables locally from T0.
  Four table loads replace loads followed by runtime rotations. Lookup storage
  grows from 1 KiB to 4 KiB; no extra key state is retained.
- **Polynomial partial products:** split the two 64-bit operands into halves,
  compute four independent carry-less 32-bit products and combine them with XOR.
  The loop has 32 iterations instead of 64. Independent accumulators expose work
  to the GPU scheduler and shorten the loop-carried chains. This describes the
  source data flow; machine critical-path cycles were not measured.

Both changes were written locally. No third-party implementation was reused.

## Controlled comparisons

Apple M4, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4, Metal 4.0 / -O3.
4,096 hashes, 128 threads/group and compilation limit 128. Each run uses five
interleaved A/B pairs after equal alternating warm-up of at least 0.75 seconds.
The confirmation also reverses which variant starts. Thermal state was nominal
for every sample; Low Power Mode was off. Xcode replay was stopped before timing.

Values are median MH/s. Each candidate has its own paired baseline.

| Variant / input bytes | Baseline GPU / E2E | Candidate GPU / E2E | E2E gain |
| --- | ---: | ---: | ---: |
| AES tables / 64 | 0.6581 / 0.6320 | 0.7228 / 0.6819 | 7.9% |
| Partial products / 64 | 0.6547 / 0.6249 | 0.8502 / 0.8059 | 29.0% |
| Combined / 64 | 0.6644 / 0.6382 | 0.9248 / 0.8746 | 37.0% |
| Combined confirmation / 64 | 0.6733 / 0.6413 | 0.8578 / 0.8153 | 27.1% |
| Combined / 1,487 | 0.5890 / 0.5650 | 0.7973 / 0.7526 | 33.2% |

The combined candidate's sample ranges do not overlap its baseline's ranges in
any of these three comparisons. E2E includes command creation, encoding,
dispatch and waiting. Both paths include the complete hash and exclude setup,
allocation, compilation and verification. These short sessions are not sustained
performance or mining-rate measurements.

Later identical-source controls found an argument/engine-position effect of
roughly 4–6% in this study driver; see [PARALLELISM.md](PARALLELISM.md). The earlier
combined-kernel gain remains positive in both argument orders and substantially
larger than that control effect, but the exact percentages should not be treated
as measurements free of systematic bias. Raw historical runs are unchanged.

## Xcode evidence

One Serial / Medium replay; every row has exactly 4,096 kernel invocations.
Register labels below reproduce Xcode's distinct displays.

| Variant | Temporary Registers | Allocated / High Register | Spilled Bytes | Kernel Occupancy | Static ALU | Executed ALU, batch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 96 | 192 / 192 | 32 | 9.14% | 2,642 | 5,683,897,376 |
| AES tables | 96 | 192 / 192 | 32 | 9.15% | 2,402 | 5,316,532,176 |
| Partial products | 96 | 192 / 192 | 32 | 9.45% | 2,811 | 4,300,758,304 |
| Combined | 96 | 192 / 192 | 32 | 9.39% | 2,571 | 3,964,590,016 |

The combination executes **30.25% fewer ALU instructions** with unchanged
register/spill counts. Static code size alone would miss much of this gain:
the partial-product variant has more static ALU instructions but executes fewer
loop iterations. Occupancy changes only slightly; the gain does not require a
large occupancy improvement. Profiling replay durations are not throughput data.

## Verification and limits

All three variants pass 148 independent reference vectors, partial groups,
workspace reuse, guards, 512 directed mix cases and Metal shader validation.
Another 8,192 product/AES cases compare against ARM PMULL/AES, including all
4,096 single-bit operand pairs, zero, full-width extrema and deterministic random
inputs. The promoted default passes its reference/Metal validation suite; the CPU
passes ASan/UBSan. Its GPU backend exactly matches the validated combination.

Later default CPU/GPU smoke runs produced CPU / GPU / E2E medians of
0.2223 / 0.7922 / 0.5704 MH/s (64 bytes) and
0.1888 / 0.6890 / 0.5010 MH/s (1,487 bytes), with substantial E2E scatter.
These runs alternate CPU/GPU, occurred later and lack a paired original GPU
baseline; they are preserved separately and do not establish the speedup.

## Reproduce

```sh
make test-instructions-v22
./build/v22/register-study/study bench 64 baseline i12_combined
./build/v22/register-study/study bench 64 i12_combined baseline
./build/v22/register-study/study bench 1487 baseline i12_combined
make validate-v22 sanitize-v22
```

The original source remains in `experiments/v22-register-pressure/baseline`.
Transformations are in `tools/v22_instruction_variants.py`. Raw runs and variant
manifests remain under `build/v22/register-study`; the consolidated result and
Xcode screenshots are in `build/v22/instruction-study`. The two previously
pending register-study profiles were also completed in this capture; see
[REGISTER-PRESSURE.md](REGISTER-PRESSURE.md).
