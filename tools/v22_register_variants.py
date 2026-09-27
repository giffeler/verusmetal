#!/usr/bin/env python3
"""Build isolated register-pressure experiments from a frozen source snapshot."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STUDY = ROOT / 'build/v22/register-study'
BASE = ROOT / 'experiments/v22-register-pressure/baseline'


def replace(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def transform(core, platform, name):
    if name == 'e1_finish':
        start = core.index('inline void finish(')
        head, tail = core[:start], core[start:]
        declaration = '    V a = work.get(keyVectors), b = work.get(keyVectors+1);\n'
        tail = replace(tail, declaration, '')
        tail = replace(tail, '    haraka512<true>', declaration + '    haraka512<true>')
        core = head + tail
    elif name == 'e1_parity':
        core = replace(core, 'U64 dividend = low(acc);', 'bool evenDividend = (acc.x & 1) == 0;')
        core = replace(core, 'if ((dividend & 1) == 0)', 'if (evenDividend)')
    elif name == 'e1_selector':
        core = replace(core, 'U64 selector = low(acc);', 'U32 selectorLow = acc.x, selectorHigh = acc.y;')
        for old, new in [
            ('U32(selector >> 5)', '(selectorLow >> 5)'),
            ('U32(selector >> 32)', 'selectorHigh'),
            ('U32(selector >> 2)', '(selectorLow >> 2)'),
            ('U32(selector)', 'selectorLow'),
            ('int(selector >> 61)', 'int(selectorHigh >> 29)'),
            ('(selector & (U64(1) << (28+r))) != 0',
             '((((selectorLow >> 28) | (selectorHigh << 4)) >> r) & 1) != 0'),
        ]:
            assert old in core
            core = core.replace(old, new)
    elif name == 'e2_late':
        core = replace(core, '        V p = work.message(lane), q = work.message(lane ^ 1);\n', '')
        core = core.replace('operation == 0 ? q : p', 'work.message(operation == 0 ? lane ^ 1 : lane)')
        core = core.replace('operation == 0 ? p : q', 'work.message(operation == 0 ? lane : lane ^ 1)')
        core = core.replace('left ^ q', 'left ^ work.message(lane ^ 1)')
        core = core.replace('cross(q)', 'cross(work.message(lane ^ 1))')
        core = core.replace('cross(left ^ p) ^ cross(p)', 'cross(left ^ work.message(lane)) ^ cross(work.message(lane))')
        core = core.replace('acc ^= p;', 'acc ^= work.message(lane);')
        core = core.replace('(right ^ q) : (cross(right ^ p) ^ cross(p))',
                            '(right ^ work.message(lane ^ 1)) : (cross(right ^ work.message(lane)) ^ cross(work.message(lane)))')
        core = replace(core, 'V a = q, b = p;', 'V a = work.message(lane ^ 1), b = work.message(lane);')
        core = replace(core, '((r & 1) != 0) == branch ? p : q',
                       'work.message(((r & 1) != 0) == branch ? lane : lane ^ 1)')
    elif name == 'e2_split':
        start = core.index('        case 5:\n')
        end = core.index('\n        }\n    }\n    return reduce', start)
        core = core[:start] + '''        case 5: {
            U32 cursor = first, aesOffset = 0;
            for (int r = int(selector >> 61); r >= 0; --r) {
                V last = work.get(cursor++);
                bool branch = (selector & (U64(1) << (28+r))) != 0;
                V selected = ((r & 1) != 0) == branch ? p : q;
                if (branch) acc ^= cross(last ^ selected);
                else {
                    keyedPair(last, selected, work, cursor+aesOffset);
                    aesOffset += 4;
                    acc ^= last ^ selected;
                }
            }
            V left = work.get(first), right = work.get(second);
            work.put(second, left ^ roundedProduct(acc, left));
            work.put(first, right);
            break;
        }
        case 6: {
            U32 cursor = first;
            V last{};
            for (int r = int(selector >> 61); r >= 0; --r) {
                last = work.get(cursor++);
                bool branch = (selector & (U64(1) << (28+r))) != 0;
                V selected = ((r & 1) != 0) == branch ? p : q;
                last ^= selected;
                if (branch) acc ^= remainder(last, U32(selector));
                else { last = cross(last); acc ^= roundedProduct(acc, last); }
            }
            V right = work.get(second);
            work.put(second, last);
            work.put(first, right ^ acc);
            break;
        }''' + core[end:]
    elif name == 'e3_halves':
        platform = replace(platform, '''    int4 al = as_type<int4>(a << 16) >> 16, bl = as_type<int4>(b << 16) >> 16;
    int4 ah = as_type<int4>(a) >> 16, bh = as_type<int4>(b) >> 16;
    return (as_type<V>((al * bl + 16384) >> 15) & 65535u)
        | (as_type<V>((ah * bh + 16384) >> 15) << 16);''', '''    V packed;
    {
        int4 al = as_type<int4>(a << 16) >> 16, bl = as_type<int4>(b << 16) >> 16;
        packed = as_type<V>((al * bl + 16384) >> 15) & 65535u;
    }
    {
        int4 ah = as_type<int4>(a) >> 16, bh = as_type<int4>(b) >> 16;
        packed |= as_type<V>((ah * bh + 16384) >> 15) << 16;
    }
    return packed;''')
    elif name == 'e4_reload':
        core = replace(core, 'inline void haraka256(VM_THREAD V &a, VM_THREAD V &b)',
                       'inline void haraka256(VM_THREAD V &a, VM_THREAD V &b, Workspace work, U32 source)')
        core = replace(core, '    V originalA = a, originalB = b;\n', '')
        core = replace(core, 'a ^= originalA; b ^= originalB;', 'a ^= work.get(source); b ^= work.get(source+1);')
        core = replace(core, 'haraka256(a, b);', 'haraka256(a, b, work, k == 0 ? keyVectors : k-2);')
    elif name == 'e2_aes_key':
        for state, offset in [('a', 'offset'), ('b', 'offset + 1'), ('a', 'offset + 2'), ('b', 'offset + 3')]:
            core = replace(core, f'aes({state}, key.get({offset}))', f'(aes({state}, V{{}}) ^ key.get({offset}))')
        for state, offset in [('a', 'offset+k'), ('b', 'offset+k+1'), ('c', 'offset+k+2'), ('d', 'offset+k+3')]:
            rc = offset.removeprefix('offset+')
            core = replace(core, f'aes({state}, keyed ? key.get({offset}) : RC[{rc}])',
                           f'(aes({state}, V{{}}) ^ (keyed ? key.get({offset}) : RC[{rc}]))')
    elif name == 'e5_product':
        platform = replace(platform, '    for (U32 bit = 0; bit != 64; ++bit)',
                           '    #pragma clang loop unroll(disable)\n    for (U32 bit = 0; bit != 64; ++bit)')
    elif name == 'e5_rounds':
        assert core.count('    for (U32 r = 0; r != 5; ++r)') == 2
        core = core.replace('    for (U32 r = 0; r != 5; ++r)',
                            '    #pragma clang loop unroll(disable)\n    for (U32 r = 0; r != 5; ++r)')
    elif name == 'e5_aes':
        platform = replace(platform, '    for (U32 c = 0; c != 4; ++c)',
                           '    #pragma clang loop unroll(disable)\n    for (U32 c = 0; c != 4; ++c)')
    elif name == 'e5_aes2':
        platform = replace(platform, '    for (U32 c = 0; c != 4; ++c)',
                           '    #pragma clang loop unroll_count(2)\n    for (U32 c = 0; c != 4; ++c)')
    elif name == 'e1_dispatch':
        pass  # This experiment changes only the entry point below.
    elif name == 'e4_snapshot':
        core = replace(core, '    V feedA{a.z, a.w, b.z, b.w}, feedB{c.x, c.y, d.x, d.y};',
                       '''    // These message slots are unused during absorption and dead after mix.
    // Keyed Haraka reads only key slots 0...550, so the snapshot cannot alias it.
    key.put(keyVectors, V{a.z, a.w, b.z, b.w});
    key.put(keyVectors+1, V{c.x, c.y, d.x, d.y});''')
        core = replace(core, '^ feedB;', '^ key.get(keyVectors+1);')
        core = replace(core, '^ feedA;', '^ key.get(keyVectors);')
    else:
        raise ValueError(name)
    return core, platform


VARIANTS = ['baseline', 'e1_finish', 'e1_parity', 'e1_selector', 'e2_late', 'e2_split', 'e3_halves', 'e4_reload',
            'e2_aes_key', 'e5_product', 'e5_rounds', 'e5_aes', 'e1_dispatch', 'e4_snapshot', 'e5_aes2']


def build(name, steps, extra_source=''):
    dest = STUDY / name
    shutil.copytree(BASE, dest / 'src', dirs_exist_ok=True)
    core = (BASE / 'core.h').read_text()
    platform = (BASE / 'platform.h').read_text()
    for step in steps:
        core, platform = transform(core, platform, step)
    (dest / 'src/core.h').write_text(core)
    (dest / 'src/platform.h').write_text(platform)
    source = (BASE / 'verus.metal').read_text().replace('kernel void verus_v22(', f'kernel void verus_{name}(')
    if 'e1_dispatch' in steps:
        source = replace(source, '    hash(inputs+tid*parameters.inputStride, lengths[tid], work, outputs+2*tid);',
                         '''    absorb(inputs+tid*parameters.inputStride, lengths[tid], work);
    expandKey(work);
    ulong intermediate = mix(work);
    finish(work, lengths[tid]&31, intermediate, outputs+2*tid);''')
    source += '''
kernel void pressure_cases(device uint4 *scratch [[buffer(0)]],
                           device uint4 *output [[buffer(1)]],
                           uint tid [[thread_position_in_grid]]) {
    ulong reduced = mix(Workspace{scratch+tid, 512});
    output[2*tid] = words(reduced, 0);
    V a = scratch[554*512+tid], b = scratch[555*512+tid];
    output[2*tid+1] = roundedProduct(a, b);
}
'''
    source += extra_source
    (dest / 'src/kernel.metal').write_text(source)
    subprocess.run(['xcrun', 'metal', '-std=metal4.0', '-O3', '-frecord-sources', '-c',
                    str(dest / 'src/kernel.metal'), '-o', str(dest / 'kernel.air')], check=True)
    subprocess.run(['xcrun', 'metallib', str(dest / 'kernel.air'), '-o', str(dest / 'kernel.metallib')], check=True)
    manifest = {str(f.relative_to(dest)): hashlib.sha256(f.read_bytes()).hexdigest()
                for f in sorted(dest.rglob('*')) if f.is_file() and f.suffix in ['.h', '.metal', '.metallib', '.air']}
    (dest / 'manifest.json').write_text(json.dumps({'steps': steps, 'sha256': manifest}, indent=2)+'\n')
    print(name, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', nargs='?', choices=VARIANTS + ['combined'])
    parser.add_argument('--steps', nargs='+', choices=VARIANTS[1:])
    args = parser.parse_args()
    for name in ([args.name] if args.name else VARIANTS):
        build(name, args.steps if name == 'combined' else ([] if name == 'baseline' else [name]))
