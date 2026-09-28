#!/usr/bin/env python3
"""Build the mining-layout A/B driver and validate the current Metal primitives.

Timing runs are explicit: build/v22/cache-study/study bench 32768 baseline cached.
Reverse arguments and run cached/control in both orders before interpreting gains.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/v22/cache-study'
BASE = ROOT / 'experiments/v22-cache/baseline'
OUT.mkdir(parents=True, exist_ok=True)


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def metal(source, name):
    run('xcrun', 'metal', '-std=metal4.0', '-O3', '-frecord-sources', '-c', str(source), '-o', str(OUT / f'{name}.air'))
    run('xcrun', 'metallib', str(OUT / f'{name}.air'), '-o', str(OUT / f'{name}.metallib'))


metal(BASE / 'Sources/VerusMetalCore/MiningKernels.metal', 'baseline')
# Isolate the new primitive from caching and core-template changes.
holes = OUT / 'holes-source'
shutil.copytree(BASE, holes, dirs_exist_ok=True)
shutil.copy2(ROOT / 'src/v22/platform.h', holes / 'src/v22/platform.h')
metal(holes / 'Sources/VerusMetalCore/MiningKernels.metal', 'holes')
metal(ROOT / 'Sources/VerusMetalCore/MiningKernels.metal', 'cached')
source = (ROOT / 'Sources/VerusMetalCore/MiningKernels.metal').read_text()
source = source.replace('../../src/v22/core.h', str(ROOT / 'src/v22/core.h'))
control = OUT / 'control.metal'
control.write_text(source.replace('verus_search_cached', 'verus_search_control'))
metal(control, 'control')
# Research queue kernel uses the canonical step without altering production code.
core = (ROOT / 'src/v22/core.h').read_text()
start = core.index('        U64 selector = low(acc);', core.index('VM_INLINE U64 mix('))
end = core.index('    return reduce(acc);', start)
body = core[start:end].removesuffix('    }\n')
step = '\ntemplate<typename Work>\nVM_INLINE V mixStep(Work work, V acc) {\n'+body+'    return acc;\n}\n'
core = core.replace('#include "platform.h"', '#include "'+str(ROOT / 'src/v22/platform.h')+'"')
(OUT / 'binned-core.h').write_text(core+step)
binned = OUT / 'binned.metal'
binned.write_text((ROOT / 'experiments/v22-cache/binned.metal').read_text())
metal(binned, 'binned')
metal(ROOT / 'tests/v22-cache-kernels.metal', 'tests')
run('xcrun', 'metal', '-std=metal4.0', '-O3', '-S', '-emit-llvm',
    str(ROOT / 'Sources/VerusMetalCore/MiningKernels.metal'), '-o', str(OUT / 'mining.ll'))
# AIR intrinsics are expected; application helper calls are not.
air = (OUT / 'mining.ll').read_text()
assert not any('call ' in line and '@_Z' in line for line in air.splitlines()), 'Hot-path function call remains'
print('AIR: no application helper calls remain')
frozen = OUT / 'frozen.cpp'
frozen.write_text((BASE / 'src/v22/cpu.cpp').read_text().replace('vm_cpu_hashes', 'vm_frozen_hashes').replace('vm_primitive_test', 'vm_frozen_primitive_test'))
flags = ['xcrun', 'clang++', '-O3', '-std=c++20', '-mcpu=native', '-Wall', '-Wextra']
objects = []
for name, source, includes in [
    ('frozen', frozen, BASE / 'src/v22'),
    ('primitives', ROOT / 'tests/v22-instruction-cases.cpp', BASE / 'src/v22'),
    ('pressure', ROOT / 'tests/v22-pressure-cases.cpp', BASE / 'src/v22'),
    ('cpu', ROOT / 'src/v22/cpu.cpp', ROOT / 'src/v22'),
]:
    obj = OUT / f'{name}.o'
    run(*flags, '-I'+str(includes), '-c', str(source), '-o', str(obj))
    objects.append(str(obj))
run(*flags, '-fobjc-arc', str(ROOT / 'tools/V22CacheStudy.mm'), *objects,
    '-framework', 'Metal', '-framework', 'Foundation', '-o', str(OUT / 'study'))
files = [*ROOT.glob('src/v22/*.[ch]*'), ROOT / 'Sources/VerusMetalCore/MiningKernels.metal',
         ROOT / 'tools/V22CacheStudy.mm', *OUT.glob('*.metallib'), OUT / 'frozen.o']
manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
run(str(OUT / 'study'), 'test')
