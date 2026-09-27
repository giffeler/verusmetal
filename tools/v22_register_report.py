#!/usr/bin/env python3
"""Summarize existing measurements without modifying raw timing or Xcode records."""
from pathlib import Path
import hashlib
import json
import statistics

ROOT = Path(__file__).resolve().parents[1]
STUDY = ROOT / 'build/v22/register-study'
resources = json.loads((ROOT / 'experiments/v22-register-pressure/xcode-2026-09-27.json').read_text())
descriptions = {
    'e1_finish': 'Load final a/b after tail patching',
    'e1_parity': 'Keep one dividend parity bit',
    'e1_selector': 'Decode selector from 32-bit words',
    'e2_late': 'Reconstruct branch-selected messages at use',
    'e2_split': 'Separate selector cases 5 and 6',
    'e3_halves': 'Pack low half-products before computing high halves',
    'e4_reload': 'Reload Haraka-256 feed-forward from device memory',
    'e2_aes_key': 'Load AES key after the table expression',
    'e5_product': 'Disable polynomial-product loop unrolling',
    'e5_rounds': 'Disable five-round Haraka loop unrolling',
    'e5_aes': 'Disable four-column AES loop unrolling',
    'e1_dispatch': 'Reload input length after mix; form output address late',
    'e4_snapshot': 'Snapshot Haraka-512 feed-forward in dead workspace slots',
    'e5_aes2': 'Unroll AES columns by two',
}
records = []
for name in descriptions:
    for phase in ['screen', 'confirm', 'long']:
        log = STUDY / f'{name}-{phase}.log'
        if not log.exists():
            continue
        path = Path(log.read_text().split('Results: ')[1].strip())
        raw = json.loads(path.read_text())
        metrics = {}
        for variant in ['baseline', name]:
            metrics[variant] = {}
            for kind in ['gpu', 'endToEnd']:
                values = [s['mhs'] for s in raw['samples'] if s['path'] == f'{variant}/{kind}']
                med = statistics.median(values)
                metrics[variant][kind] = {'median': med, 'min': min(values), 'max': max(values),
                                          'relativeMAD': statistics.median(abs(x-med) for x in values)/med}
        records.append({'variant': name, 'phase': phase, 'inputBytes': raw['inputBytes'],
                        'rawFile': str(path.relative_to(ROOT)), 'metrics': metrics, 'raw': raw})

manifest = {}
for directory in ['src/v22', 'tools', 'experiments/v22-register-pressure', 'tests']:
    for path in sorted((ROOT / directory).rglob('*')):
        if path.is_file() and path.suffix in ['.py', '.swift', '.cpp', '.h', '.metal', '.json']:
            manifest[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
previous_result = STUDY / 'results.json'
historical_manifest = (json.loads(previous_result.read_text())['sourceSHA256']
                       if previous_result.exists() else manifest)
result = {'decision': 'No register-only candidate was adopted. Subsequent instruction optimization is documented in INSTRUCTION-OPTIMIZATION.md.',
          'resources': resources, 'measurements': records, 'sourceSHA256': manifest,
          'validation': {'independentFixturesPerVariant': 148, 'directedCasesPerVariant': 512,
                         'variantsIncludingBaseline': 15, 'metalValidation': 'passed', 'cpuASanUBSan': 'passed'},
          'toolchain': {'xcode': '27.0 (27A266a)', 'swift': '6.4 (swiftlang-6.4.0.34.1)',
                        'metal': '32023.921', 'metalLanguage': '4.0', 'optimization': '-O3'},
          'runtimeNotes': 'Later runs show substantial dispatch/wait jitter; no net-rate gain is established.'}
result['sourceSHA256'] = historical_manifest
result['summarySourceSHA256'] = manifest
result['fingerprintNotes'] = 'sourceSHA256 preserves the original report snapshot; summarySourceSHA256 records report regeneration. Per-run library fingerprints identify measured artifacts.'
(STUDY / 'results.json').write_text(json.dumps(result, indent=2)+'\n')

lines = ['# VerusHash v2.2 register-pressure experiments', '',
         '2026-09-27. **Historical decision: no register-only variant adopted.** Fourteen isolated GPU variants were implemented. '
         'None establishes the required reproducible net-hashrate gain. The experimental sources, frozen CPU reference, '
         'paired driver and checks remain available. The subsequent default-kernel improvement is documented in '
         '[INSTRUCTION-OPTIMIZATION.md](INSTRUCTION-OPTIMIZATION.md).', '',
         '## Controlled conditions', '',
         'Apple M4; macOS 27; Xcode 27.0 (27A266a), Swift 6.4, Metal 4.0 / -O3. '
         'Every thread computes one complete v2.2 hash with fresh key generation. Each timing batch has 4,096 hashes, '
         '128 threads/group and a pipeline compilation limit of 128. Shared buffers and inputs are identical. '
         'No algorithm, digest, CPU reference, memory size or pool behavior was changed.', '',
         'Five interleaved A/B pairs follow equal alternating warm-up (at least 0.75 seconds total); pair order reverses. '
         'GPU command-buffer timestamps and wall time including create/encode/dispatch/wait are recorded separately. '
         'Allocation, compilation, input generation and digest checks are outside timing. '
         'Xcode replay is stopped before timing; its Serial/Medium durations are never used as runtime rates.', '',
         'All 15 kernels including the baseline pass 148 independent reference vectors, partial threadgroups, dirty workspace '
         'reuse, guard checks and Metal shader validation. Each also passes 512 directed full-mix comparisons against '
         'the frozen CPU core, including all selector operations, equal/different key indices, lanes, loop endpoints and '
         'selector signs. GPU rounded-product tests load signed extrema from device memory to prevent constant folding. '
         'The unchanged CPU passes ASan/UBSan. The frozen rebuilt CPU object matches the original SHA-256.', '',
         '## Resource measurements', '',
         'These preserve Xcode metric labels: Temporary Registers and Allocated Registers / High Register are distinct '
         'displays, not interchangeable units. All read counter rows report exactly 4,096 kernel invocations.', '',
         '| Variant | Temporary | Allocated / High | Spill bytes | Occupancy |',
         '| --- | ---: | ---: | ---: | ---: |']
for section in ['first', 'followup', 'final']:
    for name, v in resources.get(section, {}).items():
        lines.append(f'| {name} ({section}) | {v[0]} | {v[1]} / {v[2]} | {v[3]} | {v[4]:.2f}% |')
for name in resources['unread']:
    lines.append(f'| {name} | Pending | Pending | Pending | Pending |')
if resources['unread']:
    lines += ['', resources['unreadReason'] + ' Their captures and correctness results exist; no resource saving is inferred.']
lines += ['',
          '## Runtime screening', '',
          'Values below are GPU / end-to-end MH/s medians, with each candidate next to its own interleaved baseline. '
          'Small differences are not accepted as gains. Later runs have large wall-time scatter despite nominal thermal '
          'state and Low Power Mode off. Raw samples and min/max/MAD are in the JSON result.', '',
          '| Variant | Experiment | Baseline GPU / E2E | Candidate GPU / E2E |',
          '| --- | --- | ---: | ---: |']
for name, desc in descriptions.items():
    row = next(r for r in records if r['variant'] == name and r['phase'] == 'screen')
    a, b = row['metrics']['baseline'], row['metrics'][name]
    lines.append(f"| {name} | {desc} | {a['gpu']['median']:.4f} / {a['endToEnd']['median']:.4f} | {b['gpu']['median']:.4f} / {b['endToEnd']['median']:.4f} |")
lines += ['', 'Confirmation runs are included in the JSON for the initially promising late-message/half-product variants '
          'and the AES loop variants. They do not establish an adoption-quality end-to-end improvement. '
          'The no-unroll AES variant also has a 1,487-byte comparison.', '',
          '## Findings and stop decision', '',
          '- Scope-only final loads, the parity bit, and sequential half-products leave the reported allocation and static '
          'instruction counts unchanged. This is evidence of no resource improvement, not proof of byte-identical machine code.',
          '- Branch-local message reconstruction adds static loads (382 to 417) and ALU instructions (2,642 to 2,827) '
          'without reducing spills. Splitting cases 5/6 and decoding the selector also leave allocation unchanged.',
          '- Haraka-256 feed reload adds two static device-load instructions (382 to 384), but does not remove the kernel peak. '
          'These are static instructions, not DRAM traffic measurements.',
          '- Moving the AES key expression later makes spilling worse: 48 instead of 32 bytes. Source load order is not '
          'a guarantee about machine scheduling.',
          '- Disabling AES column unrolling reduces Temporary Registers from 96 to 60 and spills from 32 to zero. '
          'Occupancy rises from 9.14% to 10.03% in its matched replay, while dynamic ALU instructions rise from '
          '5,679,804,896 to 8,277,166,416 (about 45.7%). Runtime GPU throughput decreases. '
          'Lower register use alone is therefore an insufficient selection criterion.',
          '- The explicit 32-byte Haraka-512 snapshot reuses workspace slots 552/553: these are unused during absorption '
          'and dead after mix; keyed finalization reads key slots only through 550. It introduces two vector stores and '
          'two requested reloads per Haraka-512 call, without enlarging scratch. The final replay reports 16 spill bytes '
          'and 9.18% occupancy, but no reproducible net-rate gain was established.',
          '- AES unrolling by two reports 61 Temporary Registers, zero spills and 9.69% occupancy in the final replay. '
          'Executed ALU instructions still increase to 6,488,627,840 from its matched baseline of 5,683,897,376.',
          '- No register-only combination was promoted. The acceptance gate requires correctness, reproducible >=3% median E2E improvement '
          'beyond scatter, and no material long-input regression. Lower-resource but slower kernels remain experiments.',
          '- Narrower metadata, threadgroup snapshots and dispatch/compile-limit tuning remain deferred. Current evidence '
          'does not justify a broad sweep, a forced volatile reload, or more invasive memory changes. No fixed 96-register '
          'hardware boundary is inferred.', '',
          '## Reproduce', '', '```sh', 'make test-register-v22',
          './build/v22/register-study/study bench 64 baseline e5_aes',
          './build/v22/register-study/study bench 1487 baseline e5_aes',
          'MTL_CAPTURE_ENABLED=1 ./build/v22/register-study/study capture 64 baseline e5_aes',
          'make sanitize-v22', '```', '',
          'Open a capture in Xcode, disable automatic profiling, replay, then select Performance / Serial / Medium / Profile. '
          'Inspect Shaders, Compute Kernel counters and Timeline / Pipeline State compiler statistics. '
          'Stop GPU workload before any runtime timing.', '',
          'Frozen source: `experiments/v22-register-pressure/baseline`. Variant transformations: '
          '`tools/v22_register_variants.py`. Results, raw timings, manifests, validation logs, captures and Xcode screenshots: '
          '`build/v22/register-study`. `python3 tools/v22_register_report.py` regenerates this summary without rerunning benchmarks.', '']
(ROOT / 'Docs/research/REGISTER-PRESSURE.md').write_text('\n'.join(lines))
print(STUDY / 'results.json')
