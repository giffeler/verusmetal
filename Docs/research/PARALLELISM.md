# Independent work inside VerusHash v2.2

2026-09-27. **Decision: retain the current instruction-optimized default.**
Three additional variants were implemented and validated. None demonstrates a
reproducible throughput gain. One complete hash still runs per GPU thread;
independent hashes already occupy separate threads.

## Dependency audit

| Work | Actual dependency | Opportunity |
| --- | --- | --- |
| Input absorption | Each 32-byte block uses the previous Haraka result. | The two new input vectors can be loaded independently, but blocks cannot be hashed independently. |
| 276 key-expansion steps | Each Haraka-256 output seeds the next step. | Two AES states within a round are independent until interleaving. Previous-output stores need not determine the next AES result; the compiler already sees this. |
| Haraka-256/512 rounds | Each state depends on its previous AES round; permutation connects states. | Two/four states and their four columns are independent within a round. Tested explicit two-state interleaving. |
| 32 outer mix steps | The accumulator selects the next operation and key indices; key mutations persist. | Do not reorder steps or stores. Equal key indices are legal and make store order significant. |
| Mix cases 1 and 3 | Each of two `cross(...)` products depends only on its operands; only their XOR is needed. | Tested lockstep product loops and immediate XOR accumulation. |
| Mix case 5 inner contributions | Selector-derived addresses and branches are known before the loop; no key stores occur inside it. | Contributions can in principle be computed independently and XOR-reduced. Not widened here: several AES/product states and divergent paths would be live together. |
| Mix case 6 | Some operands are independent, but rounded products consume the evolving accumulator. | Individual remainder/product preparation can overlap; the accumulator updates cannot generally be reordered. |
| Padding, byte packing, final feed-forward | Separate output words are independent; padding needs the absorbed state or final mix result. | Small independent expressions already visible to the compiler; no new array or threadgroup staging introduced. |

Sequential source statements do not establish strict machine-level serialization.
The existing AES calls are inline; the compiler can schedule independent work.
The product experiments specifically expose two loops as one loop. No machine
critical-path or instruction-issue trace was measured in this phase.

## Implemented experiments

- `i3_aes_pair`: alternate columns of two AES states before the next round,
  in Haraka-256, Haraka-512 and keyed pairs. Both input states remain intact until
  all output columns are computed. Slower in both argument orders.
- `i3_cross_pair`: process two independent carry-less products in one 32-step
  loop, then XOR their results. Key loads, accumulator consumers and stores keep
  their original order. This exposes overlap but carries more intermediate state.
- `i3_cross_fold`: accumulate the two products directly into their required XOR
  sum, using four rather than eight 64-bit accumulators in that helper's source.
  This is a source-state count, not a hardware-register measurement.

All variants build from the frozen original plus the already adopted AES-table
and 32-bit-product transformations. No third-party implementation is reused.

## Runtime and control result

Apple M4, Xcode 27.0 (27A266a), Metal 4.0 / -O3, Swift 6.4, macOS 27.0 (26A428).
4,096 complete fresh-key hashes, 64-byte input, 128 threads/group, equal warm-up
of at least 0.75 seconds. The baseline is `i12_combined`, not the original slower
kernel. All recorded thermal states are nominal; Low Power Mode is off.

| Candidate | Pairs per run | E2E change, baseline listed first | E2E change, candidate listed first |
| --- | ---: | ---: | ---: |
| AES pair | 5 | -7.23% | -13.82% |
| Product pair | 20 | +5.04% | -5.60% |
| Product pair, folded sum | 20 | +5.45% | -3.40% |
| Identical-source control, separate queues | 20 | +3.82% | -3.95% |
| Identical-source control, shared queue | 20 | +5.53% | -6.04% |

The 20-pair runs give both variants exactly ten dispatch-first and ten
dispatch-second positions. Nevertheless, the second argument/engine tends to
win, including with identical computation. The control changes only the kernel
name and label; core and primitive sources are identical. Sharing a command queue
does not remove the effect. Its cause remains unresolved; these results do not
identify a compiler, frequency, cache or scheduling mechanism.

Initial five-pair product screens and one 1,487-byte product-pair run also appear
positive, but the reversed controls invalidate a small intrinsic-speedup claim.
All samples, including failures to confirm, are retained. No new register, spill,
occupancy or executed-instruction counters were collected. Larger live state is
a plausible cost of explicit overlap, not a measured explanation for the slowdown.
Apple documents the general tradeoff between resource use and latency hiding in
[Finding your Metal app's GPU occupancy](https://developer.apple.com/documentation/xcode/finding-your-metal-apps-gpu-occupancy).

## Verification and reproduction

Every candidate and the identical-source control pass 148 independent reference
vectors, partial groups, dirty workspace reuse, guards and 512 directed mix
cases under Metal shader validation. Each also passes 8,192 primitive cases:
product/AES for the AES variant and control, product/cross-XOR for the two product
variants, against ARM AES/PMULL. Full-hash tests cover the new paired AES helper.
The default source files and CPU backend are unchanged.

```sh
make test-parallel-v22
VERUS_STUDY_PAIRS=20 ./build/v22/register-study/study bench 64 i12_combined i3_cross_fold
VERUS_STUDY_PAIRS=20 ./build/v22/register-study/study bench 64 i3_cross_fold i12_combined
VERUS_STUDY_PAIRS=20 ./build/v22/register-study/study bench 64 i12_combined i3_control
VERUS_STUDY_QUEUE=shared VERUS_STUDY_PAIRS=20 ./build/v22/register-study/study bench 64 i3_control i12_combined
```

Transformations: `tools/v22_parallel_variants.py`. Consolidated evidence:
`build/v22/parallel-study/results.json`. Raw measurements and validation logs:
`build/v22/register-study`. Before accepting a small gain, repeat both argument
orders and the identical-source control; more dispatch samples alone did not
remove this effect.
