#!/usr/bin/env python3
"""Record fresh paired cache benchmarks without overwriting retained evidence.

Build with make test-cache-v22 and make miner first. Stop Xcode GPU replay before
running. Includes both argument orders, identical-source controls and CLI loops.
"""
from pathlib import Path
import hashlib
import json
import statistics
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/v22/cache-study' / ('run-' + str(uuid.uuid4()))
OUT.mkdir(parents=True)
files = [*ROOT.glob('src/v22/*.[ch]*'), *ROOT.glob('Sources/VerusMetalCore/*.swift'),
         ROOT / 'Sources/VerusMetalCore/MiningKernels.metal', ROOT / 'tools/V22CacheStudy.mm',
         ROOT / 'tools/v22_cache_study.py', Path(__file__).resolve(),
         *ROOT.glob('build/v22/cache-study/*.metallib'), ROOT / 'build/v22/cache-study/frozen.o',
         ROOT / 'build/v22/cache-study/study', ROOT / 'build/miner/Build/Products/Release/verusmetal']
manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
summary = {}
cases = [(count,a,b) for count in [4096,32768] for a,b in [
    ('baseline','holes'),('holes','baseline'),('baseline','cached'),('cached','baseline'),
    ('cached','control'),('control','cached')]]
cases += [(32768,a,b) for a,b in [('cached','binned'),('binned','cached'),
                               ('cached:4096','cached:32768'),('cached:32768','cached:4096')]]
for count,a,b in cases:
    key = f'{count}-{a}-{b}'
    raw = subprocess.check_output(['build/v22/cache-study/study','bench',str(count),a,b], cwd=ROOT, text=True)
    (OUT / (key+'.json')).write_text(raw)
    data = json.loads(raw)
    row = {}
    for name in [a,b]:
        row[name] = {}
        for timing in ['gpuSeconds','wallSeconds']:
            rates = [s['count']/s[timing]/1e6 for s in data['samples'] if s['variant']==name]
            median = statistics.median(rates)
            row[name][timing] = {'medianMHs':median,'minMHs':min(rates),'maxMHs':max(rates),
                                'madMHs':statistics.median(abs(v-median) for v in rates)}
    summary[key] = row
    print(key, {name:{k:v['medianMHs'] for k,v in row[name].items()} for name in [a,b]}, flush=True)
for count in [4096,32768]:
    raw = subprocess.check_output(['build/miner/Build/Products/Release/verusmetal','benchmark',
                                   '--duration','10','--batch-nonces',str(count),'--json'], cwd=ROOT, text=True)
    (OUT / f'cli-{count}.json').write_text(raw)
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print('Evidence:', OUT)
